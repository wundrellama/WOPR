"""Scratch-only Hunt tests. Never run the game, configured SSH, or Oracle."""
import importlib
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def eventually(check, timeout=4):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(.02)
    raise AssertionError("condition not reached")


class NestTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="junk-test-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.fixture.cleanup)

    def session(self, **kwargs):
        module = importlib.import_module("junk_hunt")
        # Every exposed HOME is a disposable fixture, never the real user's HOME.
        kwargs.setdefault("home", self.fixture.name)
        session = module.Session(self.fixture.name, **kwargs)
        self.addCleanup(session.close)
        return session

    def test_exposure_is_symlink_among_existing_home_files_not_private_payload(self):
        home = Path(self.fixture.name) / "home"
        ordinary = home / "Documents"
        ordinary.mkdir(parents=True)
        neighbor = ordinary / "keep.txt"
        neighbor.write_text("user data")
        s = self.session(home=str(home))
        record = s.create(True)
        link = Path(record["path"])
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.parent, ordinary)
        self.assertEqual(record["parent"], str(ordinary))
        self.assertTrue(record["dir"])
        payload = link.resolve()
        self.assertEqual(payload.parent, Path(s.root))
        link.unlink()
        s.tend()
        self.assertEqual(s.snapshot(), [])
        self.assertFalse(payload.exists(), "link removal must purge the respawn source")
        s.close()
        self.assertEqual(neighbor.read_text(), "user data")

    def test_exposure_skips_hidden_symlink_and_private_directories(self):
        home = Path(self.fixture.name) / "home"
        ordinary = home / "Documents"
        ordinary.mkdir(parents=True)
        (home / ".hidden").mkdir()
        (home / "wopr-hunt-foreign").mkdir()
        outside = Path(self.fixture.name) / "outside"
        outside.mkdir()
        (home / "shortcut").symlink_to(outside, target_is_directory=True)
        s = self.session(home=str(home))
        records = [s.create(), s.create(True)]
        self.assertTrue(all(Path(n["parent"]) == ordinary for n in records))
        self.assertEqual(list(outside.iterdir()), [])
        s.close()
        self.assertEqual(list(ordinary.iterdir()), [])

    def test_recreated_same_target_link_is_a_user_replacement(self):
        s = self.session()
        record = s.create()
        link = Path(record["path"])
        target = os.readlink(link)
        link.unlink()
        link.symlink_to(target)
        result = s.erase(record["id"])
        self.assertFalse(result["ok"], result)
        self.assertTrue(link.is_symlink(), "even a same-target replacement belongs to the user")
        s.close()
        self.assertTrue(link.is_symlink())

    def test_replacement_at_cleanup_syscall_survives_after_link_validation(self):
        s = self.session()
        record = s.create()
        nest = s.nests[record["id"]]
        link = Path(record["path"])
        staged = link.with_name("user-staged")
        staged.write_text("user replacement")
        payload = Path(s.root) / record["name"]
        proc = nest["proc"]
        real_unlink, real_rename = os.unlink, os.rename
        swapped = []

        def replace_at_boundary(name, kwargs):
            if (name == record["name"] and
                    kwargs.get("src_dir_fd", kwargs.get("dir_fd")) == nest["parent_fd"] and
                    not swapped):
                os.replace(staged, link)
                swapped.append(True)

        def unlink(name, **kwargs):
            replace_at_boundary(name, kwargs)
            return real_unlink(name, **kwargs)

        def rename(src, dst, **kwargs):
            replace_at_boundary(src, kwargs)
            return real_rename(src, dst, **kwargs)

        with patch("junk_hunt.os.unlink", side_effect=unlink), \
                patch("junk_hunt.os.rename", side_effect=rename):
            result = s.erase(record["id"])
        self.assertEqual(swapped, [True], "must replace at the cleanup syscall boundary")
        self.assertTrue(link.is_file(), "cleanup deleted a post-validation user replacement")
        self.assertEqual(link.read_text(), "user replacement")
        self.assertFalse(result["ok"], "a raced erase is not acknowledged")
        self.assertIsNotNone(proc.poll())
        self.assertFalse(payload.exists())
        self.assertEqual(s.snapshot(), [])

    def test_blocked_restore_preserves_quarantine_and_close_failure_is_sticky(self):
        module = importlib.import_module("junk_hunt")
        s = module.Session(self.fixture.name, home=self.fixture.name)
        try:
            record = s.create()
            other = s.create(True)
            procs = [n["proc"] for n in s.nests.values()]
            nest = s.nests[record["id"]]
            link = Path(record["path"])
            staged = link.with_name("staged-directory")
            staged.mkdir()
            (staged / "keep").write_text("quarantined user data")
            link.unlink()
            staged.rename(link)
            real_restore = module._rename_noreplace
            quarantines = []

            def blocked_restore(src_fd, src, dst_fd, dst):
                quarantines.append(Path(os.readlink(f"/proc/self/fd/{src_fd}")))
                link.write_text("new occupant")
                return real_restore(src_fd, src, dst_fd, dst)

            with patch("junk_hunt._rename_noreplace", side_effect=blocked_restore):
                with self.assertRaisesRegex(OSError, "quarantine") as failure:
                    s.erase(record["id"])
            self.assertEqual(link.read_text(), "new occupant")
            self.assertEqual((quarantines[0] / "entry/keep").read_text(),
                             "quarantined user data")
            self.assertIn(str(quarantines[0] / "entry"), str(failure.exception))
            self.assertEqual(quarantines[0].stat().st_mode & 0o777, 0o700)
            self.assertNotIn(record["id"], s.nests)
            self.assertFalse((Path(s.root) / record["name"]).exists())
            with self.assertRaisesRegex(OSError, "quarantine"):
                s.close()
            self.assertTrue(s.closed)
            self.assertTrue(all(p.poll() is not None for p in procs))
            self.assertFalse(Path(other["path"]).exists())
            self.assertEqual(list(Path(s.root).iterdir()), [], "only an empty failure marker remains")
            with self.assertRaisesRegex(OSError, "quarantine"):
                s.close()
            self.assertEqual((quarantines[0] / "entry/keep").read_text(),
                             "quarantined user data")
        finally:
            if not s.closed:
                s.close()

    def test_detach_restores_directory_and_symlink_replacements(self):
        for directory in (False, True):
            for kind in ("directory", "same-target-symlink", "foreign-symlink"):
                with self.subTest(backing_directory=directory, replacement=kind):
                    s = self.session()
                    record = s.create(directory)
                    nest = s.nests[record["id"]]
                    pfd = nest["parent_fd"]
                    link = Path(record["path"])
                    staged = link.with_name("stage-" + record["id"])
                    if kind == "directory":
                        staged.mkdir()
                        (staged / "keep").write_text("user data")
                    else:
                        staged.symlink_to(nest["target"] if kind == "same-target-symlink"
                                          else "user-dangling-target")
                    identity = staged.lstat().st_ino
                    real_rename = os.rename
                    detached = []

                    def race(src, dst, **kwargs):
                        if src == record["name"] and kwargs.get("src_dir_fd") == pfd:
                            link.unlink()
                            real_rename(staged, link)
                            qfd = kwargs["dst_dir_fd"]
                            self.assertEqual(os.fstat(qfd).st_mode & 0o777, 0o700)
                            self.assertEqual(os.fstat(qfd).st_dev, os.fstat(pfd).st_dev)
                            detached.append(True)
                        return real_rename(src, dst, **kwargs)

                    with patch("junk_hunt.os.rename", side_effect=race):
                        result = s.erase(record["id"])
                    self.assertEqual(detached, [True])
                    self.assertFalse(result["ok"])
                    self.assertEqual(link.lstat().st_ino, identity)
                    if kind == "directory":
                        self.assertEqual((link / "keep").read_text(), "user data")
                    else:
                        self.assertEqual(os.readlink(link), nest["target"] if
                                         kind == "same-target-symlink" else "user-dangling-target")
                    self.assertEqual(list(link.parent.glob(".wopr-junk-cleanup-*")), [])
                    s.close()
                    self.assertEqual(link.lstat().st_ino, identity)

    def test_owned_detach_never_unlinks_new_original_name_occupant(self):
        s = self.session()
        record = s.create()
        nest = s.nests[record["id"]]
        pfd = nest["parent_fd"]
        link = Path(record["path"])
        real_unlink = os.unlink
        isolated = []

        def race(name, **kwargs):
            self.assertFalse(name == record["name"] and kwargs.get("dir_fd") == pfd,
                             "automatic cleanup must never unlink the exposed pathname")
            if name == "entry":
                self.assertNotEqual(kwargs["dir_fd"], pfd)
                self.assertFalse(os.path.lexists(link), "validation must happen after detach")
                link.write_text("new user occupant")
                isolated.append(True)
            return real_unlink(name, **kwargs)

        with patch("junk_hunt.os.unlink", side_effect=race):
            self.assertTrue(s.erase(record["id"])["ok"])
        self.assertEqual(isolated, [True])
        self.assertEqual(link.read_text(), "new user occupant")
        s.close()
        self.assertEqual(link.read_text(), "new user occupant")

    def test_vanished_at_detach_is_not_acknowledged(self):
        s = self.session()
        record = s.create()
        link = Path(record["path"])
        real_rename = os.rename

        def vanish(src, dst, **kwargs):
            if src == record["name"]:
                link.unlink()
            return real_rename(src, dst, **kwargs)

        with patch("junk_hunt.os.rename", side_effect=vanish):
            self.assertFalse(s.erase(record["id"])["ok"])
        self.assertEqual(s.snapshot(), [])
        self.assertEqual(list(link.parent.glob(".wopr-junk-cleanup-*")), [])

    def test_quarantine_name_collision_is_retried_without_touching_neighbor(self):
        from types import SimpleNamespace
        import uuid
        s = self.session()
        record = s.create()
        parent = Path(record["parent"])
        collision = parent / (".wopr-junk-cleanup-" + "a" * 32)
        collision.mkdir()
        (collision / "keep").write_text("existing user directory")
        with patch("junk_hunt.uuid.uuid4", side_effect=[SimpleNamespace(hex="a" * 32), uuid.uuid4()]):
            self.assertTrue(s.erase(record["id"])["ok"])
        s.close()
        self.assertEqual((collision / "keep").read_text(), "existing user directory")

    def test_detach_failure_during_close_still_purges_all_backing_and_writers(self):
        module = importlib.import_module("junk_hunt")
        s = module.Session(self.fixture.name, home=self.fixture.name)
        try:
            records = [s.create(), s.create(True)]
            procs = [n["proc"] for n in s.nests.values()]
            fds = [n[key] for n in s.nests.values() for key in ("fd", "parent_fd", "pidfd")]
            with patch("junk_hunt.os.rename", side_effect=PermissionError("fixture detach denied")):
                with self.assertRaisesRegex(OSError, "fixture detach denied"):
                    s.close()
            self.assertTrue(s.closed)
            self.assertTrue(all(p.poll() is not None for p in procs))
            self.assertEqual(s.nests, {})
            self.assertEqual(list(Path(s.root).iterdir()), [])
            self.assertTrue(all(Path(n["path"]).is_symlink() for n in records))
            self.assertEqual(list(Path(self.fixture.name).glob(".wopr-junk-cleanup-*")), [])
            for fd in fds:
                with self.assertRaises(OSError):
                    os.fstat(fd)
            with self.assertRaisesRegex(OSError, "fixture detach denied"):
                s.close()
        finally:
            if not s.closed:
                s.close()

    def test_noreplace_preserves_every_kind_of_destination(self):
        module = importlib.import_module("junk_hunt")
        parent = Path(self.fixture.name)
        fd = module._open_dir(parent)
        try:
            source = parent / "source"
            source.write_text("preserved source")
            for kind in ("file", "directory", "dangling-symlink"):
                destination = parent / kind
                if kind == "file":
                    destination.write_text("user destination")
                elif kind == "directory":
                    destination.mkdir()
                    (destination / "keep").write_text("user destination")
                else:
                    destination.symlink_to("does-not-exist")
                inode = destination.lstat().st_ino
                with self.assertRaises(FileExistsError):
                    module._rename_noreplace(fd, "source", fd, kind)
                self.assertEqual(destination.lstat().st_ino, inode)
                self.assertEqual(source.read_text(), "preserved source")
            module._rename_noreplace(fd, "source", fd, "empty-destination")
            self.assertFalse(source.exists())
            self.assertEqual((parent / "empty-destination").read_text(), "preserved source")
        finally:
            os.close(fd)

    def test_exposed_name_collision_never_overwrites_neighbor(self):
        from types import SimpleNamespace
        s = self.session()
        name = "nest-" + "a" * 32 + ".junk"
        neighbor = Path(self.fixture.name) / name
        neighbor.write_text("user data")
        with patch("junk_hunt.uuid.uuid4", return_value=SimpleNamespace(hex="a" * 32)):
            with self.assertRaises(ValueError):
                s.create()
        self.assertEqual(s.snapshot(), [])
        self.assertEqual(list(Path(s.root).iterdir()), [])
        s.close()
        self.assertEqual(neighbor.read_text(), "user data")

    def test_parent_replacement_does_not_redirect_cleanup(self):
        home = Path(self.fixture.name) / "home"
        ordinary = home / "Documents"
        ordinary.mkdir(parents=True)
        s = self.session(home=str(home))
        record = s.create(True)
        payload = Path(record["path"]).resolve()
        moved = home / "Documents-moved"
        ordinary.rename(moved)
        ordinary.mkdir()
        replacement = ordinary / record["name"]
        replacement.write_text("user replacement")
        s.tend()
        self.assertEqual(s.snapshot(), [])
        self.assertFalse(payload.exists())
        self.assertFalse((moved / record["name"]).is_symlink())
        s.close()
        self.assertEqual(replacement.read_text(), "user replacement")

    def test_real_file_persists_after_owned_writer_dies(self):
        s = self.session()
        record = s.create(False)
        path = Path(record["path"])
        eventually(lambda: path.stat().st_size > 0)
        s.signal_writer(record["id"], signal.SIGKILL)
        eventually(lambda: s.snapshot()[0]["pid"] == 0)
        self.assertTrue(path.is_file())
        self.assertEqual(s.snapshot()[0]["id"], record["id"])
        self.assertEqual(s.snapshot()[0]["state"], "respawning")
        self.assertGreater(s.snapshot()[0]["size"], 0)

    def test_directory_respawns_same_identity_until_confirmed_erase(self):
        s = self.session(respawn_delay=.04, writer_ttl=.15)
        first = s.create(True)
        eventually(lambda: s.snapshot()[0]["pid"] == 0)
        time.sleep(.06)
        s.tend()
        second = s.snapshot()[0]
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(second["respawns"], 1)
        self.assertNotEqual(second["pid"], first["pid"])
        self.assertTrue(s.erase(first["id"])["ok"])
        time.sleep(.06)
        s.tend()
        self.assertEqual(s.snapshot(), [])
        self.assertFalse(Path(first["path"]).exists())

    def test_pause_stops_writing_without_polling_and_resume_is_explicit(self):
        s = self.session(respawn_delay=.01)
        record = s.create()
        eventually(lambda: Path(record["path"]).stat().st_size > 0)
        s.pause()
        size = Path(record["path"]).stat().st_size
        time.sleep(.3)
        self.assertEqual(Path(record["path"]).stat().st_size, size)
        self.assertEqual(s.snapshot()[0]["state"], "dormant")
        with self.assertRaises(ValueError):
            s.create()
        s.tend()
        self.assertEqual(s.snapshot()[0]["pid"], 0)
        s.resume()
        time.sleep(.02)
        s.tend()
        self.assertGreater(s.snapshot()[0]["pid"], 0)

    def test_population_byte_bounds_and_cleanup_is_idempotent(self):
        s = self.session(max_bytes=8192)
        records = [s.create(), s.create(True)]
        with self.assertRaises(ValueError):
            s.create()
        eventually(lambda: all(n["size"] == 8192 for n in s.snapshot()))
        time.sleep(.3)
        self.assertEqual(sum(n["size"] for n in s.snapshot()), 16384)
        s.close()
        s.close()
        self.assertFalse(Path(s.root).exists())
        self.assertTrue(all(not Path(n["path"]).exists() for n in records))

    def test_external_removal_cancels_respawn_instead_of_recreating(self):
        s = self.session(respawn_delay=.01)
        record = s.create()
        Path(record["path"]).unlink()
        s.tend()
        self.assertEqual(s.snapshot(), [])
        time.sleep(.03)
        s.tend()
        self.assertFalse(Path(record["path"]).exists())

    def test_symlink_replacement_never_writes_or_erases_target(self):
        s = self.session(respawn_delay=.01)
        record = s.create(True)
        target = Path(self.fixture.name) / "unrelated"
        target.mkdir()
        sentinel = target / "keep"
        sentinel.write_text("untouched")
        Path(record["path"]).unlink()
        Path(record["path"]).symlink_to(target, target_is_directory=True)
        s.tend()
        self.assertEqual(s.snapshot(), [])
        s.close()
        self.assertEqual(sentinel.read_text(), "untouched")

    def test_id_traversal_and_competing_session_are_rejected(self):
        a, b = self.session(), self.session()
        record = b.create()
        for ident in (record["id"], "../", record["path"], None):
            self.assertFalse(a.erase(ident)["ok"])
        a.close()
        self.assertTrue(Path(record["path"]).exists())

    def test_symlink_ancestor_and_root_replacement_fail_closed(self):
        module = importlib.import_module("junk_hunt")
        link = Path(self.fixture.name) / "alias"
        link.symlink_to(self.fixture.name, target_is_directory=True)
        with self.assertRaises(OSError):
            module.Session(str(link))
        s = self.session()
        original = Path(s.root)
        moved = original.with_name(original.name + "-moved")
        original.rename(moved)
        original.symlink_to(self.fixture.name, target_is_directory=True)
        try:
            with self.assertRaises(ValueError):
                s.create()
        finally:
            original.unlink()
            moved.rename(original)

    def test_frozen_writer_ttl_uses_owned_pidfd_not_raw_pid(self):
        s = self.session(writer_ttl=.08)
        record = s.create()
        s.signal_writer(record["id"], signal.SIGSTOP)
        time.sleep(.1)
        from unittest.mock import patch
        with patch("os.kill", side_effect=AssertionError("raw PID signal")):
            s.tend()
            self.assertEqual(s.snapshot()[0]["pid"], 0)

    def test_small_byte_cap_and_nice_priority(self):
        s = self.session(max_bytes=1)
        record = s.create()
        eventually(lambda: Path(record["path"]).stat().st_size > 0)
        self.assertEqual(s.snapshot()[0]["size"], 1)
        self.assertEqual(os.getpriority(os.PRIO_PROCESS, record["pid"]), 19)

    def test_pidfd_failure_does_not_leave_an_untracked_writer(self):
        s = self.session()
        with patch("os.pidfd_open", side_effect=OSError("fixture pidfd failure")):
            with self.assertRaises(OSError):
                s.create()
        self.assertEqual(s.snapshot(), [])

    def test_stale_pid_cannot_signal_the_new_writer(self):
        s = self.session(respawn_delay=.01)
        record = s.create()
        with self.assertRaises(ValueError):
            s.signal_writer(record["id"], signal.SIGKILL, pid=record["pid"] + 1)
        self.assertEqual(s.snapshot()[0]["pid"], record["pid"])

    def test_erase_serializes_with_inflight_producer(self):
        import threading
        s = self.session(respawn_delay=.01)
        record = s.create()
        s.signal_writer(record["id"], signal.SIGKILL)
        eventually(lambda: s.snapshot()[0]["pid"] == 0)
        time.sleep(.02)
        entered, release = threading.Event(), threading.Event()
        spawn = s._spawn

        def slow(nest):
            entered.set()
            self.assertTrue(release.wait(2))
            spawn(nest)

        results = []
        with patch.object(s, "_spawn", slow):
            tending = threading.Thread(target=s.tend)
            tending.start()
            self.assertTrue(entered.wait(2))
            erasing = threading.Thread(target=lambda: results.append(s.erase(record["id"])))
            erasing.start()
            release.set()
            tending.join(2)
            erasing.join(2)
        self.assertEqual(results, [{"ok": True, "id": record["id"]}])
        self.assertFalse(Path(record["path"]).exists())
        self.assertEqual(s.snapshot(), [])


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="junk-rpc-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.fixture.cleanup)
        self.module = importlib.import_module("junk_hunt")

    def helper(self, **kwargs):
        options = dict(kwargs.pop("options", {}), home=self.fixture.name)
        helper = self.module.Helper(base=self.fixture.name, boot_window=.5, options=options, **kwargs)
        self.addCleanup(helper.close)
        return helper

    def test_independent_expiry_removes_junk_and_frozen_owned_writer(self):
        helper = self.helper(lease=.3)
        result = helper.start()
        self.assertTrue(result["ok"], result)
        record = helper.tick(create=True)["junk"][0]
        self.assertTrue(Path(record["path"]).is_file())
        self.assertTrue(helper.signal_writer(record["id"], signal.SIGSTOP)["ok"])
        eventually(lambda: not Path(record["path"]).exists())
        self.assertFalse(helper.tick()["ok"])

    def test_remote_quoted_payload_runs_in_disposable_local_executor(self):
        import subprocess
        calls = []

        def fixture_executor(command, timeout):
            calls.append(command)
            p = subprocess.run(["/bin/sh", "-c", command], capture_output=True,
                               text=True, timeout=timeout)
            return p.returncode, p.stdout, p.stderr

        helper = self.helper(executor=fixture_executor, lease=2)
        result = helper.start()
        self.assertTrue(result["ok"], result)
        record = helper.tick(create=True, directory=True)["junk"][0]
        eventually(lambda: (Path(record["path"]) / "payload.junk").stat().st_size > 0)
        self.assertTrue(helper.erase(record["id"])["ok"])
        self.assertEqual(helper.tick()["junk"], [])
        result = helper.close()
        self.assertTrue(result["ok"], result)
        self.assertGreaterEqual(len(calls), 4)
        self.assertFalse(Path(record["path"]).exists())

    def test_close_before_delayed_start_fences_the_late_producer(self):
        helper = self.helper(lease=.5)
        late_start = helper.command("start")
        result = helper.close()
        self.assertTrue(result["ok"], result)
        import subprocess
        result = subprocess.run(["/bin/sh", "-c", late_start], capture_output=True,
                                text=True, timeout=4)
        import json
        self.assertFalse(json.loads(result.stdout)["ok"])
        eventually(lambda: not list(Path(self.fixture.name).glob("wopr-hunt-*")))

    def test_helper_quarantine_error_never_becomes_ack_after_supervisor_exit(self):
        helper = self.helper(lease=2)
        # Instrument the actual standalone supervisor, not its JSON responses.
        marker = 'if __name__ == "__main__":'
        instrument = '''
_fixture_detach = Session._detach_link
_fixture_restore = _rename_noreplace

def _fixture_race(self, nest):
    pfd = nest["parent_fd"]
    os.unlink(nest["name"], dir_fd=pfd)
    fd = os.open(nest["name"], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=pfd)
    os.write(fd, b"preserved user replacement")
    os.close(fd)
    return _fixture_detach(self, nest)

def _rename_noreplace(src_fd, src, dst_fd, dst):
    os.symlink("new-user-occupant", dst, dir_fd=dst_fd)
    return _fixture_restore(src_fd, src, dst_fd, dst)

Session._detach_link = _fixture_race
'''
        helper.source = helper.source.replace(marker, instrument + "\n" + marker)
        self.assertTrue(helper.start()["ok"])
        record = helper.tick(create=True)["junk"][0]
        result = helper.erase(record["id"])
        self.assertFalse(result["ok"], result)
        self.assertIn("quarantine", result["error"])
        quarantines = list(Path(self.fixture.name).glob(".wopr-junk-cleanup-*/entry"))
        self.assertEqual(len(quarantines), 1)
        self.assertEqual(quarantines[0].read_text(), "preserved user replacement")
        self.assertEqual(os.readlink(record["path"]), "new-user-occupant")
        control = Path(self.fixture.name) / ("wopr-hunt-" + helper.token)
        eventually(lambda: (control / "revoked").exists())
        self.assertFalse(helper.start()["ok"], "failed supervisor must be revoked before restart")
        self.assertFalse(helper.close()["ok"])
        self.assertFalse(helper.close()["ok"])
        self.assertEqual(quarantines[0].read_text(), "preserved user replacement")

    def test_transport_error_or_unacknowledged_erase_is_not_success(self):
        helper = self.helper(executor=lambda *args: (124, "", "fixture timeout"))
        result = helper.start()
        self.assertFalse(result["ok"])
        self.assertIn("timeout", result["error"])
        self.assertFalse(helper.erase("a" * 32)["ok"])
        self.assertFalse(helper.close()["ok"])
        self.assertFalse(helper.close()["ok"], "repeat cleanup must not invent acknowledgement")

    def test_transport_exceptions_do_not_echo_embedded_source_or_unbounded_output(self):
        import subprocess
        secret = "SOURCE_MUST_NOT_APPEAR" * 2000
        failures = [subprocess.TimeoutExpired(["python3", "-c", secret], 8),
                    subprocess.CalledProcessError(23, ["python3", "-c", secret], stderr=secret),
                    RuntimeError(secret)]
        for failure in failures:
            with self.subTest(kind=type(failure).__name__):
                helper = self.helper(executor=Mock(side_effect=failure))
                result = helper.start()
                self.assertFalse(result["ok"])
                self.assertLessEqual(len(result["error"]), 256)
                self.assertNotIn("SOURCE_MUST_NOT_APPEAR", result["error"])

    def test_fake_remote_success_is_not_an_erase_acknowledgement(self):
        helper = self.helper(executor=lambda *a: (0, '{"ok":true,"junk":[]}', ""))
        self.assertFalse(helper.erase("a" * 32)["ok"])

    def test_remote_pause_persists_without_client_polling(self):
        helper = self.helper(lease=2)
        self.assertTrue(helper.start()["ok"])
        record = helper.tick(create=True)["junk"][0]
        self.assertTrue(helper.pause()["ok"])
        size = Path(record["path"]).stat().st_size
        time.sleep(.3)
        self.assertEqual(Path(record["path"]).stat().st_size, size)
        self.assertEqual(helper.snapshot()["junk"][0]["state"], "dormant")


