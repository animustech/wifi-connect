# Testing the connectivity scenarios without a device

Two tiers. They answer different questions and cost wildly different amounts. Build tier 1
first — it covers most of what has actually gone wrong.

Scenario numbers refer to `connectivity-scenarios.md`.

---

## Tier 1 — shell harness for `start.sh` — BUILT

`tools/test/run.sh`. No radio, no container, no device — it runs on the macOS the work is
done on, in seconds, with no dependencies. Deliberately bash 3.2 compatible.

```bash
tools/test/run.sh          # all cases
tools/test/run.sh s5       # cases matching a substring
```

**What it proves:** that `start.sh` makes the right decision in every state. Nothing about
radios.

Every defect found on 2026-09-15 was a decision bug, not a radio bug:

- the wired check misreading bridge interfaces as Ethernet (field-bricking),
- `if false && wired_connected` shipping in a debug commit,
- a single association sample pre-empting NetworkManager,
- `iwgetid` reporting our own hotspot as a healthy connection (S5),
- `sleep infinity` ending supervision for the rest of the boot (S3).

**All five are reachable with stubs.** No WiFi required.

### How it works

`start.sh` touches the outside world through exactly four things, and all four are
replaceable:

| Dependency | Stub as |
|---|---|
| `iwgetid -r` | script on `PATH` echoing a fixture SSID, or exiting 1 |
| `ip -4 -o addr show` | script on `PATH` printing fixture output |
| `/sys/class/net/*` | a fixture tree, injected via a `SYSFS_ROOT` variable |
| `./wifi-connect` | script that logs its argv, then exits on cue |

Four seams were added to `start.sh` for this, all inert in production: `SYSFS_ROOT`,
`WIFI_CONNECT_BIN`, `MAX_PASSES` (bounds the supervision loop so tests terminate) and
making `WIRED_CHECK_TIMEOUT` overridable instead of hardcoded.

Building the harness immediately earned its keep: the hardcoded `WIRED_CHECK_TIMEOUT=10`
meant every boot burned ten seconds in the wired wait before the WiFi check even began,
which nobody had noticed.

A case looks like this:

```bash
# tools/test/cases/s5-stale-portal-ap.sh
describe "S5  our own stale portal AP is not a connection"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Loci-AP-e3042ef"        # our own AP — must NOT count as connected
run_start_sh --passes 1
assert_launched
assert_log "Stale portal AP"
refute_log "WiFi connected to Loci-AP"
```

Ten cases at present: S0 wired, S0 bridges-only (the field-bricking regression), S2
associated, S3 link-lost, S3 brief-flap-is-debounced, S4 never-associates, S5 own-AP, S5
no-pointless-wait, S11 wired-while-WiFi-down, S12 `wwan0`-reads-as-wired.

No CI yet, by choice. It is an executable you run.

### What tier 1 cannot tell you

Anything involving a real radio, NetworkManager, or the Rust binary: S7 (association
rejected), S10 (own AP in the scan cache), all of M4, and the NetworkManager-disturbance
question.

---

## Tier 2 — `mac80211_hwsim` in a Linux VM — BUILT

```bash
tools/hwsim/vm-up.sh                      # create + provision the VM (idempotent)
limactl shell wifitest sudo /tmp/hwsim/ap.sh setup     # namespaces + radio placement
limactl shell wifitest sudo /tmp/hwsim/ap.sh up|down|status
limactl shell wifitest sudo /tmp/hwsim/baseline.sh
```

**`vm-up.sh` does not put the rig or the image in the VM** — it only creates and
provisions the machine. Lima mounts `~` but this repo lives outside it, so both have to be
copied in, and a VM reboot wipes `/tmp`. **Always re-run `vm-up.sh` after a VM reboot before
copying anything**: it is what guarantees four `mac80211_hwsim` radios. Then re-do these two:

```bash
# the rig -> /tmp/hwsim   (--no-xattrs keeps macOS provenance attrs out of the tar)
tar c --no-xattrs tools/hwsim | limactl shell wifitest sudo tar x -C /tmp --strip-components=1
limactl shell wifitest sudo sh -c 'chmod +x /tmp/hwsim/*.sh'

# the source -> /tmp/wcsrc, and the image the scenarios run ($IMAGE, wifi-connect:test)
limactl shell wifitest sudo rm -rf /tmp/wcsrc && limactl shell wifitest sudo mkdir -p /tmp/wcsrc
tar c --no-xattrs --exclude=.git --exclude=target --exclude=.worktrees . \
  | limactl shell wifitest sudo tar x -C /tmp/wcsrc
limactl shell wifitest sudo sh -c \
  'cd /tmp/wcsrc && cp Dockerfile.template Dockerfile && docker build -t wifi-connect:test .'
```

