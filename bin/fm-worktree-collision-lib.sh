# shellcheck shell=bash
# Worktree double-registration detection: two state/*.meta records claiming
# the same worktree= path. This header is the ONE owner of the check's
# contract; bin/fm-bootstrap.sh states only the emitted line format, and
# .agents/skills/bootstrap-diagnostics/SKILL.md only what to do about a line.
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
# Every emitted phrase is held to one rule: say exactly what the probe behind
# it proves, and no more. A backend that answered is never described as
# unreachable, and a path that could not be inspected is never described as
# empty.
#
# Two independent axes decide a collision, and each is owned by exactly one
# classifier below. PROCESS STATE (one verdict per record, from the backend)
# alone decides the kind: `live` means two or more claimants are still hazards,
# `stale` means at most one is. PATH STATE (one verdict per colliding path,
# from git) never changes the kind and never withholds a line; it only appends
# one caveat naming what is at risk at the shared path. The path fact belongs
# to the path, not to any one claimant, so it is never counted once per record.
#
# Nothing suppresses reporting. Every path claimed by more than one local
# record prints exactly one line, whatever either axis says, because absence of
# evidence is itself something the output must SAY rather than stay silent
# about.
#
# fm_worktree_collision_path_state classifies the shared worktree itself from
# cheap, entirely local git reads (no network). Exactly three verdicts are
# conclusions, and every probe that could not reach one shares a single
# fourth:
#   missing              - the path's absence was actually observed: nothing is
#                          there, and the nearest existing ancestor directory
#                          was searchable, so the absence is a fact rather than
#                          a stat that was refused. The only verdict that
#                          proves there is nothing left to lose there, and so
#                          the only one whose caveat carries no do-not-discard
#                          clause.
#   unlanded             - a probe answered, and its answer was that work is at
#                          risk: the worktree has uncommitted changes, or the
#                          ancestry check ran and said HEAD is not reachable
#                          from the project's default branch.
#   landed               - the worktree is clean and its HEAD was checked and
#                          found reachable from the project's default branch.
#                          Nothing at the path is at risk.
#   unverifiable:<cause> - a probe could not answer at all, so the path is
#                          NEITHER landed nor unlanded, and the emitted caveat
#                          says so while naming <cause>. This is the one shared
#                          mechanism for every unanswerable probe; new causes
#                          are added to it rather than given a branch of their
#                          own. Current causes:
#                            not-a-worktree  - git resolved no work tree there
#                              (a dangling .git pointer, a bare repository, a
#                              plain file, a path inside a .git dir), the same
#                              --show-toplevel condition bin/fm-teardown.sh's
#                              own inspectable_git_worktree refuses on.
#                            worktree-state  - the working-tree probe itself
#                              failed (a truncated or unreadable .git/index).
#                              It printed no changes because it read none,
#                              which is not the same fact as a clean tree.
#                            default-branch  - the ancestry check could not be
#                              performed: no origin/HEAD and no local
#                              main/master to resolve a default branch, no ref
#                              for the resolved name, or a shallow or grafted
#                              history that made merge-base error out.
#                            path-unreadable - the path could not be stat'ed
#                              because an ancestor directory is not searchable,
#                              so its absence was refused rather than observed.
# The rule those verdicts encode, in both directions: a probe that could not
# run proves nothing, so it may never reach `landed` or `missing` (a falsely
# reassuring claim) and may never claim `unlanded` work it did not see (a
# falsely alarming one). Safety does not change either way - every verdict
# except `missing` carries the same do-not-discard clause.
fm_worktree_collision_path_state() {  # <worktree-path>
  local path=$1 default top status_out ref rc answered=0
  if [ -z "$path" ] || { [ ! -e "$path" ] && [ ! -L "$path" ]; }; then
    if [ -n "$path" ] && ! fm_worktree_collision_absence_observed "$path"; then
      printf 'unverifiable:path-unreadable'
      return 0
    fi
    printf 'missing'
    return 0
  fi
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$top" ] || [ ! -d "$top" ]; then
    printf 'unverifiable:not-a-worktree'
    return 0
  fi
  if ! status_out=$(git -C "$path" status --porcelain 2>/dev/null); then
    printf 'unverifiable:worktree-state'
    return 0
  fi
  if [ -n "$status_out" ]; then
    printf 'unlanded'
    return 0
  fi
  default=$(fm_default_branch "$path" 2>/dev/null || true)
  if [ -n "$default" ]; then
    for ref in "$default" "origin/$default"; do
      git -C "$path" rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
      if git -C "$path" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
        printf 'landed'
        return 0
      else
        rc=$?
      fi
      if [ "$rc" = 1 ]; then
        answered=1
      fi
    done
  fi
  if [ "$answered" = 1 ]; then
    printf 'unlanded'
    return 0
  fi
  printf 'unverifiable:default-branch'
}

# True only when a path's absence was OBSERVED rather than refused: walk up to
# the nearest ancestor that can be stat'ed and require it to be a searchable
# directory. A chmod-000 ancestor makes `[ ! -e ]` true for a worktree that is
# still there, holding work, so absence is a claim this has to earn.
fm_worktree_collision_absence_observed() {  # <path>
  local dir=$1
  while [ "$dir" != / ] && [ "$dir" != . ]; do
    dir=$(dirname "$dir")
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      { [ -d "$dir" ] && [ -x "$dir" ]; }
      return
    fi
  done
  [ -x "$dir" ]
}

