//! The Kernel Oracle — the only privileged component in WOPR.
//!
//! The game and the telemetry daemon run as the normal user and NEVER as root.
//! This binary is spawned by the daemon under `sudo` (the sudo password IS the
//! arming incantation) and speaks a fixed-verb protocol on a Unix socket.
//! It is not a shell. There is no way to pass it a command line; every verb is
//! a compiled-in code path with its own argument parsing and guardrails.
//!
//! Arming ritual:
//!   1. The daemon asks the player for the incantation, spawns this binary
//!      via `sudo -S` (the password is consumed by sudo, never stored).
//!   2. Once listening, the Oracle refuses to ARM unless a snapper snapshot
//!      exists. No snapshot, no arming. The snapshot is a *ritual, not a
//!      promise*: the Oracle can erase the snapshot store too (--i-know).
//!   3. ARM expires after ARM_TTL; destructive verbs require a live arm.
//!
//! Frictions that survive YOLO (deliberate):
//!   - verb-only API (no shell, no argv injection)
//!   - hold-to-commit is enforced by the GAME; the Oracle adds its own rule:
//!     destructive verbs require an armed session (fresh ARM)
//!   - every verb is logged to a write-ahead log BEFORE execution
//!   - cold re-arm: the socket dies with the process; nothing persists
//!
//! Build:  cargo build --release
//! Run (spawned by frameshiftd under sudo):
//!   sudo -S kernel-oracle --socket /run/user/$UID/wopr-oracle.sock

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const ARM_TTL: Duration = Duration::from_secs(120);
const MAX_MSG: usize = 64 * 1024;

/// Paths the Oracle will NEVER erase, even armed. Deliberately short: the
/// Oracle's promise is root-level power, not root-level safety. These are
/// excluded only because they break the machine mid-play in ways a rollback
/// cannot fix while the machine is running (no gameplay value, pure brick).
const NEVER_ERASE: &[&str] = &[
    "/", "/bin", "/boot", "/dev", "/etc", "/lib", "/proc", "/root", "/run",
    "/sbin", "/sys", "/usr",
];

/// Famous footguns: destructible, but only with the extra `--i-know` flag,
/// on top of the armed-session requirement.
const NEAR_FOOTGUN: &[&str] = &[
    "/home", "/var", "/etc/passwd", "/etc/shadow", "/etc/fstab", "/home/michael",
];

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

struct Oracle {
    armed_at: Option<Instant>,
    snapshot_id: Option<String>,
    log: Box<dyn Write + Send>,
}

impl Oracle {
    fn open_log() -> Box<dyn Write + Send> {
        // WAL lives under the runtime dir; if unwritable, fall back to stderr.
        let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
        let path = format!("{dir}/wopr-oracle.log");
        match OpenOptions::new().create(true).append(true).open(&path) {
            Ok(f) => Box::new(f),
            Err(_) => Box::new(std::io::stderr()),
        }
    }

    fn log_line(&mut self, line: &str) {
        let stamp = now();
        let _ = writeln!(self.log, "[{stamp}] {line}");
        let _ = self.log.flush(); // write-AHEAD: the log lands before the verb runs
    }

    fn armed(&self) -> bool {
        match self.armed_at {
            Some(t) => t.elapsed() < ARM_TTL,
            None => false,
        }
    }

