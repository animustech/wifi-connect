# Forced Periodic Rescan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the "stale boot-time scan" design gap in the periodic-reconnect feature by forcing a fresh WiFi scan every Nth periodic tick, regardless of whether any candidate was already known.

**Architecture:** `NetworkCommandHandler` gains a tick counter (`reconnect_tick_count: u64`) and a new config field (`reconnect_rescan_every: u64`, default `2`). On every `reconnect()` call the counter increments; when it's a multiple of `reconnect_rescan_every` (and that value is non-zero), the handler unconditionally stops the AP, refreshes its cached scan, and only then computes candidates — bypassing the existing "no candidates = untouched no-op" short-circuit for that one tick. All other ticks are byte-for-byte unchanged from today's behavior. The tick-count/modulo decision itself is extracted into a small pure free function so it's unit-testable, matching this file's existing precedent (`src/reconnect_history.rs`) for carving out pure logic where the surrounding code can't be unit-tested (no D-Bus mocking available — see the original plan's Global Constraints for why).

**Tech Stack:** Same as the existing feature — Rust 2015-edition binary crate, no new dependencies, built/tested via Docker Desktop (`dc_cargo`, `rust:1.76-bullseye`, `libdbus-1-dev`/`pkg-config` workaround for the link step).

## Global Constraints

- Spec: `docs/specs/2026-08-10-conditional-wifi-reconnect.md`, AC7 (revised) and AC11 (new). This plan implements exactly those two acceptance criteria; nothing else in the spec changes.
- New config field follows the existing `RECONNECT_*` family exactly: `--reconnect-rescan-every` / `$RECONNECT_RESCAN_EVERY`, default `2`, `0` disables forced rescanning entirely (falls back to pre-existing behavior).
- Non-forced ticks must be **byte-for-byte identical** to today's `reconnect()` behavior — this plan adds a new path, it does not change the existing one.
- `src/network.rs` still has no test harness for anything touching NetworkManager D-Bus (same pre-existing structural limitation as the original plan — do not add mocking). The one exception: the tick/modulo arithmetic this plan introduces is genuinely pure and gets real unit tests, same precedent as `src/reconnect_history.rs`.
- Build/test via Docker Desktop only — no host Rust toolchain. Reuse the `dc_cargo` helper from `CLAUDE.md` / the original plan's Global Constraints:

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

  A full `dc_cargo cargo build`/`test` needs `apt-get install -y libdbus-1-dev pkg-config` inside the same container invocation first (pre-existing environment gap, not a repo change).

---

## File Structure

- **Modify `src/config.rs`** — add `reconnect_rescan_every: u64` to `Config`, with CLI/env parsing (`--reconnect-rescan-every` / `$RECONNECT_RESCAN_EVERY`, default `2`).
- **Modify `docs/command-line-arguments.md`** — document the new option.
- **Modify `src/network.rs`** — add `reconnect_tick_count: u64` to `NetworkCommandHandler`; add a pure `is_forced_rescan_tick` helper (with unit tests); restructure `reconnect()` to force a rescan on qualifying ticks.
- **Modify `docs/how-wifi-connect-works.md`** — update the "While the captive portal is running" and "Known limitations" sections to describe the new forced-rescan behavior instead of presenting the stale-scan gap as unmitigated. (Drive-by fix while in this file: the ADR link on this page currently reads `../../adr/0008-...md`, which is one segment short of the real path from `docs/how-wifi-connect-works.md` — should be `../../../adr/0008-...md`, three levels up: `docs/` → `wifi-connect/` → `loci/` → `adi/`. This was flagged as a deferred minor in the original feature's final review and never fixed; fix it now since this task is already touching the paragraph.)

No `Cargo.toml`/`Cargo.lock` changes — no new dependencies.

---

### Task 1: Add `RECONNECT_RESCAN_EVERY` configuration

**Files:**
- Modify: `src/config.rs`
- Modify: `docs/command-line-arguments.md`

**Interfaces:**
- Produces: `Config.reconnect_rescan_every: u64`. Consumed by Task 2.

- [ ] **Step 1: Add the constant**

In `src/config.rs`, find:

```rust
const DEFAULT_RECONNECT_ENABLED: &str = "true";
const DEFAULT_RECONNECT_INTERVAL_MINUTES: &str = "30";
```

Replace with:

```rust
const DEFAULT_RECONNECT_ENABLED: &str = "true";
const DEFAULT_RECONNECT_INTERVAL_MINUTES: &str = "30";
const DEFAULT_RECONNECT_RESCAN_EVERY: &str = "2";
```

- [ ] **Step 2: Add the field to `Config`**

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
    pub reconnect_enabled: bool,
    pub reconnect_interval_minutes: u64,
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
    pub reconnect_rescan_every: u64,
}
```

- [ ] **Step 3: Add the CLI argument**

Find:

```rust
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

