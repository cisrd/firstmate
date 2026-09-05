#!/usr/bin/env bash
# Fake GitHub CLI for the merge-queue ejection walkthrough. Answers exactly the
# reads the real gh answers, from per-PR fixtures under $FIX/<number>/.
num_from_url() { printf '%s\n' "${1##*/}"; }
if [ "${FM_FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
case "${1:-} ${2:-}" in
  "pr view")
    url=$3
    n=$(num_from_url "$url")
    case " $* " in
      *" headRefOid "*) printf '0123456789abcdef0123456789abcdef01234567\n'; exit 0 ;;
      *" state "*) cat "$FIX/$n/state"; exit 0 ;;
    esac
    exit 1
    ;;
  "api graphql")
    q=; filter=; prev=; n=
    for arg in "$@"; do
      case "$prev" in
        -q) filter=$arg ;;
      esac
      case "$arg" in
        query=*) q=${arg#query=} ;;
        number=*) n=${arg#number=} ;;
      esac
      prev=$arg
    done
    case "$q" in
      *enqueuePullRequest*)
        printf 'MQE_kwDOexample%s\n' "${FM_FAKE_GH_ENQUEUE_SEQ:-1}"; exit 0 ;;
      *RemovedFromMergeQueueEvent*)
        [ -n "$filter" ] || exit 1
        jq -r "$filter" < "$FIX/$n/timeline.json" || exit 1
        exit 0 ;;
      *reviewThreads*)
        [ -n "$filter" ] || exit 1
        jq -r "$filter" < "$FIX/$n/pr.json" || exit 1
        exit 0 ;;
    esac
    exit 1
    ;;
esac
exit 1
