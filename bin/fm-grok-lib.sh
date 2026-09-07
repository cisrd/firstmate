#!/usr/bin/env bash
# Grok executable resolution: which `grok` firstmate is allowed to launch.
# Sourced by bin/fm-spawn.sh, bin/fm-vendor-auth-probe.sh,
# bin/fm-turnend-guard-grok.sh, and bin/fm-remote-doctor.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: `grok` is a contested basename. The official xAI Grok Build CLI
# installs a per-user tree at ${GROK_HOME:-$HOME/.grok} and puts its launcher at
# <root>/bin/grok, but at least one unrelated npm package (@vibe-kit/grok-cli)
# installs an executable with the very same name into a global node bin
# directory. Whichever directory happens to come first on the pane's PATH then
# decides what a spawn actually launches. Measured on the fleet host 2026-09-07:
# `type -a grok` listed ~/.local/bin/grok (a symlink into the official tree),
# ~/.grok/bin/grok, and ~/.nvm/versions/node/v24.19.0/bin/grok
# (@vibe-kit/grok-cli 1.0.1) - three same-named executables, two identities, and
# the winner decided purely by PATH order. Launching the impostor is not a
# cosmetic error: it does not share the captain's subscription session, so it
# demands an API key and the worker never starts.
#
# The contract, stated once here and shared by every caller:
#
#   1. The official per-user installation launcher - `bin/grok` under
#      ${GROK_HOME:-$HOME/.grok} - is preferred whenever it is a usable regular
#      executable.
#   2. Otherwise a `grok` found on PATH is accepted ONLY when it canonicalizes
#      INTO that same official installation root. This is what keeps the common
#      ~/.local/bin/grok symlink working when the installer's own launcher is
#      missing, without ever trusting the basename.
#   3. Otherwise firstmate REFUSES and names both paths. An unrecognized
#      same-name executable is never launched, never probed, and never run with
#      grok's flags.
#
# Identity is structural on purpose. Unlike bin/fm-cursor-lib.sh, this file
# runs NO `--version` or `--help` probe to break a tie: the impostor is exactly
# the executable that reacts to being run by demanding a credential, so
# executing an unrecognized homonym to find out what it is would perform the
# hazard this file exists to close. Installation-root identity is also a
# stronger signal than any string a release note could change.
#
# GROK_HOME is the operator knob for a non-default installation root. It is
# grok's own home variable and bin/fm-spawn.sh already honors it for the
# turn-end hook tree, so a home that moves the installation moves both together.

# Canonical absolute path for $1, or the input unchanged when it cannot be
# resolved. Symlink resolution is what makes the structural signal work: the
# official installer points <root>/bin/grok at ../downloads/<platform-binary>,
# and PATH entries such as ~/.local/bin/grok are symlinks at the same tree.
fm_grok_canonical_path() {  # <path>
  local path=$1 dir base hops=0 target
  [ -n "$path" ] || return 1
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || { printf '%s\n' "$path"; return 0; }
  base=$(basename -- "$path")
  # Follow the symlink chain by hand: readlink -f is GNU-only and realpath is
  # not guaranteed on macOS, and this needs no new dependency.
  while [ -L "$dir/$base" ] && [ "$hops" -lt 16 ]; do
    target=$(readlink -- "$dir/$base") || break
    case "$target" in
      /*) dir=$(CDPATH='' cd -- "$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
      *)  dir=$(CDPATH='' cd -- "$dir/$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$dir/$base"
}

# The official installation root, as configured. Printed unresolved so a
# diagnostic can name the path the operator actually set; returns 1 only when
# neither GROK_HOME nor HOME gives one.
fm_grok_official_root() {
  if [ -n "${GROK_HOME:-}" ]; then
    printf '%s\n' "$GROK_HOME"
    return 0
  fi
  [ -n "${HOME:-}" ] || return 1
  printf '%s\n' "$HOME/.grok"
}

# The official installation launcher path, or return 1.
fm_grok_official_binary() {
  local root
  root=$(fm_grok_official_root) || return 1
  printf '%s/bin/grok\n' "$root"
}

# True when $1 is a usable regular executable. -f follows symlinks, so a symlink
# at a real file passes while a dangling link, a directory, or a non-executable
# file does not.
fm_grok_usable_executable() {  # <path>
  local path=$1
  [ -n "$path" ] && [ -f "$path" ] && [ -x "$path" ]
}

# True when executable $1 belongs to the official installation: its canonical
# path lies inside the canonical official root. The root is canonicalized too,
# so a symlinked ~/.grok still matches, and the comparison is anchored on a
# path separator so a sibling such as ~/.grokkery can never match.
fm_grok_path_is_official() {  # <path>
  local path=$1 root canonical canonical_root
  [ -n "$path" ] || return 1
  root=$(fm_grok_official_root) || return 1
  canonical_root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || return 1
  [ -n "$canonical_root" ] || return 1
  canonical=$(fm_grok_canonical_path "$path") || return 1
  case "$canonical" in
    "$canonical_root"/*) return 0 ;;
  esac
  return 1
}

# Print $1 as an absolute path without resolving symlinks in its spelling. An
# absolute input is printed unchanged, matching how the sibling resolvers in
# bin/fm-spawn.sh preserve a launcher's stable spelling; a relative one (a
# relative GROK_HOME, or a relative PATH entry) is anchored so the launch
# command a pane receives cannot depend on that pane's working directory.
fm_grok_stable_path() {  # <path>
  local path=$1 dir
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  dir=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || dir=
  if [ -n "$dir" ]; then
    printf '%s/%s\n' "$dir" "$(basename -- "$path")"
  else
    printf '%s\n' "$path"
  fi
}

# Print the stable absolute launcher path for the official Grok CLI, or return 1
# with a diagnostic on stderr.
#
# The STABLE launcher is printed, not the canonical binary. Identity is proven
# THROUGH canonicalization, but grok's installer points <root>/bin/grok at a
# downloaded platform binary that its own self-update replaces, so a recorded
# launch command must name the launcher to stay valid across an upgrade.
fm_grok_resolve_binary() {
  local official candidate root
  official=$(fm_grok_official_binary) || {
    echo "error: cannot locate the official Grok CLI because neither GROK_HOME nor HOME is set; set GROK_HOME to the Grok installation root" >&2
    return 1
  }
  if fm_grok_usable_executable "$official"; then
    fm_grok_stable_path "$official"
    return 0
  fi
  candidate=$(command -v grok 2>/dev/null || true)
  if fm_grok_usable_executable "$candidate" && fm_grok_path_is_official "$candidate"; then
    fm_grok_stable_path "$candidate"
    return 0
  fi
  root=$(fm_grok_official_root 2>/dev/null || true)
  if [ -n "$candidate" ]; then
    echo "error: refusing to launch '$candidate' as grok: it is not part of the official Grok installation at '$root' and 'grok' is a name unrelated CLIs also install. Install the official xAI Grok CLI so '$official' exists, or set GROK_HOME to its installation root." >&2
  else
    echo "error: no official Grok executable found; expected '$official' and no 'grok' on PATH resolves into '$root'. Install the official xAI Grok CLI, or set GROK_HOME to its installation root." >&2
  fi
  return 1
}
