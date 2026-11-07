"""oracle_bridge — the daemon's client side of the Kernel Oracle.

The daemon itself never runs as root. To arm the YOLO tier it spawns the
kernel-oracle binary under `sudo -S` (the player's incantation is fed to
sudo on stdin and never stored anywhere), then talks fixed verbs to the
Oracle's Unix socket. The Oracle enforces its own ritual (snapshot must
exist) and its own TTL; this module is a dumb pipe with lifecycle management.

Verbs here are forwarded verbatim; the Oracle is the authority on what is
allowed. This module only refuses obviously-malformed requests early.
"""
import json
import os
import shutil
import socket
import subprocess
import threading
import time

ORACLE_BIN = os.environ.get(
    "WOPR_ORACLE_BIN",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "oracle", "target", "release", "kernel-oracle"),
)

_state = {"proc": None, "socket": None, "armed": False, "lock": threading.Lock()}


def _sock_path() -> str:
    d = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return f"{d}/wopr-oracle-{os.getuid()}.sock"


def _oracle_call(line: str, timeout: float = 15.0) -> dict:
    """One request per connection, like the Oracle expects."""
    sp = _state["socket"] or _sock_path()
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(sp)
        s.sendall((line + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
        return json.loads(buf.decode())
    except (OSError, ValueError) as e:
        return {"ok": False, "error": f"oracle unreachable: {e}"}


def oracle_alive() -> bool:
    p = _state["proc"]
    return p is not None and p.poll() is None


def arm(incantation: str) -> dict:
    """Spend the incantation on sudo, spawn the Oracle, run its ARM ritual."""
    with _state["lock"]:
        if oracle_alive():
            return {"ok": False, "error": "oracle already armed (disarm first)"}
        binary = os.path.realpath(ORACLE_BIN)
        if not os.path.exists(binary):
            return {"ok": False, "error": f"oracle binary not built: {binary}"}
        sp = _sock_path()
        # sudo -S reads the password from stdin; it is never written to disk,
        # never logged, and dies with this process' stdin buffer.
        try:
            proc = subprocess.Popen(
                ["sudo", "-S", binary, "--socket", sp],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
            )
        except OSError as e:
            return {"ok": False, "error": f"cannot spawn sudo: {e}"}
        try:
            proc.stdin.write(incantation + "\n")
            proc.stdin.flush()
        except OSError:
            pass
        # wait for the socket to appear (sudo prompt failure kills us fast)
        deadline = time.time() + 8
        while time.time() < deadline:
            if os.path.exists(sp):
                break
            if proc.poll() is not None:
                err = (proc.stderr.read() or "").strip().splitlines()
                hint = "wrong incantation" if "password" in " ".join(err).lower() else (err[-1] if err else f"sudo exit {proc.returncode}")
                return {"ok": False, "error": f"oracle did not start: {hint}"}
            time.sleep(0.15)
        else:
            proc.kill()
            return {"ok": False, "error": "oracle did not bind its socket in time"}
        # the Oracle's own ritual: ARM requires a snapshot to exist
        res = _oracle_call("ARM")
        if not res.get("ok"):
            proc.terminate()
            _cleanup_socket()
            return res
        _state["proc"] = proc
        _state["socket"] = sp
        _state["armed"] = True
        # watchdog: if the Oracle dies (TTL is its own; crash is what we watch)
        threading.Thread(target=_watch, args=(proc,), daemon=True).start()
        return res


def _watch(proc):
    proc.wait()
    _state["armed"] = False
    _cleanup_socket()


def _cleanup_socket():
    try:
        os.unlink(_sock_path())
    except OSError:
        pass


def disarm() -> dict:
    with _state["lock"]:
        res = _oracle_call("DISARM") if oracle_alive() else {"ok": True, "result": "not armed"}
        p = _state["proc"]
        if p and p.poll() is None:
            p.terminate()
        _state["proc"] = None
        _state["armed"] = False
        _cleanup_socket()
        return res


def status() -> dict:
    if not oracle_alive():
        return {"armed": False, "running": False}
    res = _oracle_call("STATUS", timeout=3)
    return {"armed": _state["armed"], "running": True,
            "detail": res.get("result", res.get("error", ""))}


def verb(line: str) -> dict:
    """Forward a fixed verb line to the Oracle. No shell, no argv, ever."""
    if not oracle_alive():
        return {"ok": False, "error": "oracle not armed"}
    # early sanity: reject newlines/CRs so one line is exactly one verb
    if any(c in line for c in "\r\n\x00"):
        return {"ok": False, "error": "malformed verb"}
    return _oracle_call(line)


def shutdown():
    """atexit: never leave a root process behind."""
    p = _state["proc"]
    if p and p.poll() is None:
        p.terminate()
    _state["proc"] = None
    _state["armed"] = False
    _cleanup_socket()
