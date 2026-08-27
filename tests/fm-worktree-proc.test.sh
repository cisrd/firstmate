#!/usr/bin/env bash
# Processes left running in a task's local copy: attribution, the guards that
# keep every other process on the machine out of reach, and the paths that stop
# them.
#
# The whole mechanism rests on one claim - "this process's real working
# directory is inside that exact disposable copy" - so these tests use real
# processes and real git worktrees rather than a stubbed resolver. What they
# pin:
#   1. Only a linked git worktree that is not a primary checkout, and not a
#      clone under the home's projects/, can ever be a target root.
#   2. A process in such a copy is found by working directory and stopped.
#   3. A process in a primary checkout is never a target, even when a durable
#      record names that checkout as the task's copy - the negative case that
#      matters most, because the operator's own stack lives in checkouts.
#   4. A task whose agent is alive is never touched, and neither is one whose
#      endpoint classifier says dead while its current state says otherwise.
#   5. A working directory that cannot be read leaves its process alone; an
#      unreadable state is never a default kill.
#   6. The shell the task's OWN record names as its endpoint survives a cleanup
#      that means to keep that endpoint - and a session-leader daemon that is
#      NOT that shell does not, because the process that saturated the host on
#      2026-08-27 was exactly that shape.
#   7. When the record cannot name that shell nothing is guessed: every session
#      leader is left alone AND the report says how many, so a copy that was
#      never classified is never mistaken for a clean one.
#   8. A per-task temp root gets the same home and projects/ refusals the
#      worktree root gets, so a record naming the operator's own tree as a
#      second reap root reaches nothing.
#   9. The reap tells the truth about its own outcome: a scan that broke BEFORE
#      anything was signalled, a scan that broke AFTER, and a process that
#      outlived the force-stop are three different answers, never one "done".
#
# Every negative case is asserted beside a positive one in the same fixture, so
# a guard that started refusing everything would fail this suite rather than
# pass it quietly. Witnesses are `sleep` processes: the incident this guards
# came out of a saturated host, and nothing here needs a server to prove
# attribution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORPHAN="$ROOT/bin/fm-orphan-reap.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-proc)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

PRIMARY="$TMP_ROOT/primary"
COPY="$TMP_ROOT/copy"
HOME_DIR="$TMP_ROOT/home"
IN_PROJECTS="$HOME_DIR/projects/clone"
PLAIN="$TMP_ROOT/plain"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/projects" "$PLAIN"
fm_git_worktree "$PRIMARY" "$COPY" task-branch
# A linked worktree that nonetheless sits under the home's projects/ tree, so
# the projects guard is proven to stand on its own rather than riding on the
# linked-worktree test.
git -C "$PRIMARY" worktree add --quiet -b in-projects "$IN_PROJECTS"

FM_HOME="$HOME_DIR"
FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_HOME FM_STATE_OVERRIDE
FM_WTPROC_GRACE=1
export FM_WTPROC_GRACE

# shellcheck source=bin/fm-worktree-proc-lib.sh
. "$ROOT/bin/fm-worktree-proc-lib.sh"

# Witnesses are started inside command substitutions, so the parent shell never
# sees an array append; the registry is a file for the same reason
# tests/lib.sh keeps its temp roots in one.
WITNESS_REGISTRY="$TMP_ROOT/.witnesses"
: > "$WITNESS_REGISTRY"
witness_cleanup() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
  done < "$WITNESS_REGISTRY"
  fm_test_cleanup
}
trap witness_cleanup EXIT
trap 'witness_cleanup; exit 130' INT
trap 'witness_cleanup; exit 143' TERM

witness() {  # <cwd> -> pid
  local dir=$1 pid
  ( cd "$dir" && exec /bin/sleep 600 ) </dev/null >/dev/null 2>&1 &
  pid=$!
  disown
  printf '%s\n' "$pid" >> "$WITNESS_REGISTRY"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "witness in $dir did not start"
  printf '%s' "$pid"
}

# The shape a terminal endpoint's shell takes: its own session leader.
session_leader_witness() {  # <cwd> -> pid
  local dir=$1 pid pidfile
  pidfile="$TMP_ROOT/leader.$RANDOM.pid"
  # setsid forks, so the leader is not the pid this shell would see; the child
  # reports its own.
  # shellcheck disable=SC2016  # $$ must expand in the child, not here
  ( cd "$dir" && exec setsid /bin/sh -c 'echo $$ > "$1"; exec /bin/sleep 600' _ "$pidfile" ) \
    </dev/null >/dev/null 2>&1 &
  disown
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$pidfile" ] && break
    sleep 0.1
  done
  pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$pid" ] || fail "session-leader witness did not start"
  printf '%s\n' "$pid" >> "$WITNESS_REGISTRY"
  sleep 0.2
  printf '%s' "$pid"
}

alive() { kill -0 "$1" 2>/dev/null; }

