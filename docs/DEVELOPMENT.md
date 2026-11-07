# WOPR developer guide

## Runtime boundaries

WOPR is not a sandbox. The normal game scene can start or adopt the telemetry daemon. Closing the game can stop an adopted daemon. Gameplay actions can signal real processes, delete real files, use SSH, or invoke the privileged Oracle.

Do not start the normal scene for visual tests. Use the isolated fixtures below. Do not enable Hunt on a real host to test a renderer.

- `telemetry/frameshiftd.py`: world snapshots, Hunt, replay state, and action routing.
- `telemetry/oracle_bridge.py`: the unprivileged client for the optional root Oracle.
- `game/scripts/main.gd`: world state, targeting, navigation, and input.
- `game/scripts/flight_overlay.gd`: screen markers and flight instruments. It does not send actions.
- `game/scripts/travel_overlay.gd`: directory and SSH transition effects.
- `game/scripts/action_effects.gd`: lock, shot, and acknowledgement effects.
- `game/scripts/world_art.gd` and `game/shaders/`: world presentation.

The local HTTP API uses loopback port 8765 by default. The client polls `/world.json`. `/action` accepts explicit verbs. Directory and remote-world requests use `/list`, `/ssh/list`, and `/ssh/world`.

Keep requested SSH aliases separate from returned hostnames. An alias selects the machine for later actions. A hostname is display data. A PID identifies a process only within its host namespace.

Godot parses JSON numbers as floats. Normalize entity IDs before dictionary lookup or membership tests. Use actual JSON serialization in regressions.

## Safe verification

```sh
# Offline Python lifecycle tests.
python3 -m unittest discover -s telemetry/tests -v

# Parse scripts and exercise the isolated Godot world.
python3 game/tests/verify_visuals.py

# Compile real shaders and capture synthetic views on a private X server.
# Requires xvfb-run. Keep artifacts in your scratch directory.
python3 game/tests/verify_visuals.py --render --output "$TMPDIR/wopr-visual-tests"
```

Python shutdown fixtures replace HTTP, SSH, Oracle, and enemy handles before startup. They raise real signals only inside disposable fixture subprocesses. Filesystem/writer tests must use disposable scratch roots and owned helper processes, never configured remote hosts or the default gameplay data directory.

Godot fixtures override daemon startup, polling, shutdown, and live actions. They provide synthetic telemetry and keep HTTP clients disconnected. Render tests cover normal and small windows. The default renderer is Forward+, so also inspect a Forward+ capture after a shader or visual change.

A successful exit code is not enough. Godot can log runtime errors and exit zero. Python can report an interrupted `atexit` callback and still exit zero. Require success markers, cleanup assertions, and clean error output.

## Shutdown

The first SIGTERM or SIGINT sets the daemon shutdown event. Later termination signals return without another `SystemExit`. The watchdog and poll loop stop cooperatively. An in-flight operation can still finish.

Cleanup callbacks register before worker startup. Server construction and serving share a `finally` path, including bind failures. Oracle cleanup precedes ordinary enemy cleanup.

Remote cleanup needs acknowledgement. A quiet terminal is not evidence that a remote purge succeeded. Network failure and process death need separate handling.

## Junk nests

The implementation plan and wire contract are in [plans/junk-nests.md](plans/junk-nests.md). Release verification includes owned writer processes, local execution of the remote protocol, actual `atexit` cleanup, and isolated Godot fixtures.

The feature is limited to WOPR-created rogues and artifacts. It must not attach writers to unrelated application processes. Artifact identity is a stable nest ID within a host namespace, not a PID. Erasure uses a confirmed ID-based action resolved by the daemon.

Keep backing junk inside private session directories. Expose marked symlinks among real files in existing ordinary directories under that host's home. Never replace an existing entry or follow a candidate directory symlink. Bound write rates, object sizes, population, and lifetime. Check process identity before signalling a stored PID.

Cleanup removes both exposures and backing data. It atomically detaches an exposed entry into a private quarantine on the same filesystem, then validates the detached entry. It deletes only the registered symlink. It restores a user replacement without overwriting a new occupant. If restoration fails, it preserves the entry, reports the quarantine path, and keeps the cleanup failure visible. Quarantine is never recursively deleted. This protects against ordinary entry-replacement races, not malicious interference from the same Unix user.

Removing the link disables respawn. Generated junk uses the ID-based erase verb, not ordinary local erasure, which resolves symlinks before deletion. Erasing an ordinary neighboring object remains a real destructive action. Failed cleanup can leave a recoverable quarantine or failure marker rather than risk deleting user data.

Hunt-off and shutdown must stop producers before removing owned artifacts. Remote sessions need an independent expiry path if SSH is unavailable. SIM must block the new action and quiesce real writers, not merely hide them in replay snapshots.

`test_junk_shutdown.py` runs the real daemon signal and `atexit` path with a fake listener and worker startup. It creates real junk only in a disposable home fixture. The parent test verifies that both the exposed link and backing payload disappear and that an ordinary neighboring file survives.

Junk file/folder geometry belongs inside the matching vault. Outdoor wayfinding uses vault beacons and must not depict files among CPU processes. Rogue roaming covers the local field, with the network/SSH district gated by Hunt tier. Roaming is presentation, never a network request.

Action acknowledgements must contain a boolean `ok`. Invalid fields, missing or mismatched erase IDs, and transport failures must preserve uncertain artifacts and clear pending UI state.