def post(daemon, request):
    import io
    import json
    from types import SimpleNamespace
    data = json.dumps(request).encode()
    handler = SimpleNamespace(path="/action", headers={"Content-Length": str(len(data))},
                              rfile=io.BytesIO(data), wfile=io.BytesIO(),
                              send_response=lambda *a: None, send_header=lambda *a: None,
                              end_headers=lambda: None)
    handler._do_rm = daemon._Handler._do_rm
    handler._do_kill = daemon._Handler._do_kill
    daemon._Handler.do_POST(handler)
    return json.loads(handler.wfile.getvalue())


class DaemonTests(unittest.TestCase):
    def setUp(self):
        from test_shutdown import load_daemon
        self.fixture = tempfile.TemporaryDirectory(prefix="junk-daemon-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.fixture.cleanup)
        self.d = load_daemon()
        real_helper = self.d.junk_hunt.Helper
        factory = lambda **kw: real_helper(base=self.fixture.name, boot_window=.5,
                                           options={"home": self.fixture.name}, **kw)
        for target, name, value in ((self.d.junk_hunt, "Helper", factory),
                                    (self.d, "_spawn_enemy", Mock()),
                                    (self.d, "ssh_probe_status", lambda: {}),
                                    (self.d, "ssh_hosts", lambda: ["fixture-alias"]),
                                    (self.d, "_ssh_run", Mock(side_effect=AssertionError("unexpected SSH")))):
            p = patch.object(target, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.d._kill_all_enemies)

    def local_nest(self):
        self.assertTrue(post(self.d, {"verb": "enemies", "level": 1})["ok"])
        self.d._last_spawn[0] = 0
        self.d._tend_enemies()
        return self.d._junk_snapshot()[0]

    def test_world_listing_id_erase_and_hunt_off_cleanup(self):
        import json
        record = self.local_nest()
        world = self.d.gather_world(1)
        self.assertEqual(world["junk"][0]["id"], record["id"])
        self.assertIn(record["pid"], world["enemies"])
        self.assertIsInstance(json.loads(json.dumps(world))["junk"][0]["pid"], int)
        listing = self.d.gather_listing(record["parent"])
        entry = next(n for n in listing["entries"] if n["name"] == record["name"])
        self.assertEqual(entry["junk_id"], record["id"])
        self.assertFalse(post(self.d, {"verb": "junk_rm", "id": record["id"]})["ok"])
        result = post(self.d, {"verb": "junk_rm", "id": record["id"],
                              "confirm": True, "path": "/must-not-be-used"})
        self.assertTrue(result["ok"], result)
        self.assertFalse(Path(record["path"]).exists())
        self.d._last_spawn[0] = 0
        self.d._tend_enemies()
        record = self.d._junk_snapshot()[0]
        self.assertTrue(post(self.d, {"verb": "enemies", "level": 0})["ok"])
        self.assertFalse(Path(record["path"]).exists())

    def test_sim_start_quiesces_writer_and_sparse_replay_cannot_restart_it(self):
        record = self.local_nest()
        eventually(lambda: Path(record["path"]).stat().st_size > 0)
        self.d.sim_record({"fixture": True})
        self.assertTrue(self.d.sim_control({"op": "start"})["ok"])
        size = Path(record["path"]).stat().st_size
        time.sleep(.3)
        self.d._last_spawn[0] = 0
        self.d._sim["last_emit"] = time.time()
        self.assertIsNone(self.d.sim_next())
        self.d._tend_enemies()
        self.assertEqual(Path(record["path"]).stat().st_size, size)
        self.assertEqual(self.d._junk_snapshot()[0]["state"], "dormant")
        self.assertFalse(post(self.d, {"verb": "junk_rm", "id": record["id"],
                                       "confirm": True})["ok"])
        self.assertFalse(self.d.junk_action({"id": record["id"], "confirm": True})["ok"])

    def test_sim_load_quiesces_without_polling(self):
        record = self.local_nest()
        self.d.sim_record({"fixture": True})
        with patch.object(self.d, "SIM_DIR", self.fixture.name):
            self.d.sim_control({"op": "save", "name": "fixture"})
            self.assertTrue(self.d.sim_control({"op": "load", "name": "fixture"})["ok"])
        self.assertEqual(self.d._junk_snapshot()[0]["state"], "dormant")
        self.assertEqual(self.d._junk_snapshot()[0]["pid"], 0)
        self.assertTrue(Path(record["path"]).exists())

    def test_expired_active_helper_is_retired_before_repopulation(self):
        self.d.ENEMY_LEVEL[0] = 1
        helper = self.d.junk_hunt.Helper(lease=.15)
        self.d._junk_helpers[""] = helper
        self.d._tend_junk(create=True)
        record = self.d._junk_snapshot()[0]
        eventually(lambda: not Path(record["path"]).exists())
        self.d._tend_junk(create=True)
        self.d._tend_junk(create=True)
        replacement = self.d._junk_snapshot()[0]
        self.assertNotEqual(replacement["id"], record["id"])
        self.assertTrue(Path(replacement["path"]).is_symlink())

    def test_sim_longer_than_local_lease_retires_expired_helper_and_can_hunt_again(self):
        self.d.ENEMY_LEVEL[0] = 1
        helper = self.d.junk_hunt.Helper(lease=.15)
        self.d._junk_helpers[""] = helper
        self.d._tend_junk(create=True)
        record = self.d._junk_snapshot()[0]
        self.d.sim_record({"fixture": True})
        self.assertTrue(self.d.sim_control({"op": "start"})["ok"])
        eventually(lambda: not Path(record["path"]).exists())
        result = self.d.sim_control({"op": "stop"})
        self.assertTrue(result["ok"], result)
        self.d._tend_junk(create=True)
        replacement = self.d._junk_snapshot()[0]
        self.assertNotEqual(replacement["id"], record["id"])
        self.assertGreater(replacement["pid"], 0)
        self.assertTrue(Path(replacement["path"]).is_symlink())

    def test_remote_tier_alias_and_downgrade_use_only_fixture_executor(self):
        import subprocess

        def ssh(host, cmd, timeout=8):
            self.assertEqual(host, "fixture-alias")
            if cmd == self.d._REMOTE_WORLD:
                return 0, "@@HOST actual-hostname\n@@MEM 1024 512\n", ""
            p = subprocess.run(["/bin/sh", "-c", cmd], text=True,
                               capture_output=True, timeout=timeout)
            return p.returncode, p.stdout, p.stderr

        self.d._ssh_run = ssh
        self.d.ssh_probe_status = lambda: {"fixture-alias": "open"}
        self.d._spawn_remote_enemies()
        self.assertEqual(self.d._junk_snapshot("fixture-alias"), [])
        post(self.d, {"verb": "enemies", "level": 2})
        self.d._spawn_remote_enemies()
        world = self.d.remote_world("fixture-alias")
        self.assertEqual(world["host"], "actual-hostname")
        record = world["junk"][0]
        self.assertIn(record["pid"], world["enemies"])
        self.assertFalse(post(self.d, {"verb": "junk_rm", "id": record["id"],
                                       "confirm": True, "host": "actual-hostname"})["ok"])
        self.assertTrue(post(self.d, {"verb": "junk_rm", "id": record["id"],
                                      "confirm": True, "host": "fixture-alias"})["ok"])
        self.d._spawn_remote_enemies()
        record = self.d._junk_snapshot("fixture-alias")[0]
        self.assertTrue(post(self.d, {"verb": "enemies", "level": 1})["ok"])
        self.assertFalse(Path(record["path"]).exists())
    def test_rogue_kill_is_pidfd_owned_and_leaves_a_respawning_nest(self):
        record = self.local_nest()
        with patch.object(self.d.os, "kill", side_effect=AssertionError("raw kill")):
            result = post(self.d, {"verb": "kill", "pid": record["pid"], "sig": 9})
        self.assertTrue(result["ok"], result)
        helper = self.d._junk_helpers[""]
        eventually(lambda: helper.snapshot()["junk"][0]["pid"] == 0)
        self.assertTrue(Path(record["path"]).exists())
        self.assertEqual(self.d._junk_snapshot()[0]["state"], "respawning")

    def test_remote_cleanup_failure_is_reported_and_retry_stays_a_failure(self):
        helper = self.d.junk_hunt.Helper(executor=lambda *a: (124, "", "fixture disconnected"))
        self.d._junk_helpers["fixture-alias"] = helper
        self.d.ENEMY_LEVEL[0] = 2
        first = post(self.d, {"verb": "enemies", "level": 1})
        second = post(self.d, {"verb": "enemies", "level": 0})
        self.assertFalse(first["ok"])
        self.assertFalse(second["ok"])
        self.assertIn("lease cleanup pending", first["error"])
        self.assertIn("fixture-alias", self.d._junk_errors)

    def test_remote_disconnect_reports_failure_but_independent_lease_purges_exposure(self):
        import subprocess
        connected = [True]

        def executor(command, timeout):
            if not connected[0]:
                return 124, "", "fixture disconnected"
            result = subprocess.run(["/bin/sh", "-c", command], capture_output=True,
                                    text=True, timeout=timeout)
            return result.returncode, result.stdout, result.stderr

        helper = self.d.junk_hunt.Helper(executor=executor, lease=.3)
        self.d._junk_helpers["fixture-alias"] = helper
        self.d.ENEMY_LEVEL[0] = 2
        self.d._tend_junk("fixture-alias", create=True)
        record = self.d._junk_snapshot("fixture-alias")[0]
        payload = Path(record["path"]).resolve()
        self.assertTrue(Path(record["path"]).is_symlink())
        connected[0] = False
        result = post(self.d, {"verb": "enemies", "level": 1})
        self.assertFalse(result["ok"])
        self.assertIn("lease cleanup pending", result["error"])
        eventually(lambda: not Path(record["path"]).is_symlink())
        self.assertFalse(payload.exists())
        connected[0] = True
        self.assertEqual(self.d._cleanup_junk(remote_only=True), [])
        self.assertEqual(self.d._junk_snapshot("fixture-alias"), [])

    def test_opt_out_waits_for_registered_inflight_remote_spawn_and_erases_it(self):
        import subprocess
        import threading
        entered, release = threading.Event(), threading.Event()

        def ssh(host, cmd, timeout=8):
            if '"op": "start"' in cmd:
                entered.set()
                if not release.wait(3):
                    raise AssertionError("test release missing")
            p = subprocess.run(["/bin/sh", "-c", cmd], text=True,
                               capture_output=True, timeout=timeout)
            return p.returncode, p.stdout, p.stderr

        self.d._ssh_run = ssh
        self.d.ssh_probe_status = lambda: {"fixture-alias": "open"}
        self.d.ENEMY_LEVEL[0] = 2
        producer = threading.Thread(target=self.d._spawn_remote_enemies)
        producer.start()
        self.assertTrue(entered.wait(2))
        results = []
        cleanup = threading.Thread(target=lambda: results.append(
            post(self.d, {"verb": "enemies", "level": 0})))
        cleanup.start()
        eventually(lambda: self.d.ENEMY_LEVEL[0] == 0)
        release.set()
        producer.join(4)
        cleanup.join(4)
        self.assertFalse(producer.is_alive())
        self.assertFalse(cleanup.is_alive())
        self.assertTrue(results[0]["ok"], results)
        self.assertEqual(self.d._junk_snapshot("fixture-alias"), [])
        self.assertEqual(list(Path(self.fixture.name).rglob("*.junk")), [])

    def test_sparse_sim_poller_never_calls_tending(self):
        self.d._sim["playing"] = True
        self.d.sim_next = lambda: None
        self.d.gather_world = lambda tick: {"fixture": tick}
        waits = []

        def stop_after_one_tick(*a):
            waits.append(True)
            self.d._shutdown_started.set()

        with patch.object(self.d, "_tend_enemies", side_effect=AssertionError("SIM tended")), \
                patch.object(self.d._shutdown_started, "wait", stop_after_one_tick):
            self.d._poller()
        self.assertEqual(len(waits), 1)


if __name__ == "__main__":
    unittest.main()
