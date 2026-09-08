#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit and a local origin. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

test_git_primary_workdir_from_linked_worktree() {
  local repo wt primary repo_real
  repo=$(make_repo "$TMP_ROOT/primary-lib-repo")
  git -C "$repo" worktree add -q --detach "$TMP_ROOT/primary-lib-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/primary-lib-wt"
  repo_real=$(cd "$repo" && pwd -P)
  primary=$(fm_git_primary_workdir "$wt")
  [ "$primary" = "$repo_real" ] || fail "linked worktree should resolve to primary '$repo_real', got '$primary'"
  primary=$(fm_git_primary_workdir "$repo")
  [ "$primary" = "$repo_real" ] || fail "primary checkout should resolve to itself, got '$primary'"
  pass "fm_git_primary_workdir: a linked worktree resolves to the primary checkout"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "does not prove isolation" "$brief" \
    "brief must say pwd vs git-toplevel equality does not prove isolation"
  assert_no_grep "absolute-git-dir" "$brief" \
    "brief must not make git-dir equality a stop condition: an ordinary clone and an Orca copy satisfy it too"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

test_brief_dot_project_resolves_primary_and_keeps_linked_worktree() {
  local home brief primary primary_real wt
  home="$TMP_ROOT/brief-dot-home"
  mkdir -p "$home/data"
  primary=$(make_repo "$TMP_ROOT/brief-dot-primary")
  git -C "$primary" worktree add -q --detach "$TMP_ROOT/brief-dot-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/brief-dot-wt"
  (
    CDPATH='' cd -- "$wt" || exit 1
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" tangle-dot-hh8 . --mode no-mistakes >/dev/null
  )
  brief="$home/data/tangle-dot-hh8/brief.md"
  assert_present "$brief" "dot-project brief was not scaffolded"
  primary_real=$(cd "$primary" && pwd -P)
  assert_grep "$primary_real" "$brief" \
    "dot-project brief must bake the resolved primary checkout path"
  assert_no_grep "worktree of ." "$brief" \
    "dot-project brief must not leave '.' as the repo label"
  assert_grep "does not prove isolation" "$brief" \
    "dot-project brief must not treat pwd vs toplevel as isolation"
  pass "fm-brief: a project of '.' resolves the primary checkout and does not false-flag a linked worktree"
}

test_spawn_dot_project_accepts_isolated_worktree() {
  local home proj fakebin out status other linked linked_real
  home="$TMP_ROOT/spawn-dot-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-dot-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-dot-fake")
  fm_test_fake_sleep_noop "$fakebin"
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-dot-linked" >/dev/null 2>&1
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-dot-other" >/dev/null 2>&1
  other="$TMP_ROOT/spawn-dot-other"
  linked="$TMP_ROOT/spawn-dot-linked"
  linked_real=$(cd "$linked" && pwd -P)
  out=$(
    CDPATH='' cd -- "$linked" || exit 1
    fm_test_spawn_brief "$home" spawn-dot-ii9 brief
    fm_test_run_spawn "$home" "$other" "$fakebin" \
      spawn-dot-ii9 . codex --mode no-mistakes --yolo off
  ); status=$?
  expect_code 0 "$status" "spawn with project '.' into a linked worktree should succeed"$'\n'"$out"
  assert_contains "$out" "spawned spawn-dot-ii9" "dot-project spawn did not report success"
  assert_grep "project=$linked_real" "$home/state/spawn-dot-ii9.meta" \
    "dot-project spawn did not bind the task to the caller's own physical project"
  assert_not_contains "$out" "isolated worktree" "dot-project spawn wrongly refused an isolated treehouse copy"
  pass "fm-spawn: project '.' from a linked worktree keeps that copy as the project and accepts a genuine isolated worktree"
}

