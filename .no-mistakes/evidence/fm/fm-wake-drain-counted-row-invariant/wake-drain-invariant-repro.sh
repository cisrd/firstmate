#!/usr/bin/env bash
# End-to-end reproduction of the reported field defect, driven through the real
# CLIs (bin/fm-guard.sh, bin/fm-wake-drain.sh, bin/fm-wake-grant.sh) of the tree
# passed as $1. Prints an operator-visible transcript.
set -u
TREE=$1
LABEL=$2
. "$TREE/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-e2e-repro)
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
GUARD="$ROOT/bin/fm-guard.sh"

PAYLOAD='stale: fleet:w2:p3 (paused 7227s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)'

hr() { printf '\n===== %s =====\n' "$1"; }
run() { # <label> <cmd...>
  local label=$1; shift
  printf '\n$ %s\n' "$label"
  "$@" 2>&1 | sed 's/^/    /'
  return 0
}

printf '######################################################################\n'
printf '# %s\n' "$LABEL"
printf '# tree: %s\n' "$ROOT"
printf '######################################################################\n'

# ---------------------------------------------------------------- scenario A
dir=$(make_case field-repro); state="$dir/state"
printf 'window=test:fm-w2\nkind=ship\n' > "$state/x.meta"
FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append stale "fleet:w2:p3" "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$PAYLOAD"

hr "A. the reported field state: one stale row queued, held by a LIVE supervision-branch grant"
printf '\nstate/.wake-queue (verbatim):\n'
sed 's/^/    /' "$state/.wake-queue"
FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" gen-live >/dev/null || { echo "GRANT ACTIVATE FAILED"; exit 1; }
seq0=$(awk -F '\t' 'END{print $2}' "$state/.wake-queue")
FM_STATE_OVERRIDE="$state" "$GRANT" publish gen-live "$seq0" >/dev/null || { echo "GRANT PUBLISH FAILED"; exit 1; }
printf '    (live branch grant published for sequence %s)\n' "$seq0"

run 'bin/fm-guard.sh   # what the operator is told on every guarded command' \
  env FM_STATE_OVERRIDE="$state" "$GUARD"
run 'bin/fm-wake-drain.sh   # what the operator gets when they follow that instruction' \
  env FM_STATE_OVERRIDE="$state" "$DRAIN"
invariant() { # <state> - INVARIANT: a row counted in the pending-warning condition
                # must be presented with an executable acknowledgement path.
  local st=$1 g d counted presented
  g=$(FM_STATE_OVERRIDE="$st" "$GUARD" 2>&1); d=$(FM_STATE_OVERRIDE="$st" "$DRAIN" 2>&1)
  case "$g" in *"queued wakes pending"*) counted=yes ;; *) counted=no ;; esac
  case "$d" in *WAKE_ACK_REQUIRED*) presented=yes ;; *) presented=no ;; esac
  printf '\n    queue holds %s row(s)\n' "$(awk 'END{print NR+0}' "$st/.wake-queue" 2>/dev/null || echo 0)"
  printf '    guard counts a row as drainable-by-main (ordinary warning): %s\n' "$counted"
  printf '    drain presents a row with an executable ack command:        %s\n' "$presented"
  if [ "$counted" = yes ] && [ "$presented" = no ]; then
    printf '    INVARIANT VIOLATED: counted but unpresentable -> queue is wedged\n'
  else
    printf '    INVARIANT HOLDS\n'
  fi
}
invariant "$state"

hr "A2. same row, same kind, same endpoint - grant released (nothing else changed)"
FM_STATE_OVERRIDE="$state" "$GRANT" release gen-live >/dev/null || echo "(release failed)"
run 'bin/fm-guard.sh' env FM_STATE_OVERRIDE="$state" "$GUARD"
run 'bin/fm-wake-drain.sh' env FM_STATE_OVERRIDE="$state" "$DRAIN"
err=$dir/a2.err
FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err"
s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
if [ -n "$s" ] && [ -n "$g" ]; then
  run "bin/fm-wake-drain.sh --ack-through $s --recovery-generation $g" \
    env FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$s" --recovery-generation "$g"
  printf '    queue after acknowledgement: %s row(s)\n' "$(awk 'END{print NR}' "$state/.wake-queue" 2>/dev/null || echo 0)"
else
  printf '    no acknowledgement command was presented\n'
fi

# ---------------------------------------------------------------- scenario B
dir=$(make_case truncated-repro); state="$dir/state"
printf 'window=test:fm-w2\nkind=ship\n' > "$state/x.meta"
FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append signal "task-a.status" "signal: task-a"' _ "$ROOT/bin/fm-wake-lib.sh"
printf '1788792074\t574\tstale\tfleet:w2:p3\n' >> "$state/.wake-queue"

hr "B. a structurally unusable row (lost its trailing fields) queued alongside a usable one"
printf '\nstate/.wake-queue (verbatim):\n'
cat -A "$state/.wake-queue" | sed 's/\$$//; s/\^I/<TAB>/g; s/^/    /'
run 'bin/fm-guard.sh' env FM_STATE_OVERRIDE="$state" "$GUARD"
run 'bin/fm-wake-drain.sh' env FM_STATE_OVERRIDE="$state" "$DRAIN"
printf '\n    queue now holds %s row(s):\n' "$(awk 'END{print NR}' "$state/.wake-queue")"
cat -A "$state/.wake-queue" | sed 's/\$$//; s/\^I/<TAB>/g; s/^/      /'
err=$dir/b.err
FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err"
s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
if [ -n "$s" ] && [ -n "$g" ]; then
  run "bin/fm-wake-drain.sh --ack-through $s --recovery-generation $g" \
    env FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$s" --recovery-generation "$g"
else
  printf '    no acknowledgement command was presented\n'
fi
printf '    queue after acknowledgement: %s row(s)\n' "$(awk 'END{print NR}' "$state/.wake-queue" 2>/dev/null || echo 0)"
run 'bin/fm-guard.sh   # is the queue finally quiet?' env FM_STATE_OVERRIDE="$state" "$GUARD"
invariant "$state"
printf '\n'
