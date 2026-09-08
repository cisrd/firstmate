# Supervision side-effect: a worker holding ONE turn open for a whole no-mistakes run

The contract above makes a validating worker keep a single turn open for the
entire run, so its completed-turn age crosses BUSY_TURN_MAX_SECS as a matter of
course. Driving the real bin/fm-watch.sh over such a crew (busy pane, no completed
turn since 2000, idle window opened 500s ago, threshold 240s):

```
== crew ships mode=no-mistakes, pane busy 4210s, no completed turn since 2000 ==
== BUSY_TURN_MAX_SECS=1 (forced), idle window opened 500s ago (threshold 240s) ==

--- PHASE A: crew-state verdict for THIS crew ---
  state: working · source: run-step · validating (fixing) · run activity recent
  watcher: still running after a full poll cycle (no wake, not woken)
  wake printed to firstmate : ''
  durable wake queue        : (empty)
  wedge escalation counter  : (none)
  idle timer restarted      : yes (must re-prove within the next 240s window)

--- PHASE B: same window, same busy pane, the run has gone quiet ---
  state: working · source: run-step · validating (fixing)
  watcher: EXITED to surface an actionable wake
  wake printed to firstmate : 'stale: fm:fm-lot-briefs (idle 504s, possible wedge, escalation 1)'
  wedge escalation counter  : 1
  queued: 1788880633	1	stale	fm:fm-lot-briefs	stale: fm:fm-lot-briefs (idle 504s, possible wedge, escalation 1)

--- watcher triage log ---
[2026-09-08T17:17:10+0200] absorbed busy (no completed turn) (this crew's own no-mistakes run reports recent activity, idle 501s): fm:fm-lot-briefs
```
