# `fm-crew-state.sh`: the supervisor line the watcher reads, from the run's own activity


### This crew's own run is fixing and its active step keeps reporting

`no-mistakes axi status` (as the client prints it):
    run:
      id: "01RUN"
      branch: fm/feat-ar
      status: fixing
      head: "57cb998001337eb27cede9f598deaddb358f922b"
      pr: ""
      findings: none
      active_steps[1]{step,active_for,last_activity,agent_pid,round}:
        review,12m3s,8s,44121,"auto-fix 1/3"

fm-crew-state.sh feat-ar ->
    state: working · source: run-step · validating (fixing) · run activity recent

### The SAME run record, gone quiet (hung step, or daemon exited under it)

`no-mistakes axi status` (as the client prints it):
    run:
      id: "01RUN"
      branch: fm/feat-ar
      status: fixing
      head: "57cb998001337eb27cede9f598deaddb358f922b"
      pr: ""
      findings: none
      active_steps[1]{step,active_for,last_activity,agent_pid,round}:
        review,42m8s,"quiet 31m2s",44121,"auto-fix 1/3"

fm-crew-state.sh feat-ar ->
    state: working · source: run-step · validating (fixing)

### No steps table for this branch: coarse ledger row only

`no-mistakes axi status` (as the client prints it):
    run:
      id: "01RUN"
      branch: fm/other-crew
      status: running
      head: "57cb998001337eb27cede9f598deaddb358f922b"
      pr: ""
      findings: none
      steps[2]{step,status,findings,duration_ms}:
        intent,completed,0,0
        review,running,0,0

fm-crew-state.sh feat-ar ->
    state: working · source: run-step · validating (background run)
