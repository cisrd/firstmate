#!/usr/bin/env bash
# tests/fm-grok-executable.test.sh - the portable regression for which `grok`
# firstmate is allowed to launch.
#
# `grok` is a contested basename: the official xAI Grok Build CLI installs a
# per-user tree at ${GROK_HOME:-$HOME/.grok} with its launcher at <root>/bin/grok,
# while unrelated npm packages install an executable with the same name into a
# global node bin directory. A bare `grok` in a launch command therefore lets
# PATH order decide whose CLI a worker starts, and the impostor cannot reach the
# captain's Grok subscription - it stops on an API-key demand and the worker
# never begins.
#
# The load-bearing contracts, all exercised through the public interfaces
# (bin/fm-grok-lib.sh's resolver, a real bin/fm-spawn.sh launch, and
# bin/fm-vendor-auth-probe.sh) against REAL temporary executables:
#   1. The official installation launcher wins over a same-named executable that
#      precedes it on PATH.
#   2. A PATH `grok` is accepted only when it canonicalizes INTO the official
#      installation root, which is what keeps the common ~/.local/bin symlink
#      working; the basename is never enough.
#   3. An unrecognized homonym is REFUSED, not launched, and not even run to
#      identify itself.
#   4. An unusable official launcher (dangling, non-executable, a directory) is
#      not silently replaced by a homonym.
#   5. Installation roots containing spaces resolve and launch correctly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-grok-lib.sh
. "$ROOT/bin/fm-grok-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-grok-executable)
trap 'rm -rf "$TMP_ROOT"' EXIT

# A REAL executable named grok that is NOT the official CLI, shaped like the
# npm homonym: an interpreted script in a node-style bin directory. It records
# every invocation so a test can prove it was never run.
make_homonym() {  # <dir> -> echoes <bindir>
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/grok" <<SH
#!/bin/sh
printf 'ran\n' >> "$dir/invocations"
echo "1.0.1"
echo "Please set GROK_API_KEY" >&2
exit 1
SH
  chmod +x "$dir/bin/grok"
  printf '%s\n' "$dir/bin"
}

# --- 1. The resolver's own contract, with real files ------------------------

test_official_wins_over_a_homonym_earlier_on_path() {
  local case_dir grok_home homonym_bin resolved
  case_dir="$TMP_ROOT/prefers-official"
  grok_home="$case_dir/grok"
  fm_test_fake_grok_install "$grok_home" >/dev/null
  homonym_bin=$(make_homonym "$case_dir/npm")

  resolved=$(GROK_HOME="$grok_home" PATH="$homonym_bin:$PATH" fm_grok_resolve_binary) \
    || fail "resolution must succeed when the official installation is present"
  [ "$resolved" = "$grok_home/bin/grok" ] \
    || fail "expected the official launcher, got '$resolved'"
  # The STABLE launcher is printed, not the canonical download it points at, so
  # a recorded launch command survives grok's own self-update.
  [ -L "$grok_home/bin/grok" ] \
    || fail "fixture lost the launcher symlink that makes this assertion meaningful"
  assert_absent "$case_dir/npm/invocations" "the homonym must never be executed to identify it"
  pass "the official installation launcher wins over a homonym earlier on PATH"
}

test_path_entry_inside_the_official_root_is_accepted() {
  local case_dir grok_home link_bin resolved
  case_dir="$TMP_ROOT/path-into-official"
  grok_home="$case_dir/grok"
  fm_test_fake_grok_install "$grok_home" >/dev/null
  # The shape the fleet host actually has: ~/.local/bin/grok is a symlink into
  # the official tree. Remove the installer's own launcher so acceptance can
  # only come from the PATH entry's identity.
  link_bin="$case_dir/local-bin"
  mkdir -p "$link_bin"
  ln -sf "$grok_home/downloads/grok-fake" "$link_bin/grok"
  rm -f "$grok_home/bin/grok"

  resolved=$(GROK_HOME="$grok_home" PATH="$link_bin:$PATH" fm_grok_resolve_binary) \
    || fail "a PATH grok resolving into the official root must be accepted"
  [ "$resolved" = "$link_bin/grok" ] \
    || fail "expected the accepted PATH entry, got '$resolved'"
  pass "a PATH grok that canonicalizes into the official root is accepted"
}

