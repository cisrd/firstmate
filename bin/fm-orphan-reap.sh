#!/usr/bin/env bash
# fm-orphan-reap.sh - find, and on an explicit instruction stop, the processes
# still running in the local copy of a task whose agent is gone.
#
# Usage:
#   fm-orphan-reap.sh scan [--task <id>]
#   fm-orphan-reap.sh reap <task-id>
#
# THE GAP THIS CLOSES. bin/fm-teardown.sh stops a task's processes, but it only
# runs on a deliberate cleanup. When the agent dies on its own - quota exhausted,
# harness crash, terminal closed - nobody comes back for the copy, and whatever
# it was running keeps running. Observed 2026-08-27: a server started at 00:50
# outlived the agent that started it (stopped 02:06) by eight and a half hours
# and took the host to 97% CPU, 90.6% of it system time, through 1460 accumulated
# proxied connections; stopping that one process took the load from 98 to 22 and
# system time from 90.6% to 3.9%. The day before, 41 processes of the same shape
# were found alive and stopped by hand.
#
# WHY `scan` REPORTS INSTEAD OF STOPPING. `reap` exists, but nothing calls it
# automatically, and that is the design, not an omission:
#
#   - The verdict rests on reading a worker as gone, and that reading can be
#     wrong: for several harnesses the endpoint classifier reads a
#     vendor-rendered surface, and one was observed on 2026-08-27 reporting
#     `dead` for a worker that was running. A wrong verdict would stop that
#     worker's own server in the middle of its run. The gate below makes two
#     independent sources agree, which is why this is safe enough to REPORT -
#     but agreement between two readings is still weaker than what
#     bin/fm-control.sh's relaunch normally has, where the agent was COMMANDED
#     to stop and the stop was watched happening.
#   - A dead agent's copy is exactly where firstmate or the captain looks after a
#     failure, and a captain working directly in a crewmate's window is
#     authoritative (AGENTS.md hard rule 4). An unattended sweep races that.
#   - The harm is cumulative, not instantaneous. The incident above needed eight
#     and a half hours to saturate the host. Acting on a reported orphan within a
#     supervision cycle is fast enough; automating it buys minutes and costs a
#     whole new class of failure.
#   - Every case where ownerless is a FACT is already automatic: a replaced
#     incarnation (bin/fm-control.sh relaunch) and a completed task
#     (bin/fm-teardown.sh). What is left here is the case that needs judgement,
#     and judgement is firstmate's.
#
# The asymmetry decides it: a missed leftover costs CPU in a disposable copy,
# while a wrong stop costs a live worker its run.
#
# SAFETY BOUNDARIES, all enforced here and in bin/fm-worktree-proc-lib.sh:
#   - Attribution is the process's real working directory, read from /proc, and
#     nothing else. No command name is ever matched.
#   - The copy must prove itself a linked git worktree that is not a primary
#     checkout, so no clone anyone works in directly can ever be a target.
#   - Only a task recorded here as a ship or scout qualifies; a secondmate's
#     recorded worktree is its firstmate home.
#   - The agent must read positively dead or missing AND the task's current
#     state must agree, from a second, independent source. A backend classifier
#     was observed calling a running worker dead, so neither source decides
#     alone.
#   - The shell of the task's OWN recorded endpoint is spared, so a copy stays
#     relaunchable - identified from that record (the backend's pane pid) and
#     never inferred from a process's own shape. A session leader that is not
#     that shell is an ordinary leftover: the process that saturated the host on
#     2026-08-27 was reparented to init, and a rule that spared every session
#     leader would have missed exactly it.
#   - When the record cannot yield that pid, nothing is guessed: every session
#     leader is left alone and the report SAYS how many, because a silently
#     empty result would read as "this copy is clean".
#   - An unreadable /proc/<pid>/cwd means the process is left alone.
#   - Processes only. This script never removes a file, never touches git, and
#     never tears a copy down.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worktree-proc-lib.sh
. "$SCRIPT_DIR/fm-worktree-proc-lib.sh"

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

