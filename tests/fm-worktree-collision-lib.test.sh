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
#     alone, and separates the two things one failed probe used to conflate:
#     `missing` proves nothing is there, `uninspectable` proves only that the
#     path could not be read, so it keeps the do-not-discard force.
#   - fm_worktree_collision_claimant_process judges ONE claimant from its own
#     recorded backend endpoint alone and passes the backend's own verdict
#     through, so the printed detail never blames a backend that answered.
#     Only dead/missing are non-hazards. The path's content never makes a dead
#     record look hazardous, and a dead record's own detail never claims work
#     that belongs to a live sibling.
#   - fm_worktree_collision_lines groups state/*.meta by worktree=, reports
#     only paths claimed by 2+ records, names every claimant, and marks the
#     collision `live` only when 2+ claimants' processes are still hazardous -
#     one live task plus a finished task's stale leftover record is `stale`,
#     not `live`, even when the shared worktree holds the live task's own
#     uncommitted work. That work is then reported once as a path-level
#     caveat, so a leftover record is never cleaned up blind - including when
#     every claimant's process is gone, where the caveat is the only thing
#     keeping the hazard from going silent.
#   - Path state never decides the kind and never withholds a line: every
#     colliding path prints exactly one line, an unverifiable process stays a
#     hazard even over a path that no longer exists, and every path that is not
#     proven landed states its own risk as a caveat on either kind instead of
#     being passed over in silence.
#   - Only LOCAL records are grouped: a record carrying remote_host= names a
#     path on another machine, so it can never collide with a local worktree.
#   - A path claimed by exactly one record never produces a line, and neither
#     does a path whose second record is torn down mid-scan - the collision has
#     resolved itself, so the vanished record is dropped rather than named.
#   - Grouping is by the recorded path byte-for-byte, so a path containing a
#     backslash still names every claimant instead of printing a claimant-less
#     line.
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
  [ "$got" = missing ] || fail "a worktree path with nothing at it should classify as missing, got '$got'"

  # Present on disk but not a readable git worktree - a returned-but-not-deleted
  # pool copy, or a dangling .git pointer. The probe proves only that it could
  # not be read, never that it is empty.
  wt="$TMP_ROOT/uninspectable-wt"
  mkdir -p "$wt"
  echo "work nobody can account for" > "$wt/scratch.txt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = uninspectable ] \
    || fail "a path that exists but is not a readable git worktree should classify as uninspectable, got '$got'"

  # Present but not a work tree at all: a plain file, a bare repository, and a
  # dangling symlink each leave `-d`/exit-status probes free to fall back on a
  # reassuring verdict. None of them proves the recorded copy is gone, so none
  # of them may read `missing`.
  wt="$TMP_ROOT/file-at-path"
  printf 'not a worktree\n' > "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = uninspectable ] \
    || fail "a plain file left at the recorded path is not proof the copy is gone, got '$got'"

  wt="$TMP_ROOT/bare-repo"
  git init -q --bare "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = uninspectable ] \
    || fail "a bare repository has no work tree to inspect, exactly as bin/fm-teardown.sh treats it, got '$got'"

  wt="$TMP_ROOT/dangling-link"
  ln -s "$TMP_ROOT/never-existed" "$wt"
  got=$(fm_worktree_collision_path_state "$wt")
  [ "$got" = uninspectable ] \
    || fail "a dangling symlink at the recorded path is still an entry that could not be inspected, got '$got'"

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

  pass "fm_worktree_collision_path_state: only an empty path reads missing; anything uninspectable keeps its warning"
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
  [ "$got" = ambiguous ] \
    || fail "a backend that answered but could not attribute the process should report ambiguous, not a flat unverifiable verdict, got '$got'"

  meta="$TMP_ROOT/dead.meta"
  fm_write_meta "$meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = missing ] \
    || fail "an authoritatively absent endpoint should report missing even when the shared worktree is dirty, got '$got'"

  meta="$TMP_ROOT/no-endpoint.meta"
  fm_write_meta "$meta" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta")
  [ "$got" = no-endpoint ] || fail "a record with no recorded target should report no-endpoint, got '$got'"

  # A corrupt record naming a backend firstmate does not know is unreadable,
  # not finished - and bootstrap's own output is captured with stderr merged
  # (bin/fm-session-start.sh), so the backend's refusal must not leak into the
  # digest as an unprefixed line no diagnostic skill can route.
  meta="$TMP_ROOT/bogus-backend.meta"
  fm_write_meta "$meta" "window=livesess:alive" "backend=bogus" "worktree=$wt" "harness=claude" "kind=ship"
  got=$(PATH="$fakebin:$PATH" fm_worktree_collision_claimant_process "$meta" 2>"$TMP_ROOT/bogus-backend.err")
  [ "$got" = unverified ] || fail "an unknown backend has no recovery classifier, so it should report unverified, got '$got'"
  [ ! -s "$TMP_ROOT/bogus-backend.err" ] \
    || fail "an unknown backend must not leak diagnostics onto stderr, got:"$'\n'"$(cat "$TMP_ROOT/bogus-backend.err")"

  pass "fm_worktree_collision_claimant_process: the backend's own verdict, from the process alone, quietly"
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

  assert_contains "$out" "WORKTREE_COLLISION: live $wt_live claimed by fm-live-a (process alive), fm-live-b (process state unknown (backend=tmux reported ambiguous)) - shared path still has unlanded work, do not discard" \
    "two hazardous processes on one worktree should be reported as a live collision naming both verdicts, and a dirty shared path still states its own risk"
  assert_not_contains "$out" "not verifiable" \
    "a backend that answered every query must never be described as unverifiable"

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

