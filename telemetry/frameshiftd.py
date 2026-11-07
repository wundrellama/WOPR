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
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import psutil
except ImportError:
    sys.exit("frameshiftd requires psutil: pip install psutil")

PORT = int(os.environ.get("FRAMESHIFT_PORT", "8765"))
TICK = float(os.environ.get("FRAMESHIFT_TICK", "1.0"))

_prev_disk = {"t": None, "read": 0, "write": 0}


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
            verb, pid, sig = req.get("verb"), int(req.get("pid", -1)), int(req.get("sig", 0))
            if verb != "kill" or sig not in (19, 18, 9):
                raise ValueError("verb must be 'kill', sig must be 19/18/9")
            if pid in self._protected():
                raise ValueError(f"pid {pid} is protected")
            os.kill(pid, sig)
            body = json.dumps({"ok": True, "syscall": f"kill({pid}, {sig})"}).encode()
        except Exception as e:
            body = json.dumps({"ok": False, "error": str(e)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/world.json", "/health"):
            body = self.blob if self.blob else b'{"error":"no snapshot yet"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

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
    tick = 0
    while True:
        t0 = time.time()
        tick += 1
        try:
            _Handler.blob = json.dumps(
                gather_world(tick), separators=(",", ":")
            ).encode()
        except Exception as e:  # keep the daemon alive on transient errors
            print(f"tick error: {e}", file=sys.stderr, flush=True)
        time.sleep(max(TICK - (time.time() - t0), 0.05))


if __name__ == "__main__":
    main()
