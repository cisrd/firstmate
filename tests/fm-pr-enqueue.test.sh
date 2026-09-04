#!/usr/bin/env bash
# Behavior tests for automatic merge-queue re-queue and its one-attempt bound.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

ENQUEUE="$ROOT/bin/fm-pr-enqueue.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-enqueue)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    case " $* " in
      *enqueuePullRequest*)
        [ "${FM_TEST_GH_ENQUEUE_FAIL:-0}" = 0 ] || exit 1
        printf '%s\n' "${FM_TEST_GH_ENQUEUE_ID:-ME_kwDOQueued}"
        exit 0
        ;;
      *reviewThreads*)
        [ "${FM_TEST_GH_READ_FAIL:-0}" = 0 ] || exit 1
        if [ -n "${FM_TEST_GH_PR_READ+x}" ]; then
          printf '%s\n' "$FM_TEST_GH_PR_READ"
        else
          line=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tSUCCESS\t0'
          printf '%s\n' "$line"
        fi
        exit 0
        ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

write_ready_meta() {
  local dir=$1
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/o/r/pull/1"
}

run_enqueue() {
  local dir=$1 reason=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$ENQUEUE" task-a "$reason"
}

test_green_failed_checks_requeues_once() {
  local dir rc
  dir=$(make_case green-requeue)
  write_ready_meta "$dir"
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "green failed_checks should requeue: $(cat "$dir/stderr")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "requeue did not print the canonical URL: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "requeue did not call enqueuePullRequest"
  ! grep -E 'pr merge| --auto' "$dir/gh.log" >/dev/null \
    || fail "requeue used a merge command"
  [ -f "$dir/home/state/task-a.pr-poll-enqueued" ] || fail "requeue did not record the attempt"

  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout2" 2> "$dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "second automatic requeue should escalate"
  [ "$(cat "$dir/stdout2")" = 'escalate: failed_checks already requeued once' ] \
    || fail "second attempt did not name the bound: $(cat "$dir/stdout2")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 1 ] || fail "the bound still called enqueuePullRequest again"
  pass "green failed_checks requeues once and then escalates"
}

test_merge_conflict_escalates_without_enqueue() {
  local dir rc
  dir=$(make_case conflict)
  write_ready_meta "$dir"
  set +e
  run_enqueue "$dir" merge_conflict > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "merge_conflict should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: merge_conflict' ] \
    || fail "merge_conflict did not keep the forge reason: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "merge_conflict called enqueuePullRequest"
  [ ! -e "$dir/home/state/task-a.pr-poll-enqueued" ] || fail "conflict recorded an enqueue attempt"
  pass "merge_conflict escalates without enqueueing"
}

test_red_checks_escalate() {
  local dir rc
  dir=$(make_case red-checks)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tFAILURE\t0' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "red checks should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks checks are not green' ] \
    || fail "red checks did not say so: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "red checks called enqueuePullRequest"
  pass "red checks escalate instead of requeueing"
}

test_unresolved_threads_escalate() {
  local dir rc
  dir=$(make_case unresolved)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tSUCCESS\t2' \
    run_enqueue "$dir" checks_timed_out > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unresolved threads should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: checks_timed_out unresolved review threads' ] \
    || fail "unresolved threads did not say so: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "unresolved threads called enqueuePullRequest"
  pass "unresolved review threads escalate instead of requeueing"
}

test_already_queued_is_idempotent() {
  local dir rc
  dir=$(make_case already-queued)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\ttrue\tMERGEABLE\t\tSUCCESS\t0' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "already-queued should succeed"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "already-queued did not print queued: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "already-queued still mutated"
  [ ! -e "$dir/home/state/task-a.pr-poll-enqueued" ] \
    || fail "already-queued counted against the bound"
  pass "a pull request already in the queue is reported queued without a mutation"
}

test_unreadable_state_escalates() {
  local dir rc
  dir=$(make_case unreadable)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_READ_FAIL=1 run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unreadable forge state should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks forge state could not be read' ] \
    || fail "unreadable state did not stay closed: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "unreadable state called enqueuePullRequest"
  pass "an unreadable forge read escalates instead of enqueueing"
}

test_green_failed_checks_requeues_once
test_merge_conflict_escalates_without_enqueue
test_red_checks_escalate
test_unresolved_threads_escalate
test_already_queued_is_idempotent
test_unreadable_state_escalates
