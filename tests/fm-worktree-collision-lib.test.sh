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
#   - fm_worktree_collision_path_state judges the SHARED PATH once from git
#     alone: gone/landed leave nothing at risk, unlanded does.
#   - fm_worktree_collision_claimant_process judges ONE claimant from its own
#     recorded backend endpoint alone: alive/unknown are hazards, dead is not.
#     The path's content never makes a dead record look hazardous, and a dead
#     record's own detail never claims work that belongs to a live sibling.
#   - fm_worktree_collision_lines groups state/*.meta by worktree=, reports
#     only paths claimed by 2+ records, names every claimant, and marks the
#     collision `live` only when 2+ claimants' processes are still hazardous -
#     one live task plus a finished task's stale leftover record is `stale`,
#     not `live`, even when the shared worktree holds the live task's own
#     uncommitted work. That work is then reported once as a path-level
#     caveat, so a leftover record is never cleaned up blind.
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

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
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

# --- unit level: the two independent classifiers ------------------------------

test_path_state_classification() {
  local wt got

  got=$(fm_worktree_collision_path_state "$TMP_ROOT/never-existed")
  [ "$got" = gone ] || fail "a worktree path that no longer exists should classify as gone, got '$got'"

  wt="$TMP_ROOT/landed-wt"
  make_worktree "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = landed ] || fail "a clean worktree on the default branch should classify as landed, got '$got'"

  wt="$TMP_ROOT/unlanded-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unlanded ] || fail "a dirty worktree should classify as unlanded, got '$got'"

  wt="$TMP_ROOT/unmerged-wt"
  make_worktree "$wt"
  git -C "$wt" checkout -q -b side
  git -C "$wt" commit -q --allow-empty -m "work not on main"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = unlanded ] \
    || fail "a clean worktree whose HEAD is not reachable from the default branch should classify as unlanded, got '$got'"

  pass "fm_worktree_collision_path_state: gone, landed, and unlanded verdicts from the path alone"
}

test_claimant_process_classification() {
  local fakebin meta wt got

  fakebin=$(make_collision_tmux "$TMP_ROOT/tmux")

  # Every case below records the same dirty worktree, so the path's content is
  # constant: any difference in verdict comes from the process alone. That is
  # the split this classifier exists to enforce - a dead record must read dead
  # even when the shared path is full of somebody's uncommitted work.
  wt="$TMP_ROOT/proc-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"

  meta="$TMP_ROOT/alive.meta"
  fm_write_meta "$meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = alive ] || fail "a live agent process should classify as alive, got '$got'"

  meta="$TMP_ROOT/ambig.meta"
  fm_write_meta "$meta" "window=livesess:ambig" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = unknown ] || fail "an ambiguous process state should classify as unknown (cannot be proven finished), got '$got'"

  meta="$TMP_ROOT/dead.meta"
  fm_write_meta "$meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = dead ] \
    || fail "a missing agent process should classify as dead even when the shared worktree is dirty, got '$got'"

  pass "fm_worktree_collision_claimant_process: alive, unknown, and dead verdicts from the process alone"
}

# --- fm_worktree_collision_lines: grouping and live/stale classification ----

test_collision_lines_grouping() {
  local state fakebin wt_live wt_stale wt_solo out

  state="$TMP_ROOT/group-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/group-tmux")

  # Genuine live collision: two records share one dirty worktree and neither
  # process is provably finished - fm-live-a's agent is alive, fm-live-b's
  # state is ambiguous. Both count as hazards, so this is the real thing.
  wt_live="$TMP_ROOT/wt-live"
  make_worktree "$wt_live"
  echo dirty > "$wt_live/scratch.txt"
  fm_write_meta "$state/fm-live-a.meta" "window=livesess:alive" "worktree=$wt_live" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-live-b.meta" "window=livesess:ambig" "worktree=$wt_live" "harness=codex" "kind=ship"

  # Stale collision: the pool slot was recycled. fm-old-finished's process is
  # gone - a finished task's leftover record - and the shared path is clean and
  # on the default branch. fm-new-active's process is genuinely alive. Only one
  # hazardous claimant, so this must read `stale`, not `live`.
  wt_stale="$TMP_ROOT/wt-stale"
  make_worktree "$wt_stale"
  fm_write_meta "$state/fm-old-finished.meta" "window=deadsess:win" "worktree=$wt_stale" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-new-active.meta" "window=livesess:alive" "worktree=$wt_stale" "harness=codex" "kind=ship"

  # A solo task with its own unique path must never produce a collision line.
  wt_solo="$TMP_ROOT/wt-solo"
  make_worktree "$wt_solo"
  fm_write_meta "$state/fm-solo.meta" "window=livesess:alive" "worktree=$wt_solo" "harness=claude" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $wt_live claimed by fm-live-a (process alive), fm-live-b (process state unknown)" \
    "two hazardous processes on one worktree should be reported as a live collision naming both verdicts"
  assert_not_contains "$out" "$wt_live claimed by fm-live-a (process alive), fm-live-b (process state unknown) -" \
    "a live collision needs no path-level caveat - a hazardous claimant is already the whole story"

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt_stale claimed by fm-new-active (process alive), fm-old-finished (process gone)" \
    "a finished task's leftover record alongside one live task should read stale and name each process verdict"

  assert_not_contains "$out" "$wt_solo" \
    "a path claimed by only one record must never produce a collision line"

  [ "$(printf '%s\n' "$out" | grep -c '^WORKTREE_COLLISION:')" = 2 ] \
    || fail "expected exactly 2 collision lines, got:"$'\n'"$out"

  pass "fm_worktree_collision_lines: groups by path, distinguishes live from stale, ignores solo paths"
}

