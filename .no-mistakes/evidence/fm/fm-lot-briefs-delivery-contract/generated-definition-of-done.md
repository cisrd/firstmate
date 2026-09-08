# Generated Definition of done — what the worker agent actually receives

Produced by running the real generator at each commit:
    FM_HOME=<tmp> bin/fm-brief.sh <task-id> some-proj --mode <mode>
and taking the `# Definition of done` section of the generated `brief.md`.
Base = d42016ac (before), After = 470fd99 (this change).

---

## mode=direct-PR — diff of the generated contract (base -> after)

```diff
@@ -1,6 +1,10 @@
 # Definition of done
 Delivery contract: mode=direct-PR
 This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
+Do not run /no-mistakes unless firstmate explicitly instructs you to change this task's delivery path.
 The task is complete only when committed on your branch.
-When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
-Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
+When it is implemented and committed, push your branch and open a PR with `gh-axi`.
+If a push, PR creation, or PR verification fails, diagnose the forge failure first, including the reported authentication, remote, branch, or API error; do not use no-mistakes as a workaround.
+Before the final status, verify with `gh-axi` that the branch was actually pushed and that the forge reports a full `https://...` PR URL for that branch.
+Only after those checks append `done: PR {url}` to the status file and stop.
+The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
```

## mode=direct-PR — full generated section as delivered

```markdown
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
Do not run /no-mistakes unless firstmate explicitly instructs you to change this task's delivery path.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`.
If a push, PR creation, or PR verification fails, diagnose the forge failure first, including the reported authentication, remote, branch, or API error; do not use no-mistakes as a workaround.
Before the final status, verify with `gh-axi` that the branch was actually pushed and that the forge reports a full `https://...` PR URL for that branch.
Only after those checks append `done: PR {url}` to the status file and stop.
The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
```

---

## mode=no-mistakes — diff of the generated contract (base -> after)

```diff
@@ -19,6 +19,9 @@
 Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
 A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
 Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.
+After every `no-mistakes axi respond`, continue in the same turn with bounded calls to the structured `no-mistakes axi status` interface until the attributed run changes step, reaches a terminal outcome, presents a genuine ask-user decision, or rule 7's daemon checks establish a real block.
+An accepted response or a status that still reports active work is not a stopping point; the same continuation rule applies after starting or reattaching to a run.
+Never end your turn or promise to resume or check later while structured status shows that validation is active, unless the attributed run presents a genuine ask-user decision - escalate it and stop - or rule 7's daemon checks have established a real block.
 
 Two firstmate-specific rules layer on top of that guidance:
 - ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
```

## mode=no-mistakes — full generated section as delivered

```markdown
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled `Captain:`, `Captain's words:`, `Captain's ask:`, or `Captain's intent:`; never copy its mixed `# Task` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll `no-mistakes axi status` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.
After every `no-mistakes axi respond`, continue in the same turn with bounded calls to the structured `no-mistakes axi status` interface until the attributed run changes step, reaches a terminal outcome, presents a genuine ask-user decision, or rule 7's daemon checks establish a real block.
An accepted response or a status that still reports active work is not a stopping point; the same continuation rule applies after starting or reattaching to a run.
Never end your turn or promise to resume or check later while structured status shows that validation is active, unless the attributed run presents a genuine ask-user decision - escalate it and stop - or rule 7's daemon checks have established a real block.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
```
