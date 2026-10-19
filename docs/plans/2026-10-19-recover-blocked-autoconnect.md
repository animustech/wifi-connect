# Recover a Blocked Saved Network: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the portal gives up, explicitly activate a visible saved WiFi profile if NetworkManager has not reconnected within a grace period. Log NM's state whenever the link is down or changes, both to stdout and to a capped file on `/data`.

**Architecture:** Everything lives in the supervision script. A new `scripts/nm.sh`, sourced by `scripts/start.sh`, wraps `nmcli` (state line, capped log, candidate listing, recovery). `start.sh` calls it at transitions, on down passes and in the give-up branch. The runtime image gains `network-manager` (for `nmcli`, talking to the host NM over the D-Bus socket `start.sh` already exports) and `jq` (for reading the reconnect history). The Rust binary is not touched.

**Tech Stack:** bash (3.2-compatible for the macOS harness, bash 5 in the container), nmcli, jq, the tier-1 harness `tools/test/`, the hwsim Lima rig `tools/hwsim/`.

**Spec:** `docs/specs/2026-10-19-recover-blocked-autoconnect.md`

## Global Constraints

- Work in the worktree `/opt/adi/loci/wifi-connect-dev` on branch `dev`. Never push.
- No Rust changes. Never install a Rust toolchain on the Mac. Docker builds only.
- `RECOVERY_GRACE` defaults to 30 (seconds). `NM_STATE_LOG` defaults to `/data/nm-state.log`. The cap is 1 MiB = 1048576 bytes. Past the cap, keep the newest 524288 bytes, trimmed forward to the next line start.
- `RECONNECT_HISTORY` defaults to `/data/reconnect-history.json`, the binary's `HISTORY_FILE_PATH`. Its format is `{"last_connected":{"<ssid>":<unix_seconds>}}`.
- The interface is `wlan0`, held in `NM_IFACE="${NM_IFACE:-wlan0}"`.
- Explicit activation: `nmcli --wait 45 connection up uuid <uuid> ifname wlan0`. Always by uuid, never by name.
- Keep the existing line `WiFi Connect gave up - leaving the radio to NetworkManager for %ss` verbatim. The S4 hwsim scenario asserts it.
- All scripts must run under macOS bash 3.2: no associative arrays, `mapfile`, `${x,,}` or `declare -n`.
- Code, test names, log strings and commit messages carry no plan or spec ids (`AC3`, `Task 2`, …). Scenario ids from `docs/connectivity-scenarios.md` (S4, S15) are the repo's own catalogue and are fine.
- Commits use conventional, short messages and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. `nmcli` is absent (an old image) or `device show wlan0` fails. The loop must keep running, state fields print `-`, and one line says NM features are disabled. Pinned in Task 2.
2. Profile names and SSIDs with spaces and colons (`Deep Runner:IOT`). They must be parsed intact, and activation goes by uuid. Pinned in Task 3.
3. NM refuses the rescan (`Scanning not allowed…`). Recovery falls back to the cached scan list instead of seeing nothing. Pinned in Task 3.
4. `reconnect-history.json` is missing or corrupt. Candidates keep nmcli's order and nothing crashes. Pinned in Task 3.
5. `/data` is unwritable or full. Stdout still gets every line and the loop continues. Pinned in Task 2.

---

### Task 1: Reproduce the blocked autoconnect on the rig (failing scenario)

**Files:**
- Create: `tools/hwsim/scenarios/s15-autoconnect-blocked.sh`
- Modify: `tools/hwsim/lib.sh`. `reset_rig` also runs `nmcli device set <dut-iface> autoconnect yes`, so a blocked radio cannot leak into later scenarios. Use whatever interface name `lib.sh` already uses for the device-under-test radio.

**Interfaces:**
- Produces: the scenario that Task 4 runs green, and a decision on which inducer to use, recorded in the commit message and later in the docs.

