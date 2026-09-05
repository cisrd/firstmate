#!/usr/bin/env bash
# End-to-end walkthrough of the captain's 2026-09-04 report: a green delivery
# leaves the GitHub merge queue, nobody is woken. Uses the real production
# scripts against a fake gh serving the forge fixtures.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
WORK=$(mktemp -d /tmp/fm-evid-run.XXXXXX)
FIX="$WORK/fixtures"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
export FIX
mkdir -p "$WORK/fakebin"
cp /tmp/fm-evid/gh "$WORK/fakebin/gh"
# jq is needed by the fake forge only.
ln -sf "$(command -v jq)" "$WORK/fakebin/jq"

say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

fixture() { # <number> <state> <reason> <at> <inqueue> <mergeable> <rollup> <unresolved>
  local n=$1 st=$2 reason=$3 at=$4 inq=$5 mrg=$6 roll=$7 unres=$8 rjson threads
  mkdir -p "$FIX/$n"
  printf '%s\n' "$st" > "$FIX/$n/state"
  if [ "$reason" = none ]; then rjson=null; else rjson="\"$reason\""; fi
  cat > "$FIX/$n/timeline.json" <<JSON
{"data":{"repository":{"pullRequest":{"isInMergeQueue":$inq,"timelineItems":{"nodes":[
 {"__typename":"AddedToMergeQueueEvent","createdAt":"2026-09-04T09:30:00Z"},
 {"__typename":"RemovedFromMergeQueueEvent","createdAt":"$at","reason":$rjson}]}}}}}
JSON
  threads='[]'
  [ "$unres" = 0 ] || threads='[{"isResolved":false,"isOutdated":false}]'
  if [ "$roll" = none ]; then roll=null; else roll="{\"state\":\"$roll\"}"; fi
  cat > "$FIX/$n/pr.json" <<JSON
{"data":{"repository":{"pullRequest":{"id":"PR_kwDO$n","state":"$st","isDraft":false,
 "isInMergeQueue":$inq,"mergeable":"$mrg","reviewDecision":"APPROVED",
 "commits":{"nodes":[{"commit":{"statusCheckRollup":$roll}}]}},
 "reviewThreads":{"nodes":$threads}}}}
JSON
  # reviewThreads belongs inside pullRequest; rebuild with jq to keep it exact.
  jq -c '.data.repository.pullRequest += {reviewThreads: .data.repository.reviewThreads} | del(.data.repository.reviewThreads)' \
    "$FIX/$n/pr.json" > "$FIX/$n/pr.json.tmp" && mv "$FIX/$n/pr.json.tmp" "$FIX/$n/pr.json"
}

new_home() { # <name>
  local d="$WORK/$1"
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/wt" "$d/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/root/bin/fm-guard.sh"
  chmod +x "$d/root/bin/fm-guard.sh"
  printf '%s\n' "$d"
}

arm() { # <dir> <task> <url>
  local d=$1 id=$2 url=$3
  printf 'window=fm-%s\nendpoint_task_id=%s\nworktree=%s\nkind=ship\nmode=no-mistakes\n' \
    "$id" "$id" "$d/wt" > "$d/home/state/$id.meta"
  chmod 0600 "$d/home/state/$id.meta"
  FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" PATH="$WORK/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-check.sh" "$id" "$url"
}

watch_cycle() { # <dir>  -> prints the wake firstmate receives
  local d=$1
  rm -f "$d/home/state/.last-check"
  perl -e 'my $pid=fork; die unless defined $pid; if(!$pid){exec @ARGV} local $SIG{ALRM}=sub{kill "TERM",$pid; waitpid $pid,0; exit 124}; alarm 15; waitpid $pid,0; alarm 0; exit($?>>8)' \
    env FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$WORK/fakebin:$BASE_PATH" \
      "$ROOT/bin/fm-watch.sh" 2>"$d/watch.err"
}

ack() { # <dir> - acknowledge the wake so the next cycle is a fresh observation
  local d=$1 st="$d/home/state" seq gen err="$d/ack.err"
  FM_STATE_OVERRIDE="$st" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_STATE_OVERRIDE="$st" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}

