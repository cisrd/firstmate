#!/usr/bin/env bash
# Fake `zellij` CLI backed by a REAL tmux server: every zellij action this
# adapter uses is mapped onto a real terminal pane running a real bash.
set -u
S=$FM_DEMO_STATE
SOCK=$FM_DEMO_SOCK
tm() { tmux -S "$SOCK" "$@"; }
win() { printf 'fmdemo%s' "$1"; }

case "${1:-}" in
  --version) echo "zellij 0.44.0"; exit 0 ;;
  list-sessions) cat "$S/session"; exit 0 ;;
  attach) exit 0 ;;
esac
[ "${1:-}" = --session ] || exit 0
shift 2
[ "${1:-}" = action ] || exit 0
shift
sub=${1:-}; shift
case "$sub" in
  list-tabs)
    jq -c -n --slurpfile t <(jq -R -s 'split("\n") | map(select(length>0))' < "$S/tabs") \
      '$t[0] | map(split("\t")) | to_entries | map({tab_id: (.value[0]|tonumber), name: .value[1], active: (.key == 0)})'
    ;;
  new-tab)
    name=; cwd=$PWD
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=${2:-}; shift 2 ;;
        --cwd) cwd=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    id=$(( $(cat "$S/nextid" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$id" > "$S/nextid"
    printf '%s\t%s\n' "$id" "$name" >> "$S/tabs"
    tm new-window -d -n "$(win "$id")" -c "$cwd" >/dev/null 2>&1
    printf '%s\n' "$id"
    ;;
  list-panes)
    jq -c -n --slurpfile t <(jq -R -s 'split("\n") | map(select(length>0))' < "$S/tabs") \
      '$t[0] | map(split("\t")) | map({id: (.[0]|tonumber), tab_id: (.[0]|tonumber), is_plugin: false})'
    ;;
  paste)
    pane=
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
      case "$1" in --pane-id) pane=${2:-}; shift 2 ;; *) shift ;; esac
    done
    shift
    tm send-keys -t "$(win "$pane")" -l -- "${1:-}"
    ;;
  send-keys)
    pane=; key=
    while [ $# -gt 0 ]; do
      case "$1" in --pane-id) pane=${2:-}; shift 2 ;; *) key=$1; shift ;; esac
    done
    case "$key" in
      Enter) tm send-keys -t "$(win "$pane")" Enter ;;
      'Ctrl c') tm send-keys -t "$(win "$pane")" C-c ;;
      'Ctrl u') tm send-keys -t "$(win "$pane")" C-u ;;
      Esc) tm send-keys -t "$(win "$pane")" Escape ;;
      *) exit 0 ;;
    esac
    ;;
  dump-screen)
    pane=; ansi=
    while [ $# -gt 0 ]; do
      case "$1" in
        --pane-id) pane=${2:-}; shift 2 ;;
        --ansi) ansi=-e; shift ;;
        *) shift ;;
      esac
    done
    # shellcheck disable=SC2086
    tm capture-pane -p $ansi -t "$(win "$pane")"
    ;;
  *) : ;;
esac
exit 0
