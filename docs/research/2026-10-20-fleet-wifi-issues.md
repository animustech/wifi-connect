# Fleet WiFi and connectivity issues ledger

As of 2026-10-20. Sources: device journals and container logs (≈3 days retained, be8bdb2 back to 09-24), balenaCloud, ais.positions (60 days), the wifi-connect scenario catalogue, agentmemory.

Scope: software issues only. Excluded are power and hardware faults, questions about where a unit is or what inventory exists, units still being provisioned at PT, and the Pi Zero 2 W and LTE, which are not actively pursued (`loci-on-balena/docs/STATE.md`).

Fleets: `gekko/loci-prod-pi5` (12 units, production, balenaOS 6.10.24, release 1.3.0) and `gekko/loci-pi5` (15 units, holding pen). Times are UTC. "Inference" marks anything not read directly from a log. Ids: S-ids are from `docs/connectivity-scenarios.md`, W-ids are from the written history, and F- and P-ids are local to this ledger.

Priority is 1-10, where higher is more urgent. It uses the workboard's scale and is the action's own priority where an action exists. Effort is the owner's hands-on hours (0.5, 1, 2, 4, 8, 16 or 40), including reviewing and testing, and is likewise taken from the existing action. Ids are stable: dropped entries leave gaps.

## Facing now

| id | priority | effort (h) | issue | container | devices | since | evidence | next step / action |
|---|---|---|---|---|---|---|---|---|
| F1 (S15) | 9 | 8 | NM keeps the saved WiFi profile blocked from autoconnect. The portal gives up and never activates the profile. Every unit running the shipped wifi-connect is exposed | wifi-connect | ed682d4 hit it; fleet exposed | 2026-09-28 (dark 21 d to 10-19) | 216 portal give-ups, 0 NM auto-activation attempts, vessel SSID in scans. Twin 0dbae4a recovered in minutes. Why NM blocked is unknown (journal rotated) | Fix in progress: explicit activation of saved profiles after give-up, plus an NM state log. `act_mvfjdoj3_0403946dadf4` |
| F3 | 8 | 2 | Relay dedup suppresses a replayed AIS track. `sessionHashes` is never cleared, so a unit that has already heard the generator's replay sends almost nothing, which blocks testing several units at once at PT. Production keeps the dedup by design, and ais.positions' unique key (source, mmsi, timestamp) remains the intended dedupe there | loci-nmea-relay | holding-pen units at PT (seen on ed682d4) | 2026-10-19 | Two-unit replay test on 10-19 at 18:01: the unit fresh from power-on delivered about 9/s, the other only 17 messages in the first minute | Add an env var that turns relay dedup off, and set it fleet-wide on gekko/loci-pi5, scoped to the service. With dedup off, the offline buffer's row key (the same hash, `mqttBuffer.ts:73`) must include the timestamp. Check each unit at its broker topic, because side-by-side units collapse into one row in ais.positions. `act_mvfknw5x_0d61f397b6ed` |
| F12 (W17) | 7 | 1 | The 5 min install window is too short. With the retry gap, the AP is held about 27% of the time | wifi-connect | prod fleet | 2026-10-07 | Owner request | The default rises to 10 min in wifi-connect (`docs/specs/2026-10-20-longer-install-window.md`) and ships in 1.3.3; prod moves two units at a time. `act_muy3ufb9_11d62ed172c6` |
| F7 (W14) | 6 | 8 | The vessel network hijacks NTP through DNS, so positions are stamped +464..536 s | loci-nmea-relay | fbbebff | 2026-10-14 | 915 rows corrected. Public NTP by IP in config.json is the mitigation | Mitigated on the device. Relay clock guard: `act_mv9lxxti_810ad73a5cf1` |
| F6 (S6) | 5 | 2 | MQTT keepalive timeouts, and EAI_AGAIN at relay restart, with no WiFi event | loci-nmea-relay | all online prod units | baseline | 2-31 keepalive timeouts per 14 d on every unit. EAI_AGAIN on 7 units' relay restarts | Decide whether to roll out the 30 s keepalive. `act_mv0mzmne_e35e452b6d27` |
| F11 (W2 residue) | 5 | 4 | Per-serial position sweep not done; loci-init retries without bound | loci-init | fleet | 2026-08-26 | Config-fetch blackout already fixed in the relay | `act_mv19na2k_314cef01e36d` |
| F9 (W16) | 4 | 4 | Units seen online that delivered nothing in 60 days: stale UDP config, no S3 config, or a silent receiver | loci-nmea-relay (S3 config) | a8b3a68 (last row 07-16), be465c3 | 2026-09-14 / 10-04 | Zero rows while the cloud saw the device | Stale UDP config clean-up: `act_mvfnc7c2_cf15839c0167`. Needs the units powered to confirm |
| F8 | 3 | 2 | Short WiFi drops that recover by themselves; brcmfmac `set chanspec ... reason -52` on drop days | host OS (NetworkManager, brcmfmac) | db55a37 (13 ssid-not-found 10-04..10-16), a94b11f (10-19 15:06, ~21 min), 7ef9558 (10-19 20:45, 3 cycles in 7 min), f697310 (10-14 14:01, ~1.5 h) | 2026-09-24 | `activated -> failed (reason 'ssid-not-found')`, `association took too long`, `ASSOC-REJECT 16`. wifi-connect waits 60 s, then rejoins, or gives up and NM takes over | Time-correlate -52 against NM disconnects on a94b11f and 7ef9558 before their journals rotate (≈3 d). New action needed |
| F10 | 3 | 2 | Relay falls back to `/dev/ttyACM0` when the config has no serialPath. a94b11f logged 8 "serial port closed unexpectedly", and 53ad5af logged "cannot open ttyACM0: no such device" | loci-nmea-relay | a94b11f, 53ad5af, 2b0d3b3 | 2026-10-06 | Relay log lines | Decide whether this is a fault or a harmless default. Low confidence. New action needed |
| F14 (S8) | 3 | 8? | Not covered by the design: the vessel changes its WiFi password, and the unit cannot rejoin until someone re-provisions it | wifi-connect | any | design | S8 cannot be solved on the unit alone | Effort: 8h? — it is unclear what a fix without someone on board would be. New action needed |

