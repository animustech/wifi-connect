# Conditional WiFi Reconnect + Wired-Connection Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While wifi-connect's AP/captive-portal is running, periodically retry saved WiFi networks that are currently in range (most-recently-connected first); and, independently, teach `start.sh` to skip launching wifi-connect at all when a wired connection is already up.

**Architecture:** Two independent changes. (1) `src/network.rs` gains a new periodic `NetworkCommand::Reconnect`, driven by a timer thread, that walks NetworkManager connection profiles ordered by last-successful-connection time — as tracked by wifi-connect itself in a small local cache module, `src/reconnect_history.rs` — and tries to `activate()` each one currently visible in a scan, reusing the existing stop-portal/attempt/restore-portal shape already used by the manual `connect()` path. (2) `scripts/start.sh` gets a wired-interface check (via `ip`, sysfs-backed) added ahead of its existing WiFi check, with a short bounded wait for DHCP to settle — a one-time, boot-only decision; no wired-awareness is added to the Rust binary itself.

**Tech Stack:** Rust 2015-edition binary crate (`clap` 2.x, `error-chain` 0.12, `network-manager` via git dependency, `serde`/`serde_json` — all already existing dependencies, no Cargo.toml changes needed anywhere in this plan), Bash (`start.sh`), Debian container image (`Dockerfile.template`).

## Global Constraints

