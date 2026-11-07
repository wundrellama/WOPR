#!/usr/bin/env python3
"""Exercise presentation with an isolated Godot subclass, never the live daemon.

Default: headless runtime smoke tests. --render: also compile the real OpenGL
shaders and capture title/world/target and alternate states on a private Xvfb.
Screenshots use synthetic, explicitly named fixtures; no invented telemetry.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


PROJECT = Path(__file__).resolve().parents[1]
VIEWS = ("title", "world", "hunt", "hunt-behind", "target", "remote", "vault", "sim", "armed", "ritual", "farewell")
ERROR = re.compile(r"(?:SCRIPT ERROR|SHADER ERROR|^ERROR:|Parse Error|Assertion failed)", re.MULTILINE)


def run(command, expected=None):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if result.returncode or ERROR.search(result.stdout) or (expected and expected not in result.stdout):
        print(result.stdout, file=sys.stderr)
        raise RuntimeError(f"Failed: {' '.join(map(str, command))}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--output", type=Path, help="Directory for PNGs (required with --render)")
    args = parser.parse_args()
    if args.render and (not args.output or not shutil.which("xvfb-run")):
        parser.error("--render requires --output and xvfb-run")
    scripts = ("scripts/main.gd", "scripts/world_art.gd", "scripts/flight_overlay.gd",
               "scripts/console_ui.gd", "scripts/travel_overlay.gd", "scripts/action_effects.gd",
               "tests/visual_smoke.gd", "tests/navigation_regression.gd", "tests/travel_test.gd",
               "tests/action_feedback_test.gd", "tests/presentation_sequence.gd", "tests/daemon_probe_test.gd",
               "tests/hunt_render_test.gd")
    for script in scripts:
        run(["godot", "--headless", "--path", str(PROJECT), "--check-only", "--script", script])
    print(f"PASS: {len(scripts)} GDScript parse checks", flush=True)
    for view in VIEWS:
        run(["godot", "--headless", "--path", str(PROJECT), "--script",
             "tests/visual_smoke.gd", "--", f"--view={view}"], f"VISUAL_SMOKE_OK view={view}")
        print(f"PASS: headless runtime / {view}", flush=True)
    for script, marker in (("hunt_render_test.gd", "HUNT_RENDER_OK"),
                           ("daemon_probe_test.gd", "DAEMON_PROBE_OK"),
                           ("navigation_regression.gd", "NAVIGATION_REGRESSION_OK"),
                           ("travel_test.gd", "TRAVEL_TEST_OK"),
                           ("action_feedback_test.gd", "ACTION_FEEDBACK_OK")):
        run(["godot", "--headless", "--path", str(PROJECT), "--script", "tests/" + script], marker)
        print(f"PASS: regression / {script}", flush=True)
    for kind in ("vault", "ssh", "shots"):
        run(["godot", "--headless", "--path", str(PROJECT), "--script",
             "tests/presentation_sequence.gd", "--", f"--kind={kind}"], f"PRESENTATION_SEQUENCE_OK kind={kind}")
        print(f"PASS: animation runtime / {kind}", flush=True)
    if args.render:
        args.output.mkdir(parents=True, exist_ok=True)
        for width, height in ((1600, 900), (1152, 648)):
            for view in VIEWS:
                output = args.output.resolve() / f"{view}-{width}x{height}.png"
                run(["xvfb-run", "-a", "-s", f"-screen 0 {width}x{height}x24",
                     "godot", "--display-driver", "x11", "--audio-driver", "Dummy",
                     "--rendering-method", "gl_compatibility", "--path", str(PROJECT),
                     "--resolution", f"{width}x{height}", "--script", "tests/visual_smoke.gd",
                     "--", f"--view={view}", f"--output={output}"], f"VISUAL_CAPTURE {output}")
                if not output.is_file() or output.stat().st_size < 1000:
                    raise RuntimeError(f"Missing/empty capture: {output}")
                print(f"PASS: rendered {view} / {width}x{height} / {output}", flush=True)
        for kind in ("vault", "ssh", "shots"):
            directory = args.output.resolve() / f"sequence-{kind}"
            run(["xvfb-run", "-a", "-s", "-screen 0 1600x900x24", "godot",
                 "--display-driver", "x11", "--audio-driver", "Dummy",
                 "--rendering-method", "gl_compatibility", "--fixed-fps", "30", "--path", str(PROJECT),
                 "--script", "tests/presentation_sequence.gd", "--", f"--kind={kind}",
                 f"--output-dir={directory}"], f"PRESENTATION_SEQUENCE_OK kind={kind}")
            frames = sorted(directory.glob("[0-9][0-9][0-9].png"))
            if len(frames) != 32:
                raise RuntimeError(f"Expected 32 sequence frames, got {len(frames)} for {kind}")
            print(f"PASS: rendered animation / {kind} / {len(frames)} frames", flush=True)
    print("PASS: visual verification complete; no live daemon used", flush=True)


if __name__ == "__main__":
    main()
