# Live re-verification: Grok interrupt key on the installed build

Independent re-run of the change's own experiment, on the machine that will run
the fleet, using Firstmate's real adapter table to choose the key.

* Installed CLI: `grok 1.0.13 (5e9a58528b76) [stable]` (`~/.local/bin/grok` ->
  `~/.grok/downloads/grok-linux-x86_64`), tmux 3.5a, model `Grok 4.6 (high)`.
* Launch shape: the production spawn shape `grok --always-approve "<prompt>"`
  (no `--no-alt-screen`), one tmux pane, prompt = run a real foreground
  `sleep 60` and do not answer until it exits.
* Key under test was never hard-coded: each trial sourced `bin/fm-control-lib.sh`
  and delivered `fm_control_interrupt_key <harness>` the recorded number of times.

| File | Trial | Key (from the adapter table) | Result |
| --- | --- | --- | --- |
| `ctrlc-1.txt` | retained production path | `fm_control_interrupt_key grok` -> `C-c` | `Turn cancelled by user in 30s.`, grok alive, composer restored, `sleep 60` child still running; a follow-up in the same session answered `READY` |
| `escape-1.txt` | the alternative the intent asked about | `fm_control_interrupt_key claude` -> `Escape` | `Turn cancelled by user in 48s.`, grok alive, composer restored, `sleep 60` child still running |
| `busy-classifier-1013.txt` | recorded busy-signature staleness | n/a | a live in-flight pane (`⠦ Thinking… · Esc:cancel` footer) classified by the real functions |

Each trial file holds the raw tmux pane render immediately before the key,
immediately after it, and three seconds later - the rendered TUI surface a user
sees.

## What this shows about the change

* Escape does cancel a genuinely in-flight turn on 1.0.13 under the production
  launch shape, so the old "Escape only focuses scrollback" premise is indeed
  stale for this build - which is what the change's documentation now says.
* It buys nothing over the incumbent: `C-c` cancelled the same way, and in both
  of these trials the already-running `sleep 60` tool child survived the key.
  No measured axis favours Escape, so retaining `C-c` (no behaviour change) is
  the supported outcome.
* The recorded busy-signature staleness reproduces exactly: a genuinely busy
  1.0.13 pane is read as not-busy by all three consumers named in the record.
