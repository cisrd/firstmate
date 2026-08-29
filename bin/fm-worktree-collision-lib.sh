# shellcheck shell=bash
# Worktree double-registration detection: two state/*.meta records claiming
# the same worktree= path.
# Usage: . bin/fm-worktree-collision-lib.sh
#
# Requires bin/fm-backend.sh (fm_meta_get, fm_backend_of_meta,
# fm_backend_target_of_meta, fm_backend_agent_state) and bin/fm-tangle-lib.sh
# (fm_default_branch) sourced first by the caller. This file is sourced by
# scripts and has no side effects on source.
#
# A pooled worktree handed to two live task records is quiet and expensive: a
# commit can land on the wrong branch, or a teardown can return a copy another
# task still needs. This is detection only - it never repairs a collision,
# because an automatic fix here could discard unlanded work.
#
# fm_worktree_collision_claimant_state classifies ONE claimant of a shared
# path from cheap, entirely local evidence (no network):
#   alive    - fm_backend_agent_state reports the recorded backend/target
#              alive. Always a hazard regardless of worktree content.
#   unknown  - the process state is ambiguous, unreadable, or unverified (or
#              the record has no usable target). Cannot be proven finished, so
#              it is treated as a hazard rather than guessed away.
#   unlanded - the process is confirmed dead or missing, but the shared path
#              has uncommitted changes, or its HEAD is not proven reachable
#              from the project's default branch. A hazard: discarding this
#              copy could lose real work.
#   gone     - the recorded path is no longer an inspectable git worktree (a
#              prior teardown already removed it). Nothing of this claimant's
#              is left to lose.
#   landed   - the process is confirmed dead or missing, the worktree is
#              clean, and its HEAD is reachable from the project's default
#              branch. The task is finished; this claimant's record is stale.
# gone and landed are the only two non-hazard verdicts.
fm_worktree_collision_claimant_state() {  # <meta-file>
  local meta=$1 backend target state path default
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$target" ]; then
    state=$(fm_backend_agent_state "$backend" "$target")
  else
    state=unverified
  fi
  [ "$state" = alive ] && { printf 'alive'; return 0; }
  path=$(fm_meta_get "$meta" worktree)
  if [ -z "$path" ] || ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'gone'
    return 0
  fi
  case "$state" in
    dead|missing) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    printf 'unlanded'
    return 0
  fi
  default=$(fm_default_branch "$path" 2>/dev/null || true)
  if [ -n "$default" ]; then
    if git -C "$path" rev-parse --verify -q "$default" >/dev/null 2>&1 \
      && git -C "$path" merge-base --is-ancestor HEAD "$default" 2>/dev/null; then
      printf 'landed'
      return 0
    fi
    if git -C "$path" rev-parse --verify -q "origin/$default" >/dev/null 2>&1 \
      && git -C "$path" merge-base --is-ancestor HEAD "origin/$default" 2>/dev/null; then
      printf 'landed'
      return 0
    fi
  fi
  printf 'unlanded'
}

# One human-readable fragment per claimant state, used in the printed line.
fm_worktree_collision_claimant_desc() {  # <claimant-state>
  case "$1" in
    alive) printf 'process alive' ;;
    unknown) printf 'process state unknown' ;;
    unlanded) printf 'process gone, work not landed' ;;
    gone) printf 'finished: worktree already gone' ;;
    landed) printf 'finished: process gone, work landed' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_worktree_collision_lines: scan every state/*.meta under <state-dir> for
# worktree= paths claimed by more than one task record, and print one
# "WORKTREE_COLLISION: <kind> <path> claimed by <id> (<detail>), ..." line per
# colliding path, oldest kind first (live before stale). kind is `live` when
# two or more claimants classify as a hazard (alive, unknown, or unlanded
# above); otherwise `stale` - at most one hazardous claimant, so the
# collision is a finished task's leftover record rather than two tasks
# actually sharing a copy. Prints nothing when no path is claimed twice.
# Portable: no associative arrays, so this runs on bash 3.2 (macOS) too.
fm_worktree_collision_lines() {  # <state-dir>
  local state=$1 meta id path pairs dup_paths p ids_for_path
  local claimant_state desc claimant_line live_count kind
  [ -d "$state" ] || return 0
  pairs=$(
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      path=$(fm_meta_get "$meta" worktree)
      [ -n "$path" ] || continue
      printf '%s\t%s\n' "$path" "$id"
    done
  )
  [ -n "$pairs" ] || return 0
  dup_paths=$(printf '%s\n' "$pairs" | cut -f1 | sort | uniq -d)
  [ -n "$dup_paths" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ids_for_path=$(printf '%s\n' "$pairs" | awk -F'\t' -v p="$p" '$1 == p {print $2}' | sort)
    live_count=0
    claimant_line=
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      claimant_state=$(fm_worktree_collision_claimant_state "$state/$id.meta")
      case "$claimant_state" in
        alive|unknown|unlanded) live_count=$((live_count + 1)) ;;
      esac
      desc=$(fm_worktree_collision_claimant_desc "$claimant_state")
      claimant_line="${claimant_line:+$claimant_line, }$id ($desc)"
    done <<EOF
$ids_for_path
EOF
    if [ "$live_count" -ge 2 ]; then
      kind=live
    else
      kind=stale
    fi
    printf 'WORKTREE_COLLISION: %s %s claimed by %s\n' "$kind" "$p" "$claimant_line"
  done <<EOF
$dup_paths
EOF
}