# The regression this file's split classifiers exist for: a recycled pool slot
# where the surviving task is still working. The shared worktree is dirty with
# the LIVE claimant's own work in progress, so counting that dirt once per
# record used to promote the collision to `live` and to print the live task's
# unfinished work against the FINISHED record's name. Only one process is a
# hazard, so the kind is `stale`, the dead record's own detail says nothing but
# `process gone`, and the unlanded work is stated once, for the path.
test_collision_lines_live_claimants_wip_stays_path_level() {
  local state fakebin wt out

  state="$TMP_ROOT/wip-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/wip-tmux")

  wt="$TMP_ROOT/wt-wip"
  make_worktree "$wt"
  fm_write_meta "$state/fm-new-active.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-old-finished.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  # Case A: the live claimant has uncommitted work in the shared worktree.
  echo wip > "$wt/live-task-wip.txt"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt claimed by fm-new-active (process alive), fm-old-finished (process gone) - shared path still has unlanded work, do not discard" \
    "one live claimant working in the shared worktree is still a stale collision, with the unlanded work stated once for the path"
  assert_not_contains "$out" "work not landed" \
    "the live claimant's work in progress must never be described as a claimant's own unlanded work"
  assert_not_contains "$out" "fm-old-finished (process gone," \
    "the finished record's own detail must say nothing beyond its process state"

  # Case B: the same fixture with that work removed - clean and merged.
  rm -f "$wt/live-task-wip.txt"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt claimed by fm-new-active (process alive), fm-old-finished (process gone)" \
    "a clean, landed shared worktree with one live claimant is still a stale collision"
  assert_not_contains "$out" "unlanded" \
    "a landed shared path must carry no unlanded-work caveat"

  pass "fm_worktree_collision_lines: a live claimant's own WIP never promotes the kind or lands on a finished record"
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

# Local-half-only bootstrap on a pinned PATH: the collision check reads meta
# files, the recorded backend endpoint, and the worktree's own git state, so
# neither case may depend on the host's real gh auth or tool versions.
run_bootstrap() {  # <home> <fakebin>
  PATH="$2:$BASE_PATH" FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_surfaces_collision_line() {
  local home fakebin wt out

  fakebin=$(make_collision_tmux "$TMP_ROOT/bootstrap-tmux")

  home="$TMP_ROOT/bootstrap-clean"
  mkdir -p "$home/state"
  out=$(run_bootstrap "$home" "$fakebin" | grep '^WORKTREE_COLLISION:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a WORKTREE_COLLISION line on a clean home: $out"

  home="$TMP_ROOT/bootstrap-collision"
  mkdir -p "$home/state"
  wt="$TMP_ROOT/bootstrap-wt"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$home/state/fm-one.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$home/state/fm-two.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(run_bootstrap "$home" "$fakebin" | grep '^WORKTREE_COLLISION:' || true)
  assert_contains "$out" "live $wt claimed by" "bootstrap did not report the double-registered worktree"
  assert_contains "$out" "fm-one" "bootstrap's collision line did not name the first claimant"
  assert_contains "$out" "fm-two" "bootstrap's collision line did not name the second claimant"

  pass "fm-bootstrap.sh: WORKTREE_COLLISION line fires only when a worktree is double-registered"
}

test_path_state_classification
test_claimant_process_classification
test_collision_lines_grouping
test_collision_lines_live_claimants_wip_stays_path_level
test_collision_lines_silent_on_clean_home
test_bootstrap_surfaces_collision_line
