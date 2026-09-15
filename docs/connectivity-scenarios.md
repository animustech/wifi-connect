# Connectivity scenarios and what answers them

Every connectivity situation a Loci unit can be in, what the stack currently does about it,
and where the gaps are. Written 2026-09-15 after a day in which three separate causes of
the same symptom — "the device is dark" — were found one behind the other.

This file is a map, not a state file. It says what each mechanism is *for*. What is
actually deployed is in `loci-on-balena/docs/STATE.md`; what is pinned and released is in
`tools/brief/brief.sh`.

## The mechanisms, in one place

There are four, and confusing them is what made this hard to reason about.

| # | Mechanism | Lives in | Runs when |
|---|---|---|---|
| M1 | Wired-connection check | `scripts/start.sh` | Every supervision pass |
| M2 | WiFi association poll | `scripts/start.sh` | Every supervision pass |
| M3 | Captive portal | `wifi-connect` binary | Only while the binary runs |
| M4 | Periodic reconnect | `wifi-connect` binary (`src/network.rs`) | Only while the binary runs |

**The single most important fact:** M3 and M4 exist only while the `wifi-connect` process
is alive, and that process **exits the moment it successfully joins a network**. That is
upstream's design, not a bug. Everything M4 does — retrying saved networks, forced
rescans — stops dead the instant a connection succeeds.

`start.sh` (M1/M2) is therefore the only thing that runs continuously. It is a supervision
loop: it re-decides every `SUPERVISE_INTERVAL` whether the binary needs launching.

### Knobs

| Setting | Default | What it governs |
|---|---|---|
| `SUPERVISE_INTERVAL` | 60 s | How often `start.sh` re-examines the link when healthy |
| `WIFI_CHECK_TIMEOUT` | 60 s | How long to let an in-flight association complete before raising the portal |
| `WIFI_CHECK_INTERVAL` | 5 s | Sampling rate within that window |
| `RECONNECT_ENABLED` | true | M4 on/off |
| `RECONNECT_INTERVAL_MINUTES` | 15 | M4 tick |
| `RECONNECT_RESCAN_EVERY` | 2 | Force a fresh scan every Nth tick |
| `ACTIVITY_TIMEOUT` | 0 (disabled) | If set, the portal exits after N seconds with no visitor |

All are environment variables, so all can be changed on a balena fleet **without a
release**.

---

## The timings, in plain language

Seven numbers govern everything, and they are easy to confuse because several sound alike.
All are **seconds** unless the name says minutes.

| Knob | Default | In one sentence |
|---|---|---|
| `WIRED_CHECK_TIMEOUT` | 10 s | At boot only: how long to wait for a plugged-in cable to finish getting an IP before deciding there is no cable. |
| `SUPERVISE_INTERVAL` | 60 s | While everything is fine: how often we glance at the link. |
| `WIFI_CHECK_TIMEOUT` | 60 s | Once the link looks down: how long we give NetworkManager to sort it out before taking the radio away from it. |
| `WIFI_CHECK_INTERVAL` | 5 s | How often we look during that window. |
| `RECONNECT_INTERVAL_MINUTES` | 15 min | While the portal is up: how often the binary tries the networks it already knows. |
| `RECONNECT_RESCAN_EVERY` | 2 ticks | Every second of those tries also does a fresh scan, so every 30 minutes — that is what finds a network that was not visible earlier. |
| `ACTIVITY_TIMEOUT` | 0 = off | If set: how long the portal waits for a human to open it before giving up and handing the radio back. |

### What that feels like in practice

**A healthy boot.** The check happens immediately — there is no fixed delay — so a device
that already knows the network logs one line and goes quiet. Nothing else happens for days.

**A boot with no network available.** 10 s waiting for a cable that is not there, then
60 s giving WiFi a chance, so the portal appears about **70 seconds** after the container
starts. Then the binary retries known networks every 15 minutes, with a fresh scan every
30.

**The link dies hours later.** Up to 60 s before we notice, then 60 s letting
NetworkManager try on its own. Worst case the portal appears about **2 minutes** after the
link actually went. In practice NetworkManager usually fixes it inside that window and the
portal never appears at all — which is the desired outcome, not a failure.

**A brief flap.** A link that drops and returns within 60 s costs nothing: no portal, no
log noise beyond one "connection lost" line.

