#!/usr/bin/env bash
# tests/fm-worktree-collision-lib.test.sh - the worktree double-registration
# guard owned by bin/fm-worktree-collision-lib.sh and surfaced by
# bin/fm-bootstrap.sh's WORKTREE_COLLISION line.
#
# The gap under test: firstmate hands each task a pooled worktree, and nothing
# detects two state/*.meta records claiming the same worktree= path. That is
# quiet and expensive - a commit can land on the wrong task's branch, or a
# teardown can return a copy another task still needs.
#
# The guarantees under test:
#   - fm_worktree_collision_claimant_state classifies one claimant from purely
#     local evidence: alive/unknown/unlanded are hazards; gone/landed are not,
#     because the claimant's task is provably finished (agent gone AND either
#     nothing left at the path, or the work is clean and merged).
#   - fm_worktree_collision_lines groups state/*.meta by worktree=, reports
#     only paths claimed by 2+ records, names every claimant, and marks the
#     collision `live` only when 2+ claimants are still hazardous - one live
#     task plus a finished task's stale leftover record is `stale`, not `live`.
#   - A path claimed by exactly one record never produces a line.
#   - bin/fm-bootstrap.sh surfaces the same line and stays silent on a clean
#     home, matching every other detect-only bootstrap check's contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"
# shellcheck source=bin/fm-worktree-collision-lib.sh
. "$ROOT/bin/fm-worktree-collision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-collision)
fm_git_identity fmtest fmtest@example.invalid

# A fake tmux with two sessions: `livesess` has a window `alive` whose
# foreground command classifies as a verified harness (agent state: alive),
# and a window `ambig` whose foreground command is an ordinary process the
# classifier cannot place (agent state: ambiguous). Any other session reports
# a clean "no such session" failure (agent state: missing). No real tty/ps
# reads are involved - fm_backend_tmux_agent_state's own current-command
# fallback settles the verdict directly from the faked pane_current_command,
# exactly like the equivalent probe in tests/fm-secondmate-liveness.test.sh.
make_collision_tmux() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
prev=
target=
for a in "$@"; do
  [ "$prev" = -t ] && target=$a
  prev=$a
done
case "${1:-}" in
  list-windows)
    case "$target" in
      livesess) printf '%s\n' alive; printf '%s\n' ambig ;;
      *) printf "can't find session: %s\n" "$target" >&2; exit 1 ;;
    esac
    ;;
  display-message)
    case "$target" in
      livesess:alive) printf '%s\n' claude ;;
      livesess:ambig) printf '%s\n' node ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A clean repo on `main` with one commit, ready to be a task's worktree.
make_worktree() {  # <dir>
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
}

# --- unit level: fm_worktree_collision_claimant_state ------------------------

test_claimant_state_classification() {
  local fakebin meta wt got

  fakebin=$(make_collision_tmux "$TMP_ROOT/tmux")

  # alive short-circuits before any worktree read, so a non-existent path is
  # fine here - the claimant is a hazard purely because the process is live.
  meta="$TMP_ROOT/alive.meta"
  fm_write_meta "$meta" "window=livesess:alive" "worktree=$TMP_ROOT/unused" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_state "$meta")
  [ "$got" = alive ] || fail "a live agent process should classify as alive, got '$got'"

  # unknown requires a real worktree at the recorded path - otherwise an
  # ambiguous process with nothing left on disk would (correctly) read gone.
  wt="$TMP_ROOT/ambig-wt"
  make_worktree "$wt"
  meta="$TMP_ROOT/ambig.meta"
  fm_write_meta "$meta" "window=livesess:ambig" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_state "$meta")
  [ "$got" = unknown ] || fail "an ambiguous process state should classify as unknown (cannot be proven finished), got '$got'"

  meta="$TMP_ROOT/gone.meta"
  fm_write_meta "$meta" "window=deadsess:win" "worktree=$TMP_ROOT/never-existed" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_state "$meta")
  [ "$got" = gone ] || fail "a worktree path that no longer exists should classify as gone, got '$got'"

  wt="$TMP_ROOT/landed-wt"
  make_worktree "$wt"
  meta="$TMP_ROOT/landed.meta"
  fm_write_meta "$meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_state "$meta")
  [ "$got" = landed ] || fail "a clean worktree on the default branch with a gone process should classify as landed, got '$got'"

  wt="$TMP_ROOT/unlanded-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  meta="$TMP_ROOT/unlanded.meta"
  fm_write_meta "$meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_state "$meta")
  [ "$got" = unlanded ] || fail "a dirty worktree with a gone process should classify as unlanded, got '$got'"

  pass "fm_worktree_collision_claimant_state: alive, unknown, gone, landed, and unlanded verdicts"
}

