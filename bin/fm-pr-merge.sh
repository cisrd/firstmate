#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# GitHub direct merges default to --squash when the caller names no method.
# `--queue` is the canonical merge-queue request and invokes GitHub's supported
# GraphQL enqueuePullRequest mutation rather than the gh-axi merge parser.
# One parser owns every queue spelling and all caller-argument interpretation.
# It refuses repeated queue tokens, a queue token mixed with an explicit merge
# strategy, and any extra argument the enqueue mutation cannot honour.
# Before enqueue, one live GraphQL read proves the URL-derived repository is
# writable, the pull request is open, its status-check rollup is not red, and
# its head still matches the head fm-pr-check recorded.
# enqueuePullRequest receives that same head as expectedHeadOid, so a later push
# makes the mutation fail instead of queueing a changed identity.
# The base must have an effective merge_queue rule, and a successful mutation
# must return a queue entry before an independent live read confirms membership.
# A direct merge that discovers a queue-governed base prints one runnable
# `--queue` retry, unless the caller already supplied any accepted queue token.
# Rules that are absent, unreadable, conflicting, or unrecognised remain
# distinct outcomes, but none can produce a retry the parser rejects.
# The gh-axi merge abstraction still owns non-queue GitHub merges.
# After it returns, GitHub's live state is read back and accepted only when the
# pull request is merged or in the merge queue.
# gh's GraphQL API supplies the queue-aware read when gh is on PATH; when gh is
# absent or its read fails, gh-axi's own view can still prove a landed merge.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose. The observed state is judged the same way whichever
# read produced it, and a refusal built on the gh-axi view says the merge queue
# could not be observed at all rather than implying an unqueued pull request.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
# Queue tokens are refused up front on GitLab, where no glab flag spells them.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab because the head comes only from the live read.
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
shift 2
[ "${1:-}" = "--" ] && shift

