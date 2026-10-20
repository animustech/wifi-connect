# A 10-Minute Install Window: Implementation Plan

**Goal:** `start.sh` defaults `ACTIVITY_TIMEOUT` to 600 s instead of 300 s.

**Spec:** `docs/specs/2026-10-20-longer-install-window.md`

## Global Constraints

- Work in the worktree `/opt/adi/loci/wifi-connect-dev` on branch `dev`. Never push.
- No Rust changes. Never install a Rust toolchain on the Mac.
- Do not change `RECONNECT_INTERVAL_MINUTES` or `PORTAL_RETRY_GAP`.
- Scripts run under macOS bash 3.2.
- Code, test names, log strings and commit messages carry no plan or spec ids. Scenario ids (S4) are fine.
- Commits are conventional, short, and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

### Task 1: Default the install window to 600 s

**Files:**
- Modify: `tools/test/lib/harness.sh` (the wifi-connect stub records `ACTIVITY_TIMEOUT`; `run_start_sh --default-activity-timeout` leaves it unset for `start.sh`; `assert_activity_timeout`)
- Create: `tools/test/cases/activity-timeout-default.sh`, `tools/test/cases/activity-timeout-override.sh`
- Modify: `scripts/start.sh`
- Modify: `docs/connectivity-scenarios.md`, `docs/testing-connectivity.md`, `tools/hwsim/scenarios/s4-stranded-recovers.sh` (comment)

- [ ] **Step 1: Failing cases.** With the variable unset the binary must receive 600. With `ACTIVITY_TIMEOUT=45` it must receive 45. Run them: the default case fails against 300. (Spec criteria 1, 2.)
- [ ] **Step 2: Change the default** in `scripts/start.sh` to 600 and update its comment. Both cases pass. (Criterion 1.)
- [ ] **Step 3: Docs.** Every statement of the default says 600 s; the text that relies on the window being shorter than the 900 s M4 tick says 600 still satisfies it. (Criterion 4.)
- [ ] **Step 4: Verify.** Full tier-1 suite under `/bin/bash` and Homebrew bash; hwsim `run-scenarios.sh s4` (s4 and s4b). (Criterion 3.)
- [ ] **Step 5: Env check, read-only.** `balena env list` at fleet and device level on `gekko/loci-prod-pi5` for `ACTIVITY_TIMEOUT` and `PORTAL_RETRY_GAP`. Change nothing. (Criterion 5.)