`Dockerfile.template` is copied to `Dockerfile` because it is a plain Dockerfile here — it
carries no balena `%%` substitutions. Docker's layer cache survives the VM reboot, so a
rebuild after a source change is seconds unless the Rust dependencies moved.

**The rig needs four radios**: `wlan0` is the device, and `ap.sh` claims one each for slots
`1`, `2` and `peer`. A short rig fails as `Cannot find device "wlan1"` during a scenario's
*setup*, which reads as a scenario failure but is not one. Check with

```bash
limactl shell wifitest sudo sh -c 'ls -d /sys/class/ieee80211/phy* | wc -l'   # must be 4
```

**Built and working:** two virtual radios, a WPA2 AP with DHCP in its own network
namespace, a device radio under NetworkManager, and a measured baseline.

The real container runs against it — the image built from this repo, with host networking,
the system D-Bus socket and a `/data` volume, exactly as the compose service has it.

```bash
limactl shell wifitest sudo /tmp/hwsim/run-scenarios.sh        # all
limactl shell wifitest sudo /tmp/hwsim/run-scenarios.sh s4     # just the S4 pair
```

**One caveat about the rig, worth understanding before trusting a result.** A vessel Pi has
no cable, but the VM cannot drop its own Ethernet uplink without killing the shell driving
it — and `start.sh` correctly treats that uplink as a wired connection and suppresses
wifi-connect entirely. So the container is given a `SYSFS_ROOT` view containing only the
radio. Everything else is real: NetworkManager, D-Bus, wpa_supplicant, the radio. That the
rig hit this at all is itself a faithful reproduction of S0 and S12.

```bash
limactl shell wifitest sudo /tmp/hwsim/run-scenarios.sh        # all nine
limactl shell wifitest sudo /tmp/hwsim/run-scenarios.sh s7     # one
```

Nine scenarios, each asserted rather than eyeballed. Four virtual radios: the device, two
vessel APs (so ordering can be tested) and a neighbouring Loci unit's portal.

### Traps that cost time, so they are in the scripts

