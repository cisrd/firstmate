#!/usr/bin/env bash
# Replay of the two secondmate wake-loop false alarms the captain measured on
# 2026-09-07 against the fmverif secondmate, driving the real captain-facing
# entry point (bin/fm-watch-checkpoint.sh) on the BASE watcher (d4eb228) and on
# the FIXED watcher (96930cb). Everything printed under "captain sees" is the
# verbatim stdout of the supervision checkpoint - what the firstmate actually
# has to read and act on. Each such line costs the captain one supervision turn.
#
# Usage:
#   git archive d4eb228 | tar -x -C /tmp/fm-base-d4eb228
#   TARGET_ROOT=<this worktree> BASE_ROOT=/tmp/fm-base-d4eb228 ./replay-2026-09-07-secondmate-stall.sh
set -u

TARGET_ROOT=${TARGET_ROOT:?}
BASE_ROOT=${BASE_ROOT:?}
WORK=$(mktemp -d /tmp/fm-stall-replay.XXXXXX)
TANGLE=$(mktemp -d /tmp/fm-stall-tangle.XXXXXX)
ALARM="$WORK/alarm-recorder"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "${1:-}" "${2:-}" >> "%s/alarm.log"\nexit 0\n' "$WORK" > "$ALARM"
chmod +x "$ALARM"
: > "$WORK/alarm.log"
trap 'rm -rf "$WORK" "$TANGLE"' EXIT

hr() { printf '%s\n' '--------------------------------------------------------------------------'; }

# Legend: "check: rearm-resurface" is the watcher re-surfacing the parent's OWN
# already-published, not-yet-drained wake queue. It is not a new stall finding,
# so it is not counted. The counted metric is the number of durable
# secondmate-wake-loop-fmverif-* rows in the firstmate's own wake queue: one row
# is one supervision turn the captain has to spend.

# setup_case <case-dir> [fake-clock]
setup_case() {
  local dir=$1 clock=${2:-}
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/fmverif/state"
  printf 'fmverif\n' > "$dir/fmverif/.fm-secondmate-home"
  printf 'window=firstmate:fm-fmverif\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$dir/fmverif" > "$dir/state/fmverif.meta"
  printf 'idle\n' > "$dir/pane.txt"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-fmverif' ;;
  capture-pane) cat "${FM_REPLAY_PANE:?}" ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  if [ -n "$clock" ]; then
    cat > "$dir/fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then cat "\${FM_REPLAY_NOW:?}"; else exec $(command -v date) "\$@"; fi
SH
    chmod +x "$dir/fakebin/date"
  fi
}

# observe <root> <dir> <label> -- runs one supervision checkpoint
observe() {
  local root=$1 dir=$2 label=$3
  shift 3
  printf '  $ bin/fm-watch-checkpoint.sh --seconds 2      # %s\n' "$label"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$TANGLE" \
    FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-fmverif' \
    FM_REPLAY_PANE="$dir/pane.txt" FM_REPLAY_NOW="$dir/now" \
    FM_WEDGE_ALARM_EXEC="$ALARM" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    "$root/bin/fm-watch-checkpoint.sh" --seconds 2 2>/dev/null \
    | sed 's/^/    captain sees | /'
}

supervision_turns() {  # <dir>
  grep -c 'secondmate-wake-loop-fmverif-' "$1/state/.wake-queue" 2>/dev/null || echo 0
}

