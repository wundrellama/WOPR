# Frameshift

An open world exploration game where the world is the virtual insides of the
actual machine running the game. Every monolith is a real process. Every spell
is a real syscall.

## Layout

- `telemetry/frameshiftd.py` — world-state daemon (psutil). Serves
  `http://127.0.0.1:8765/world.json` (world snapshot, 1 Hz) and accepts
  `POST /action` for Tier-2 verbs (real `kill()` with a protected set).
- `game/` — Godot 4.7 project. Procedurally builds the world from live
  telemetry: one monolith per process, height = RAM, glow = CPU, frozen
  (SIGSTOP'd) processes turn to grey stone and stop breathing.

## Run it

```sh
python3 telemetry/frameshiftd.py        # terminal 1
godot --path game/                      # terminal 2
```

## Controls

| Key | Verb | Reality |
|---|---|---|
| WASD / Q,E | move | — |
| Shift | sprint | — |
| Left-click | target | raycast |
| `F` | freeze | `kill(pid, SIGSTOP)` — real |
| `C` | resume | `kill(pid, SIGCONT)` — real |
| `Shift+K` | smite | `kill(pid, SIGKILL)` — real |
| Esc | quit | — |

Yes, those are real. A Tier-2 protected set (PID 1, the daemon, its ancestors)
is enforced daemon-side; everything else on your user account is fair game.

## Danger tiers (design)

1. **Sim** — fake process table, fully safe. *(planned)*
2. **Live** — real PIDs, real signals, protected set, no file verbs. **← built**
   Plus: **vaults** (enter mounts/dirs, hold-X erase guarded `rm -rf`) and
   **SSH travel** (gateways from `~/.ssh/config` → remote worlds, remote
   kill/rm via fixed verbs, remote file browsing with `V`).
3. **YOLO** — root "Kernel Oracle" helper: `rm -rf`, `systemctl stop`,
   `rmmod`, everything. Requires sudo as the arming ritual and a btrfs
   snapshot (`snapper create`) to exist before arming. *(planned)*

The Oracle will expose **verbs, never a shell** — path arguments, not command
strings — so the privileged surface stays one small auditable binary.

## Enemies

The daemon spawns real CPU-burner + RAM-hoarder child processes (nice'd to
19, TTL 180s, cap 4). They roam the plains as red ROGUE monoliths. Kill them
with Shift+K before they expire or you "let one go free". Freezing one only
buys 8 seconds — rogues break out of SIGSTOP. Because they wander among your
real processes, an errant smite can kill something that matters. That's the
game.

## Roadmap

- [x] Live telemetry daemon (procs, cpu, mem, disk, sockets, listeners)
- [x] Godot world render + fly camera + HUD
- [x] Tier-2 freeze/resume/smite with protected set
- [ ] Network bridges rendered as light-roads to remote-host towers
- [ ] Memory as water level, swap pressure as flood
- [ ] systemd respawn = hydra enemies; zombie processes = ghosts
- [ ] Sim mode (record/replay a world snapshot)
- [ ] The Kernel Oracle (Rust) + YOLO arming ritual + snapper rollback