- **`pgrep` is not namespace-aware.** The process table is shared across network namespaces,
  so `ip netns exec ap2 pgrep -x hostapd` happily finds slot 1's AP. Worse, `pkill -x
  hostapd` inside one namespace kills every AP on the box. Track pids per slot.
- **Reloading `mac80211_hwsim` renumbers the phys** — `phy0..3` became `phy2..5`. Resolve
  `netdev -> phy` at runtime, never hardcode.
- **A scenario with a syntax error sourced as a pass.** `.` aborts partway, assertions never
  run, and the failure counter stays at zero. The runner now `bash -n`s every case first; a
  case that never ran must never read as green.
- **NetworkManager's scan cache lags a freshly started AP** by several seconds, and `nmcli
  device wifi connect` fails outright rather than waiting — which looks like a broken AP.
  Wait for the SSID to be visible, then connect.

### What it has proven so far

**S4, the scenario that could never be observed on hardware.** A device stranded with its
portal up, the vessel AP returning, nobody touching anything — it recovers.

Note *how* it recovers, because the rig originally got this wrong. At production settings
the portal's `ACTIVITY_TIMEOUT` (300 s) expires long before M4's first tick (900 s), so the
portal gives up, deletes its profile and hands `wlan0` back, and **NetworkManager** does the
reconnecting. `s4-stranded-recovers.sh` asserts that path and *refutes* M4's log lines, so
raising `ACTIVITY_TIMEOUT` above the tick fails the run instead of silently changing what is
under test. M4's own path still works but is only reachable with `ACTIVITY_TIMEOUT=0`, and
is kept under test separately as `s4b-m4-legacy-reconnect.sh`.

Both assert S10 — the device's own AP never appears in its own scan.

Confirmed in the field on `f5bffbf`, 2026-09-16: give-up at exactly 300.000159 s, associated
13.1 s later, no M4 tick anywhere in the boot.

### The baseline it also produced

With wifi-connect **not running at all**, NetworkManager reacquires the AP **5–10 seconds**
after it returns, keeping its DHCP lease. Measured repeatedly on 2026-09-15.

That single number is the yardstick for every design decision here. M4's tick is 15
minutes. So any time wifi-connect holds the radio during an outage, recovery is roughly two
orders of magnitude slower than doing nothing — which is why the supervision loop must hand
the radio back rather than camp on it.

**What it proves:** real association behaviour, the reconnect path, and whether the
supervision loop disturbs NetworkManager.

`mac80211_hwsim` is the kernel's virtual WiFi radio driver — the same thing the
wpa_supplicant and kernel test suites use. It creates N fully functional virtual radios
that associate with each other through a simulated medium. hostapd, wpa_supplicant and
NetworkManager all treat them as real hardware.

### Why not Docker Desktop

Docker Desktop's LinuxKit VM does not ship `mac80211_hwsim` and you cannot reasonably
`modprobe` into it. Use a real Linux VM. On Apple Silicon, Lima runs arm64 natively — no
emulation, and the same architecture as the Pi 5.

Debian rather than Ubuntu: it is what the container images are built on
(`debian:trixie`), so NetworkManager, wpa_supplicant and D-Bus versions line up with what
actually ships.

`tools/hwsim/vm-up.sh` does all of it. Three things in there were not obvious and each
cost real time:

- **Debian's cloud kernel has no `mac80211_hwsim`.** Installing `linux-image-arm64`
  alongside it is not enough — GRUB keeps booting the cloud kernel, so it has to be purged
  outright and the VM rebooted. `modinfo mac80211_hwsim` is the check.
- **NetworkManager must be told to leave `eth0` alone *before* it is installed**, or it
  takes over the VM's uplink and the Lima shell dies with it.
- **`pkill -f hostapd` kills the shell running it**, because the pattern matches that
  shell's own command line. Use `pkill -x hostapd`.

Also: without a DHCP server in the AP namespace, association succeeds and IP configuration
then times out, which reads like an auth failure and sends you hunting in the wrong place.

### Shape of the rig

- **Radio A** is the vessel AP: move its phy into a network namespace
  (`iw phy phy1 set netns <pid>`), run `hostapd` on it. Bringing the scenario's AP "down"
  is `systemctl stop hostapd` — instant, scriptable, repeatable.
- **Radio B** is the device: leave it in the main namespace under NetworkManager, exactly
  as balenaOS has it.
- Run the wifi-connect container against radio B with `--privileged --network host` and the
  system D-Bus socket bind-mounted, mirroring the compose service.

### What each scenario becomes

| Scenario | How to stage it |
|---|---|
| S1 | No saved profile, start the stack, drive the portal over HTTP at `192.168.42.1` |
| S2 | Pre-seed an `.nmconnection`, boot, assert the binary never launches |
| S3 | Associate, then `systemctl stop hostapd`, assert the portal appears and when |
| S4 | Start with hostapd down; bring it up and wait for the portal to give up and NM to reacquire |
| S6 | hostapd up with no upstream route — proves association ≠ connectivity |
| S7 | hostapd configured to reject associations, or `max_num_sta=0` |
| S10 | Assert the portal SSID never appears in the binary's own `Access points:` log line |
| NM tension | Count `Starting WiFi Connect` / `WiFi Connect exited` pairs over a staged hour-long outage |

S4 and the NetworkManager question are the two that matter most and that nothing else can
answer.

### Caveats

- balenaOS is not Ubuntu. The D-Bus socket path (`/host/run/dbus/system_bus_socket`),
  supervisor behaviour and container SIGKILL grace differ. The rig proves *logic*, not
  balenaOS integration.
- `mac80211_hwsim` has no RF: no weak signal, no interference, no distance. `status_code=16`
  from an AP that is powered but not answering — the actual `be8bdb2` failure — is
  approximated, not reproduced.

`balena-os/balenaos-in-container` is worth reading before building this. It is old and
abandoned, so do not try to run it, but it shows how balenaOS's init, supervisor and D-Bus
plumbing were faked inside a container — which is exactly the gap between a Debian VM and
a real device. Take the ideas, not the code.

---

## Where this leaves us

Tier 1 is built and green. It covers every defect found on 2026-09-15 — all of which were
decision bugs in shell that had never been executed before it reached a fleet.

Tier 2 is justified by one question above all: **does the supervision loop stop
NetworkManager healing on its own?** That is the open risk in the current design, and
hardware testing answers it slowly, expensively, and only for the one scenario you happened
to stage.
