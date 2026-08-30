#!/usr/bin/env bash
# End-to-end demonstration of the worktree double-registration guard as an
# operator experiences it: real bin/fm-bootstrap.sh runs against real firstmate
# homes, printing the real session-start digest lines.
set -u
ROOT=$1
LIB_OVERRIDE=${2:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=fmdemo GIT_AUTHOR_EMAIL=fmdemo@example.invalid
export GIT_COMMITTER_NAME=fmdemo GIT_COMMITTER_EMAIL=fmdemo@example.invalid
export FM_GATE_REFUSE_BYPASS=1
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
prev=; target=
for a in "$@"; do [ "$prev" = -t ] && target=$a; prev=$a; done
case "${1:-}" in
  list-windows)
    case "$target" in
      livesess) printf '%s\n' alive; printf '%s\n' ambig ;;
      *) printf "can't find session: %s\n" "$target" >&2; exit 1 ;;
    esac ;;
  display-message)
    case "$target" in
      livesess:alive) printf '%s\n' claude ;;
      livesess:ambig) printf '%s\n' node ;;
      *) exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

# A pooled task worktree: a clone-shaped repo whose default branch is published.
make_worktree() {
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
meta() { local f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done; }

FM_SRC=$ROOT
if [ -n "$LIB_OVERRIDE" ]; then
  FM_SRC="$TMP/fmsrc"
  cp -a "$ROOT" "$FM_SRC"
  cp "$LIB_OVERRIDE" "$FM_SRC/bin/fm-worktree-collision-lib.sh"
fi

bootstrap() {  # <home>
  PATH="$FAKEBIN:$BASE_PATH" FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BOOTSTRAP_NETWORK=skip \
    "$FM_SRC/bin/fm-bootstrap.sh" 2>/dev/null
}

banner() { printf '\n========================================================================\n%s\n========================================================================\n' "$1"; }

# ---------------------------------------------------------------- scenario 1
banner "1. Healthy fleet: every task record owns its own worktree"
H="$TMP/home-clean"; mkdir -p "$H/state"
make_worktree "$TMP/wt-a"; make_worktree "$TMP/wt-b"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$TMP/wt-a" "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$TMP/wt-b" "harness=codex"  "kind=ship"
echo '$ bin/fm-bootstrap.sh          # session-start digest, bootstrap section'
bootstrap "$H" | grep -E '^(WORKTREE_COLLISION|MISSING|BACKEND_INVALID):' || echo '(no WORKTREE_COLLISION line - nothing is double-registered)'

# ---------------------------------------------------------------- scenario 2
banner "2. THE BUG THIS GUARD CATCHES: one pooled copy handed to two live tasks,"
echo "   and the copy holds the task's own uncommitted work"
H="$TMP/home-live"; mkdir -p "$H/state"
POOL="$TMP/pool-wt-1"; make_worktree "$POOL"
echo 'half-finished refactor' > "$POOL/scratch.txt"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$POOL" "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$POOL" "harness=codex"  "kind=ship"
echo '$ bin/fm-bootstrap.sh'
bootstrap "$H" | grep '^WORKTREE_COLLISION:'

# ---------------------------------------------------------------- scenario 3
banner "3. Leftover bookkeeping: a finished task's record still claims the copy"
H="$TMP/home-stale"; mkdir -p "$H/state"
POOL="$TMP/pool-wt-2"; make_worktree "$POOL"
echo 'live task work' > "$POOL/notes.md"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$POOL" "harness=claude" "kind=ship"
meta "$H/state/fm-gone.meta"  "window=deadsess:win"  "worktree=$POOL" "harness=claude" "kind=ship"
echo '$ bin/fm-bootstrap.sh'
bootstrap "$H" | grep '^WORKTREE_COLLISION:'

# ---------------------------------------------------------------- scenario 4
banner "4. Verdict honesty (a): clean copy whose work IS on the published default"
H="$TMP/home-landed"; mkdir -p "$H/state"
POOL="$TMP/pool-wt-3a"; make_worktree "$POOL"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$POOL" "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$POOL" "harness=codex"  "kind=ship"
echo '$ git -C pool-wt-3a status --porcelain     # clean'
git -C "$POOL" status --porcelain; echo '(empty)'
echo '$ bin/fm-bootstrap.sh     # collision still reported; NO caveat - nothing at risk there'
bootstrap "$H" | grep '^WORKTREE_COLLISION:'

banner "4. Verdict honesty (b): clean copy merged into a LOCAL main that was never pushed"
H="$TMP/home-unpub"; mkdir -p "$H/state"
POOL="$TMP/pool-wt-3b"
git init -q -b main "$POOL"
git -C "$POOL" commit -q --allow-empty -m init
git -C "$POOL" checkout -q -b feat/x
git -C "$POOL" commit -q --allow-empty -m 'task work'
git -C "$POOL" branch -f main feat/x     # merged into LOCAL main, pushed nowhere
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$POOL" "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$POOL" "harness=codex"  "kind=ship"
echo '$ git -C pool-wt-3b status --porcelain     # clean, nothing uncommitted'
git -C "$POOL" status --porcelain; echo '(empty)'
echo '$ git -C pool-wt-3b merge-base --is-ancestor HEAD main && echo "HEAD is on LOCAL main"'
git -C "$POOL" merge-base --is-ancestor HEAD main && echo "HEAD is on LOCAL main"
echo '$ bin/fm-bootstrap.sh     # must NOT read as safe-to-reclaim'
bootstrap "$H" | grep '^WORKTREE_COLLISION:'

# ---------------------------------------------------------------- scenario 5
banner "5. Same copy spelled two ways (symlinked pool path) is ONE collision"
H="$TMP/home-symlink"; mkdir -p "$H/state"
POOL="$TMP/pool-wt-4"; make_worktree "$POOL"
ln -s "$POOL" "$TMP/pool-link"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$POOL"          "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$TMP/pool-link" "harness=codex"  "kind=ship"
echo '$ bin/fm-bootstrap.sh'
bootstrap "$H" | grep '^WORKTREE_COLLISION:'

# ------------------------------------------------- scenario 6 (newline fix)
# state/<id>.meta is a line-based key=value record, so a recorded worktree=
# never itself holds a newline; the newline lives in the PHYSICAL pool path,
# and each record spells it through a newline-free symlink. That is exactly the
# canonical-newline-path grouping case this fix exists for.
banner "6. CANONICAL NEWLINE-PATH GROUPING: one physical copy under a newline-holding"
echo "   pool dir, recorded by two records through two different symlinks"
H="$TMP/home-nl"; mkdir -p "$H/state"
NL=$'\n'
PHYS="$TMP/pool-a${NL}b"; mkdir -p "$PHYS"
make_worktree "$PHYS/wt"
echo 'unlanded task work' > "$PHYS/wt/wip.txt"
ln -s "$PHYS" "$TMP/nl-link-a"; ln -s "$PHYS" "$TMP/nl-link-b"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$TMP/nl-link-a/wt" "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$TMP/nl-link-b/wt" "harness=codex"  "kind=ship"
echo '$ ls -bd "$TMP"/pool-a*     # the physical pool dir really does hold a newline'
ls -bd "$TMP"/pool-a*
echo '$ bin/fm-bootstrap.sh     # expect ONE line, newline printed escaped as \n'
bootstrap "$H" | grep '^WORKTREE_COLLISION:' || echo '!! NO COLLISION LINE - the double registration went unreported !!'

# ------------------------------------------------- scenario 7 (injectivity)
banner "7. A real-newline copy and a literal backslash-n copy stay DISTINCT"
H="$TMP/home-inj"; mkdir -p "$H/state"
A="$TMP/inj-a${NL}b"; B="$TMP/inj-a\\nb"
make_worktree "$A"; make_worktree "$B"
ln -s "$A" "$TMP/inj-link"
meta "$H/state/fm-nl1.meta" "window=livesess:alive" "worktree=$TMP/inj-link" "harness=claude" "kind=ship"
meta "$H/state/fm-nl2.meta" "window=livesess:ambig" "worktree=$TMP/inj-link" "harness=codex"  "kind=ship"
meta "$H/state/fm-bs1.meta" "window=livesess:alive" "worktree=$B" "harness=claude" "kind=ship"
meta "$H/state/fm-bs2.meta" "window=livesess:ambig" "worktree=$B" "harness=codex"  "kind=ship"
echo '$ ls -bd "$TMP"/inj-a*      # two DIFFERENT physical copies'
ls -bd "$TMP"/inj-a*
echo '$ bin/fm-bootstrap.sh     # expect TWO separate lines, each naming only its own claimants'
bootstrap "$H" | grep '^WORKTREE_COLLISION:'

# ------------------------------------------- scenario 8 (trailing newline)
banner "8. A copy whose name ENDS in a newline is named as itself, not resolved away"
H="$TMP/home-tnl"; mkdir -p "$H/state"
POOL="$TMP/tail-pool"; mkdir -p "$POOL"
WT="$POOL/wt${NL}"; make_worktree "$WT"
echo 'unlanded task work' > "$WT/wip.txt"
ln -s "$WT" "$POOL/link"
meta "$H/state/fm-alpha.meta" "window=livesess:alive" "worktree=$POOL/link" "harness=claude" "kind=ship"
meta "$H/state/fm-beta.meta"  "window=livesess:ambig" "worktree=$POOL/link" "harness=codex"  "kind=ship"
echo '$ ls -bd "$TMP"/tail-pool/wt*  ;  test -e "$TMP/tail-pool/wt"  # the TRUNCATED path does NOT exist'
ls -bd "$POOL"/wt*
if [ -e "$POOL/wt" ]; then echo "tail-pool/wt exists"; else echo "tail-pool/wt: no such path"; fi
echo '$ bin/fm-bootstrap.sh     # must name the copy that exists, and NOT say it is gone'
bootstrap "$H" | grep '^WORKTREE_COLLISION:' || echo '!! NO COLLISION LINE !!'
