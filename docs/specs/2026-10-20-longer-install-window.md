# A 10-minute install window

## What

Raise the default `ACTIVITY_TIMEOUT`, the time the captive portal waits for someone to open it
before giving up, from 300 s to 600 s. Ship it in the same release as the recovery of saved
networks that NetworkManager will not autoconnect (1.3.3). Roll that release out to
`gekko/loci-prod-pi5` two units at a time.

## Why

- Installers need longer than 5 minutes to reach the portal on board (owner request,
  2026-10-07, `act_muy3ufb9_11d62ed172c6`, which asked for 15 minutes). 10 minutes is the first
  step, because a longer window delays rejoining once the vessel network returns.
- A default in code lets the change travel with the other fixes in 1.3.3. A fleet env var
  would be a second change to stage and later remove.

## The trade-off

While the AP is up, the unit cannot rejoin the vessel's WiFi. If the network returns during a
portal window, the unit rejoins only when the window ends. Positions are buffered meanwhile, so
the cost is delay, not data loss. Over a long outage, with `PORTAL_RETRY_GAP` at 900 s:

| window | AP share | worst-case late rejoin | average late rejoin |
|---|---|---|---|
| 300 s (today) | ~24% | 5 min | ~0.5 min |
| 600 s | ~39% | 10 min | ~2 min |

600 s stays below the periodic reconnect's 900 s tick (M4, `RECONNECT_INTERVAL_MINUTES` = 15).
So the portal still gives up first, as `docs/connectivity-scenarios.md` documents and the s4
rig scenario guards.

## Acceptance criteria

1. With no `ACTIVITY_TIMEOUT` set, `start.sh` passes 600 to wifi-connect. A harness case pins
   it.
2. An explicitly set `ACTIVITY_TIMEOUT` still wins. A harness case pins it.
3. The tier-1 harness and every hwsim scenario pass, including s4's guard that M4 never fires.
4. The docs state 600 s wherever they state the default: the knobs table in
   `docs/connectivity-scenarios.md`, `docs/testing-connectivity.md`, and the stale "120 s" line.
   The S4 text that relies on the window being shorter than the M4 tick still holds.
5. Before rollout, `balena env list` shows no fleet-level or device-level `ACTIVITY_TIMEOUT` on
   `gekko/loci-prod-pi5` that would override the new default.
6. Rollout: 1.3.3 is released to `gekko/loci-prod-pi5` while every unit is still pinned to
   1.3.0, so nothing moves. Then two online units at a time are moved to 1.3.3. Each pair is
   checked before the next pair moves:
   - the `wifi-connect` and `loci-nmea-relay` container names carry the 1.3.3 release;
   - the unit did not reboot unexpectedly;
   - `ais.positions` keeps receiving rows from both serials.
   Units that are offline at rollout move when they come back.

## Non-goals

- 900 s. If installers still run out of time, try it on one unit with a device env var before
  changing the default. At 900 s the window equals the M4 tick, so the default change would
  also need `RECONNECT_INTERVAL_MINUTES` raised.
- `PORTAL_RETRY_GAP` stays at 900 s.
- No Rust change, and M4 is not revived.
- Anything else that 1.3.3 brings to prod (1.3.1's clock trust, 1.3.2's AIS filter, the S15
  recovery) is covered by its own spec. This spec only sets the batch size it rolls out with.