    /// The snapshot ritual: at least one real snapper snapshot must exist.
    /// Returns its number (newest) or None.
    fn newest_snapshot(&self) -> Option<u32> {
        let out = Command::new("snapper")
            .args(["-c", "root", "list", "--columns", "number"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        // snapper lists oldest first; last numeric row (skipping 0 = "current")
        let mut newest: Option<u32> = None;
        for line in text.lines().skip(1) {
            let Ok(num) = line.split_whitespace().next().unwrap_or("").parse::<u32>() else {
                continue;
            };
            if num > 0 {
                newest = Some(num);
            }
        }
        newest
    }

    fn cmd_arm(&mut self) -> String {
        // The incantation was already spent by the sudo that spawned us.
        // Enforce the rest of the ritual: a snapshot must exist.
        match self.newest_snapshot() {
            None => {
                self.log_line("ARM refused: no snapper snapshots exist");
                err("no snapshots: create one first — snapshot create wopr-arming")
            }
            Some(id) => {
                self.armed_at = Some(Instant::now());
                self.snapshot_id = Some(id.to_string());
                self.log_line(&format!("ARMED. rollback anchor snapshot #{id}"));
                ok(&format!(
                    "armed. rollback anchor: snapshot #{id}. TTL {}s",
                    ARM_TTL.as_secs()
                ))
            }
        }
    }

    fn cmd_disarm(&mut self) -> String {
        self.armed_at = None;
        self.log_line("DISARMED");
        ok("disarmed")
    }

    fn require_arm(&self, verb: &str) -> Option<String> {
        if self.armed() {
            None
        } else {
            Some(err(&format!(
                "{verb} requires an armed oracle (ARM + snapshot ritual)"
            )))
        }
    }

    fn cmd_kill(&mut self, args: &[&str]) -> String {
        // kill <pid> <sig> — armed kills cross the ownership wall.
        let (Some(pid_s), Some(sig_s)) = (args.first(), args.get(1)) else {
            return err("usage: kill <pid> <sig>");
        };
        let (Ok(pid), Ok(sig)) = (pid_s.parse::<i32>(), sig_s.parse::<i32>()) else {
            return err("pid and sig must be integers");
        };
        // no broadcast kills, no init, no kernel threads
        if pid <= 1 || !(1..=64).contains(&sig) {
            return err("refusing: pid<=1 (or broadcast) or sig out of range");
        }
        if let Some(e) = self.require_arm("kill") {
            return e;
        }
        self.log_line(&format!("kill({pid}, {sig})"));
        match Command::new("kill")
            .arg("-s")
            .arg(sig.to_string())
            .arg(pid.to_string())
            .status()
        {
            Ok(s) if s.success() => ok(&format!("kill({pid}, {sig})")),
            Ok(s) => err(&format!("kill failed: exit {s}")),
            Err(e) => err(&format!("kill failed: {e}")),
        }
    }

    fn cmd_systemctl(&mut self, args: &[&str]) -> String {
        // systemctl <action> <unit> — action allowlist, unit name validated.
        const ACTIONS: &[&str] = &[
            "start", "stop", "restart", "enable", "disable", "mask", "unmask",
        ];
        let (Some(action), Some(unit)) = (args.first(), args.get(1)) else {
            return err("usage: systemctl <action> <unit>");
        };
        if !ACTIONS.contains(action) {
            return err("action not on allowlist");
        }
        if unit.is_empty()
            || !unit
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_.@:".contains(c))
        {
            return err("unit name has forbidden characters");
        }
        if let Some(e) = self.require_arm("systemctl") {
            return e;
        }
        self.log_line(&format!("systemctl {action} {unit}"));
        match Command::new("systemctl").arg(action).arg(unit).status() {
            Ok(s) if s.success() => ok(&format!("systemctl {action} {unit}")),
            Ok(s) => err(&format!("systemctl failed: exit {s}")),
            Err(e) => err(&format!("systemctl failed: {e}")),
        }
    }

    fn cmd_modprobe(&mut self, args: &[&str]) -> String {
        // modprobe [-r] <module>
        let (remove, module) = match args {
            ["-r", m] => (true, *m),
            [m] => (false, *m),
            _ => return err("usage: modprobe [-r] <module>"),
        };
        if module.is_empty()
            || !module
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return err("module name has forbidden characters");
        }
        if let Some(e) = self.require_arm("modprobe") {
            return e;
        }
        self.log_line(&format!("modprobe {}{module}", if remove { "-r " } else { "" }));
        let mut c = Command::new("modprobe");
        if remove {
            c.arg("-r");
        }
        match c.arg(module).status() {
            Ok(s) if s.success() => ok(&format!("modprobe {module}")),
            Ok(s) => err(&format!("modprobe failed: exit {s}")),
            Err(e) => err(&format!("modprobe failed: {e}")),
        }
    }

    fn cmd_rm(&mut self, args: &[&str]) -> String {
        // rm <path> [--i-know] — path may be single-quoted to carry spaces
        let raw = match args.first() {
            Some(p) => *p,
            None => return err("usage: rm <path> [--i-know]"),
        };
        let raw = raw
            .strip_prefix('\'')
            .and_then(|s| s.strip_suffix('\''))
            .unwrap_or(raw);
        let i_know = args.contains(&"--i-know");
        let canonical = match Path::new(raw).canonicalize() {
            Ok(p) => p,
            Err(_) => return err("no such path"),
        };
        let cpath = canonical.to_string_lossy().to_string();
        // NEVER_ERASE blocks the exact directory only — subpaths of /usr/share
        // etc. are legitimate gameplay verbs. The list is short on purpose:
        // this is YOLO, not the daemon's tier-2 guard list.
        if NEVER_ERASE.contains(&cpath.as_str()) {
            self.log_line(&format!("REFUSED rm {cpath} (never-erase list)"));
            return err(&format!("refused forever: {cpath}"));
        }
        if NEAR_FOOTGUN.contains(&cpath.as_str()) && !i_know {
            return err(&format!("{cpath} is a famous footgun; repeat with --i-know"));
        }
        // The snapshot store is destructible BY DESIGN (the README says so),
        // but the Oracle logs it loudly and demands --i-know.
        if (cpath.contains("/.snapshots") || cpath.starts_with("/@")) && !i_know {
            return err("that path is snapshot/subvolume territory; --i-know");
        }
        if let Some(e) = self.require_arm("rm") {
            return e;
        }
        if cpath.contains("/.snapshots") || cpath.starts_with("/@") {
            self.log_line(&format!("!!! erasing snapshot/subvolume territory: {cpath}"));
        }
        self.log_line(&format!("rm -rf {cpath}"));
        match Command::new("rm").arg("-rf").arg("--").arg(&canonical).status() {
            Ok(s) if s.success() => ok(&format!("rm -rf {cpath}")),
            Ok(s) => err(&format!("rm failed: exit {s}")),
            Err(e) => err(&format!("rm failed: {e}")),
        }
    }

    fn cmd_snapshot(&mut self, args: &[&str]) -> String {
        // snapshot create [desc] | rollback <id> | list
        match args {
            ["create", rest @ ..] => {
                let desc = if rest.is_empty() {
                    "wopr".to_string()
                } else {
                    rest.join(" ")
                };
                self.log_line(&format!("snapper create ({desc})"));
                match Command::new("snapper")
                    .args(["-c", "root", "create", "-c", "pre", "-d"])
                    .arg(&desc)
                    .output()
                {
                    Ok(o) if o.status.success() => {
                        ok(&String::from_utf8_lossy(&o.stdout).trim().to_string())
                    }
                    Ok(o) => err(&String::from_utf8_lossy(&o.stderr).trim().to_string()),
                    Err(e) => err(&format!("snapper failed: {e}")),
                }
            }
            ["rollback", id] => {
                let Ok(_idn) = id.parse::<u32>() else {
                    return err("snapshot id must be numeric");
                };
                if let Some(e) = self.require_arm("rollback") {
                    return e;
                }
                // Live rollback of a mounted rootfs is impossible; the honest
                // verb stages the reboot and says so.
                self.log_line(&format!("rollback staged to #{id}"));
                ok(&format!(
                    "rollback to #{id} staged: reboot and pick the snapshot from the bootloader (grub → snapshots). live rollback is impossible on a mounted rootfs"
                ))
            }
            ["list"] => match Command::new("snapper").args(["-c", "root", "list"]).output() {
                Ok(o) if o.status.success() => ok(&String::from_utf8_lossy(&o.stdout)),
                Ok(o) => err(&String::from_utf8_lossy(&o.stderr).trim().to_string()),
                Err(e) => err(&format!("snapper failed: {e}")),
            },
            _ => err("usage: snapshot create [desc] | rollback <id> | list"),
        }
    }

    fn dispatch(&mut self, line: &str) -> String {
        let mut parts = line.split_whitespace();
        let Some(verb) = parts.next() else {
            return err("empty request");
        };
        let args: Vec<&str> = parts.collect();
        match verb {
            "PING" => ok("pong"),
            "STATUS" => ok(&format!(
                "armed={} snapshot={}",
                self.armed(),
                self.snapshot_id.clone().unwrap_or_else(|| "-".into())
            )),
            "ARM" => self.cmd_arm(),
            "DISARM" => self.cmd_disarm(),
            "kill" => self.cmd_kill(&args),
            "systemctl" => self.cmd_systemctl(&args),
            "modprobe" => self.cmd_modprobe(&args),
            "rm" => self.cmd_rm(&args),
            "snapshot" => self.cmd_snapshot(&args),
            other => err(&format!("unknown verb: {other}")),
        }
    }
}

fn ok(msg: &str) -> String {
    format!("{{\"ok\": true, \"result\": {}}}", json_str(msg))
}
fn err(msg: &str) -> String {
    format!("{{\"ok\": false, \"error\": {}}}", json_str(msg))
}
/// minimal JSON string escaping (no serde on purpose: zero deps, small audit surface)
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn handle_conn(conn: UnixStream, oracle: &mut Oracle) -> std::io::Result<()> {
    // One request per connection. Access control is the filesystem: the
    // socket lives in the root-owned runtime path at 0600, so only root
    // (i.e. the daemon's own sudo-spawned proxy) can connect.
    conn.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut line = String::new();
    {
        let mut reader = BufReader::new(conn.try_clone()?);
        let n = reader.read_line(&mut line)?;
        if n == 0 || n > MAX_MSG {
            return Ok(());
        }
    }
    let reply = oracle.dispatch(line.trim_end());
    let mut conn = conn;
    conn.write_all(reply.as_bytes())?;
    conn.write_all(b"\n")?;
    conn.flush()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let socket = args
        .iter()
        .position(|a| a == "--socket")
        .and_then(|i| args.get(i + 1))
        .cloned()
        .unwrap_or_else(|| {
            let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
            format!("{dir}/wopr-oracle.sock")
        });

    if getuid() != 0 {
        eprintln!("kernel-oracle must run as root (spawned via sudo by frameshiftd)");
        std::process::exit(1);
    }

    let _ = fs::remove_file(&socket); // stale socket from a dead session
    let listener = match UnixListener::bind(&socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cannot bind {socket}: {e}");
            std::process::exit(1);
        }
    };
    // The daemon that connects runs as the *invoking user*, not root.
    // chown the socket to whoever spent the sudo password (SUDO_UID) and
    // keep it 0600: exactly one user may talk to the Oracle — the one who
    // armed it. No other user on the box can connect.
    let _ = fs::set_permissions(&socket, fs::Permissions::from_mode(0o600));
    if let (Ok(uid_s), Ok(gid_s)) = (
        std::env::var("SUDO_UID"),
        std::env::var("SUDO_GID"),
    ) {
        use std::os::unix::fs::chown;
        if let (Ok(uid), Ok(gid)) = (uid_s.parse::<u32>(), gid_s.parse::<u32>()) {
            let _ = chown(&socket, Some(uid), Some(gid));
        }
    }

    let mut oracle = Oracle {
        armed_at: None,
        snapshot_id: None,
        log: Oracle::open_log(),
    };
    oracle.log_line(&format!("oracle listening on {socket}"));
    eprintln!("kernel-oracle listening on {socket}");

    for conn in listener.incoming() {
        match conn {
            Ok(c) => {
                let _ = handle_conn(c, &mut oracle);
            }
            Err(_) => continue,
        }
    }
}

/// tiny libc shim without the libc crate (zero deps on purpose)
fn getuid() -> u32 {
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    unsafe { getuid() }
}