# All claimants finished, shared path still dirty: the kind is decided by
# process concurrency alone, so this reads `stale` - but the unlanded work must
# still be stated, or the one thing that could be destroyed here goes unsaid.
test_collision_lines_all_dead_unlanded_keeps_caveat() {
  local state fakebin wt out

  state="$TMP_ROOT/dead-unlanded-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/dead-unlanded-tmux")

  wt="$TMP_ROOT/wt-dead-unlanded"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$state/fm-dead-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-dead-b.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt claimed by fm-dead-a (process gone), fm-dead-b (process gone) - shared path still has unlanded work, do not discard" \
    "two finished records over dirty shared work should read stale and still carry the unlanded caveat"

  pass "fm_worktree_collision_lines: unlanded work is never silent even when no process is a hazard"
}

# A path that no longer exists is still a path two records both claim, so it is
# never dropped from the output: the vanished path becomes its own caveat, and
# an unverifiable process stays a hazard there exactly as it would anywhere
# else - the detector says what it cannot verify rather than staying silent.
test_collision_lines_gone_path_is_always_reported() {
  local state fakebin gone_path out

  state="$TMP_ROOT/gone-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/gone-tmux")
  gone_path="$TMP_ROOT/torn-down-wt"

  fm_write_meta "$state/fm-ambig-a.meta" "window=livesess:ambig" "worktree=$gone_path" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-ambig-b.meta" "window=livesess:ambig" "worktree=$gone_path" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: live $gone_path claimed by fm-ambig-a (process state unknown (backend=tmux reported ambiguous)), fm-ambig-b (process state unknown (backend=tmux reported ambiguous)) - shared worktree no longer exists at that path" \
    "two unverifiable claimants of a torn-down worktree must still be reported, naming the backend that could not answer and the vanished path"

  # A confirmed-alive claimant over the same vanished path: still reported, and
  # the alive claimant is named as the hazard it is.
  fm_write_meta "$state/fm-ambig-b.meta" "window=livesess:alive" "worktree=$gone_path" "harness=codex" "kind=ship"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: live $gone_path claimed by fm-ambig-a (process state unknown (backend=tmux reported ambiguous)), fm-ambig-b (process alive) - shared worktree no longer exists at that path" \
    "a confirmed-alive claimant of a worktree that no longer exists must still be reported"

  # One hazard only (alive plus a finished record) reads stale, and the gone
  # caveat is a path fact, so it rides that kind too.
  fm_write_meta "$state/fm-ambig-a.meta" "window=deadsess:win" "worktree=$gone_path" "harness=claude" "kind=ship"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: stale $gone_path claimed by fm-ambig-a (process gone), fm-ambig-b (process alive) - shared worktree no longer exists at that path" \
    "a live claimant beside a finished record over a vanished path reads stale and still carries the gone caveat"

  pass "fm_worktree_collision_lines: a vanished path is reported with its own caveat, never silenced"
}