Replace with:

```rust
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
        .arg(
            Arg::with_name("reconnect-rescan-every")
                .long("reconnect-rescan-every")
                .value_name("reconnect_rescan_every")
                .help(&format!(
                    "Force a fresh WiFi scan every Nth periodic reconnect attempt, regardless \
                     of cached candidates; 0 disables forced rescanning (default: {})",
                    DEFAULT_RECONNECT_RESCAN_EVERY
                ))
                .takes_value(true),
        )
        .get_matches();
```

- [ ] **Step 4: Parse the value and include it in the returned `Config`**

Find:

```rust
    let reconnect_interval_minutes =
        u64::from_str(&matches.value_of("reconnect-interval-minutes").map_or_else(
            || {
                env::var("RECONNECT_INTERVAL_MINUTES")
                    .unwrap_or_else(|_| DEFAULT_RECONNECT_INTERVAL_MINUTES.to_string())
            },
            String::from,
        ))
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

Replace with:

```rust
    let reconnect_interval_minutes =
        u64::from_str(&matches.value_of("reconnect-interval-minutes").map_or_else(
            || {
                env::var("RECONNECT_INTERVAL_MINUTES")
                    .unwrap_or_else(|_| DEFAULT_RECONNECT_INTERVAL_MINUTES.to_string())
            },
            String::from,
        ))
        .expect("Cannot parse reconnect interval minutes");

    let reconnect_rescan_every =
        u64::from_str(&matches.value_of("reconnect-rescan-every").map_or_else(
            || {
                env::var("RECONNECT_RESCAN_EVERY")
                    .unwrap_or_else(|_| DEFAULT_RECONNECT_RESCAN_EVERY.to_string())
            },
            String::from,
        ))
        .expect("Cannot parse reconnect rescan every");

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
        reconnect_rescan_every,
    }
}
```

- [ ] **Step 5: Document the new option**

In `docs/command-line-arguments.md`, find:

```markdown
*   **--reconnect-interval-minutes** reconnect_interval_minutes, **$RECONNECT_INTERVAL_MINUTES**

    Minutes between periodic reconnect attempts

    Default: _30_
```

Replace with:

```markdown
*   **--reconnect-interval-minutes** reconnect_interval_minutes, **$RECONNECT_INTERVAL_MINUTES**

    Minutes between periodic reconnect attempts

    Default: _30_

*   **--reconnect-rescan-every** reconnect_rescan_every, **$RECONNECT_RESCAN_EVERY**

    Force a fresh WiFi scan every Nth periodic reconnect attempt, regardless of cached candidates; 0 disables forced rescanning

    Default: _2_
```

- [ ] **Step 6: Build and verify (via Docker — see Global Constraints for `dc_cargo`)**

```bash
dc_cargo cargo build 2>&1 | tail -40
dc_cargo cargo run --bin wifi-connect -- --help
```

Expected: build succeeds; `--help` output lists `--reconnect-rescan-every` with the help text above. (Safe without root/NetworkManager — `--help` short-circuits before `require_root()`/`init_networking()` run.)

- [ ] **Step 7: Commit**

```bash
git add src/config.rs docs/command-line-arguments.md
git commit -m "feat(config): add RECONNECT_RESCAN_EVERY"
```

---

### Task 2: Implement forced periodic rescan in `network.rs`

**Files:**
- Modify: `src/network.rs`
- Modify: `docs/how-wifi-connect-works.md`

**Interfaces:**
- Consumes: `Config.reconnect_rescan_every: u64` (Task 1).
- Produces: `NetworkCommandHandler.reconnect_tick_count: u64` field; free function `is_forced_rescan_tick(tick_count: u64, rescan_every: u64) -> bool` (unit-tested); method `NetworkCommandHandler::tear_down_portal_if_up(&mut self) -> Result<()>` (also adopted by the existing `connect()` method to remove a pre-existing duplicate of the same 3-line block).

- [ ] **Step 1: Write the failing unit tests for the pure tick-decision logic**

In `src/network.rs`, find the end of the file (the last function, `is_wifi_connection`, and nothing after it):

```rust
fn is_wifi_connection(connection: &Connection) -> bool {
    connection.settings().kind == "802-11-wireless"
}
```

Replace with (appending the new function and its test module — the function itself is a stub for now, just enough to make the file compile so the tests can fail on assertion, not on a missing symbol):

```rust
fn is_wifi_connection(connection: &Connection) -> bool {
    connection.settings().kind == "802-11-wireless"
}