enqueue() { # <dir> <task> <reason>
  local d=$1 id=$2 reason=$3
  FM_HOME="$d/home" FM_STATE_OVERRIDE="$d/home/state" PATH="$WORK/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-enqueue.sh" "$id" "$reason"
}

# --- the captain's four deliveries, 2026-09-04 -------------------------------
fixture 447 OPEN MERGE_CONFLICT   2026-09-04T09:41:00Z false MERGEABLE SUCCESS 0
fixture 450 OPEN FAILED_CHECKS    2026-09-04T10:02:00Z false MERGEABLE SUCCESS 0
fixture 451 OPEN CHECKS_TIMED_OUT 2026-09-04T11:17:00Z false MERGEABLE SUCCESS 0
fixture 453 OPEN CHECKS_TIMED_OUT 2026-09-04T12:48:00Z false MERGEABLE SUCCESS 0

say "=== 1. The reported failure: an ejected PR is OPEN, so the old poll is silent ==="
say ""
git -C "$ROOT" show 8f7b79c77c2198a71a01082215227a64500015e3:bin/fm-pr-poll.sh > "$WORK/old-fm-pr-poll.sh"
chmod +x "$WORK/old-fm-pr-poll.sh"
d=$(new_home before)
arm "$d" task-450 https://github.com/o/r/pull/450 >/dev/null || exit 1
say "\$ gh pr view https://github.com/o/r/pull/450 --json state -q .state"
PATH="$WORK/fakebin:$BASE_PATH" gh pr view https://github.com/o/r/pull/450 --json state -q .state
say "  (ejected from the merge queue at 2026-09-04T10:02:00Z, reason FAILED_CHECKS)"
say ""
say "\$ <poll program at base 8f7b79c> --validated github https://github.com/o/r/pull/450 github.com o/r 450"
say "  # this is exactly how the watcher runs an armed poll"
out=$(PATH="$WORK/fakebin:$BASE_PATH" "$WORK/old-fm-pr-poll.sh" --validated github https://github.com/o/r/pull/450 github.com o/r 450 2>&1)
printf '%s\n' "${out:-<no output>}"
say "  -> no output: nobody is woken, the delivery sleeps. This is the bug."
say ""
say "  (the harness is wired: the same old program still reports a merge)"
printf '%s\n' MERGED > "$FIX/450/state"
say "\$ <poll program at base 8f7b79c> --validated ... 450     # with the PR MERGED"
PATH="$WORK/fakebin:$BASE_PATH" "$WORK/old-fm-pr-poll.sh" --validated github https://github.com/o/r/pull/450 github.com o/r 450
printf '%s\n' OPEN > "$FIX/450/state"
say ""
say "\$ bin/fm-pr-poll.sh --validated github https://github.com/o/r/pull/450 github.com o/r 450   # AFTER"
PATH="$WORK/fakebin:$BASE_PATH" "$ROOT/bin/fm-pr-poll.sh" --validated github https://github.com/o/r/pull/450 github.com o/r 450
say "  -> a second signal, distinct from merged."
say ""
say "\$ cmp -s bin/fm-pr-poll.sh state/task-450.check.sh   # the armed check is that program"
cmp -s "$ROOT/bin/fm-pr-poll.sh" "$d/home/state/task-450.check.sh" \
  && say "armed check is byte-identical to bin/fm-pr-poll.sh" || say "DIFFERENT"
rule

say "=== 2. What firstmate actually receives: the watcher wake, one per ejection ==="
for pr in 447 450 451 453; do
  case $pr in
    447) reason=merge_conflict ;;
    450) reason=failed_checks ;;
    *) reason=checks_timed_out ;;
  esac
  d=$(new_home "wake-$pr")
  arm "$d" "task-$pr" "https://github.com/o/r/pull/$pr" >/dev/null || exit 1
  say ""
  say "--- PR $pr ($reason) ---"
  say "\$ bin/fm-watch.sh      # cycle 1"
  watch_cycle "$d"
  ack "$d"
  say "\$ bin/fm-watch.sh      # cycle 2, same ejection, nothing new happened"
  o=$(watch_cycle "$d")
  printf '%s\n' "${o:-<silent: the same ejection never wakes twice>}"
  say "\$ cat state/task-$pr.pr-poll-dequeued   # the ejection identity that keeps it quiet"
  sed -n '1,8p' "$d/home/state/task-$pr.pr-poll-dequeued"
  printf '%s\n' "$d" > "$WORK/dir-$pr"
