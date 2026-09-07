# Live re-verification of the Grok interrupt verdict (independent test-phase run)

Installed CLI: `grok 1.0.13 (5e9a58528b76) [stable]` (`/home/awilliam/.local/bin/grok` ->
`/home/awilliam/.grok/downloads/grok-linux-x86_64`), tmux 3.5a, model `Grok 4.6 (high)`.

Launch shape: **`grok --always-approve "<prompt>"`** — the production spawn shape from
`bin/fm-spawn.sh:1462`, i.e. WITHOUT the `--no-alt-screen` flag the change's own record used.
Protocol per trial: one turn running a foreground `sleep 60`, wait until the footer shows
`Esc:cancel`, a live `sleep 60` child exists, and the turn counter is >= 20s, then send exactly
one key with `tmux send-keys`; capture immediately and 3s later.

| Trial | Key | Pane state when key was sent | Immediate effect | grok process | Tool child after 3s |
| --- | --- | --- | --- | --- | --- |
| escape-1 | `Escape` | `Thinking… 0.7s`, 28s elapsed, `sleep 60` live | `Cancelling…` then idle bar; `Turn cancelled by user in 28s.` | alive | **still running** |
| escape-2 | `Escape` | `Run sleep 60 in the foreground… 12s`, 27s | `Cancelling…` then idle bar | alive | gone |
| escape-3 | `Escape` | `Foreground sleep for 60 seconds… 13s`, 27s | idle bar | alive | gone |
| escape-4 | `Escape` | `Foreground sleep for 60 seconds… 0.6s`, 29s | `Turn cancelled by user in 29s.` | alive | n/a (follow-up `READY` returned in same session) |
| control | `C-c` | `Thinking… 0.1s`, 28s elapsed, `sleep 60` live | idle bar + `◎ 1 command still running` | alive | **still running** |

Result: on 1.0.13 under the production launch shape a single `Escape` visibly cancels a genuinely
in-flight turn and preserves an interactive session, and a single `C-c` does exactly the same in the
matched state. Neither key stopped an already-detached tool child (`◎ 1 command still running`
residue appears for both). There is therefore no discriminator that favours Escape over the
incumbent key, which matches the change's recorded verdict: retain `C-c`, tighten documentation only.

Active-turn footers observed under the production shape:

```text
Shift+Tab:mode  │  Esc:cancel  │  Ctrl+b:send to bg  │  Ctrl+x:shortcuts
Shift+Tab:mode  │  Esc:cancel  │  Ctrl+x:shortcuts
```

Idle bar: `Shift+Tab:mode  │  Ctrl+x:shortcuts`. No active footer contains `Ctrl+c:cancel`, which is
the busy-signature staleness the change records (and defers). The `Ctrl+b:send to bg` cell appears
when the running tool is backgroundable and is not in the record's `--no-alt-screen` captures.

See `grok-escape-trial-{1,2,3}.txt`, `grok-escape-trial-4-session-survival.txt`,
`grok-ctrlc-control-trial.txt`, and `grok-busy-classifier-on-live-1013-pane.txt`.
