# How WiFi Connect Works

This is a deeper, end-to-end look at wifi-connect's runtime behavior, complementing the
step-by-step captive-portal walkthrough in the main [README](../README.md#how-it-works).

## Startup

1. `scripts/start.sh` runs first, and keeps running: it is a supervision loop, not a
   one-shot boot gate. Every `SUPERVISE_INTERVAL` seconds (default 60) it re-decides
   whether wifi-connect is needed.
   - A wired (Ethernet) connection counts as "job done" — wifi-connect is not launched.
     Interfaces are discriminated by physical backing (`/sys/class/net/<iface>/device`),
     not by name, because under `network_mode: host` the container also sees `balena0`,
     `docker0` and `br-*`, all of which carry a global IP with nothing plugged in.
   - Otherwise it polls for a WiFi association (`iwgetid -r`) for up to
     `WIFI_CHECK_TIMEOUT` seconds (default 300, sampled every `WIFI_CHECK_INTERVAL`,
     default 5). That window is also a debounce: a link that drops briefly and returns is
     not worth raising a captive portal for.
   - An association to the device's *own* portal SSID (`Loci-AP-<uuid7>`) does not count.
     `iwgetid -r` reports the hotspot's SSID when `wlan0` is in AP mode, so a portal
     profile left behind by an ungraceful exit is auto-activated at boot and would
     otherwise read as healthy. Detecting it skips the wait and relaunches, which deletes
     the stale profile.
   - Only if neither check finds a connection does it launch the wifi-connect binary.
   - wifi-connect **exits as soon as it joins a network** — upstream's design. The loop is
     what picks supervision back up afterwards. Without it, a device that came up fine and
     lost its link hours later had no portal process and no reconnect timer left alive;
     measured on `e3042ef` on 2026-09-15, `wlan0` saw no activity at all for 37 minutes
     after the link died.

2. wifi-connect itself starts NetworkManager (if needed), finds a managed WiFi device,
   scans for visible access points, and opens the AP/captive portal (`src/network.rs`).

## While the captive portal is running

- A user can connect a phone/laptop to the AP, load the captive portal, pick an SSID and
  enter a passphrase. wifi-connect attempts that connection; on success it exits (the
  device now has WiFi), on failure it recreates the AP for another attempt.
- Independently, a periodic timer (default: every 15 minutes, configurable via
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
  anything to try. This is the one case where the AP is disturbed for a few seconds (up
  to ~10s, since stopping and rescanning both retry with short sleeps) even with no
  known candidates — it exists specifically so a network that wasn't visible earlier
  (e.g. its router was mid-reboot at boot time) is eventually noticed without a manual
  captive-portal visit. Setting `RECONNECT_RESCAN_EVERY=0` disables this and reverts to
  never rescanning without a candidate already in hand.
- If nobody visits the captive portal for `ACTIVITY_TIMEOUT` seconds, wifi-connect exits
  without ever having connected (this timeout is disabled by default).

### Periodic reconnect flow

```mermaid
flowchart TD
    A["Periodic timer fires<br/>(NetworkCommand::Reconnect)"] --> B["tick_count += 1"]
    B --> C{"Forced-rescan tick?<br/>RECONNECT_RESCAN_EVERY &gt; 0 and<br/>tick_count % RECONNECT_RESCAN_EVERY == 0"}
    C -->|yes| D["Stop AP<br/>Take a fresh WiFi scan"]
    C -->|no| E["Keep cached scan"]
    D --> F["Compute candidates:<br/>saved + in-range,<br/>most-recent-first"]
    E --> F
    F --> G{"Any candidates?"}
    G -->|no| H{"Was this a<br/>forced-rescan tick?"}
    H -->|yes| I["Recreate AP"]
    H -->|no| J["Leave AP untouched"]
    I --> K["Wait for next tick"]
    J --> K
    G -->|yes| L["Stop AP if still up"]
    L --> M["Try next candidate:<br/>activate() connection"]
    M --> N{"Activated?"}
    N -->|yes| O["Record success in<br/>reconnect-history cache"]
    O --> P["wifi-connect exits — job done"]
    N -->|no, more candidates left| M
    N -->|no, none left| Q["Refresh scan"]
    Q --> R["Recreate AP"]
    R --> K
```

The "no candidates → AP untouched" path (`J`) is the normal case on most ticks. The "no candidates → recreate AP" path (`I`) only happens on a forced-rescan tick — it's the one place the AP is disturbed for a few seconds without ever finding anything to try, and it exists specifically to keep the cached scan from going stale forever.

## Persistence

wifi-connect's reconnect-history cache lives at `/data/reconnect-history.json` — a fixed
path, not configurable — backed by a dedicated Docker volume mounted only into
wifi-connect's own container. This is a deliberate, reusable convention: see
[ADR 0008](../../../adr/0008-per-service-volume-standardized-data-mount.md) (or this repo's
`docs/adr/0001-per-service-volume-standardized-data-mount.md`) for the rationale. Writes
are atomic (write-temp-then-rename) and happen only on a successful connection, never on
every timer tick, since these devices have no UPS and typically run off SD/eMMC storage
that doesn't tolerate write-heavy or interrupted-write workloads well. A missing or
corrupt cache file is treated as empty history, not a crash.

## Known limitations

- The WiFi check in `start.sh` is bounded. Past `WIFI_CHECK_TIMEOUT` the portal is
  raised regardless, and recovery from that point is the periodic reconnect's job, not
  `start.sh`'s.
- Reaction to a change is bounded by `SUPERVISE_INTERVAL` plus `WIFI_CHECK_TIMEOUT`, so
  in the worst case a lost link takes ~6 minutes to raise the portal. Wired arriving while
  the portal is already up is noticed on the next pass, but does not tear the portal down
  mid-session — wifi-connect is only re-evaluated once it exits.
- The periodic reconnect feature matches saved networks against the last scan wifi-connect
  took. Most ticks reuse that cached scan; every `RECONNECT_RESCAN_EVERY`th tick forces a
  fresh one (see above). So a network that comes back into range can take up to
  `RECONNECT_INTERVAL_MINUTES × RECONNECT_RESCAN_EVERY` minutes to be noticed — not
  instant, but bounded, rather than the unbounded staleness of relying solely on a
  candidate already being known. Setting `RECONNECT_RESCAN_EVERY=0` restores the
  unbounded version of this limitation.
- The reconnect-history cache only knows about connections wifi-connect itself has made.
  A saved NetworkManager profile that predates this feature (or was never used via
  wifi-connect) has no history entry yet, so it sorts last until wifi-connect succeeds in
  connecting to it at least once.