done
rule

say "=== 3. Firstmate's response to a dequeued: wake (AGENTS.md section 8 item 3) ==="
for pr in 447 450 451 453; do
  case $pr in
    447) reason=merge_conflict ;;
    450) reason=failed_checks ;;
    *) reason=checks_timed_out ;;
  esac
  d=$(cat "$WORK/dir-$pr")
  say ""
  say "\$ bin/fm-pr-enqueue.sh task-$pr $reason"
  enqueue "$d" "task-$pr" "$reason"; rc=$?
  say "[exit $rc]"
  say "\$ bin/fm-pr-enqueue.sh task-$pr $reason    # the same ejection, answered again"
  enqueue "$d" "task-$pr" "$reason"; rc=$?
  say "[exit $rc]"
done
rule

say "=== 4. Re-queue is not a merge ==="
d=$(cat "$WORK/dir-450")
say "\$ ls state/task-450.*"
(cd "$d/home/state" && ls task-450.* | sed 's/^/  /')
say "  poll still armed (task-450.check.sh, task-450.pr-poll), no retirement,"
say "  no merge notification: the delivery is back in the queue, not merged."
say ""
say "\$ grep -c . state/task-450.pr-poll-merge-notified 2>/dev/null || echo '  no merge outcome recorded'"
grep -c . "$d/home/state/task-450.pr-poll-merge-notified" 2>/dev/null || echo "  no merge outcome recorded"
say ""
say "\$ cat state/task-450.pr-poll-enqueued        # the automatic-attempt bound"
sed -n '1,9p' "$d/home/state/task-450.pr-poll-enqueued"
rule

say "=== 5. Refusals: only green + resolved is re-queued, and errors stay silent ==="
fixture 460 OPEN FAILED_CHECKS 2026-09-04T13:00:00Z false MERGEABLE FAILURE 0
fixture 461 OPEN FAILED_CHECKS 2026-09-04T13:10:00Z false MERGEABLE SUCCESS 1
fixture 462 OPEN none          2026-09-04T13:20:00Z false MERGEABLE SUCCESS 0
for pr in 460 461 462; do
  d=$(new_home "refuse-$pr")
  arm "$d" "task-$pr" "https://github.com/o/r/pull/$pr" >/dev/null || exit 1
  say ""
  case $pr in
    460) say "--- PR $pr: red checks ---" ;;
    461) say "--- PR $pr: unresolved review thread ---" ;;
    462) say "--- PR $pr: the forge left the ejection unlabelled ---" ;;
  esac
  say "\$ bin/fm-watch.sh"
  wake=$(watch_cycle "$d"); printf '%s\n' "$wake"
  reason=$(printf '%s\n' "$wake" | sed -n 's/.*dequeued:\([A-Za-z0-9_]*\):.*/\1/p')
  say "\$ bin/fm-pr-enqueue.sh task-$pr $reason"
  enqueue "$d" "task-$pr" "$reason"; say "[exit $?]"
done
say ""
say "--- a forge read that fails is still silent, never read as an ejection ---"
d=$(new_home "forge-down")
fixture 470 OPEN FAILED_CHECKS 2026-09-04T14:00:00Z false MERGEABLE SUCCESS 0
arm "$d" task-470 https://github.com/o/r/pull/470 >/dev/null || exit 1
say "\$ FM_FAKE_GH_FAIL=1 bin/fm-watch.sh     # gh cannot reach the forge"
o=$(FM_FAKE_GH_FAIL=1 watch_cycle "$d")
printf '%s\n' "${o:-<silent: a failed lookup is never a merge and never an ejection>}"
rule
say "walkthrough complete"
