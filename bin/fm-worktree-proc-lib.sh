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
# Sparing the endpoint's shell is POSITIVE IDENTIFICATION, never an inference.
# The paths that reuse a terminal endpoint must not close it, and the shell that
# endpoint runs sits in the task copy like any leftover does. That shell is
# resolved from the task's OWN recorded endpoint (the backend's pane pid), so a
# daemon that called setsid inside the copy - the shape that saturated the host
# on 2026-08-27, an API reparented to init - is eligible again. When the record
# cannot yield that pid, nothing is guessed: every session leader is left alone
# AND the count of leaders left alone is reported, because a silently empty
# result reads as "this copy is clean" and would hide exactly the process this
# library exists to find.
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
#   fm_wtproc_endpoint_shell_pid <backend> <target>
#                                       -> the pid of the shell that endpoint
#                                          runs, or 1 when the record cannot
#                                          yield one
#   fm_wtproc_disposable_worktree <dir> -> echoes the resolved path, 0 when the
#                                          path is provably a linked worktree
#                                          and not a primary checkout
#   fm_wtproc_task_tmp <task-id> <dir>  -> echoes the resolved per-task tmp root
#   fm_wtproc_worker_is_gone <task-id> <agent-state>
#   fm_wtproc_collect <dir>...          -> FM_WTPROC_PIDS
#   fm_wtproc_snapshot_begin / _end     -> hold one machine listing across a
#                                          read-only sweep of several copies
#   fm_wtproc_select <spare>            -> FM_WTPROC_SELECTED,
#                                          FM_WTPROC_SPARED_LEADERS,
#                                          FM_WTPROC_SPARED_ENDPOINT
#   fm_wtproc_reap <label> <spare> <dir>...
#
# <spare> is the one thing a caller may hold back, and it is the same argument
# for the report and for the reap so the two can never disagree: a numeric pid
# (the endpoint's shell, positively identified from the record), `unknown` (the
# record could not yield one, so every session leader is held back and counted),
# or `none` (hold nothing back).
#
# Environment knobs:
#   FM_PROC_ROOT_OVERRIDE   proc root (default /proc); a path that is not a
#                           directory, one that does not answer the cwd
#                           question, or one whose cwd listing cannot be
#                           produced at all, selects the lsof fallback
#   FM_WTPROC_GRACE         seconds between TERM and KILL (default 3)
#   FM_WTPROC_KILL_SETTLE   seconds to wait before confirming the KILL (default 1)
#   FM_WTPROC_CREW_STATE_TIMEOUT  bound on the current-state read (default 20)
#   FM_WTPROC_CREW_STATE_BIN      current-state reader (default bin/fm-crew-state.sh)

# shellcheck source=bin/fm-wake-lib.sh
if ! declare -F fm_pid_identity >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
fi

FM_WTPROC_GRACE=${FM_WTPROC_GRACE:-3}
FM_WTPROC_KILL_SETTLE=${FM_WTPROC_KILL_SETTLE:-1}

_fm_wtproc_proc_root() {
  printf '%s' "${FM_PROC_ROOT_OVERRIDE:-/proc}"
}

# _fm_wtproc_proc_answers_cwd: does this proc root actually expose a working
# directory, or does it merely exist?
#
# The existence of the directory proves nothing. A /proc that is not
# Linux-shaped in this one respect - Cygwin/MSYS, a supported platform here
# (bin/fm-wake-lib.sh), where a native Windows process's cwd link does not
# resolve - would make every scan return an empty set with status 0, and every
# caller reads that as "nothing is running there": a teardown would remove a
# worktree with its processes still in it and a scan would report a leaking copy
# as clean forever. That is the same silent degradation this library refuses to
# accept from lsof, so the verdict is gated on a cwd link resolving to the
# directory whose occupant it names.
#
# The caller's own working directory answers that question best, but it is not
# allowed to be the only way of asking it. A process whose working directory has
# been REMOVED under it - the state a torn-down task copy leaves the shell that
# was sitting in it, and the reachable trigger for a fleet scan run from
# bin/fm-session-start.sh - cannot resolve its own cwd at all, and that says
# nothing whatsoever about whether this /proc exposes cwd links. Concluding
# `none` from it would turn a perfectly answerable host into one that reports it
# cannot look. So when the caller cannot be placed, the same question is put
# again from a directory that is known to exist: the proc root itself, entered
# by the probing subshell whose own self link then has to name it back.
_fm_wtproc_proc_answers_cwd() {  # <root>
  local root=$1 link target here probe
  here=$(pwd -P 2>/dev/null) || here=
  if [ -n "$here" ]; then
    for link in "$root/self/cwd" "$root/${BASHPID:-$$}/cwd" "$root/$$/cwd"; do
      [ -L "$link" ] || continue
      target=$(cd "$link" 2>/dev/null && pwd -P) || continue
      [ "$target" = "$here" ] && return 0
    done
  fi
  [ -L "$root/self/cwd" ] || return 1
  probe=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  target=$(cd "$root" 2>/dev/null && cd "$root/self/cwd" 2>/dev/null && pwd -P) || return 1
  [ "$target" = "$probe" ]
}