contains_pid() {  # <list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

write_task_meta() {  # <id> <worktree> <window> [tasktmp]
  {
    echo "window=${3}"
    echo "endpoint_task_id=$1"
    echo "worktree=$2"
    echo "backend=tmux"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    [ -n "${4:-}" ] && echo "tasktmp=$4"
  } > "$HOME_DIR/state/$1.meta"
}

# tmux/ps stubs modelling one endpoint whose agent state is whatever
# $FAKE_AGENT_STATE says. `missing` is a session tmux cannot find; `dead` is a
# listed window whose foreground group is nothing but a shell; `alive` is the
# same window running the harness.
make_backend_stub() {  # <dir> <window-name>
  local fb="$1/fakebin" win=$2
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
state=\$(cat "\$FAKE_AGENT_FILE" 2>/dev/null || echo missing)
case "\${1:-}" in
  list-windows)
    if [ "\$state" = missing ]; then
      echo "can't find session: fmses" >&2
      exit 1
    fi
    printf '%s\n' '$win'
    exit 0
    ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_tty*) printf '/dev/pts/424242\n'; exit 0 ;;
        *pane_pid*)
          # The endpoint's shell as the RECORD would name it: whatever the
          # fixture put in this file, or nothing when the backend cannot say.
          cat "\$FAKE_PANE_PID_FILE" 2>/dev/null || printf 'fakepane'
          printf '\n'
          exit 0 ;;
        *pane_current_command*)
          if [ "\$state" = alive ]; then printf 'claude\n'; else printf 'bash\n'; fi
          exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
state=$(cat "$FAKE_AGENT_FILE" 2>/dev/null || echo missing)
if [ "${1:-}" = -t ] && [ "${2:-}" = pts/424242 ]; then
  if [ "$state" = alive ]; then printf '424242 424242 424242 claude\n'
  else printf '424242 424242 424242 bash\n'; fi
  exit 0
fi
exec "$FAKE_REAL_PS" "$@"
SH
  chmod +x "$fb/ps"
}

# A current-state reader whose verdict comes from a file, standing in for
# bin/fm-crew-state.sh so the disagreement case can be reproduced deterministically.
make_crew_state_stub() {  # <dir>
  cat > "$1/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: pane · stub
' "$(cat "$FAKE_CREW_STATE_FILE" 2>/dev/null || echo unknown)"
SH
  chmod +x "$1/crew-state"
  printf 'unknown' > "$1/crew"
}

run_orphan() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_WTPROC_GRACE=1 \
      FAKE_AGENT_FILE="$dir/agent" FAKE_REAL_PS="$(command -v ps)" \
      FAKE_CREW_STATE_FILE="$dir/crew" FAKE_PANE_PID_FILE="$dir/panepid" \
      FM_WTPROC_CREW_STATE_BIN="$dir/crew-state" \
      "$ORPHAN" "$@" 2>&1
}

# --- 1. what may ever be a target root --------------------------------------