# Parse the caller's merge arguments once for every provider path.
# This is the single owner of queue-token grammar and of how caller arguments
# are interpreted. Queue tokens are Firstmate flags,
# never forge CLI flags. A repeated queue token, a queue token mixed with an
# explicit strategy, or an argument the GraphQL enqueue path cannot honour is
# refused rather than dropped or forwarded with changed meaning.
FM_PR_CALLER_HAS_METHOD=false
FM_PR_CALLER_METHOD=
FM_PR_CALLER_AUTO=false
FM_PR_CALLER_QUEUE=false
FM_PR_CALLER_QUEUE_COUNT=0
FM_PR_CALLER_QUEUE_TOKENS=
FM_PR_CALLER_EXPLICIT_METHODS=
FM_PR_CALLER_FORWARD=()
fm_pr_parse_merge_args() {
  local arg pending_method=false unsupported=''
  FM_PR_CALLER_HAS_METHOD=false
  FM_PR_CALLER_METHOD=
  FM_PR_CALLER_AUTO=false
  FM_PR_CALLER_QUEUE=false
  FM_PR_CALLER_QUEUE_COUNT=0
  FM_PR_CALLER_QUEUE_TOKENS=
  FM_PR_CALLER_EXPLICIT_METHODS=
  FM_PR_CALLER_FORWARD=()

  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    if [ "$pending_method" = true ]; then
      FM_PR_CALLER_METHOD=$arg
      FM_PR_CALLER_EXPLICIT_METHODS="${FM_PR_CALLER_EXPLICIT_METHODS:+$FM_PR_CALLER_EXPLICIT_METHODS }--method $arg"
      FM_PR_CALLER_FORWARD+=(--method "$arg")
      pending_method=false
      continue
    fi
    case "$arg" in
      --queue)
        FM_PR_CALLER_HAS_METHOD=true
        FM_PR_CALLER_METHOD=queue
        FM_PR_CALLER_QUEUE=true
        FM_PR_CALLER_QUEUE_COUNT=$((FM_PR_CALLER_QUEUE_COUNT + 1))
        FM_PR_CALLER_QUEUE_TOKENS="${FM_PR_CALLER_QUEUE_TOKENS:+$FM_PR_CALLER_QUEUE_TOKENS }$arg"
        ;;
      --method)
        FM_PR_CALLER_HAS_METHOD=true
        pending_method=true
        ;;
      --squash|--merge|--rebase|--method=*)
        FM_PR_CALLER_HAS_METHOD=true
        FM_PR_CALLER_METHOD=${arg#--}
        FM_PR_CALLER_METHOD=${FM_PR_CALLER_METHOD#method=}
        FM_PR_CALLER_EXPLICIT_METHODS="${FM_PR_CALLER_EXPLICIT_METHODS:+$FM_PR_CALLER_EXPLICIT_METHODS }$arg"
        FM_PR_CALLER_FORWARD+=("$arg")
        ;;
      --auto)
        FM_PR_CALLER_AUTO=true
        FM_PR_CALLER_FORWARD+=("$arg")
        ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) FM_PR_CALLER_AUTO=true ;;
          *) FM_PR_CALLER_AUTO=false ;;
        esac
        FM_PR_CALLER_FORWARD+=("$arg")
        ;;
      --disable-auto)
        FM_PR_CALLER_AUTO=false
        FM_PR_CALLER_FORWARD+=("$arg")
        ;;
      *) FM_PR_CALLER_FORWARD+=("$arg") ;;
    esac
  done
  if [ "$pending_method" = true ]; then
    FM_PR_CALLER_EXPLICIT_METHODS="${FM_PR_CALLER_EXPLICIT_METHODS:+$FM_PR_CALLER_EXPLICIT_METHODS }--method"
    FM_PR_CALLER_FORWARD+=(--method)
  fi

  if [ "$FM_PR_CALLER_QUEUE_COUNT" -gt 1 ]; then
    printf 'error: extra merge arguments repeat the queue request (%s); pass exactly one queue token\n' \
      "$FM_PR_CALLER_QUEUE_TOKENS" >&2
    return 1
  fi
  if [ "$FM_PR_CALLER_QUEUE" = true ] && [ -n "$FM_PR_CALLER_EXPLICIT_METHODS" ]; then
    printf 'error: extra merge arguments must not combine a queue request (%s) with an explicit merge strategy (%s)\n' \
      "$FM_PR_CALLER_QUEUE_TOKENS" "$FM_PR_CALLER_EXPLICIT_METHODS" >&2
    return 1
  fi
  if [ "$FM_PR_CALLER_QUEUE" = true ]; then
    for arg in "${FM_PR_CALLER_FORWARD[@]+"${FM_PR_CALLER_FORWARD[@]}"}"; do
      case "$arg" in
        --auto|--auto=[tT]|--auto=[tT][rR][uU][eE]|--auto=1) ;;
        *) unsupported="${unsupported:+$unsupported }$arg" ;;
      esac
    done
    if [ -n "$unsupported" ]; then
      printf 'error: queue enqueue does not support extra merge arguments (%s)\n' "$unsupported" >&2
      return 1
    fi
  fi
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
fm_pr_parse_merge_args "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1
if [ "$PROVIDER" = gitlab ] && [ "$FM_PR_CALLER_QUEUE" = true ]; then
  echo "error: extra merge arguments must not request GitHub's merge queue on GitLab" >&2
  exit 1
fi

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view when available; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for the merge abstraction.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

FM_PR_GITHUB_NODE_ID=
FM_PR_GITHUB_HEAD=