test_unrecognized_homonym_is_refused_never_launched() {
  local case_dir grok_home homonym_bin out status
  case_dir="$TMP_ROOT/refuse-homonym"
  grok_home="$case_dir/grok"
  mkdir -p "$grok_home"
  homonym_bin=$(make_homonym "$case_dir/npm")

  out=$(GROK_HOME="$grok_home" PATH="$homonym_bin:$PATH" fm_grok_resolve_binary 2>&1)
  status=$?
  expect_code 1 "$status" "an unrecognized homonym must be refused"
  assert_contains "$out" "$homonym_bin/grok" "the refusal must name the executable it rejected"
  assert_contains "$out" "$grok_home" "the refusal must name the official installation root"
  assert_absent "$case_dir/npm/invocations" "a refused homonym must never be executed"
  pass "an unrecognized same-name executable is refused, named, and never run"
}

test_no_grok_at_all_is_refused_with_an_actionable_diagnostic() {
  local case_dir grok_home empty_bin out status
  case_dir="$TMP_ROOT/no-grok"
  grok_home="$case_dir/grok"
  empty_bin="$case_dir/empty"
  mkdir -p "$grok_home" "$empty_bin"

  out=$(GROK_HOME="$grok_home" PATH="$empty_bin" fm_grok_resolve_binary 2>&1)
  status=$?
  expect_code 1 "$status" "no grok executable at all must be refused"
  assert_contains "$out" "$grok_home/bin/grok" "the refusal must name the expected launcher path"
  assert_contains "$out" "GROK_HOME" "the refusal must name the operator knob for a non-default root"
  pass "no Grok executable anywhere refuses with an actionable diagnostic"
}

test_unusable_official_launcher_does_not_fall_back_to_a_homonym() {
  local case_dir grok_home homonym_bin out status
  homonym_bin=$(make_homonym "$TMP_ROOT/unusable-npm")

  # Dangling launcher symlink.
  case_dir="$TMP_ROOT/unusable-dangling"
  grok_home="$case_dir/grok"
  mkdir -p "$grok_home/bin"
  ln -sf ../downloads/gone "$grok_home/bin/grok"
  out=$(GROK_HOME="$grok_home" PATH="$homonym_bin:$PATH" fm_grok_resolve_binary 2>&1)
  status=$?
  expect_code 1 "$status" "a dangling official launcher must not fall back to a homonym"
  assert_contains "$out" "$homonym_bin/grok" "the dangling case must name the rejected homonym"

  # Present but not executable.
  case_dir="$TMP_ROOT/unusable-noexec"
  grok_home="$case_dir/grok"
  mkdir -p "$grok_home/bin"
  printf '#!/bin/sh\nexit 0\n' > "$grok_home/bin/grok"
  chmod 0644 "$grok_home/bin/grok"
  out=$(GROK_HOME="$grok_home" PATH="$homonym_bin:$PATH" fm_grok_resolve_binary 2>&1)
  status=$?
  expect_code 1 "$status" "a non-executable official launcher must not fall back to a homonym"

  # A directory where the launcher belongs.
  case_dir="$TMP_ROOT/unusable-dir"
  grok_home="$case_dir/grok"
  mkdir -p "$grok_home/bin/grok"
  out=$(GROK_HOME="$grok_home" PATH="$homonym_bin:$PATH" fm_grok_resolve_binary 2>&1)
  status=$?
  expect_code 1 "$status" "a directory at the launcher path must not resolve"

  assert_absent "$TMP_ROOT/unusable-npm/invocations" "no unusable-official case may execute the homonym"
  pass "an unusable official launcher refuses rather than falling back to a homonym"
}

test_sibling_root_is_not_mistaken_for_the_official_one() {
  local case_dir grok_home sibling out status
  case_dir="$TMP_ROOT/sibling"
  grok_home="$case_dir/grok"
  sibling="$case_dir/grokkery"
  mkdir -p "$grok_home"
  fm_test_fake_grok_install "$sibling" >/dev/null

  out=$(GROK_HOME="$grok_home" PATH="$sibling/bin:$PATH" fm_grok_resolve_binary 2>&1)
  status=$?
  expect_code 1 "$status" "a root sharing a name prefix must not satisfy the official-root test"
  ! (GROK_HOME="$grok_home"; fm_grok_path_is_official "$sibling/bin/grok") \
    || fail "GROK_HOME='$grok_home' must not claim '$sibling/bin/grok'"
  # Positive control, so the rejection above cannot pass vacuously: the very
  # same launcher IS official once the root that owns it is the configured one.
  (GROK_HOME="$sibling"; fm_grok_path_is_official "$sibling/bin/grok") \
    || fail "the sibling launcher must test as official under its own root"
  pass "a sibling directory sharing the root's name prefix is never accepted"
}