test_only_a_linked_worktree_is_a_disposable_copy() {
  local out rc

  out=$(fm_wtproc_disposable_worktree "$COPY" "$HOME_DIR" 2>&1) \
    || fail "disposable-copy: the task's linked worktree was refused: $out"
  [ "$out" = "$COPY" ] || fail "disposable-copy: expected $COPY, got $out"

  rc=0
  out=$(fm_wtproc_disposable_worktree "$PRIMARY" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: a primary checkout was accepted as a disposable copy"
  case "$out" in
    *"is a primary checkout"*) ;;
    *) fail "disposable-copy: the primary checkout refusal did not name its cause: $out" ;;
  esac

  rc=0
  out=$(fm_wtproc_disposable_worktree "$IN_PROJECTS" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: a clone under the home's projects/ was accepted"
  case "$out" in
    *"is a primary clone"*) ;;
    *) fail "disposable-copy: the projects/ refusal did not name its cause: $out" ;;
  esac

  rc=0
  out=$(fm_wtproc_disposable_worktree "$PLAIN" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: a directory that is not a git worktree was accepted"

  rc=0
  out=$(fm_wtproc_disposable_worktree "$HOME" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "disposable-copy: the home directory itself was accepted"

  pass "only a linked worktree outside the home's own clones is accepted as a disposable copy"
}

# --- 2. attribution and the reap -------------------------------------------

test_a_process_in_a_disposable_copy_is_found_and_stopped() {
  local inside outside pids
  inside=$(witness "$COPY")
  outside=$(witness "$PRIMARY")

  pids=$(fm_wtproc_pids_under "$COPY") || fail "reap: the copy could not be scanned"
  contains_pid "$pids" "$inside" \
    || fail "reap: the process in the copy was not attributed to it"
  contains_pid "$pids" "$outside" \
    && fail "reap: a process outside the copy was attributed to it"

  fm_wtproc_reap "test" none "$COPY" >/dev/null 2>&1 \
    || fail "reap: the cleanup could not be completed"
  sleep 0.3
  alive "$inside" && fail "reap: the process in the copy survived"
  alive "$outside" || fail "reap: a process outside the copy was stopped"
  kill -KILL "$outside" 2>/dev/null || true
  pass "a process is attributed to a copy by working directory and stopped there, and only there"
}

# --- 3. a primary checkout is never reachable, even when a record names it ---

test_a_primary_checkout_is_never_a_target() {
  local dir stack_pid copy_pid out
  dir="$TMP_ROOT/case-primary"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-stack
  make_crew_state_stub "$dir"
  printf 'missing' > "$dir/agent"

  # The operator's own stack: a live process in a checkout they work in
  # directly, recorded - wrongly - as a task's local copy, with that task's
  # agent gone. Nothing about this may reach the process.
  stack_pid=$(witness "$PRIMARY")
  write_task_meta stack "$PRIMARY" "fmses:fm-stack"
  # A real disposable copy in the same home and the same state, so the scan is
  # proven to be working rather than silently finding nothing at all.
  copy_pid=$(witness "$COPY")
  write_task_meta copyt "$COPY" "fmses:fm-stack"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: copyt"*) ;;
    *) fail "primary-checkout: the disposable copy was not reported, so this case proves nothing: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: stack"*) fail "primary-checkout: a checkout was reported as a task copy: $out" ;;
  esac

  out=$(run_orphan "$dir" reap stack)
  case "$out" in
    *"nothing to stop"*) ;;
    *) fail "primary-checkout: an explicit cleanup did not refuse the checkout: $out" ;;
  esac
  sleep 0.3
  alive "$stack_pid" || fail "primary-checkout: a process in a checkout was stopped"

  run_orphan "$dir" reap copyt >/dev/null
  sleep 0.3
  alive "$copy_pid" && fail "primary-checkout: the disposable copy's process was not stopped"
  alive "$stack_pid" || fail "primary-checkout: the checkout's process was stopped by the copy's cleanup"

  kill -KILL "$stack_pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/stack.meta" "$HOME_DIR/state/copyt.meta"
  pass "a primary checkout is never a target, even when a durable record names it as the task's copy"
}

# --- 4. a live worker is never touched --------------------------------------

test_a_live_workers_processes_are_never_stopped() {
  local dir pid out
  dir="$TMP_ROOT/case-live"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-live
  make_crew_state_stub "$dir"
  printf 'alive' > "$dir/agent"

  pid=$(witness "$COPY")
  write_task_meta live "$COPY" "fmses:fm-live"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: live"*) fail "live-worker: a live worker's copy was reported as leftover: $out" ;;
  esac
  out=$(run_orphan "$dir" reap live)
  case "$out" in
    *"nothing to stop"*) ;;
    *) fail "live-worker: an explicit cleanup did not refuse a live worker: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "live-worker: a live worker's process was stopped"

  # Same fixture, same process, only the agent's verdict changes: the case is
  # proven to hinge on liveness and nothing else.
  printf 'dead' > "$dir/agent"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: live"*) ;;
    *) fail "live-worker: the same copy was not reported once its agent read dead: $out" ;;
  esac
  run_orphan "$dir" reap live >/dev/null
  sleep 0.3
  alive "$pid" && fail "live-worker: the copy's process survived once its agent was gone"

  rm -f "$HOME_DIR/state/live.meta"
  pass "a task whose agent is alive is never touched, and the same copy is cleaned once that agent is gone"
}

# --- 4b. two sources have to agree ------------------------------------------
#
# Observed 2026-08-27 on the captain's host: the Herdr endpoint classifier
# reported `dead` for a worker that was running, while the current-state reader
# correctly reported it working. Acting on the first source alone would have
# stopped a live worker's processes.

test_a_disagreeing_current_state_vetoes_the_verdict() {
  local dir pid out
  dir="$TMP_ROOT/case-disagree"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-dis
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'working' > "$dir/crew"

  pid=$(witness "$COPY")
  write_task_meta dis "$COPY" "fmses:fm-dis"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: dis"*) fail "two-sources: a copy was called ownerless while its current state read working: $out" ;;
  esac
  out=$(run_orphan "$dir" scan --task dis)
  case "$out" in
    *"the two disagree"*) ;;
    *) fail "two-sources: the refusal did not name the disagreement: $out" ;;
  esac
  out=$(run_orphan "$dir" reap dis)
  case "$out" in
    *"nothing to stop"*) ;;
    *) fail "two-sources: an explicit cleanup did not refuse the disagreement: $out" ;;
  esac
  sleep 0.3
  alive "$pid" || fail "two-sources: a running worker's process was stopped on one source alone"

  # Only the second source changes: the case is proven to hinge on the
  # agreement and not on anything else in the fixture.
  printf 'unknown' > "$dir/crew"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: dis"*) ;;
    *) fail "two-sources: the same copy was not reported once both sources agreed: $out" ;;
  esac
  run_orphan "$dir" reap dis >/dev/null
  sleep 0.3
  alive "$pid" && fail "two-sources: the copy's process survived once both sources agreed"

  rm -f "$HOME_DIR/state/dis.meta"
  pass "a current state that disagrees with the endpoint classifier vetoes the ownerless verdict"
}

