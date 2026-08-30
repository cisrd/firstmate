#!/usr/bin/env bash
# Operator-level transcript for the queue-governed merge path of
# bin/fm-pr-merge.sh. The forge CLIs are stubbed to behave like a real GitHub
# repo whose base branch "main" is governed by a merge queue: an explicit merge
# strategy is refused with GitHub's own message, and a call with no strategy is
# accepted and enqueues the pull request.
set -u
ROOT=$1
WORK=$(mktemp -d /tmp/fmq/run.XXXXXX)
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"

new_case() {
  local name=$1 rules=$2 state=$3 merged=$4 queued=$5 dir
  dir="$WORK/$name"
  mkdir -p "$dir/state" "$dir/bin" "$dir/wt"
  printf '%s\n' "window=fm-task-x1" "worktree=$dir/wt" "project=$dir/project" \
    "kind=ship" "mode=no-mistakes" > "$dir/state/task-x1.meta"
  printf '%s\n' "state=$state" "merged=$merged" "queued=$queued" "base=main" > "$dir/outcome"
  printf '%s' "$rules" > "$dir/rules"
  : > "$dir/gh-axi.log"

  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/gh-axi.log"
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  for a in "$@"; do
    case "$a" in
      --squash|--merge|--rebase)
        # GitHub's own refusal on a merge-queue-governed base branch.
        echo "failed to merge pull request: The merge strategy for main is set by the merge queue" >&2
        exit 1 ;;
    esac
  done
  for a in "$@"; do
    if [ "$a" = --auto ] && [ -e "$CASE/enters-queue" ]; then
      printf '%s\n' "state=OPEN" "merged=false" "queued=true" "base=main" > "$CASE/outcome"
    fi
  done
  echo "Pull request #${3:-} will be added to the merge queue when all requirements are met"
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr view" ]; then
  printf 'pull_request:\n  number: %s\n  state: open\n' "${3:-}"
fi
exit 0
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") case " $* " in *headRefOid*) echo 1111111111111111111111111111111111111111; exit 0 ;; esac ;;
  "api graphql") cat "$CASE/outcome"; exit 0 ;;
  api\ *) cat "$CASE/rules"; exit 0 ;;
esac
exit 0
SH
  cat > "$dir/bin/glab" <<'SH'
#!/usr/bin/env bash
echo "glab $*" >> "$CASE/glab.log"
exit 0
SH
  chmod +x "$dir/bin/gh-axi" "$dir/bin/gh" "$dir/bin/glab"
  printf '%s\n' "$dir"
}

run() {
  local dir=$1; shift
  echo "\$ bin/fm-pr-merge.sh $*"
  CASE="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$dir/bin:$PATH" "$PR_MERGE" "$@" 2>&1 | sed "s#$PR_MERGE#bin/fm-pr-merge.sh#g"
  local rc=${PIPESTATUS[0]}
  echo "[exit $rc]"
  echo
}

echo "=================================================================="
echo "1. Merging a PR whose base branch is governed by a GitHub merge queue"
echo "   (no method flags -> the tool's historical --squash default)"
echo "=================================================================="
d=$(new_case default-squash 'merge_method=MERGE
' OPEN false false)
run "$d" task-x1 https://github.com/example/repo/pull/3335
echo "--- what reached the forge CLI ---"
sed 's/^/gh-axi /' "$d/gh-axi.log"
echo

echo "=================================================================="
echo "2. Running the retry the refusal above printed, on the same PR"
echo "=================================================================="
d2=$(new_case advised-retry 'merge_method=MERGE
' OPEN false false)
: > "$d2/enters-queue"
run "$d2" task-x1 https://github.com/example/repo/pull/3335 -- --auto --no-method
echo "--- what reached the forge CLI (no strategy flag) ---"
sed 's/^/gh-axi /' "$d2/gh-axi.log"
echo "--- merge poll left armed, still waiting for a MERGED state ---"
ls "$d2/state" | sed 's/^/state\//'
echo

echo "=================================================================="
echo "3. Same retry, but required checks keep the PR out of the queue"
echo "   (the guidance must not hand back the command just run)"
echo "=================================================================="
d3=$(new_case already-used 'merge_method=MERGE
' OPEN false false)
run "$d3" task-x1 https://github.com/example/repo/pull/3335 -- --auto --no-method

echo "=================================================================="
echo "3b. Same, with branch rules that disagree about the queue method"
echo "=================================================================="
d3b=$(new_case already-used-conflicting 'merge_method=MERGE
merge_method=SQUASH
' OPEN false false)
run "$d3b" task-x1 https://github.com/example/repo/pull/3335 -- --auto --no-method

echo "=================================================================="
echo "3c. Same, with a queue method this tool does not recognise"
echo "=================================================================="
d3c=$(new_case already-used-unrecognised 'merge_method=FASTFORWARD
' OPEN false false)
run "$d3c" task-x1 https://github.com/example/repo/pull/3335 -- --auto --no-method

echo "=================================================================="
echo "4. Asking the forge to choose AND naming a strategy: refused up front"
echo "=================================================================="
d4=$(new_case conflicting-request 'merge_method=MERGE
' OPEN false false)
run "$d4" task-x1 https://github.com/example/repo/pull/3335 -- --no-method --squash
echo "--- the forge CLI was never called ---"
if [ -s "$d4/gh-axi.log" ]; then sed 's/^/gh-axi /' "$d4/gh-axi.log"; else echo "(gh-axi.log is empty)"; fi
echo

echo "=================================================================="
echo "5. The same forge-decides token on GitLab, which has no such flag"
echo "=================================================================="
d5=$(new_case gitlab-refusal 'merge_method=MERGE
' OPEN false false)
run "$d5" task-x1 https://gitlab.com/example/repo/-/merge_requests/7 -- --no-method
echo "--- glab was never called ---"
if [ -s "$d5/glab.log" ]; then cat "$d5/glab.log"; else echo "(glab.log is empty)"; fi

echo
echo "=================================================================="
echo "6. The armed merge poll from step 2, over the queued PR's lifetime"
echo "   (queue membership is not a landing; only MERGED wakes the poll)"
echo "=================================================================="
cat > "$d2/bin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --json state "*) cat "$CASE/pr-state" ; exit 0 ;;
esac
exit 0
SH
chmod +x "$d2/bin/gh"
echo 'OPEN' > "$d2/pr-state"
echo "\$ PR is OPEN (sitting in the merge queue)"
echo "poll output: [$(CASE="$d2" PATH="$d2/bin:$PATH" bash "$d2/state/task-x1.check.sh")]"
echo 'MERGED' > "$d2/pr-state"
echo "\$ the merge queue lands it, PR is MERGED"
echo "poll output: [$(CASE="$d2" PATH="$d2/bin:$PATH" bash "$d2/state/task-x1.check.sh")]"
