#!/usr/bin/env bash
# fm-worktree-proc-lib.sh - the single owner of "which running processes belong
# to a task's disposable local copy", and of stopping them without ever reaching
# outside it.
#
# Why this exists. A crewmate that starts a long-running process in its task
# worktree - a dev server, a watcher, a queue worker - leaves that process
# running when the AGENT itself dies without a teardown: quota exhausted, harness
# crash, session closed. The worktree keeps its slot and the process keeps its
# sockets, CPU, and file descriptors for as long as the machine is up. Observed
# 2026-08-27: one such server outlived its agent by eight and a half hours and
# drove the host to 97% CPU (90.6% system time) through accumulated proxied
# connections; 41 processes of the same shape had been reaped by hand the day
# before.
#
# ATTRIBUTION IS BY WORKING DIRECTORY, NEVER BY NAME. The only question this
# library answers is "is this process's real current working directory inside
# that exact disposable copy". A command-name match (pkill -f node and friends)
# would reach into other firstmate homes and into the operator's own stack, so
# no function here ever looks at a command line to decide whether to signal.
#
# Resolution order, and why /proc comes first. `lsof` is not installed
# everywhere - it is absent on the host the incident above was observed on - and
# a cwd scan that depends on it degrades silently exactly where the reap matters
# most. On any host exposing a Linux-compatible /proc, the cwd is read from
# /proc/<pid>/cwd, which is a kernel fact rather than a tool's output. lsof stays
# as the fallback for a host with no /proc (macOS), and a host with neither
# reports that it cannot establish a safe result rather than guessing.
#
# An unreadable /proc/<pid>/cwd (another user's process, a race with exit) is
# NOT evidence of anything: such a process is skipped and left alone. Nothing
# here ever signals a pid it could not positively place inside the copy.
#
# Ownership boundary. This library owns RESOLUTION (which pids, under which
# roots, with which guards) for every caller. It also owns the report-and-
# continue reap used by the paths that are not destroying anything.
# bin/fm-teardown.sh keeps its own multi-pass refuse-before-removal loop,
# because there the reap gates an irreversible worktree removal and an
# unresolved process must block it; that loop calls this library's resolver so
# there is still exactly one definition of "processes of this copy".
#
# Public surface:
#   fm_wtproc_resolver                  -> proc | lsof | none
#   fm_wtproc_pids_under <dir>          -> pids, one per line (0 = safe result)
#   fm_wtproc_session_id <pid>          -> session id
#   fm_wtproc_is_session_leader <pid>   -> 0 when sid == pid
#   fm_wtproc_disposable_worktree <dir> -> echoes the resolved path, 0 when the
#                                          path is provably a linked worktree
#                                          and not a primary checkout
#   fm_wtproc_task_tmp <task-id> <dir>  -> echoes the resolved per-task tmp root
#   fm_wtproc_worker_is_gone <task-id> <agent-state>
#   fm_wtproc_reap <label> <keep-endpoint-shell> <dir>...
#
# Environment knobs:
#   FM_PROC_ROOT_OVERRIDE   proc root (default /proc); a path that is not a
#                           directory selects the lsof fallback
#   FM_WTPROC_GRACE         seconds between TERM and KILL (default 3)
#   FM_WTPROC_CREW_STATE_TIMEOUT  bound on the current-state read (default 20)
#   FM_WTPROC_CREW_STATE_BIN      current-state reader (default bin/fm-crew-state.sh)

# shellcheck source=bin/fm-wake-lib.sh
if ! declare -F fm_pid_identity >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
fi

FM_WTPROC_GRACE=${FM_WTPROC_GRACE:-3}

_fm_wtproc_proc_root() {
  printf '%s' "${FM_PROC_ROOT_OVERRIDE:-/proc}"
}

# fm_wtproc_resolver: which cwd source this host can answer with.
fm_wtproc_resolver() {
  if [ -d "$(_fm_wtproc_proc_root)" ]; then
    printf 'proc'
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    printf 'lsof'
    return 0
  fi
  printf 'none'
  return 0
}