# --- 5. an unreadable working directory is left alone -----------------------

test_an_unreadable_working_directory_leaves_the_process_alone() {
  local fake readable unreadable absent pids
  fake="$TMP_ROOT/fake-proc"
  rm -rf "$fake"
  readable=$(witness "$COPY")
  unreadable=$(witness "$COPY")
  absent=$(witness "$COPY")
  mkdir -p "$fake/$readable" "$fake/$unreadable" "$fake/$absent" "$fake/self"
  # The resolver only trusts a proc root that answers the cwd question about the
  # caller itself, so this synthetic root has to answer it too - otherwise the
  # case would prove the self-test rather than the parser.
  ln -s "$(pwd -P)" "$fake/self/cwd"
  ln -s "$COPY" "$fake/$readable/cwd"
  # `ls -l` renders a link whose target the caller may not read as an entry with
  # no target at all, and a process that vanished mid-scan as no entry at all.
  # Both must read as "no evidence", never as "reap it".
  printf '%s\n' "$COPY" > "$fake/$unreadable/cwd"

  FM_PROC_ROOT_OVERRIDE="$fake"
  pids=$(fm_wtproc_pids_under "$COPY") \
    || fail "unreadable-cwd: the scan failed instead of skipping what it could not read"
  contains_pid "$pids" "$readable" \
    || fail "unreadable-cwd: the readable working directory was not attributed, so this case proves nothing"
  contains_pid "$pids" "$unreadable" \
    && fail "unreadable-cwd: a process whose working directory could not be read was attributed"
  contains_pid "$pids" "$absent" \
    && fail "unreadable-cwd: a process with no working-directory entry was attributed"

  fm_wtproc_reap "test" none "$COPY" >/dev/null 2>&1 \
    || fail "unreadable-cwd: the cleanup could not be completed"
  unset FM_PROC_ROOT_OVERRIDE
  sleep 0.3
  alive "$readable" && fail "unreadable-cwd: the attributed process was not stopped"
  alive "$unreadable" || fail "unreadable-cwd: a process whose working directory could not be read was stopped"
  alive "$absent" || fail "unreadable-cwd: a process with no working-directory entry was stopped"

  kill -KILL "$unreadable" "$absent" 2>/dev/null || true
  pass "a working directory that cannot be read leaves its process alone; it is never a default kill"
}

# --- 6. the endpoint's own shell, named by the record ------------------------
#
# The process that saturated the host on 2026-08-27 was an API reparented to
# init - its own session leader. A rule that spared every session leader would
# have skipped exactly it, so the shell that IS spared has to be the one the
# task's record names and nothing else.

test_only_the_recorded_endpoint_shell_is_spared() {
  local endpoint daemon ordinary err
  err="$TMP_ROOT/spare.err"
  endpoint=$(session_leader_witness "$COPY")
  daemon=$(session_leader_witness "$COPY")
  ordinary=$(witness "$COPY")

  fm_wtproc_reap "test" "$endpoint" "$COPY" >/dev/null 2>"$err" \
    || fail "endpoint-shell: the cleanup could not be completed: $(cat "$err")"
  sleep 0.3
  alive "$ordinary" \
    && fail "endpoint-shell: an ordinary leftover survived, so this case proves nothing"
  alive "$daemon" \
    && fail "endpoint-shell: a session-leader daemon that is not the endpoint's shell survived"
  alive "$endpoint" \
    || fail "endpoint-shell: the shell the record names as this endpoint's was stopped"
  [ "$FM_WTPROC_SPARED_ENDPOINT" = "$endpoint" ] \
    || fail "endpoint-shell: the reap did not report which pid it held back"
  [ "$FM_WTPROC_SPARED_LEADERS" = 0 ] \
    || fail "endpoint-shell: leaders were held back although the endpoint's shell was named"

  kill -KILL "$endpoint" 2>/dev/null || true
  sleep 0.3
  pass "only the shell the record names as the endpoint's is spared; a session-leader daemon in the same copy is not"
}

