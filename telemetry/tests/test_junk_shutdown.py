"""Real atexit cleanup for scratch-owned junk; all live server boundaries are fake."""
import atexit
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


DAEMON = Path(__file__).resolve().parents[1] / "frameshiftd.py"


def shutdown_fixture(directory):
    sys.path.insert(0, str(DAEMON.parent))
    spec = importlib.util.spec_from_file_location("junk_exit_fixture", DAEMON)
    assert spec is not None and spec.loader is not None
    daemon = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(daemon)
    base = Path(directory)
    home = base / "fixture-home"
    ordinary = home / "Documents"
    ordinary.mkdir(parents=True)
    neighbor = ordinary / "keep.txt"
    neighbor.write_text("fixture neighbor")
    real_helper = daemon.junk_hunt.Helper
    daemon.junk_hunt.Helper = lambda **kw: real_helper(
        base=str(base), boot_window=.5, options={"home": str(home)}, **kw)
    daemon.ENEMY_LEVEL[0] = 1
    daemon._tend_junk(create=True)
    records = daemon._junk_snapshot()
    assert len(records) == 1 and Path(records[0]["path"]).is_symlink()
    paths = [{"link": record["path"], "payload": str(Path(record["path"]).resolve())}
             for record in records]
    (base / "paths.json").write_text(json.dumps(paths))
    daemon.oracle_bridge.shutdown = lambda: None

    class Server:
        def __init__(self, *args):
            pass

        def serve_forever(self):
            signal.raise_signal(signal.SIGTERM)

        def server_close(self):
            pass

    def audit():
        assert not daemon._junk_helpers
        assert all(not os.path.lexists(record["path"]) for record in records)
        assert neighbor.read_text() == "fixture neighbor"
        print("JUNK_ATEXIT_OK", flush=True)

    atexit.register(audit)  # runs after the callbacks registered by main()
    with patch.object(daemon.threading, "Thread"), \
            patch.object(daemon, "ThreadingHTTPServer", Server), \
            patch.object(sys, "argv", [str(DAEMON)]):
        daemon.main()


class JunkShutdownTests(unittest.TestCase):
    def test_actual_atexit_removes_exposed_link_and_backing_payload(self):
        with tempfile.TemporaryDirectory(prefix="junk-exit-", dir=os.environ["TMPDIR"]) as directory:
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), "--fixture", directory],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("JUNK_ATEXIT_OK", result.stdout, result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertNotIn("Exception ignored", result.stderr)
            for record in json.loads((Path(directory) / "paths.json").read_text()):
                self.assertFalse(os.path.lexists(record["link"]))
                self.assertFalse(Path(record["payload"]).exists())
            self.assertEqual((Path(directory) / "fixture-home/Documents/keep.txt").read_text(),
                             "fixture neighbor")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        shutdown_fixture(sys.argv[2])
    else:
        unittest.main()