# ===========================================================================
scenario_a() {  # measured defect 1: healthy queue draining at a real ~70s turn cadence
  local root=$1 tag=$2 dir
  dir="$WORK/$tag-a"
  setup_case "$dir" clock
  printf '\n### %s watcher - defect 1 replay: fmverif drains normally at a ~70s turn cadence\n' "$tag"
  printf '    (measured rows 409/434/436; FM_SECONDMATE_WAKE_STALL_SECS unset = this build default)\n\n'

  printf '1000\n' > "$dir/now"
  printf '937\t409\tcheck\trouted\tcheck: routed row 409\n995\t434\tcheck\trouted\tcheck: routed row 434\n' \
    > "$dir/fmverif/state/.wake-queue"
  observe "$root" "$dir" 't=1000s  queue=[409,434]  oldest row age 63s'

  # the mate finished its turn and drained 409
  printf '1070\n' > "$dir/now"
  printf '995\t434\tcheck\trouted\tcheck: routed row 434\n' > "$dir/fmverif/state/.wake-queue"
  observe "$root" "$dir" 't=1070s  mate drained 409, queue=[434]  oldest row age 75s'

  # the mate appended 436, then finished another turn and drained 434
  printf '1140\n' > "$dir/now"
  printf '1080\t436\tcheck\trouted\tcheck: routed row 436\n' > "$dir/fmverif/state/.wake-queue"
  observe "$root" "$dir" 't=1140s  mate drained 434, queue=[436]  oldest row age 60s'

  printf '\n    => supervision turns the captain pays for this HEALTHY session: %s\n' "$(supervision_turns "$dir")"
}

scenario_b() {  # measured defect 2: two workers stopped on a declared external wait
  local root=$1 tag=$2 dir
  dir="$WORK/$tag-b"
  setup_case "$dir" clock
  printf '\n### %s watcher - defect 2 replay: two declared external waits (upstream review)\n' "$tag"
  printf '    (verbatim measured rows; AGENTS.md section 8 says a declared pause needs no firstmate action)\n\n'
  cat > "$dir/fmverif/state/.wake-queue" <<'EOF'
1000	7	stale	fleet:w2:p4	stale: fleet:w2:p4 (paused 3613s, awaiting external - declared paused)
1000	8	stale	fleet:w2:p3	stale: fleet:w2:p3 (paused 3615s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)
EOF
  printf '4613\n' > "$dir/now"
  observe "$root" "$dir" 'first hourly poll, rows paused 3613s/3615s'
  printf '8613\n' > "$dir/now"
  observe "$root" "$dir" 'next hourly poll, still nothing but the declared wait' FM_SECONDMATE_WAKE_STALL_SECS=1
  printf '\n    => supervision turns the captain pays, every hour, for days: %s\n' "$(supervision_turns "$dir")"
}

scenario_c() {  # the real failure must still be caught, at the build's own default
  local root=$1 tag=$2 dir
  dir="$WORK/$tag-c"
  setup_case "$dir" clock
  printf '\n### %s watcher - a GENUINELY frozen wake loop, mate not in a turn\n' "$tag"
  printf '    (queue never advances; FM_SECONDMATE_WAKE_STALL_SECS unset = this build default)\n\n'
  printf '900\t409\tcheck\trouted\tcheck: routed row 409\n' > "$dir/fmverif/state/.wake-queue"
  printf '1000\n' > "$dir/now"
  observe "$root" "$dir" 't=1000s  first observation'
  printf '1070\n' > "$dir/now"
  observe "$root" "$dir" 't=1070s  70s with no drain progress - exactly one real turn'
  printf '1260\n' > "$dir/now"
  observe "$root" "$dir" 't=1260s  260s with no drain progress - well past any turn'
  printf '1460\n' > "$dir/now"
  observe "$root" "$dir" 't=1460s  still frozen - must not storm'
  printf '\n    => supervision turns for this REAL stall: %s (want exactly 1)\n' "$(supervision_turns "$dir")"
}

