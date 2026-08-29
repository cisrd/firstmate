#!/usr/bin/env bash
# tests/fm-endpoint-shell-launch-window.test.sh - spawn-path regression for the
# endpoint-shell marker's launch window (task fm-endpoint-shell-backends).
#
# The marker is a PS1 assignment firstmate plants on the task pane's own shell,
# and a BARE marked prompt is the fleet-wide proof that the agent exited
# (bin/fm-busy-lib.sh's `dead endpoint-shell`). So the pane must never show a
# bare marked prompt while the endpoint is HEALTHY and merely still launching -
# a spawn that plants the marker on a line of its own hands the pane back to a
# bare marked prompt for the whole interval until the launch text is typed, and
# a concurrent reader classifies that live endpoint as dead.
#
# This drives the REAL bin/fm-spawn.sh against a fake `zellij` CLI that
# simulates the pane's shell (a PS1, an input buffer, a rendered screen), snaps
# the screen after every draw, and then classifies every one of those snapshots
# through the real fm_busy_classify. Nothing here reads spawn's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the zellij adapter)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-shell-launch-window)
SNAP_SEP='---fm-snapshot---'

# A fake `zellij` that is a small pane simulator, not just a command log. It
# keeps the pane's PS1, its unsubmitted paste buffer, and its rendered rows in
# $FM_FAKE_ZJ_STATE, and appends the whole screen to `snapshots` every time the
# screen changes - which is what lets the assertions below ask "was there EVER
# a moment during this spawn when the pane read as a dead endpoint shell?".
#
# The simulated shell models exactly the three behaviors that matter here:
# a submitted line echoes behind the current prompt, a leading `PS1='...'`
# assignment changes the prompt from then on, and a command that starts the
# harness keeps the shell busy so no new prompt is drawn (every other command
# returns and the shell draws its prompt again).
make_zellij_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_ZJ_STATE:?}"
SEP="${FM_FAKE_ZJ_SNAP_SEP:?}"

snapshot() { { cat "$S/screen"; printf '%s\n' "$SEP"; } >> "$S/snapshots"; }

draw_prompt() { printf '%s\n' "$(cat "$S/ps1")" >> "$S/screen"; snapshot; }

commit_line() {
  local line ps1 rest
  line=$(cat "$S/pending"); : > "$S/pending"
  ps1=$(cat "$S/ps1")
  printf '%s%s\n' "$ps1" "$line" >> "$S/screen"
  snapshot
  rest=$line
  # A leading PS1 assignment takes effect for every later prompt, exactly as a
  # real shell applies it; the rest of the line still runs.
  if [[ $rest == PS1=\'*\'* ]]; then
    ps1=${rest#PS1=\'}
    ps1=${ps1%%\'*}
    printf '%s' "$ps1" > "$S/ps1"
    rest=${rest#PS1=\'*\'}
    rest=${rest#;}
    rest=${rest# }
  fi
  case "$rest" in
    *__FM_ZELLIJ_CWD_BEGIN__*)
      printf '__FM_ZELLIJ_CWD_BEGIN__\n%s\n__FM_ZELLIJ_CWD_END__\n' \
        "${FM_FAKE_PANE_PATH:-/}" >> "$S/screen"
      snapshot
      ;;
  esac
  case "$rest" in
    *"${FM_FAKE_ZJ_LAUNCH_MATCH:-__never__}"*)
      # The harness is now the shell's foreground job: no prompt is drawn
      # again until it exits.
      printf '1\n' > "$S/launched"
      return 0
      ;;
  esac
  draw_prompt
}

case "${1:-}" in
  --version) printf 'zellij %s\n' "${FM_FAKE_ZJ_VERSION:-0.44.0}"; exit 0 ;;
  list-sessions) [ -f "$S/session" ] && cat "$S/session"; exit 0 ;;
  attach) printf '%s\n' "${3:-}" > "$S/session"; exit 0 ;;
esac

# `zellij --session <name> action <subcommand> ...`
[ "${1:-}" = --session ] || exit 0
shift 2
[ "${1:-}" = action ] || exit 0
shift
sub=${1:-}
shift
case "$sub" in
  list-tabs)
    jq -c -n --slurpfile t <(jq -R -s 'split("\n") | map(select(length>0))' < "$S/tabs") \
      '$t[0] | map(split("\t")) | to_entries | map({tab_id: (.value[0]|tonumber), name: .value[1], active: (.key == 0)})'
    ;;
  new-tab)
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=${2:-}; shift 2 ;;
        --cwd) shift 2 ;;
        *) shift ;;
      esac
    done
    id=$(( $(cat "$S/nextid" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$id" > "$S/nextid"
    printf '%s\t%s\n' "$id" "$name" >> "$S/tabs"
    printf '%s\n' "$id"
    ;;
  list-panes)
    jq -c -n --slurpfile t <(jq -R -s 'split("\n") | map(select(length>0))' < "$S/tabs") \
      '$t[0] | map(split("\t")) | map({id: (.[0]|tonumber), tab_id: (.[0]|tonumber), is_plugin: false})'
    ;;
  paste)
    while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
    shift
    printf '%s' "${1:-}" >> "$S/pending"
    ;;
  send-keys)
    key=
    while [ $# -gt 0 ]; do
      case "$1" in
        --pane-id) shift 2 ;;
        *) key=$1; shift ;;
      esac
    done
    [ "$key" = Enter ] && commit_line
    ;;
  dump-screen) cat "$S/screen" ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/zellij"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

