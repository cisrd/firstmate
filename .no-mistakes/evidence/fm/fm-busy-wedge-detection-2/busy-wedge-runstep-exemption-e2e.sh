#!/usr/bin/env bash
# Manual end-to-end evidence: a busy pane whose progress counters are frozen.
# Case A: its authoritative no-mistakes run-step is still working (waiting on
#         upstream CI) -> the operator is NOT paged.
# Case B: nothing authoritative says it is alive -> the operator IS paged.
set -u
cd "$(dirname "$0")" >/dev/null
ROOT_REPO=${1:?worktree path}
cd "$ROOT_REPO"
. tests/wake-helpers.sh
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-busy-wedge-evidence)

file_mtime() { stat -c %Y "$1" 2>/dev/null; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
prime_turnend_seen() { local f=$1 base; base=$(basename "$f" | tr '.' '_'); printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"; }
record_pi_busy() { local state=$1 id=$2 gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id"); "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" --source pi-ext --event agent-start; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
# Acknowledge the intentional stop of the setup watcher, exactly as the suite does,
# so the next watcher does not open with a downtime-recovery wake of its own.
ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.evidence-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}
busy_footer() { printf 'Pollinating... (%ss - %s tokens - esc to interrupt)\n' "$1" "$2"; }
wait_poll_cycle() {
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 1; first=$(file_mtime "$beat"); [ -n "$first" ] && break; sleep 0.1; i=$((i+1)); done
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 1; now=$(file_mtime "$beat"); if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi; sleep 0.1; i=$((i+1)); done
  return 1
}
wait_for_exit() { local pid=$1 limit=${2:-150} i=0; while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done; return 1; }

scenario() {  # <name> <crew-state-line> <expect>
  local name=$1 crew=$2 expect=$3 dir state fakebin out capture window key id pid
  id="$name"
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="ship:fm-$id"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  busy_footer 61 2344 > "$capture"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/$id.meta"
  record_pi_busy "$state" "$id"
  printf 'working: waiting on the upstream pull request checks\n' > "$state/$id.status"
  printf '%s' "$(seen_sig "$state/$id.status")" > "$state/.seen-${id}_status"
  touch "$state/$id.turn-ended"; prime_turnend_seen "$state/$id.turn-ended"

  echo
  echo "##### CASE: $name"
  echo "--- what the operator's tmux pane shows (harness footer, token meter) ---"
  cat "$capture"
  echo "--- authoritative no-mistakes state for this crew (bin/fm-crew-state.sh) ---"
  echo "$crew"

  # Phase 1: a live watcher watches the meter rise, which is what arms the measure.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$crew" \
    FM_BUSY_TURN_MAX_SECS=999999 FM_STALE_ESCALATE_SECS=999999 FM_BUSY_NO_PROGRESS_SECS=999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { echo "SETUP FAILED (first reading)"; reap "$pid"; return 1; }
  busy_footer 61 2481 > "$capture"
  wait_poll_cycle "$state" "$pid" || { echo "SETUP FAILED (second reading)"; reap "$pid"; return 1; }
  reap "$pid"
  ack_stopped_cycle "$state" || echo "(could not acknowledge the setup stop)"
  echo "--- the meter was seen to rise (2344 -> 2481 tokens), so this pane's progress is measurable ---"
  [ -e "$state/.progress-moved-$key" ] && echo "armed: $state/.progress-moved-$key exists"
  # Now the meter freezes: the pane keeps ticking but the token count never moves again.
  busy_footer 900 2481 > "$capture"
  printf '%s' "$(( $(date +%s) - 1800 ))" > "$state/.progress-since-$key"
  echo "--- 30 minutes later the pane still says busy and the token meter has not moved ---"
  cat "$capture"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$crew" \
    FM_BUSY_TURN_MAX_SECS=999999 FM_STALE_ESCALATE_SECS=999999 FM_BUSY_NO_PROGRESS_SECS=1500 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if [ "$expect" = wake ]; then
    wait_for_exit "$pid" || { echo "RESULT: watcher never surfaced (UNEXPECTED)"; reap "$pid"; return 1; }
  else
    wait_poll_cycle "$state" "$pid" >/dev/null || true
    wait_poll_cycle "$state" "$pid" >/dev/null || true
    reap "$pid"
  fi
  echo "--- what fm-watch.sh printed to the operator ---"
  if [ -s "$out" ]; then cat "$out"; else echo "(nothing: the watcher absorbed this poll and kept watching)"; fi
  echo "--- the captain's wake queue (bin/fm-wake-drain.sh) ---"
  FM_STATE_OVERRIDE="$state" "$DRAIN" 2>&1 | grep -v '^●' | sed -n '1,12p'
  echo "--- watcher triage log ---"
  grep -E 'busy progress|busy no-progress' "$state/.watch-triage.log" | tail -4
}

scenario busy-runstep-waiting-on-ci 'state: working · source: run-step · monitoring upstream CI' quiet
scenario busy-wedged-no-authority 'state: unknown · source: none · no authoritative signal' wake
echo
echo "##### END"