/// Whether this periodic-reconnect tick should force a fresh WiFi scan
/// regardless of what the cached scan showed. `rescan_every == 0` disables
/// forced rescanning entirely (always `false`). `tick_count` is expected to
/// already be incremented (1-based) by the caller before this is checked.
fn is_forced_rescan_tick(_tick_count: u64, _rescan_every: u64) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rescan_every_zero_never_forces() {
        assert!(!is_forced_rescan_tick(1, 0));
        assert!(!is_forced_rescan_tick(2, 0));
        assert!(!is_forced_rescan_tick(100, 0));
    }

    #[test]
    fn rescan_every_one_forces_every_tick() {
        assert!(is_forced_rescan_tick(1, 1));
        assert!(is_forced_rescan_tick(2, 1));
        assert!(is_forced_rescan_tick(3, 1));
    }

    #[test]
    fn rescan_every_two_forces_every_other_tick_starting_at_the_second() {
        assert!(!is_forced_rescan_tick(1, 2));
        assert!(is_forced_rescan_tick(2, 2));
        assert!(!is_forced_rescan_tick(3, 2));
        assert!(is_forced_rescan_tick(4, 2));
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail for the right reason**

```bash
docker run --rm \
    -v "$(pwd)":/usr/src/app -w /usr/src/app \
    -v wifi-connect-cargo-registry:/usr/local/cargo/registry \
    -v wifi-connect-cargo-git:/usr/local/cargo/git \
    rust:1.76-bullseye \
    bash -c "apt-get update -qq && apt-get install -y -qq libdbus-1-dev pkg-config >/dev/null && cargo test is_forced_rescan_tick 2>&1 | tail -30"
```

Expected: FAIL — `rescan_every_one_forces_every_tick` and `rescan_every_two_forces_every_other_tick_starting_at_the_second` fail their assertions (the stub always returns `false`); `rescan_every_zero_never_forces` passes (stub returns `false`, which happens to be correct for that one case). This confirms the test harness is wired up and exercising real logic, not a tautology.

- [ ] **Step 3: Implement the real logic**

Find:

```rust
fn is_forced_rescan_tick(_tick_count: u64, _rescan_every: u64) -> bool {
    false
}
```

Replace with:

```rust
fn is_forced_rescan_tick(tick_count: u64, rescan_every: u64) -> bool {
    rescan_every > 0 && tick_count % rescan_every == 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
docker run --rm \
    -v "$(pwd)":/usr/src/app -w /usr/src/app \
    -v wifi-connect-cargo-registry:/usr/local/cargo/registry \
    -v wifi-connect-cargo-git:/usr/local/cargo/git \
    rust:1.76-bullseye \
    bash -c "apt-get update -qq && apt-get install -y -qq libdbus-1-dev pkg-config >/dev/null && cargo test is_forced_rescan_tick 2>&1 | tail -30"
```

Expected: PASS — all 3 tests green.

- [ ] **Step 5: Add the tick-count field to `NetworkCommandHandler`**

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
    reconnect_history: ReconnectHistory,
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
    reconnect_tick_count: u64,
}
```

- [ ] **Step 6: Initialize it in `NetworkCommandHandler::new`**

Find:

```rust
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

Replace with:

```rust
        let config = config.clone();
        let activated = false;
        let reconnect_history = ReconnectHistory::load(Path::new(HISTORY_FILE_PATH));
        let reconnect_tick_count = 0;

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
            reconnect_tick_count,
        })
    }
```

- [ ] **Step 7: Extract a `tear_down_portal_if_up` helper (removes a duplication this task would otherwise introduce), and restructure `reconnect()` to force a rescan on qualifying ticks**