- [ ] **Step 1: Start the rig.** Run `limactl start wifitest`, then `tools/hwsim/vm-up.sh`. Confirm that `limactl shell wifitest ls -d /sys/class/ieee80211/phy*` lists 4 radios. Note `nmcli --version` in the VM.
- [ ] **Step 2: Write the scenario** in the style of `s4-stranded-recovers.sh`. The block is induced *before* the container starts, so the portal cycle runs against an NM that already refuses to autoconnect.
  1. `reset_rig`. Bring AP 1 up as `Deep Runner-IOT` / `testpass123`, then `learn_network`.
  2. Induce the block with `nmcli device disconnect <dut-iface>`, the spec's inducer.
  3. `sleep 20`, then require `not_joined`, which proves the block holds with the AP present. Otherwise `sfail "setup: block did not hold"`.
  4. `device_up ACTIVITY_TIMEOUT=20 PORTAL_RETRY_GAP=600`.
  5. `wait_for 90 portal_is_up`. Then wait up to 60 s for `Timeout reached. Exiting...` in `device_log`.
  6. `wait_for 90 joined_a_network || sfail "still stranded 90s after give-up"`.
  7. `assert_log "Recovery: activating saved profile 'Deep Runner-IOT' -> activated"`.
- [ ] **Step 3: Run it against the current code.** Copy the rig and the worktree's source into the VM, build `wifi-connect:test` and run `run-scenarios.sh s15`, as in `docs/testing-connectivity.md`. Expected: FAIL with `still stranded 90s after give-up`. If it fails earlier, fix the scenario.
- [ ] **Step 4: If it joined instead**, the portal's own activation cleared the device-level block. Switch step 2.2 to a no-secrets block:
  1. Restart AP 1 with `wrongpass123`.
  2. Wait up to 90 s until `nmcli -g GENERAL.REASON device show <dut-iface>` mentions secrets.
  3. Restart AP 1 with `testpass123`.

  Re-run step 3, which must now FAIL as expected. Then amend the spec's criterion 2 to name that inducer, in its own `docs(spec)` commit. If neither inducer holds through a portal cycle, STOP and report: NM then recovers by itself, and the field block is something else.
- [ ] **Step 5: Commit** the scenario and the `lib.sh` change: `test(hwsim): a saved network NetworkManager will not autoconnect`. The body names the inducer that held.

### Task 2: NM state log (stdout and capped file) and the image

**Files:**
- Create: `scripts/nm.sh`
- Modify: `scripts/start.sh`. Source `nm.sh` with `. "$(dirname "${BASH_SOURCE[0]}")/nm.sh"` after line 3, and add the call sites below.
- Modify: `Dockerfile.template`. Add `network-manager jq` to the runtime `apt-get install`, and copy `scripts/nm.sh` next to `start.sh`.
- Modify: `tools/test/lib/harness.sh`. Add the `nmcli` stub, its fixtures, `assert_log_count`, `assert_nmcli_called` and `refute_nmcli_called`, and the new defaults in `run_start_sh`: `RECOVERY_GRACE=${RECOVERY_GRACE:-1}`, `NM_STATE_LOG=$TMP/nm-state.log`, `RECONNECT_HISTORY=$TMP/reconnect-history.json`.
- Test: `tools/test/cases/log-nm-state-*.sh`

**Interfaces (in `scripts/nm.sh`):**
- `nm_available` returns 0 if `nmcli` is on PATH. Otherwise it returns 1 and, once per process, logs `NetworkManager tools not available - state log and recovery disabled`.
- `nm_log <text>` prints `<UTC ISO-8601 timestamp> <text>` to stdout and appends the same line to `$NM_STATE_LOG`, then applies the cap. File errors are swallowed.
- `nm_state_line` echoes exactly `NM state: wlan0=<state text> (reason=<reason>) dev-autoconnect=<yes|no> active=<connection> profiles=[<name> auto=<yes|no> visible=<yes|no>, ...]`.
  - `<state text>` is the word inside nmcli's parentheses: `100 (connected)` becomes `connected`.
  - `<reason>` is GENERAL.REASON as nmcli prints it.
  - Any empty or failed field prints `-`. `profiles=[]` means there are no WiFi profiles.
  - Visibility uses the cached list (`--rescan no`).
- `nm_log_state` is `nm_available && nm_log "$(nm_state_line)"`.
- `nm_visible_ssids <yes|no>` prints the SSIDs from `nmcli --escape no -t -f SSID device wifi list ifname wlan0 --rescan <arg>`, one per line, skipping empty ones.
- `nm_wifi_profiles` prints `uuid<TAB>autoconnect<TAB>name` for every `802-11-wireless` profile, parsed from `nmcli -t -f UUID,TYPE,AUTOCONNECT,NAME connection show`. NAME is last; split off the first three fields and unescape `\:` in the rest.
- `nm_profile_field <uuid> <field>` is `nmcli --escape no -g <field> connection show uuid <uuid>`. It is called separately for `802-11-wireless.ssid` and `802-11-wireless.mode`.
- Device fields come from `nmcli --escape no -g <FIELD> device show wlan0`, one call per field: GENERAL.STATE, GENERAL.REASON, GENERAL.AUTOCONNECT, GENERAL.CONNECTION.

