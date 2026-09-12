#!/usr/bin/env bash
# fm-ntfy.sh - operator entrypoint and standing delivery check for firstmate's
# outbound ntfy notifier.
#
# bin/fm-ntfy-lib.sh is the single owner of the notifier contract: what may be
# published, how an intent becomes a receipt, and every safety boundary. This
# script only exposes that contract as commands and composes it with the
# existing watcher state-check machinery. It adds no second notification policy.
#
# Usage:
#   fm-ntfy.sh status
#       One-line summary of this home's notifier: off, misconfigured with the
#       exact reason, or on with its scope, whether PR links are allowed, and
#       how many notifications are still waiting to be accepted. Prints no
#       topic and no token.
#
#   fm-ntfy.sh check
#       Publish what is waiting. Silent when there is nothing to do or the
#       publish succeeded; prints one line when an operator must fix something
#       (bad configuration, refused token, rejected request, a parked
#       notification). The watcher turns that line into a `check:` wake.
#
#   fm-ntfy.sh test
#       Prove the transport end to end without fabricating a fleet event. It
#       publishes one notification of the dedicated `self-test` kind, which is
#       not part of the event catalog and can never be mistaken for real work,
#       then reports whether ntfy ACCEPTED it. Acceptance is not delivery and is
#       not a person having read it; check the phone to learn that.
#
#   fm-ntfy.sh arm
#       Write state/ntfy.check.sh and bind its bytes with fm-check-register.sh,
#       so the watcher runs the delivery check on its normal FM_CHECK_INTERVAL
#       cadence. Refuses when this home has no usable notifier configuration,
#       so an armed home is always a home that can actually publish.
#
#   fm-ntfy.sh disarm
#       Remove the check shim and its trust binding. Recorded notifications and
#       receipts are left alone; `disarm` stops delivery, it does not discard.
#
# Configuration lives in <FM_HOME>/.env and the private token file it names.
# See docs/configuration.md "Outbound ntfy notifications" for the schema and
# docs/ntfy-notifications.md for setup, privacy, and failure modes.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=ntfy
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-ntfy-lib.sh
. "$SCRIPT_DIR/fm-ntfy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-ntfy.sh status    print this home's notifier state (never the topic or token)
  fm-ntfy.sh check     publish what is waiting; one line only when an operator must act
  fm-ntfy.sh test      publish one self-test notification and report whether ntfy accepted it
  fm-ntfy.sh arm       write and register state/ntfy.check.sh
  fm-ntfy.sh disarm    remove the check shim and its trust binding
  fm-ntfy.sh --help    print this help

Configuration (FM_NTFY_URL, FM_NTFY_TOPIC, FM_NTFY_TOKEN_FILE, FM_NTFY_SCOPE,
FM_NTFY_PR_LINKS) is read from <FM_HOME>/.env. See docs/configuration.md
"Outbound ntfy notifications" for the schema.
EOF
}

die_usage() {
  printf 'fm-ntfy: %s\n' "$1" >&2
  usage >&2
  exit 2
}

action_status() {
  local rc=0 pending
  fm_ntfy_config_load "$FM_HOME" || rc=$?
  case "$rc" in
    1)
      printf 'ntfy: off (no FM_NTFY_URL in %s/.env)\n' "$FM_HOME"
      return 0
      ;;
    2)
      printf 'ntfy: misconfigured - %s\n' "$FM_NTFY_CFG_ERROR"
      return 1
      ;;
  esac
  pending=$(fm_ntfy_pending_count)
  printf 'ntfy: on (scope=%s pr-links=%s armed=%s waiting=%s)\n' \
    "$FM_NTFY_CFG_SCOPE" "$FM_NTFY_CFG_PR_LINKS" \
    "$(fm_custom_check_registered "$STATE" "$CHECK_ID" && printf yes || printf no)" \
    "$pending"
  return 0
}

action_check() {
  fm_ntfy_drain
  return 0
}

# The self-test deliberately does NOT go through fm_ntfy_record: a test must
# never leave a durable intent that looks like a real fleet event, and it must
# never be able to publish one of the catalog's real types. It builds its own
# one-off payload, publishes it once, and keeps no record either way.
action_test() {
  local rc=0 payload result publish_rc code
  fm_ntfy_config_load "$FM_HOME" || rc=$?
  case "$rc" in
    1) printf 'fm-ntfy: this home has no notifier configured (set FM_NTFY_URL in %s/.env)\n' "$FM_HOME" >&2; return 1 ;;
    2) printf 'fm-ntfy: %s\n' "$FM_NTFY_CFG_ERROR" >&2; return 1 ;;
  esac
  payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ntfy-test.XXXXXX") || return 1
  printf '{"topic":"%s","title":"Firstmate","message":"Transport self-test. No fleet event happened.","priority":1,"tags":["gear"],"sequence_id":"firstmate-self-test"}\n' \
    "$FM_NTFY_CFG_TOPIC" > "$payload" || { rm -f -- "$payload"; return 1; }
  result=$(_fm_ntfy_publish "$payload")
  publish_rc=$?
  rm -f -- "$payload"
  case "$publish_rc" in
    0) ;;
    3) printf 'fm-ntfy: the token file named by FM_NTFY_TOKEN_FILE could not be read\n' >&2; return 1 ;;
    127) printf 'fm-ntfy: curl is not installed\n' >&2; return 1 ;;
    *) printf 'fm-ntfy: the ntfy server could not be reached\n' >&2; return 1 ;;
  esac
  code=${result%%$'\t'*}
  case "$code" in
    2*)
      printf 'accepted: ntfy stored the self-test (HTTP %s). Accepted is not delivered and not read; check the device.\n' "$code"
      return 0
      ;;
    401|403)
      printf 'fm-ntfy: the server refused this token (HTTP %s); check FM_NTFY_TOKEN_FILE and the topic access rules\n' "$code" >&2
      return 1
      ;;
    *)
      printf 'fm-ntfy: the server rejected the self-test (HTTP %s); check FM_NTFY_URL and FM_NTFY_TOPIC\n' "$code" >&2
      return 1
      ;;
  esac
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {  # <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-ntfy.sh - outbound notification delivery shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-ntfy.sh") check"
}

SHIM_WRITE_TMP=

# Write the shim the way this repo writes its other trusted check shims: every
# guard runs before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
shim_write() {  # <wanted-content>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-ntfy-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm restores
# what a working home was already using rather than an equivalent rewrite.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-ntfy-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it every cycle and
# wakes firstmate about unauthenticated state checks. So after a failed or
# interrupted arm the home must never hold a shim without a matching binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-ntfy: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home rc=0
  fm_ntfy_config_load "$FM_HOME" || rc=$?
  case "$rc" in
    1)
      printf 'fm-ntfy: this home has no notifier configured; set FM_NTFY_URL in %s/.env before arming\n' "$FM_HOME" >&2
      return 1
      ;;
    2)
      printf 'fm-ntfy: %s\n' "$FM_NTFY_CFG_ERROR" >&2
      return 1
      ;;
  esac
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-ntfy: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-ntfy: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-ntfy: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-ntfy: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-status}" in
  status) action_status ;;
  check) action_check ;;
  test) action_test ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
