#!/usr/bin/env python3
"""
frameshiftd — the world-state daemon for Frameshift.

Polls the real system (psutil + /proc + ss) and serves world snapshots as
newline-delimited JSON over a Unix socket. One client at a time is fine for
v0; the game just reads the latest line.

Protocol:
  HTTP on 127.0.0.1:$FRAMESHIFT_PORT (default 8765):
    GET /world.json  -> latest world snapshot (JSON)
    GET /health      -> {"ok": true}
  The game polls /world.json once per second. Loopback only, no auth —
  this is a local game feed, not a service.

World schema (v0):
  {
    "t": float, "tick": int,
    "host": {"hostname","os","uptime","boot_time"},
    "cpu": {"count","per_core":[..],"total":float,"load":[1,5,15]},
    "mem": {"total","used","available","swap_total","swap_used","percent"},
    "disk": {"total","used","percent","read_bps","write_bps"},
    "procs": [ {pid,name,user,state,ppid,cpu,mem_rss,mem_percent,
                threads,children,age,cmdline,frozen} ],
    "net": {"conns":[{fdip,fdport,fhip,fhport,state,proto}],
            "listeners":[{ip,port,proto}],
            "remote_hosts":[{ip,count}]}
  }
"""
import json
import atexit
import collections
import gzip
import os
import random
import shutil
import socket
import subprocess
import sys
import threading
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import oracle_bridge  # noqa: E402  (Kernel Oracle client side)
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import psutil
except ImportError:
    sys.exit("frameshiftd requires psutil: pip install psutil")

PORT = int(os.environ.get("FRAMESHIFT_PORT", "8765"))
TICK = float(os.environ.get("FRAMESHIFT_TICK", "1.0"))

# --- enemies: real CPU-burner child processes the player must hunt ---
ENEMY_CAP = int(os.environ.get("FRAMESHIFT_ENEMIES", "4"))
ENEMY_TTL = float(os.environ.get("FRAMESHIFT_ENEMY_TTL", "180"))
ENEMY_SPAWN_SECS = float(os.environ.get("FRAMESHIFT_ENEMY_SPAWN", "20"))
ENEMY_FREEZE_ESCAPE = 8.0
ENEMIES = {}  # pid -> {"proc": Popen, "spawned": t, "frozen_since": float|None}
_last_spawn = [0.0]
# 0 = off, 1 = local only, 2 = local + remote machines (opt-in per level)
ENEMY_LEVEL = [0]
REMOTE_ENEMIES = {}  # host -> {pid: spawned_ts}
REMOTE_ENEMY_CAP = 2
_last_remote_spawn = [0.0]


def _remote_burn_cmd(ttl: float, hog_mb: int) -> str:
    """nohup'd burner on the far side; TTL is its only leash (plus purge)."""
    return ("nohup nice -n 19 python3 -c '%s' %d %d >/dev/null 2>&1 & echo $!"
            % (_BURN.replace("'", "'\\''"), int(ttl), hog_mb * 1024 * 1024))


def _remote_tend_cmd(pids) -> str:
    """Report each tracked pid's state; SIGCONT any frozen one (a stopped
    process cannot run its own TTL clock — same leak we plugged locally, and
    PDEATHSIG is useless over ssh since the session parent exits at once)."""
    parts = []
    for p in pids:
        parts.append(
            "s=$(awk '{print $3}' /proc/{p}/stat 2>/dev/null || echo Z); "
            "[ \"$s\" = T ] && kill -CONT {p} 2>/dev/null; echo {p} $s".format(p=p))
    return "; ".join(parts)


def _tend_remote_host(host: str):
    tracked = REMOTE_ENEMIES.get(host, {})
    if not tracked:
        return
    rc, out, _err = _ssh_run(host, _remote_tend_cmd(tracked.keys()), timeout=10)
    if rc != 0:
        return
    for line in out.splitlines():
        cols = line.split()
        if len(cols) == 2 and cols[0].isdigit():
            if cols[1] in ("Z", "?"):
                tracked.pop(int(cols[0]), None)


