#!/usr/bin/env bash
# End-to-end demonstration of the endpoint-shell marker on a REAL bash shell in
# a REAL terminal pane. The zellij CLI surface is a shim onto tmux
# (/tmp/fm-es-e2e/zellij); fm-spawn.sh, the zellij adapter, fm_busy_classify and
# fm-crew-state.sh are the real product code.
set -u
ROOT=${FM_DEMO_ROOT:?}
. "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-composer-lib.sh"
. "$ROOT/bin/fm-busy-lib.sh"

D=/tmp/fm-es-e2e/run
rm -rf "$D"; mkdir -p "$D"
export FM_DEMO_STATE="$D/sim" FM_DEMO_SOCK="$D/tmux.sock"
mkdir -p "$FM_DEMO_STATE"
: > "$FM_DEMO_STATE/tabs"; printf 'fm-demo\n' > "$FM_DEMO_STATE/session"

home=$D/home proj=$D/project wt=$D/wt fb=$D/fakebin panehome=$D/panehome
mkdir -p "$home"/{data,projects,state,config} "$fb" "$panehome"

# The "agent": a real process that occupies the pane's shell as a foreground
# job exactly as a harness does, and exits when interrupted.
cat > "$fb/claude" <<'AGENT'
#!/usr/bin/env bash
echo "claude (demo harness) starting - model: opus"
echo "> ready for the brief"
trap 'echo "claude: session ended"; exit 0' INT
sleep 900
AGENT
chmod +x "$fb/claude"
cp /tmp/fm-es-e2e/zellij "$fb/zellij"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"; chmod +x "$fb/no-mistakes"

printf 'claude\n' > "$home/config/crew-harness"
printf 'zellij\n' > "$home/config/backend"
touch "$home/state/.last-watcher-beat"
printf '%s\n' "$$" > "$home/state/.lock"

fm_git_worktree "$proj" "$wt" wt-demo >/dev/null 2>&1
id=demo-task
mkdir -p "$home/data/$id"
printf 'Demo brief for %s\n' "$id" > "$home/data/$id/brief.md"

export PATH="$fb:$PATH"
# The pane's own HOME is the demo dir, so the real `treehouse` the pane runs
# keeps its workspaces inside this throwaway tree.
env HOME="$panehome" tmux -S "$FM_DEMO_SOCK" -f /dev/null new-session -d -s host -x 100 -y 24 >/dev/null 2>&1
# Panes run a non-login shell so /etc/profile does not rewrite the PATH that
# carries this demo's fake `claude` harness.
tmux -S "$FM_DEMO_SOCK" set-option -g default-command 'bash --noprofile --norc' >/dev/null 2>&1
trap 'tmux -S "$FM_DEMO_SOCK" kill-server >/dev/null 2>&1' EXIT

hr() { printf '\n=== %s ===\n' "$*"; }

printf 'firstmate endpoint-shell marker - end-to-end demo\n'
printf 'repo head: %s\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
printf 'backend: zellij (CLI surface shimmed onto a real tmux server hosting a real bash pane)\n'
printf 'marker:  %s\n' "$FM_COMPOSER_ENDPOINT_SHELL_MARKER"

hr "1. fm-spawn.sh launches a task onto a real bash pane (backend=zellij)"
env -u TMUX FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_ZELLIJ_SESSION=fm-demo \
  "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --backend zellij --mode no-mistakes --yolo off 2>&1 \
  | sed -n '/^spawned/p'
sleep 3

TARGET=$(sed -n 's/^window=//p' "$home/state/$id.meta")
. "$ROOT/bin/fm-backend.sh"
fm_backend_source zellij

capture() { fm_backend_capture zellij "$TARGET" 20; }
classify() { fm_busy_classify zellij "$TARGET" claude "$id" "$1" "$2"; }

norec=$D/norecord; mkdir -p "$norec"

hr "2. HEALTHY endpoint - the agent is running in the pane"
cap=$(capture)
printf '%s\n' "$cap" | sed 's/^/  | /'
printf '  fm_busy_classify -> %s\n' "$(classify "$norec" "$cap")"

hr "3. the agent exits (Ctrl-C to the pane); that same shell prints its prompt"
fm_backend_send_key zellij "$TARGET" C-c >/dev/null 2>&1
sleep 2
cap2=$(capture)
printf '%s\n' "$cap2" | tail -8 | sed 's/^/  | /'
printf '  fm_busy_classify -> %s\n' "$(classify "$norec" "$cap2")"

hr "4. operator surface: fm-crew-state.sh on that endpoint"
# The marker's job is exactly the no-busy-record case (hooks not yet armed,
# torn wiring): show what records exist, then ask fm-crew-state.
printf '  (a) with the busy record fm-spawn just wrote:\n'
PATH="$fb:$PATH" FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ZELLIJ_SESSION=fm-demo \
  "$ROOT/bin/fm-crew-state.sh" "$id" 2>&1 | sed 's/^/      /'
printf '  (b) with NO busy record - the case the marker exists for (a hook that\n'
printf '      was never armed, a torn wiring file); records removed:\n'
rm -f "$home/state/$id".busy-state "$home/state/$id".busy-gen
PATH="$fb:$PATH" FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ZELLIJ_SESSION=fm-demo \
  "$ROOT/bin/fm-crew-state.sh" "$id" 2>&1 | sed 's/^/      /'

hr "5. CONTROL - the SAME endpoint with no firstmate marker on its prompt"
fm_backend_zellij_send_text_line "$TARGET" "PS1='captain@ship:~/project\$ '" \
  && echo "  (sent an unmarked PS1 to the same live shell)"
sleep 1
cap3=$(capture)
printf '%s\n' "$cap3" | tail -6 | sed 's/^/  | /'
printf '  fm_busy_classify -> %s\n' "$(classify "$norec" "$cap3")"
PATH="$fb:$PATH" FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_ZELLIJ_SESSION=fm-demo \
  "$ROOT/bin/fm-crew-state.sh" "$id" 2>&1 | sed 's/^/  /'
