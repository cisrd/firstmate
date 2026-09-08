#!/usr/bin/env bash
# End-to-end transcript of the captain-hold completion gate transferring a
# RESERVED decision key, driven through the real bin/fm-captain-hold.sh.
# Reuses the repo suite's own fixture helpers (tests/lib.sh + the first 200
# lines of tests/fm-captain-hold-lifecycle.test.sh, which are helpers only).
#   usage: captain-hold-transfer-scenario.sh <firstmate-tree> <label>
set -u
TREE=$1; LABEL=$2
HELPERS=$(mktemp "$TREE/tests/.fm-evidence-helpers.XXXXXX.sh")
sed -n '1,200p' "$TREE/tests/fm-captain-hold-lifecycle.test.sh" > "$HELPERS"
# shellcheck source=/dev/null
. "$HELPERS"

printf '######  captain-held transfer of a reserved decision key  ######\n'
printf 'tree : %s\n' "$LABEL"

id=sample-reserved-review
key=pending-reply-abcdef0123456789
home=$(make_home evidence-reserved-transfer)
mkdir -p "$home/data/$id"
tasks_in "$home" add "$id" "Investigate reserved escalations" --kind scout --repo sample --start >/dev/null
write_origin_meta "$home" "$id"
printf 'blocked [key=%s]: pending-reply-missed: task=%s request=ship it\n' "$key" "$id" \
  > "$home/state/$id.status"

printf '\n$ cat state/%s.status\n' "$id"; cat "$home/state/$id.status"
printf '\n$ bin/fm-captain-hold.sh hold sample-reserved-call --origin %s ...\n' "$id"
run_captain "$home" hold sample-reserved-call \
  --title "Answer the missed reply" --reason "the escalated reply is unanswered" \
  --repo sample --origin "$id" >/dev/null 2>&1 \
  && printf '[exit 0] captain-held task sample-reserved-call registered\n' \
  || printf '[FAILED to register the hold]\n'

printf '\n$ bin/fm-captain-hold.sh complete %s sample-reserved-call\n' "$id"
rc=0
run_captain "$home" complete "$id" sample-reserved-call 2>&1 | sed 's/^/  /' || rc=$?
printf '[exit %s]\n' "$rc"

printf '\n$ cat state/%s.status        # the transfer line written by the gate\n' "$id"
cat "$home/state/$id.status"

printf '\n$ status_open_decisions state/%s.status   # is the key still open beside its hold?\n' "$id"
open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$TREE/bin/fm-classify-lib.sh" "$home/state/$id.status")
if [ -n "$open" ]; then
  printf '%s\n>>> STILL OPEN: the decision is tracked BOTH as a captain-held task and as an open status decision\n' "$open"
else
  printf '(empty - the reserved key closed into its captain-held task, tracked exactly once)\n'
fi

printf '\n$ bin/fm-captain-hold.sh verify %s\n' "$id"
rc=0
run_captain "$home" verify "$id" >/dev/null 2>&1 || rc=$?
printf '[exit %s]\n' "$rc"
rm -f "$HELPERS"