# _fm_wtproc_proc_lists_cwd_entries: can the scan's OWN mechanism be run here?
#
# A cwd link that resolves proves the kernel exposes the fact; it does not prove
# the listing this library reads that fact through can be produced. `ls`
# unresolvable on PATH would leave the self-test satisfied and every scan
# answering "nothing is running there" with status 0 - the same silent
# degradation the cwd probe exists to refuse, reached one step further along. So
# the verdict is gated on the listing too, taken once here and thrown away
# rather than cached: the resolver is memoised for the life of the shell and a
# listing may never outlive one observation.
_fm_wtproc_proc_lists_cwd_entries() {  # <root>
  local root=$1 listing
  listing=$(_fm_wtproc_listing_run "$root") || return 1
  case "$listing" in
    *"$root"/[0-9]*/cwd*) return 0 ;;
  esac
  return 1
}

# fm_wtproc_resolver: which cwd source this host can answer with. Memoised per
# proc root: the self-test is cheap but the answer is asked once per scanned
# root, and the root only changes under an explicit override.
_FM_WTPROC_RESOLVER=
_FM_WTPROC_RESOLVER_ROOT=
fm_wtproc_resolver() {
  local root
  root=$(_fm_wtproc_proc_root)
  if [ -z "$_FM_WTPROC_RESOLVER" ] || [ "$_FM_WTPROC_RESOLVER_ROOT" != "$root" ]; then
    _FM_WTPROC_RESOLVER_ROOT=$root
    if [ -d "$root" ] && _fm_wtproc_proc_answers_cwd "$root" \
       && _fm_wtproc_proc_lists_cwd_entries "$root"; then
      _FM_WTPROC_RESOLVER=proc
    elif command -v lsof >/dev/null 2>&1; then
      _FM_WTPROC_RESOLVER=lsof
    else
      _FM_WTPROC_RESOLVER=none
    fi
  fi
  printf '%s' "$_FM_WTPROC_RESOLVER"
}

# The one whole-machine listing every root is matched against.
#
# The listing is the expensive part of a /proc scan and it is identical for
# every root, so it is taken once and reused: a task has two roots (its copy and
# its temp root), a reap re-collects up to five times, and a fleet scan runs
# from the session-start digest on a host that was already saturated.
#
# The cache MUST NOT outlive one logical observation, and that is the whole of
# its contract. A reap re-scans precisely to see which of the processes it
# signalled have died since the last pass, and a listing carried across those
# passes would report a survivor that is already gone - or miss one that is not.
# So it is loaded and released inside a single fm_wtproc_collect, and the only
# way to hold one across several is fm_wtproc_snapshot_begin, which
# fm_wtproc_reap drops before it collects anything.
#
# It is loaded in the CALLER's own shell rather than inside the command
# substitution that reads the pids, because an assignment made in a subshell
# would be thrown away with it and every root would pay for its own walk again.
_FM_WTPROC_LISTING=
_FM_WTPROC_LISTING_ROOT=
_FM_WTPROC_LISTING_HELD=0
_FM_WTPROC_LISTING_PASS=0

