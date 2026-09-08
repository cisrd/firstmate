# Evidence - unified keyed-decision resolution grammar (fm/fm-lot-decision-fold-consistency)

Base `d42016a` vs target `22a1b7a`, both driven through the real
`bin/fm-send.sh`, `bin/fm-wake-drain.sh` and `bin/fm-captain-hold.sh`.

| file | what it shows |
| --- | --- |
| `reserved-key-scenarios.sh` | reproducible driver: reserved key answered with `fm-send --resolve-key`, and a hand-written explicit `resolved [key=...]` on a reserved key |
| `before-d42016a.txt` | BEFORE: `--resolve-key` refuses a key the fold itself listed as `blocked:`; the manual `resolved` line is a silent no-op (no UNREAD STATUS, rc=1, needs_decision=0) |
| `after-22a1b7a.txt` | AFTER: the answer is delivered and the key closes; the manual line stays open but surfaces in UNREAD STATUS as `reconciliation-required:` with `needs_decision=1` |
| `captain-hold-transfer-scenario.sh` | reproducible driver: `fm-captain-hold.sh hold` + `complete` over an origin holding a reserved `pending-reply-*` decision |
| `hold-transfer-before-d42016a.txt` | BEFORE: after the transfer the decision is open in the status fold AND held as a captain task; `verify` exits 1 |
| `hold-transfer-after-22a1b7a.txt` | AFTER: the transfer says `pending-reply-captain-held:` (never "resolved"), the fold is empty, `verify` exits 0 |
| `regression-new-tests-at-base.txt` | the change's new cases run against base: they fail there and pass on the target |

Intent bullet mapping:
1. `--resolve-key` refusing keys the fold accepts on `blocked:` lines -> Scenario A.
2. a documented `resolved [key=...]` leaving a key open after a full fold -> Scenario B
   (kept open by the recorded product decision, but no longer silent).
3. reserved `pending-reply-*` keys silently ignoring explicit resolutions -> Scenario B
   (UNREAD STATUS + `reconciliation-required:` + main-only routing marker) and the
   captain-hold transfer transcript.