The forced-rescan path and the existing candidate-attempt path both need to "stop the portal if it's up, then clear it" — without a shared helper this task would paste that 3-line block a second time. Extract it once, and adopt it in `connect()` too (which already had its own copy of the exact same block, unrelated to this task but trivially deduplicated now that the helper exists).

**7a.** Find (inside the existing `connect()` method):

```rust
    fn connect(&mut self, ssid: &str, identity: &str, passphrase: &str) -> Result<bool> {
        delete_existing_connections_to_same_network(&self.manager, ssid);

        if let Some(ref connection) = self.portal_connection {
            stop_portal(connection, &self.config)?;
        }

        self.portal_connection = None;

        self.access_points = get_access_points(&self.device)?;
```

Replace with:

```rust
    fn connect(&mut self, ssid: &str, identity: &str, passphrase: &str) -> Result<bool> {
        delete_existing_connections_to_same_network(&self.manager, ssid);

        self.tear_down_portal_if_up()?;

        self.access_points = get_access_points(&self.device)?;
```

**7b.** Find (the entire current `reconnect()` method — this replaces it in full to insert the new helper immediately above it and thread `force_rescan` through the empty-candidates early return):

```rust
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
```

Replace with:

```rust
    /// Stops and clears the AP portal connection if one is currently up. A no-op if
    /// it's already down (e.g. already torn down earlier in the same tick).
    fn tear_down_portal_if_up(&mut self) -> Result<()> {
        if let Some(ref connection) = self.portal_connection {
            stop_portal(connection, &self.config)?;
        }

        self.portal_connection = None;

        Ok(())
    }

    /// Periodically-triggered reconnect: try saved WiFi networks that are currently
    /// visible in range, most-recently-connected first. Only touches the AP if there
    /// is at least one candidate to try — except on a forced-rescan tick (every
    /// `config.reconnect_rescan_every`th call), which refreshes the scan unconditionally
    /// so a network that wasn't visible at boot (or the last successful scan) is
    /// eventually noticed without requiring a manual captive-portal visit.
    fn reconnect(&mut self) -> Result<bool> {
        self.reconnect_tick_count = self.reconnect_tick_count.wrapping_add(1);

        let force_rescan = is_forced_rescan_tick(
            self.reconnect_tick_count,
            self.config.reconnect_rescan_every,
        );

        if force_rescan {
            info!(
                "Forced periodic rescan (every {} ticks)",
                self.config.reconnect_rescan_every
            );

            self.tear_down_portal_if_up()?;
            self.access_points = get_access_points(&self.device)?;
        }

        let candidates = self.get_reconnect_candidates()?;

        if candidates.is_empty() {
            debug!("No saved networks currently in range - skipping periodic reconnect");

            if force_rescan {
                self.portal_connection = Some(create_portal(&self.device, &self.config)?);
            }

            return Ok(false);
        }

        info!(
            "Periodic reconnect: attempting {} saved network(s) in range",
            candidates.len()
        );

        self.tear_down_portal_if_up()?;

        for candidate in &candidates {
```

The rest of the method (the `for` loop body, the tail that re-scans and recreates the portal on exhaustion, and the closing braces) is unchanged — do not touch it.

- [ ] **Step 8: Full build (via Docker — see Global Constraints for `dc_cargo`)**

```bash
docker run --rm \
    -v "$(pwd)":/usr/src/app -w /usr/src/app \
    -v wifi-connect-cargo-registry:/usr/local/cargo/registry \
    -v wifi-connect-cargo-git:/usr/local/cargo/git \
    rust:1.76-bullseye \
    bash -c "apt-get update -qq && apt-get install -y -qq libdbus-1-dev pkg-config >/dev/null && cargo build 2>&1 | tail -60 && cargo test 2>&1 | tail -30"
```

Expected: build succeeds; full test suite passes (the 5 existing `reconnect_history` tests plus the 3 new `is_forced_rescan_tick` tests — 8 total).

- [ ] **Step 9: Update the overview doc**

In `docs/how-wifi-connect-works.md`, find:

```markdown
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
```

Replace with:

```markdown
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
- Every Nth tick (`RECONNECT_RESCAN_EVERY`, default `2` — effectively every hour at the
  default interval) is a **forced-rescan tick**: the AP is stopped and a fresh scan is
  taken regardless of what the previous scan showed, before deciding whether there's
  anything to try. This is the one case where the AP is briefly disturbed even with no
  known candidates — it exists specifically so a network that wasn't visible earlier
  (e.g. its router was mid-reboot at boot time) is eventually noticed without a manual
  captive-portal visit. Setting `RECONNECT_RESCAN_EVERY=0` disables this and reverts to
  never rescanning without a candidate already in hand.
```