scenario_d() {  # active-turn gate defers, does not cancel
  local root=$1 tag=$2 dir
  dir="$WORK/$tag-d"
  setup_case "$dir"
  printf '\n### %s watcher - frozen queue while a live worker is mid-turn, then the turn ends\n' "$tag"
  printf '    (FM_SECONDMATE_WAKE_STALL_SECS=1, so only the active-turn gate can hold the alert back)\n\n'
  printf 'working\n' > "$dir/pane.txt"
  printf '%s\t409\tcheck\trouted\tcheck: routed row 409\n' "$(( $(date +%s) - 300 ))" \
    > "$dir/fmverif/state/.wake-queue"
  "$root/bin/fm-busy-event.sh" arm "$dir/state" fmverif >/dev/null 2>&1 \
    || printf '    (this build has no busy contract wiring for the mate)\n'
  observe "$root" "$dir" 'fmverif is mid-turn with a live worker implementing' FM_SECONDMATE_WAKE_STALL_SECS=1
  observe "$root" "$dir" 'still mid-turn, queue still frozen' FM_SECONDMATE_WAKE_STALL_SECS=1
  printf '    => supervision turns while the mate is demonstrably working: %s\n\n' "$(supervision_turns "$dir")"
  "$root/bin/fm-busy-event.sh" apply "$dir/state" fmverif idle --current-gen \
    --source claude-hook --event stop >/dev/null 2>&1 || true
  printf 'idle\n' > "$dir/pane.txt"
  observe "$root" "$dir" 'the turn ended and the queue is STILL frozen' FM_SECONDMATE_WAKE_STALL_SECS=1
  printf '\n    => supervision turns after the turn ended: %s (the alert is deferred, not cancelled)\n' \
    "$(supervision_turns "$dir")"
}

cat <<'LEGEND'
Replay of the 2026-09-07 fmverif secondmate wake-loop false alarms.
Each block drives the real captain-facing supervision entry point,
bin/fm-watch-checkpoint.sh, against a fixture reproducing the measured state.

  "captain sees | ..."        verbatim stdout of the supervision checkpoint
  "check: secondmate ..."     the stall escalation under test - one per supervision turn
  "check: rearm-resurface"    the watcher re-surfacing the parent's OWN already-published,
                              undrained wake queue. Not a new stall finding, not counted.
  "checkpoint: no actionable wake within 2s"
                              the checkpoint was quiet - the captain is not interrupted

  "supervision turns"         durable secondmate-wake-loop-fmverif-* rows in the firstmate's
                              own wake queue. One row = one supervision turn the captain pays.

LEGEND

scenario_e() {  # rollout safety: a pre-upgrade stall marker must not mute a real stall forever
  local root=$1 tag=$2 dir
  dir="$WORK/$tag-e"
  setup_case "$dir" clock
  printf '\n### %s watcher - upgrade rollout: a stall marker already on disk, no progress baseline yet\n' "$tag"
  printf '    (the state a real host is in the moment this build ships; the queue is genuinely frozen)\n\n'
  printf '900\t409\tcheck\trouted\tcheck: routed row 409\n' > "$dir/fmverif/state/.wake-queue"
  printf '800-409\n' > "$dir/state/.secondmate-wake-stall-fmverif"
  printf '1000\n' > "$dir/now"
  observe "$root" "$dir" 't=1000s  first observation after the upgrade'
  printf '1260\n' > "$dir/now"
  observe "$root" "$dir" 't=1260s  260s with no drain progress'
  printf '\n    => supervision turns for this REAL stall despite the pre-existing marker: %s (want exactly 1)\n' \
    "$(supervision_turns "$dir")"
}

for variant in BASE TARGET; do
  case "$variant" in
    BASE) root=$BASE_ROOT ;;
    TARGET) root=$TARGET_ROOT ;;
  esac
  hr
  printf '== %s watcher (%s) ==\n' "$variant" "$(git -C "$TARGET_ROOT" rev-parse --short "$( [ "$variant" = BASE ] && echo d4eb228 || echo 96930cb )")"
  hr
  scenario_a "$root" "$variant"
  scenario_b "$root" "$variant"
  scenario_c "$root" "$variant"
  scenario_d "$root" "$variant"
  scenario_e "$root" "$variant"
  printf '\n'
done
hr
printf 'no desktop notification was fired during this replay (alarm seam log): %s line(s)\n' \
  "$(wc -l < "$WORK/alarm.log" 2>/dev/null || echo 0)"