# A path that is present but unreadable is the case bin/fm-teardown.sh refuses
# on: the probe proves only that git could not inspect it, so the line must not
# imply the path is empty, and the do-not-discard warning must survive.
test_collision_lines_uninspectable_path_keeps_do_not_discard() {
  local state fakebin wt out

  state="$TMP_ROOT/uninspectable-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/uninspectable-tmux")

  wt="$TMP_ROOT/wt-uninspectable"
  mkdir -p "$wt"
  echo "uncommitted work nobody can account for" > "$wt/scratch.txt"
  fm_write_meta "$state/fm-u-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-u-b.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt claimed by fm-u-a (process gone), fm-u-b (process gone) - shared path is not an inspectable git worktree, so whether work would be lost cannot be verified, do not discard" \
    "a shared path that exists but cannot be inspected must keep the do-not-discard warning"
  assert_not_contains "$out" "no longer exists" \
    "a path that is still on disk must never be reported as gone"

  # The same guarantee for a pool slot that is present but has no work tree at
  # all - the case bin/fm-teardown.sh's own --show-toplevel probe refuses on.
  wt="$TMP_ROOT/wt-bare-shared"
  git init -q --bare "$wt"
  fm_write_meta "$state/fm-u-a.meta" "window=deadsess:win" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-u-b.meta" "window=deadsess:win" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: stale $wt claimed by fm-u-a (process gone), fm-u-b (process gone) - shared path is not an inspectable git worktree, so whether work would be lost cannot be verified, do not discard" \
    "a shared path with no inspectable work tree must keep the do-not-discard warning"
  assert_not_contains "$out" "no longer exists" \
    "a path git could not inspect must never be reported as gone"

  pass "fm_worktree_collision_lines: an uninspectable shared path is never reported as empty"
}

# A recorded worktree path may contain any character a directory name can hold.
# A backslash used to be eaten by awk's own escape processing before the path
# was compared, so no record matched, and the line printed with nothing at all
# after "claimed by" - a collision naming no claimant.
test_collision_lines_path_with_backslash_names_every_claimant() {
  local state fakebin wt out
  local leaf='wt-back\tslash'

  state="$TMP_ROOT/backslash-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/backslash-tmux")

  wt="$TMP_ROOT/$leaf"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"
  fm_write_meta "$state/fm-bs-a.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-bs-b.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $wt claimed by fm-bs-a (process alive), fm-bs-b (process state unknown (backend=tmux reported ambiguous)) - shared path still has unlanded work, do not discard" \
    "a worktree path containing a backslash must still group its records and name every claimant"
  assert_not_contains "$out" "claimed by -" \
    "a collision line must never print with no claimant at all"
  assert_not_contains "$out" "claimed by $wt" \
    "a collision line must never print with no claimant at all"

  pass "fm_worktree_collision_lines: a path with a backslash still names every claimant"
}