# One caveat per path state, appended to the printed line whatever its kind -
# the risk at a shared path does not depend on how many processes are hazards.
# Every `unverifiable:<cause>` verdict shares one sentence, built here once:
# the cause names which probe could not answer, and the same do-not-discard
# clause every non-landed verdict carries closes it.
fm_worktree_collision_path_caveat() {  # <path-state>
  local cause
  case "$1" in
    landed) ;;
    unlanded) printf ' - shared path still has unlanded work, do not discard' ;;
    missing) printf ' - shared worktree no longer exists at that path' ;;
    unverifiable:*)
      case "${1#unverifiable:}" in
        not-a-worktree) cause='is not an inspectable git worktree' ;;
        worktree-state) cause='is a git worktree whose working-tree state could not be read' ;;
        default-branch) cause="is a git worktree whose HEAD could not be checked against the project's default branch" ;;
        path-unreadable) cause='could not be examined because an ancestor directory is not searchable' ;;
        *) cause='could not be examined' ;;
      esac
      printf ' - shared path %s, so whether work would be lost cannot be verified, do not discard' "$cause"
      ;;
  esac
}

# fm_worktree_collision_claimant_process reports ONE claimant's agent process
# from its own recorded backend endpoint alone - no git reads, so a claimant is
# never credited or blamed for the shared path's content. It passes through
# fm_backend_agent_state's own vocabulary verbatim (alive, dead, missing,
# ambiguous, unreadable, unverified - that function's header owns those
# meanings), because collapsing them here would throw away the distinction the
# printed line has to make between a backend that answered and one that could
# not. `no-endpoint` is this function's own addition, for a record carrying no
# usable target at all.
# Per that contract only `dead` and `missing` are confident finished verdicts,
# so every other value is a hazard for the kind.
fm_worktree_collision_claimant_process() {  # <meta-file>
  local meta=$1 target
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'no-endpoint'; return 0; }
  fm_backend_agent_state "$(fm_backend_of_meta "$meta")" "$target" 2>/dev/null \
    || printf 'unreadable'
}

# One human-readable fragment per claimant process state, used in the printed
# line. Each fragment describes only that claimant's own process - the shared
# path's state is reported once for the line, never here. An unverified verdict
# says the backend has no recovery classifier, an ambiguous or unreadable one
# quotes the verdict the backend actually returned, and a record with no
# endpoint blames no backend at all, so the reader is never sent to check a
# backend that answered correctly.
fm_worktree_collision_claimant_desc() {  # <claimant-process-state> [backend]
  local state=$1 backend=${2:-}
  case "$state" in
    alive) printf 'process alive' ;;
    dead|missing) printf 'process gone' ;;
    no-endpoint) printf 'process state unknown (record has no endpoint)' ;;
    *)
      if [ -z "$backend" ]; then
        printf 'process state unknown (%s)' "$state"
      elif [ "$state" = unverified ]; then
        printf 'process state unknown (backend=%s has no recovery classifier)' "$backend"
      else
        printf 'process state unknown (backend=%s reported %s)' "$backend" "$state"
      fi
      ;;
  esac
}

# fm_worktree_collision_lines: scan every state/*.meta under <state-dir> for
# worktree= paths claimed by more than one task record, and print one
# "WORKTREE_COLLISION: <kind> <path> claimed by <id> (<detail>), ...<caveat>"
# line per colliding path, in path order (the paths are sorted, so a stale
# collision can print before a live one). kind is `live` when two or more
# claimants are hazards on their own process state; otherwise `stale` - at most
# one hazardous claimant, so the collision is a finished task's leftover record
# rather than two tasks actually sharing a copy. The caveat is the path axis
# and rides either kind.
# Scope: LOCAL task records only. A record carrying remote_host= is skipped,
# because its worktree= is a path on another machine that is only unique when
# host-qualified (bin/fm-secondmate-registry-lib.sh keys those homes as
# ssh:<host>:<home>), and neither the local git probe nor the local backend
# probe can say anything true about it - so this check does NOT cover remote
# secondmates, whose dedicated homes are never pooled or recycled anyway.
# Prints nothing when no path is claimed twice. The scan is a snapshot, and
# this check holds no fleet lock, so a record torn down between the snapshot
# and its own process probe is dropped rather than reported as an unverifiable
# hazard: a path left with fewer than two surviving records is no longer a
# collision and prints nothing.
# Portable: no associative arrays, so this runs on bash 3.2 (macOS) too.
fm_worktree_collision_lines() {  # <state-dir>
  local state=$1 meta id path pairs dup_paths p ids_for_path
  local proc_state desc claimant_line claimant_count live_count kind path_state caveat
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
    ids_for_path=$(printf '%s\n' "$pairs" | fm_collision_p="$p" awk -F'\t' '$1 == ENVIRON["fm_collision_p"] {print $2}' | sort)
    path_state=$(fm_worktree_collision_path_state "$p")
    caveat=$(fm_worktree_collision_path_caveat "$path_state")
    live_count=0
    claimant_count=0
    claimant_line=
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ -f "$state/$id.meta" ] || continue
      claimant_count=$((claimant_count + 1))
      proc_state=$(fm_worktree_collision_claimant_process "$state/$id.meta")
      case "$proc_state" in
        dead|missing) ;;
        *) live_count=$((live_count + 1)) ;;
      esac
      desc=$(fm_worktree_collision_claimant_desc "$proc_state" "$(fm_backend_of_meta "$state/$id.meta")")
      claimant_line="${claimant_line:+$claimant_line, }$id ($desc)"
    done <<EOM
$ids_for_path
EOM
    [ "$claimant_count" -ge 2 ] || continue
    if [ "$live_count" -ge 2 ]; then
      kind=live
    else
      kind=stale
    fi
    printf 'WORKTREE_COLLISION: %s %s claimed by %s%s\n' "$kind" "$p" "$claimant_line" "$caveat"
  done <<EOM
$dup_paths
EOM
}
