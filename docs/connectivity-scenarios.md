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
| M4 | Periodic reconnect | `wifi-connect` binary (`src/network.rs`) | Never, at shipped settings — see S4 |

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
| `RECONNECT_INTERVAL_MINUTES` | 15 | M4 tick — longer than `ACTIVITY_TIMEOUT`, so M4 never fires |
| `RECONNECT_RESCAN_EVERY` | 2 | Force a fresh scan every Nth tick |
| `ACTIVITY_TIMEOUT` | 300 s | The portal gives up if nobody opens it in that time, handing the radio back |
| `PORTAL_RETRY_GAP` | 900 s | After it gives up, how long the radio is left to NetworkManager before offering the portal again |

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
the binary so M3 comes back.

**The debounce, measured on `f5bffbf` 2026-09-16.** A deliberate short outage:

```
08:32:44.086  Connection lost - waiting up to 60s for it to return
08:33:04.177  WiFi connected to #Skyroam_t0n
```

20.1 s, absorbed whole. No portal, no AP raised, `wlan0` never left station mode —
NetworkManager reassociated in 4.6 s (`disconnected -> prepare` 08:32:57, DHCP lease and
`Activation: successful` 08:33:01) and `start.sh` stayed out of the way.

**So an outage shorter than `WIFI_CHECK_TIMEOUT` costs nothing.** Longer than that and you
pay the full portal cycle: up to `ACTIVITY_TIMEOUT` before the give-up, then seconds to
recover. Note the detection lag — the drop can precede the `Connection lost` line by up to
`SUPERVISE_INTERVAL`, so the real tolerated outage is 60-120 s, not a flat 60.

**Partly covered before, fully covered as of `1.2.0-wifi-connect.2`.**

Be precise about what was missing. NetworkManager has always retried on its own and is
good at it — on `e3042ef` the 37-minute gap ended **4 seconds** after the AP returned, and
that was NetworkManager, not us. What was absent was the portal and M4 as a *fallback*:
`start.sh` decided once and then slept forever, so after the first successful connection
there was no portal process and no reconnect timer for the rest of the boot. If
NetworkManager had not recovered it, nothing would have.

### S4 — Boots with the network absent, nobody attends the portal

M3 raises the AP. What then rescues the device is **not** M4.

**M4 cannot fire at shipped settings.** `spawn_activity_timeout` is a one-shot
`sleep(ACTIVITY_TIMEOUT)`, and `spawn_periodic_reconnect` is `loop { sleep(interval); ... }`
— it sleeps *before* its first tick. So M4 only ever runs when

```
ACTIVITY_TIMEOUT > RECONNECT_INTERVAL_MINUTES x 60      (or ACTIVITY_TIMEOUT = 0)
```

Shipped defaults are 300 s against 900 s, so the portal always exits first and **M4 never
ticks in production**. It is vestigial rather than broken: `ACTIVITY_TIMEOUT` arrived with
the duty-cycle work, after M4 was written, and superseded it.

**What actually recovers the device** is the give-up path. The portal exits at
`ACTIVITY_TIMEOUT`, deletes its own profile, and hands `wlan0` back to NetworkManager,
which auto-activates the saved vessel profile.

**Measured in the field** — `f5bffbf`, 2026-09-16, production settings, nobody touching
anything:

```
08:01:17.780  Starting HTTP server on 192.168.42.1:80
08:06:17.780  Timeout reached. Exiting...                  <- exactly 300.000159 s
08:06:17.782  NM: activated -> deactivating (reason 'connection-removed')
08:06:25.380  NM: policy: auto-activating connection '#Skyroam_t0n'
08:06:30.922  NM: Activation: successful, device activated
```

**13.1 seconds** from give-up to associated — roughly 70x faster than M4's 900 s tick would
have been, which is the entire reason `ACTIVITY_TIMEOUT` exists. (The AP was already back
in that run, so this measures the give-up, not the reacquire.)

**And the true vessel case** — same device, same day, a 7.5-minute outage with the AP
absent across the whole give-up:

