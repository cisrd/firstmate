## claude / mobile-tablet-ui

**Loaded skill:** `/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.claude/skills/mobile-tablet-ui/SKILL.md`
**Reference:** `.../mobile-tablet-ui/references/device-checks.md`

**The problem.** A phone screenshot only shows the static layout. The failure appears when the software keyboard shrinks the usable height and the submit button ends up below or behind it.

**Adaptation plan (proposed, not applied)**
1. Read the project's form template, design tokens, and supported browser/device list first.
2. Replace any fixed `100vh` or bottom-pinned submit button with dynamic viewport units (`dvh`/`svh`) and a fallback. Keep submit in the normal document flow, or in a sticky footer that respects safe-area insets.
3. Make sure focusing the lowest input scrolls it into view (`scroll-margin`/`scroll-padding`) and that submit stays reachable by scrolling or keyboard, not hidden behind overflow clipping.
4. Test with long localized labels, error messages and enlarged text, not an empty form.

**Checks to run (proposed matrix)**
- Phone widths 320, 375 and 390, portrait and landscape; tablet 768/820 and 1024/1180; desktop regression. These are samples, not breakpoints.
- Open the software keyboard on the lowest input, confirm focus is visible and submit is reachable, then close it and confirm the layout recovers.
- Hardware keyboard tab order to submit, touch target size, allowed zoom.
- Target browsers: iOS Safari and Android Chrome.

**Evidence limits**
- No tests have been run. The list above is a plan only.
- Browser emulation can show layout and simulated input. It cannot show real software-keyboard overlay, browser-chrome resizing, safe areas or assistive-technology behavior.
- Physical phone and tablet sessions and tablet split-view are unavailable, so mark them unverified.
- Each observation should record browser/version, OS, viewport, orientation, input mode, whether it was emulated, steps and result.

## claude / ui-quality-evidence

**Loaded skill:** `/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.claude/skills/ui-quality-evidence/SKILL.md`
**Reference:** `.../ui-quality-evidence/references/matrix.md`

**Required coverage:** 2 states × 2 themes × 2 locales = 8 combinations. None may be sampled away. Viewports come from the contract and are not stated here.

| # | State / theme / locale | Functional (click) | Template parity | Keyboard / focus | Overflow / long FR text |
|---|---|---|---|---|---|
| 1–4 | Loaded × {light, dark} × {FR, EN} | Pass (test pointer) | **Fail**: table density differs from the template | Unverified | Record per row |
| 5–8 | Empty × {light, dark} × {FR, EN} | Pass (test pointer) | Compare the empty-state composition separately | Unverified | Record per row |

Every row also records:
- template and app revisions
- the fictional fixture
- browser, OS and version
- viewport and device-pixel ratio
- fonts
- the steps to reproduce
- expected vs. observed result
- the artifact pointer

**Density failure (repro):** Load the loaded-state fixture and compare row height, padding and columns against the template. Record the measured values. Don't refresh the baseline to hide the difference.

**Limitations:**
- Passing click tests doesn't show the page matches the template. Visual parity gets its own verdict.
- Hardware keyboard testing wasn't available, so keyboard navigation, activation, Escape, focus trapping and return, and visible focus are all **unverified**. Synthetic key events can't stand in for a real keyboard.
- An automated accessibility scan, if one is run, counts as one source of evidence. It doesn't prove full conformance.
- Screenshots don't prove anything about touch, physical devices or screen readers that weren't used.
- Loading, error and permission states are out of scope unless the contract requires them. If it does, they're unverified.

**Status:** Not approved. The density failure is still open and keyboard testing is unverified. Approval stays with the project's owner through its live review of the real app.

## claude / api-contract-evidence

**Skill:** `/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.claude/skills/api-contract-evidence/SKILL.md`
**Reference:** `…/.claude/skills/api-contract-evidence/references/paths.md`

Each row below is a planned check. None of them were run. Before every row, record the before-state of the target rows, related rows, and the outbox/queue.

| Path | Status | Payload | Persisted effects |
|---|---|---|---|
| Allowed (own tenant, permitted role, new key) | The success code the contract defines | Only contract fields; secret field absent | Exactly one expected write, plus the related rows and queued effects the contract lists |
| Refused: role denied | 403 | Error shape; secret absent from body, error and metadata | No create, update or delete. Protected fields unchanged. No queued write once async work has finished. |
| Refused: foreign tenant (distinct fictional tenant and object ID, including nested references) | The status the contract declares, which is not necessarily 403 | No foreign data in the body, totals or metadata | Foreign object's fields unchanged; no queued effect |
| Replay (same key and body) | The contract's replay status | Same as the first response; secret absent | Still one write and one queued effect, no duplicates |
| Replay (same key, different body) | The contract's conflict status | Conflict error shape | No new or changed write |
| Partial failure (authorized fault injected after the intermediate write) | Failure status | Error shape; secret absent | The contract's rollback, compensation or documented partial outcome; key state consistent with retry |