test_an_unnameable_endpoint_shell_holds_leaders_back_and_says_how_many() {
  local unnamed ordinary err
  err="$TMP_ROOT/unknown.err"
  unnamed=$(session_leader_witness "$COPY")
  ordinary=$(witness "$COPY")

  fm_wtproc_reap "test" unknown "$COPY" >/dev/null 2>"$err" \
    || fail "unnameable-endpoint: the cleanup could not be completed: $(cat "$err")"
  sleep 0.3
  alive "$ordinary" \
    && fail "unnameable-endpoint: an ordinary leftover survived, so this case proves nothing"
  alive "$unnamed" \
    || fail "unnameable-endpoint: a session leader was stopped although the endpoint's shell could not be named"
  [ "$FM_WTPROC_SPARED_LEADERS" = 1 ] \
    || fail "unnameable-endpoint: expected 1 held-back leader, got $FM_WTPROC_SPARED_LEADERS"
  case "$(cat "$err")" in
    *"session leader(s)"*"could not be identified from the task record"*) ;;
    *) fail "unnameable-endpoint: the held-back leaders were not named: $(cat "$err")" ;;
  esac

  # And once nothing is held back at all, the same leader goes: the case hinges
  # on what the caller could name and not on the process being unkillable.
  fm_wtproc_reap "test" none "$COPY" >/dev/null 2>&1 \
    || fail "unnameable-endpoint: the unconditional cleanup could not be completed"
  sleep 0.3
  alive "$unnamed" && fail "unnameable-endpoint: a cleanup that holds nothing back spared a session leader"
  pass "an endpoint shell the record cannot name holds every session leader back and reports how many"
}

# --- 7. the same rule through the reporting path -----------------------------

test_a_copy_with_only_unclassifiable_leaders_is_never_reported_clean() {
  local dir leader out
  dir="$TMP_ROOT/case-unnameable"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-unn
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  # The backend cannot say which pid its pane runs, so nothing may be classified.
  printf 'fakepane' > "$dir/panepid"

  leader=$(session_leader_witness "$COPY")
  write_task_meta unn "$COPY" "fmses:fm-unn"

  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"UNRESOLVED: unn"*"leaders_skipped=1"*) ;;
    *) fail "unnameable-report: a copy holding an unclassifiable leader was reported as clean: $out" ;;
  esac
  out=$(run_orphan "$dir" reap unn)
  case "$out" in
    *"left alone because its endpoint shell could not be identified"*) ;;
    *) fail "unnameable-report: the explicit cleanup did not say why it stopped nothing: $out" ;;
  esac
  sleep 0.3
  alive "$leader" || fail "unnameable-report: an unclassifiable session leader was stopped"

  # Same fixture, same process: only the record's ability to name the endpoint's
  # own shell changes, and now the leader is an ordinary orphan.
  printf '%s' "$leader" > "$dir/panepid"
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unn"*) fail "unnameable-report: the endpoint's own shell was reported as a leftover: $out" ;;
    *"UNRESOLVED: unn"*) fail "unnameable-report: the copy was still unresolved once its endpoint shell was named: $out" ;;
  esac

  # And a daemon beside it, which is not that shell, is reported and stopped.
  local daemon
  daemon=$(session_leader_witness "$COPY")
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unn"*"$daemon"*) ;;
    *) fail "unnameable-report: an orphaned session-leader daemon was not reported: $out" ;;
  esac
  run_orphan "$dir" reap unn >/dev/null
  sleep 0.3
  alive "$daemon" && fail "unnameable-report: an orphaned session-leader daemon survived the cleanup"
  alive "$leader" || fail "unnameable-report: the recorded endpoint's own shell was stopped"

  kill -KILL "$leader" 2>/dev/null || true
  rm -f "$HOME_DIR/state/unn.meta"
  pass "a session-leader daemon is reported and stopped once the record names the endpoint's shell, and that shell never is"
}

# --- 8. the per-task temp root is a reap root and gets the same refusals ------

test_a_temp_root_in_the_operators_tree_is_never_a_reap_root() {
  local good rc out projects_tmp home_tmp pid_in_copy pid_in_projects dir

  good="$TMP_ROOT/fm-good"
  mkdir -p "$good"
  out=$(fm_wtproc_task_tmp good "$good" "$HOME_DIR" 2>&1) \
    || fail "temp-root: a legitimate per-task temp root was refused: $out"
  [ "$out" = "$good" ] || fail "temp-root: expected $good, got $out"

  projects_tmp="$HOME_DIR/projects/fm-tmpguard"
  mkdir -p "$projects_tmp"
  rc=0
  out=$(fm_wtproc_task_tmp tmpguard "$projects_tmp" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "temp-root: a temp root under the home's projects/ was accepted"
  case "$out" in
    *"is a primary clone"*) ;;
    *) fail "temp-root: the projects/ refusal did not name its cause: $out" ;;
  esac

  home_tmp="$HOME_DIR/fm-tmphome"
  mkdir -p "$home_tmp"
  rc=0
  out=$(HOME="$HOME_DIR" fm_wtproc_task_tmp tmphome "$home_tmp" "$HOME_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "temp-root: a temp root sitting directly in the home directory was accepted"

  # End to end: a record naming the operator's own tree as this task's second
  # reap root reaches nothing in it, while the real copy is still cleaned.
  dir="$TMP_ROOT/case-tmproot"
  mkdir -p "$dir"
  make_backend_stub "$dir" fm-tmpguard
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"
  printf 'fakepane' > "$dir/panepid"
  pid_in_projects=$(witness "$projects_tmp")
  pid_in_copy=$(witness "$COPY")
  write_task_meta tmpguard "$COPY" "fmses:fm-tmpguard" "$projects_tmp"

  out=$(run_orphan "$dir" scan --task tmpguard)
  case "$out" in
    *"$pid_in_projects"*) fail "temp-root: a process under the home's projects/ was attributed to a task: $out" ;;
  esac
  run_orphan "$dir" reap tmpguard >/dev/null
  sleep 0.3
  alive "$pid_in_projects" \
    || fail "temp-root: a process under the home's projects/ was stopped by a task's cleanup"
  alive "$pid_in_copy" \
    && fail "temp-root: the task's own copy was not cleaned, so this case proves nothing"

  kill -KILL "$pid_in_projects" 2>/dev/null || true
  rm -f "$HOME_DIR/state/tmpguard.meta"
  pass "a per-task temp root pointing into the operator's own tree is refused, and nothing in it is ever signalled"
}