- Spec: `docs/specs/2026-08-10-conditional-wifi-reconnect.md`. Every acceptance criterion (AC1–AC10) in that file must be traceable to a task below.
- `README.md` must not be modified (spec non-goal).
- No wired-connection code is added to `src/`. All wired-awareness lives in `scripts/start.sh` as a single, one-time, boot-only check (spec AC1/AC2). Do not add polling, a config flag, or a periodic re-check for wired state to the Rust binary.
- New config surface uses the shared `RECONNECT_*` namespace: `--reconnect-enabled` / `$RECONNECT_ENABLED` (default `true`) and `--reconnect-interval-minutes` / `$RECONNECT_INTERVAL_MINUTES` (default `30`), following the existing `--portal-*` / `$PORTAL_*` pattern in `src/config.rs`. This is already implemented (Task 2, complete) — nothing further to do for it.
- **Reconnect ordering is tracked by wifi-connect itself, not read from NetworkManager.** Upstream's `network-manager` crate reads but discards NetworkManager's own `connection.timestamp` D-Bus property, and exposing it would require vendoring/patching that crate — considered and rejected (see [ADR 0008](/opt/adi/adr/0008-per-service-volume-standardized-data-mount.md) and `docs/specs/2026-08-10-conditional-wifi-reconnect.md`'s Non-goals). Instead, `src/reconnect_history.rs` maintains its own small JSON cache at a fixed path, `/data/reconnect-history.json`, per ADR 0008. **No CLI flag/env var for this path** — it is not configurable.
- Per ADR 0008, `/data` is a dedicated Docker volume mounted only into wifi-connect's own container (a companion change to `loci-on-balena`'s `docker-compose.yml`, outside this repo — not part of this plan). Code in this repo must not assume any other service can see this path, and must not write anywhere else.
- **Cache writes must be crash-safe and infrequent.** These devices have no UPS and typically use SD/eMMC storage that balena's own docs warn is prone to corruption under write-heavy workloads. Writes happen only on a successful connection (write-temp-file-then-rename, never in-place), never on every timer tick or failed attempt. A missing or corrupt cache file on read is treated as empty history — logged, never a crash.
- **`src/reconnect_history.rs` is pure and fully unit-testable** (plain `std::fs`/`serde_json` file I/O, no D-Bus/NetworkManager involved) — implement it with real TDD and `#[cfg(test)]` tests. This is different from the rest of `src/network.rs`, where **no unit-test harness exists today for anything touching NetworkManager D-Bus** (`src/network.rs` has zero `#[cfg(test)]` modules, and the `network-manager` crate's `Connection`/`AccessPoint` types cannot be constructed outside a live D-Bus session — `Connection`'s fields are private and its only constructor calls into D-Bus; `AccessPoint`'s `ssid: Ssid` field is public but `Ssid` itself is not part of the crate's public API, so it can't be named or constructed from `src/`). This is a pre-existing structural limitation, not something introduced here — do not add a mocking/trait-abstraction layer to work around it; that is out of scope. Tasks touching `src/network.rs` are gated on `cargo build`/`cargo check` succeeding, plus an explicit manual verification protocol on a real NetworkManager host.
- **This is ultimately a container workload (loci-on-balena, running on a Raspberry Pi 5) — build and test through Docker Desktop, not a host-installed Rust toolchain.** The host has no `cargo`/`rustc` on `PATH` and none should be installed for this work. Docker Desktop is available (`docker context show` → `desktop-linux`; host/daemon arch `linux/arm64`, which matches the Rpi5 target natively — no QEMU emulation needed for the build/test loop). Every `cargo` invocation in this plan runs inside a `rust:1.76-bullseye` container (matches CI's `rust_toolchain: 1.76` and the `debian:bullseye` runtime base in `Dockerfile.template`), using this exact helper — define it once per shell session, reuse for every build/test step below:

  ```bash
  dc_cargo() {
      docker run --rm \
          -v "$(pwd)":/usr/src/app -w /usr/src/app \
          -v wifi-connect-cargo-registry:/usr/local/cargo/registry \
          -v wifi-connect-cargo-git:/usr/local/cargo/git \
          rust:1.76-bullseye \
          "$@"
  }
  ```

  The two named volumes cache the crates.io/git dependency downloads across invocations (including the `network-manager` git fetch) without writing anything outside the container or the repo's already-`.gitignore`d `/target/`. `Cargo.lock` is already committed and CI-validated — do not run `cargo update`; a plain `dc_cargo cargo build` resolves against the locked versions. Example: `dc_cargo cargo build`, `dc_cargo cargo test`, `dc_cargo cargo tree`.

---

## File Structure

- **Create `src/reconnect_history.rs`** — a small, pure, fully unit-tested module maintaining a local JSON cache of `{ssid: last-successful-connection-unix-timestamp}` at `/data/reconnect-history.json` (fixed path, per ADR 0008). Crash-safe (write-temp-then-rename) writes, corrupt/missing file treated as empty history.
- **Modify `src/main.rs`** — add `mod reconnect_history;`.
- **Modify `src/config.rs`** — add `reconnect_enabled: bool` and `reconnect_interval_minutes: u64` to `Config`, with CLI/env parsing. **Already done (Task 2, complete).**
- **Modify `docs/command-line-arguments.md`** — document the two new options. **Already done (Task 2, complete).**
- **Modify `src/network.rs`** — add `NetworkCommand::Reconnect`, a periodic-timer spawn function, a `run_loop` match arm, a `reconnect_history: ReconnectHistory` field on `NetworkCommandHandler`, and the `reconnect()` / `get_reconnect_candidates()` methods; extract a shared `confirm_connectivity_and_log` helper and make both `connect()` and `reconnect()` record successes into the cache.
- **Modify `scripts/start.sh`** — add a wired-connection check (with bounded DHCP-settle wait) ahead of the existing WiFi check.
- **Modify `Dockerfile.template`** — add the `iproute2` package (needed by `start.sh`'s new `ip` invocation).
- **Create `docs/how-wifi-connect-works.md`** — high-level overview doc, in the style of the existing `docs/*.md` files, covering the new behavior. `README.md` itself is untouched.

No `Cargo.toml`/`Cargo.lock` changes anywhere in this plan — `serde`, `serde_derive`, and `serde_json` are already dependencies, and `std::fs`/`std::path`/`std::time` are standard library.

---

### Task 1: Implement the reconnect-history cache module

**Files:**
- Create: `src/reconnect_history.rs`
- Modify: `src/main.rs`

**Interfaces:**
- Produces: `pub const reconnect_history::HISTORY_FILE_PATH: &str = "/data/reconnect-history.json"`; `pub struct ReconnectHistory`; `ReconnectHistory::load(path: &Path) -> ReconnectHistory`; `ReconnectHistory::record_success(&mut self, ssid: &str, path: &Path)`; `ReconnectHistory::last_connected(&self, ssid: &str) -> Option<u64>`. Consumed by Task 3.

This module is pure (no D-Bus/NetworkManager) — implement it with real TDD: write each test first, watch it fail for the right reason, then implement.

- [ ] **Step 1: Write the failing tests**

Create `src/reconnect_history.rs` with just the test module first:

```rust
use serde_json;

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub const HISTORY_FILE_PATH: &str = "/data/reconnect-history.json";

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;

    fn temp_history_path(test_name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "wifi-connect-test-{}-{}-{}.json",
            test_name,
            process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn load_missing_file_returns_empty_history() {
        let path = temp_history_path("missing");

        let history = ReconnectHistory::load(&path);

        assert_eq!(history.last_connected("AnySsid"), None);
    }

    #[test]
    fn load_corrupt_file_returns_empty_history() {
        let path = temp_history_path("corrupt");
        fs::write(&path, "not valid json{{{").unwrap();

        let history = ReconnectHistory::load(&path);

        assert_eq!(history.last_connected("AnySsid"), None);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn record_success_then_reload_round_trips() {
        let path = temp_history_path("roundtrip");

        let mut history = ReconnectHistory::default();
        history.record_success("HomeWifi", &path);

        let reloaded = ReconnectHistory::load(&path);
        let timestamp = reloaded.last_connected("HomeWifi");

        assert!(timestamp.is_some());
        assert!(timestamp.unwrap() > 0);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn last_connected_is_none_for_unrecorded_ssid() {
        let path = temp_history_path("unrecorded");

        let mut history = ReconnectHistory::default();
        history.record_success("HomeWifi", &path);

        assert_eq!(history.last_connected("SomeOtherSsid"), None);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn record_success_updates_existing_entry() {
        let path = temp_history_path("update");

        let mut history = ReconnectHistory::default();
        history.record_success("HomeWifi", &path);
        let first = history.last_connected("HomeWifi").unwrap();

        std::thread::sleep(std::time::Duration::from_millis(1100));
        history.record_success("HomeWifi", &path);
        let second = history.last_connected("HomeWifi").unwrap();

        assert!(second >= first);

        let _ = fs::remove_file(&path);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail for the right reason (missing types)**

```bash
dc_cargo cargo test --lib reconnect_history 2>&1 | tail -40
```

Expected: FAILS to compile — `ReconnectHistory` (and its methods `load`, `record_success`, `last_connected`, `Default`) don't exist yet. This is the expected red state.

- [ ] **Step 3: Implement `ReconnectHistory`**

Add above the `#[cfg(test)]` module (i.e. right after the `HISTORY_FILE_PATH` constant):

```rust
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct ReconnectHistory {
    last_connected: HashMap<String, u64>,
}

impl ReconnectHistory {
    /// Loads the cache from `path`. A missing or corrupt file is treated as
    /// empty history — never a hard error, since losing this cache must
    /// never prevent wifi-connect from running.
    pub fn load(path: &Path) -> Self {
        let contents = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(_) => {
                debug!(
                    "No reconnect history file at '{}' yet - starting fresh",
                    path.display()
                );
                return Self::default();
            }
        };

        match serde_json::from_str(&contents) {
            Ok(history) => history,
            Err(e) => {
                warn!(
                    "Reconnect history file '{}' is corrupt, starting fresh: {}",
                    path.display(),
                    e
                );
                Self::default()
            }
        }
    }

    /// Records `ssid` as successfully connected right now, and persists the
    /// updated cache to `path` (best-effort — a write failure is logged, not
    /// propagated, since it must never block the connection this just made).
    pub fn record_success(&mut self, ssid: &str, path: &Path) {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        self.last_connected.insert(ssid.to_string(), timestamp);

        self.save(path);
    }

    /// Seconds since the Unix epoch this SSID was last successfully
    /// connected to by wifi-connect, or `None` if never recorded.
    pub fn last_connected(&self, ssid: &str) -> Option<u64> {
        self.last_connected.get(ssid).copied()
    }

    fn save(&self, path: &Path) {
        let json = match serde_json::to_string(self) {
            Ok(json) => json,
            Err(e) => {
                error!("Serializing reconnect history failed: {}", e);
                return;
            }
        };

        if let Some(parent) = path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                error!(
                    "Creating reconnect history directory '{}' failed: {}",
                    parent.display(),
                    e
                );
                return;
            }
        }

        let tmp_path = path.with_extension("tmp");

        if let Err(e) = fs::write(&tmp_path, &json) {
            error!(
                "Writing reconnect history temp file '{}' failed: {}",
                tmp_path.display(),
                e
            );
            return;
        }

        if let Err(e) = fs::rename(&tmp_path, path) {
            error!("Renaming reconnect history temp file into place failed: {}", e);
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
dc_cargo cargo test --lib reconnect_history 2>&1 | tail -40
```

Expected: PASS — all 5 tests green (`load_missing_file_returns_empty_history`, `load_corrupt_file_returns_empty_history`, `record_success_then_reload_round_trips`, `last_connected_is_none_for_unrecorded_ssid`, `record_success_updates_existing_entry`).

- [ ] **Step 5: Register the module**

In `src/main.rs`, find:

```rust
mod config;
mod dnsmasq;
mod errors;
mod exit;
mod logger;
mod network;
mod privileges;
mod server;
```

Replace with:

```rust
mod config;
mod dnsmasq;
mod errors;
mod exit;
mod logger;
mod network;
mod privileges;
mod reconnect_history;
mod server;
```

- [ ] **Step 6: Full build (via Docker — see Global Constraints for `dc_cargo`)**

```bash
dc_cargo cargo build 2>&1 | tail -40
```

Expected: succeeds. `reconnect_history` is not yet used anywhere outside its own tests (Task 3 wires it up), so expect an `unused` warning for the module at this point — that's fine and temporary, Task 3 resolves it.

- [ ] **Step 7: Commit**

```bash
git add src/reconnect_history.rs src/main.rs
git commit -m "feat: add local reconnect-history cache for periodic-reconnect ordering"
```

---

### Task 2: Add `RECONNECT_ENABLED` / `RECONNECT_INTERVAL_MINUTES` configuration

**Files:**
- Modify: `src/config.rs`
- Modify: `docs/command-line-arguments.md`

**Interfaces:**
- Produces: `Config.reconnect_enabled: bool`, `Config.reconnect_interval_minutes: u64`. Consumed by Task 3.

- [ ] **Step 1: Add the two constants**

In `src/config.rs`, find:

```rust
const DEFAULT_LISTENING_PORT: &str = "80";
```

Replace with:

```rust
const DEFAULT_LISTENING_PORT: &str = "80";
const DEFAULT_RECONNECT_ENABLED: &str = "true";
const DEFAULT_RECONNECT_INTERVAL_MINUTES: &str = "30";
```

- [ ] **Step 2: Add fields to `Config`**

Find:

```rust
#[derive(Clone)]
pub struct Config {
    pub interface: Option<String>,
    pub ssid: String,
    pub passphrase: Option<String>,
    pub gateway: Ipv4Addr,
    pub dhcp_range: String,
    pub listening_port: u16,
    pub activity_timeout: u64,
    pub ui_directory: PathBuf,
}
```

Replace with:

```rust
#[derive(Clone)]
pub struct Config {
    pub interface: Option<String>,
    pub ssid: String,
    pub passphrase: Option<String>,
    pub gateway: Ipv4Addr,
    pub dhcp_range: String,
    pub listening_port: u16,
    pub activity_timeout: u64,
    pub ui_directory: PathBuf,
    pub reconnect_enabled: bool,
    pub reconnect_interval_minutes: u64,
}
```

- [ ] **Step 3: Add the two CLI arguments**

Find:

```rust
        .arg(
            Arg::with_name("ui-directory")
                .short("u")
                .long("ui-directory")
                .value_name("ui_directory")
                .help(&format!(
                    "Web UI directory location (default: {})",
                    DEFAULT_UI_DIRECTORY
                ))
                .takes_value(true),
        )
        .get_matches();
```

Replace with:

```rust
        .arg(
            Arg::with_name("ui-directory")
                .short("u")
                .long("ui-directory")
                .value_name("ui_directory")
                .help(&format!(
                    "Web UI directory location (default: {})",
                    DEFAULT_UI_DIRECTORY
                ))
                .takes_value(true),
        )
        .arg(
            Arg::with_name("reconnect-enabled")
                .long("reconnect-enabled")
                .value_name("reconnect_enabled")
                .help(&format!(
                    "Periodically retry saved WiFi networks in range while the captive portal is active (true/false) (default: {})",
                    DEFAULT_RECONNECT_ENABLED
                ))
                .takes_value(true),
        )
        .arg(
            Arg::with_name("reconnect-interval-minutes")
                .long("reconnect-interval-minutes")
                .value_name("reconnect_interval_minutes")
                .help(&format!(
                    "Minutes between periodic reconnect attempts (default: {})",
                    DEFAULT_RECONNECT_INTERVAL_MINUTES
                ))
                .takes_value(true),
        )
        .get_matches();
```

- [ ] **Step 4: Parse the two values and include them in the returned `Config`**

Find:

```rust
    let ui_directory = get_ui_directory(matches.value_of("ui-directory"));

    Config {
        interface,
        ssid,
        passphrase,
        gateway,
        dhcp_range,
        listening_port,
        activity_timeout,
        ui_directory,
    }
}
```

Replace with:

```rust
    let ui_directory = get_ui_directory(matches.value_of("ui-directory"));

    let reconnect_enabled = bool::from_str(&matches.value_of("reconnect-enabled").map_or_else(
        || env::var("RECONNECT_ENABLED").unwrap_or_else(|_| DEFAULT_RECONNECT_ENABLED.to_string()),
        String::from,
    ))
    .expect("Cannot parse reconnect enabled flag");

    let reconnect_interval_minutes = u64::from_str(
        &matches.value_of("reconnect-interval-minutes").map_or_else(
            || {
                env::var("RECONNECT_INTERVAL_MINUTES")
                    .unwrap_or_else(|_| DEFAULT_RECONNECT_INTERVAL_MINUTES.to_string())
            },
            String::from,
        ),
    )
    .expect("Cannot parse reconnect interval minutes");

    Config {
        interface,
        ssid,
        passphrase,
        gateway,
        dhcp_range,
        listening_port,
        activity_timeout,
        ui_directory,
        reconnect_enabled,
        reconnect_interval_minutes,
    }
}
```

- [ ] **Step 5: Document the new options**

In `docs/command-line-arguments.md`, find:

```markdown
*   **-u, --ui-directory** ui_directory, **$UI_DIRECTORY**

    Web UI directory location

    Default: _ui_
```

Replace with:

```markdown
*   **-u, --ui-directory** ui_directory, **$UI_DIRECTORY**

    Web UI directory location

    Default: _ui_

*   **--reconnect-enabled** reconnect_enabled, **$RECONNECT_ENABLED**

    Periodically retry saved WiFi networks in range while the captive portal is active (true/false)

    Default: _true_

*   **--reconnect-interval-minutes** reconnect_interval_minutes, **$RECONNECT_INTERVAL_MINUTES**

    Minutes between periodic reconnect attempts

    Default: _30_
```

- [ ] **Step 6: Build and verify (via Docker — see Global Constraints for `dc_cargo`)**

```bash
dc_cargo cargo build 2>&1 | tail -40
dc_cargo cargo run --bin wifi-connect -- --help
```

Expected: build succeeds; `--help` output lists `--reconnect-enabled` and `--reconnect-interval-minutes` with the help text above. (`--help` is handled by `clap` before `require_root()`/`init_networking()` run, so this is safe to run without root or a live NetworkManager — no `--privileged`/D-Bus setup needed for this check.)

- [ ] **Step 7: Commit**

```bash
git add src/config.rs docs/command-line-arguments.md
git commit -m "feat(config): add RECONNECT_ENABLED and RECONNECT_INTERVAL_MINUTES"
```

---

### Task 3: Implement periodic reconnect in the network command handler

**Files:**
- Modify: `src/network.rs`

**Interfaces:**
- Consumes: `Config.reconnect_enabled: bool`, `Config.reconnect_interval_minutes: u64` (Task 2); `reconnect_history::HISTORY_FILE_PATH`, `reconnect_history::ReconnectHistory` with `load`/`record_success`/`last_connected` (Task 1).
- Produces: `NetworkCommand::Reconnect` variant; `NetworkCommandHandler.reconnect_history: ReconnectHistory` field; `NetworkCommandHandler::reconnect(&mut self) -> Result<bool>`; `NetworkCommandHandler::get_reconnect_candidates(&self) -> Result<Vec<Connection>>`; free function `confirm_connectivity_and_log(manager: &NetworkManager)` (also used by the existing `connect()`, replacing its inline duplicate of the same logic).

- [ ] **Step 1: Add the new imports**

Find (the top of `src/network.rs`):

```rust
use std::collections::HashSet;
use std::net::Ipv4Addr;
use std::process;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;
use std::time::Duration;

use network_manager::{
    AccessPoint, AccessPointCredentials, Connection, ConnectionState, Connectivity, Device,
    DeviceState, DeviceType, NetworkManager, Security, ServiceState,
};

use config::Config;
use dnsmasq::{start_dnsmasq, stop_dnsmasq};
use errors::*;
use exit::{exit, trap_exit_signals, ExitResult};
use server::start_server;
```

Replace with:

```rust
use std::collections::HashSet;
use std::net::Ipv4Addr;
use std::path::Path;
use std::process;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;
use std::time::Duration;

use network_manager::{
    AccessPoint, AccessPointCredentials, Connection, ConnectionState, Connectivity, Device,
    DeviceState, DeviceType, NetworkManager, Security, ServiceState,
};

use config::Config;
use dnsmasq::{start_dnsmasq, stop_dnsmasq};
use errors::*;
use exit::{exit, trap_exit_signals, ExitResult};
use reconnect_history::{ReconnectHistory, HISTORY_FILE_PATH};
use server::start_server;
```

- [ ] **Step 2: Add the `reconnect_history` field to `NetworkCommandHandler`**

Find:

```rust
struct NetworkCommandHandler {
    manager: NetworkManager,
    device: Device,
    access_points: Vec<AccessPoint>,
    portal_connection: Option<Connection>,
    config: Config,
    dnsmasq: process::Child,
    server_tx: Sender<NetworkCommandResponse>,
    network_rx: Receiver<NetworkCommand>,
    activated: bool,
}
```

Replace with:

```rust
struct NetworkCommandHandler {
    manager: NetworkManager,
    device: Device,
    access_points: Vec<AccessPoint>,
    portal_connection: Option<Connection>,
    config: Config,
    dnsmasq: process::Child,
    server_tx: Sender<NetworkCommandResponse>,
    network_rx: Receiver<NetworkCommand>,
    activated: bool,
    reconnect_history: ReconnectHistory,
}
```

- [ ] **Step 3: Add the `Reconnect` command variant**

Find:

```rust
pub enum NetworkCommand {
    Activate,
    Timeout,
    Exit,
    Connect {
        ssid: String,
        identity: String,
        passphrase: String,
    },
}
```

Replace with:

```rust
pub enum NetworkCommand {
    Activate,
    Timeout,
    Exit,
    Reconnect,
    Connect {
        ssid: String,
        identity: String,
        passphrase: String,
    },
}
```

- [ ] **Step 4: Spawn the periodic timer thread**

Find:

```rust
    fn spawn_activity_timeout(config: &Config, network_tx: Sender<NetworkCommand>) {
        let activity_timeout = config.activity_timeout;

        if activity_timeout == 0 {
            return;
        }

        thread::spawn(move || {
            thread::sleep(Duration::from_secs(activity_timeout));

            if let Err(err) = network_tx.send(NetworkCommand::Timeout) {
                error!(
                    "Sending NetworkCommand::Timeout failed: {}",
                    err.to_string()
                );
            }
        });
    }
```

Replace with:

```rust
    fn spawn_activity_timeout(config: &Config, network_tx: Sender<NetworkCommand>) {
        let activity_timeout = config.activity_timeout;

        if activity_timeout == 0 {
            return;
        }

        thread::spawn(move || {
            thread::sleep(Duration::from_secs(activity_timeout));

            if let Err(err) = network_tx.send(NetworkCommand::Timeout) {
                error!(
                    "Sending NetworkCommand::Timeout failed: {}",
                    err.to_string()
                );
            }
        });
    }

    // Boot-time-only wired-connection awareness lives entirely in `scripts/start.sh`
    // (see docs/specs/2026-08-10-conditional-wifi-reconnect.md) — this handler has no
    // wired-awareness and never checks it. Treating wired-state changes as boot-time-only
    // is a deliberate simplification that may be worth revisiting later.
    fn spawn_periodic_reconnect(config: &Config, network_tx: Sender<NetworkCommand>) {
        if !config.reconnect_enabled || config.reconnect_interval_minutes == 0 {
            return;
        }

        let interval = Duration::from_secs(config.reconnect_interval_minutes * 60);

        thread::spawn(move || loop {
            thread::sleep(interval);

            if let Err(err) = network_tx.send(NetworkCommand::Reconnect) {
                error!(
                    "Sending NetworkCommand::Reconnect failed: {}",
                    err.to_string()
                );
                return;
            }
        });
    }
```

- [ ] **Step 5: Start the timer thread and load the reconnect-history cache in `NetworkCommandHandler::new`**

Find:

```rust
        Self::spawn_server(config, exit_tx, server_rx, network_tx.clone());

        Self::spawn_activity_timeout(config, network_tx);

        let config = config.clone();
        let activated = false;

        Ok(NetworkCommandHandler {
            manager,
            device,
            access_points,
            portal_connection,
            config,
            dnsmasq,
            server_tx,
            network_rx,
            activated,
        })
    }
```

Replace with:

```rust
        Self::spawn_server(config, exit_tx, server_rx, network_tx.clone());

        Self::spawn_activity_timeout(config, network_tx.clone());

        Self::spawn_periodic_reconnect(config, network_tx);

        let config = config.clone();
        let activated = false;
        let reconnect_history = ReconnectHistory::load(Path::new(HISTORY_FILE_PATH));

        Ok(NetworkCommandHandler {
            manager,
            device,
            access_points,
            portal_connection,
            config,
            dnsmasq,
            server_tx,
            network_rx,
            activated,
            reconnect_history,
        })
    }
```

- [ ] **Step 6: Handle the command in `run_loop`**

Find:

```rust
                NetworkCommand::Timeout => {
                    if !self.activated {
                        info!("Timeout reached. Exiting...");
                        return Ok(());
                    }
                }
                NetworkCommand::Exit => {
```

Replace with:

```rust
                NetworkCommand::Timeout => {
                    if !self.activated {
                        info!("Timeout reached. Exiting...");
                        return Ok(());
                    }
                }
                NetworkCommand::Reconnect => {
                    if self.reconnect()? {
                        return Ok(());
                    }
                }
                NetworkCommand::Exit => {
```

- [ ] **Step 7: Extract a shared connectivity-confirmation helper, and record successes into the cache**

`connect()` already contains a "wait for connectivity, then log success/failure" block that `reconnect()` (Step 8) needs too. Extract it once now rather than duplicating it, switch `connect()` to use it, and record this success into the reconnect-history cache — manual captive-portal connections must count too, or a network the user enters by hand would never earn recency and would always sort last in future periodic-reconnect cycles.

Find (inside the existing `connect()` method):

```rust
            match wifi_device.connect(access_point, &credentials) {
                Ok((connection, state)) => {
                    if state == ConnectionState::Activated {
                        match wait_for_connectivity(&self.manager, 20) {
                            Ok(has_connectivity) => {
                                if has_connectivity {
                                    info!("Internet connectivity established");
                                } else {
                                    warn!("Cannot establish Internet connectivity");
                                }
                            }
                            Err(err) => error!("Getting Internet connectivity failed: {}", err),
                        }

                        return Ok(true);
                    }
```

Replace with:

```rust
            match wifi_device.connect(access_point, &credentials) {
                Ok((connection, state)) => {
                    if state == ConnectionState::Activated {
                        self.reconnect_history
                            .record_success(ssid, Path::new(HISTORY_FILE_PATH));

                        confirm_connectivity_and_log(&self.manager);

                        return Ok(true);
                    }
```

(`ssid` here is `connect()`'s own `ssid: &str` parameter — already in scope.)

Find (the `wait_for_connectivity` free function, further down the file):

```rust
fn wait_for_connectivity(manager: &NetworkManager, timeout: u64) -> Result<bool> {
```

Immediately above that line, insert:

```rust
fn confirm_connectivity_and_log(manager: &NetworkManager) {
    match wait_for_connectivity(manager, 20) {
        Ok(has_connectivity) => {
            if has_connectivity {
                info!("Internet connectivity established");
            } else {
                warn!("Cannot establish Internet connectivity");
            }
        }
        Err(err) => error!("Getting Internet connectivity failed: {}", err),
    }
}

```

(i.e. the new function goes right before `wait_for_connectivity`, which it calls.)

- [ ] **Step 8: Implement `reconnect()` and `get_reconnect_candidates()`**

Find (the end of the existing `connect()` method, right before its closing brace and the following `}` that ends `impl NetworkCommandHandler`):

```rust
        self.access_points = get_access_points(&self.device)?;

        self.portal_connection = Some(create_portal(&self.device, &self.config)?);

        Ok(false)
    }
}
```

Replace with:

```rust
        self.access_points = get_access_points(&self.device)?;

        self.portal_connection = Some(create_portal(&self.device, &self.config)?);

        Ok(false)
    }

    /// Periodically-triggered reconnect: try saved WiFi networks that are currently
    /// visible in range, most-recently-connected first. Only touches the AP if there
    /// is at least one candidate to try.
    fn reconnect(&mut self) -> Result<bool> {
        let candidates = self.get_reconnect_candidates()?;

        if candidates.is_empty() {
            debug!("No saved networks currently in range - skipping periodic reconnect");
            return Ok(false);
        }

        info!(
            "Periodic reconnect: attempting {} saved network(s) in range",
            candidates.len()
        );

        if let Some(ref connection) = self.portal_connection {
            stop_portal(connection, &self.config)?;
        }

        self.portal_connection = None;

        for candidate in &candidates {
            let ssid = connection_ssid_as_str(candidate)
                .unwrap_or("<unknown>")
                .to_string();

            info!("Reconnecting to saved network '{}'...", ssid);

            match candidate.activate() {
                Ok(ConnectionState::Activated) => {
                    self.reconnect_history
                        .record_success(&ssid, Path::new(HISTORY_FILE_PATH));

                    confirm_connectivity_and_log(&self.manager);

                    return Ok(true);
                }
                Ok(state) => {
                    warn!(
                        "Reconnecting to saved network not activated '{}': {:?}",
                        ssid, state
                    );
                }
                Err(e) => {
                    warn!("Error reconnecting to saved network '{}': {}", ssid, e);
                }
            }
        }

        self.access_points = get_access_points(&self.device)?;

        self.portal_connection = Some(create_portal(&self.device, &self.config)?);

        Ok(false)
    }

    /// Saved WiFi station profiles (excludes wifi-connect's own AP/hotspot profile)
    /// whose SSID is currently visible in the last known scan, ordered by wifi-connect's
    /// own reconnect-history cache of last-successful-connection time, most recent first
    /// (networks never recorded there sort last).
    fn get_reconnect_candidates(&self) -> Result<Vec<Connection>> {
        let visible_ssids: HashSet<&str> = self
            .access_points
            .iter()
            .filter_map(|ap| ap.ssid().as_str().ok())
            .collect();

        let mut candidates: Vec<Connection> = self
            .manager
            .get_connections()?
            .into_iter()
            .filter(|c| is_wifi_connection(c) && !is_access_point_connection(c))
            .filter(|c| {
                connection_ssid_as_str(c)
                    .map(|ssid| visible_ssids.contains(ssid))
                    .unwrap_or(false)
            })
            .collect();

        let history = &self.reconnect_history;
        candidates.sort_by(|a, b| {
            let a_ts = connection_ssid_as_str(a)
                .and_then(|ssid| history.last_connected(ssid))
                .unwrap_or(0);
            let b_ts = connection_ssid_as_str(b)
                .and_then(|ssid| history.last_connected(ssid))
                .unwrap_or(0);
            b_ts.cmp(&a_ts)
        });

        Ok(candidates)
    }
}
```

- [ ] **Step 9: Build (via Docker — see Global Constraints for `dc_cargo`)**

```bash
dc_cargo cargo build 2>&1 | tail -60
```

Expected: succeeds. This writes the binary to `target/debug/wifi-connect` on the host (bind mount, not a named volume), for Step 10.

- [ ] **Step 10: Docker-based smoke test, then real-hardware verification protocol**

No automated test harness exists for this (see Global Constraints). Docker Desktop cannot exercise real WiFi hardware or a real NetworkManager scan — the Linux VM behind it has no wireless NIC — but it CAN prove the binary starts, talks to a real D-Bus/NetworkManager session, and fails gracefully rather than crashing:

```bash
mkdir -p /tmp/wifi-connect-data-smoketest
docker run --rm --network host --cap-add NET_ADMIN \
    -v "$(pwd)/target/debug/wifi-connect":/usr/local/sbin/wifi-connect:ro \
    -v "$(pwd)/ui":/usr/src/app/ui:ro \
    -v /tmp/wifi-connect-data-smoketest:/data \
    debian:bullseye bash -c '
        apt-get update -qq && apt-get install -y -qq --no-install-recommends network-manager dbus >/dev/null &&
        mkdir -p /run/dbus &&
        dbus-daemon --system --fork &&
        (NetworkManager --no-daemon &) &&
        sleep 3 &&
        UI_DIRECTORY=/usr/src/app/ui wifi-connect --reconnect-interval-minutes=1
    '
```

Note the `(NetworkManager --no-daemon &)` subshell, not a bare trailing `&` — a bare `&` on the last line of an `&&`-chain backgrounds the *entire preceding chain* (including `apt-get install`), not just `NetworkManager`, which races `wifi-connect` against an unfinished package install. Wrapping just that one command in its own backgrounded subshell keeps the rest of the chain foregrounded/sequential while only the long-running daemon gets detached.

The `/tmp/wifi-connect-data-smoketest:/data` bind mount stands in for the real per-service Docker volume from ADR 0008, so `ReconnectHistory::load`/`record_success` have somewhere to read/write during this smoke test — without it, `/data` wouldn't exist in a plain `debian:bullseye` container.

Expected: the process starts NetworkManager's D-Bus service successfully, then exits with a `NoWiFiDevice` error (there is no wireless NIC in the container) — confirming clean startup and graceful failure, not a panic or hang. This is a floor, not a substitute for the real protocol below.

On a real Linux host with NetworkManager active, real WiFi hardware, and at least two saved WiFi connection profiles for networks currently in range (a Raspberry Pi 5 running the loci-on-balena stack is the actual target — use one if available, otherwise any NetworkManager-managed Linux box with WiFi):

1. Run `wifi-connect --reconnect-interval-minutes=1` as root.
2. Confirm the AP comes up as usual and `journalctl`/stdout shows no reconnect activity for the first ~50s.
3. After ~1 minute, confirm the log shows `Periodic reconnect: attempting N saved network(s) in range`, the AP dropping, and either a successful activation (process exits 0) or the AP being recreated after all candidates fail.
4. Temporarily rename/disable all saved profiles' SSIDs out of range (or run somewhere with no saved networks in range) and confirm the log shows `No saved networks currently in range - skipping periodic reconnect` with the AP undisturbed.
5. While the AP is up, open the captive portal in a browser (triggers `NetworkCommand::Activate`) and confirm a periodic reconnect tick firing around the same time does not corrupt the UI's network list or crash the process — commands are processed serially off a single channel, so this should never race by construction.

- [ ] **Step 11: Commit**

```bash
git add src/network.rs
git commit -m "feat(network): periodically retry saved WiFi networks while AP is active"
```

---

### Task 4: Add boot-time wired-connection check to `start.sh`

**Files:**
- Modify: `scripts/start.sh`
- Modify: `Dockerfile.template`

**Interfaces:** None (shell-only, no interaction with the Rust binary).

- [ ] **Step 1: Add `iproute2` to the container image**

In `Dockerfile.template`, find:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends dnsmasq wireless-tools curl ca-certificates
```

Replace with:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends dnsmasq wireless-tools iproute2 curl ca-certificates
```

- [ ] **Step 2: Add the wired check ahead of the existing WiFi check**

In `scripts/start.sh`, find:

```bash
#!/usr/bin/env bash

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket

# Optional step - it takes couple of seconds (or longer) to establish a WiFi connection
# sometimes. In this case, following checks will fail and wifi-connect
# will be launched even if the device will be able to connect to a WiFi network.
# If this is your case, you can wait for a while and then check for the connection.
sleep 15

# Choose a condition for running WiFi Connect according to your use case:

# 1. Is there a default gateway?
# ip route | grep default

# 2. Is there Internet connectivity?
# nmcli -t g | grep full

# 3. Is there Internet connectivity via a google ping?
# wget --spider http://google.com 2>&1

# 4. Is there an active WiFi connection?
iwgetid -r

if [ $? -eq 0 ]; then
    printf 'Skipping WiFi Connect\n'
else
    printf 'Starting WiFi Connect\n'
    ./wifi-connect -s "Loci-AP-${BALENA_DEVICE_UUID:0:7}" -p "!${BALENA_DEVICE_UUID:0:7}#"
fi

# Start your application here.
sleep infinity
```

Replace with:

```bash
#!/usr/bin/env bash

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket

# True (exit 0) if any non-loopback, non-wireless interface currently has a global
# IPv4 address, i.e. a wired connection is genuinely up (not just cabled but still
# negotiating DHCP).
wired_connected() {
    for iface_path in /sys/class/net/*/; do
        iface="$(basename "$iface_path")"
        case "$iface" in
            lo|wlan*|wl*) continue ;;
        esac
        if ip -4 -o addr show dev "$iface" scope global up 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

# Wired interfaces typically finish link negotiation and DHCP faster than WiFi, so a
# short bounded wait here is enough to avoid a boot-time race against a plugged-in
# cable that just hasn't finished getting an address yet.
WIRED_CHECK_TIMEOUT=10
elapsed=0
while ! wired_connected && [ "$elapsed" -lt "$WIRED_CHECK_TIMEOUT" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
done

if wired_connected; then
    printf 'Wired connection detected - skipping WiFi Connect\n'
else
    # Optional step - it takes couple of seconds (or longer) to establish a WiFi connection
    # sometimes. In this case, following checks will fail and wifi-connect
    # will be launched even if the device will be able to connect to a WiFi network.
    # If this is your case, you can wait for a while and then check for the connection.
    sleep 15

    # Choose a condition for running WiFi Connect according to your use case:

    # 1. Is there a default gateway?
    # ip route | grep default

    # 2. Is there Internet connectivity?
    # nmcli -t g | grep full

    # 3. Is there Internet connectivity via a google ping?
    # wget --spider http://google.com 2>&1

    # 4. Is there an active WiFi connection?
    iwgetid -r

    if [ $? -eq 0 ]; then
        printf 'Skipping WiFi Connect\n'
    else
        printf 'Starting WiFi Connect\n'
        ./wifi-connect -s "Loci-AP-${BALENA_DEVICE_UUID:0:7}" -p "!${BALENA_DEVICE_UUID:0:7}#"
    fi
fi

# Start your application here.
sleep infinity
```

- [ ] **Step 3: Syntax-check, then a real positive/negative test via Docker Desktop**

The host is macOS — `/sys/class/net` and `ip` don't exist there at all, so `wired_connected` can only be meaningfully exercised inside a Linux container. Docker Desktop gives us a genuine positive case for free: a container on the default `bridge` network gets an `eth0` with a real global IPv4 address, which is indistinguishable from a wired connection as far as this function is concerned; `--network none` gives a genuine negative case (no interface but `lo`). `nicolaka/netshoot` already bundles `bash`/`ip`/`sed`, so no package install is needed at test time (important for the `--network none` case, which has no network to `apt-get` with).

```bash
bash -n scripts/start.sh
```

Expected: no output (valid syntax).

```bash
docker run --rm --network bridge \
    -v "$(pwd)/scripts/start.sh":/start.sh:ro \
    nicolaka/netshoot bash -c '
        source <(sed -n "/^wired_connected/,/^}/p" /start.sh)
        wired_connected && echo "RESULT: wired_connected=true" || echo "RESULT: wired_connected=false"
    '
```

Expected: `RESULT: wired_connected=true` (the container's `eth0` has a global bridge-network address).

```bash
docker run --rm --network none \
    -v "$(pwd)/scripts/start.sh":/start.sh:ro \
    nicolaka/netshoot bash -c '
        source <(sed -n "/^wired_connected/,/^}/p" /start.sh)
        wired_connected && echo "RESULT: wired_connected=true" || echo "RESULT: wired_connected=false"
    '
```

Expected: `RESULT: wired_connected=false` (only `lo` exists).

- [ ] **Step 4: Real-hardware verification protocol** (the one thing Docker Desktop's networking can't fake — its own IP assignment is effectively instant, so it can't exercise the bounded-wait/still-negotiating-DHCP race)

On a real balena/Loci device (Raspberry Pi 5) or VM with NetworkManager:

1. With Ethernet plugged in and up at boot, confirm the container log shows `Wired connection detected - skipping WiFi Connect` and wifi-connect never launches.
2. With Ethernet unplugged, confirm the existing WiFi-check behavior (`iwgetid`-based) is unchanged.
3. With Ethernet plugged in but the switch/DHCP server briefly delayed, confirm the bounded wait (`WIRED_CHECK_TIMEOUT`) gives it a chance to come up before falling through to the WiFi path.

- [ ] **Step 5: Commit**

```bash
git add scripts/start.sh Dockerfile.template
git commit -m "feat(start.sh): skip WiFi Connect when a wired connection is already up"
```

---

### Task 5: Add a high-level "how wifi-connect works" overview doc

**Files:**
- Create: `docs/how-wifi-connect-works.md`

**Interfaces:** None.

- [ ] **Step 1: Write the overview doc**

Create `docs/how-wifi-connect-works.md`:

```markdown
# How WiFi Connect Works

This is a deeper, end-to-end look at wifi-connect's runtime behavior, complementing the
step-by-step captive-portal walkthrough in the main [README](../README.md#how-it-works).

## Startup

1. `scripts/start.sh` runs first, before the wifi-connect binary itself.
   - It checks whether a wired (Ethernet) connection is already up (waiting a short,
     bounded time for one that's still negotiating DHCP). If so, wifi-connect is never
     launched — a wired connection is treated as "job done," the same as a successful
     WiFi connection.
   - Otherwise it falls back to the existing check: if the device already has an active
     WiFi connection (`iwgetid -r`), wifi-connect is skipped too.
   - Only if neither check finds an existing connection does it launch the wifi-connect
     binary.
   - This decision is made once, at boot. Neither `start.sh` nor the wifi-connect binary
     re-checks wired state afterward — see "Known limitations" below.
2. wifi-connect itself starts NetworkManager (if needed), finds a managed WiFi device,
   scans for visible access points, and opens the AP/captive portal (`src/network.rs`).

## While the captive portal is running

- A user can connect a phone/laptop to the AP, load the captive portal, pick an SSID and
  enter a passphrase. wifi-connect attempts that connection; on success it exits (the
  device now has WiFi), on failure it recreates the AP for another attempt.
- Independently, a periodic timer (default: every 30 minutes, configurable via
  `RECONNECT_ENABLED` / `RECONNECT_INTERVAL_MINUTES` — see
  [command line arguments](./command-line-arguments.md)) tries to reconnect to
  previously-saved WiFi networks that are currently visible in range, trying the
  most-recently-connected one first. "Most-recently-connected" comes from a small local
  cache wifi-connect maintains itself (`src/reconnect_history.rs`), not from
  NetworkManager — every successful connection, manual or automatic, is recorded there
  with the current time. If one succeeds, wifi-connect exits, exactly as if a user had
  submitted it manually. If all fail, or there are no saved networks in range, the AP is
  left running (or restored) untouched.
- If nobody visits the captive portal for `ACTIVITY_TIMEOUT` seconds, wifi-connect exits
  without ever having connected (this timeout is disabled by default).

## Persistence

wifi-connect's reconnect-history cache lives at `/data/reconnect-history.json` — a fixed
path, not configurable — backed by a dedicated Docker volume mounted only into
wifi-connect's own container. This is a deliberate, reusable convention: see
[ADR 0008](../../adr/0008-per-service-volume-standardized-data-mount.md) (or this repo's
`docs/adr/0001-per-service-volume-standardized-data-mount.md`) for the rationale. Writes
are atomic (write-temp-then-rename) and happen only on a successful connection, never on
every timer tick, since these devices have no UPS and typically run off SD/eMMC storage
that doesn't tolerate write-heavy or interrupted-write workloads well. A missing or
corrupt cache file is treated as empty history, not a crash.

## Known limitations

- The wired-connection check in `start.sh` is a one-time, boot-time decision. If wired
  comes up *after* the AP is already running, the AP is not automatically torn down; if
  wired goes down *after* wifi-connect has already exited because wired was up at boot,
  nothing automatically relaunches wifi-connect. Both directions require external
  supervision (a restart policy, health check, etc.) to notice and react — this is a
  deliberate simplification, tracked for revisiting later if it proves too coarse in the
  field.
- The periodic reconnect feature matches saved networks against the last scan wifi-connect
  took, which is only refreshed when the AP is created or recreated — not on every timer
  tick — so very recently-appeared networks may not be tried until the next AP
  create/recreate cycle.
- The reconnect-history cache only knows about connections wifi-connect itself has made.
  A saved NetworkManager profile that predates this feature (or was never used via
  wifi-connect) has no history entry yet, so it sorts last until wifi-connect succeeds in
  connecting to it at least once.
```

- [ ] **Step 2: Verify `README.md` is untouched and the new doc reads correctly**

```bash
git diff --stat README.md
```

Expected: no output (zero changes).

```bash
git status --porcelain docs/how-wifi-connect-works.md
```

Expected: shows the new file as untracked/added.

- [ ] **Step 3: Commit**

```bash
git add docs/how-wifi-connect-works.md
git commit -m "docs: add high-level wifi-connect overview"
```