# The scan is a snapshot taken without a fleet lock, so bin/fm-teardown.sh can
# remove state/<id>.meta between the snapshot and that record's process probe.
# The vanished record must be dropped, never reported as an unverifiable hazard
# pointing the reader at a record that no longer exists - and a path left with
# one surviving claimant is no longer a collision at all.
test_collision_lines_record_removed_mid_scan_is_dropped() {
  local state fakebin wt out
  local vanish_target=

  state="$TMP_ROOT/vanish-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/vanish-tmux")

  wt="$TMP_ROOT/wt-vanish"
  make_worktree "$wt"
  echo dirty > "$wt/scratch.txt"

  # Drop the record from disk as the scan finishes reading it, which is exactly
  # where a concurrent teardown lands: present for the snapshot, gone for the
  # probe.
  eval "$(declare -f fm_meta_get | sed '1s/^fm_meta_get/fm_meta_get_orig/')"
  fm_meta_get() {
    fm_meta_get_orig "$@"
    if [ -n "$vanish_target" ] && [ "$2" = remote_host ] && [ "$1" = "$vanish_target" ]; then
      rm -f "$1"
    fi
  }
  vanish_target="$state/fm-torn-down.meta"

  fm_write_meta "$state/fm-live-a.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-live-b.meta" "window=livesess:alive" "worktree=$wt" "harness=codex" "kind=ship"
  fm_write_meta "$vanish_target" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  assert_contains "$out" "WORKTREE_COLLISION: live $wt claimed by fm-live-a (process alive), fm-live-b (process alive) - shared path still has unlanded work, do not discard" \
    "the surviving claimants of a still-real collision must still be reported"
  assert_not_contains "$out" "fm-torn-down" \
    "a record removed during the scan must never be named as a claimant"

  # Only one record survives the teardown, so the collision has resolved itself.
  rm -f "$state/fm-live-b.meta"
  fm_write_meta "$vanish_target" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")

  unset -f fm_meta_get
  eval "$(declare -f fm_meta_get_orig | sed '1s/^fm_meta_get_orig/fm_meta_get/')"
  unset -f fm_meta_get_orig

  [ -z "$out" ] \
    || fail "a path left with one surviving record is no longer a collision, got:"$'\n'"$out"

  pass "fm_worktree_collision_lines: a record torn down mid-scan is dropped, not reported as a phantom hazard"
}

# Remote secondmate records name a home on another machine: that path is unique
# only when host-qualified, so it can never collide with a local worktree and
# neither the local git probe nor the local backend probe can judge it.
test_collision_lines_skips_remote_records() {
  local state fakebin wt out

  state="$TMP_ROOT/remote-state"
  mkdir -p "$state"
  fakebin=$(make_collision_tmux "$TMP_ROOT/remote-tmux")

  wt="$TMP_ROOT/wt-shared-remote-home"
  make_worktree "$wt"
  fm_write_meta "$state/fm-remote-a.meta" "window=remote:fm-remote-a" "worktree=$wt" \
    "harness=claude" "kind=secondmate" "remote_host=hostA" "remote_root=/srv/code"
  fm_write_meta "$state/fm-remote-b.meta" "window=remote:fm-remote-b" "worktree=$wt" \
    "harness=claude" "kind=secondmate" "remote_host=hostB" "remote_root=/srv/code"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  [ -z "$out" ] \
    || fail "two remote secondmates whose homes share a path string are on different machines and must not collide, got:"$'\n'"$out"

  fm_write_meta "$state/fm-local-x.meta" "window=livesess:alive" "worktree=$wt" "harness=claude" "kind=ship"
  fm_write_meta "$state/fm-local-y.meta" "window=livesess:ambig" "worktree=$wt" "harness=codex" "kind=ship"

  out=$(PATH="$fakebin:$PATH" fm_worktree_collision_lines "$state")
  assert_contains "$out" "WORKTREE_COLLISION: live $wt claimed by fm-local-x (process alive), fm-local-y (process state unknown (backend=tmux reported ambiguous))" \
    "the local pair sharing that same path must still be reported"
  assert_not_contains "$out" "fm-remote-a" \
    "a remote record must never be named as a claimant of a local worktree"
  assert_not_contains "$out" "fm-remote-b" \
    "a remote record must never be named as a claimant of a local worktree"

  pass "fm_worktree_collision_lines: remote_host= records are out of scope and never join a local collision"
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
test_collision_lines_all_dead_unlanded_keeps_caveat
test_collision_lines_gone_path_is_always_reported
test_collision_lines_uninspectable_path_keeps_do_not_discard
test_collision_lines_path_with_backslash_names_every_claimant
test_collision_lines_record_removed_mid_scan_is_dropped
test_collision_lines_skips_remote_records
test_collision_lines_silent_on_clean_home
test_bootstrap_surfaces_collision_line