# --- 9. the reap's account of its own outcome --------------------------------
#
# "Stopped" is what an operator acts on, so it may only be said when it is true.
# These cases drive the scan through a synthetic cwd source - the proc root is
# pointed at nothing so the lsof branch answers - because the three outcomes
# below are all about what the reap does when the machine stops answering, or
# answers that a process outlived a KILL (the uninterruptible-wait shape of the
# 2026-08-27 incident, which no test can produce on demand).

make_cwd_source_stub() {  # <dir> <pid> <cwd> <good-answers|forever>
  mkdir -p "$1/bin"
  printf '0' > "$1/count"
  cat > "$1/bin/lsof" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FAKE_LSOF_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" > "$FAKE_LSOF_COUNT"
if [ "$FAKE_LSOF_GOOD" != forever ] && [ "$n" -gt "$FAKE_LSOF_GOOD" ]; then
  echo "lsof: synthetic failure" >&2
  exit 1
fi
printf 'p%s\nfcwd\nn%s\n' "$FAKE_LSOF_PID" "$FAKE_LSOF_DIR"
SH
  chmod +x "$1/bin/lsof"
  # A birth identity that stays put after the process is gone, so "still listed"
  # is not quietly rescued by the pid-reuse guard.
  cat > "$1/bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "$FAKE_LSOF_PID" ]; then
  printf 'Mon Jan  1 00:00:00 2024 /bin/sleep 600\n'
  exit 0
fi
exec "$FAKE_REAL_PS_BIN" "$@"
SH
  chmod +x "$1/bin/ps"
  FAKE_LSOF_COUNT="$1/count"
  FAKE_LSOF_PID=$2
  FAKE_LSOF_DIR=$3
  FAKE_LSOF_GOOD=$4
  FAKE_REAL_PS_BIN=$(command -v ps)
  export FAKE_LSOF_COUNT FAKE_LSOF_PID FAKE_LSOF_DIR FAKE_LSOF_GOOD FAKE_REAL_PS_BIN
}

with_stubbed_cwd_source() {  # <dir> <command...>
  local dir=$1 saved_path=$PATH rc=0
  shift
  PATH="$dir/bin:$PATH"
  FM_PROC_ROOT_OVERRIDE="$dir/no-proc"
  "$@" || rc=$?
  PATH=$saved_path
  unset FM_PROC_ROOT_OVERRIDE
  return "$rc"
}

test_the_reap_distinguishes_a_scan_that_broke_before_a_signal_from_one_after() {
  local dir pid err rc

  dir="$TMP_ROOT/outcome-before"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/before.err"
  make_cwd_source_stub "$dir" "$pid" "$dir/work" 0
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "before" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 1 ] || fail "reap-outcome: a scan that failed before any signal returned $rc, not 1"
  case "$(cat "$err")" in
    *"nothing was signalled"*) ;;
    *) fail "reap-outcome: the pre-signal failure did not say nothing was signalled: $(cat "$err")" ;;
  esac
  alive "$pid" || fail "reap-outcome: a process was signalled by a scan that never resolved"
  kill -KILL "$pid" 2>/dev/null || true

  dir="$TMP_ROOT/outcome-after"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/after.err"
  # Two answers is exactly enough to select and signal; the recheck after the
  # grace period is the one that breaks.
  make_cwd_source_stub "$dir" "$pid" "$dir/work" 2
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "after" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 2 ] || fail "reap-outcome: a scan that failed after the signal returned $rc, not 2"
  case "$(cat "$err")" in
    *"nothing was signalled"*)
      fail "reap-outcome: a post-signal failure claimed nothing was signalled: $(cat "$err")" ;;
    *"their fate is unknown"*) ;;
    *) fail "reap-outcome: the post-signal failure did not name the uncertainty: $(cat "$err")" ;;
  esac
  case " $FM_WTPROC_REAPED " in
    *" $pid "*) ;;
    *) fail "reap-outcome: the post-signal failure did not name what it had signalled" ;;
  esac
  pass "a scan that breaks before a signal and one that breaks after it are two different answers"
}

