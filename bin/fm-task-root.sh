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
# The replacement is validated with fm_wtproc_signalling_root, the same check
# teardown applies, so this command can never move a record from one refused
# path to another. A replacement that does not exist is accepted and reported:
# teardown treats an absent root as nothing-to-scan, which is the correct record
# for a disposable copy that is already gone.
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

# The replacement clears the SAME wall teardown applies, so this command can
# never move a record off one refused path onto another. Absent is accepted:
# teardown reads a missing root as nothing to scan, which is the truthful record
# for a copy that has already been removed.
ROOT_STATE=present
RESOLVED=
CHECK_RC=0
RESOLVED=$(fm_wtproc_signalling_root "$NEW" "task $ID's replacement $FIELD" "$FM_HOME" 2>&1) || CHECK_RC=$?
case "$CHECK_RC" in
  0) ;;
  2) ROOT_STATE=absent; RESOLVED=$NEW ;;
  *)
    echo "error: '$NEW' is not a path teardown may ever signal into (${RESOLVED:-the check refused it without stating a reason}); the record for $ID was not changed" >&2
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