**The nmcli stub** (`$TMP/bin/nmcli`) appends its argv to `$T/nmcli.argv` and serves only the invocations above, from these fixtures:

| Helper | Writes |
|---|---|
| `fixture_nmcli_device FIELD=value ...` | `nmcli.device` |
| `fixture_nmcli_profile <uuid> <name> <ssid> <yes\|no> [<mode>]` | a TSV line appended to `nmcli.profiles` (mode defaults to `infrastructure`) |
| `fixture_nmcli_visible <ssid> ...` | `nmcli.visible` |
| `fixture_nmcli_rescan_fails` | `nmcli.rescan_fails` (`--rescan yes` then exits 1) |
| `fixture_nmcli_up <uuid> ok\|"fail <msg>"` | `nmcli.up.<uuid>` |

- A missing fixture yields empty output and exit 0. For `device show`, a missing fixture exits 10, the way a missing device does.
- An `up … ok` prints `Connection successfully activated` and writes the profile's SSID to `$T/iwgetid.override`, so `connected` turns true.
- An `up` that fails, or has no fixture, prints `Error: Connection activation failed: <msg>` to stderr and exits 4.

**Call sites in `start.sh`:**
- In the `if connected` branch, right after the `Wired…`/`WiFi connected to…` line (only on a transition), call `nm_log_state`.
- On every disconnected pass, right after `last_state="disconnected"`, call `nm_log_state`.
- Task 3 adds the give-up-branch calls.

- [ ] **Step 1: Write the failing tests.** Each is a case file, in the style of `s4-portal-gives-up.sh`:
  - `log-nm-state-down-pass.sh`: `fixture_iwgetid ""`, a device fixture of `GENERAL.STATE=30 (disconnected)`, `GENERAL.REASON=39 (Device disconnected by user or client)`, `GENERAL.AUTOCONNECT=no` and `GENERAL.CONNECTION=`, and the profile `u1 "Prospect WiFi" "Prospect WiFi" yes`, visible `"Prospect WiFi"`. Run `--passes 1` and assert the log contains `NM state: wlan0=disconnected (reason=39 (Device disconnected by user or client)) dev-autoconnect=no active=- profiles=[Prospect WiFi auto=yes visible=yes]`. Also assert `$TMP/nm-state.log` contains that line with a leading `20..-..-..T..:..:..Z` timestamp.
  - `log-nm-state-quiet-while-up.sh`: `fixture_iwgetid "Vessel"`, `--passes 3`, then `assert_log_count 1 "NM state:"`, and the file has exactly 1 line.
  - `log-nm-state-cap.sh`: pre-fill `$TMP/nm-state.log` with 1100000 bytes of `old line\n`. Run one down pass. The file is ≤ 1048576 bytes and ≥ 1 byte, its last line is the new state line, and its first line is exactly `old line`.
  - `log-nm-state-unwritable.sh` (Review Focus 5): `NM_STATE_LOG=$TMP/missing-dir/x.log`, a down pass. `assert_log "NM state:"`, `assert_launched`, and the exit is clean (`gave up` line present).
  - `log-nm-state-no-nmcli.sh` (Review Focus 1): delete `$TMP/bin/nmcli` after the fixtures, `--passes 2`. `assert_log_count 1 "NetworkManager tools not available"` and `assert_log "gave up - leaving the radio to NetworkManager"`.
  - `log-nm-state-no-device.sh` (Review Focus 1): no device fixture. Assert `wlan0=- (reason=-) dev-autoconnect=- active=- profiles=[]`.