test_a_scan_that_breaks_between_selecting_and_signalling_names_the_root() {
  local dir pid err rc
  dir="$TMP_ROOT/outcome-between"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/between.err"
  # One good answer: enough to collect and select, so the recheck that guards
  # the TERM is the pass that breaks. A cleanup abandoned there has to name the
  # root that stopped answering, exactly as the earlier failure does.
  make_cwd_source_stub "$dir" "$pid" "$dir/work" 1
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "between" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 1 ] || fail "reap-outcome: a scan that broke before the TERM returned $rc, not 1"
  case "$(cat "$err")" in
    *"nothing was signalled"*) ;;
    *) fail "reap-outcome: the failure between selecting and signalling said nothing about what it did: $(cat "$err")" ;;
  esac
  case "$(cat "$err")" in
    *"$dir/work"*) ;;
    *) fail "reap-outcome: the abandoned cleanup did not name the root that stopped answering: $(cat "$err")" ;;
  esac
  alive "$pid" || fail "reap-outcome: a process was signalled after the scan stopped answering"
  kill -KILL "$pid" 2>/dev/null || true
  pass "a cleanup abandoned between selecting and signalling names the root it lost and says nothing was signalled"
}

test_a_process_that_outlives_the_force_stop_is_never_reported_stopped() {
  local dir pid err rc
  dir="$TMP_ROOT/outcome-survivor"
  mkdir -p "$dir/work"
  pid=$(witness "$dir/work")
  err="$dir/survivor.err"
  # The cwd source keeps answering that the process is there, and its birth
  # identity keeps matching: from the reap's side this is indistinguishable
  # from a process wedged past a KILL.
  make_cwd_source_stub "$dir" "$pid" "$dir/work" forever
  rc=0
  with_stubbed_cwd_source "$dir" fm_wtproc_reap "survivor" none "$dir/work" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" = 3 ] || fail "reap-outcome: a process still listed after the force-stop returned $rc, not 3"
  [ "$FM_WTPROC_SURVIVORS" = "$pid" ] \
    || fail "reap-outcome: the survivor was not named: '$FM_WTPROC_SURVIVORS'"
  case "$(cat "$err")" in
    *"still running after being force-stopped"*) ;;
    *) fail "reap-outcome: the survivor was not reported: $(cat "$err")" ;;
  esac
  kill -KILL "$pid" 2>/dev/null || true
  pass "a process that outlives the force-stop is reported as surviving, never as stopped"
}

# --- 10. a copy the host could not look at is never reported clean -----------
#
# "I looked and found nothing" and "I could not look" are different facts, and
# the session-start digest prints the first as "(none)". A scan that folded the
# second into it would tell an operator a fleet is clean on the strength of
# never having examined it.

test_a_copy_this_host_cannot_list_is_never_reported_clean() {
  local dir pid out rc
  dir="$TMP_ROOT/case-unscannable"
  mkdir -p "$dir/fakebin"
  make_backend_stub "$dir" fm-unscan
  make_crew_state_stub "$dir"
  printf 'dead' > "$dir/agent"

  pid=$(witness "$COPY")
  write_task_meta unscan "$COPY" "fmses:fm-unscan"

  # The same fixture on a host that CAN answer, so what follows is proven to
  # hinge on the missing cwd source and nothing else.
  out=$(run_orphan "$dir" scan)
  case "$out" in
    *"LEFTOVER: unscan"*) ;;
    *) fail "unscannable: the copy was not reported while the host could answer, so this case proves nothing: $out" ;;
  esac

  # Now no cwd source can answer at all: the proc root points at nothing and the
  # only other source refuses.
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: synthetic failure" >&2
exit 1
SH
  chmod +x "$dir/fakebin/lsof"
  export FM_PROC_ROOT_OVERRIDE="$dir/no-proc"

  rc=0
  out=$(run_orphan "$dir" scan) || rc=$?
  case "$out" in
    *"UNSCANNABLE: unscan"*) ;;
    *) fail "unscannable: a copy that could not be listed was not reported: $out" ;;
  esac
  case "$out" in
    *"$COPY"*) ;;
    *) fail "unscannable: the report did not name the root it could not read: $out" ;;
  esac
  case "$out" in
    *"LEFTOVER: unscan"*) fail "unscannable: an unexamined copy was reported as leaking: $out" ;;
  esac
  [ "$rc" != 0 ] || fail "unscannable: a scan that could not look exited 0, so the digest would print (none)"

  rc=0
  out=$(run_orphan "$dir" reap unscan) || rc=$?
  [ "$rc" != 0 ] || fail "unscannable: an explicit cleanup that could not look reported success"
  case "$out" in
    *"nothing to stop"*) fail "unscannable: a copy that could not be listed was reported as having nothing to stop: $out" ;;
  esac
  case "$out" in
    *"could not be listed"*) ;;
    *) fail "unscannable: the refusal did not say the copy could not be listed: $out" ;;
  esac
  unset FM_PROC_ROOT_OVERRIDE
  rm -f "$dir/fakebin/lsof"

  sleep 0.3
  alive "$pid" || fail "unscannable: a process was stopped by a scan that could not resolve anything"
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/unscan.meta"
  pass "a copy this host cannot list is reported as unexamined, and never as clean or as stopped"
}

