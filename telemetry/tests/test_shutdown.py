"""Offline lifecycle tests: no listener, SSH, Oracle, or live enemy processes.

The child fixture runs the real main()/atexit/signal path, but replaces every
external boundary before main() runs. Signals are raised only in that fixture.
"""
import atexit
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
from typing import Any
import unittest
from unittest.mock import Mock, patch


DAEMON_PATH = Path(__file__).resolve().parents[1] / "frameshiftd.py"


def load_daemon() -> Any:
    spec = importlib.util.spec_from_file_location("shutdown_fixture", DAEMON_PATH)
    assert spec is not None and spec.loader is not None
    daemon = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(daemon)
    return daemon


class StopPoll(BaseException):
    """Escape an unexpected poll without the production error loop catching it."""


def cleanup_fixture(cleanup_signal):
    daemon = load_daemon()
    local_kills = []
    remote_calls = []
    daemon.ENEMIES[12345] = {"proc": Mock(kill=lambda: local_kills.append(12345))}
    daemon.REMOTE_ENEMIES.update({"fixture-a": {23456: 0}, "fixture-b": {34567: 0}})
    daemon.oracle_bridge.shutdown = lambda: print("ORACLE_CLEANUP_COMPLETE", flush=True)

    def ssh(host, command, timeout):
        remote_calls.append((host, command, timeout))
        print("REMOTE_CLEANUP_BEGIN " + host, flush=True)
        # Reproduce a second termination signal while inside atexit cleanup.
        signal.raise_signal(cleanup_signal)
        print("REMOTE_CLEANUP_COMPLETE " + host, flush=True)
        return 0, "", ""

    daemon._ssh_run = ssh
    daemon.sim_next = Mock(side_effect=StopPoll)

    class Thread:
        def __init__(self, *, target, args=(), daemon=False):
            self.target = target

        def start(self):
            if self.target is daemon._poller:
                try:
                    self.target()
                except StopPoll:
                    pass

    class Server:
        def __init__(self, *args):
            pass

        def serve_forever(self):
            signal.raise_signal(signal.SIGTERM)

        def server_close(self):
            print("SERVER_CLOSED", flush=True)

    def audit():
        assert not daemon.ENEMIES and not daemon.REMOTE_ENEMIES
        assert local_kills == [12345]
        assert remote_calls == [("fixture-a", "kill -9 23456", 10),
                                ("fixture-b", "kill -9 34567", 10)]
        print("SHUTDOWN_FIXTURE_OK", flush=True)

    atexit.register(audit)  # registered first, audited after production cleanup
    with patch.object(daemon.threading, "Thread", Thread), \
            patch.object(daemon, "ThreadingHTTPServer", Server), \
            patch.object(sys, "argv", [str(DAEMON_PATH), "--parent", "123456"]):
        daemon.main()


class ShutdownTests(unittest.TestCase):
    def test_repeated_sigterm_during_atexit(self):
        self.check_cleanup_fixture("SIGTERM")

    def test_sigint_during_atexit(self):
        self.check_cleanup_fixture("SIGINT")

    def check_cleanup_fixture(self, name):
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--cleanup-fixture", name],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SHUTDOWN_FIXTURE_OK", result.stdout, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("ORACLE_CLEANUP_COMPLETE"), 1)
        self.assertEqual(result.stdout.count("REMOTE_CLEANUP_COMPLETE"), 2)
        self.assertNotIn("Exception ignored", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def stopped_daemon(self, *, startup_failure=False):
        daemon = load_daemon()
        server = Mock()
        server.serve_forever.side_effect = SystemExit(0)
        with patch.object(daemon.threading, "Thread"), \
                patch.object(daemon.atexit, "register"), \
                patch.object(daemon.signal, "signal"), \
                patch.object(daemon, "ThreadingHTTPServer") as constructor, \
                patch.object(sys, "argv", [str(DAEMON_PATH)]):
            if startup_failure:
                constructor.side_effect = OSError("fixture bind failure")
                with self.assertRaisesRegex(OSError, "fixture bind failure"):
                    daemon.main()
            else:
                constructor.return_value = server
                daemon.main()
                server.server_close.assert_called_once()
        return daemon

    def check_watchdog_stopped(self, daemon):
        def kill(pid, sig):
            if sig == 0:
                raise ProcessLookupError()

        with patch.object(daemon.os, "kill", side_effect=kill) as kill_mock, \
                patch.object(daemon.time, "sleep"):
            daemon._watch_parent(123456)
        kill_mock.assert_not_called()

    def test_watchdog_stops_when_main_exits(self):
        self.check_watchdog_stopped(self.stopped_daemon())

    def test_watchdog_stops_on_bind_failure(self):
        self.check_watchdog_stopped(self.stopped_daemon(startup_failure=True))

    def test_poller_does_not_restart_work_after_shutdown(self):
        daemon = self.stopped_daemon()
        with patch.object(daemon.atexit, "register"), \
                patch.object(daemon, "sim_next", side_effect=StopPoll) as poll:
            daemon._poller()
        poll.assert_not_called()

    def test_live_watchdog_still_requests_shutdown_for_missing_parent(self):
        daemon = load_daemon()

        def kill(pid, sig):
            if sig == 0:
                raise ProcessLookupError()

        with patch.object(daemon.os, "kill", side_effect=kill) as kill_mock, \
                patch.object(daemon.time, "sleep"), \
                patch.object(daemon.threading.Event, "wait", return_value=False):
            daemon._watch_parent(123456)
        self.assertEqual(kill_mock.call_args_list[0].args, (123456, 0))
        self.assertEqual(kill_mock.call_args_list[1].args,
                         (daemon.os.getpid(), signal.SIGTERM))
        self.assertEqual(kill_mock.call_count, 2)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--cleanup-fixture":
        cleanup_fixture(getattr(signal, sys.argv[2]))
    else:
        unittest.main()