def _spawn_remote_enemies():
    """Best-effort: drop a rogue on each open host that lacks one. Never blocks long."""
    status = ssh_probe_status()
    for host, st in status.items():
        if st != "open":
            continue
        _tend_remote_host(host)
        have = {p: t for p, t in REMOTE_ENEMIES.get(host, {}).items()
                if time.time() - t < ENEMY_TTL + 30}
        if len(have) >= REMOTE_ENEMY_CAP:
            REMOTE_ENEMIES[host] = have
            continue
        hog_mb = random.randint(100, 400)
        rc, out, _err = _ssh_run(host, _remote_burn_cmd(ENEMY_TTL, hog_mb), timeout=10)
        if rc == 0 and out.strip().isdigit():
            have[int(out.strip())] = time.time()
            REMOTE_ENEMIES[host] = have


def _purge_remote_enemies():
    for host, pids in REMOTE_ENEMIES.items():
        if pids:
            _ssh_run(host, "kill -9 " + " ".join(str(p) for p in pids), timeout=10)
    REMOTE_ENEMIES.clear()


def _child_guard() -> None:
    """Runs in the child between fork and exec (child context!)."""
    os.nice(19)
    os.setpgrp()  # own process group; can't accidentally signal our session
    # kernel guarantee: SIGTERM the instant the daemon dies, even if the
    # child is SIGSTOPped (a frozen process cannot run its own TTL clock)
    import ctypes
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, 15)  # PR_SET_PDEATHSIG, SIGTERM

_BURN = (
    "import time,sys,random\n"
    "end=time.time()+float(sys.argv[1])\n"
    "target=int(sys.argv[2])\n"
    "hog=[]\n"
    "got=0\n"
    "while got<target:\n"
    "    try:\n"
    "        hog.append(bytearray(16*1024*1024)); got+=16*1024*1024\n"
    "    except MemoryError:\n"
    "        break\n"
    "while time.time()<end:\n"
    "    pass\n"
)


