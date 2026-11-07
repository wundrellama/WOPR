"""Owned, bounded Hunt nests. Standard library only; never accepts artifact paths.

Writers receive an already-open file descriptor, not a pathname: erasing a nest
cannot be undone by a late writer. All deletion is relative to held directory
FDs, and all signalling uses pidfds, never a potentially reused numeric PID.
"""
import ctypes
import json
import fcntl
import os
from pathlib import Path
import re
import random
import shlex
import shutil
import signal
import socket
import struct
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

MAX_NESTS = 2
MAX_BYTES = 256 * 1024
WRITE_BYTES = 4096
WRITE_INTERVAL = .25
WRITER_TTL = 180.0
RESPAWN_DELAY = 8.0
LEASE_SECONDS = 45.0
ID_RE = re.compile(r"[0-9a-f]{32}\Z")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_WRITER = '''import os,sys,time
os.nice(19)
fd=int(sys.argv[1]); limit=int(sys.argv[2]); end=time.monotonic()+float(sys.argv[3])
while time.monotonic()<end:
    st=os.fstat(fd)
    if st.st_nlink!=1: break
    size=st.st_size
    if size<limit:
        os.pwrite(fd,(b'WOPR JUNK\\n'+b'.'*4096)[:min(4096,limit-size)],size)
    time.sleep(.25)
'''


def _open_dir(path):
    """Open absolute directories componentwise; even ancestor symlinks fail."""
    path = os.fspath(path)
    if not os.path.isabs(path) or ".." in path.split("/"):
        raise ValueError("absolute non-traversing directory required")
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.split("/"):
            if part and part != ".":
                nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def _identity(st):
    return st.st_dev, st.st_ino