# Every pid whose /proc cwd link resolves to <dir> or below it.
#
# One `ls -l` over the whole proc root rather than a readlink per pid: the scan
# runs on the session-start path, and a fork per process would cost seconds on a
# busy host where the single listing costs milliseconds. A link the caller may
# not read is listed with no `-> target` at all, which is exactly the required
# behaviour - an unreadable working directory is not evidence of anything, so
# that process is skipped and left alone. Never this shell.
_fm_wtproc_pids_under_proc() {  # <real-dir>
  local dir=$1 root line entry link pid self
  root=$(_fm_wtproc_proc_root)
  [ -d "$root" ] || return 1
  self=${BASHPID:-$$}
  while IFS= read -r line; do
    case "$line" in *' -> '*) ;; *) continue ;; esac
    entry=${line%%' -> '*}
    link=${line#*' -> '}
    # The listing prefixes each path with ls's own columns; take the path from
    # the proc root onwards so a root containing a space is still parsed right.
    case "$entry" in
      *"$root"/*/cwd) pid=${entry##*"$root"/} ;;
      *) continue ;;
    esac
    pid=${pid%/cwd}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$self" ] && continue
    [ "$pid" = "$$" ] && continue
    case "$link" in
      "$dir"|"$dir"/*) printf '%s\n' "$pid" ;;
    esac
  done < <(ls -l "$root"/[0-9]*/cwd 2>/dev/null || true)
}

# The same question answered from one bounded system-wide `lsof -a -d cwd` scan
# (never the recursive +D file-tree walk, which lsof itself documents as slow).
# A malformed field stream returns failure rather than a partial answer.
_fm_wtproc_pids_under_lsof() {  # <real-dir>
  local dir=$1 out pid path line self
  self=${BASHPID:-$$}
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ "$pid" != "$self" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# fm_wtproc_pids_under: pids whose real cwd is <dir> or below. An empty result
# with status 0 means "nothing is running there"; a non-zero status means the
# question could not be answered safely and the caller must not assume either.
fm_wtproc_pids_under() {  # <dir>
  local dir=$1 real
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  case "$(fm_wtproc_resolver)" in
    proc) _fm_wtproc_pids_under_proc "$real" ;;
    lsof) _fm_wtproc_pids_under_lsof "$real" ;;
    *) return 1 ;;
  esac
}