- **A 403 alone is not proof of refusal.** Because a refused request may still enqueue a write, wait until the queue finishes before comparing the after-state. If there is no way to observe or finish the queue, mark the row "unverified".
- **Ambiguities go to the project's decision owner.** Examples: whether refused requests should use the key, or which status a foreign-tenant request should get. I'm not choosing an authorization policy.

## pi / mobile-tablet-ui

**Loaded canonical skill:**  
`/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.agents/skills/mobile-tablet-ui/SKILL.md`

**Loaded reference:**  
`/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.agents/skills/mobile-tablet-ui/references/device-checks.md`

### Bounded adaptation plan

1. Read the project’s form template, tokens, browser/device contract, accessibility requirements, and submit journey.
2. Reproduce the content pressure conceptually at narrow widths with the lowest input focused, long labels/errors, and enlarged text.
3. Keep the submit action in normal document flow or a deliberately scrollable, named form region so it remains reachable above the software keyboard.
4. If the design requires a fixed/sticky action, account for dynamic viewport height, keyboard resizing, browser chrome, and safe-area insets; avoid relying solely on `100vh`.
5. Preserve zoom, visible focus, logical tab order, and a suitably sized touch target. Confirm the layout recovers after keyboard dismissal.
6. Proposed checks:
   - 320/375/390 CSS-pixel phone samples, portrait and landscape.
   - Supported iOS Safari and Android Chrome, software keyboard opened on the lowest field.
   - Hardware-keyboard navigation and desktop regression.
   - 768/820 tablet portrait, 1024/1180 landscape, and narrow split-view when available.
   - Resize while focused and while validation errors are visible.

### Evidence limits

No application testing occurred. Phone screenshots alone cannot establish keyboard reachability. Tablet split-view and all physical-device behavior remain **unverified**, including real keyboard geometry, browser chrome, safe areas, performance, and assistive technology. Any later evidence should record browser/version, OS, route/state, viewport, orientation, input mode, device/emulation configuration, steps, and observed result.

## pi / ui-quality-evidence

Canonical skill: `/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.agents/skills/ui-quality-evidence/SKILL.md`

Reference: `/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.agents/skills/ui-quality-evidence/references/matrix.md`

### Selected evidence matrix

| State | Theme | Locale | Structural/visual | Click interaction | Hardware keyboard | Overall |
|---|---|---|---|---|---|---|
| Loaded | Light | EN | **Fail:** table density differs from authoritative template | Pass | Unverified | Fail |
| Loaded | Light | FR | **Fail:** table density differs; localized overflow not established | Pass | Unverified | Fail |
| Loaded | Dark | EN | **Fail:** table density differs | Pass | Unverified | Fail |
| Loaded | Dark | FR | **Fail:** table density differs; localized overflow not established | Pass | Unverified | Fail |
| Empty | Light | EN | Unverified | Pass | Unverified | Unverified |
| Empty | Light | FR | Unverified; localized text/reflow not established | Pass | Unverified | Unverified |
| Empty | Dark | EN | Unverified | Pass | Unverified | Unverified |
| Empty | Dark | FR | Unverified; localized text/reflow not established | Pass | Unverified | Unverified |

### Limitations

- Click-test success does not establish template parity, keyboard accessibility, focus behavior, or visual correctness.
- Hardware keyboard navigation, activation, escape behavior, focus visibility, containment, and restoration remain **unverified**.
- No browser/OS, viewport, DPR, font, fixture, revision, readiness assertion, screenshot diff, accessibility, contrast, zoom/reflow, or overflow evidence was supplied.
- The table-density mismatch requires reproducible comparison against the authoritative template; baselines must not be changed merely to erase it.
- This evidence neither approves delivery nor replaces the project’s required live review and approval owner.

## pi / api-contract-evidence

Loaded canonical skill:  
`/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.agents/skills/api-contract-evidence/SKILL.md`

Loaded reference:  
`/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.quality-live-r3jtaai8/.agents/skills/api-contract-evidence/references/paths.md`

Planned evidence only; no requests executed.

