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
# Two independent axes decide a collision, and each is owned by exactly one
# classifier below. PROCESS STATE (alive/unknown/dead, one verdict per record,
# from the backend) alone decides the kind: `live` means two or more claimants'
# processes are concurrently hazardous, `stale` means at most one is. PATH
# STATE (gone/landed/unlanded, one verdict per colliding path, from git) never
# changes the kind - unlanded work is not a kind trigger; it is reported as a
# caveat on the stale line instead, so the hazard is never silent even though
# it is not called `live`. The path fact belongs to the path, not to any one
# claimant, so it is never counted once per record.
#
# Path state does modulate whether a collision is reported at all, asymmetrically
# and in one direction only: on a `gone` path an `unknown` process verdict stops
# counting as a hazard, because absence of evidence must not manufacture a
# collision over a worktree that no longer exists, while a confirmed `alive`
# claimant is never suppressed by a gone path - confirmed evidence always
# outranks a missing directory, and a live agent whose worktree is unaccounted
# for is the most interesting anomaly this detector can surface.
#
# fm_worktree_collision_path_state classifies the shared worktree itself from
# cheap, entirely local git reads (no network):
#   gone     - the recorded path is no longer an inspectable git worktree (a
#              prior teardown already removed it). Nothing is left to lose.
#   unlanded - the path has uncommitted changes, or its HEAD is not proven
#              reachable from the project's default branch. Discarding this
#              copy could lose real work, whichever claimant produced it.
#   landed   - the worktree is clean and its HEAD is reachable from the
#              project's default branch. Nothing at the path is at risk.
fm_worktree_collision_path_state() {  # <worktree-path>
  local path=$1 default
  if [ -z "$path" ] || ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'gone'
    return 0
  fi
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

# fm_worktree_collision_claimant_process classifies ONE claimant's agent
# process from its own recorded backend endpoint alone - no git reads, so a
# claimant is never credited or blamed for the shared path's content:
#   alive   - fm_backend_agent_state reports the recorded backend/target alive.
#             A hazard: the record still owns the path.
#   unknown - the process state is ambiguous, unreadable, or unverified (or the
#             record has no usable target). Cannot be proven finished, so it is
#             treated as a hazard rather than guessed away - unless the shared
#             path is already gone, where the caller suppresses it.
#   dead    - the process is confirmed dead or missing. This record alone is
#             never a hazard; whatever is left at the path is the path's fact,
#             reported by fm_worktree_collision_path_state instead.
fm_worktree_collision_claimant_process() {  # <meta-file>
  local meta=$1 backend target state
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$target" ]; then
    state=$(fm_backend_agent_state "$backend" "$target")
  else
    state=unverified
  fi
  case "$state" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# One human-readable fragment per claimant process state, used in the printed
# line. Each fragment describes only that claimant's own process - the shared
# path's landed/unlanded state is reported once for the line, never here.
fm_worktree_collision_claimant_desc() {  # <claimant-process-state>
  case "$1" in
    alive) printf 'process alive' ;;
    unknown) printf 'process state unknown' ;;
    dead) printf 'process gone' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_worktree_collision_lines: scan every state/*.meta under <state-dir> for
# worktree= paths claimed by more than one task record, and print one
# "WORKTREE_COLLISION: <kind> <path> claimed by <id> (<detail>), ..." line per
# colliding path, in path order (the paths are sorted, so a stale collision can
# print before a live one). kind is `live` when two or more claimants are
# hazards on their own process state (alive, or unknown over a path that still
# exists); otherwise `stale` - at most one hazardous claimant, so the collision
# is a finished task's leftover record rather than two tasks actually sharing a
# copy. Unlanded shared work never promotes the kind: a `stale` line whose
# shared path still holds unlanded work carries one path-level caveat instead,
# so a leftover record is never cleaned up blind. A gone path whose every
# claimant is unknown is not reported at all - nothing remains on disk and
# nothing is known about any claimant, so there is no collision to manufacture.
# Scope: LOCAL task records only. A record carrying remote_host= is skipped,
# because its worktree= is a path on another machine that is only unique when
# host-qualified (bin/fm-secondmate-registry-lib.sh keys those homes as
# ssh:<host>:<home>), and neither the local git probe nor the local backend
# probe can say anything true about it - so this check does NOT cover remote
# secondmates, whose dedicated homes are never pooled or recycled anyway.
# Prints nothing when no path is claimed twice.
# Portable: no associative arrays, so this runs on bash 3.2 (macOS) too.
fm_worktree_collision_lines() {  # <state-dir>
  local state=$1 meta id path pairs dup_paths p ids_for_path
  local proc_state desc claimant_line live_count kind path_state caveat
  local unknown_count claimant_count
  [ -d "$state" ] || return 0
  pairs=$(
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      path=$(fm_meta_get "$meta" worktree)
      [ -n "$path" ] || continue
      [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
      printf '%s\t%s\n' "$path" "$id"
    done
  )
  [ -n "$pairs" ] || return 0
  dup_paths=$(printf '%s\n' "$pairs" | cut -f1 | sort | uniq -d)
  [ -n "$dup_paths" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ids_for_path=$(printf '%s\n' "$pairs" | awk -F'\t' -v p="$p" '$1 == p {print $2}' | sort)
    path_state=$(fm_worktree_collision_path_state "$p")
    live_count=0
    unknown_count=0
    claimant_count=0
    claimant_line=
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      claimant_count=$((claimant_count + 1))
      proc_state=$(fm_worktree_collision_claimant_process "$state/$id.meta")
      case "$proc_state" in
        alive) live_count=$((live_count + 1)) ;;
        unknown)
          unknown_count=$((unknown_count + 1))
          if [ "$path_state" != gone ]; then
            live_count=$((live_count + 1))
          fi
          ;;
      esac
      desc=$(fm_worktree_collision_claimant_desc "$proc_state")
      claimant_line="${claimant_line:+$claimant_line, }$id ($desc)"
    done <<EOM
$ids_for_path
EOM
    if [ "$path_state" = gone ] && [ "$unknown_count" -eq "$claimant_count" ]; then
      continue
    fi
    caveat=
    if [ "$live_count" -ge 2 ]; then
      kind=live
    else
      kind=stale
      if [ "$path_state" = unlanded ]; then
        caveat=' - shared path still has unlanded work, do not discard'
      fi
    fi
    printf 'WORKTREE_COLLISION: %s %s claimed by %s%s\n' "$kind" "$p" "$claimant_line" "$caveat"
  done <<EOM
$dup_paths
EOM
}