# fm_wtproc_session_id: the process's session id, from /proc stat field 6 where
# a compatible /proc exists and from ps otherwise.
fm_wtproc_session_id() {  # <pid>
  local pid=$1 root stat_line sess
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  root=$(_fm_wtproc_proc_root)
  if [ -r "$root/$pid/stat" ]; then
    stat_line=$(cat "$root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 3 is proc stat field 6.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 4 ] || return 1
    sess=${stat_fields[3]}
  else
    sess=$(ps -o sess= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  fi
  case "$sess" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$sess"
}

# fm_wtproc_is_session_leader: a terminal endpoint's shell is the session leader
# of the pty the backend opened for it, and its cwd is the task worktree - so it
# is indistinguishable from a leaked server by cwd alone. Callers that must keep
# the endpoint alive (a relaunch reuses it) protect every session leader. A
# process that cannot be classified is treated as a leader, so an unreadable
# state protects rather than kills.
fm_wtproc_is_session_leader() {  # <pid>
  local pid=$1 sess
  sess=$(fm_wtproc_session_id "$pid") || return 0
  [ "$sess" = "$pid" ]
}

# fm_wtproc_disposable_worktree: prove <dir> is a task's disposable local copy
# before anything running in it may be signalled, and echo its resolved path.
#
# The structural test is that the path is the ROOT of a LINKED git worktree:
# `git rev-parse --git-dir` differs from `--git-common-dir` only for a worktree
# added beside a checkout, never for the checkout itself. That single fact
# excludes every primary checkout on the machine - the operator's own clones and
# this home's projects/ clones alike - without depending on where they happen to
# live. The remaining guards refuse the paths whose shape alone makes them
# implausible as a task copy.
fm_wtproc_disposable_worktree() {  # <dir> [fm-home]
  local dir=$1 home=${2:-${FM_HOME:-}} real top top_real git_dir common_dir home_real
  [ -n "$dir" ] || { echo "fm-worktree-proc: no local copy recorded" >&2; return 1; }
  [ -d "$dir" ] || { echo "fm-worktree-proc: '$dir' is not a directory" >&2; return 1; }
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    echo "fm-worktree-proc: '$dir' cannot be resolved" >&2
    return 1
  }
  case "$real" in
    /) echo "fm-worktree-proc: refusing the filesystem root" >&2; return 1 ;;
    /*/*) ;;
    *) echo "fm-worktree-proc: '$real' is too shallow to be a task's local copy" >&2; return 1 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    home_real=$(cd "$HOME" 2>/dev/null && pwd -P) || home_real=$HOME
    if [ "$real" = "$home_real" ] || [ "$(dirname "$real")" = "$home_real" ]; then
      echo "fm-worktree-proc: '$real' sits directly in the home directory, not in a disposable copy" >&2
      return 1
    fi
  fi
  if [ -n "$home" ]; then
    home_real=$(cd "$home" 2>/dev/null && pwd -P) || home_real=$home
    if [ "$real" = "$home_real" ]; then
      echo "fm-worktree-proc: '$real' is the firstmate home itself" >&2
      return 1
    fi
    case "$real" in
      "$home_real"/projects|"$home_real"/projects/*)
        echo "fm-worktree-proc: '$real' is a primary clone, not a disposable copy" >&2
        return 1
        ;;
    esac
  fi
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || {
    echo "fm-worktree-proc: '$real' is not a git worktree" >&2
    return 1
  }
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || top_real=
  [ "$top_real" = "$real" ] || {
    echo "fm-worktree-proc: '$real' is not a worktree root (root is ${top:-unknown})" >&2
    return 1
  }
  git_dir=$(git -C "$real" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=
  common_dir=$(cd "$real" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || {
    echo "fm-worktree-proc: '$real' git layout cannot be inspected" >&2
    return 1
  }
  [ "$git_dir" != "$common_dir" ] || {
    echo "fm-worktree-proc: '$real' is a primary checkout, not a linked worktree" >&2
    return 1
  }
  printf '%s' "$real"
}

# fm_wtproc_task_tmp: the per-task temp root fm-spawn records, accepted only when
# it still resolves to a directory named for this exact task.
fm_wtproc_task_tmp() {  # <task-id> <dir>
  local id=$1 dir=$2 real
  [ -n "$id" ] && [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  case "$real" in
    */"fm-$id") ;;
    *) echo "fm-worktree-proc: temp root '$real' is not named for task $id" >&2; return 1 ;;
  esac
  case "$real" in
    /*/*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$real"
}

# fm_wtproc_worker_is_gone: 0 only when TWO independent sources agree that a
# task's worker is gone, so no single classifier can license a cleanup on its
# own.
#
# This gate is not defensive decoration. Observed 2026-08-27 on the captain's
# host: the Herdr backend's agent-state classifier reported `dead` for a worker
# that was running at that moment, while bin/fm-crew-state.sh - reading the
# harness busy signal rather than the rendered pane - correctly reported it
# working. A cleanup that had trusted the first source alone would have stopped
# a live worker's processes, which is the one outcome worse than the leak this
# whole mechanism exists to stop.
#
# <agent-state> is the backend classifier's verdict, read by the caller. Only
# `dead` and `missing` pass it. Current state then has to agree: `working`,
# `parked`, `blocked`, and `paused` all mean something is still going on and
# veto the verdict, as does a read that times out or cannot be taken at all.
# `done`, `failed`, and `unknown` - the last being what a torn-off worker with no
# attributed run reads as - let it stand.
FM_WTPROC_CREW_STATE_TIMEOUT=${FM_WTPROC_CREW_STATE_TIMEOUT:-20}
fm_wtproc_worker_is_gone() {  # <task-id> <agent-state>
  local id=$1 verdict=$2 bin out state
  case "$verdict" in
    dead|missing) ;;
    *) return 1 ;;
  esac
  bin=${FM_WTPROC_CREW_STATE_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-crew-state.sh"}
  [ -x "$bin" ] || return 1
  out=$(timeout "$FM_WTPROC_CREW_STATE_TIMEOUT" "$bin" "$id" 2>/dev/null) || return 1
  state=${out#state: }
  state=${state%% *}
  # Exposed so a caller can name the state that vetoed it.
  FM_WTPROC_CREW_STATE=$state
  export FM_WTPROC_CREW_STATE
  case "$state" in
    done|failed|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# Collect the pids under every root, deduplicated. Sets FM_WTPROC_PIDS and
# FM_WTPROC_FAILED_ROOT; returns 1 when any root could not be scanned safely.
fm_wtproc_collect() {  # <dir>...
  local dir out pids=""
  FM_WTPROC_PIDS=
  FM_WTPROC_FAILED_ROOT=
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! out=$(fm_wtproc_pids_under "$dir"); then
      FM_WTPROC_FAILED_ROOT=$dir
      return 1
    fi
    pids="$pids
$out"
  done
  FM_WTPROC_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}

_fm_wtproc_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

# fm_wtproc_reap: stop everything rooted (by cwd) under <dir>..., TERM first and
# KILL after the grace period. Every signal is guarded twice: the pid must still
# be under one of the roots at signal time, and its birth identity must still
# match the one recorded when it was selected, so a pid recycled between the
# scan and the signal is never touched.
#
# <keep-endpoint-shell> 1 protects session leaders (see
# fm_wtproc_is_session_leader): the paths that reuse a terminal endpoint must not
# close it. 0 reaps them too.
#
# Prints one human-readable line per action on stderr and the reaped pids on
# stdout. Returns 0 when nothing is left running, 1 when the scan could not be
# answered or something survived - the caller decides what that means.
fm_wtproc_reap() {  # <label> <keep-endpoint-shell> <dir>...
  local label=$1 keep=$2 pid identity i reaped=""
  local -a sel_pids sel_ids left_pids left_ids
  shift 2
  if ! fm_wtproc_collect "$@"; then
    echo "fm-worktree-proc: cannot determine the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} on this host (no readable /proc and no lsof); nothing was signalled" >&2
    return 1
  fi
  [ -n "$FM_WTPROC_PIDS" ] || return 0
  sel_pids=()
  sel_ids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ "$keep" = 1 ] && fm_wtproc_is_session_leader "$pid"; then
      continue
    fi
    identity=$(fm_pid_identity "$pid") || continue
    sel_pids+=("$pid")
    sel_ids+=("$identity")
  done <<EOF
$FM_WTPROC_PIDS
EOF
  [ "${#sel_pids[@]}" -gt 0 ] || return 0
  echo "fm-worktree-proc: stopping $label process(es) left in ${*}: ${sel_pids[*]}" >&2
  fm_wtproc_collect "$@" || return 1
  for i in "${!sel_pids[@]}"; do
    pid=${sel_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${sel_ids[$i]}" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      reaped="$reaped $pid"
    fi
  done
  sleep "$FM_WTPROC_GRACE"
  fm_wtproc_collect "$@" || return 1
  left_pids=()
  left_ids=()
  for i in "${!sel_pids[@]}"; do
    pid=${sel_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${sel_ids[$i]}" ]; then
      left_pids+=("$pid")
      left_ids+=("${sel_ids[$i]}")
    fi
  done
  if [ "${#left_pids[@]}" -gt 0 ]; then
    echo "fm-worktree-proc: force-stopping $label process(es): ${left_pids[*]}" >&2
    fm_wtproc_collect "$@" || return 1
    for i in "${!left_pids[@]}"; do
      pid=${left_pids[$i]}
      if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
         && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${left_ids[$i]}" ]; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
  fi
  printf '%s\n' "${reaped# }"
  return 0
}