# --- 11. a caller whose own working directory is gone can still look ---------

test_a_removed_working_directory_does_not_make_the_host_unanswerable() {
  local lib gone stub pid out rc baseline
  lib="$ROOT/bin/fm-worktree-proc-lib.sh"
  baseline=$(bash -c '. "$1"; fm_wtproc_resolver' _ "$lib" 2>/dev/null || true)
  if [ "$baseline" != proc ]; then
    pass "the caller's own working directory is not this host's cwd source; nothing to prove"
    return 0
  fi

  stub="$TMP_ROOT/gone-cwd-bin"
  mkdir -p "$stub"
  # The only other source refuses, so the answer below can only have come from
  # /proc.
  cat > "$stub/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: synthetic failure" >&2
exit 1
SH
  chmod +x "$stub/lsof"

  gone="$TMP_ROOT/gone-cwd"
  mkdir -p "$gone"
  pid=$(witness "$COPY")
  rc=0
  # A shell left sitting in a directory that is then removed under it - what a
  # torn-down task copy leaves behind, and the reachable trigger for the whole
  # fleet scan reporting nothing.
  out=$(cd "$gone" && rm -rf "$gone" \
    && PATH="$stub:$PATH" bash -c '. "$1"; fm_wtproc_pids_under "$2"' _ "$lib" "$COPY" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || fail "gone-cwd: a caller whose own working directory was removed could not answer at all"
  contains_pid "$out" "$pid" \
    || fail "gone-cwd: the process in the copy was not found from a caller with no working directory: '$out'"

  kill -KILL "$pid" 2>/dev/null || true
  pass "a caller whose own working directory was removed still resolves processes from /proc"
}

# --- 12. one listing per observation, and never one across two ---------------

test_each_collect_looks_at_the_machine_again() {
  local pid other tmp_root
  tmp_root="$TMP_ROOT/collect-roots/fm-collect"
  mkdir -p "$tmp_root"
  pid=$(witness "$COPY")
  other=$(witness "$tmp_root")

  fm_wtproc_collect "$COPY" "$tmp_root" \
    || fail "collect: a scan of two roots failed"
  contains_pid "$FM_WTPROC_PIDS" "$pid" \
    || fail "collect: the process in the first root was not attributed"
  contains_pid "$FM_WTPROC_PIDS" "$other" \
    || fail "collect: the process in the second root was not attributed, so the roots do not share one listing correctly"

  kill -KILL "$other" 2>/dev/null || true
  sleep 0.3
  fm_wtproc_collect "$COPY" "$tmp_root" \
    || fail "collect: the second scan of two roots failed"
  contains_pid "$FM_WTPROC_PIDS" "$pid" \
    || fail "collect: the surviving process was lost by the second scan"
  contains_pid "$FM_WTPROC_PIDS" "$other" \
    && fail "collect: a process that had already exited was still reported, so one observation answered another"

  kill -KILL "$pid" 2>/dev/null || true
  pass "every collect looks at the machine again; a process that has died since the last one is gone from the next"
}

test_only_a_linked_worktree_is_a_disposable_copy
test_a_process_in_a_disposable_copy_is_found_and_stopped
test_a_primary_checkout_is_never_a_target
test_a_live_workers_processes_are_never_stopped
test_a_disagreeing_current_state_vetoes_the_verdict
test_an_unreadable_working_directory_leaves_the_process_alone
test_only_the_recorded_endpoint_shell_is_spared
test_an_unnameable_endpoint_shell_holds_leaders_back_and_says_how_many
test_a_copy_with_only_unclassifiable_leaders_is_never_reported_clean
test_a_temp_root_in_the_operators_tree_is_never_a_reap_root
test_the_reap_distinguishes_a_scan_that_broke_before_a_signal_from_one_after
test_a_scan_that_breaks_between_selecting_and_signalling_names_the_root
test_a_process_that_outlives_the_force_stop_is_never_reported_stopped
test_a_copy_this_host_cannot_list_is_never_reported_clean
test_a_removed_working_directory_does_not_make_the_host_unanswerable
test_each_collect_looks_at_the_machine_again
