#!/usr/bin/env bash
# fm-task-root.sh - retarget ONE recorded root of a task record: `worktree=` or
# `tasktmp=`, and nothing else.
#
# Why this exists. bin/fm-teardown.sh proves both recorded roots against
# bin/fm-worktree-proc-lib.sh's shape wall before it may signal anything inside
# them, and refuses a record that names the filesystem root, a path sitting
# directly in the home, or anything under the firstmate home's projects/ - the
# tree the captain's own stack lives in. A record that already carries such a
# path is then stuck: the wall has no --force escape, because forcing a reap
# under projects/ would kill exactly the stack the wall exists to protect.
#
# The escape is to correct the RECORD, not to weaken the wall, and the operator
# must not have to hand-edit a state file to do it. This command is that repair:
# it rewrites the single named field to a path that clears the same wall, under
# the same per-task locks every other lifecycle writer takes, leaving every
# other line of the record byte-identical. It signals nothing, removes nothing,
# and touches neither the old path nor the new one.
#
# EVERY REPLACEMENT CLEARS THE GUARD ITS OWN FIELD IS READ THROUGH, because a
# repair that writes a state some other guard then refuses is not a repair - it
# only moves the dead end. The two fields are read through different guards, so
# they are validated through different ones here:
#
#   worktree=  fm_wtproc_signalling_root, the shape wall teardown itself applies.
#              A task copy may legitimately be an ordinary clone rather than a
#              linked worktree, which teardown's own suite pins, so the stricter
#              linked-worktree proof would refuse a shape teardown must handle.
#   tasktmp=   fm_wtproc_task_tmp, which binds the temp root to the exact
#              $FM_TASK_TMP_ROOT/fm-<id> path bin/fm-spawn.sh creates. That is
#              the guard bin/fm-orphan-reap.sh reads this field through, and a
#              value teardown tolerates but the scanner refuses would print an
#              UNSCANNABLE line for the task at every session start. Anything
#              else is refused, naming the path that would be accepted.
#
# A replacement that does not exist yet is still walled. Existence is not what
# makes a path safe: accepting `<home>/projects/ghost` because nothing is there
# would record the very shape the wall exists to keep out and hand the refusal
# straight back the day that directory appears. An absent value clears
# fm_wtproc_prospective_root - the same refusals resolved against the deepest
# ancestor that does exist - and is then recorded and reported as absent, which
# is the truthful record for a disposable copy already removed.
#
# Usage: fm-task-root.sh <task-id> <worktree|tasktmp> <path>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# This command rewrites a durable task record, so a no-mistakes gate agent that
# has adopted the captain identity is kept out of it exactly as it is kept out
# of fm-spawn, fm-send and fm-teardown (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

usage() {
  echo "usage: fm-task-root.sh <task-id> <worktree|tasktmp> <path>" >&2
}

[ "$#" -eq 3 ] || { usage; exit 2; }
ID=$1
FIELD=$2
NEW=$3

fm_task_id_path_safe "$ID" || { echo "error: invalid task id" >&2; exit 2; }
case "$FIELD" in
  worktree|tasktmp) ;;
  *)
    echo "error: only the worktree and tasktmp roots may be retargeted (got '$FIELD')" >&2
    exit 2
    ;;
esac
case "$NEW" in
  /*) ;;
  *) echo "error: the replacement $FIELD must be an absolute path (got '$NEW')" >&2; exit 2 ;;
esac
case "$NEW" in
  *$'\n'*) echo "error: the replacement $FIELD may not contain a newline" >&2; exit 2 ;;
esac

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: retarget refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# Both of these create state on the way in - fm-wake-lib.sh makes $STATE at
# source time - so neither may load before the guard above has had its look.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worktree-proc-lib.sh
. "$SCRIPT_DIR/fm-worktree-proc-lib.sh"

META="$STATE/$ID.meta"
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
retarget_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap retarget_cleanup EXIT

fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1

fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: task record for $ID is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
}

EXPECTED_TASK_TMP="${FM_TASK_TMP_ROOT:-/tmp}/fm-$ID"
EXPECTED_TASK_TMP_REAL=$(fm_wtproc_prospective_root "$EXPECTED_TASK_TMP" "task $ID's own temp root" "$FM_HOME" 2>/dev/null) \
  || EXPECTED_TASK_TMP_REAL=$EXPECTED_TASK_TMP

ROOT_STATE=present
RESOLVED=
CHECK_RC=0
case "$FIELD" in
  worktree) RESOLVED=$(fm_wtproc_signalling_root "$NEW" "task $ID's replacement worktree" "$FM_HOME" 2>&1) || CHECK_RC=$? ;;
  tasktmp) RESOLVED=$(fm_wtproc_task_tmp "$ID" "$NEW" "$FM_HOME" 2>&1) || CHECK_RC=$? ;;
esac
case "$CHECK_RC" in
  0) ;;
  # Absent. The guard stops before its refusals in this case, so they are run
  # here against the path this WOULD resolve to, and the tasktmp binding - which
  # the absent guard never reached either - is checked lexically.
  2)
    ROOT_STATE=absent
    RESOLVED=$(fm_wtproc_prospective_root "$NEW" "task $ID's replacement $FIELD" "$FM_HOME" 2>&1) || {
      echo "error: '$NEW' is not a path this may ever record as task $ID's $FIELD (${RESOLVED:-the check refused it without stating a reason}); the record for $ID was not changed" >&2
      exit 1
    }
    if [ "$FIELD" = tasktmp ] && [ "$RESOLVED" != "$EXPECTED_TASK_TMP_REAL" ]; then
      echo "error: '$NEW' is not task $ID's own temp root; the only value accepted for tasktmp is $EXPECTED_TASK_TMP (the path bin/fm-spawn.sh builds for this task). The record for $ID was not changed" >&2
      exit 1
    fi
    ;;
  *)
    echo "error: '$NEW' is not a path this may ever record as task $ID's $FIELD (${RESOLVED:-the check refused it without stating a reason}); the record for $ID was not changed" >&2
    [ "$FIELD" != tasktmp ] || echo "The only value accepted for tasktmp is $EXPECTED_TASK_TMP, the path bin/fm-spawn.sh builds for this task." >&2
    exit 1
    ;;
esac

OLD=$(fm_meta_get "$META" "$FIELD")
TMP="$STATE/.$ID.meta.retarget.${BASHPID:-$$}"
grep -v "^$FIELD=" "$META" > "$TMP" || :
printf '%s=%s\n' "$FIELD" "$RESOLVED" >> "$TMP"
if ! fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE"; then
  rm -f -- "$TMP"
  TMP=
  echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
TMP=

echo "retargeted $ID $FIELD: ${OLD:-<unset>} -> $RESOLVED"
if [ "$ROOT_STATE" = absent ]; then
  echo "note: nothing exists at $RESOLVED; teardown will treat this root as already gone"
fi
