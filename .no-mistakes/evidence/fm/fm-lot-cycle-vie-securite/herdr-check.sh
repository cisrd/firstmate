#!/usr/bin/env bash
set -eu
ROOT=$PWD
export HOME="$ROOT/.local-test/h" XDG_CONFIG_HOME="$ROOT/.h" XDG_DATA_HOME="$ROOT/.local-test/h/d" XDG_STATE_HOME="$ROOT/.local-test/h/s" XDG_CACHE_HOME="$ROOT/.local-test/h/cache"
unset HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_ENV
export FM_GATE_REFUSE_BYPASS=1
export FM_HOME="$ROOT/.local-test/live-home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data/hsmoke" "$ROOT/.local-test/proj" "$ROOT/.local-test/other"
PROJ="$ROOT/.local-test/proj"
WT="$ROOT/.local-test/wt"
git -C "$PROJ" init -q
printf '# fixture\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
git -C "$PROJ" worktree add -q -b hsmoke "$WT"
printf '# Brief\nTest occupancy refusal.\n' > "$FM_HOME/data/hsmoke/brief.md"
pane=$(jq -r .result.root_pane.pane_id .local-test/workspace.json)
herdr pane run "$pane" "cd '$WT'" >/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
for i in {1..40}; do seen=$(fm_backend_current_path herdr "default:$pane"); [ "$seen" != "$WT" ] || break; sleep .1; done
[ "$seen" = "$WT" ]
herdr pane report-agent "$pane" --source lifecycle-test --agent fixture --state idle >/dev/null
printf '%s\n' "window=default:$pane" endpoint_task_id=hsmoke "worktree=$WT" "project=$PROJ" harness=claude kind=ship mode=no-mistakes yolo=off model=default effort=default backend=herdr herdr_session=default herdr_workspace_id=w1 herdr_tab_id=w1:t1 "herdr_pane_id=$pane" > "$FM_HOME/state/hsmoke.meta"
cp "$FM_HOME/state/hsmoke.meta" "$ROOT/.local-test/prior.meta"
herdr pane run "$pane" "cd '$ROOT/.local-test/other'" >/dev/null
for i in {1..40}; do seen=$(fm_backend_current_path herdr "default:$pane"); [ "$seen" != "$ROOT/.local-test/other" ] || break; sleep .1; done
[ "$seen" = "$ROOT/.local-test/other" ]
echo '$ herdr pane get <fixture-pane> (launch cwd versus foreground cwd)'
herdr pane get "$pane"
echo '$ fm-control.sh hsmoke relaunch --note "must not stop"'
rc=0
FM_CONTROL_POLL=.2 FM_CONTROL_EXIT_WAIT=2 "$ROOT/bin/fm-control.sh" hsmoke relaunch --note 'must not stop' > .local-test/herdr-refusal.txt 2>&1 || rc=$?
/bin/cat .local-test/herdr-refusal.txt
[ "$rc" = 1 ]
grep -F 'not its recorded worktree' .local-test/herdr-refusal.txt >/dev/null
cmp "$FM_HOME/state/hsmoke.meta" .local-test/prior.meta
state=$(fm_backend_agent_state herdr "default:$pane")
[ "$state" = alive ]
printf 'After refusal: agent=%s; task metadata byte-identical; recorded worktree preserved=%s\n' "$state" "$([ -d "$WT" ] && echo yes)"
echo '$ herdr pane get <fixture-pane> (after refusal)'
herdr pane get "$pane"