# The launch brief is the contract the worker actually reads. A repo LABEL
# cannot be compared with `pwd -P`, so the exact copy and the repository
# primary have to be in it, whatever spelling the project was given.
test_spawn_renders_exact_isolation_paths_into_the_launch_brief() {
  local home proj fakebin out status wt wt_real proj_real brief
  home="$TMP_ROOT/spawn-label-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-label-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-label-fake")
  fm_test_fake_sleep_noop "$fakebin"
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-label-wt" >/dev/null 2>&1
  wt="$TMP_ROOT/spawn-label-wt"
  wt_real=$(cd "$wt" && pwd -P)
  proj_real=$(cd "$proj" && pwd -P)
  fm_test_spawn_brief "$home" spawn-label-kk1 brief
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" \
    spawn-label-kk1 "$proj" codex --mode no-mistakes --yolo off); status=$?
  expect_code 0 "$status" "a label-named ship spawn should succeed"$'\n'"$out"
  brief="$home/data/spawn-label-kk1/launch-brief.md"
  assert_present "$brief" "the launch brief the worker reads was not rendered"
  assert_grep "Your task worktree is \`$wt_real\`" "$brief" \
    "the launch brief must name the exact copy the worker must be in"
  assert_grep "primary checkout is \`$proj_real\`" "$brief" \
    "the launch brief must name the exact primary checkout the worker must not work in"
  assert_grep "is not exactly \`$wt_real\`, STOP" "$brief" \
    "the launch brief must stop the worker on a path mismatch"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "the launch brief lost the isolation blocked-status contract"
  pass "fm-spawn: the launch brief carries the exact worktree and primary paths, not a repo label"
}

test_spawn_dot_project_still_refuses_the_primary() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-dot-primary-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-dot-primary-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-dot-primary-fake")
  fm_test_fake_sleep_noop "$fakebin"
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-dot-primary-linked" >/dev/null 2>&1
  out=$(
    CDPATH='' cd -- "$TMP_ROOT/spawn-dot-primary-linked" || exit 1
    fm_test_spawn_brief "$home" spawn-dot-jj0 brief
    fm_test_run_spawn "$home" "$proj" "$fakebin" \
      spawn-dot-jj0 . codex --mode no-mistakes --yolo off
  ); status=$?
  expect_code 1 "$status" "spawn with project '.' into the primary checkout should abort"
  assert_contains "$out" "did not enter an isolated worktree" "dot-project primary spawn lacked the isolation error"
  pass "fm-spawn: project '.' still refuses the repository primary checkout"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# Spawn isolation uses the shared spawn fakebin (pane path + window ops).
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  fm_test_spawn_brief "$home" "$id" brief
  fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # The assertions concern identity, not how long an unchanged cwd is polled.
  fm_test_fake_sleep_noop "$fakebin"
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  # The non-git case must BE non-git wherever this suite runs. A directory under
  # TMPDIR is not one when TMPDIR itself sits inside a git repository - git walks
  # up and finds that repo, and the spawn reports the subdirectory cause instead.
  # GIT_CEILING_DIRECTORIES stops that upward walk: git does not chdir up into a
  # listed directory, though it never excludes the directory being searched, so
  # the ceiling is the PARENT of the path handed to the spawn (git(1),
  # "GIT_CEILING_DIRECTORIES").
  mkdir -p "$TMP_ROOT/spawn-notgit-root/plain" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  # The discovery poll screens every candidate with the isolation conditions, so
  # a path like this is never adopted and the refusal comes from the poll's own
  # deadline, naming the path and why it was rejected. The assertions pin which
  # cause fired, not the operator wording that explains it.
  out=$(GIT_CEILING_DIRECTORIES="$TMP_ROOT/spawn-notgit-root" \
    run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit-root/plain" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not enter an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_contains "$out" "not inside a git worktree" "non-worktree spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not enter an isolated worktree" "primary-checkout spawn lacked the isolation error"
  assert_contains "$out" "not a worktree root" "primary-checkout spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-primary-ee5.meta" "aborted spawn must not record meta"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  fm_test_spawn_brief "$home" "$id" brief
  FM_TMUX_REC="$rec" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse-get and the worktree wait loop target the stable id.
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse get must be sent to the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

test_git_primary_workdir_from_linked_worktree
test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_brief_dot_project_resolves_primary_and_keeps_linked_worktree
test_spawn_isolation_abort
test_spawn_dot_project_accepts_isolated_worktree
test_spawn_dot_project_still_refuses_the_primary
test_spawn_renders_exact_isolation_paths_into_the_launch_brief
test_spawn_tmux_window_construction