```
08:43:04.305  Connection lost - waiting up to 60s for it to return
08:44:13.486  Starting HTTP server on 192.168.42.1:80
08:49:13.486  Timeout reached. Exiting...                  <- 299.999825 s
08:49:13.974  NM: wlan0 disconnected - radio handed back
     (7 m 32 s: AP absent, radio free, NetworkManager watching, start.sh asleep)
08:56:45.525  NM: policy: auto-activating connection '#Skyroam_t0n'
08:56:50.077  NM: Activation: successful, device activated
```

**4.6 s** from the AP returning to associated with a lease. The device spent the outage in
the best possible state: radio released, nothing holding it. At upstream's
`ACTIVITY_TIMEOUT=0` it would still have been sitting in AP mode, dark, waiting for someone
to walk up with a phone — the failure that took a production vessel dark three times in
twelve days.

`start.sh` logs nothing between the give-up and the end of `PORTAL_RETRY_GAP`, so **silence
there is the design working, not a hang**. The reconnect evidence lives only in the
NetworkManager journal.

One trap in the log above: the binary's `Access points:` line still listed the vessel SSID a
minute after the AP was switched off. That is NetworkManager's scan cache, not ground truth.

**Do not measure this from balenaCloud.** That same device only flipped `IS ONLINE: true` at
08:13:23, nearly seven minutes after it was actually associated. The lag is the VPN
reconnecting, not the network. Read the NetworkManager journal instead — measuring from the
dashboard makes a 13-second recovery look like a 7-minute one.

**Covered by `tools/hwsim/scenarios/s4-stranded-recovers.sh`** at production ratios. M4's
legacy behaviour is kept under test separately, in `s4b-m4-legacy-reconnect.sh`, which has
to force `ACTIVITY_TIMEOUT=0` to reach it at all — that override is the proof M4 is
unreachable otherwise.

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

**Covered, with a measured limit.** If the cache is missing or corrupt it is treated as
empty history: candidates are still tried, just unordered. No credentials live in that file,
so losing the volume costs ordering, never access.

The cache only records connections **wifi-connect itself** made — via the portal or a
reconnect tick. NetworkManager's own autoconnect, which is how a healthy device connects
almost every time, is never recorded. A unit that has been online for months therefore has
an empty cache and arbitrary ordering the first time M4 runs. Found by
`tools/hwsim/scenarios/s9-ordering.sh`, which originally asserted the documented behaviour
and failed.

### S10 — The device's own hotspot pollutes its own scan

Immediately after tearing its own AP down, the just-removed `Loci-AP-<uuid7>` can still sit
in NetworkManager's scan cache. `get_access_points` returns as soon as the list is
non-empty, so the scan can "succeed" containing nothing but the device's own AP — no
candidate matches, the portal goes straight back up, and the next tick repeats it forever.

**Covered and proven.** The portal SSID is filtered out of scan results and a scan is
requested actively rather than waiting for the cache to refresh. Both S4 scenarios assert
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

**Implemented.** `ACTIVITY_TIMEOUT` defaults to 120 s here, against upstream's 0: the portal
gives up if nobody opens it (`src/network.rs` — `NetworkCommand::Timeout` returns when
`!self.activated`, and `run()` calls `stop()` unconditionally, which deletes the portal
profile and releases the radio). `PORTAL_RETRY_GAP` then leaves the radio alone for 15
minutes before offering the portal again — without it the loop would simply re-raise the
portal a minute later and the timeout would buy nothing.

A **fixed** gap, not exponential backoff: the backoff buys little over a sensible constant
and adds a state machine nobody wants to reason about at 3am.

Measured on the hwsim rig with an AP that stays down, sampling whether `wlan0` is in AP
mode (compressed timings — the ratio transfers, not the absolute numbers):

| | radio held by wifi-connect | available to NetworkManager |
|---|---|---|
| upstream default (portal never gives up) | 75% | 25% |
| 20 s timeout : 60 s gap (1:3) | 34% | 66% |
| 50 s timeout : 150 s gap (1:3, the shipped ratio) | 27% | 73% |