# --- fm_worktree_collision_lines: grouping and live/stale classification ----

test_collision_lines_grouping() {
  local state fakebin wt_live wt_stale wt_solo out

  state="$TMP_ROOT/group-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/group-tmux")

  # Genuine live collision: two records share one dirty worktree, and neither
  # process is provably alive OR finished - fm-live-a's process is dead with
  # unlanded work, fm-live-b's is ambiguous. Both count as hazards.
  wt_live="$TMP_ROOT/wt-live"
  make_worktree "$wt_live"
  echo dirty > "$wt_live/scratch.txt"
  fm_write_meta "$state/fm-live-a.meta" "window=deadsess:win" "worktree=$wt_live" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-live-b.meta" "window=livesess:ambig" "worktree=$wt_live" "harness=codex" "kind=ship"

  # Stale collision: the pool slot was recycled. fm-old-finished's process is
  # gone and its work is landed (clean, on the default branch) - a finished
  # task's leftover record. fm-new-active's process is genuinely alive. Only
  # one hazardous claimant, so this must read `stale`, not `live`.
  wt_stale="$TMP_ROOT/wt-stale"
  make_worktree "$wt_stale"
  fm_write_meta "$state/fm-old-finished.meta" "window=deadsess:win" "worktree=$wt_stale" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-new-active.meta" "window=livesess:alive" "worktree=$wt_stale" "harness=codex" "kind=ship"

  # A solo task with its own unique path must never produce a collision line.
  wt_solo="$TMP_ROOT/wt-solo"
  make_worktree "$wt_solo"
  fm_write_meta "$state/fm-solo.meta" "window=livesess:alive" "worktree=$wt_solo" "harness=claude" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $wt_live claimed by" \
    "the dirty shared worktree should be reported as a live collision"
  assert_contains "$out" "fm-live-a (process gone, work not landed)" \
    "fm-live-a's unlanded verdict should be named"
  assert_contains "$out" "fm-live-b (process state unknown)" \
    "fm-live-b's unknown verdict should be named"

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt_stale claimed by" \
    "a finished task's leftover record alongside one live task should read stale, not live"
  assert_contains "$out" "fm-old-finished (finished: process gone, work landed)" \
    "fm-old-finished's landed verdict should be named"
  assert_contains "$out" "fm-new-active (process alive)" \
    "fm-new-active's alive verdict should be named"

  assert_not_contains "$out" "$wt_solo" \
    "a path claimed by only one record must never produce a collision line"

  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 2 ] \
    || fail "expected exactly 2 collision lines, got:"$'\n'"$out"

  pass "fm_worktree_collision_lines: groups by path, distinguishes live from stale, ignores solo paths"
}

test_collision_lines_silent_on_clean_home() {
  local state wt out

  state="$TMP_ROOT/clean-state"
  mkdir -p "$state"
  out=$(fm_worktree_collision_lines "$state")
  [ -z "$out" ] || fail "an empty state dir must produce no output, got: $out"

  wt="$TMP_ROOT/clean-wt"
  make_worktree "$wt"
  fm_write_meta "$state/fm-only.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  out=$(fm_worktree_collision_lines "$state")
  [ -z "$out" ] || fail "a home with no shared worktree paths must produce no output, got: $out"

  pass "fm_worktree_collision_lines: silent when no path is claimed twice"
}

# --- bootstrap integration ---------------------------------------------------

run_bootstrap() {  # <home>
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_surfaces_collision_line() {
  local home fakebin wt out

  home="$TMP_ROOT/bootstrap-clean"
  mkdir -p "$home/state"
  out=$(run_bootstrap "$home" | grep '^WORKTREE_COLLISION:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a WORKTREE_COLLISION line on a clean home: $out"

  home="$TMP_ROOT/bootstrap-collision"
  mkdir -p "$home/state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/bootstrap-tmux")
  wt="$TMP_ROOT/bootstrap-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$home/state/fm-one.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/fm-two.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" run_bootstrap "$home" | grep '^WORKTREE_COLLISION:' || true)
  assert_contains "$out" "live $wt claimed by" "bootstrap did not report the double-registered worktree"
  assert_contains "$out" "fm-one" "bootstrap's collision line did not name the first claimant"
  assert_contains "$out" "fm-two" "bootstrap's collision line did not name the second claimant"

  pass "fm-bootstrap.sh: WORKTREE_COLLISION line fires only when a worktree is double-registered"
}

test_claimant_state_classification
test_collision_lines_grouping
test_collision_lines_silent_on_clean_home
test_bootstrap_surfaces_collision_line
