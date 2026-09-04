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
        prev=
        for arg in "$@"; do
          if [ "$prev" = -F ]; then
            case "$arg" in
              owner=true|owner=false|owner=null|name=true|name=false|name=null|owner=[0-9]*|name=[0-9]*)
                exit 1
                ;;
            esac
          fi
          prev=$arg
        done
        if [ -n "${FM_TEST_GH_PR_READ_FILE:-}" ] && [ -f "$FM_TEST_GH_PR_READ_FILE" ]; then
          line=$(head -n 1 "$FM_TEST_GH_PR_READ_FILE")
          tail -n +2 "$FM_TEST_GH_PR_READ_FILE" > "$FM_TEST_GH_PR_READ_FILE.next"
          mv "$FM_TEST_GH_PR_READ_FILE.next" "$FM_TEST_GH_PR_READ_FILE"
          printf '%s\n' "$line"
          exit 0
        fi
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

write_dequeued_marker() {
  local dir=$1 provider=${2:-github} host=${3:-github.com} path=${4:-o/r}
  local number=${5:-1} reason=${6:-failed_checks} created=${7:-2026-09-04T10:00:00Z}
  fm_pr_poll_dequeued_mark_notified "$dir/home/state" task-a \
    "$provider" "$host" "$path" "$number" "$reason" "$created" \
    || fail "could not write the ejection marker"
}