- [ ] **Step 2: Run them.** `tools/test/run.sh log-nm-state`. Expected: all FAIL (no state lines yet).
- [ ] **Step 3: Implement** `scripts/nm.sh` and the two call sites as specified above.
- [ ] **Step 4: Run** `tools/test/run.sh`. Expected: the new cases and all 12 existing ones PASS.
- [ ] **Step 5: Build the image.** `cp Dockerfile.template Dockerfile && docker build -t wifi-connect:nmtest .`, then `docker run --rm --entrypoint sh wifi-connect:nmtest -c 'nmcli --version && jq --version && ls nm.sh start.sh'`. Expected: both versions print and both scripts are present. Record the image size before and after (`docker image ls`) for the report, then delete the copied `Dockerfile` if it is untracked.
- [ ] **Step 6: Commit.** Two commits:
  - `feat(start.sh): log NetworkManager state when the link is down or changes`, covering `scripts/` and `Dockerfile.template`.
  - `test: nmcli stub and state-log cases`, covering `tools/test/`.

### Task 3: Explicit recovery after give-up

**Files:**
- Modify: `scripts/nm.sh`. Add `nm_recovery_candidates` and `nm_recover_saved_networks`.
- Modify: `scripts/start.sh`. Add the `RECOVERY_GRACE` knob next to `PORTAL_RETRY_GAP`, with a comment in the file's style: why the grace exists, and that an explicit activation overrides NM's autoconnect blocks. Then rework the give-up branch (lines 156-164).
- Test: `tools/test/cases/s15-*.sh`

**Interfaces:**
- Consumes: Task 2's `nm_available`, `nm_log`, `nm_log_state`, `nm_visible_ssids`, `nm_wifi_profiles`, `nm_profile_field`, and the nmcli stub.
- `nm_recovery_candidates` prints `uuid<TAB>ssid<TAB>name`.
  - Candidates are WiFi profiles with autoconnect `yes`, mode not `ap`, SSID not `$PORTAL_SSID`, and SSID in `nm_visible_ssids yes`. If the rescan exits non-zero, it uses `nm_visible_ssids no` instead.
  - They are sorted by `jq -r --arg s "$ssid" '.last_connected[$s] // 0' "$RECONNECT_HISTORY"`, descending, with a stable sort. A missing or corrupt file counts as 0.
  - It also sets `NM_VISIBLE_COUNT` to the number of visible SSIDs. Run it in the current shell, not a subshell, or write the count to a file.
- `nm_recover_saved_networks` tries each candidate once, in order, and returns 0 on the first success, 1 otherwise. The lines it logs, all through `nm_log`:
  - `Recovery: no saved network to activate (<n> SSIDs visible)`
  - `Recovery: activating saved profile '<name>' -> activated`
  - `Recovery: activating saved profile '<name>' -> failed: <nmcli's message, with the leading "Error: " removed>`

**Give-up branch, in order:**
1. The existing `gave up` printf, unchanged.
2. `nm_log_state`.
3. Poll `connected` every `WIFI_CHECK_INTERVAL` for up to `RECOVERY_GRACE`.
4. If connected: `nm_log "Recovery: NetworkManager reconnected by itself"`.
5. Otherwise, if `nm_available`: `nm_recover_saved_networks`, then `nm_log_state`.
6. If now connected: `continue`, so supervision resumes on the next pass.
7. Otherwise: `nm_log "Recovery: nothing activated - waiting ${PORTAL_RETRY_GAP}s"` and `sleep "$PORTAL_RETRY_GAP"`.