# Take the listing, and answer whether it could be taken at all.
#
# `ls` exits non-zero as soon as it meets one link it may not read, which is the
# ordinary case on a multi-user host and must never fail a scan - the entry is
# still listed, with no `-> target`, and an unreadable working directory is not
# evidence of anything. So the exit status is deliberately discarded. What may
# NOT be discarded is the listing coming back with nothing at all: the scanning
# process's own entry is always in it (it is filtered out of the results, not
# out of the listing), so an empty listing means the command did not run - `ls`
# unresolvable on PATH, the proc root gone since the resolver answered - and
# that is unanswerable, never a clean machine.
_fm_wtproc_listing_run() {  # <root>
  local out
  out=$(ls -l "$1"/[0-9]*/cwd 2>/dev/null || true)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

_fm_wtproc_listing_load() {  # <root>
  local root=$1 out
  [ -d "$root" ] || return 1
  [ "$_FM_WTPROC_LISTING_ROOT" = "$root" ] && return 0
  out=$(_fm_wtproc_listing_run "$root") || return 1
  _FM_WTPROC_LISTING=$out
  _FM_WTPROC_LISTING_ROOT=$root
}

# Drop the listing unless a collect pass or an explicit snapshot is holding it.
# The default is to drop: a caller that asks the question on its own - the
# multi-pass loop in bin/fm-teardown.sh does - gets a fresh look every time.
_fm_wtproc_listing_release() {
  { [ "$_FM_WTPROC_LISTING_HELD" = 1 ] || [ "$_FM_WTPROC_LISTING_PASS" = 1 ]; } && return 0
  _FM_WTPROC_LISTING=
  _FM_WTPROC_LISTING_ROOT=
  return 0
}

# fm_wtproc_snapshot_begin / fm_wtproc_snapshot_end: hold ONE listing across a
# read-only sweep of several copies, so a fleet-wide report costs one walk of
# the machine rather than one per task. Only a caller that signals nothing may
# open one, and it has to close it: everything inside it is answered from the
# same instant.
fm_wtproc_snapshot_begin() {
  _FM_WTPROC_LISTING=
  _FM_WTPROC_LISTING_ROOT=
  _FM_WTPROC_LISTING_HELD=1
}

fm_wtproc_snapshot_end() {
  _FM_WTPROC_LISTING_HELD=0
  _FM_WTPROC_LISTING=
  _FM_WTPROC_LISTING_ROOT=
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
  _fm_wtproc_listing_load "$root" || return 1
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
  done <<EOF
$_FM_WTPROC_LISTING
EOF
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
  local dir=$1 real rc=0
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  case "$(fm_wtproc_resolver)" in
    proc) _fm_wtproc_pids_under_proc "$real" || rc=$? ;;
    lsof) _fm_wtproc_pids_under_lsof "$real" || rc=$? ;;
    *) rc=1 ;;
  esac
  _fm_wtproc_listing_release
  return "$rc"
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
# is indistinguishable from a leaked server by cwd alone. This is the LAST
# RESORT, used only when the record could not name the endpoint's shell: it is
# not a way of identifying that shell, it is a way of not guessing, and it
# withholds a daemon that called setsid inside the copy along with it. A process
# that cannot be classified is treated as a leader, so an unreadable state
# withholds rather than kills.
fm_wtproc_is_session_leader() {  # <pid>
  local pid=$1 sess
  sess=$(fm_wtproc_session_id "$pid") || return 0
  [ "$sess" = "$pid" ]
}