# Read the exact PR identity and repository authority immediately before a
# queue enqueue. The head is also passed to enqueuePullRequest as
# expectedHeadOid, so a push after this read makes the mutation refuse rather
# than queueing code this run did not inspect. A red rollup is refused before
# enqueue, and repository READ permission cannot masquerade as merge authority.
github_read_enqueue_preflight() {
  local fields line recorded_head
  local total=0 named=0 state='' merged='' queued='' base=''
  local node='' head='' checks='' permission=''
  command -v gh >/dev/null 2>&1 || {
    echo "error: enqueueing a GitHub pull request requires gh on PATH" >&2
    return 1
  }
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){viewerPermission pullRequest(number:$number){id state merged isInMergeQueue baseRefName headRefOid commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository as $r | $r.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // ""), "node=" + (.id // ""), "head=" + (.headRefOid // ""), "checks=" + (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"), "permission=" + ($r.viewerPermission // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    echo "error: could not read the GitHub pull request identity and merge authority before enqueueing" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      node=*) node=${line#node=} ;;
      head=*) head=${line#head=} ;;
      checks=*) checks=${line#checks=} ;;
      permission=*) permission=${line#permission=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 8 ] || [ "$total" -ne 8 ] \
    || { ! { [ "$state" = OPEN ] && [ "$merged" = false ]; } \
      && ! { [ "$state" = MERGED ] && [ "$merged" = true ]; }; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ] || [ -z "$node" ] || ! fm_pr_head_valid "$head"; then
    echo "error: the GitHub pull request identity is not a readable enqueue candidate" >&2
    return 1
  fi
  case "$permission" in
    WRITE|MAINTAIN|ADMIN) ;;
    *)
      printf 'error: refusing to enqueue %s: repository %s/%s grants only %s permission, not merge authority\n' \
        "$URL" "$PR_OWNER" "$PR_REPO" "${permission:-unreadable}" >&2
      return 1
      ;;
  esac
  case "$checks" in
    FAILURE|ERROR)
      printf 'error: refusing to enqueue %s: the current head %s has a red status-check rollup (%s)\n' \
        "$URL" "$head" "$checks" >&2
      return 1
      ;;
    SUCCESS|PENDING|EXPECTED|NONE) ;;
    *)
      printf 'error: refusing to enqueue %s: the status-check rollup is unreadable (%s)\n' \
        "$URL" "${checks:-empty}" >&2
      return 1
      ;;
  esac
  recorded_head=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$recorded_head" ] && [ "$recorded_head" != "$head" ]; then
    printf 'error: refusing to enqueue %s: recorded head %s changed to %s before the queue request\n' \
      "$URL" "$recorded_head" "$head" >&2
    return 1
  fi
  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
  FM_PR_GITHUB_NODE_ID=$node
  FM_PR_GITHUB_HEAD=$head
}

# Invoke GitHub's supported queue operation. The mutation result must name a
# queue entry, then the ordinary live outcome read independently confirms queue
# membership. The expected head preserves the same changed-identity boundary
# that direct merges obtain from the forge CLI.
github_enqueue_pull_request() {
  local fields line entry_id='' entry_state='' total=0 named=0
  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='mutation($pullRequestId:ID!,$expectedHeadOid:GitObjectID!){enqueuePullRequest(input:{pullRequestId:$pullRequestId,expectedHeadOid:$expectedHeadOid}){mergeQueueEntry{id state}}}' \
    -f "pullRequestId=$FM_PR_GITHUB_NODE_ID" \
    -f "expectedHeadOid=$FM_PR_GITHUB_HEAD" \
    --jq '.data.enqueuePullRequest.mergeQueueEntry | "entry_id=" + (.id // ""), "entry_state=" + (.state // "")' \
    2>&1); then
    [ -z "$fields" ] || printf '%s\n' "$fields" >&2
    echo "error: GitHub rejected enqueuePullRequest; nothing was reported as queued" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      entry_id=*) entry_id=${line#entry_id=} ;;
      entry_state=*) entry_state=${line#entry_state=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] || [ -z "$entry_id" ]; then
    echo "error: enqueuePullRequest returned no readable merge-queue entry" >&2
    return 1
  fi
  case "$entry_state" in
    QUEUED|AWAITING_CHECKS|MERGEABLE|UNMERGEABLE|LOCKED) ;;
    *)
      printf 'error: enqueuePullRequest returned an unknown merge-queue state (%s)\n' \
        "${entry_state:-empty}" >&2
      return 1
      ;;
  esac
}

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

