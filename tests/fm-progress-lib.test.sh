#!/usr/bin/env bash
# tests/fm-progress-lib.test.sh - the observable-progress contract
# (bin/fm-progress-lib.sh): which rendered numbers count as PROGRESS and which
# are animation that must never be mistaken for it.
#
# The whole busy-but-frozen report rests on this distinction. If a duration or a
# spinner leaked in here, a wedged worker would look busy AND advancing forever
# and the report could never fire; if a counter were missed, a working worker
# would look frozen and the report would fire on real work. Both directions are
# pinned below.
#
# These are pure text assertions with no harness and no state, so CI runs them
# everywhere. The complementary question - does a given harness RELEASE still
# render the counters this library knows how to read - is a rendered-surface
# fact only a real harness can answer, and
# tests/fm-busy-progress-drift-live-e2e.test.sh is the opt-in guard for it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-progress-lib.sh
. "$ROOT/bin/fm-progress-lib.sh"

counters_of() {  # <text> -> space-joined tokens, or the literal "NONE"
  local out
  if out=$(fm_progress_counters "$1"); then
    printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//'
  else
    printf 'NONE'
  fi
}

has_counter() {  # <text> <expected-token>
  fm_progress_counters "$1" 2>/dev/null | grep -Fx "$2" >/dev/null
}

# --- counters that are real progress ----------------------------------------
# Every footer below is a shape a verified harness actually renders; the
# down-arrow token meters are transcribed from the recorded pane observations in
# docs/verification/runtime-backends.md and tests/fm-tmux-submit-busy.test.sh.

CLAUDE_FOOTER='✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)'
has_counter "$CLAUDE_FOOTER" 'tok:down=1.1k' \
  || fail "a rendered down-token meter was not read as progress: $(counters_of "$CLAUDE_FOOTER")"
has_counter "$CLAUDE_FOOTER" 'tok:n=1.1k' \
  || fail "a word-anchored token count was not read as progress: $(counters_of "$CLAUDE_FOOTER")"
pass "a live token meter in a real harness footer is read as progress"

# shellcheck disable=SC2016  # the $ is a literal currency sign in a rendered footer
RICH_FOOTER='✻ Thinking… (22m 15s · ↑ 3.2k ↓ 812 tokens · $1.42 · 45% context left)'
has_counter "$RICH_FOOTER" 'tok:up=3.2k' || fail "up-token meter missed: $(counters_of "$RICH_FOOTER")"
has_counter "$RICH_FOOTER" 'tok:down=812' || fail "down-token meter missed: $(counters_of "$RICH_FOOTER")"
has_counter "$RICH_FOOTER" 'cost=1.42' || fail "cost meter missed: $(counters_of "$RICH_FOOTER")"
has_counter "$RICH_FOOTER" 'ctx:pct=45' || fail "context percentage missed: $(counters_of "$RICH_FOOTER")"
pass "up/down tokens, spend, and context percentage are all read as progress"

has_counter 'context: 12.3k/200k' 'ctx:ratio=12.3k/200k' \
  || fail "a used/total context meter missed: $(counters_of 'context: 12.3k/200k')"
pass "a used/total context meter is read as progress, both numbers kept"

# --- animation that must never be read as progress --------------------------
# This is the half that makes the report possible at all: a frozen worker keeps
# repainting these, so anything counted here would mask every wedge forever.

for animation in \
  'Working... (3600.1s)' \
  '• Working (6s • esc to interrupt)' \
  'esc to interrupt' \
  '⠋ Thinking… 0:12' \
  'Running… 1m 30s elapsed' \
  'Compiling [=====>    ] 45% done in 0:12' \
  '[00:01:05] still going'
do
  [ "$(counters_of "$animation")" = NONE ] \
    || fail "an elapsed clock, spinner, or unrelated meter was read as progress in [$animation]: $(counters_of "$animation")"
done
pass "elapsed clocks, spinners, and non-context percentages are never read as progress"

# The exact discrimination the report depends on: same worker, same instant,
# only the clock advanced. The counters must be byte-identical across the two
# readings while a whole-pane hash of the same two frames would differ.
A='✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)'
B='✢ Pollinating… (48s · ↓ 1.1k tokens · thought for 1s)'
[ "$(counters_of "$A")" = "$(counters_of "$B")" ] \
  || fail "a ticking clock changed the progress reading: [$(counters_of "$A")] vs [$(counters_of "$B")]"
[ "$A" != "$B" ] \
  || fail "the two frames are identical, so this case proves nothing about the clock"
pass "a ticking clock alone leaves the progress reading byte-identical (the pane hash would not)"

# The opposite direction, so the case above cannot pass vacuously: real
# generation between two readings MUST change it.
C='✢ Pollinating… (48s · ↓ 2.4k tokens · thought for 1s)'
[ "$(counters_of "$A")" != "$(counters_of "$C")" ] \
  || fail "real token growth did not change the progress reading: $(counters_of "$C")"
pass "real token growth does change the progress reading"

# --- absence is reported, never invented ------------------------------------

if fm_progress_counters '• Working (6s • esc to interrupt)' >/dev/null; then
  fail "a counter-free footer reported success instead of admitting it has no measure"
fi
pass "a harness that renders no counters returns no reading and says so"

if fm_progress_counters '' >/dev/null; then
  fail "empty input reported a progress reading"
fi
pass "empty input returns no reading"

# --- displayed content cannot fake progress ---------------------------------
# Counters are read from the footer region only. Chat or file content scrolling
# through the pane can contain token-shaped text, and treating it as progress
# would let a frozen worker's static transcript suppress the report.

# shellcheck disable=SC2016  # the $ is a literal currency sign in displayed content
CONTENT_ABOVE=$(printf 'we used ↓ 9.9k tokens last run and it cost $4.20\n%s\n' 'x')
FILLER=$(for i in $(seq 1 20); do printf 'line %s\n' "$i"; done)
[ "$(counters_of "$(printf '%s\n%s\n• Working (6s • esc to interrupt)\n' "$CONTENT_ABOVE" "$FILLER")")" = NONE ] \
  || fail "token-shaped text scrolled above the footer was read as progress"
pass "token-shaped text outside the footer region is not read as progress"

echo "# fm-progress-lib.test.sh: all assertions passed"
