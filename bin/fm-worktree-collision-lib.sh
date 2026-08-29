# shellcheck shell=bash
# Worktree double-registration detection: two state/*.meta records claiming
# the same worktree= path.
# Usage: . bin/fm-worktree-collision-lib.sh
#
# Requires bin/fm-backend.sh (fm_meta_get, fm_backend_of_meta,
# fm_backend_target_of_meta, fm_backend_agent_alive) and bin/fm-tangle-lib.sh
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
# Nothing suppresses reporting. Every path claimed by more than one local
# record prints exactly one line, whatever its path state and whatever its
# claimants' process states, and an unverifiable process state counts as a
# hazard unconditionally - on a vanished path just as on a live one. Absence of
# evidence is itself something the output must SAY rather than stay silent
# about, so both unverifiable facts are surfaced explicitly instead: the
# claimant detail names the backend whose state could not be verified, and a
# path that no longer exists carries its own caveat on the line.
#
# fm_worktree_collision_path_state classifies the shared worktree itself from
# cheap, entirely local git reads (no network):
#   gone     - the recorded path is no longer an inspectable git worktree (a
#              prior teardown already removed it). Nothing is left to lose, but
#              the line says so - every claimant of a vanished path is claiming
#              something that is not there.
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
# claimant is never credited or blamed for the shared path's content. The
# alive/dead/unknown mapping itself has one owner, fm_backend_agent_alive; this
# adds only the guard for a record with no usable target, and treats an
# unreadable endpoint the same way that helper's own callers do:
#   alive   - the recorded backend/target is reported alive. A hazard: the
#             record still owns the path.
#   unknown - the process state is ambiguous, unreadable, or unverified (or the
#             record has no usable target). Cannot be proven finished, so it is
#             always treated as a hazard rather than guessed away, and the
#             printed detail names the backend that could not answer.
#   dead    - the process is confirmed dead or missing. This record alone is
#             never a hazard; whatever is left at the path is the path's fact,
#             reported by fm_worktree_collision_path_state instead.
fm_worktree_collision_claimant_process() {  # <meta-file>
  local meta=$1 target
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'unknown'; return 0; }
  fm_backend_agent_alive "$(fm_backend_of_meta "$meta")" "$target" 2>/dev/null \
    || printf 'unknown'
}

# One human-readable fragment per claimant process state, used in the printed
# line. Each fragment describes only that claimant's own process - the shared
# path's landed/unlanded/gone state is reported once for the line, never here.
# An unknown verdict names the backend that could not answer, so the reader can
# tell an unsupported execution engine from a backend that is merely unreachable
# right now.
fm_worktree_collision_claimant_desc() {  # <claimant-process-state> [backend]
  case "$1" in
    alive) printf 'process alive' ;;
    unknown)
      if [ -n "${2:-}" ]; then
        printf 'process state unknown (backend=%s not verifiable)' "$2"
      else
        printf 'process state unknown'
      fi
      ;;
    dead) printf 'process gone' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_worktree_collision_lines: scan every state/*.meta under <state-dir> for
# worktree= paths claimed by more than one task record, and print one
# "WORKTREE_COLLISION: <kind> <path> claimed by <id> (<detail>), ..." line per
# colliding path, in path order (the paths are sorted, so a stale collision can
# print before a live one). kind is `live` when two or more claimants are
# hazards on their own process state (alive or unknown); otherwise `stale` - at
# most one hazardous claimant, so the collision is a finished task's leftover
# record rather than two tasks actually sharing a copy. Path state never
# promotes the kind and never withholds a line; it appends at most one caveat:
# a `stale` line whose shared path still holds unlanded work says so, so a
# leftover record is never cleaned up blind, and a path that no longer exists
# says so on either kind, because nothing else in the line reveals it.
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
  local proc_state desc desc_backend claimant_line live_count kind path_state caveat
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
    claimant_line=
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      proc_state=$(fm_worktree_collision_claimant_process "$state/$id.meta")
      case "$proc_state" in
        alive|unknown) live_count=$((live_count + 1)) ;;
      esac
      desc_backend=
      if [ "$proc_state" = unknown ]; then
        desc_backend=$(fm_backend_of_meta "$state/$id.meta")
      fi
      desc=$(fm_worktree_collision_claimant_desc "$proc_state" "$desc_backend")
      claimant_line="${claimant_line:+$claimant_line, }$id ($desc)"
    done <<EOM
$ids_for_path
EOM
    caveat=
    if [ "$live_count" -ge 2 ]; then
      kind=live
    else
      kind=stale
      if [ "$path_state" = unlanded ]; then
        caveat=' - shared path still has unlanded work, do not discard'
      fi
    fi
    if [ "$path_state" = gone ]; then
      caveat=' - shared worktree no longer exists at that path'
    fi
    printf 'WORKTREE_COLLISION: %s %s claimed by %s%s\n' "$kind" "$p" "$claimant_line" "$caveat"
  done <<EOM
$dup_paths
EOM
}