# Run one real spawn onto the simulated zellij pane. Echoes the state dir the
# simulator wrote (screen, ps1, snapshots).
run_zellij_spawn() {  # <name> -> echoes sim-state dir
  local name=$1 case_dir home proj wt fakebin sim id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sim="$case_dir/sim"
  fakebin=$(make_zellij_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$sim"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'zellij\n' > "$home/config/backend"
  touch "$home/state/.last-watcher-beat"
  : > "$sim/tabs"; : > "$sim/pending"; : > "$sim/screen"; : > "$sim/snapshots"
  printf 'fm-sim-%s\n' "$name" > "$sim/session"
  printf 'captain@ship:~$ ' > "$sim/ps1"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  env -u FM_TRACE_CONTEXT -u TMUX \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    FM_ZELLIJ_SESSION="fm-sim-$name" \
    FM_FAKE_ZJ_STATE="$sim" FM_FAKE_ZJ_SNAP_SEP="$SNAP_SEP" \
    FM_FAKE_ZJ_LAUNCH_MATCH='--dangerously-skip-permissions' \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --backend zellij --mode no-mistakes --yolo off \
    > "$case_dir/spawn.out" 2>&1 || true
  printf '%s\n' "$sim"
}

# Classify one captured screen exactly as a concurrent supervisor would: no
# busy record for the task yet (the pane is still launching), so classification
# falls through to the endpoint-shell arm.
classify_screen() {  # <state-dir> <screen>
  fm_busy_classify zellij "sim:1" claude sim-task "$1" "$2"
}

test_launch_window_never_reads_as_a_dead_endpoint_shell() {
  local sim state snap line n=0 verdict launched
  sim=$(run_zellij_spawn launchwindow)
  state="$sim/norecord"
  mkdir -p "$state"

  launched=$(cat "$sim/launched" 2>/dev/null || echo 0)
  [ "$launched" = 1 ] \
    || fail "the fixture never reached the launch command; the simulated spawn did not run to launch"

  [ -s "$sim/snapshots" ] || fail "the simulated pane recorded no screen at all"

  snap=
  while IFS= read -r line; do
    if [ "$line" = "$SNAP_SEP" ]; then
      n=$((n + 1))
      verdict=$(classify_screen "$state" "$snap")
      [ "$verdict" != "dead endpoint-shell" ] \
        || fail "screen #$n during the launch window classified '$verdict'; a healthy launching endpoint must never read as a dead endpoint shell:"$'\n'"$snap"
      snap=
      continue
    fi
    snap="$snap$line"$'\n'
  done < "$sim/snapshots"

  [ "$n" -gt 2 ] || fail "expected the simulated pane to be drawn repeatedly during spawn, saw only $n screens"
  pass "no screen drawn during a real spawn's launch window reads as a dead endpoint shell ($n screens)"
}

# The companion half: the marker must still MEAN what it meant. The launch line
# itself carries the PS1 assignment, so by the time the harness is running the
# pane's prompt is the marked one - and the first prompt it draws after the
# harness exits is the bare marked prompt the recovery path reads as dead.
test_marker_still_proves_a_dead_endpoint_shell_after_the_agent_exits() {
  local sim state ps1 screen verdict
  sim=$(run_zellij_spawn afterexit)
  state="$sim/norecord"
  mkdir -p "$state"

  ps1=$(cat "$sim/ps1")
  [ "$ps1" = "$FM_COMPOSER_ENDPOINT_SHELL_MARKER " ] \
    || fail "after launch the pane's prompt must be the endpoint-shell marker, got '$ps1'"

  # The harness exits: that same shell prints its own prompt again.
  screen=$(cat "$sim/screen")$'\n'"$ps1"
  verdict=$(classify_screen "$state" "$screen")
  [ "$verdict" = "dead endpoint-shell" ] \
    || fail "the prompt the pane draws after the agent exits must classify dead endpoint-shell, got '$verdict'"
  pass "the marker still proves a dead endpoint shell once the agent exits"
}

test_launch_window_never_reads_as_a_dead_endpoint_shell
test_marker_still_proves_a_dead_endpoint_shell_after_the_agent_exits
