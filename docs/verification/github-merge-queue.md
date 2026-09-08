# GitHub merge-queue verification

This record supports the current guarantee that `bin/fm-pr-merge.sh` uses GitHub's GraphQL `enqueuePullRequest` operation for a queue request and never treats queue membership as a landing.
The helper's header owns queue-token grammar, caller-argument interpretation, preconditions, and retry behavior.
`bin/fm-pr-poll.sh` and `bin/fm-teardown.sh` continue to accept only a merged pull request as landed.

## Environment

Recorded 2026-09-08 on GNU bash 5.2.37(1)-release (x86_64-pc-linux-gnu).

```text
$ gh --version
gh version 2.46.0 (2025-01-13 Debian 2.46.0-3)
https://github.com/cli/cli/releases/tag/v2.46.0

$ gh-axi --version
0.1.33
```

## Supported enqueue operation

Live GitHub GraphQL introspection reports `pullRequestId` and `expectedHeadOid` on `EnqueuePullRequestInput`.
The helper supplies both, with the head read during its live preflight.

```text
$ jq -nc --arg q 'query { __type(name: "EnqueuePullRequestInput") { inputFields { name type { kind name ofType { kind name } } } } }' '{query:$q}' | gh-axi api POST /graphql --input - --jq '.data.__type.inputFields'
[4]:
  - name: clientMutationId
    type:
      kind: SCALAR
      name: String
      ofType: null
  - name: pullRequestId
    type:
      kind: NON_NULL
      name: null
      ofType:
        kind: SCALAR
        name: ID
  - name: jump
    type:
      kind: SCALAR
      name: Boolean
      ofType: null
  - name: expectedHeadOid
    type:
      kind: SCALAR
      name: GitObjectID
      ofType: null
```

The payload exposes the queue entry that the helper requires before it performs an independent membership read.

```text
$ jq -nc --arg q 'query { __type(name: "EnqueuePullRequestPayload") { fields { name type { kind name ofType { kind name } } } } }' '{query:$q}' | gh-axi api POST /graphql --input - --jq '.data.__type.fields'
[2]:
  - name: clientMutationId
    type:
      kind: SCALAR
      name: String
      ofType: null
  - name: mergeQueueEntry
    type:
      kind: OBJECT
      name: MergeQueueEntry
      ofType: null
```

A queue entry and a pull request have different state machines.
A queued pull request remains open until GitHub lands it, while `MergeQueueEntryState` carries `QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`, `UNMERGEABLE`, or `LOCKED`.
The merge poll therefore remains silent for an open queued pull request and reports only the later merged state.

## Delivery-target authority

The consolidated delivery target is `cisrd/firstmate`, where the authenticated captain account has push authority.
The former upstream target `kunchenguid/firstmate` is read-only for the same account.

```text
$ gh-axi api /repos/cisrd/firstmate --jq '.permissions.push'
true

$ gh-axi api /repos/kunchenguid/firstmate --jq '.permissions.push'
false
```

`bin/fm-pr-check.sh` performs the same URL-derived live permission read for a GitHub task carrying `yolo=on` before it records the PR as ready.
A task without autonomous merge authority keeps the existing upstream-contribution path.

## Portable regressions

```sh
bin/fm-test-run.sh tests/fm-pr-merge.test.sh
bin/fm-test-run.sh tests/fm-pr-check-security.test.sh
bin/fm-test-run.sh tests/fm-teardown.test.sh
```

The merge tests execute the public wrapper and prove that `--queue` calls `enqueuePullRequest`, binds `expectedHeadOid`, requires an effective queue rule, rejects a red status rollup and read-only repository, and independently confirms queue membership.
They also prove that direct-merge refusals emit a runnable canonical retry, never repeat a queue operation the caller already requested, reject repeated queue tokens, and reject arguments the mutation cannot honor.
The PR-check tests prove that autonomous delivery accepts a writable URL-derived target and refuses read-only or unverifiable targets before recording readiness.
The teardown tests prove that an open pull request, including one waiting in a merge queue, is not landed work.
