#!/usr/bin/env bash
# End-to-end captain transcript for the three reported defects, driven through
# the real bin/fm-send.sh and bin/fm-wake-drain.sh executables.
#   usage: reserved-key-scenarios.sh <firstmate-tree> <label>
set -u
TREE=$1; LABEL=$2
SEND="$TREE/bin/fm-send.sh"
DRAIN="$TREE/bin/fm-wake-drain.sh"
WORK=$(mktemp -d /tmp/fm-evidence.XXXXXX)
FB="$WORK/fakebin"; mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '+----+\n|    |\n+----+\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1 fm-mate; exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/sleep"; chmod +x "$FB/sleep"

. "$TREE/bin/fm-marker-lib.sh"
# The gate-lifecycle guard refuses fleet drivers from a gate worktree; the repo's
# own suite (tests/lib.sh) exempts itself the same way so real binaries can run.
export FM_GATE_REFUSE_BYPASS=1
unset FM_TASK_ID

hr() { printf '\n===============================================================\n%s\n===============================================================\n' "$1"; }
show() { printf '\n$ %s\n' "$1"; }

printf '######  firstmate reserved-decision-key captain transcript  ######\n'
printf 'tree      : %s\n' "$LABEL"
printf 'reserved  : FM_CLASSIFY_RESERVED_KEY_PREFIXES="pending-reply- secret-"\n'
export FM_CLASSIFY_RESERVED_KEY_PREFIXES='pending-reply- secret-'

########################################################################
hr 'SCENARIO A - the captain answers a reserved key that the OPEN DECISIONS fold itself listed as blocked'
HOME_A="$WORK/A"; mkdir -p "$HOME_A/state"
printf 'window=sess:fm-t1\nkind=ship\n' > "$HOME_A/state/t1.meta"
printf 'blocked [key=secret-abc]: secret-held: cannot ship until the captain rules\n' > "$HOME_A/state/t1.status"
show "cat state/t1.status"
cat "$HOME_A/state/t1.status"
show "bin/fm-wake-drain.sh          # what the captain sees before answering"
FM_STATE_OVERRIDE="$HOME_A/state" "$DRAIN" 2>&1 | sed -n '/OPEN DECISIONS/,$p'
show "bin/fm-send.sh t1 --resolve-key secret-abc 'ship it, the hold is cleared'"
: > "$WORK/send.log"
env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$HOME_A" FM_HOME="$HOME_A" \
  FM_SEND_LOG="$WORK/send.log" FM_SEND_SETTLE=0 \
  "$SEND" t1 --resolve-key secret-abc "ship it, the hold is cleared" 2>&1
printf '[exit %s]\n' "$?"
show "cat state/t1.status                       # did the close get written?"
cat "$HOME_A/state/t1.status"
show "cat state/t1.inbox/001.msg                # was the answer delivered?"
cat "$HOME_A/state/t1.inbox/001.msg" 2>&1 || printf '(no inbox record - nothing was delivered)\n'
show "bin/fm-wake-drain.sh          # is the decision gone from the captain's list?"
out=$(FM_STATE_OVERRIDE="$HOME_A/state" "$DRAIN" 2>&1)
if printf '%s' "$out" | grep -qF 'OPEN DECISIONS'; then
  printf '%s\n' "$out" | sed -n '/OPEN DECISIONS/,$p'
  printf '>>> STILL OPEN\n'
else
  printf '(no OPEN DECISIONS section - the reserved key is closed)\n'
fi

########################################################################
hr 'SCENARIO B - a mate writes the documented explicit resolution by hand on a reserved key'
HOME_B="$WORK/B"; mkdir -p "$HOME_B/state"
printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$HOME_B/state/ios.status"
OFF=$(LC_ALL=C wc -c < "$HOME_B/state/ios.status" | tr -d '[:space:]')
printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$HOME_B/state/ios.status"
show "cat state/ios.status"
cat "$HOME_B/state/ios.status"
show "bin/fm-wake-drain.sh          # captain-facing surfaces after the manual line"
FM_STATE_OVERRIDE="$HOME_B/state" "$DRAIN" 2>&1 | sed -n '/OPEN DECISIONS\|UNREAD STATUS/,$p'
show "status_span_first_actionable_record over the manual line  # what the watcher classifies"
bash -c '. "$1"; rec=""; nd=""
  rc=0; status_span_first_actionable_record "$2" "$3" rec nd || rc=$?
  printf "rc=%s\nevents=%s\nneeds_decision=%s\n" "$rc" "${rec:-<none>}" "${nd:-0}"' \
  _ "$TREE/bin/fm-classify-lib.sh" "$HOME_B/state/ios.status" "$OFF" 2>&1
printf '\n(rc=1 / no events = the manual resolution was a SILENT no-op;\n needs_decision=1 = the reconciliation error routes to the captain, not the Pi supervision branch)\n'

########################################################################
hr 'SCENARIO C - vocabulary written by an authoritative captain-held transfer'
show 'status_decision_close_note <verb> pending-reply-abcdef0123456789 "tracked by sample-call"'
bash -c '. "$1"
  if ! command -v status_decision_close_note >/dev/null 2>&1; then
    printf "(status_decision_close_note does not exist in this tree)\n"; exit 0
  fi
  for v in resolved captain-held; do
    printf "%-13s -> %s\n" "$v" "$(status_decision_close_note "$v" pending-reply-abcdef0123456789 "tracked by sample-call")"
  done' _ "$TREE/bin/fm-classify-lib.sh" 2>&1

rm -rf "$WORK"
