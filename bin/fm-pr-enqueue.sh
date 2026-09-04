#!/usr/bin/env bash
# Re-queue a GitHub pull request that the merge-queue poll reported as ejected.
# Usage: fm-pr-enqueue.sh <task-id> <reason>
#
# The watcher wakes firstmate with dequeued:<reason>:<timestamp>. This script is
# the response: it calls enqueuePullRequest when the live pull request is still
# open, not a draft, not already in the queue, mergeable, with green checks and
# resolved review threads, and the ejection reason is a transient check failure
# in either the forge's or firstmate's spelling. Any other reason, including
# merge_conflict, an ejection the forge left unlabelled, a reason no known
# vocabulary covers, red checks, unresolved threads, an unreadable forge read,
# or a second automatic attempt for the same armed PR identity, prints
# escalate: and does not enqueue.
# Re-queue is not a merge. The bound is one automatic enqueuePullRequest per
# armed PR identity, recorded in state/<id>.pr-poll-enqueued.
#
# GitHub's merge-queue mutation is GraphQL-only. gh-axi has no enqueue verb, and
# gh-axi pr merge --auto can land a merge when no queue is required, so this
# script uses gh api graphql for the authorized enqueuePullRequest mutation
# only. GitLab merge trains are out of scope.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

escalate() {
  printf 'escalate: %s\n' "$1"
  exit 2
}

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR enqueue request" >&2
  exit 2
fi
ID=$1
REASON=$2
if ! fm_pr_task_id_valid "$ID" || ! [[ "$REASON" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "error: invalid PR enqueue request" >&2
  exit 2
fi

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
fm_pr_metadata_identity_parse "$META" || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
URL=$FM_PR_META_URL
PROVIDER=$FM_PR_META_PROVIDER
HOST=$FM_PR_META_HOST
PROJECT_PATH=$FM_PR_META_PATH
NUMBER=$FM_PR_META_NUMBER
[ "$PROVIDER" = github ] || escalate "$REASON gitlab merge queue is not supported"
[ "$HOST" = github.com ] || escalate "$REASON host is not github.com"

OWNER=${PROJECT_PATH%%/*}
REPO=${PROJECT_PATH#*/}

if fm_pr_poll_enqueued_already "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER"; then
  escalate "$REASON already requeued once"
fi

# The forge spells its removal reasons in upper snake case, and firstmate's own
# vocabulary is lower snake case, so the token is folded before it is matched
# and a reason outside every known spelling is refused by name rather than
# silently treated as ineligible.
REASON_TOKEN=$(printf '%s\n' "$REASON" | tr '[:lower:]' '[:upper:]')
case "$REASON_TOKEN" in
  CI_FAILURE|CI_TIMEOUT|FAILED_CHECKS|CHECKS_TIMED_OUT) ;;
  UNREPORTED|UNREADABLE)
    escalate "$REASON the forge reported no usable ejection reason" ;;
  MANUAL|MERGE_CONFLICT|QUEUE_CLEARED|ROLL_BACK|BRANCH_PROTECTIONS|ALREADY_MERGED|\
  GIT_TREE_INVALID|INVALID_MERGE_COMMIT|UNKNOWN_REMOVAL_REASON)
    escalate "$REASON is not an automatic re-queue reason" ;;
  *)
    escalate "$REASON is not a known merge-queue ejection reason" ;;
esac