test_installation_root_containing_spaces_resolves() {
  local case_dir grok_home resolved
  case_dir="$TMP_ROOT/spaces"
  grok_home="$case_dir/grok home/x y"
  fm_test_fake_grok_install "$grok_home" >/dev/null
  resolved=$(GROK_HOME="$grok_home" fm_grok_resolve_binary) \
    || fail "an installation root containing spaces must resolve"
  [ "$resolved" = "$grok_home/bin/grok" ] \
    || fail "expected '$grok_home/bin/grok', got '$resolved'"
  (GROK_HOME="$grok_home"; fm_grok_path_is_official "$grok_home/bin/grok") \
    || fail "a space-containing official launcher must test as official"
  pass "an installation root containing spaces resolves and identifies"
}

test_a_relative_installation_root_is_anchored_before_launch() {
  local case_dir grok_home resolved
  case_dir="$TMP_ROOT/relative-root"
  grok_home="$case_dir/grok"
  fm_test_fake_grok_install "$grok_home" >/dev/null
  # A relative GROK_HOME must not put a cwd-dependent launcher into a launch
  # command the pane runs somewhere else.
  resolved=$(cd "$case_dir" && GROK_HOME=grok fm_grok_resolve_binary) \
    || fail "a relative installation root must still resolve"
  case "$resolved" in
    /*) : ;;
    *) fail "a relative installation root must be anchored, got '$resolved'" ;;
  esac
  [ -x "$resolved" ] || fail "the anchored path must still be executable: '$resolved'"
  pass "a relative installation root is anchored to an absolute launcher"
}

test_home_default_is_used_when_grok_home_is_unset() {
  local case_dir fake_home resolved
  case_dir="$TMP_ROOT/home-default"
  fake_home="$case_dir/home"
  fm_test_fake_grok_install "$fake_home/.grok" >/dev/null
  resolved=$(env -u GROK_HOME HOME="$fake_home" bash -c \
    ". '$ROOT/bin/fm-grok-lib.sh'; fm_grok_resolve_binary") \
    || fail "an unset GROK_HOME must fall back to \$HOME/.grok"
  [ "$resolved" = "$fake_home/.grok/bin/grok" ] \
    || fail "expected the \$HOME/.grok launcher, got '$resolved'"
  pass "an unset GROK_HOME falls back to the per-user default installation root"
}

# --- 2. The real spawn launch command ---------------------------------------

run_grok_spawn() {  # <case-dir> <extra PATH dir> [spawn args...]
  local case_dir=$1 path_dir=$2
  shift 2
  local home="$case_dir/home" proj="$case_dir/project" wt="$case_dir/wt"
  local fakebin id="grok-launch-x1"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id" >/dev/null 2>&1
  GROK_HOME="$case_dir/grok" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    PATH="$path_dir:$PATH" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" grok --mode no-mistakes --yolo off
}

test_spawn_launches_the_official_path_not_the_path_homonym() {
  local case_dir homonym_bin out status launch
  case_dir="$TMP_ROOT/spawn-official"
  fm_test_fake_grok_install "$case_dir/grok" >/dev/null
  homonym_bin=$(make_homonym "$case_dir/npm")

  out=$(run_grok_spawn "$case_dir" "$homonym_bin")
  status=$?
  expect_code 0 "$status" "a grok spawn with the official installation present should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "'$case_dir/grok/bin/grok' --always-approve" \
    "the launch command must name the resolved official launcher"
  assert_not_contains "$launch" "$homonym_bin/grok" \
    "the launch command must not name the PATH homonym"
  # The normal official argument vector is intact.
  assert_contains "$launch" "--always-approve" "the launch lost --always-approve"
  assert_contains "$launch" "encode launch-brief <" "the launch lost the brief argument"
  assert_absent "$case_dir/npm/invocations" "the spawn must never execute the homonym"
  pass "a grok spawn launches the resolved official path, never the PATH homonym"
}

test_spawn_refuses_rather_than_launching_an_unrelated_cli() {
  local case_dir homonym_bin out status
  case_dir="$TMP_ROOT/spawn-refuse"
  mkdir -p "$case_dir/grok"
  homonym_bin=$(make_homonym "$case_dir/npm")

  out=$(run_grok_spawn "$case_dir" "$homonym_bin")
  status=$?
  [ "$status" -ne 0 ] || fail "a grok spawn with no official installation must fail, got: $out"
  assert_contains "$out" "$homonym_bin/grok" "the spawn refusal must name the rejected executable"
  assert_absent "$case_dir/launch.log" "a refused spawn must not publish a launch command"
  assert_absent "$case_dir/npm/invocations" "a refused spawn must never execute the homonym"
  pass "a grok spawn refuses rather than launching an unrelated same-name CLI"
}

test_spawn_launches_from_a_root_containing_spaces() {
  local case_dir out status launch grok_home
  case_dir="$TMP_ROOT/spawn spaces"
  grok_home="$case_dir/grok"
  fm_test_fake_grok_install "$grok_home" >/dev/null
  out=$(run_grok_spawn "$case_dir" "$case_dir/fake/fakebin")
  status=$?
  expect_code 0 "$status" "a grok spawn from a space-containing path should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "$grok_home/bin/grok" \
    "the launch command must carry the space-containing official launcher"
  pass "a grok spawn resolves and quotes an installation root containing spaces"
}

# --- 3. The authentication probe --------------------------------------------

probe_grok() {  # <grok-home> <extra PATH dir>
  GROK_HOME="$1" PATH="$2:$PATH" FM_VENDOR_AUTH_PROBE_TIMEOUT=10 \
    "$ROOT/bin/fm-vendor-auth-probe.sh" grok 2>/dev/null
}

test_probe_reads_the_official_cli_and_never_the_homonym() {
  local case_dir grok_home homonym_bin out
  case_dir="$TMP_ROOT/probe-official"
  grok_home="$case_dir/grok"
  mkdir -p "$grok_home/bin" "$grok_home/downloads"
  cat > "$grok_home/downloads/grok-fake" <<'SH'
#!/bin/sh
case "${1:-}" in
  --version) echo "grok 0.2.117 (f1c06093089f) [stable]" ;;
  models) echo "You are logged in with grok.com." ;;
esac
exit 0
SH
  chmod +x "$grok_home/downloads/grok-fake"
  ln -sf ../downloads/grok-fake "$grok_home/bin/grok"
  homonym_bin=$(make_homonym "$case_dir/npm")

  out=$(probe_grok "$grok_home" "$homonym_bin")
  assert_contains "$out" "status=authenticated" "the probe must read the official CLI's answer: $out"
  assert_contains "$out" "versionVerified=yes" "the probe must read the official CLI's version: $out"
  assert_absent "$case_dir/npm/invocations" "the probe must never execute the homonym"
  pass "the authentication probe reads the official CLI and never the PATH homonym"
}

test_probe_reports_unavailable_instead_of_probing_a_homonym() {
  local case_dir grok_home homonym_bin out
  case_dir="$TMP_ROOT/probe-refuse"
  grok_home="$case_dir/grok"
  mkdir -p "$grok_home"
  homonym_bin=$(make_homonym "$case_dir/npm")

  out=$(probe_grok "$grok_home" "$homonym_bin")
  assert_contains "$out" "probe=grok status=unavailable" \
    "an unrecognized homonym must land as unavailable, not as a vendor verdict: $out"
  assert_contains "$out" "version=none" "an unresolved probe must report no version: $out"
  assert_not_contains "$out" "$homonym_bin" "the probe must never print a path"
  assert_absent "$case_dir/npm/invocations" "the probe must never execute the homonym"
  pass "the authentication probe reports unavailable rather than probing a homonym"
}

test_official_wins_over_a_homonym_earlier_on_path
test_path_entry_inside_the_official_root_is_accepted
test_unrecognized_homonym_is_refused_never_launched
test_no_grok_at_all_is_refused_with_an_actionable_diagnostic
test_unusable_official_launcher_does_not_fall_back_to_a_homonym
test_sibling_root_is_not_mistaken_for_the_official_one
test_installation_root_containing_spaces_resolves
test_a_relative_installation_root_is_anchored_before_launch
test_home_default_is_used_when_grok_home_is_unset
test_spawn_launches_the_official_path_not_the_path_homonym
test_spawn_refuses_rather_than_launching_an_unrelated_cli
test_spawn_launches_from_a_root_containing_spaces
test_probe_reads_the_official_cli_and_never_the_homonym
test_probe_reports_unavailable_instead_of_probing_a_homonym
printf '# all fm-grok-executable tests passed\n'
