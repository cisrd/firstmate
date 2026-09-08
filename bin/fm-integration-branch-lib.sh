# shellcheck shell=bash
# The one resolver for "which branch does this project integrate on".
# Usage: . bin/fm-integration-branch-lib.sh
#
# A registry entry may carry the structured `integration-branch=<branch>`
# annotation; bin/fm-project-mode.sh owns that format and its validation, and is
# the only reader of the registry here. The declaration is authoritative for
# every path that has to pick a base branch - bin/fm-fleet-sync.sh's refresh
# target, the branch bin/fm-home-seed.sh and bin/fm-remote-home-provision.sh
# check out in a new clone, the base bin/fm-spawn.sh resets a pooled worktree to,
# using origin/<branch> with a remote or the verified local branch without one,
# the base bin/fm-review-diff.sh diffs a task against, and the branch
# bin/fm-teardown.sh tests landed content and unmerged local-only work against
# and bin/fm-merge-local.sh fast-forwards - so a project cannot be synced,
# worked, reviewed and landed against four different branches.
#
# A project that declares nothing keeps the legacy resolution, origin's default
# branch, so unannotated homes behave exactly as before. A declaration that is
# empty or not a valid branch name is never downgraded to that fallback: the
# query fails, its diagnostic reaches the caller's stderr, and every consumer
# refuses rather than working from a base the registry did not ask for.
# Callers pass the registry home through the same FM_HOME/FM_DATA_OVERRIDE
# variables bin/fm-project-mode.sh already reads.

FM_INTEGRATION_BRANCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Origin's default branch for <dir>: the tracked origin/HEAD, else a local main
# or master. Returns 1 when neither resolves, so a caller can refuse rather than
# guess a base.
default_branch() {  # <dir>
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# The branch <project-name> declares in the registry, or nothing when the entry
# uses the legacy format without a declaration. Returns non-zero, and lets the
# diagnostic through to stderr, when the entry declares an invalid branch.
declared_integration_branch() {  # <project-name>
  "$FM_INTEGRATION_BRANCH_LIB_DIR/fm-project-mode.sh" --integration-branch "$1"
}

# The branch new work, refreshes, reviews and landings must follow in <dir>: the
# declaration when the project makes one, otherwise origin's default branch.
# Returns 1 when the declaration is invalid, or when neither resolves.
integration_branch() {  # <dir> <project-name>
  local declared
  declared=$(declared_integration_branch "$2") || return 1
  if [ -n "$declared" ]; then
    printf '%s\n' "$declared"
    return 0
  fi
  default_branch "$1"
}
