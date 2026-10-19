# Recover a saved network NetworkManager will not autoconnect

## What

Two additions to the supervision loop (`start.sh` plus whatever binary support it needs):

1. **Explicit recovery after give-up.** When the portal gives up without joining anything, wait
   a short grace period for NetworkManager to reconnect on its own, as it normally does. If it
   has not, and a saved WiFi profile's SSID is in a fresh scan, explicitly activate that
   profile. An explicit activation overrides whatever is blocking NM's autoconnect.
2. **NetworkManager state log.** Record NM's view of `wlan0` and of the saved WiFi profiles
   whenever the link is down or its state changes. Write it to stdout and also to a
   size-bounded file on `/data`, so the start of an outage survives journal rotation.

## Why

- Recovery today rests entirely on NM's autoconnect. The give-up path deletes the portal
  profile and sleeps `PORTAL_RETRY_GAP`, and the binary's periodic reconnect (M4) never fires
  at shipped settings (`docs/connectivity-scenarios.md`, S4).
- On ed682d4 (50022), NM held the vessel profile blocked from autoconnect. Over at least three
  days it made 0 auto-activation attempts while wifi-connect raised and gave up its portal 216
  times, with the vessel SSID visible in every scan. Only a power cut cleared it, after
  21 days without data. Its twin on the same network hit the same drop and recovered within
  minutes, because there NM was not blocked.
- The cause of the block is unknown because the journal rotated within ~3 days, mostly on
  brcmfmac scan noise. The next occurrence has to leave evidence that survives.

## Acceptance criteria

1. After a give-up, if the link is not up within a grace period (default 30 s, set by an
   environment variable), wifi-connect runs a fresh scan. If it finds one or more candidates, it
   explicitly activates them one at a time in reconnect-history order, most recent first, and
   stops at the first success. A candidate is a saved WiFi profile with
   `connection.autoconnect=yes` whose SSID is visible, other than the portal profile.
2. On the hwsim rig, with NM's autoconnect blocked on `wlan0` (induced with
   `nmcli device disconnect wlan0`) and the saved AP present, the device is associated within
   90 s of give-up. A new scenario covers this, and it fails against the current code, which
   stays disconnected for the whole `PORTAL_RETRY_GAP`.
3. If NM reconnects by itself within the grace period, nothing is activated explicitly and the
   existing S4 scenario passes unchanged at production settings.
4. Profiles with `connection.autoconnect=no` and the portal profile are never activated.
5. If no candidate is visible, nothing is activated, and one line says so with the number of
   visible SSIDs.
6. Each give-up tries each candidate at most once. A failed activation is logged with NM's
   state reason and the next candidate is tried. When all have failed, the loop falls through
   to `PORTAL_RETRY_GAP` as it does today, so there is no retry storm.
7. Every explicit activation logs one line naming the profile and the outcome.
8. One state line is written on every connected↔disconnected transition, on every pass that
   finds the link down, after every give-up and after every recovery attempt. Each line holds a
   timestamp, `wlan0`'s NM device state and state reason, the device's autoconnect flag, the
   active connection, and for each saved WiFi profile its id, `connection.autoconnect` and
   whether its SSID is visible. While the link is up and unchanged, nothing is logged, so the
   journal gains no per-pass noise.
9. The same lines are appended to a file on `/data`, capped at 1 MiB. Past the cap, the oldest
   half is dropped. Nothing is written to the file while the link is up and unchanged, which
   limits SD wear. A missing or unwritable file never stops the loop.
10. The decision-path harness and every existing hwsim scenario still pass.

## Non-goals

- Finding why NM blocked autoconnect on ed682d4. The state log exists to catch that next time.
- Host-side changes: journal size and retention, NM log levels, persistent-logging config.
- Reviving M4 or changing the `ACTIVITY_TIMEOUT`, `PORTAL_RETRY_GAP` or reconnect defaults.
- Rebooting the device or restarting NetworkManager as a recovery step.
- Wired and LTE paths, and the portal-submit path (`connect()`).
- The relay's undelivered offline backlog and the 2026-09-28 outage on ed682d4. Those are
  separate investigations.

## Interface / config additions (indicative; names are finalized in planning)

- `RECOVERY_GRACE` (s, default 30): how long after give-up to wait for NM before activating
  explicitly.
- `NM_STATE_LOG` (path, default `/data/nm-state.log`), capped at 1 MiB.
- Log line shapes, for example:
  - `NM state: wlan0=disconnected(reason=…) dev-autoconnect=no active=- profiles=[Prospect_WiFi auto=yes visible=yes]`
  - `Recovery: activating saved profile 'Prospect_WiFi' -> activated`

## Base

Builds on `dev` (`6aa3348`, the pinned SHA). The unmerged `fix/pi0-2w-timeout` widens NM and
scan timings, and the plan must reconcile with it. On a Pi Zero 2 W the radio needs more than
10 s after AP teardown before a scan shows neighbours, and the grace period covers that.
