# Junk Nest Hunt Implementation Plan

**Goal:** Give file deletion a gameplay purpose: some game-owned rogues leave real junk that enables respawn until erased.

**Architecture:** The daemon owns bounded per-session junk identities and publishes authoritative metadata. Local and opt-in remote helpers manage real writer processes and game-owned artifacts. Godot renders distinctive junk objects, locators, and vault highlights, and sends confirmed ID-based erase requests. This extends Hunt, not arbitrary application processes.

**Tech stack:** Existing Python standard library/psutil daemon, SSH fixed commands, Godot 4.7 GDScript, existing isolated tests.

## User decisions

- Implement on local and remote hosts. Remote writing requires Hunt LOCAL + REMOTE.
- Killing a writer leaves its junk. The same nest can respawn a new PID after a delay.
- Erasing its marked file/folder disables that nest's respawn.
- Normal game close and Hunt-off remove session-owned junk and stop its processes.
- Files/folders need distinctive geometry, labels, and direction/range indicators.
- Correction: visible junk must appear among real files. Keep backing data in WOPR's private session directory, but expose marked symlinks in random existing ordinary directories under the local/remote home. Choosing the wrong neighboring file remains dangerous.
- Correction: render junk files/folders only inside their actual vault directories. Outdoor wayfinding points to a vault destination, not file props beside CPU processes.
- Rogues roam the whole local field. Network harbor and SSH areas are excluded unless LOCAL + REMOTE hunting is enabled. Movement never initiates network travel or actions.

## Safety and boundaries

- Only WOPR-spawned rogues write junk. Never modify unrelated applications.
- Backing payloads live inside private WOPR-owned session directories. Exposed symlinks live among real files under HOME. Never overwrite an existing entry, follow candidate directory symlinks, or place links outside that host's home.
- Record exposed-link and parent identity. Cleanup unlinks only an unchanged WOPR-created link, never a user replacement. Remove backing payloads as well. Deleting a link externally disables the nest, not just deleting its backing data.
- Close the replacement race with atomic detachment into a private same-filesystem quarantine before identity validation. Restore non-owned entries without overwriting a new occupant. Preserve and report an uncertain entry rather than delete it. A second pathname check is not a race fix.
- Small bounded write rate, per-object and aggregate limits, and capped populations.
- Validate IDs and ownership. Cleanup must not follow symlinks, traverse paths, delete unrelated sessions, or signal reused PIDs.
- Repeated cleanup is safe. Stop producers before removing artifacts. Preserve the recently fixed idempotent signal shutdown.
- Remote helpers have a renewable lease and an independent cleanup/expiry path. If immediate SSH cleanup fails, report it rather than claim success.
- SIM refuses actions and stops real respawning/writing. Tests must not contact configured remote hosts or run the real main scene/daemon.
- Local filesystem/process integration tests may use only explicitly created scratch fixtures and disposable owned helper subprocesses.

## Backend task

Create `telemetry/junk_hunt.py` plus `telemetry/tests/test_junk_hunt.py`. Integrate with `telemetry/frameshiftd.py`.

1. Write and observe a failing test for owned artifact creation and persistence after writer death.
2. Implement bounded file and directory nests with stable IDs, identity-safe owned writers, delayed respawn, and erase cancellation.
3. Add tests and implementation for session cleanup, opt-out, lease expiry, symlink/path/PID defenses, and in-flight cleanup coordination.
4. Integrate with existing Hunt population, SIM, world snapshots, remote snapshots, listing metadata, and shutdown. Do not bypass existing general file/action policies.
5. Test remote protocol through local isolated helper fixtures, never real SSH hosts.

### Shared wire contract

- Local `/world.json`: `junk` array.
- Remote `/ssh/world`: `junk` array for the requested SSH alias, not the response hostname.
- Each record: `id` (opaque string), `path` (absolute exposed-symlink path on its host), `parent` (absolute exposed parent), `name`, `dir` (boolean, backing object type), `size` (actual payload bytes), `pid` (integer or 0), `state` (`active` / `respawning` / `dormant`), `respawns` (count). Keep backing locations internal.
- Stable identity is `(host namespace, id)`, never PID alone.
- POST `/action`: `{verb: "junk_rm", id: <id>, confirm: true, host: <requested SSH alias if remote>}`. The server resolves its own ID registry, never an arbitrary client path. SIM blocks it. Success means erase is acknowledged, not merely queued.
- Junk records disappear after confirmed erasure or cleanup. Removed artifacts cannot be recreated by late writers.
- Existing `enemies` arrays include currently live junk-writer PIDs, so rogue targeting works normally.
- Do not require a new network API or package dependency.

## Client task

Modify `game/scripts/main.gd`, `game/scripts/flight_overlay.gd`, and isolated client tests.

1. Add a RED regression for local/remote JSON metadata, namespace isolation, persistent artifacts after PID death, cleanup of disappeared artifacts, and presentation-only locators.
2. Render magenta/coral junk file/folder objects with readable JUNK/NEST labels only inside the correct vault. Outdoor representations are clearly labelled vault beacons at the file-vault destination, never file/folder props on CPU plains.
3. Add direction/range markers to outdoor vault beacons and marked vault entries. Keep collision-aware layout shared with existing rogue locators.
4. Aim + Enter on an outdoor vault beacon opens the exposed parent vault among real files, using the current requested SSH alias. Highlight matching vault entries and show that erasing disables respawn. Style based on matching junk metadata, since listing a directory symlink with nofollow can classify it as a file.
5. Hold-X on a marked vault entry sends the ID-based `junk_rm` verb through `_request_action`; never route generated junk through the root Oracle. Keep ordinary file erasure unchanged.
6. Extend synthetic visual views and headless/real-render coverage. Existing fixtures must remain disconnected from HTTP and must never invoke real deletion or spawning.
7. Reject non-boolean action acknowledgements without leaving pending requests stuck. Preserve artifacts and clear pending state on malformed/missing/mismatched acknowledgements.
8. Expand rogue roaming across the field with explicit Hunt-tier gating around the network/SSH district. Ordinary process geography remains unchanged. Test local-only exclusion, enabled network roaming, finite bounds, and host namespace isolation.

## Integration and release

- Run Python unit tests on embedded and system Python. Run Python compilation and the full isolated Godot verifier.
- Render and inspect junk outdoors and vaults at normal/small sizes with Compatibility, plus a Forward+ sample.
- Run disposable scratch-only writer/erase/cleanup/remote-lease integration tests.
- Obtain independent logic/security review and address concrete findings.
- Keep player-facing instructions brief in README. Developer details go in `docs/DEVELOPMENT.md`, not a test report in the README.
- Preserve the pre-existing staged README changes unless explicitly superseded by the approved documentation split. Do not publish unfinished work.

## Release verification status

- [x] Owned writer, exposed-home-link, respawn, ID action, SIM, remote-protocol, and lease fixtures exercise real scratch files/processes without live hosts.
- [x] Normal SIGTERM/atexit cleanup removes exposed links and backing payloads while preserving a neighboring fixture file, under both Python runtimes.
- [x] Replacement-safe cleanup passes deterministic entry-swap regression and independent re-review.
- [x] Vault-only file geometry, outdoor destination beacons, malformed ACK recovery, and broad gated roaming pass the isolated Godot suite.
- [x] Updated normal/small-window captures and Forward+ output are inspected.
- [x] Player/developer docs and screenshots match verified behavior.
- [ ] External project-knowledge sync is blocked. Local requirements are preserved; knowledge-store recovery is separate work.
- [x] Verified changes are cleared for commit and publication after independent release review. Remote branch verification is part of the release handoff.