def _rename_noreplace(src_fd, src, dst_fd, dst):
    """Linux atomic restore: never replace even a dangling symlink or directory.

    Fail closed if libc/kernel/filesystem lacks RENAME_NOREPLACE. An existence
    check followed by ordinary rename would reintroduce the replacement race.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                       ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(src_fd, os.fsencode(src), dst_fd, os.fsencode(dst), 1):
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), dst)


class Session:
    """One private local registry. The service below supplies its independent lease."""
    def __init__(self, base=None, *, home=None, respawn_delay=RESPAWN_DELAY,
                 writer_ttl=WRITER_TTL, max_bytes=MAX_BYTES):
        base = os.fspath(base or os.environ.get("TMPDIR") or tempfile.gettempdir())
        self.lock = threading.RLock()
        self.base = base
        self.home = os.path.abspath(os.fspath(home or Path.home()))
        # Validate HOME componentwise before creating any session state.
        home_fd = _open_dir(self.home)
        self.home_identity = _identity(os.fstat(home_fd))
        os.close(home_fd)
        self.base_fd = _open_dir(base)
        self.name = "wopr-junk-" + uuid.uuid4().hex
        os.mkdir(self.name, 0o700, dir_fd=self.base_fd)
        self.root = os.path.join(base, self.name)
        self.fd = os.open(self.name, DIR_FLAGS, dir_fd=self.base_fd)
        self.identity = _identity(os.fstat(self.fd))
        self.nests = {}
        self.cleanup_errors = []
        self.closed = False
        self.paused = False
        self.respawn_delay = max(.01, float(respawn_delay))
        self.writer_ttl = max(.05, min(WRITER_TTL, float(writer_ttl)))
        self.max_bytes = max(1, min(MAX_BYTES, int(max_bytes)))

    def _expose(self, nest):
        """Choose an existing ordinary HOME directory; never follow symlinks.

        Discovery is bounded and excludes hidden, private session and foreign
        directories. Re-open the selected path componentwise to fence renames.
        The retained FD pins cleanup to the exact original parent directory.
        """
        candidates = []
        pending = [(self.home, 0)]
        scanned = 0
        while pending and scanned < 512:
            parent, depth = pending.pop(0)
            try:
                fd = _open_dir(parent)
            except OSError:
                continue
            try:
                if parent == self.home and _identity(os.fstat(fd)) != self.home_identity:
                    raise ValueError("HOME replaced")
                with os.scandir(fd) as entries:
                    for entry in entries:
                        scanned += 1
                        if scanned > 512:
                            break
                        if entry.name.startswith((".", "wopr-junk-", "wopr-hunt-")):
                            continue
                        st = entry.stat(follow_symlinks=False)
                        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
                            continue
                        path = os.path.join(parent, entry.name)
                        candidates.append((path, _identity(st)))
                        if depth < 3:
                            pending.append((path, depth + 1))
            finally:
                os.close(fd)
        # Empty homes still permit an exposed link beside their ordinary files.
        if not candidates:
            candidates = [(self.home, self.home_identity)]
        random.shuffle(candidates)
        for parent, identity in candidates:
            pfd = None
            try:
                pfd = _open_dir(parent)
                if _identity(os.fstat(pfd)) != identity:
                    continue
                target = os.path.join(self.root, nest["name"])
                os.symlink(target, nest["name"], dir_fd=pfd)
                nest.update(parent=parent, parent_fd=pfd, target=target,
                            link_inode=_identity(os.stat(nest["name"], dir_fd=pfd,
                                                        follow_symlinks=False)))
                pfd = None  # registry owns it now
                return
            except (FileExistsError, PermissionError, FileNotFoundError, NotADirectoryError):
                continue
            finally:
                if pfd is not None:
                    os.close(pfd)
        raise ValueError("no safe writable HOME directory for junk exposure")

    def _check(self):
        if self.cleanup_errors:
            raise OSError("; ".join(self.cleanup_errors))
        if self.closed:
            raise ValueError("session closed")
        st = os.stat(self.name, dir_fd=self.base_fd, follow_symlinks=False)
        if _identity(st) != self.identity or not stat.S_ISDIR(st.st_mode):
            raise ValueError("session root replaced")

    def create(self, directory=False):
        with self.lock:
            self._check()
            if self.paused or len(self.nests) >= MAX_NESTS:
                raise ValueError("paused or nest population cap reached")
            ident = uuid.uuid4().hex
            name = "nest-" + ident + (".d" if directory else ".junk")
            if directory:
                os.mkdir(name, 0o700, dir_fd=self.fd)
                dfd = os.open(name, DIR_FLAGS, dir_fd=self.fd)
                try:
                    fd = os.open("payload.junk", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=dfd)
                finally:
                    os.close(dfd)
            else:
                fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=self.fd)
            nest = dict(id=ident, name=name, dir=bool(directory), fd=fd,
                        inode=_identity(os.stat(name, dir_fd=self.fd, follow_symlinks=False)),
                        proc=None, pidfd=None, respawns=0, due=None)
            self.nests[ident] = nest
            try:
                self._expose(nest)
                self._spawn(nest)
            except BaseException:
                self._forget(nest)
                raise
            return self._record(nest)

    def _spawn(self, nest):
        p = subprocess.Popen([sys.executable, "-c", _WRITER, str(nest["fd"]),
                              str(self.max_bytes), str(self.writer_ttl)],
                             pass_fds=(nest["fd"],), start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        try:
            pidfd = os.pidfd_open(p.pid)
        except BaseException:
            # p is still our unreaped child, so Popen's identity is safe here.
            p.kill()
            p.wait(timeout=5)
            raise
        nest["proc"] = p
        nest["pidfd"] = pidfd
        nest["due"] = None
        nest["born"] = time.monotonic()

    def signal_writer(self, ident, sig, pid=None):
        with self.lock:
            nest = self.nests[ident]
            if pid is not None and (nest["proc"] is None or nest["proc"].pid != pid):
                raise ValueError("writer identity changed")
            if nest["proc"] is not None and nest["proc"].poll() is None:
                signal.pidfd_send_signal(nest["pidfd"], sig)

    def _reap(self, nest):
        if nest["proc"] is not None and nest["proc"].poll() is not None:
            nest["proc"].wait()
            os.close(nest["pidfd"])
            nest["proc"] = nest["pidfd"] = None
            nest["due"] = time.monotonic() + self.respawn_delay

    def _record(self, nest):
        self._reap(nest)
        p = nest["proc"]
        return dict(id=nest["id"], path=os.path.join(nest["parent"], nest["name"]),
                    parent=nest["parent"], name=nest["name"], dir=nest["dir"],
                    size=os.fstat(nest["fd"]).st_size, pid=p.pid if p else 0,
                    state="dormant" if self.paused else ("active" if p else "respawning"),
                    respawns=nest["respawns"])

    def tend(self):
        with self.lock:
            self._check()
            for nest in list(self.nests.values()):
                if not self._valid(nest):
                    self._forget(nest)
                    continue
                self._reap(nest)
                if nest["proc"] and time.monotonic() - nest["born"] >= self.writer_ttl:
                    self._stop(nest)
                    nest["due"] = time.monotonic() + self.respawn_delay
                if not self.paused and nest["proc"] is None and nest["due"] is not None:
                    if time.monotonic() >= nest["due"]:
                        self._spawn(nest)
                        nest["respawns"] += 1

    def _valid(self, nest):
        try:
            pfd = _open_dir(nest["parent"])
            try:
                if _identity(os.fstat(pfd)) != _identity(os.fstat(nest["parent_fd"])):
                    return False
            finally:
                os.close(pfd)
            if not self._link_valid(nest):
                return False
            st = os.stat(nest["name"], dir_fd=self.fd, follow_symlinks=False)
            if _identity(st) != nest["inode"] or stat.S_ISLNK(st.st_mode):
                return False
            if nest["dir"]:
                dfd = os.open(nest["name"], DIR_FLAGS, dir_fd=self.fd)
                try:
                    st = os.stat("payload.junk", dir_fd=dfd, follow_symlinks=False)
                finally:
                    os.close(dfd)
            return (_identity(st) == _identity(os.fstat(nest["fd"]))
                    and stat.S_ISREG(st.st_mode) and st.st_nlink == 1)
        except OSError:
            return False

    def _link_valid(self, nest):
        try:
            st = os.stat(nest["name"], dir_fd=nest["parent_fd"], follow_symlinks=False)
            return (stat.S_ISLNK(st.st_mode) and _identity(st) == nest["link_inode"]
                    and os.readlink(nest["name"], dir_fd=nest["parent_fd"]) == nest["target"])
        except OSError:
            return False

    def _detach_link(self, nest):
        """Claim the entry atomically before inspecting or deleting it.

        Quarantine lives on the exposure filesystem, outside the backing tree.
        Only its private, held-FD namespace is checked then unlinked. A user
        replacement is restored atomically without overwriting a new occupant;
        if that fails it remains quarantined and the error names its location.
        Mode 0700 isolates other UIDs, not malicious processes with our own UID.
        """
        pfd = nest["parent_fd"]
        for _ in range(8):
            name = ".wopr-junk-cleanup-" + uuid.uuid4().hex
            try:
                os.mkdir(name, 0o700, dir_fd=pfd)
                break
            except FileExistsError:
                continue
        else:
            raise OSError("cannot allocate private exposure quarantine")
        qfd = None
        occupied = False
        try:
            qfd = os.open(name, DIR_FLAGS, dir_fd=pfd)
            try:
                os.rename(nest["name"], "entry", src_dir_fd=pfd, dst_dir_fd=qfd)
            except FileNotFoundError:
                return False
            occupied = True
            st = os.stat("entry", dir_fd=qfd, follow_symlinks=False)
            owned = (stat.S_ISLNK(st.st_mode) and _identity(st) == nest["link_inode"]
                     and os.readlink("entry", dir_fd=qfd) == nest["target"])
            if owned:
                os.unlink("entry", dir_fd=qfd)
            else:
                _rename_noreplace(qfd, "entry", pfd, nest["name"])
            occupied = False
            return owned
        except Exception as exc:
            # Resolve the held parent for diagnostics even if its path moved.
            parent = os.readlink(f"/proc/self/fd/{pfd}")
            path = os.path.join(parent, name, "entry")
            raise OSError(f"exposure cleanup failed; inspect quarantine {path}: {exc}") from exc
        finally:
            if qfd is not None:
                os.close(qfd)
            if not occupied:
                os.rmdir(name, dir_fd=pfd)  # never recursively remove quarantine

    def _forget(self, nest):
        self._stop(nest)
        exposure_error = None
        removed = False
        if "parent_fd" in nest:
            try:
                removed = self._detach_link(nest)
            except Exception as exc:
                exposure_error = exc
                self.cleanup_errors.append(str(exc))
            finally:
                os.close(nest["parent_fd"])
        try:
            st = os.stat(nest["name"], dir_fd=self.fd, follow_symlinks=False)
            if _identity(st) == nest["inode"]:
                if stat.S_ISDIR(st.st_mode):
                    shutil.rmtree(nest["name"], dir_fd=self.fd)
                else:
                    os.unlink(nest["name"], dir_fd=self.fd)
        except FileNotFoundError:
            pass
        os.close(nest["fd"])
        del self.nests[nest["id"]]
        if exposure_error is not None:
            raise exposure_error
        return removed

    def pause(self):
        with self.lock:
            self.paused = True
            for nest in self.nests.values():
                self._stop(nest)
                nest["due"] = None

    def resume(self):
        with self.lock:
            if self.paused:
                self.paused = False
                for nest in self.nests.values():
                    nest["due"] = time.monotonic() + self.respawn_delay

    def erase(self, ident):
        with self.lock:
            self._check()
            if not isinstance(ident, str) or not ID_RE.fullmatch(ident) or ident not in self.nests:
                return {"ok": False, "error": "unknown nest ID"}
            nest = self.nests[ident]
            valid = self._valid(nest)
            removed = self._forget(nest)  # always cancel and purge, never erase a replacement
            return ({"ok": True, "id": ident} if valid and removed else
                    {"ok": False, "error": "nest removed or replaced"})

    def snapshot(self):
        with self.lock:
            if self.cleanup_errors:
                raise OSError("; ".join(self.cleanup_errors))
            if self.closed:
                return []
            self._check()
            for nest in list(self.nests.values()):
                if not self._valid(nest):
                    self._forget(nest)
            return [self._record(n) for n in self.nests.values()]

    def _stop(self, nest):
        self._reap(nest)
        if nest["proc"]:
            try:
                signal.pidfd_send_signal(nest["pidfd"], signal.SIGKILL)
            except ProcessLookupError:
                pass
            nest["proc"].wait(timeout=5)
            os.close(nest["pidfd"])
            nest["proc"] = nest["pidfd"] = None

    def close(self):
        with self.lock:
            if self.closed:
                if self.cleanup_errors:
                    raise OSError("; ".join(self.cleanup_errors))
                return
            for nest in list(self.nests.values()):
                try:
                    self._forget(nest)
                except Exception as exc:
                    if str(exc) not in self.cleanup_errors:
                        self.cleanup_errors.append(str(exc))
            try:
                if not self.cleanup_errors:
                    self._check()
                    shutil.rmtree(self.name, dir_fd=self.base_fd)
                # Retain the empty private root as a failure marker. Without
                # it an unreachable helper's close fallback could invent ACK.
            finally:
                self.closed = True
                os.close(self.fd)
                os.close(self.base_fd)
            if self.cleanup_errors:
                raise OSError("; ".join(self.cleanup_errors))


# A supervisor is independent of the SSH connection and daemon. It owns all
# writers and enforces TTLs/lease expiry even when a writer is SIGSTOPped.
# RPC uses an owner-only Unix socket reached through a held directory FD.
_BOOT = "import sys;exec(compile(sys.argv[1],'<wopr-junk>','exec'))"


def _source():
    return Path(__file__).read_text()


def _spawn_service(source, request):
    argv = [sys.executable, "-c", _BOOT, source, json.dumps(request)]
    # Only called inside the single-threaded command subprocess, never inside
    # the multithreaded daemon. Some embedded Pythons lack spawn(SETSID).
    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            for fd in (0, 1, 2):
                null = os.open(os.devnull, os.O_RDONLY if fd == 0 else os.O_WRONLY)
                os.dup2(null, fd)
                if null != fd:
                    os.close(null)
            os.execv(sys.executable, argv)
        finally:
            os._exit(127)
    return pid


def _read_message(sock):
    data = bytearray()
    while len(data) <= 65536:
        chunk = sock.recv(4096)
        if not chunk:
            raise ValueError("incomplete helper response")
        data.extend(chunk)
        if b"\n" in chunk:
            return json.loads(bytes(data).split(b"\n", 1)[0])
    raise ValueError("helper message too large")


def _rpc(fd, request):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5)
        sock.connect(f"/proc/self/fd/{fd}/control.sock")
        sock.sendall(json.dumps(request).encode() + b"\n")
        return _read_message(sock)


def _control(request, create=False):
    token = request["token"]
    if not isinstance(token, str) or not ID_RE.fullmatch(token):
        raise ValueError("bad session token")
    base = request.get("base") or os.environ.get("TMPDIR") or tempfile.gettempdir()
    bfd = _open_dir(base)
    name = "wopr-hunt-" + token
    try:
        if create:
            try:
                os.mkdir(name, 0o700, dir_fd=bfd)
            except FileExistsError:
                pass
        fd = os.open(name, DIR_FLAGS, dir_fd=bfd)
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            os.close(fd)
            raise ValueError("control directory is not private and owned")
        return base, name, bfd, fd
    except BaseException:
        os.close(bfd)
        raise


def _mark_revoked(fd):
    marker = os.open("revoked", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW,
                     0o600, dir_fd=fd)
    os.close(marker)


def _revoked(fd):
    try:
        os.stat("revoked", dir_fd=fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _retire_control(request, bfd, fd, name):
    # Retain an empty tombstone until the only authorized bootstrap deadline.
    # Thus a slow/disconnected SSH start cannot resurrect an opted-out session.
    time.sleep(max(0, request["deadline"] - time.time()) + .1)
    try:
        st = os.stat(name, dir_fd=bfd, follow_symlinks=False)
        if _identity(st) == _identity(os.fstat(fd)) and stat.S_ISDIR(st.st_mode):
            shutil.rmtree(name, dir_fd=bfd)
    except FileNotFoundError:
        pass


def _serve(source, request, reaper=False):
    base, name, bfd, fd = _control(request)
    engine = None
    try:
        if reaper:
            _retire_control(request, bfd, fd, name)
            return
        if _revoked(fd) or time.time() >= request["deadline"]:
            _mark_revoked(fd)
            _retire_control(request, bfd, fd, name)
            return
        engine = Session(os.path.join(base, name), **request.get("options", {}))
        lease = max(.1, min(LEASE_SECONDS, float(request.get("lease", LEASE_SECONDS))))
        expires = time.monotonic() + lease
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(f"/proc/self/fd/{fd}/control.sock")
            os.chmod("control.sock", 0o600, dir_fd=fd)
            listener.listen(4)
            listener.settimeout(.05)
            done = False
            while not done and time.monotonic() < expires:
                engine.tend()
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(2)
                    response = None
                    try:
                        _, uid, _ = struct.unpack("3i", conn.getsockopt(
                            socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                        req = _read_message(conn)
                        if uid != os.getuid() or req.get("token") != request["token"]:
                            raise ValueError("helper authentication failed")
                        op = req.get("op")
                        if op == "close":
                            _mark_revoked(fd)
                            engine.close()
                            done = True
                        elif op == "tick":
                            expires = time.monotonic() + lease
                            if req.get("create"):
                                engine.create(bool(req.get("directory")))
                        elif op == "pause":
                            engine.pause()
                        elif op == "resume":
                            engine.resume()
                        elif op == "erase":
                            response = engine.erase(req.get("id"))
                        elif op == "signal":
                            sig = req.get("sig")
                            if sig not in (signal.SIGSTOP, signal.SIGCONT, signal.SIGKILL):
                                raise ValueError("invalid writer signal")
                            engine.signal_writer(req.get("id"), sig, pid=req.get("pid"))
                        elif op != "snapshot":
                            raise ValueError("unknown helper operation")
                        if response is None:
                            response = {"ok": True}
                        response["junk"] = engine.snapshot()
                    except Exception as exc:
                        response = {"ok": False, "error": str(exc)}
                    try:
                        conn.sendall(json.dumps(response).encode() + b"\n")
                    except OSError:
                        pass  # lost RPC cannot cancel independent cleanup/expiry
    finally:
        try:
            try:
                if engine is not None:
                    engine.close()
            finally:
                _mark_revoked(fd)  # failed cleanup must fence another bootstrap too
            _retire_control(request, bfd, fd, name)
        finally:
            os.close(fd)
            os.close(bfd)


def _endpoint(source, request):
    op = request.get("op")
    if op == "start" and time.time() >= request["deadline"]:
        return {"ok": False, "error": "bootstrap expired"}
    try:
        base, name, bfd, fd = _control(request, create=op in ("start", "close"))
    except FileNotFoundError:
        if op == "close":
            return {"ok": True, "junk": []}
        return {"ok": False, "error": "helper expired or missing"}
    lockfd = None
    try:
        lockfd = os.open("lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
                         0o600, dir_fd=fd)
        fcntl.flock(lockfd, fcntl.LOCK_EX)
        if op == "start":
            if _revoked(fd):
                return {"ok": False, "error": "session revoked"}
            try:
                return _rpc(fd, dict(request, op="snapshot"))
            except (FileNotFoundError, ConnectionRefusedError):
                child = _spawn_service(source, dict(request, op="serve"))
                end = min(request["deadline"], time.time() + 4)
                while time.time() < end:
                    try:
                        return _rpc(fd, dict(request, op="snapshot"))
                    except (FileNotFoundError, ConnectionRefusedError):
                        # Reap a failed bootstrap child rather than looping blindly.
                        if os.waitpid(child, os.WNOHANG)[0]:
                            raise RuntimeError("supervisor failed to start")
                        time.sleep(.01)
                _mark_revoked(fd)
                raise TimeoutError("supervisor bootstrap timed out")
        if op == "close":
            _mark_revoked(fd)
            try:
                return _rpc(fd, request)
            except (FileNotFoundError, ConnectionRefusedError):
                # No server: fence any late bootstrap and independently retire.
                contents = os.listdir(fd)
                if any(n.startswith("wopr-junk-") for n in contents):
                    return {"ok": False, "error": "supervisor unreachable; lease cleanup pending"}
                _spawn_service(source, dict(request, op="reap"))
                return {"ok": True, "junk": []}
        if _revoked(fd):
            return {"ok": False, "error": "session revoked"}
        return _rpc(fd, request)
    finally:
        if lockfd is not None:
            os.close(lockfd)
        os.close(fd)
        os.close(bfd)


class Helper:
    """Lazy, bounded local/remote supervisor client; executor never defaults to SSH.

    A remote executor accepts (fixed_shell_command, timeout) and returns
    (returncode, stdout, stderr). The daemon alone selects an allowed host alias.
    """
    def __init__(self, *, base=None, executor=None, lease=LEASE_SECONDS,
                 boot_window=12.0, options=None):
        self.token = uuid.uuid4().hex
        self.request = dict(token=self.token, base=base, lease=lease,
                            deadline=time.time() + min(12, max(.1, boot_window)),
                            options=options or {})
        self.executor = executor
        self.source = _source()
        self.lock = threading.RLock()
        self.closed = False
        self.cache = []
        self.close_result = None

    def command(self, op, **kwargs):
        req = dict(self.request, op=op, **kwargs)
        return " ".join(shlex.quote(s) for s in
                        ["python3", "-c", _BOOT, self.source, json.dumps(req)])

    def _call(self, op, **kwargs):
        with self.lock:
            if self.closed and op != "close":
                return {"ok": False, "error": "helper closed"}
            try:
                if self.executor:
                    rc, out, err = self.executor(self.command(op, **kwargs), 8)
                else:
                    result = subprocess.run([sys.executable, "-c", _BOOT, self.source,
                                             json.dumps(dict(self.request, op=op, **kwargs))],
                                            capture_output=True, text=True, timeout=8)
                    rc, out, err = result.returncode, result.stdout, result.stderr
                if rc:
                    raise RuntimeError(err.strip() or f"helper exit {rc}")
                response = json.loads(out)
                if not isinstance(response, dict) or type(response.get("ok")) is not bool:
                    raise ValueError("unacknowledged helper response")
                if response["ok"]:
                    if not isinstance(response.get("junk"), list):
                        raise ValueError("missing helper snapshot")
                    if op == "erase" and (response.get("id") != kwargs.get("id") or any(
                            n.get("id") == kwargs.get("id") for n in response["junk"])):
                        raise ValueError("erase not acknowledged")
                    self.cache = response["junk"]
                return response
            except subprocess.TimeoutExpired:
                return {"ok": False, "error": "helper transport timed out"}
            except subprocess.CalledProcessError as exc:
                return {"ok": False, "error": f"helper transport failed (exit {exc.returncode})"}
            except Exception as exc:
                message = str(exc)
                if len(message) > 256:
                    message = f"{type(exc).__name__}: oversized transport details omitted"
                return {"ok": False, "error": message}

    def start(self):
        return self._call("start")

    def tick(self, *, create=False, directory=False):
        return self._call("tick", create=create, directory=directory)

    def snapshot(self):
        return self._call("snapshot")

    def pause(self):
        return self._call("pause")

    def resume(self):
        return self._call("resume")

    def erase(self, ident):
        return self._call("erase", id=ident)

    def signal_writer(self, ident, sig, pid=None):
        return self._call("signal", id=ident, sig=int(sig), pid=pid)

    def close(self):
        with self.lock:
            if self.closed and self.close_result and self.close_result["ok"]:
                return self.close_result
            result = self._call("close")
            self.closed = True
            self.close_result = result
            if result["ok"]:
                self.cache = []
            return result


if __name__ == "__main__":
    try:
        _src, _req = sys.argv[1], json.loads(sys.argv[2])
        if _req.get("op") in ("serve", "reap"):
            _serve(_src, _req, reaper=_req["op"] == "reap")
        else:
            print(json.dumps(_endpoint(_src, _req)), flush=True)
    except Exception as _exc:
        print(json.dumps({"ok": False, "error": str(_exc)}), flush=True)