def _spawn_enemy():
    # each rogue burns one core AND hoards 100-600 MB of real RAM
    hog_mb = random.randint(100, 600)
    p = subprocess.Popen(
        [sys.executable, "-c", _BURN, str(ENEMY_TTL), str(hog_mb * 1024 * 1024)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        preexec_fn=_child_guard,
    )
    ENEMIES[p.pid] = {"proc": p, "spawned": time.time(), "frozen_since": None}
    return p.pid


def _kill_all_enemies():
    for pid, e in list(ENEMIES.items()):
        try:
            e["proc"].kill()
        except OSError:
            pass
    ENEMIES.clear()
    if REMOTE_ENEMIES:
        try:
            _purge_remote_enemies()
        except Exception:
            pass  # best effort on shutdown


def _tend_enemies():
    """Reap dead, punish freezes, keep the world at population (per level)."""
    now = time.time()
    if ENEMY_LEVEL[0] == 0:
        if ENEMIES:
            _kill_all_enemies()
        if REMOTE_ENEMIES:
            _purge_remote_enemies()
        return
    for pid in list(ENEMIES.keys()):
        e = ENEMIES[pid]
        if e["proc"].poll() is not None:
            del ENEMIES[pid]
            continue
        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                state = f.read().rsplit(b")", 1)[1].split()[0]
        except OSError:
            state = b"?"
        if state == b"T":
            if e["frozen_since"] is None:
                e["frozen_since"] = now
            elif now - e["frozen_since"] > ENEMY_FREEZE_ESCAPE:
                os.kill(pid, 18)  # SIGCONT — rogues break free
                e["frozen_since"] = None
        else:
            e["frozen_since"] = None
    if len(ENEMIES) < ENEMY_CAP and now - _last_spawn[0] > ENEMY_SPAWN_SECS:
        _last_spawn[0] = now
        try:
            _spawn_enemy()
        except OSError:
            pass
    if ENEMY_LEVEL[0] >= 2 and now - _last_remote_spawn[0] > ENEMY_SPAWN_SECS:
        # ssh round-trips are slow: never block the world tick on them
        if not getattr(_spawn_remote_enemies, "_busy", False):
            _spawn_remote_enemies._busy = True
            _last_remote_spawn[0] = now
            threading.Thread(target=_remote_spawn_thread, daemon=True).start()


def _remote_spawn_thread():
    try:
        _spawn_remote_enemies()
    finally:
        _spawn_remote_enemies._busy = False

_prev_disk = {"t": None, "read": 0, "write": 0}

# --- hydras: processes that respawn right after being smited ---
_recent_kills = {}  # name -> (kill_time, killed_pid)
HYDRA_WINDOW = 10.0


def _note_kill(pid: int, name: str) -> None:
    _recent_kills[name] = (time.time(), pid)


def _hydra_flags(procs) -> None:
    """Tag procs born within HYDRA_WINDOW of a smite of the same name."""
    now = time.time()
    stale = [n for n, (t, _) in _recent_kills.items() if now - t > HYDRA_WINDOW]
    for n in stale:
        del _recent_kills[n]
    if not _recent_kills:
        return
    for p in procs:
        hit = _recent_kills.get(p["name"])
        if hit and p["pid"] != hit[1] and p["age"] <= HYDRA_WINDOW:
            p["hydra"] = True


def _read_process_state(pid: int) -> str:
    """Get real process state from /proc (psutil 'running' vs our frozen check)."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            # state is the field after the comm field, which may contain spaces
            raw = f.read().rsplit(b")", 1)[1].split()
            return raw[0].decode()
    except OSError:
        return "?"


def gather_processes():
    procs = []
    children_of = {}
    infos = []
    for p in psutil.process_iter(
        ["pid", "name", "username", "status", "ppid", "cpu_percent",
         "memory_info", "memory_percent", "num_threads", "create_time",
         "cmdline", "cpu_num"]
    ):
        try:
            infos.append(p.info)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    for info in infos:
        children_of.setdefault(info["ppid"], []).append(info["pid"])
    now = time.time()
    for info in infos:
        pid = info["pid"]
        mi = info.get("memory_info")
        ct = info.get("create_time") or now
        procs.append({
            "pid": pid,
            "name": info.get("name") or "?",
            "user": info.get("username") or "?",
            "state": _read_process_state(pid),  # 'T' means SIGSTOP'd — frozen in-world
            "ppid": info["ppid"],
            "cpu": round(info.get("cpu_percent") or 0.0, 1),
            "mem_rss": mi.rss if mi else 0,
            "mem_percent": round(info.get("memory_percent") or 0.0, 2),
            "threads": info.get("num_threads") or 0,
            "children": len(children_of.get(pid, [])),
            "age": round(now - ct, 1),
            "cpu_num": info.get("cpu_num", -1) if info.get("cpu_num", -1) is not None else -1,
            "cmdline": " ".join(info.get("cmdline") or [])[:200],
        })
    _hydra_flags(procs)
    return procs


def gather_net():
    conns, listeners, remote_counts = [], [], {}
    try:
        raw = psutil.net_connections(kind="inet")
    except (psutil.AccessDenied, PermissionError):
        raw = []
    for c in raw:
        proto = "tcp" if c.type == socket.SOCK_STREAM else "udp"
        la, ra = c.laddr, c.raddr
        entry = {
            "fdip": la.ip if la else "", "fdport": la.port if la else 0,
            "fhip": ra.ip if ra else "", "fhport": ra.port if ra else 0,
            "state": c.status, "proto": proto, "pid": c.pid or 0,
        }
        if c.status == psutil.CONN_LISTEN:
            listeners.append(entry)
        else:
            conns.append(entry)
            if ra and ra.ip:
                remote_counts[ra.ip] = remote_counts.get(ra.ip, 0) + 1
    remotes = sorted(
        ({"ip": ip, "count": n} for ip, n in remote_counts.items()),
        key=lambda x: -x["count"],
    )
    return {"conns": conns[:512], "listeners": listeners, "remote_hosts": remotes}


def gather_disk():
    d = psutil.disk_io_counters()
    now = time.time()
    read_bps = write_bps = 0.0
    if _prev_disk["t"] is not None and d:
        dt = max(now - _prev_disk["t"], 1e-6)
        read_bps = (d.read_bytes - _prev_disk["read"]) / dt
        write_bps = (d.write_bytes - _prev_disk["write"]) / dt
    if d:
        _prev_disk.update(t=now, read=d.read_bytes, write=d.write_bytes)
    du = psutil.disk_usage("/")
    return {
        "total": du.total, "used": du.used,
        "percent": du.percent,
        "read_bps": int(read_bps), "write_bps": int(write_bps),
    }


def gather_hardware():
    """Mounts, GPU busy%, temperatures — the physical geography."""
    mounts = []
    seen = set()
    for part in psutil.disk_partitions(all=False):
        if part.mountpoint in seen:
            continue
        seen.add(part.mountpoint)
        try:
            du = psutil.disk_usage(part.mountpoint)
            pct = du.percent
        except OSError:
            pct = 0
        mounts.append({
            "path": part.mountpoint, "fstype": part.fstype,
            "total": du.total if pct else 0, "percent": pct,
        })
    gpu_busy = -1
    try:  # amdgpu / nvidia expose a sysfs busy percent (card index varies)
        import glob
        for cand in sorted(glob.glob("/sys/class/drm/card*/device/gpu_busy_percent")):
            with open(cand) as f:
                gpu_busy = int(f.read().strip())
            break
    except (OSError, ValueError):
        pass
    temps = {}
    try:
        st = psutil.sensors_temperatures()
        for label, entries in (st or {}).items():
            if entries:
                temps[label] = round(entries[0].current, 1)
    except Exception:
        pass
    return {"mounts": mounts, "gpu_busy": gpu_busy, "temps": temps}


def ssh_hosts() -> list:
    """Hosts from ~/.ssh/config (no wildcards). The travel network."""
    path = os.path.expanduser("~/.ssh/config")
    hosts = []
    try:
        with open(path) as f:
            for line in f:
                s = line.strip()
                if s.lower().startswith("host ") and "*" not in s:
                    for tok in s.split()[1:]:
                        if "*" not in tok and tok not in hosts:
                            hosts.append(tok)
    except OSError:
        pass
    return hosts


_ssh_probe_cache = {"t": 0.0, "status": {}, "refreshing": False}

# ---------------------------------------------------------------- sim mode
# The daemon ALWAYS records a rolling window of world snapshots (zlib'd;
# ~15 MB for the full window). Sim mode replays that window instead of live
# telemetry and hard-refuses every real verb. This is the tier-0 safe world:
# the daemon is the enforcement point, not the game.
SIM_WINDOW = int(os.environ.get("FRAMESHIFT_SIM_WINDOW", "1800"))  # ticks (1/s)
SIM_DIR = os.path.expanduser("~/.local/share/wopr/saves")
_sim = {
    "buffer": collections.deque(maxlen=SIM_WINDOW),  # list of zlib'd snapshots
    "playing": False,
    "idx": 0,
    "speed": 1.0,       # ticks per real second
    "last_emit": 0.0,
    "name": "live-window",
}


def sim_active() -> bool:
    return _sim["playing"]


def sim_record(snap: dict) -> None:
    _sim["buffer"].append(zlib.compress(
        json.dumps(snap, separators=(",", ":")).encode(), 1))


def sim_next() -> dict | None:
    """Next replayed snapshot at the configured speed, or None if not playing."""
    if not _sim["playing"] or not _sim["buffer"]:
        return None
    now = time.time()
    if now - _sim["last_emit"] < 1.0 / max(_sim["speed"], 0.25):
        return None  # not time for the next replay tick yet
    _sim["last_emit"] = now
    _sim["idx"] = (_sim["idx"] + 1) % len(_sim["buffer"])
    return json.loads(zlib.decompress(_sim["buffer"][_sim["idx"]]))


def sim_state() -> dict:
    return {
        "playing": _sim["playing"],
        "idx": _sim["idx"],
        "length": len(_sim["buffer"]),
        "speed": _sim["speed"],
        "name": _sim["name"],
    }


def sim_control(req: dict) -> dict:
    op = req.get("op")
    buf = _sim["buffer"]
    if op == "start":
        if not buf:
            return {"ok": False, "error": "nothing recorded yet"}
        _sim["playing"] = True
        _sim["idx"] = int(req.get("idx", len(buf) - 1)) % len(buf)
        _sim["name"] = str(req.get("name", "live-window"))
        return {"ok": True, "sim": sim_state()}
    if op == "stop":
        _sim["playing"] = False
        return {"ok": True, "sim": sim_state()}
    if op == "speed":
        _sim["speed"] = max(0.25, min(8.0, float(req.get("speed", 1.0))))
        return {"ok": True, "sim": sim_state()}
    if op == "jump":
        if buf:
            _sim["idx"] = int(req.get("idx", 0)) % len(buf)
        return {"ok": True, "sim": sim_state()}
    if op == "save":
        os.makedirs(SIM_DIR, exist_ok=True)
        name = "".join(c for c in str(req.get("name", "save"))
                       if c.isalnum() or c in "-_.") or "save"
        path = os.path.join(SIM_DIR, f"{name}.wopr.gz")
        with gzip.open(path, "wb") as f:
            for blob in buf:
                f.write(blob)
                f.write(b"\x00\x00\x00\x00")  # zlib stream delimiter
        return {"ok": True, "path": path, "frames": len(buf)}
    if op == "load":
        name = "".join(c for c in str(req.get("name", ""))
                       if c.isalnum() or c in "-_.")
        path = os.path.join(SIM_DIR, f"{name}.wopr.gz")
        if not name or not os.path.exists(path):
            return {"ok": False, "error": f"no such save: {name or '?'}"}
        frames = []
        with gzip.open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                frames.append(chunk)
        # re-split concatenated zlib streams
        raw = b"".join(frames)
        blobs, pos = [], 0
        while pos < len(raw):
            end = raw.find(b"\x00\x00\x00\x00", pos)
            if end < 0:
                break
            blobs.append(raw[pos:end])
            pos = end + 4
        if not blobs:
            return {"ok": False, "error": "save is empty or corrupt"}
        buf.clear()
        buf.extend(blobs)
        _sim["playing"] = True
        _sim["idx"] = 0
        _sim["name"] = name
        return {"ok": True, "sim": sim_state()}
    if op == "list":
        try:
            os.makedirs(SIM_DIR, exist_ok=True)
            saves = sorted(f[:-8] for f in os.listdir(SIM_DIR)
                           if f.endswith(".wopr.gz"))
        except OSError:
            saves = []
        return {"ok": True, "saves": saves}
    return {"ok": False, "error": "unknown sim op"}


def _ssh_run(host: str, cmd: str, timeout: float = 8.0):
    """Fixed-verb ssh runner. BatchMode: never prompts, never hangs."""
    try:
        r = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
             host, cmd],
            capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except OSError as e:
        return 125, "", str(e)


def _ssh_probe_refresh():
    status = {}
    for h in ssh_hosts():
        rc, out, err = _ssh_run(h, "echo ok", timeout=7)
        if rc == 0:
            status[h] = "open"
        elif "host key verification failed" in err.lower():
            status[h] = "unknown-hostkey"
        else:
            status[h] = "closed"
    _ssh_probe_cache.update(t=time.time(), status=status, refreshing=False)


def ssh_probe_status() -> dict:
    """Cached reachability per host; refresh runs off-thread so the world
    tick never blocks on ssh timeouts."""
    c = _ssh_probe_cache
    if not c["refreshing"] and time.time() - c["t"] > 30:
        c["refreshing"] = True
        threading.Thread(target=_ssh_probe_refresh, daemon=True).start()
    # copy: the refresh thread mutates the live dict; the world tick iterates it
    return dict(c["status"])


_REMOTE_WORLD = (
    "echo '@@LOAD '$(cat /proc/loadavg); "
    "echo '@@MEM '$(grep -E '^(MemTotal|MemAvailable)' /proc/meminfo | awk '{printf \"%s \", $2}'); "
    "echo '@@HOST '$(hostname); "
    "ps -eo pid,ppid,user,comm,rss,pcpu,state --no-headers 2>/dev/null | head -400"
)


def remote_world(host: str) -> dict:
    rc, out, err = _ssh_run(host, _REMOTE_WORLD)
    if rc != 0:
        return {"error": err or f"ssh exit {rc}"}
    procs, load, mem, rhost = [], [0, 0, 0], (0, 0), host
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("@@LOAD "):
            load = line[7:].split()[:3]
        elif line.startswith("@@MEM "):
            parts = line[6:].split()
            if len(parts) >= 2:
                mem = (int(parts[0]) * 1024, int(parts[1]) * 1024)
        elif line.startswith("@@HOST "):
            rhost = line[7:]
        elif line:
            cols = line.split(None, 6)
            if len(cols) >= 7:
                try:
                    procs.append({
                        "pid": int(cols[0]), "ppid": int(cols[1]),
                        "user": cols[2], "name": cols[3],
                        "mem_rss": int(cols[4]) * 1024,
                        "cpu": float(cols[5]), "state": cols[6],
                    })
                except ValueError:
                    continue
    total, avail = mem
    return {
        "host": rhost, "load": load,
        "mem": {"total": total, "available": avail,
                "percent": round(100.0 * (total - avail) / max(total, 1), 1)},
        "procs": procs,
        "enemies": sorted(REMOTE_ENEMIES.get(host, {}).keys()),
    }


_REMOTE_LIST_TMPL = (
    "cd -- {path} 2>/dev/null || {{ echo CDD_FAIL; exit 0; }}; "
    "find . -maxdepth 1 -mindepth 1 -printf '%y %s %T@ %f\\n' 2>/dev/null | head -400"
)


def remote_list(host: str, path: str) -> dict:
    import shlex
    # let the REMOTE shell expand ~ (remote user may differ from local)
    if path in ("~", ""):
        qpath = "$HOME"
    elif path.startswith("~/"):
        qpath = '"$HOME"/' + shlex.quote(path[2:])
    else:
        qpath = shlex.quote(path)
    rc, out, err = _ssh_run(host, _REMOTE_LIST_TMPL.format(path=qpath))
    if rc != 0:
        return {"error": err or f"ssh exit {rc}"}
    if "CDD_FAIL" in out:
        return {"error": "no such directory"}
    entries = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        typ, size, mtime, name = parts
        entries.append({
            "name": name, "dir": typ == "d",
            "size": int(float(size)), "mtime": float(mtime),
        })
    entries.sort(key=lambda x: (not x["dir"], -x["size"]))
    parent = os.path.dirname(path.rstrip("/")) or "/"
    return {"path": path, "parent": parent, "entries": entries, "truncated": False}


def remote_action(host: str, req: dict) -> dict:
    """Fixed verbs only: kill(pid,sig) and rm(path) on the remote."""
    import shlex
    verb = req.get("verb")
    if verb == "kill":
        pid, sig = int(req.get("pid", -1)), int(req.get("sig", 0))
        if sig not in (19, 18, 9) or pid < 1:
            return {"ok": False, "error": "bad kill args"}
        rc, out, err = _ssh_run(host, f"kill -{sig} {pid} 2>&1; echo RC:$?")
        ok = "RC:0" in out
        return {"ok": ok, "syscall": f"ssh {host} kill({pid},{sig})",
                "error": None if ok else (out + err).replace("RC:1", "").strip()}
    if verb == "rm":
        if not req.get("confirm"):
            return {"ok": False, "error": "rm requires confirm"}
        path = str(req.get("path", ""))
        if path in ("", "/", "~", ".", ".."):
            return {"ok": False, "error": "refused"}
        rc, out, err = _ssh_run(
            host, f"rm -rf -- {shlex.quote(path)} 2>&1; echo RC:$?")
        ok = "RC:0" in out
        return {"ok": ok, "syscall": f"ssh {host} rm -rf {path}",
                "error": None if ok else (out + err).replace("RC:1", "").strip()}
    return {"ok": False, "error": "unknown remote verb"}


def gather_listing(path: str) -> dict:
    """Directory contents for vault interiors. Dir sizes use a capped walk."""
    path = os.path.realpath(path)
    budget = [20000]

    def dir_size(d: str) -> int:
        total = 0
        for root, _dirs, files in os.walk(d):
            for f in files:
                if budget[0] <= 0:
                    return total
                budget[0] -= 1
                try:
                    total += os.lstat(os.path.join(root, f)).st_size
                except OSError:
                    pass
        return total

    entries = []
    with os.scandir(path) as it:
        for e in it:
            try:
                is_dir = e.is_dir(follow_symlinks=False)
                st = e.stat(follow_symlinks=False)
                entries.append({
                    "name": e.name, "dir": is_dir,
                    "size": dir_size(e.path) if is_dir else st.st_size,
                    "mtime": st.st_mtime,
                })
            except OSError:
                continue
    entries.sort(key=lambda x: (not x["dir"], -x["size"]))
    return {
        "path": path,
        "parent": os.path.dirname(path) or "/",
        "entries": entries[:400],
        "truncated": len(entries) > 400,
    }


def protected_paths() -> set:
    """Paths the rm verb will never touch, even in Tier 2."""
    home = os.path.expanduser("~")
    s = {"/", "/home", home, os.path.expanduser("~/.hermes")}
    try:
        for part in psutil.disk_partitions(all=False):
            s.add(os.path.realpath(part.mountpoint))
    except Exception:
        pass
    return s


def gather_world(tick: int) -> dict:
    vm = psutil.virtual_memory()
    sw = psutil.swap_memory()
    try:
        load = list(os.getloadavg())
    except OSError:
        load = [0.0, 0.0, 0.0]
    osname = "unknown"
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    osname = line.split("=", 1)[1].strip().strip('"')
                    break
    except OSError:
        pass
    boot = psutil.boot_time()
    try:
        me = psutil.Process().username()
    except psutil.Error:
        me = "?"
    return {
        "t": time.time(),
        "tick": tick,
        "me": {"user": me, "pid": os.getpid()},
        "host": {
            "hostname": socket.gethostname(),
            "os": osname,
            "uptime": round(time.time() - boot, 1),
            "boot_time": boot,
        },
        "cpu": {
            "count": psutil.cpu_count(logical=True),
            "per_core": psutil.cpu_percent(percpu=True),
            "total": psutil.cpu_percent(),
            "load": [round(x, 2) for x in load],
        },
        "mem": {
            "total": vm.total, "used": vm.used, "available": vm.available,
            "swap_total": sw.total, "swap_used": sw.used,
            "percent": vm.percent,
        },
        "disk": gather_disk(),
        "hw": gather_hardware(),
        "procs": gather_processes(),
        "net": gather_net(),
        "enemies": sorted(ENEMIES.keys()),
        "enemies_level": ENEMY_LEVEL[0],
        "remote_enemies": {h: sorted(p.keys()) for h, p in dict(REMOTE_ENEMIES).items()},
        "ssh": {"hosts": ssh_hosts(), "status": ssh_probe_status()},
        "oracle": oracle_bridge.status(),
    }


class _Handler(BaseHTTPRequestHandler):
    # latest snapshot is shared state on the class
    blob: bytes = b""

    @staticmethod
    def _protected() -> set:
        # Never signal: PID 0/1, this daemon, or any of its ancestors
        # (our shell, the terminal). Tier-2 protected set.
        s = {0, 1, os.getpid()}
        try:
            cur = os.getpid()
            for _ in range(16):
                ppid = psutil.Process(cur).ppid()
                if ppid in s or ppid == 0:
                    break
                s.add(ppid)
                cur = ppid
        except psutil.Error:
            pass
        return s

    def do_POST(self):
        if self.path != "/action":
            self.send_error(404)
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n))
            verb = req.get("verb")
            host = req.get("host")
            if verb == "sim":
                body = json.dumps(sim_control(req)).encode()
            elif sim_active():
                # SIM LOCKOUT: while a replay is playing the daemon refuses
                # every real verb — kills, rm, ssh, enemy spawns, oracle.
                # The safe tier is enforced here, server-side, not by the
                # game's UI. Only "sim" control itself passes.
                body = json.dumps({"ok": False, "error": "SIM MODE: verbs are frozen. stop the sim first (M)"}).encode()
            elif verb == "enemies":
                if "level" in req:
                    ENEMY_LEVEL[0] = max(0, min(2, int(req["level"])))
                else:
                    ENEMY_LEVEL[0] = 1 if req.get("on") else 0
                if ENEMY_LEVEL[0] == 0:
                    _kill_all_enemies()
                    _purge_remote_enemies()
                elif ENEMY_LEVEL[0] == 1 and REMOTE_ENEMIES:
                    _purge_remote_enemies()
                body = json.dumps({"ok": True,
                                   "enemies": ENEMY_LEVEL[0]}).encode()
            elif host:
                body = json.dumps(remote_action(str(host), req)).encode()
            elif verb == "rm":
                body = self._do_rm(req)
            elif verb == "oracle_arm":
                # the incantation is the sudo password. it is piped to sudo
                # and never logged, stored, or echoed by this daemon.
                body = json.dumps(oracle_bridge.arm(str(req.get("incantation", "")))).encode()
            elif verb == "oracle_disarm":
                body = json.dumps(oracle_bridge.disarm()).encode()
            elif verb == "oracle":
                # fixed-verb passthrough: "kill 123 9", "rm /path --i-know",
                # "systemctl stop foo", "snapshot create desc", ...
                # The Oracle is the authority on what is allowed.
                line = str(req.get("line", ""))
                if not line.strip():
                    raise ValueError("oracle verb requires 'line'")
                out = oracle_bridge.verb(line.strip())
                out.setdefault("verb", line.strip())
                body = json.dumps(out).encode()
            else:
                body = self._do_kill(req)
        except Exception as e:
            body = json.dumps({"ok": False, "error": str(e)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    @staticmethod
    def _do_kill(req: dict) -> bytes:
        pid, sig = int(req.get("pid", -1)), int(req.get("sig", 0))
        if req.get("verb") != "kill" or sig not in (19, 18, 9):
            raise ValueError("verb must be 'kill', sig must be 19/18/9")
        if pid in _Handler._protected():
            raise ValueError(f"pid {pid} is protected")
        if sig == 9:
            # remember the victim's name so a respawn can be flagged as hydra
            try:
                with open(f"/proc/{pid}/comm", "rb") as f:
                    _note_kill(pid, f.read().decode().strip())
            except OSError:
                pass
        os.kill(pid, sig)
        return json.dumps({"ok": True, "syscall": f"kill({pid}, {sig})"}).encode()

    @staticmethod
    def _do_rm(req: dict) -> bytes:
        # Tier-2 file verb: real rm -rf, but guarded. Requires explicit
        # confirm flag (the game's hold-to-erase gesture sets it), refuses
        # protected paths, and refuses anything not writable by this user.
        if not req.get("confirm"):
            raise ValueError("rm requires confirm=true (hold the erase key)")
        raw = str(req.get("path", ""))
        path = os.path.realpath(os.path.expanduser(raw))
        if not os.path.exists(path) and not os.path.islink(path):
            raise ValueError(f"no such path: {path}")
        if path in protected_paths():
            raise ValueError(f"{path} is protected")
        # never climb above a mount root into protected territory
        for prot in protected_paths():
            if path == prot or path.startswith(prot.rstrip("/") + "/"):
                if path == prot:
                    raise ValueError(f"{path} is protected")
        if not os.access(path, os.W_OK):
            raise ValueError(f"not writable by this user: {path}")
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
            verb_txt = f"rm -rf {path}"
        else:
            os.unlink(path)
            verb_txt = f"rm {path}"
        return json.dumps({"ok": True, "syscall": verb_txt, "path": path}).encode()

    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed_url.query)
        if parsed_url.path == "/ssh/world":
            host = qs.get("host", [""])[0]
            body = json.dumps(remote_world(host) if host else {"error": "no host"}).encode()
            self._json(body)
        elif parsed_url.path == "/ssh/list":
            host = qs.get("host", [""])[0]
            path = qs.get("path", ["~"])[0]
            body = json.dumps(remote_list(host, path) if host else {"error": "no host"}).encode()
            self._json(body)
        elif parsed_url.path.startswith("/list"):
            try:
                path = qs.get("path", [os.path.expanduser("~")])[0]
                body = json.dumps(gather_listing(path)).encode()
            except Exception as e:
                body = json.dumps({"error": str(e)}).encode()
            self._json(body)
        elif self.path in ("/world.json", "/health"):
            body = self.blob if self.blob else b'{"error":"no snapshot yet"}'
            self._json(body)
        else:
            self.send_error(404)

    def _json(self, body: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # quiet


def main():
    threading.Thread(target=_poller, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), _Handler)
    print(f"frameshiftd: http://127.0.0.1:{PORT}/world.json every {TICK}s", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


def _poller():
    atexit.register(_kill_all_enemies)
    atexit.register(oracle_bridge.shutdown)
    tick = 0
    while True:
        t0 = time.time()
        tick += 1
        try:
            replay = sim_next()
            if replay is not None:
                # sim mode: serve the replayed frame; enemies/ssh stay frozen
                replay["sim"] = sim_state()
                _Handler.blob = json.dumps(
                    replay, separators=(",", ":")).encode()
            else:
                _tend_enemies()
                snap = gather_world(tick)
                sim_record(snap)
                snap["sim"] = sim_state()
                _Handler.blob = json.dumps(
                    snap, separators=(",", ":")).encode()
        except Exception as e:  # keep the daemon alive on transient errors
            print(f"tick error: {e}", file=sys.stderr, flush=True)
        time.sleep(max(TICK - (time.time() - t0), 0.05))


if __name__ == "__main__":
    main()