**Stranded with the portal up and nobody aboard.** Known networks are retried at 15, 30,
45, 60 minutes and so on; every second attempt rescans first. So the worst case for
noticing that the vessel's AP came back is **30 minutes** — against NetworkManager's few
seconds, which is exactly why we would rather not be holding the radio at all.

### Why the two "wait for WiFi" numbers are different

`WIFI_CHECK_TIMEOUT` (60 s) answers *"is an association that is already underway going to
succeed?"* On a busy network that is seconds.

`RECONNECT_INTERVAL_MINUTES` (15 min) answers *"has anything changed out there?"* That is a
much slower question and deserves a much larger number.

Briefly these were conflated and `WIFI_CHECK_TIMEOUT` was set to 300 s, which is far too
long for the first question and far too short for the second. If either number is ever
changed, check which question is being answered.

---

## Scenarios

Numbering follows the owner's original list; S5 onward are the ones that list did not
cover.

### S0 — Boots wired

Ethernet carries a global IPv4 address. M1 sees it, the binary is never launched, no AP.

**Covered.** Re-checked every pass, so a cable pulled later is noticed.

Detection is by physical backing (`/sys/class/net/<iface>/device`), not interface name —
under `network_mode: host` the container also sees `balena0`, `supervisor0`, `docker0` and
`br-*`, all of which carry a global IP with nothing plugged in. A name-based filter reports
"wired" on a device with no Ethernet at all and wifi-connect never starts. That is
field-bricking and was caught only by testing against the real network mode.

> **Open:** this path reportedly did not behave as expected during testing on 2026-09-15.
> Not yet diagnosed. See "Open questions".

### S1 — Boots, no credentials, operator provisions via the portal

No saved network. M2 polls for `WIFI_CHECK_TIMEOUT`, gives up, M3 raises
`Loci-AP-<uuid7>`. Operator picks an SSID, enters a passphrase, the device joins and the
binary exits. `start.sh` resumes supervision.

**Covered.** This is the only scenario the captive portal genuinely exists for.

### S2 — Boots, has credentials, joins, stays up for days

NetworkManager auto-connects a saved profile. M2 sees the association immediately (the
poll checks before sleeping, so there is no fixed delay), the binary is never launched.

**Covered.**

### S3 — Joins at boot, loses the link hours later

The link drops. M2 notices within `SUPERVISE_INTERVAL`, waits `WIFI_CHECK_TIMEOUT` for it
to return — NetworkManager gets that window uninterrupted — and if it does not, launches
the binary so M3/M4 come back.

**Partly covered before, fully covered as of `1.2.0-wifi-connect.2`.**

Be precise about what was missing. NetworkManager has always retried on its own and is
good at it — on `e3042ef` the 37-minute gap ended **4 seconds** after the AP returned, and
that was NetworkManager, not us. What was absent was the portal and M4 as a *fallback*:
`start.sh` decided once and then slept forever, so after the first successful connection
there was no portal process and no reconnect timer for the rest of the boot. If
NetworkManager had not recovered it, nothing would have.

### S4 — Boots with the network absent, nobody attends the portal

M3 raises the AP. M4 then retries saved networks every `RECONNECT_INTERVAL_MINUTES`,
forcing a fresh scan every `RECONNECT_RESCAN_EVERY` ticks so a network that was invisible
at the moment of boot is eventually noticed.

**Covered and now proven** — `tools/hwsim/scenario-s4.sh`, 2026-09-15. Previously every
recovery seen in the field came from a human opening the portal before the first tick
fired, so this was designed-but-unobserved. The simulated rig staged it end to end: portal
up with the AP gone, AP returns, nobody touches anything, and the device reconnects on a
forced-rescan tick:

```
Forced periodic rescan (every 2 ticks)
Stopping access point 'Loci-AP-e3042ef'...
Access points: ["Deep Runner-IOT"]
Periodic reconnect: attempting 1 saved network(s) in range
Internet connectivity established
WiFi Connect exited - resuming supervision
```

Recovery is bounded by the tick, so at production settings (15 min, rescan every 2nd tick)
the worst case is ~30 minutes.

### S5 — A stale portal profile survives an ungraceful exit

A hard reboot or a SIGKILL before teardown leaves the `Loci-AP-<uuid7>` NetworkManager
profile behind. NetworkManager auto-activates it at boot, and `iwgetid -r` then reports the
device's **own** hotspot SSID — which reads as a perfectly healthy association.