# Resolve the roots this task's processes may legitimately be attributed to.
# Prints them one per line; a task that cannot qualify prints nothing and
# returns 1, with the reason on stderr only when <verbose> is 1.
task_roots() {  # <task-id> <meta> <verbose>
  local id=$1 meta=$2 verbose=$3 kind wt tmp wt_real tmp_real
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *)
      [ "$verbose" = 1 ] && echo "task $id is recorded as $kind; its local copy is not a disposable task copy" >&2
      return 1
      ;;
  esac
  wt=$(fm_meta_get "$meta" worktree)
  if ! wt_real=$(fm_wtproc_disposable_worktree "$wt" "$FM_HOME" 2>/dev/null); then
    if [ "$verbose" = 1 ]; then
      fm_wtproc_disposable_worktree "$wt" "$FM_HOME" >/dev/null || true
    fi
    return 1
  fi
  printf '%s\n' "$wt_real"
  tmp=$(fm_meta_get "$meta" tasktmp)
  if [ -n "$tmp" ] && tmp_real=$(fm_wtproc_task_tmp "$id" "$tmp" "$FM_HOME" 2>/dev/null); then
    printf '%s\n' "$tmp_real"
  fi
}

# The pid of the shell this task's OWN endpoint runs, read from the record, or
# `unknown` when the backend cannot answer for it. `unknown` is not a failure to
# report - it is the instruction to hold every session leader back and name how
# many, rather than risk a working agent's shell on a guess.
endpoint_shell_spare() {  # <meta>
  local backend target window pid
  window=$(fm_meta_get "$1" window)
  backend=$(fm_backend_of_meta "$1")
  target=$(fm_backend_target_of_meta "$1")
  pid=$(fm_wtproc_endpoint_shell_pid "$backend" "${target:-$window}" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  printf '%s' "$pid"
}

# The agent's own verdict, from the backend's classifier. Only dead and missing
# mean the copy has no living owner.
agent_verdict() {  # <meta>
  local backend target window
  window=$(fm_meta_get "$1" window)
  [ -n "$window" ] || { printf 'missing'; return 0; }
  backend=$(fm_backend_of_meta "$1")
  target=$(fm_backend_target_of_meta "$1")
  fm_backend_agent_state "$backend" "${target:-$window}" 2>/dev/null || printf 'unknown'
}

# Listening ports held by these pids, as supporting evidence for the report.
# Best-effort and never part of any decision: ss is not everywhere, and a
# process holding no socket is exactly as much of a leftover as one that does.
listening_ports() {  # <pid>...
  local pids=" $* " out
  command -v ss >/dev/null 2>&1 || return 0
  out=$(ss -H -tlnp 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk -v pids="$pids" '
    {
      port = $4
      sub(/.*:/, "", port)
      while (match($0, /pid=[0-9]+/)) {
        p = substr($0, RSTART + 4, RLENGTH - 4)
        if (index(pids, " " p " ") > 0 && !(port in seen)) { seen[port] = 1; list = list (list ? "," : "") port }
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    END { if (list) print list }
  '
}

scan_task() {  # <task-id> <verbose>
  local id=$1 verbose=$2 meta verdict pids ports line spare skipped note
  local -a roots=()
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || {
    [ "$verbose" = 1 ] && echo "no durable record for task $id in $STATE" >&2
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    roots+=("$line")
  done < <(task_roots "$id" "$meta" "$verbose" || true)
  [ "${#roots[@]}" -gt 0 ] || return 1
  # Cheapest question first: an empty copy needs no backend call at all, so a
  # healthy fleet costs one /proc pass per copy and nothing else.
  fm_wtproc_collect "${roots[@]}" || {
    [ "$verbose" = 1 ] && echo "cannot determine the processes in task $id's local copy on this host" >&2
    return 1
  }
  [ -n "$FM_WTPROC_PIDS" ] || return 1
  verdict=$(agent_verdict "$meta")
  case "$verdict" in
    dead|missing) ;;
    *)
      [ "$verbose" = 1 ] && echo "task $id's agent reads '$verdict'; its processes have a living owner and are left alone" >&2
      return 1
      ;;
  esac
  # Two sources have to agree before a copy is called ownerless; see
  # bin/fm-worktree-proc-lib.sh's fm_wtproc_worker_is_gone for the observed
  # misclassification that makes this gate load-bearing.
  if ! fm_wtproc_worker_is_gone "$id" "$verdict"; then
    [ "$verbose" = 1 ] && echo "task $id's endpoint reads '$verdict' but its current state reads '${FM_WTPROC_CREW_STATE:-unreadable}'; the two disagree, so nothing in its local copy is touched" >&2
    return 1
  fi
  # Only now, for a copy that really has no living owner, is it worth asking the
  # backend which shell belongs to the endpoint - and it is asked of the task's
  # own record, so nothing else in the copy inherits that shell's protection.
  spare=$(endpoint_shell_spare "$meta")
  fm_wtproc_select "$spare"
  skipped=$FM_WTPROC_SPARED_LEADERS
  pids=$(printf '%s' "$FM_WTPROC_SELECTED" | tr '\n' ' ')
  pids=${pids% }
  SCAN_ROOTS=("${roots[@]}")
  SCAN_PIDS=$pids
  SCAN_VERDICT=$verdict
  SCAN_SPARE=$spare
  SCAN_SKIPPED_LEADERS=$skipped
  if [ -z "$pids" ]; then
    # Never a silent "(none)": leaders held back because the endpoint's shell
    # could not be named are the one case where an empty set is not evidence of
    # a clean copy, and the report has to say so.
    [ "$skipped" -gt 0 ] || return 1
    printf 'UNRESOLVED: %s agent=%s copy=%s leaders_skipped=%s (the endpoint shell could not be identified from the record, so no session leader in this copy was classified; inspect them by hand)\n' \
      "$id" "$verdict" "${roots[0]}" "$skipped"
    return 0
  fi
  # shellcheck disable=SC2086  # pids is a deliberate space-separated list
  ports=$(listening_ports $pids)
  note=""
  [ "$skipped" -gt 0 ] && note=" leaders_skipped=$skipped"
  printf 'LEFTOVER: %s agent=%s copy=%s pids=%s%s%s\n' \
    "$id" "$verdict" "${roots[0]}" "$(printf '%s' "$pids" | tr ' ' ',')" \
    "${ports:+ listening=$ports}" "$note"
}

cmd_scan() {
  local want="" found=0 meta id
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) shift; want=${1:-}; [ -n "$want" ] || die "--task needs a task id" ;;
      *) die "unknown scan argument '$1'" ;;
    esac
    shift
  done
  if [ -n "$want" ]; then
    scan_task "$want" 1 && found=1
  else
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      scan_task "$id" 0 && found=1
    done
  fi
  [ "$found" = 1 ] || return 0
  echo "Each LEFTOVER line names a local copy whose worker is gone while processes it started are still running."
  echo "An UNRESOLVED line names one where the endpoint's own shell could not be identified from the record, so its session leaders were left unclassified rather than guessed at; inspect those by hand."
  echo "Stop one with: FM_HOME=$FM_HOME $SCRIPT_DIR/fm-orphan-reap.sh reap <task-id>"
}

cmd_reap() {  # <task-id>
  local id=${1:-} rc=0
  [ -n "$id" ] || { usage >&2; exit 2; }
  SCAN_ROOTS=()
  SCAN_PIDS=
  SCAN_VERDICT=
  SCAN_SPARE=unknown
  SCAN_SKIPPED_LEADERS=0
  if ! scan_task "$id" 1 >/dev/null; then
    echo "nothing to stop for $id"
    return 0
  fi
  if [ -z "$SCAN_PIDS" ]; then
    echo "nothing to stop for $id: $SCAN_SKIPPED_LEADERS session leader(s) in its local copy were left alone because its endpoint shell could not be identified from the record; inspect them by hand"
    return 0
  fi
  echo "$id: agent reads '$SCAN_VERDICT'; stopping $(printf '%s' "$SCAN_PIDS" | wc -w) process(es) left in its local copy"
  # Called in this shell rather than a command substitution so the reap's own
  # account of what it signalled and what outlived it survives the call.
  fm_wtproc_reap "$id ownerless" "$SCAN_SPARE" "${SCAN_ROOTS[@]}" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    2) die "the processes in task $id's local copy were signalled but could not be re-checked afterwards; they are in an unknown state - inspect them before retrying" ;;
    3) die "task $id's local copy still holds ${FM_WTPROC_SURVIVORS// /,} after a force-stop; they did not respond to it and are still running" ;;
    *) die "the processes in task $id's local copy could not be accounted for; nothing was signalled, but inspect them before retrying" ;;
  esac
  if [ -n "$FM_WTPROC_REAPED" ]; then
    echo "stopped $id pids=$(printf '%s' "$FM_WTPROC_REAPED" | tr ' ' ',')"
  else
    echo "nothing to stop for $id"
  fi
}

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  reap) shift; cmd_reap "$@" ;;
  *) usage >&2; exit 2 ;;
esac