write_ready_meta() {
  local dir=$1 url=${2:-https://github.com/o/r/pull/1}
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$url"
  fm_pr_url_parse "$url" || fail "ready-meta fixture URL was invalid"
  write_dequeued_marker "$dir" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
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
  [ "$(cat "$dir/stdout")" = 'escalate: merge_conflict is not an automatic re-queue reason' ] \
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

test_forge_spelled_reason_requeues() {
  local dir rc
  dir=$(make_case forge-spelling)
  write_ready_meta "$dir"
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the forge's own spelling should requeue: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "CI_FAILURE did not requeue: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "CI_FAILURE did not call enqueuePullRequest"

  dir=$(make_case forge-spelling-timeout)
  write_ready_meta "$dir"
  set +e
  run_enqueue "$dir" ci_timeout > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a folded timeout reason should requeue: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "ci_timeout did not requeue: $(cat "$dir/stdout")"
  pass "a transient check failure requeues in the forge's spelling and in firstmate's"
}

test_unknown_reason_is_refused_by_name() {
  local dir rc
  dir=$(make_case unknown-reason)
  write_ready_meta "$dir"
  set +e
  run_enqueue "$dir" flurbed_by_kraken > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unknown reason should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: flurbed_by_kraken is not a known merge-queue ejection reason' ] \
    || fail "an unknown reason was not refused by name: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "an unknown reason called enqueuePullRequest"
  pass "a reason outside every known vocabulary is refused explicitly"
}

test_unlabelled_ejection_escalates() {
  local dir rc reason
  for reason in unreported unreadable; do
    dir=$(make_case "unlabelled-$reason")
    write_ready_meta "$dir"
    set +e
    run_enqueue "$dir" "$reason" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "an unlabelled ejection should escalate"
    [ "$(cat "$dir/stdout")" = "escalate: $reason the forge reported no usable ejection reason" ] \
      || fail "an unlabelled ejection did not say so: $(cat "$dir/stdout")"
    ! grep -q enqueuePullRequest "$dir/gh.log" \
      || fail "an unlabelled ejection called enqueuePullRequest"
  done
  pass "an ejection the forge did not label usably escalates instead of requeueing"
}

test_unrecorded_requeue_is_reported_as_queued() {
  local dir rc
  dir=$(make_case unrecorded-requeue)
  write_ready_meta "$dir"
  mkdir "$dir/home/state/task-a.pr-poll-enqueued"
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unrecorded requeue should still escalate"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "the requeue mutation did not run"
  grep -Fqx 'queued: https://github.com/o/r/pull/1' "$dir/stdout" \
    || fail "an unrecorded requeue hid the landed requeue: $(cat "$dir/stdout")"
  grep -Fqx 'escalate: failed_checks pull request was requeued but the attempt could not be recorded' \
    "$dir/stdout" || fail "an unrecorded requeue did not name the lost bound: $(cat "$dir/stdout")"
  pass "a requeue whose attempt could not be recorded is still reported as queued"
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

test_unknown_then_mergeable_requeues() {
  local dir rc reads
  dir=$(make_case unknown-then-mergeable)
  write_ready_meta "$dir"
  printf '%s\n%s\n' \
    $'PR_kwDOabc\tOPEN\tfalse\tfalse\tUNKNOWN\t\tSUCCESS\t0' \
    $'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tSUCCESS\t0' \
    > "$dir/pr-reads"
  set +e
  FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS=0 FM_TEST_GH_PR_READ_FILE="$dir/pr-reads" \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "UNKNOWN then MERGEABLE should requeue: $(cat "$dir/stdout") $(cat "$dir/stderr")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "UNKNOWN then MERGEABLE did not requeue: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "UNKNOWN then MERGEABLE did not call enqueuePullRequest"
  reads=$(grep -c reviewThreads "$dir/gh.log")
  [ "$reads" -eq 2 ] || fail "UNKNOWN then MERGEABLE did not re-read: $reads"
  pass "transient UNKNOWN mergeability is re-read until MERGEABLE"
}

test_persistent_unknown_mergeability_is_refused() {
  local dir rc
  dir=$(make_case persistent-unknown)
  write_ready_meta "$dir"
  set +e
  FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS=0 FM_PR_ENQUEUE_UNKNOWN_BUDGET_SECS=60 \
    FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tUNKNOWN\t\tSUCCESS\t0' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "persistent UNKNOWN should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks mergeable is UNKNOWN' ] \
    || fail "persistent UNKNOWN did not stay closed: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "persistent UNKNOWN called enqueuePullRequest"
  pass "UNKNOWN mergeability that never recomputes is refused rather than assumed mergeable"
}

test_ejection_marker_mismatch_is_refused() {
  local dir rc
  dir=$(make_case marker-mismatch)
  write_ready_meta "$dir"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/o/r/pull/2"
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a marker/metadata mismatch should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks ejection identity does not match task metadata' ] \
    || fail "mismatch did not refuse: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "mismatch called enqueuePullRequest"
  pass "enqueue refuses when the ejection marker and task metadata name different pull requests"
}

test_absent_rollup_is_named_not_called_red() {
  local dir rc
  dir=$(make_case absent-rollup)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\t\t0' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an absent rollup should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks no checks on the head commit' ] \
    || fail "an absent rollup was labelled as red checks: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "an absent rollup called enqueuePullRequest"
  pass "an absent check rollup is refused as missing checks, not as red checks"
}

test_graphql_string_fields_are_sent_raw() {
  local dir rc
  dir=$(make_case graphql-string-vars)
  write_ready_meta "$dir" https://github.com/true/true/pull/1
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a JSON-looking repo name should still requeue: $(cat "$dir/stdout") $(cat "$dir/stderr")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/true/true/pull/1' ] \
    || fail "JSON-looking repo name did not requeue: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "JSON-looking repo name did not call enqueuePullRequest"
  pass "GraphQL owner and name are sent as strings even when they look like JSON literals"
}

test_green_failed_checks_requeues_once
test_merge_conflict_escalates_without_enqueue
test_red_checks_escalate
test_unresolved_threads_escalate
test_already_queued_is_idempotent
test_unreadable_state_escalates
test_forge_spelled_reason_requeues
test_unknown_reason_is_refused_by_name
test_unlabelled_ejection_escalates
test_unrecorded_requeue_is_reported_as_queued
test_unknown_then_mergeable_requeues
test_persistent_unknown_mergeability_is_refused
test_ejection_marker_mismatch_is_refused
test_absent_rollup_is_named_not_called_red
test_graphql_string_fields_are_sent_raw