The shipped 300 s : 900 s is that same 1:3 ratio, so expect roughly **27% held**. Widening
the gap to 1800 s would land near 14%, at the cost of a longer wait for an installer who
misses the portal window.

The provisioning trade-off is real: an installer who takes longer than `ACTIVITY_TIMEOUT`
to get their phone out finds the AP gone and must wait out the gap. For a fleet being
installed, raise `ACTIVITY_TIMEOUT` and drop `PORTAL_RETRY_GAP`; both are environment
variables, so that is a fleet setting, not a release.

One thing to keep in view: M4 runs *only* while the binary runs, so portal-up and
NetworkManager-in-control are mutually exclusive recovery modes. Favour NetworkManager —
it is faster at the common case by three orders of magnitude.

---

## What is actually tested

Tier 1 is `tools/test/run.sh` (12 cases, stubbed tools, no radio, seconds). Tier 2 is
`tools/hwsim/run-scenarios.sh` (9 scenarios, the real container on virtual radios, minutes).

| Scenario | Tier 1 | Tier 2 |
|---|---|---|
| S0 wired, and the bridges-only field-bricking regression | yes | — |
| S1 operator provisions through the portal | yes | yes (real HTTP: `/networks`, `/connect`) |
| S2 associated at boot | yes | — |
| S3 link lost later, and the brief-flap debounce | yes | — |
| S4 stranded, unattended recovery | yes | yes |
| S5 stale portal AP, both branches | yes | — |
| S6 associated with no route | — | yes (characterisation: must do nothing) |
| S7 AP present but rejecting | — | yes |
| S8 stale credentials | — | yes (proves the limit, not a fix) |
| S9 reconnect ordering | — | yes |
| S10 own AP in scan | — | yes (asserted inside S4 and S13) |
| S11 wired arriving mid-portal | yes | yes |
| S12 LTE reads as wired | yes | — |
| S13 two Loci units in range | — | yes |
| S14 repeated restarts | — | yes |

Every scenario in this document now has at least one test. Two caveats on what that means:

- **S14 restarts the container, not the device.** Kernel and NetworkManager state survive, so
  it proves service-level behaviour only — not a power cut.
- **S7 approximates.** `status_code=16` in the field was an AP that did not answer at all;
  the rig reproduces it with a hostapd MAC deny list, which is a deliberate refusal. Same
  observable, different cause.

### What writing the tests found

- **`WIRED_CHECK_TIMEOUT` was hardcoded at 10 s**, so every boot burned ten seconds in the
  wired wait before the WiFi check began.
- **The reconnect-history cache only records connections wifi-connect made itself** — through
  the portal, or through a reconnect tick. A connection NetworkManager makes on its own never
  appears, and NM autoconnect is the normal case on a healthy device. So on a unit that has
  simply been online for months the cache is empty and M4's ordering is arbitrary. It still
  tries every candidate, so this costs time, not recovery — but "most-recently-connected
  first" overstates what happens in practice.

## Open questions

1. **S0 did not behave as expected during testing on 2026-09-15.** Undiagnosed.
2. ~~**S4 has never been observed working on hardware.**~~ Closed 2026-09-15 — proven in
   simulation, though still not on a device.
3. **S12 is unverified.** Does `wwan0` really read as wired?
4. **Does the supervision loop disturb NetworkManager in practice?** Now bounded rather
   than unknown — see the duty-cycle measurement above — but still unobserved on a device.
   The tell in the field is repeated `Starting WiFi Connect` / `gave up` pairs.
5. ~~**`ACTIVITY_TIMEOUT` + backoff**~~ Closed 2026-09-15 — implemented as a fixed gap and
   measured.

## Testing these

`tools/test/run.sh` covers every `start.sh` decision path with stubbed tools — no radio, no
container, no device. Scenario numbers in this file map to case names there.

See `docs/testing-connectivity.md` for that harness and for the `mac80211_hwsim` VM that
would cover real association behaviour.