# shellcheck disable=SC2016 # GraphQL variables are for gh, not the shell.
gql_read='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id state isDraft isInMergeQueue mergeable reviewDecision commits(last:1){nodes{commit{statusCheckRollup{state}}}} reviewThreads(first:100){nodes{isResolved isOutdated}}}}}'
# shellcheck disable=SC2016 # jq owns every $ expression in this filter.
gql_read_filter='.data.repository.pullRequest as $pr | if $pr == null then empty else [($pr.id // ""), ($pr.state // ""), (if $pr.isDraft == true then "true" else "false" end), (if $pr.isInMergeQueue == true then "true" else "false" end), ($pr.mergeable // ""), ($pr.reviewDecision // ""), ((($pr.commits.nodes // []) | last | .commit.statusCheckRollup.state) // ""), ([($pr.reviewThreads.nodes // [])[] | select(.isResolved == false and .isOutdated != true)] | length | tostring)] | @tsv end'
raw=$(gh api graphql -f query="$gql_read" -F owner="$OWNER" -F name="$REPO" -F number="$NUMBER" -q "$gql_read_filter" 2>/dev/null) || escalate "$REASON forge state could not be read"
[ -n "$raw" ] || escalate "$REASON forge state could not be read"
case "$raw" in
  *$'\n'*) escalate "$REASON forge state could not be read" ;;
esac
[ "$(printf '%s\n' "$raw" | awk -F '\t' '{print NF}')" = 8 ] \
  || escalate "$REASON forge state could not be read"
pr_id=$(printf '%s\n' "$raw" | awk -F '\t' '{print $1}')
pr_state=$(printf '%s\n' "$raw" | awk -F '\t' '{print $2}')
is_draft=$(printf '%s\n' "$raw" | awk -F '\t' '{print $3}')
in_queue=$(printf '%s\n' "$raw" | awk -F '\t' '{print $4}')
mergeable=$(printf '%s\n' "$raw" | awk -F '\t' '{print $5}')
review_decision=$(printf '%s\n' "$raw" | awk -F '\t' '{print $6}')
check_state=$(printf '%s\n' "$raw" | awk -F '\t' '{print $7}')
unresolved=$(printf '%s\n' "$raw" | awk -F '\t' '{print $8}')
[ -n "$pr_id" ] || escalate "$REASON forge state could not be read"
[[ "$pr_id" =~ ^[A-Za-z0-9_=-]+$ ]] || escalate "$REASON forge state could not be read"

if [ "$in_queue" = true ]; then
  printf 'queued: %s\n' "$URL"
  exit 0
fi
[ "$pr_state" = OPEN ] || escalate "$REASON pull request is not open"
[ "$is_draft" = false ] || escalate "$REASON pull request is a draft"
[ "$mergeable" = MERGEABLE ] || escalate "$REASON mergeable is $mergeable"
[ "$review_decision" != CHANGES_REQUESTED ] || escalate "$REASON changes requested"
[ "$check_state" = SUCCESS ] || escalate "$REASON checks are not green"
[ "$unresolved" = 0 ] || escalate "$REASON unresolved review threads"

# shellcheck disable=SC2016 # GraphQL variables are for gh, not the shell.
gql_mut='mutation($id:ID!){enqueuePullRequest(input:{pullRequestId:$id}){mergeQueueEntry{id}}}'
gql_mut_filter='.data.enqueuePullRequest.mergeQueueEntry.id // empty'
queued_id=$(gh api graphql -f query="$gql_mut" -F id="$pr_id" -q "$gql_mut_filter" 2>/dev/null) || escalate "$REASON enqueuePullRequest failed"
[ -n "$queued_id" ] || escalate "$REASON enqueuePullRequest failed"
case "$queued_id" in
  *$'\n'*) escalate "$REASON enqueuePullRequest failed" ;;
esac

# The mutation already landed, so the outcome reported is a re-queue either way.
# A marker that could not be written only loses the one-attempt bound, and
# saying the re-queue failed would send the captain after a pull request that is
# in fact back in the queue.
if ! fm_pr_poll_enqueued_mark "$STATE" "$ID" "$PROVIDER" "$HOST" "$PROJECT_PATH" "$NUMBER" "$REASON"; then
  printf 'queued: %s\n' "$URL"
  escalate "$REASON pull request was requeued but the attempt could not be recorded"
fi
printf 'queued: %s\n' "$URL"
exit 0