## Faced before

| id | issue | container | devices | first seen | root cause | fixed in / status | refs |
|---|---|---|---|---|---|---|---|
| W1 (S3, S4, S7) | Dark for hours after a power event: AP `Loci-AP-be8bdb2` up, no route. Outages of 18h45m, 5h45m and 28h | wifi-connect | be8bdb2 | 2026-09-08 | start.sh sampled `iwgetid` once, 15 s after the container started. ASSOC-REJECT 16 (the router is slower than the Pi). The portal then ran `sleep infinity` | FIXED: supervise loop 462b350, give-up e75a6fa; release 1.2.0 (wifi-connect 6aa3348d), prod 1.3.0 on all 12 units. Field-validated 09-16 on f5bffbf | STATE sec.1, sec.4; single-shot spec |
| W2 | Config-fetch blackout: the relay logs but sends nothing for up to 3 d (48% of be8bdb2's positions missing, 26 Aug to 9 Sep) | loci-nmea-relay | be8bdb2 | 2026-08-26 | Blocking S3 fetch with uncapped backoff | FIXED: relay 72da942 (1.0.2: 37ce051 dev, 39d0691 prod); config cache in 1.3.0. Residue: F11 | STATE sec.2, 14 |
| S0 | Bridges (balena0, docker0) read as wired, so wifi-connect never starts | wifi-connect | test rig | 2026-09-15 | Name-based interface filter | FIXED b3e9e18 (`/sys/class/net/<if>/device`). Wired skip confirmed 10-07 | scenarios S0 |
| S3 | Link lost hours after boot, no reconnect | wifi-connect | e3042ef, f5bffbf, be8bdb2 | 2026-09-15 | start.sh decided once | FIXED 462b350 (60 s debounce) | scenarios S3 |
| S4 | Stranded with nobody at the portal | wifi-connect | f5bffbf, e3042ef | 2026-09-16 | The periodic reconnect never fired (300 s timeout < 900 s interval) | FIXED e75a6fa; the reconnect is vestigial (c204fed) | scenarios S4 |
| S5 | A stale own-AP profile reads as healthy | wifi-connect | f5bffbf | 2026-09-15 | `iwgetid` shows the unit's own SSID | Guard added; the premise is false on the Pi 5 (6aa3348) | scenarios S5 |
| S10 | Own AP still in the scan cache after teardown | wifi-connect | any | 2026-09-15 | Scan cache | FIXED (filter plus active scan) | scenarios S10 |
| S1, S2, S9, S11, S13 | Provisioning and normal boot; ordering-cache limit; wired arriving mid-portal; two Loci APs | wifi-connect | n/a | design | Per the catalogue | Covered, or a known harmless limit | scenarios |
| W15 | A cross-fleet move downgraded two units to 0.0.5 on retired listeners and purged their volumes | all (fleet move) | #900 (2f6621fd717d65e9), #901 (844bb0a877645012) | 2026-08-25 | `balena device move` | FIXED by pushing 1.0.0 to dev; rule added to CLAUDE.md | lsn_365d5b55ae6cfe2f |
| W16 | A new unit first boots on a stale UDP S3 config and delivers nothing | loci-nmea-relay (S3 config) | fc2208e | 2026-10-19 | Pre-cutover S3 file pinned to udp | FIXED 10-19 17:27 (4460 rows landed). The fleet-wide residue is F9 | STATE sec.20 |
| W18 | Cloud and log blind spots: IS ONLINE lags 25 s to 7 min, and cloud logs end hours before a unit dies | n/a (balenaCloud) | all | 2026-09-16 | balena | Use the NM journal and ais.positions max(timestamp) instead | lsn_76a68ebe465075f0, lsn_247e576a9f33a8e6 |
| P1 | 0dbae4a's profile was re-created on 10-11 at 00:12/00:17 and on 10-12 at 08:31/08:36 (`ssid-not-found`, `connection-removed`, reactivated within 10 s to 1 min) | host OS (NetworkManager) | 0dbae4a | 2026-10-11 | Unknown. The 5 min spacing looks like a profile rewrite by the portal or a person (inference) | Recovered by itself; no catalogue id (new) | pi5 sweep |
| P2 | be8bdb2 lost WiFi on 2026-09-26 10:56-11:39: link timeouts at 11:02 and 11:32, final disconnect 11:39, a `WRONG_KEY` label after repeated rejects | host OS (NetworkManager) | be8bdb2 | 2026-09-26 | AP or vessel network instability (inference; the key was not changed) | Recovered by itself; no catalogue id (new) | prod-a sweep |
| P3 | ed682d4 dark from 2026-09-28 08:36 to 2026-10-19 11:54 (21.1 d); only a power cut cleared it | wifi-connect | ed682d4 | 2026-09-28 | See F1 | Open under F1 (fix not shipped) | S15 spec |

## Per-device timeline

Log coverage: J = persistent host journal (window), C = container logs, CL = balena cloud logs only, none = no logs retrievable. Only software incidents are listed.

### gekko/loci-prod-pi5

| uuid7 | serial | vessel | online now | last delivery | incidents | log coverage |
|---|---|---|---|---|---|---|
| dd8913d | 22c8ef5089e69504 | not recorded | yes | 10-20 08:18 | relay keepalive flaps 2-8 a day, no WiFi event (F6) | J 10-02..now; C relay from 10-06 |
| be8bdb2 | 281f6bebcbde050c | Deep Runner (Murphy), unit 515 | yes | 10-20 08:17 | W1 strands 09-03..09-15; W2; 09-26 WiFi loss (P2); 10-14 12:24 loss for 45 s; 9 EAI_AGAIN (F6) | J 09-24..now; C relay from 10-01 |
| 2b0d3b3 | 678511feb931dec8 | not recorded | no (10-14 03:02) | 10-14 03:01 | no software incident in the retained logs; serialPath fallback (F10) | CL 10-13 16:59..10-14 02:00 only |
| 1c8293e | 6bac6a19077e8de2 | @PT, being provisioned | yes | 10-16 23:40 | being provisioned; relay keepalive storm 10-09/10-10 (F6) | J 10-02..now; C relay |
| 6939fd9 | 6f3bf174fd58a870 | "Loci-005 @ Kings Quay" (plan) | yes (WiFi MOC-GUEST plus eth0) | 10-20 08:18 | none | J 10-02..now; C relay |
| 53ad5af | 70049c16d1d11934 | not recorded | no (10-15 20:41) | 10-15 20:40 | relay could not open ttyACM0 (F10) | CL 10-13 16:28..10-15 20:09 |
| 7ef9558 | 85d1220a3a86f6b2 | not recorded (VSAT, Java-Secure) | yes | 10-20 08:14 | 10-19 20:45 roaming / ASSOC-REJECT cycles and brcmfmac -52 (F8) | J 10-02..now; C relay |
| a94b11f | d7fa28075b1a9c27 | "Loci-008 @ Vietnam" (plan) | yes | 10-20 08:18 | 10-19 15:06-15:27 WiFi loss, portal give-up, NM recovered (F8); 8 serial port closes (F10) | J 09-16..now; C relay from 10-06, wifi-connect 10-19 only |
| f6b674a | df78fe710b79919b | not recorded | no (10-18 11:36) | 10-18 11:34 | no software incident in the retained logs | CL 10-11 22:00..10-17 18:00 |
| fbbebff | e4d1649576072f90 | @PT, being provisioned | yes (ethernet) | 10-20 08:19 | being provisioned; NTP skew 10-14 (F7) | J 10-13..now; C wifi-connect from 10-13 06:37 |
| db55a37 | f75b9adc2083f61b | "Loci Lite 505 @ Congo" (Ms. Jolie) | yes | 10-20 08:18 | 13 ssid-not-found drops 10-04..10-16, -52 on many days (F8); 29 keepalive timeouts, 20 ECONNRESET (F6) | J 10-02..now; C relay from 10-06 |
| f697310 | f8470a1312c023c1 | "Loci Lite 513 @ PT" (plan) | yes | 10-20 08:18 | 10-14 14:01 supplicant-disconnect, give-up, recovered (F8) | J 10-02..now; C relay |

### gekko/loci-pi5

| uuid7 | serial | vessel | online now | last delivery | incidents | log coverage |
|---|---|---|---|---|---|---|
| ed682d4 | 18505d96487077ca | "unit 50022", Prospect_WiFi | no (10-19 18:32) | 10-19 18:31 | F1 / P3; F3 | CL 10-19 15:00..17:49 |
| 0dbae4a | 47fab2dca1a4b8ca | "unit 50023", @PT, being provisioned | yes | 10-19 18:34 | being provisioned; profile re-created 10-11 and 10-12 (P1) | J 10-02..now; C relay and wifi-connect |
| fc2208e | b71c2ac04604e13e | new unit 10-19 | no (10-19 18:28) | 10-19 18:26 | W16 (fixed); keepalive flaps 18:11 (F6) | CL 10-19 18:00..18:23 |
| a8b3a68 | 1b33790e7dbfa310 | not recorded | no (10-04) | none in 60 d (last row 07-16) | F9 | none |
| be465c3 | 93f403a592104da8 | not recorded | no (09-14) | none in 60 d | F9 | none |

These units have no software incident and no retrievable logs; they look shelved. All 10 are offline: 1645520, 82e48f6, d323096, 0b15bf2, a022612, f07cb4a, 015215d, 6565850, b349f82, b6653c4.

## Patterns

1. **brcmfmac `set chanspec ... fail, reason -52`** shows on 7ef9558 (15 per chanspec, on or near 10-19), a94b11f (83 on 10-19, 8 on 09-16), f697310 (33 on 10-14) and db55a37 (8-46 a day on 10 days). a94b11f, f697310 and 7ef9558 each had a drop on the same day. db55a37 also has the noise on days without drops, and its drops on 10-04 and 10-05 coincide with it. This is coincidence so far, not shown to be causal: timing was not extracted per line. dd8913d, 1c8293e, 6939fd9 and 0dbae4a show no such noise.
2. **`ssid-not-found` roams** on db55a37 (13), a94b11f, be8bdb2, 7ef9558 and 0dbae4a. The AP vanished from the scan for seconds to minutes, and NM reactivated it. All recovered by themselves, so the cause is on the vessel side (inference). Do not confuse this with F1: here NM does retry.
3. **EAI_AGAIN at relay start** on 53ad5af, 2b0d3b3, f6b674a, fbbebff, f697310, be8bdb2 (9), ed682d4, fc2208e and 0dbae4a. The relay starts before DNS is ready, falls back to the cached config and recovers within about 10 s. It is a boot race (inference), and nothing has been seen to result from it except a stale clock.
4. **Keepalive timeouts with no WiFi event** on every online prod unit (2-31 per 14 d; 1c8293e 29 in 24 h). The link stays up while the broker session flaps. Upstream, not WiFi.
5. **An ASSOC-REJECT 16 pair after every boot** (be8bdb2 21, 7ef9558 8) is harmless: CONNECTED follows within seconds. It is the same status code that drove W1, and the 60 s debounce now absorbs it.

## Gaps in the evidence

- **Journal rotation.** Journals reach back about 3 days on busy units (fbbebff 7 d; be8bdb2 26 d and dd8913d 17 d, because their journals are small). Anything older can be recovered only from ais.positions gaps, which show that data stopped, not why.
- **Gaps versus AIS silence.** The gaps report cannot tell a lost link from a receiver that hears nothing. a94b11f and f697310 (about 470 rows a day since 10-11) did not get the serial rx check.
- **Undelivered periods versus WiFi events.** ais.positions gaps were not joined to NM events, except where the history already did so (be8bdb2).
- **Contradictions resolved.**
  - The scenario catalogue lists S0 wired detection as an open question. Lesson lsn_e93e6dcb6df011e3 says the wired skip was confirmed on 10-07. The doc is stale.
  - ACTIVITY_TIMEOUT: the scenario doc says 120 s in one place and 300 s in the table. Traces (299.99 s) say 300.