| Scenario | Fixture/request | Status and payload evidence | Persisted-effect evidence |
|---|---|---|---|
| Allowed | Authorized user in tenant A mutates owned object with key K1 | Assert contract-defined success status and exact allowed fields; secret absent | Compare before/after entity, related rows, audit/outbox, and settled queue; exactly one intended mutation/effect |
| Role-refused | Tenant A user lacking required role, otherwise identical request | Assert 403 and declared error shape; secret absent from body and metadata | Protected fields unchanged; no audit/outbox entry or queued write after asynchronous settlement. Any enqueue is a reproducible contract failure despite 403 |
| Foreign-tenant refused | Authorized tenant A user targets distinguishable tenant B object/reference | Assert 403 and declared non-leaking error; secret and foreign data absent | Tenant B entity and related state unchanged; no queued, audit, or external effect |
| Replay | Repeat successful request with K1 and identical payload | Assert contract-defined replay status/payload and no secret | Same mutation identity/result; no duplicate rows, outbox events, jobs, or external calls |
| Partial failure | Authorized request with supported injected failure after an intermediate step, using K2 | Assert contract-defined failure status/error; secret absent | Assert declared rollback, compensation, or documented partial outcome across entity, related rows, outbox, queue, and stubs; mark **unverified** if fault injection or semantics are unavailable |

Exact statuses beyond the specified 403 and exact partial-failure semantics must come from the authoritative contract, not policy inference.

## codex / mobile-tablet-ui

Captain, I’ll read the skill and its device-check reference, then give a bounded plan without running the form.

Captain, I loaded the [mobile-tablet-ui skill](/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.agents/skills/mobile-tablet-ui/SKILL.md) and its [device-check reference](/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.agents/skills/mobile-tablet-ui/references/device-checks.md).

The screenshot establishes a layout concern, but the keyboard-hidden submit button is an input-state failure. First, check the form’s design and supported-browser contract. Adapt its narrow layout so the focused field stays visible and the submit action remains reachable when the keyboard reduces usable space. Check any fixed footer against dynamic viewport height and safe-area insets; allow the form to scroll where needed.

For validation, propose phone widths of 320, 375, and 390 CSS pixels, plus available tablet portrait and landscape samples. At each available size, check long labels and errors, zoom, keyboard opening on the lowest field, submit access, focus visibility, keyboard closing, and layout recovery. Record browser, OS, viewport, orientation, input mode, steps, and result.

**No application tests were run.** Tablet split-view and physical-device behavior remain unverified. Browser emulation, if used later, cannot establish real keyboard, browser-chrome, safe-area, or assistive-technology behavior.

## codex / ui-quality-evidence

Captain, I’ll read the skill and its matrix reference, then give the requested read-only evidence assessment.

Captain, I loaded [ui-quality-evidence/SKILL.md](/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.agents/skills/ui-quality-evidence/SKILL.md) and [references/matrix.md](/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.agents/skills/ui-quality-evidence/references/matrix.md).

| Selected evidence row | Verdict from the scenario |
| --- | --- |
| Loaded state, template parity: table density | **Fail** — density differs from the authoritative template. Record the exact route, comparison region, fixture, environment, and artifact so the difference can be reproduced. |
| Route click interactions | **Pass**, limited to the supplied click tests. Record their test pointers. |
| Empty state; light/dark; FR/EN combinations | **Unverified** — no observations or artifacts were supplied. Keep a row for every required combination. |
| Hardware keyboard navigation and focus | **Unverified** — testing was unavailable. |

The evidence record also needs the template and application revisions, viewport, browser, fonts, readiness steps, and expected and observed results. Click results do not resolve the density failure. No delivery approval follows from this assessment.

## codex / api-contract-evidence

Captain, I’m loading the API contract evidence skill and its path reference, then I’ll draft the requested evidence rows without running requests.

Captain, I loaded the canonical skill at [SKILL.md](/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.agents/skills/api-contract-evidence/SKILL.md) and its [references/paths.md](/home/awilliam/.no-mistakes/worktrees/a03e7f5d4084/01M3ENAN0HWS8TPJ7S0FV1SFBT/.agents/skills/api-contract-evidence/references/paths.md).

| Scenario | Status and payload evidence | Persisted-effect evidence |
| --- | --- | --- |
| Allowed write | Contract-defined success status and fields; secret field absent. | One expected mutation and its declared related effects. |
| Role-denied write | 403; contract-defined error payload; secret field absent. | Protected data unchanged; **no write queued**, including in an outbox. |
| Foreign-tenant write | 403 if that is the endpoint’s declared refusal status; contract-defined error payload; secret field absent. | Foreign data unchanged; no queued or later write. |
| Replay with same idempotency key | Compare status and payload with the successful request under the declared replay semantics. | No second mutation or duplicate related effect. |
| Partial failure | Contract-defined failure status and payload; secret field absent. | Check the declared rollback, compensation, or documented partial outcome, including queued effects. Mark unverified if that behavior is unspecified. |

These are **expected evidence checks, not observed results**. Capture a known before-state and inspect settled after-state, including queued effects, so a 403 followed by a delayed write is recorded as a contract failure. No requests were executed.
