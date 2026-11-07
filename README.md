# WOPR

*The most dangerous game.*

An open world exploration game where the world is the virtual insides of the
actual machine running the game. Every monolith is a real process. Every spell
is a real syscall. "Shall we play a game?"

## ⚠️ THIS GAME CAN DESTROY YOUR SYSTEM

This is not a simulation and there is no sandbox. Every verb is a real syscall
executed by a real daemon running as you:

- **`K` is a real `SIGKILL`.** Aim at the wrong monolith and you kill your
  browser, your compositor, your SSH session, your work. Unsaved = gone.
- **Hold-X in a vault is a real `rm -rf`.** The daemon guards a short list of
  protected paths (`/`, `~`, mount roots) — that is a guardrail, not a wall.
  Anything you own and the guard list misses is destructible, permanently.
- **The backup is not safe either.** Your btrfs snapshots live on the same disk,
  inside the same filesystem, under paths like `@/.snapshots`. A recursive erase
  aimed carelessly — or, in YOLO tier, deliberately — destroys the snapshots
  *along with* the data they were supposed to rescue. There is no undo, no
  trash, and no rollback of the rollback. If you want a real safety net, it must
  live off this machine.
- **SSH travel extends all of this to every host in your `~/.ssh/config`.**
  A smite or erase abroad is a real remote `kill` / `rm -rf` on that machine.

Play it on a machine you can afford to lose, or with backups you can afford to
lose the machine for. That tension — a beautiful world you are *allowed* to
ruin — is the entire point of the game.

## Layout

- `telemetry/frameshiftd.py` — world-state daemon (psutil). Serves
  `http://127.0.0.1:8765/world.json` (world snapshot, 1 Hz) and accepts
  `POST /action` for Tier-2 verbs (real `kill()` with a protected set).
- `game/` — Godot 4.7 project. Procedurally builds the world from live
  telemetry: one monolith per process, height = RAM, glow = CPU, frozen
  (SIGSTOP'd) processes turn to grey stone and stop breathing.

## Run it

```sh
godot --path game/                      # that's it
```

The game adopts a running `frameshiftd` if one answers on `127.0.0.1:8765`,
otherwise it spawns its own as a child with a parent-death watchdog. Either
way, **quitting the game stops everything** — recording, enemies, the Oracle.
To run the daemon separately (e.g. for remote-host enemy hunting before you
launch the game): `python3 telemetry/frameshiftd.py`.

## Controls

| Key | Verb | Reality |
|---|---|---|
| WASD / Q,E | move | — |
| Shift | sprint | — |
| Left-click | target | raycast |
| `F` | freeze | `kill(pid, SIGSTOP)` — real |
| `C` | resume | `kill(pid, SIGCONT)` — real |
| `K` | smite | `kill(pid, SIGKILL)` — real |
| `H` | hunt: cycle off / local / +remote rogues | spawns real burner processes |
| `Enter` | descend vault / travel gate | — |
| `V` | browse remote files (in a remote world) | — |
| Hold-`X` | erase (in a vault) | `rm -rf` — real, guarded (as root when armed) |
| `Y` | arm the Kernel Oracle | sudo ritual · root verbs for 120s |
| `M` | sim mode: replay the recorded window | all real verbs frozen server-side |
| `Esc` | leave vault / return home / two-stage exit | — |

Yes, those are real. A Tier-2 protected set (PID 1, the daemon, its ancestors)
is enforced daemon-side; everything else on your user account is fair game.

## Danger tiers (design)

1. **Sim** — the daemon always records a rolling 30-minute window of real
   world snapshots; press **M** to replay it. While a replay plays, the
   daemon **refuses every real verb server-side** — kills, rm, ssh, enemy
   spawns, even the Oracle. Safety is enforced by the daemon, not the UI.
   Saves/loads via `~/.local/share/wopr/saves/*.wopr.gz`. *(built)*
2. **Live** — real PIDs, real signals, protected set, no file verbs. **← built**
   Plus: **vaults** (enter mounts/dirs, hold-X erase guarded `rm -rf`) and
   **SSH travel** (gateways from `~/.ssh/config` → remote worlds, remote
   kill/rm via fixed verbs, remote file browsing with `V`).
3. **YOLO** — root "Kernel Oracle" helper: `kill` any pid, `systemctl`,
   `modprobe ±r`, `rm -rf`, snapshots. Press **Y** in-game, speak the
   incantation (your sudo password — piped to sudo, never stored), and the
   Oracle arms **only if a snapper snapshot exists** — a *ritual*, not a
   promise: erasing the snapshot store is a supported verb (it demands
   `--i-know` and logs it in caps). Armed for 120s, then cold. Every verb
   is written to a write-ahead log *before* it runs.
   *(built — first live use is your call, on a machine you can afford)*
   One-time setup: `sudo snapper -c root create-config /` and a
   `sudo snapper -c root create -c pre -d "wopr baseline"`.

The Oracle exposes **verbs, never a shell** — fixed argv arrays, allowlisted
actions, path arguments only. Zero Rust dependencies, ~450 auditable lines
(`oracle/`). The daemon itself never runs as root; the Oracle is spawned by
`sudo -S` and its socket is 0600 owned by the user who armed it.

## Enemies

The daemon spawns real CPU-burner + RAM-hoarder child processes (nice'd to
19, TTL 180s, cap 4). They roam the plains as red ROGUE monoliths. Kill them
with K before they expire or you "let one go free". Freezing one only
buys 8 seconds — rogues break out of SIGSTOP. Because they wander among your
real processes, an errant smite can kill something that matters. That's the
game.

## Roadmap

- [x] Live telemetry daemon (procs, cpu, mem, disk, sockets, listeners)
- [x] Godot world render + fly camera + HUD
- [x] Tier-2 freeze/resume/smite with protected set
- [x] Network bridges rendered as light-roads to remote-host towers
- [x] Memory as water level, swap pressure as flood (blood-crest at high swap)
- [x] zombie processes = ghosts (pale monoliths)
- [x] systemd respawn = hydra enemies (respawn within 10s of a smite = Hydra)
- [x] Sim mode (record/replay a world snapshot)
- [x] The Kernel Oracle (Rust) + YOLO arming ritual + snapper rollback (staged via bootloader)