- [ ] **Step 1: Write the failing tests.** Every case uses `fixture_iwgetid ""` unless stated otherwise.
  - `s15-recovers-blocked-profile.sh`: profile `u1 "Deep Runner:IOT" "Deep Runner:IOT" yes`, visible the same, `fixture_nmcli_up u1 ok`, `--passes 2`.
    - `assert_nmcli_called "connection up uuid u1 ifname wlan0"`
    - `assert_log "Recovery: activating saved profile 'Deep Runner:IOT' -> activated"`
    - `assert_log "WiFi connected to Deep Runner:IOT"`
    - `assert_log "gave up - leaving the radio to NetworkManager"`
    - This also pins Review Focus 2.
  - `s15-nm-reconnects-itself.sh`: `fixture_iwgetid "Vessel" --drop-after 0 --return-after 4`, `RECOVERY_GRACE=5`, profile `u1` visible with up ok.
    - `assert_log "Recovery: NetworkManager reconnected by itself"`
    - `refute_nmcli_called "connection up"`
  - `s15-skips-autoconnect-no-and-portal.sh`: profiles `u1 Vessel Vessel no` and `u2 Loci-AP-e3042ef Loci-AP-e3042ef yes ap`, both visible.
    - `refute_nmcli_called "connection up"`
    - `assert_log "Recovery: no saved network to activate (2 SSIDs visible)"`
  - `s15-nothing-in-range.sh`: profile `u1 A A yes`, visible `Other1 Other2`.
    - `assert_log "Recovery: no saved network to activate (2 SSIDs visible)"`
    - `assert_log "Recovery: nothing activated - waiting 1s"`
  - `s15-history-order-and-fallthrough.sh`: profiles `u1 Old Old yes` and `u2 Recent Recent yes`, both visible. History `{"last_connected":{"Old":100,"Recent":200}}`. `fixture_nmcli_up u2 "fail Secrets were required, but not provided"`, `fixture_nmcli_up u1 ok`.
    - In `nmcli.argv`, the `connection up uuid u2` line precedes `connection up uuid u1`.
    - `assert_log "'Recent' -> failed: Connection activation failed: Secrets were required, but not provided"`
    - `assert_log "'Old' -> activated"`
  - `s15-all-fail-once-each.sh`: the same two profiles, both up fail, `--passes 1`.
    - `connection up uuid u1` and `u2` each appear exactly once in `nmcli.argv`.
    - `assert_log "Recovery: nothing activated - waiting 1s"`
  - `s15-rescan-refused.sh` (Review Focus 3): profile `u1` visible, `fixture_nmcli_rescan_fails`, up ok.
    - `assert_nmcli_called "connection up uuid u1"`
  - `s15-corrupt-history.sh` (Review Focus 4): history file `not json`, profiles `u1 First First yes` and `u2 Second Second yes`, both visible, both up ok.
    - Only `u1` is activated.
    - `refute_log "parse error"`
- [ ] **Step 2: Run** `tools/test/run.sh s15`. Expected: all FAIL.
- [ ] **Step 3: Implement** the two functions and the give-up branch as specified.
- [ ] **Step 4: Run** `tools/test/run.sh`. Expected: everything PASSES, including `s4-portal-gives-up`.
- [ ] **Step 5: Commit.** Two commits:
  - `feat(start.sh): activate a visible saved network NetworkManager has not reconnected`
  - `test: recovery cases after the portal gives up`

### Task 4: Rig verification and the scenario docs

**Files:**
- Modify: `docs/connectivity-scenarios.md`.
  - Add M5 `Post-give-up recovery | scripts/start.sh + scripts/nm.sh | after every give-up` to the mechanism table.
  - Add `RECOVERY_GRACE` (30 s) and `NM_STATE_LOG` (`/data/nm-state.log`, 1 MiB) to the knobs table.
  - Add an S15 section, "NetworkManager holds a saved profile blocked from autoconnect". It covers the ed682d4 field case in two sentences, the inducer that held on the rig and what the portal cycle does or does not clear (from Task 1), and the measured give-up-to-associated time.
  - Add one sentence to S4's "What actually recovers" paragraph: M5 is the fallback when NM does not.
  - Add rows to the "What is actually tested" table.
- Modify: `docs/testing-connectivity.md`. Add a line for the new scenario only if that file lists scenarios.

- [ ] **Step 1: Rebuild the image in the VM** from the worktree, as in Task 1 step 3.
- [ ] **Step 2: Run** `run-scenarios.sh s15`. Expected: PASS. Record the time from `Timeout reached` to `joined_a_network`; it must be ≤ 90 s.
- [ ] **Step 3: Run** `run-scenarios.sh s4`. Expected: s4 PASSES, and its log shows `Recovery: NetworkManager reconnected by itself` with no `connection up`. s4b runs too; report its result.
- [ ] **Step 4: Run** `run-scenarios.sh` (all). Expected: every scenario PASSES. Report each one's pass or fail, and paste any failure's tail.
- [ ] **Step 5: Run** `tools/test/run.sh` once more. Expected: all PASS.
- [ ] **Step 6: Write the docs** above with the measured numbers. Commit as `docs(scenarios): S15 and post-give-up recovery`.

## After the plan (not part of execution)

- Squash `dev` per topic and hand it over. The owner pushes.
- Shipping is a separate, owner-approved step in `loci-on-balena`: bump the `wifi-connect` pin and `balena.yml`'s version, then `tools/deploy/release.sh`.
- `fix/pi0-2w-timeout` (`0ea8f2a`) touches only `src/network.rs` and does not conflict with this plan.
