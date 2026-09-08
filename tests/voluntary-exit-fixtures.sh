#!/usr/bin/env bash

voluntary_exit_cases() {
  printf '%s\n' 'valid yes' 'reordered yes' 'schema no' 'reason no' 'wait no' \
    'epoch no' 'duplicate no' 'extra no' 'missing no' 'symlink no'
}

voluntary_exit_fixture() {
  local rec=$1 variant=$2 schema=fm-voluntary-exit.v1 reason=external-wait wait_kind=pr-poll epoch=1
  case "$variant" in
    schema) schema=fm-voluntary-exit.v2 ;;
    reason) reason=crash ;;
    wait) wait_kind=ci-poll ;;
    epoch) epoch=-1 ;;
    missing) return 0 ;;
  esac
  if [ "$variant" = reordered ]; then
    printf 'exited_at=123\nwait=pr-poll\nreason=external-wait\nschema=fm-voluntary-exit.v1\n' > "$rec"
  else
    printf 'schema=%s\nreason=%s\nwait=%s\nexited_at=%s\n' \
      "$schema" "$reason" "$wait_kind" "$epoch" > "$rec"
  fi
  case "$variant" in
    duplicate) printf 'wait=pr-poll\n' >> "$rec" ;;
    extra) printf 'unknown=value\n' >> "$rec" ;;
    symlink) mv "$rec" "$rec.target"; ln -s "$rec.target" "$rec" ;;
  esac
}