# fm_wtproc_endpoint_shell_pid: the pid of the shell the task's OWN recorded
# endpoint runs, asked of the backend that owns that endpoint.
#
# This is the whole of "which process must survive a cleanup that reuses the
# endpoint". It is a fact read from the record, not a property inferred from the
# process: a session leader that is not this pid has no claim on being spared,
# and a backend that cannot answer the question gets no answer invented for it -
# it fails, and the caller withholds and says so.
fm_wtproc_endpoint_shell_pid() {  # <backend> <target>
  local backend=$1 target=$2 pid
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  case "$backend" in
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  pid=$(printf '%s' "$pid" | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$pid" || return 1
  printf '%s' "$pid"
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
#
# Every root a caller may signal into passes _fm_wtproc_refuse_sensitive_root
# first, whatever kind of root it is: the shape refusals are what keep a record
# that names the operator's own tree from turning into a kill root, and a second
# root that skipped them would be a hole in the same wall.
_fm_wtproc_refuse_sensitive_root() {  # <real-path> <fm-home> <what>
  local real=$1 home=$2 what=$3 home_real
  case "$real" in
    /) echo "fm-worktree-proc: refusing the filesystem root" >&2; return 1 ;;
    /*/*) ;;
    *) echo "fm-worktree-proc: '$real' is too shallow to be $what" >&2; return 1 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    home_real=$(cd "$HOME" 2>/dev/null && pwd -P) || home_real=$HOME
    if [ "$real" = "$home_real" ] || [ "$(dirname "$real")" = "$home_real" ]; then
      echo "fm-worktree-proc: '$real' sits directly in the home directory, not in a disposable copy" >&2
      return 1
    fi
  fi
  [ -n "$home" ] || return 0
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
}

fm_wtproc_disposable_worktree() {  # <dir> [fm-home]
  local dir=$1 home=${2:-${FM_HOME:-}} real top top_real git_dir common_dir
  [ -n "$dir" ] || { echo "fm-worktree-proc: no local copy recorded" >&2; return 1; }
  [ -d "$dir" ] || { echo "fm-worktree-proc: '$dir' is not a directory" >&2; return 1; }
  real=$(cd "$dir" 2>/dev/null && pwd -P) || {
    echo "fm-worktree-proc: '$dir' cannot be resolved" >&2
    return 1
  }
  _fm_wtproc_refuse_sensitive_root "$real" "$home" "a task's local copy" || return 1
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
# it still resolves to a directory named for this exact task AND clears the same
# shape refusals the worktree root does.
#
# This root cannot prove itself a linked git worktree - it is not a checkout at
# all - so the name and the depth are all its structure gives. That is precisely
# why the home and projects/ refusals have to apply here too: without them a
# record reading `tasktmp=$HOME/projects/fm-x1` would turn every process under
# the operator's own stack into a target, which is the one thing no root is ever
# allowed to do.
fm_wtproc_task_tmp() {  # <task-id> <dir> [fm-home]
  local id=$1 dir=$2 home=${3:-${FM_HOME:-}} real
  [ -n "$id" ] && [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  case "$real" in
    */"fm-$id") ;;
    *) echo "fm-worktree-proc: temp root '$real' is not named for task $id" >&2; return 1 ;;
  esac
  _fm_wtproc_refuse_sensitive_root "$real" "$home" "a task's temp root" || return 1
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
#
# FM_WTPROC_CREW_STATE is set on EVERY path, including the ones that never reach
# the reader, so a caller quoting it can never name the wrong blocker: a live
# endpoint reads `not-consulted`, a missing reader reads `no-reader`, and a read
# that timed out or failed reads `unreadable`. Left carrying a previous call's
# value it would tell an operator that a current-state read vetoed a cleanup the
# endpoint verdict had already vetoed on its own.
FM_WTPROC_CREW_STATE_TIMEOUT=${FM_WTPROC_CREW_STATE_TIMEOUT:-20}
fm_wtproc_worker_is_gone() {  # <task-id> <agent-state>
  local id=$1 verdict=$2 bin out state
  FM_WTPROC_CREW_STATE=not-consulted
  export FM_WTPROC_CREW_STATE
  case "$verdict" in
    dead|missing) ;;
    *) return 1 ;;
  esac
  bin=${FM_WTPROC_CREW_STATE_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-crew-state.sh"}
  [ -x "$bin" ] || { FM_WTPROC_CREW_STATE=no-reader; return 1; }
  out=$(timeout "$FM_WTPROC_CREW_STATE_TIMEOUT" "$bin" "$id" 2>/dev/null) || {
    FM_WTPROC_CREW_STATE=unreadable
    return 1
  }
  state=${out#state: }
  state=${state%% *}
  [ -n "$state" ] || state=unreadable
  # Exposed so a caller can name the state that vetoed it.
  FM_WTPROC_CREW_STATE=$state
  case "$state" in
    done|failed|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# Collect the pids under every root, deduplicated. Sets FM_WTPROC_PIDS and
# FM_WTPROC_FAILED_ROOT; returns 1 when any root could not be scanned safely.
#
# All of a task's roots are matched against ONE listing of the machine, taken
# here and released here: this call is the logical observation, and nothing that
# follows it may be answered from what it saw.
fm_wtproc_collect() {  # <dir>...
  local dir out pids="" rc=0
  FM_WTPROC_PIDS=
  FM_WTPROC_FAILED_ROOT=
  _FM_WTPROC_LISTING_PASS=1
  if [ "$(fm_wtproc_resolver)" = proc ]; then
    _fm_wtproc_listing_load "$(_fm_wtproc_proc_root)" || true
  fi
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! out=$(fm_wtproc_pids_under "$dir"); then
      FM_WTPROC_FAILED_ROOT=$dir
      rc=1
      break
    fi
    pids="$pids
$out"
  done
  [ "$rc" = 0 ] && FM_WTPROC_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
  _FM_WTPROC_LISTING_PASS=0
  _fm_wtproc_listing_release
  return "$rc"
}

_fm_wtproc_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

# fm_wtproc_select: split the collected pids into the ones a caller may act on
# and the ones it holds back, from FM_WTPROC_PIDS into FM_WTPROC_SELECTED.
#
# One implementation for the report and for the reap: `scan` naming a copy as
# leaking and `reap` stopping what is in it have to be talking about the same
# set of processes, and two filters written twice would eventually disagree
# about which. Sets FM_WTPROC_SPARED_ENDPOINT to the endpoint shell it held back
# and FM_WTPROC_SPARED_LEADERS to the number of session leaders it could not
# rule out - a count callers are required to report rather than fold into an
# empty result.
FM_WTPROC_SELECTED=
FM_WTPROC_SPARED_LEADERS=0
FM_WTPROC_SPARED_ENDPOINT=
fm_wtproc_select() {  # <spare>
  local spare=$1 pid out=""
  case "$spare" in
    none|unknown) ;;
    ''|*[!0-9]*) spare=unknown ;;
  esac
  FM_WTPROC_SELECTED=
  FM_WTPROC_SPARED_LEADERS=0
  FM_WTPROC_SPARED_ENDPOINT=
  [ -n "$FM_WTPROC_PIDS" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    case "$spare" in
      none) ;;
      unknown)
        if fm_wtproc_is_session_leader "$pid"; then
          FM_WTPROC_SPARED_LEADERS=$((FM_WTPROC_SPARED_LEADERS + 1))
          continue
        fi
        ;;
      *)
        if [ "$pid" = "$spare" ]; then
          # shellcheck disable=SC2034 # Consumed by sourcing callers.
          FM_WTPROC_SPARED_ENDPOINT=$pid
          continue
        fi
        ;;
    esac
    out="$out$pid