- [ ] **Step 10: Revise the "Known limitations" entry this closes**

In `docs/how-wifi-connect-works.md`, find:

```markdown
- The periodic reconnect feature matches saved networks against the last scan wifi-connect
  took, which is only refreshed when the AP is created or recreated — not on every timer
  tick — so very recently-appeared networks may not be tried until the next AP
  create/recreate cycle.
```

Replace with:

```markdown
- The periodic reconnect feature matches saved networks against the last scan wifi-connect
  took. Most ticks reuse that cached scan; every `RECONNECT_RESCAN_EVERY`th tick forces a
  fresh one (see above). So a network that comes back into range can take up to
  `RECONNECT_INTERVAL_MINUTES × RECONNECT_RESCAN_EVERY` minutes to be noticed — not
  instant, but bounded, rather than the unbounded staleness of relying solely on a
  candidate already being known. Setting `RECONNECT_RESCAN_EVERY=0` restores the
  unbounded version of this limitation.
```

- [ ] **Step 11: Fix the ADR link depth while in this file**

Find:

```markdown
wifi-connect's reconnect-history cache lives at `/data/reconnect-history.json` — a fixed
path, not configurable — backed by a dedicated Docker volume mounted only into
wifi-connect's own container. This is a deliberate, reusable convention: see
[ADR 0008](../../adr/0008-per-service-volume-standardized-data-mount.md) (or this repo's
`docs/adr/0001-per-service-volume-standardized-data-mount.md`) for the rationale. Writes
```

Replace with:

```markdown
wifi-connect's reconnect-history cache lives at `/data/reconnect-history.json` — a fixed
path, not configurable — backed by a dedicated Docker volume mounted only into
wifi-connect's own container. This is a deliberate, reusable convention: see
[ADR 0008](../../../adr/0008-per-service-volume-standardized-data-mount.md) (or this repo's
`docs/adr/0001-per-service-volume-standardized-data-mount.md`) for the rationale. Writes
```

(Three levels up from `docs/how-wifi-connect-works.md`: `docs/` → `wifi-connect/` → `loci/` → `adi/`, where the canonical ADR lives. This was a deferred minor from the original feature's final review, left unfixed — corrected now since this task already touches the surrounding paragraph.)

- [ ] **Step 12: Manual verification protocol** (same limitation as the rest of `network.rs` — no NetworkManager/WiFi hardware available in Docker Desktop)

On a real Linux host with NetworkManager, real WiFi hardware, and at least one saved profile currently out of range at boot:

1. Run `wifi-connect --reconnect-interval-minutes=1 --reconnect-rescan-every=2`.
2. Confirm ticks 1, 3, 5, ... behave exactly as before (no candidates → untouched no-op, logged as such).
3. Confirm tick 2 (and 4, 6, ...) logs `Forced periodic rescan (every 2 ticks)`, briefly stops and recreates the AP even when nothing new is found. `stop_portal_impl`'s 1s sleep plus `get_access_points_impl`'s up-to-10×1s retry-when-empty loop mean this can hold the portal down for up to ~10-12s even when nothing is found — confirm this window is what's actually observed, not a hang.
4. Bring the previously-out-of-range network into range between tick 1 and tick 2. Confirm tick 2's forced rescan discovers it as a candidate and successfully reconnects (process exits).
5. **dnsmasq survival across a forced-rescan teardown/recreate** (highest-value real-hardware check — `dnsmasq` is spawned once at process start with `--bind-interfaces` and never restarted across an AP teardown/recreate cycle; this path previously only ran after a user-triggered failed connect, but forced rescan now exercises it unattended, hourly, on an idle device). After a forced-rescan tick recreates the AP (step 3), join the AP from a phone and confirm you actually get a DHCP lease and the captive portal page loads — not just that the SSID is broadcasting. A silently-dead DHCP/DNS path here would be invisible from the logs alone.

- [ ] **Step 13: Commit**

```bash
git add src/network.rs docs/how-wifi-connect-works.md
git commit -m "feat(network): force a periodic rescan to close the stale-boot-scan gap"
```