FM_PR_GITHUB_AUTO_REQUESTED=$FM_PR_CALLER_AUTO
FM_PR_GITHUB_MERGE_ACCEPTED=false

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# The one retry a queue-governed base accepts. `--queue` is parsed by this
# script and invokes enqueuePullRequest directly, so the command names neither
# a merge strategy nor gh-axi's unrelated auto-merge flag.
github_queue_retry_command() {
  printf '%s %s %s -- --queue' "$0" "$ID" "$URL"
}

# A caller who supplied any accepted queue spelling already requested the one
# operation the retry would perform. Never hand that same operation back under
# either the canonical spelling or a legacy alias.
github_caller_already_ran_queue_retry() {
  [ "$FM_PR_CALLER_QUEUE" = true ]
}

github_report_queue_rules() {
  local queue_method methods_display situation
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      printf -v situation \
        'base branch %s requires the merge queue, which sets the merge method (%s) itself and refuses an explicit strategy' \
        "$FM_PR_GITHUB_BASE" "$queue_method"
      ;;
    conflicting)
      printf -v situation \
        'base branch %s has conflicting merge queue methods (%s), so which one it would apply is ambiguous; the merge queue applies its own without being told' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }"
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf -v situation \
        'base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises; the merge queue applies its own without being told' \
        "$FM_PR_GITHUB_BASE" "$methods_display"
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      return 0
      ;;
    *)
      return 0
      ;;
  esac
  if github_caller_already_ran_queue_retry; then
    printf 'error: %s; enqueuePullRequest is the one supported queue operation and this run already requested it, so no different retry exists to name: the outcome reported above for %s is the blocking cause, and re-check the pull request'"'"'s merge queue state before running the same command again\n' \
      "$situation" "$URL" >&2
  else
    printf 'error: %s; retry with: %s\n' "$situation" "$(github_queue_retry_command)" >&2
  fi
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
record_pr_metadata || exit 1

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if [ "$FM_PR_CALLER_QUEUE" = true ]; then
      github_read_enqueue_preflight || exit 1
      if [ "$FM_PR_GITHUB_MERGED" = true ]; then
        : # The ordinary outcome path below records the already-landed result.
      elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
        printf 'verified: %s is already queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
          "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
        exit 0
      else
        github_read_queue_method
      case "$FM_PR_GITHUB_QUEUE_STATUS" in
        single|conflicting|unrecognised) ;;
        none)
          printf 'error: refusing to enqueue %s: base branch %s has no effective merge-queue rule\n' \
            "$URL" "$FM_PR_GITHUB_BASE" >&2
          exit 1
          ;;
        *)
          printf 'error: refusing to enqueue %s: the merge-queue rule for base branch %s could not be read\n' \
            "$URL" "$FM_PR_GITHUB_BASE" >&2
          exit 1
          ;;
      esac
        enqueue_status=0
        github_enqueue_pull_request || enqueue_status=$?
        if [ "$enqueue_status" -ne 0 ]; then
          if github_read_outcome; then
            if [ "$FM_PR_GITHUB_QUEUED" = true ]; then
              printf 'actionable: enqueuePullRequest for %s failed, but the pull request now reads as queued\n' \
                "$URL" >&2
            else
              github_report_unmerged_outcome
            fi
          fi
          exit "$enqueue_status"
        fi
      fi
    else
      if [ "$FM_PR_CALLER_HAS_METHOD" != true ]; then
        merge_args=(--squash)
      fi
      if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
        "${merge_args[@]+"${merge_args[@]}"}" \
        "${FM_PR_CALLER_FORWARD[@]+"${FM_PR_CALLER_FORWARD[@]}"}" 2>&1); then
        FM_PR_GITHUB_MERGE_ACCEPTED=true
      else
        merge_status=$?
        [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
        if github_read_outcome; then
          if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
            github_report_unmerged_outcome
          else
            printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
              "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
          fi
        fi
        exit "$merge_status"
      fi
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