Without a guard, `start.sh` skips the binary: no portal, no reconnect, dark until someone
physically attends it. Same strand, different door.

**Covered.** An association to our own portal SSID is treated as not connected, the wait is
skipped (a radio serving our own AP is not about to associate to anything), and the binary
is relaunched — which deletes the leftover profile when it creates its own.

### S6 — Associated, but no route to anywhere

The vessel AP answers, WPA completes, DHCP grants a lease — and the upstream VSAT link is
down. `iwgetid -r` succeeds, so M1/M2 see a healthy connection and the binary is never
launched. M4 never runs.

**Not covered, and nothing here addresses it.** Association is not connectivity. On a
vessel with a spotty satellite uplink this is likely the *most* common failure, and it is
invisible to every mechanism in this repo.

It is also arguably correct that wifi-connect does nothing: the WiFi link is genuinely
fine, and raising a captive portal would not fix a dead satellite modem. The remedy belongs
upstream of here — `loci-nmea-relay` buffers to SQLite and drains when the uplink returns,
which is the actual answer. Worth stating explicitly so nobody looks for it in wifi-connect.

If a connectivity-level check is ever wanted here, the binary already has
`confirm_connectivity_and_log`; `start.sh` has no equivalent and would need one.

### S7 — The saved AP is in range but refuses the association

`CTRL-EVENT-ASSOC-REJECT status_code=16` with an all-zero BSSID — the AP did not answer.
Not a credential failure. This is what actually stranded `be8bdb2` three times.

**Covered by M2's window and M4's ticks**, in that NetworkManager keeps retrying for the
whole `WIFI_CHECK_TIMEOUT` before the portal takes the interface, and M4 retries afterwards.
The original single 15-second sample pre-empted NetworkManager mid-attempt, which is what
made this fatal.

### S8 — Credentials are stale (the vessel changed its WiFi password)

The device has a profile that can never succeed. M4 will try it every tick forever. The
portal is the only remedy and there is nobody aboard to use it.

**Not covered, and not solvable from here.** Recovery requires an operator, an LTE fallback
(`loci-modem`), or a physical visit. Worth naming so it is not mistaken for a bug in M4.

### S9 — Several saved networks in range

M4 orders candidates most-recently-successful first, from its own cache at
`/data/reconnect-history.json` — NetworkManager exposes no usable last-connected timestamp.

**Covered.** If the cache is missing or corrupt it is treated as empty history: candidates
are still tried, just unordered. No credentials live in that file, so losing the volume
costs ordering, never access.

### S10 — The device's own hotspot pollutes its own scan

Immediately after tearing its own AP down, the just-removed `Loci-AP-<uuid7>` can still sit
in NetworkManager's scan cache. `get_access_points` returns as soon as the list is
non-empty, so the scan can "succeed" containing nothing but the device's own AP — no
candidate matches, the portal goes straight back up, and the next tick repeats it forever.

**Covered and proven.** The portal SSID is filtered out of scan results and a scan is
requested actively rather than waiting for the cache to refresh. `scenario-s4.sh` asserts
it directly: the device's own AP never appears in its own `Access points:` line, measured
seconds after tearing that AP down.

### S11 — Wired arrives or departs mid-session

Arriving: noticed on the next supervision pass, but the portal is not torn down mid-session
— the binary is only re-evaluated once it exits. Departing: noticed on the next pass, and
WiFi supervision resumes normally.

**Partially covered.** The arriving case is a deliberate simplification, not an oversight.

### S12 — An LTE modem is up (`loci-modem`)

`wwan0` is a USB device, so `/sys/class/net/wwan0/device` exists, and it carries no
`phy80211`/`wireless` symlink and does not match `wlan*`/`wl*`. **M1 will therefore almost
certainly classify it as a wired connection** and suppress wifi-connect entirely.

That is probably the behaviour you want — the device has connectivity — but it is
accidental rather than designed, and it has never been verified on a device with both a
modem and the WiFi stack. Check it before shipping `loci-modem` and wifi-connect together.

### S13 — Two Loci units within range of each other

Routinely observed: scans show `Loci-AP-<other-uuid7>` alongside real networks. Harmless —
a device has no credentials for a neighbour's portal, and the S10 filter removes only its
*own* SSID, which is correct.