"
  done <<EOF
$FM_WTPROC_PIDS
EOF
  FM_WTPROC_SELECTED=${out%$'\n'}
}

# fm_wtproc_reap: stop everything rooted (by cwd) under <dir>..., TERM first and
# KILL after the grace period. Every signal is guarded twice: the pid must still
# be under one of the roots at signal time, and its birth identity must still
# match the one recorded when it was selected, so a pid recycled between the
# scan and the signal is never touched.
#
# <spare> is passed straight to fm_wtproc_select: the endpoint shell's pid when
# the caller reuses that endpoint and the record could name it, `unknown` when
# it could not, `none` when nothing is held back.
#
# Prints one human-readable line per action on stderr and the reaped pids on
# stdout, and sets FM_WTPROC_REAPED and FM_WTPROC_SURVIVORS for callers that
# need more than the exit status. The status distinguishes the four outcomes,
# because "cannot be determined" said before any signal and said after one are
# different facts about the machine and an operator acts on them differently:
#
#   0  nothing selected, or everything selected is gone
#   1  the scan failed BEFORE anything was signalled - nothing was signalled
#   2  signals were delivered and the outcome could not be established
#   3  signals were delivered and something survived them (FM_WTPROC_SURVIVORS)
FM_WTPROC_REAPED=
FM_WTPROC_SURVIVORS=
fm_wtproc_reap() {  # <label> <spare> <dir>...
  local label=$1 spare=$2 pid identity i reaped=""
  local -a sel_pids sel_ids left_pids left_ids survivors
  shift 2
  FM_WTPROC_REAPED=
  FM_WTPROC_SURVIVORS=
  # The selection globals are reset here as well as inside fm_wtproc_select,
  # because the paths below return before the selector ever runs - a scan that
  # failed, a copy with nothing in it - and a caller quoting them afterwards
  # must never be handed a previous copy's held-back shell or leader count.
  FM_WTPROC_SELECTED=
  FM_WTPROC_SPARED_LEADERS=0
  # shellcheck disable=SC2034 # Consumed by sourcing callers.
  FM_WTPROC_SPARED_ENDPOINT=
  # A reap observes the machine again between every pass, so it never reads a
  # listing some outer report is holding: whatever a caller snapshotted, this
  # drops it.
  fm_wtproc_snapshot_end
  if ! fm_wtproc_collect "$@"; then
    echo "fm-worktree-proc: cannot determine the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} on this host (no readable /proc and no lsof); nothing was signalled" >&2
    return 1
  fi
  [ -n "$FM_WTPROC_PIDS" ] || return 0
  fm_wtproc_select "$spare"
  if [ "$FM_WTPROC_SPARED_LEADERS" -gt 0 ]; then
    echo "fm-worktree-proc: $FM_WTPROC_SPARED_LEADERS session leader(s) in ${*} were left alone because the endpoint's own shell could not be identified from the task record; inspect them by hand rather than assuming the copy is clean" >&2
  fi
  sel_pids=()
  sel_ids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    identity=$(fm_pid_identity "$pid") || continue
    sel_pids+=("$pid")
    sel_ids+=("$identity")
  done <<EOF
$FM_WTPROC_SELECTED
EOF
  [ "${#sel_pids[@]}" -gt 0 ] || return 0
  echo "fm-worktree-proc: stopping $label process(es) left in ${*}: ${sel_pids[*]}" >&2
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} stopped being listable between selecting them and signalling them; nothing was signalled" >&2
    return 1
  }
  for i in "${!sel_pids[@]}"; do
    pid=${sel_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${sel_ids[$i]}" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      reaped="$reaped $pid"
    fi
  done
  FM_WTPROC_REAPED=${reaped# }
  # Past this point something HAS been signalled, so a scan that cannot answer
  # any more leaves those processes in an unknown state rather than an untouched
  # one; 2, never 1.
  [ -n "$FM_WTPROC_REAPED" ] || return 0
  sleep "$FM_WTPROC_GRACE"
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} could not be re-checked after they were signalled; ${FM_WTPROC_REAPED} were sent TERM and their fate is unknown" >&2
    return 2
  }
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
  if [ "${#left_pids[@]}" -eq 0 ]; then
    printf '%s\n' "$FM_WTPROC_REAPED"
    return 0
  fi
  echo "fm-worktree-proc: force-stopping $label process(es): ${left_pids[*]}" >&2
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} could not be re-checked before the force-stop; ${left_pids[*]} survived TERM and their fate is unknown" >&2
    return 2
  }
  for i in "${!left_pids[@]}"; do
    pid=${left_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${left_ids[$i]}" ]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  # A KILL is not a receipt. A process wedged in an uninterruptible wait - the
  # socket-heavy shape of the 2026-08-27 incident - stays on the process table
  # after it, and reporting "stopped" for one of those tells an operator a leak
  # is cleaned when it is still burning the host. Re-collect and say so.
  sleep "$FM_WTPROC_KILL_SETTLE"
  fm_wtproc_collect "$@" || {
    echo "fm-worktree-proc: the $label processes under ${FM_WTPROC_FAILED_ROOT:-<missing>} could not be re-checked after the force-stop; ${left_pids[*]} were sent KILL and their fate is unknown" >&2
    return 2
  }
  survivors=()
  for i in "${!left_pids[@]}"; do
    pid=${left_pids[$i]}
    if _fm_wtproc_contains "$FM_WTPROC_PIDS" "$pid" \
       && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${left_ids[$i]}" ]; then
      survivors+=("$pid")
    fi
  done
  printf '%s\n' "$FM_WTPROC_REAPED"
  [ "${#survivors[@]}" -eq 0 ] || {
    # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/fm-control.sh, bin/fm-orphan-reap.sh).
    FM_WTPROC_SURVIVORS="${survivors[*]}"
    echo "fm-worktree-proc: $label process(es) still running after being force-stopped: ${survivors[*]}" >&2
    return 3
  }
  return 0
}