### S14 — Repeated resets (power flapping)

Each reset restarts the whole sequence. With S5 handled, a stale portal profile no longer
compounds across reboots.

The trigger — poor vessel IT infrastructure, an intermittent VSAT link, unclean power — is
out of scope here. The design goal is that a reset costs minutes, not days.

---

## The NetworkManager tension

Worth stating plainly, because it cuts against the instinct to make wifi-connect more
aggressive.

**NetworkManager reassociates within seconds of an AP returning. M4 takes up to
`RECONNECT_INTERVAL_MINUTES`.** So every minute the portal holds `wlan0` is a minute in
which recovery is slower than doing nothing at all. The captive portal has positive value
only when a human is present to use it.

The evidence is in the field data: the one long outage that self-healed unaided
(2026-09-03 → 09-07) did so precisely because wifi-connect was *not* holding the interface
that boot.

`WIFI_CHECK_TIMEOUT` sizes one thing only: how long to let an association that is already
in flight finish. On a busy network that is seconds; 60 s is generous. It is **not** the
answer to "how long should we wait for an absent AP to come back" — that is a different
question with a different answer, and loading both onto one knob is how it briefly ended up
at 300 s.

**Proposed, not yet implemented.** `ACTIVITY_TIMEOUT` is the elegant answer and most of
what is needed: the portal exits if no visitor arrives (confirmed in `src/network.rs` —
`NetworkCommand::Timeout` returns when `!self.activated`), our `stop()` deletes the portal
profile on the way out, and the radio goes back to NetworkManager unaided. That makes
raising the portal cheap and reversible instead of a seizure.

It needs one companion: a gap between unattended portal offers, so the loop does not simply
re-raise the portal a minute later. A **fixed** gap, not exponential backoff — the backoff
buys little over a sensible constant and adds a state machine nobody wants to reason about
at 3am.

Suggested: `ACTIVITY_TIMEOUT=120` seconds with a ~15 minute gap between offers, giving
NetworkManager the radio roughly 90% of the time during a long outage. `ACTIVITY_TIMEOUT`
is an environment variable, so that half can be set on a fleet today with no release.

Two things to weigh before setting it:

- **The timer is one-shot, not a rolling idle timer.** `spawn_activity_timeout` sleeps once
  from process start and then sends `Timeout`, which is ignored if anyone has opened the
  portal (`self.activated`). So "unattended" means *nobody ever opened the page*.
  An installer who opens it and walks away does not strand the device, though — M4 is the
  escape hatch: `NetworkCommand::Reconnect` returns from the run loop when a saved network
  takes, so the binary exits within one tick and NetworkManager gets the radio back. The
  portal genuinely persists only when nothing joinable is in range, which is the one case
  where having it up is correct.

  That narrows what `ACTIVITY_TIMEOUT` buys: not rescuing an abandoned portal session, but
  handing the radio back to NetworkManager during the stretches when there is nothing to
  join — which is precisely the disturbance concern below.
- **It also applies during provisioning (S1).** An installer who takes longer than
  `ACTIVITY_TIMEOUT` to get their phone out will find the AP gone, and will have to wait
  out the gap before it returns. That argues for a generous timeout and a short gap on a
  fleet being installed, and the opposite on vessels already at sea.

One thing to keep in view: M4 runs *only* while the binary runs, so portal-up and
NetworkManager-in-control are mutually exclusive recovery modes. Favour NetworkManager —
it is faster at the common case by three orders of magnitude.

---

## Open questions

1. **S0 did not behave as expected during testing on 2026-09-15.** Undiagnosed.
2. ~~**S4 has never been observed working on hardware.**~~ Closed 2026-09-15 — proven in
   simulation, though still not on a device.
3. **S12 is unverified.** Does `wwan0` really read as wired?
4. **Does the supervision loop disturb NetworkManager in practice?** The tell is repeated
   `Starting WiFi Connect` / `WiFi Connect exited` pairs a few minutes apart.
5. **`ACTIVITY_TIMEOUT` + backoff** — agreed in principle, not built.

## Testing these

`tools/test/run.sh` covers every `start.sh` decision path with stubbed tools — no radio, no
container, no device. Scenario numbers in this file map to case names there.

See `docs/testing-connectivity.md` for that harness and for the `mac80211_hwsim` VM that
would cover real association behaviour.
