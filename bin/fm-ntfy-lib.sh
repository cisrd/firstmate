#!/usr/bin/env bash
# fm-ntfy-lib.sh - the single owner of firstmate's outbound ntfy notifier.
#
# WHAT THIS IS. A secondary, non-authoritative pager. It publishes a fixed,
# generic projection of the few outcomes firstmate has already decided the
# captain must see, so a captain away from the machine learns that something
# wants them. It is never a source of truth, never an input, and never an
# authority: nothing ntfy returns or does can resolve a decision, approve a
# merge, consume a firstmate notification, or change any firstmate record.
# Reading, clearing, or deleting a notification on a phone changes nothing here.
#
# WHAT IT IS NOT. It does not classify importance of its own: producers call it
# at the exact points firstmate already publishes a captain-facing outcome, and
# this library only projects those. It never scans state files looking for work,
# never forwards worker text, logs, report bodies, project or branch names, and
# never emits an action button that performs an HTTP request.
#
# OFF BY DEFAULT, PER HOME. With no FM_NTFY_URL, every entry point below is a
# silent no-op that creates no directory, writes no record, and makes no network
# call. Configuration lives in the home's own gitignored .env and the private
# token file it names, so two homes on one machine share nothing.
# docs/configuration.md "Outbound ntfy notifications" owns that schema, and
# docs/ntfy-notifications.md owns setup, privacy properties, and failure modes.
#
# DELIVERY SEMANTICS: at-least-once, deduplicated by firstmate.
#   1. A producer calls fm_ntfy_record. That writes a durable publication intent
#      under state/ntfy/outbox/ and returns. No network call happens here, so a
#      slow or dead ntfy can never delay supervision or project work.
#   2. fm_ntfy_drain (the standing check in bin/fm-ntfy.sh) publishes pending
#      intents and writes an identity-bound receipt under state/ntfy/receipts/.
#   3. A receipt suppresses every later publication of that identity, including
#      after a restart. The intent is removed only once its receipt exists.
# Three crash windows are covered: before the call (retried), during the call
# (retried, so an ambiguous timeout may duplicate), and after a 2xx but before
# the receipt (retried, so it may duplicate). A rare duplicate is deliberately
# preferred to a silent loss. The retry reuses the same ntfy sequence_id, which
# lets a client collapse the repeat visually; the ntfy server still stores a new
# event, so sequence_id is display de-duplication, never server idempotency, and
# the receipt here is the only authority on what was published.
#
# HTTP 2xx MEANS ACCEPTED BY NTFY. It does not mean delivered to a device, shown
# on a screen, or read by a person. Nothing in this library, and nothing a
# caller may infer from it, treats a receipt as human acknowledgement.
#
# SECRETS. The bearer token is read fresh from the private file named by
# FM_NTFY_TOKEN_FILE on each publish, is passed to curl through a 0600 header
# file, and never reaches argv, a log, a record, an error, or a notification.
# The topic is carried in the JSON request body rather than the URL path, so it
# stays out of argv too. A token embedded in FM_NTFY_URL, or supplied inline as
# FM_NTFY_TOKEN, is refused rather than used.
#
# Sourced by bin/fm-ntfy.sh, bin/fm-watch.sh, bin/fm-pr-check.sh,
# bin/fm-merge-outcome-lib.sh, bin/fm-bootstrap.sh, and tests. Sourcing has no
# side effect: nothing is read, created, or resolved until a function is called.

_FM_NTFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Record schemas. A record whose first line is not its schema is treated as
# unreadable and discarded rather than parsed, so a format change cannot make an
# old record publish something unintended.
FM_NTFY_OUTBOX_SCHEMA=fm-ntfy-outbox-v1
FM_NTFY_RECEIPT_SCHEMA=fm-ntfy-receipt-v1

FM_NTFY_TIMEOUT_DEFAULT=10
FM_NTFY_RETRY_BASE_DEFAULT=30
FM_NTFY_RETRY_CAP_DEFAULT=3600
FM_NTFY_RETRY_MAX_ATTEMPTS_DEFAULT=12
FM_NTFY_DRAIN_MAX_DEFAULT=10
# A ntfy message body is capped at 4096 bytes before it becomes an attachment.
# This projection is generic and far shorter; the cap is enforced anyway so a
# long task id can never turn a notification into an attachment.
FM_NTFY_MESSAGE_MAX=240

# The complete set of publishable events. Adding a type here is the only way to
# make firstmate notify a phone about something new, which is what keeps the
# projection central and reviewable. Each row is:
#   <type>|<priority>|<tag>|<generic message>
# The message is fixed text. It names no project, client, branch, worker,
# finding, or file, because a phone lock screen must be treated as public.
_fm_ntfy_catalog() {
  cat <<'EOF'
decision-required|4|warning|A decision is waiting for you in firstmate.
work-failed|4|rotating_light|Work stopped and needs you in firstmate.
credential-required|4|key|A sign-in is required before work can continue.
pr-ready|3|eyes|A change is ready for your review.
merged|2|white_check_mark|A change was delivered.
EOF
}

# 0 when <type> is publishable. Every entry point validates through this, so an
# unknown or caller-invented type is refused instead of published.
fm_ntfy_type_known() {  # <type>
  local want=${1-}
  [ -n "$want" ] || return 1
  _fm_ntfy_catalog | awk -F '|' -v want="$want" '$1 == want { found = 1 } END { exit found ? 0 : 1 }'
}

_fm_ntfy_catalog_field() {  # <type> <1-based field>
  _fm_ntfy_catalog | awk -F '|' -v want="$1" -v f="$2" '$1 == want { print $f; exit }'
}

# --- configuration ----------------------------------------------------------
#

_fm_ntfy_env_file_value() {  # <env-file> <key>
  local file=$1 key=$2 line k v
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"
    k="${k#"${k%%[![:space:]]*}"}"
    k="${k%"${k##*[![:space:]]}"}"
    [ "$k" = "$key" ] || continue
    v="${line#*=}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
      \"*\") v=${v#\"}; v=${v%\"} ;;
      \'*\') v=${v#\'}; v=${v%\'} ;;
    esac
    printf '%s' "$v"
    return 0
  done < "$file"
  return 1
}

_fm_ntfy_setting() {  # <env-file> <key>
  _fm_ntfy_env_file_value "$1" "$2" || printf ''
}

# True when <text> contains only characters from <allowed>, using tr rather than
# a bracket expression so no character in the set needs shell-specific placement.
_fm_ntfy_charset_ok() {  # <text> <allowed>
  local text=$1 allowed=$2 stripped
  [ -n "$text" ] || return 1
  stripped=$(printf '%s' "$text" | LC_ALL=C tr -d "$allowed")
  [ -z "$stripped" ]
}

_fm_ntfy_url_valid() {  # <url>
  local url=$1 rest hostport
  case "$url" in
    *[[:space:]]*|*'?'*|*'#'*|*\\*|*'"'*|*"'"*) return 1 ;;
  esac
  case "$url" in
    https://*) rest=${url#https://} ;;
    *) return 1 ;;
  esac
  [ -n "$rest" ] || return 1
  # Reject userinfo anywhere: a credential embedded in the URL would reach argv
  # and the server's access log, which is what the token file exists to prevent.
  case "$rest" in *@*) return 1 ;; esac
  hostport=${rest%%/*}
  _fm_ntfy_charset_ok "$hostport" 'A-Za-z0-9.:_[]-' || return 1
  return 0
}

# ntfy topic charset. The topic is a capability - on an instance without access
# control it is effectively the password - so it is validated here and then kept
# out of argv, logs, receipts, errors, and notification text.
_fm_ntfy_topic_valid() {  # <topic>
  local topic=$1
  [ -n "$topic" ] || return 1
  [ "${#topic}" -le 64 ] || return 1
  _fm_ntfy_charset_ok "$topic" 'A-Za-z0-9_-'
}

_fm_ntfy_file_mode() {  # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# The token file must be a regular, non-symlink, owner-only file. A file another
# account can read is refused rather than used, because an ntfy publish token
# carries nearly the whole account's authority and cannot be narrowed to one
# topic.
_fm_ntfy_token_file_valid() {  # <path>
  local path=$1 mode
  case "$path" in /*) ;; *) return 1 ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(_fm_ntfy_file_mode "$path") || return 1
  case "$mode" in 600|0600) ;; *) return 1 ;; esac
  return 0
}

# Read the token fresh. A rotated token therefore takes effect on the next
# publish with no restart, and no copy of it outlives one call.
_fm_ntfy_token_read() {  # <path>
  local path=$1 token
  _fm_ntfy_token_file_valid "$path" || return 1
  token=$(head -n 1 -- "$path" 2>/dev/null) || return 1
  token=${token%$'\r'}
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  [ -n "$token" ] || return 1
  case "$token" in *[[:space:]]*) return 1 ;; esac
  printf '%s' "$token"
}

# fm_ntfy_config_load [home]
#
# Returns 0 with FM_NTFY_CFG_* set when this home has a usable notifier,
# 1 when the home has not opted in (no FM_NTFY_URL), and 2 when it opted in with
# a configuration that cannot be used safely, leaving the reason in
# FM_NTFY_CFG_ERROR. The 1 and 2 cases are deliberately distinct: absence is
# silent, while a half-configured channel is an operator error worth reporting.
# FM_NTFY_HOME lets a caller that already resolved which home an outcome belongs
# to (bin/fm-merge-outcome-lib.sh takes the home as an argument) scope the
# notifier to that home without reassigning FM_HOME for everything else it does.
fm_ntfy_config_load() {  # [home]
  local home=${1:-${FM_NTFY_HOME:-${FM_HOME:-}}} env_file url topic token_file scope pr_links inline
  FM_NTFY_CFG_URL=''
  FM_NTFY_CFG_TOPIC=''
  FM_NTFY_CFG_TOKEN_FILE=''
  FM_NTFY_CFG_SCOPE=minimal
  FM_NTFY_CFG_PR_LINKS=off
  FM_NTFY_CFG_ERROR=''
  [ -n "$home" ] || home=$(cd "$_FM_NTFY_LIB_DIR/.." && pwd)
  env_file="$home/.env"

  url=$(_fm_ntfy_setting "$env_file" FM_NTFY_URL)
  [ -n "$url" ] || return 1

  url=${url%/}
  if ! _fm_ntfy_url_valid "$url"; then
    FM_NTFY_CFG_ERROR='FM_NTFY_URL must be an https base URL with no credentials, query, or fragment'
    return 2
  fi

  inline=$(_fm_ntfy_setting "$env_file" FM_NTFY_TOKEN)
  if [ -n "$inline" ]; then
    FM_NTFY_CFG_ERROR='FM_NTFY_TOKEN is not accepted; put the token in the private file named by FM_NTFY_TOKEN_FILE'
    return 2
  fi

  topic=$(_fm_ntfy_setting "$env_file" FM_NTFY_TOPIC)
  if ! _fm_ntfy_topic_valid "$topic"; then
    FM_NTFY_CFG_ERROR='FM_NTFY_TOPIC must be 1-64 characters of A-Z a-z 0-9 _ -'
    return 2
  fi

  token_file=$(_fm_ntfy_setting "$env_file" FM_NTFY_TOKEN_FILE)
  if [ -z "$token_file" ]; then
    FM_NTFY_CFG_ERROR='FM_NTFY_TOKEN_FILE is required and must name an absolute path'
    return 2
  fi
  if ! _fm_ntfy_token_file_valid "$token_file"; then
    FM_NTFY_CFG_ERROR='FM_NTFY_TOKEN_FILE must be an absolute path to a regular file with mode 600'
    return 2
  fi

  scope=$(_fm_ntfy_setting "$env_file" FM_NTFY_SCOPE)
  case "$scope" in
    ''|minimal) scope=minimal ;;
    detail) ;;
    *)
      FM_NTFY_CFG_ERROR='FM_NTFY_SCOPE must be minimal or detail'
      return 2
      ;;
  esac

  pr_links=$(_fm_ntfy_setting "$env_file" FM_NTFY_PR_LINKS)
  case "$pr_links" in
    ''|off) pr_links=off ;;
    on) ;;
    *)
      FM_NTFY_CFG_ERROR='FM_NTFY_PR_LINKS must be on or off'
      return 2
      ;;
  esac

  FM_NTFY_CFG_URL=$url
  FM_NTFY_CFG_TOPIC=$topic
  FM_NTFY_CFG_TOKEN_FILE=$token_file
  FM_NTFY_CFG_SCOPE=$scope
  FM_NTFY_CFG_PR_LINKS=$pr_links
  return 0
}

# Silent probe used by producers. True only for a home that is both opted in and
# usable, so a misconfigured home records nothing rather than accumulating
# intents that can never be published.
fm_ntfy_enabled() {  # [home]
  fm_ntfy_config_load "${1:-${FM_NTFY_HOME:-${FM_HOME:-}}}" >/dev/null 2>&1
}

# --- durable records --------------------------------------------------------

fm_ntfy_root() {  # [state]
  local state=${1:-${STATE:-}}
  [ -n "$state" ] \
    || state="${FM_STATE_OVERRIDE:-${FM_NTFY_HOME:-${FM_HOME:-$(cd "$_FM_NTFY_LIB_DIR/.." && pwd)}}/state}"
  printf '%s/ntfy' "$state"
}

# Create the private tree only when something is actually about to be stored, so
# a home that never opted in keeps no ntfy footprint at all.
_fm_ntfy_root_ensure() {  # <root>
  local root=$1
  [ ! -L "$root" ] || return 1
  mkdir -p "$root/outbox" "$root/receipts" 2>/dev/null || return 1
  chmod 0700 "$root" "$root/outbox" "$root/receipts" 2>/dev/null || return 1
  return 0
}

_fm_ntfy_digest() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

# The identity is what firstmate deduplicates on, and the digest of it is what
# names the record. Hashing keeps caller-supplied text out of a path entirely.
fm_ntfy_identity() {  # <type> <scope-id> [discriminator]
  printf '%s|%s|%s' "$1" "${2-}" "${3-}"
}

# The scope id is the identity's middle field; it is the only caller-supplied
# text that may appear in a notification, and only under the detail scope.
_fm_ntfy_scope_id_of() {  # <identity>
  local rest=${1#*|}
  printf '%s' "${rest%%|*}"
}

# Restrict a caller-supplied id to a charset that is safe in a notification, a
# JSON string, and a record, then bound its length.
_fm_ntfy_clean_id() {  # <id>
  local id
  id=$(printf '%s' "${1-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  printf '%s' "${id:0:64}"
}

_fm_ntfy_record_field() {  # <file> <schema> <key>
  local file=$1 schema=$2 key=$3 line first=1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$schema" ] || return 1
      continue
    fi
    case "$line" in
      "$key"=*) printf '%s' "${line#"$key"=}"; return 0 ;;
    esac
  done < "$file"
  printf ''
  return 0
}

_fm_ntfy_now() {
  case "${FM_NTFY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$FM_NTFY_NOW" ;;
  esac
}

_fm_ntfy_write_private() {  # <destination> <content>
  local dest=$1 content=$2 tmp dir
  dir=$(dirname -- "$dest")
  tmp=$(umask 077; mktemp "$dir/.fm-ntfy.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ -e "$dest" ] && { [ ! -f "$dest" ] || [ -L "$dest" ]; }; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# A link is carried only when it is one of firstmate's own canonical forge URLs.
# bin/fm-pr-lib.sh is the single owner of that parse, so the notifier never
# invents its own idea of a safe destination and free text can never become a
# link.
_fm_ntfy_link_allowed() {  # <url>
  local url=$1
  [ -n "$url" ] || return 1
  case "$url" in https://*) ;; *) return 1 ;; esac
  case "$url" in *[[:space:]]*|*'"'*|*\\*|*'<'*|*'>'*) return 1 ;; esac
  if ! command -v fm_pr_url_parse >/dev/null 2>&1; then
    # shellcheck source=bin/fm-pr-lib.sh
    # shellcheck disable=SC1091
    . "$_FM_NTFY_LIB_DIR/fm-pr-lib.sh"
  fi
  # Run the parse in a subshell: it publishes FM_PR_* globals, and a producer
  # that calls the notifier mid-sequence must not have its own PR identity
  # silently rewritten by this check.
  ( fm_pr_url_parse "$url" >/dev/null 2>&1 && [ "$FM_PR_URL" = "$url" ] ) || return 1
  return 0
}

# fm_ntfy_record <type> <scope-id> [link] [discriminator]
#
# Record one publication intent. Always returns 0 for a disabled home so a
# producer can call it unconditionally; returns 2 only for a caller error (an
# unknown type), which is a firstmate bug rather than an operator condition.
# Never makes a network call and never fails a producer's own work.
fm_ntfy_record() {  # <type> <scope-id> [link] [discriminator]
  local type=$1 scope_id link=${3-} disc=${4-}
  local root identity key outbox receipt now
  fm_ntfy_type_known "$type" || return 2
  fm_ntfy_enabled || return 0
  [ "$FM_NTFY_CFG_PR_LINKS" = on ] || link=''
  [ -z "$link" ] || _fm_ntfy_link_allowed "$link" || link=''

  scope_id=$(_fm_ntfy_clean_id "${2-}")
  root=$(fm_ntfy_root) || return 0
  _fm_ntfy_root_ensure "$root" || return 0

  identity=$(fm_ntfy_identity "$type" "$scope_id" "$disc")
  key=$(_fm_ntfy_digest "$identity") || return 0
  receipt="$root/receipts/$key.rec"
  outbox="$root/outbox/$key.rec"
  # A published identity is never published again, including across restarts.
  [ ! -f "$receipt" ] || return 0
  # An intent already queued for this identity keeps its attempt history rather
  # than being reset, so a failing event cannot loop back to attempt one.
  [ ! -f "$outbox" ] || return 0

  now=$(_fm_ntfy_now)
  _fm_ntfy_write_private "$outbox" \
    "$(printf '%s\nidentity=%s\ntype=%s\nlink=%s\ncreated=%s\nattempts=0\nnext=%s' \
      "$FM_NTFY_OUTBOX_SCHEMA" "$identity" "$type" "$link" "$now" "$now")" || return 0
  return 0
}

# fm_ntfy_forget <type> <scope-id> [discriminator]
#
# Drop both the intent and the receipt for one identity, so the same condition
# notifies again the next time it actually occurs. Used for a recurring
# environment condition (an expired login) whose recovery firstmate can observe.
fm_ntfy_forget() {  # <type> <scope-id> [discriminator]
  local type=$1 scope_id disc=${3-} root key
  fm_ntfy_type_known "$type" || return 2
  root=$(fm_ntfy_root) || return 0
  [ -d "$root" ] || return 0
  scope_id=$(_fm_ntfy_clean_id "${2-}")
  key=$(_fm_ntfy_digest "$(fm_ntfy_identity "$type" "$scope_id" "$disc")") || return 0
  rm -f -- "$root/outbox/$key.rec" "$root/receipts/$key.rec" 2>/dev/null || true
  return 0
}

# fm_ntfy_status_types <classified-status-events>
#
# Project a classified captain-relevant status span onto publishable types,
# reading ONLY the leading verb of each line. The rest of a status line is
# worker-authored free text and is discarded here, which is what makes "no
# worker text is ever forwarded" a property of the projection rather than a
# promise about every caller. Prints distinct types, one per line.
fm_ntfy_status_types() {  # <events>
  local events=${1-} line verb seen=''
  [ -n "$events" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verb=${line%%:*}
    verb="${verb#"${verb%%[![:space:]]*}"}"
    verb=${verb%%[![:alnum:]-]*}
    case "$verb" in
      needs-decision) verb=decision-required ;;
      blocked|failed) verb=work-failed ;;
      *) continue ;;
    esac
    case " $seen " in *" $verb "*) continue ;; esac
    seen="$seen $verb"
    printf '%s\n' "$verb"
  done <<EOF
$events
EOF
}

# --- publication ------------------------------------------------------------

# Escape one already-sanitized value for a JSON string. Inputs reaching here are
# fixed catalog text, a charset-restricted id, a canonical forge URL, or a hex
# digest, so this handles the structural characters rather than pretending to be
# a general JSON encoder.
_fm_ntfy_json_escape() {  # <text>
  local text=${1-}
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\n'/ }
  text=${text//$'\r'/ }
  text=${text//$'\t'/ }
  printf '%s' "$text"
}

# Build the notification body for one type. Under the default minimal scope the
# body is exactly the catalog's generic sentence; detail adds the firstmate task
# id and nothing else. Neither scope can emit worker text.
fm_ntfy_message() {  # <type> <scope-id>
  local type=$1 scope_id=${2-} message
  message=$(_fm_ntfy_catalog_field "$type" 4)
  [ -n "$message" ] || return 1
  if [ "${FM_NTFY_CFG_SCOPE:-minimal}" = detail ] && [ -n "$scope_id" ]; then
    message="$message ($scope_id)"
  fi
  printf '%s' "${message:0:$FM_NTFY_MESSAGE_MAX}"
}

# The complete request body. The topic lives here rather than in the URL path so
# it stays out of argv and out of the server's request-line logging. The only
# action this function can produce is ntfy's `view`, which opens a URL; there is
# deliberately no code path that emits an `http` action button, because such a
# button would let a phone perform a firstmate action with no identity,
# correlation, expiry, or replay protection.
fm_ntfy_payload() {  # <type> <scope-id> <link> <sequence-id>
  local type=$1 scope_id=${2-} link=${3-} seq=${4-} priority tag message actions=''
  priority=$(_fm_ntfy_catalog_field "$type" 2)
  tag=$(_fm_ntfy_catalog_field "$type" 3)
  message=$(fm_ntfy_message "$type" "$scope_id") || return 1
  [ -n "$priority" ] && [ -n "$tag" ] || return 1
  [ "${FM_NTFY_CFG_PR_LINKS:-off}" = on ] || link=''
  [ -z "$link" ] || _fm_ntfy_link_allowed "$link" || link=''
  if [ -n "$link" ]; then
    actions=$(printf ',"click":"%s","actions":[{"action":"view","label":"Open","url":"%s","clear":false}]' \
      "$(_fm_ntfy_json_escape "$link")" "$(_fm_ntfy_json_escape "$link")")
  fi
  printf '{"topic":"%s","title":"Firstmate","message":"%s","priority":%s,"tags":["%s"],"sequence_id":"%s"%s}\n' \
    "$(_fm_ntfy_json_escape "$FM_NTFY_CFG_TOPIC")" \
    "$(_fm_ntfy_json_escape "$message")" \
    "$priority" \
    "$(_fm_ntfy_json_escape "$tag")" \
    "$(_fm_ntfy_json_escape "$seq")" \
    "$actions"
}

# Publish one payload. On a completed request it prints one tab-separated
# "<http-code>\t<retry-after>\t<message-id>\t<received>" line and returns 0; every other
# return code names a condition that produced no HTTP answer at all. Results are
# printed rather than assigned because the caller reads this through a command
# substitution, and a variable set in that subshell would never reach it.
_fm_ntfy_delivery_budget() {
  local check_timeout=${FM_CHECK_TIMEOUT:-30} budget
  case "$check_timeout" in
    ''|*[!0-9]*) printf '0'; return ;;
    0) printf '20'; return ;;
  esac
  budget=$((check_timeout * 2 / 3))
  [ "$budget" -le 20 ] || budget=20
  printf '%s' "$budget"
}

_fm_ntfy_publish() {  # <payload-file>
  local payload=$1 auth token headers body code rc timeout retry_after id received budget
  budget=$(_fm_ntfy_delivery_budget)
  [ "$budget" -gt 0 ] || return 4
  command -v curl >/dev/null 2>&1 || return 127
  token=$(_fm_ntfy_token_read "$FM_NTFY_CFG_TOKEN_FILE") || return 3
  auth=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ntfy-auth.XXXXXX") || return 1
  if ! chmod 600 "$auth" 2>/dev/null || ! printf 'Authorization: Bearer %s\n' "$token" > "$auth"; then
    rm -f -- "$auth"
    return 1
  fi
  token=''
  headers=$(mktemp "${TMPDIR:-/tmp}/fm-ntfy-head.XXXXXX") || { rm -f -- "$auth"; return 1; }
  body=$(mktemp "${TMPDIR:-/tmp}/fm-ntfy-body.XXXXXX") || { rm -f -- "$auth" "$headers"; return 1; }
  timeout=${2:-$FM_NTFY_TIMEOUT_DEFAULT}
  [ "$timeout" -le "$budget" ] || timeout=$budget
  # Neither the token nor the topic appears in argv: the token rides a 0600
  # header file and the topic rides the payload file.
  code=$(curl -sS -m "$timeout" -o "$body" -D "$headers" -w '%{http_code}' \
    -X POST \
    -H "@$auth" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$FM_NTFY_CFG_URL/" 2>/dev/null)
  rc=$?
  rm -f -- "$auth"
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$headers" "$body"
    return 4
  fi
  received=$(_fm_ntfy_now)
  retry_after=$(_fm_ntfy_retry_after "$headers" "$received")
  id=$(_fm_ntfy_response_id "$body")
  rm -f -- "$headers" "$body"
  printf '%s\t%s\t%s\t%s' "$code" "$retry_after" "$id" "$received"
  return 0
}

_fm_ntfy_retry_after() {  # <headers-file>
  local headers=$1 value epoch now
  [ -f "$headers" ] || return 0
  value=$(awk 'tolower($0) ~ /^retry-after:/ { sub(/^[^:]*:[ \t]*/, ""); sub(/[\r \t]+$/, ""); print; exit }' "$headers")
  case "$value" in
    '') return 0 ;;
    *[!0-9]*)
      epoch=$(LC_ALL=C date -u -d "$value" +%s 2>/dev/null) \
        || epoch=$(LC_ALL=C date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$value" +%s 2>/dev/null) || return 0
      now=${2:-$(_fm_ntfy_now)}
      [ "$epoch" -gt "$now" ] || return 0
      printf '%s' "$((epoch - now))"
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# ntfy answers a successful publish with the stored event as JSON. Its id is
# recorded in the receipt purely as evidence for an operator reading the record;
# nothing here depends on it, so a body that cannot be parsed is not a failure.
_fm_ntfy_response_id() {  # <body-file>
  local body=$1 id=''
  [ -f "$body" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    id=$(jq -r '.id // empty' "$body" 2>/dev/null) || id=''
  fi
  case "$id" in
    ''|*[!A-Za-z0-9_-]*) printf '' ;;
    *) printf '%s' "$id" ;;
  esac
}

_fm_ntfy_backoff() {  # <attempts> [retry-after]
  local attempts=$1 after=${2-} base cap delay jitter
  base=$FM_NTFY_RETRY_BASE_DEFAULT
  cap=$FM_NTFY_RETRY_CAP_DEFAULT
  case "$after" in ''|*[!0-9]*) after='' ;; esac
  delay=$base
  while [ "$attempts" -gt 1 ] && [ "$delay" -lt "$cap" ]; do
    delay=$((delay * 2))
    attempts=$((attempts - 1))
  done
  [ "$delay" -le "$cap" ] || delay=$cap
  # Bounded jitter keeps several homes, or several parked events, from retrying
  # in lockstep after a shared outage.
  jitter=$((RANDOM % (delay / 4 + 1)))
  delay=$((delay + jitter))
  [ -z "$after" ] || [ "$after" -le "$delay" ] || delay=$after
  printf '%s' "$delay"
}

_fm_ntfy_reschedule() {  # <record> <attempts> <delay> <now>
  local rec=$1 attempts=$2 delay=$3 now=$4 identity type link created
  identity=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" identity) || return 0
  type=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" type)
  link=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" link)
  created=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" created)
  case "$delay" in ''|*[!0-9]*) delay=$FM_NTFY_RETRY_BASE_DEFAULT ;; esac
  _fm_ntfy_write_private "$rec" \
    "$(printf '%s\nidentity=%s\ntype=%s\nlink=%s\ncreated=%s\nattempts=%s\nnext=%s' \
      "$FM_NTFY_OUTBOX_SCHEMA" "$identity" "$type" "$link" "$created" "$attempts" "$((now + delay))")" || true
  return 0
}

_fm_ntfy_receipt_write() {  # <root> <key> <identity> <type> <now> <message-id>
  local root=$1 key=$2 identity=$3 type=$4 now=$5 message=${6-}
  _fm_ntfy_write_private "$root/receipts/$key.rec" \
    "$(printf '%s\nidentity=%s\ntype=%s\npublished=%s\nmessage=%s' \
      "$FM_NTFY_RECEIPT_SCHEMA" "$identity" "$type" "$now" "$message")" || return 1
  return 0
}

# A standing condition must report ONCE, not on every cadence tick: the watcher
# turns each printed line into a wake, so an unfixed configuration or a parked
# notification would otherwise nag forever. The last reported line is kept, an
# identical repeat stays silent, and a changed or cleared condition reports
# again - so a problem that gets worse, or comes back, is still seen.
_fm_ntfy_report_emit() {  # <root> <line>
  local root=$1 line=$2 record="$1/.report"
  if [ -z "$line" ]; then
    rm -f -- "$record" 2>/dev/null || true
    return 0
  fi
  _fm_ntfy_root_ensure "$root" || { printf '%s\n' "$line"; return 0; }
  [ "$(cat "$record" 2>/dev/null)" = "$line" ] && return 0
  # Print before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  printf '%s\n' "$line"
  _fm_ntfy_write_private "$record" "$line" || true
  return 0
}

# fm_ntfy_drain
#
# Publish pending intents, bounded per run. Prints at most one diagnostic line
# describing a condition an operator must fix, and only the first time that
# exact condition is seen; a healthy drain is silent. Always returns 0: a
# notifier problem is reported, never propagated into the caller's own work.
fm_ntfy_drain() {
  local max=$FM_NTFY_DRAIN_MAX_DEFAULT
  local root rec key identity type link attempts next now payload report=''
  local max_attempts attempted=0 rc result code retry_after message_id
  local budget deadline remaining timeout recovered=0
  budget=$(_fm_ntfy_delivery_budget)
  deadline=$((SECONDS + budget))

  rc=0
  fm_ntfy_config_load || rc=$?
  if [ "$rc" -ne 0 ]; then
    # 1 is an opted-out home and stays silent; 2 is an operator error worth one
    # line, because a half-configured channel is a channel the captain believes
    # is working.
    [ "$rc" -eq 2 ] && _fm_ntfy_report_emit "$(fm_ntfy_root)" "ntfy: $FM_NTFY_CFG_ERROR"
    return 0
  fi
  max_attempts=$FM_NTFY_RETRY_MAX_ATTEMPTS_DEFAULT

  root=$(fm_ntfy_root)
  if [ "$budget" -le 0 ]; then
    _fm_ntfy_report_emit "$root" 'ntfy: FM_CHECK_TIMEOUT cannot accommodate notification delivery; use at least 2 whole seconds or 0 for no outer deadline'
    return 0
  fi
  case "$(cat "$root/.report" 2>/dev/null)" in
    'ntfy: FM_NTFY_'*|'ntfy: FM_CHECK_TIMEOUT cannot accommodate notification delivery;'*) _fm_ntfy_report_emit "$root" '' ;;
  esac
  [ -d "$root/outbox" ] || return 0
  now=$(_fm_ntfy_now)

  for rec in "$root"/outbox/*.rec; do
    [ -f "$rec" ] || continue
    [ "$SECONDS" -lt "$deadline" ] || break
    [ "$attempted" -lt "$max" ] || break
    key=$(basename -- "$rec" .rec)
    if [ -f "$root/receipts/$key.rec" ]; then
      # The receipt is the authority; an intent left beside one is a crash
      # between the two writes and must never republish.
      rm -f -- "$rec"
      continue
    fi
    identity=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" identity) \
      || { rm -f -- "$rec"; continue; }
    type=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" type)
    fm_ntfy_type_known "$type" || { rm -f -- "$rec"; continue; }
    link=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" link)
    attempts=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" attempts)
    case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
    next=$(_fm_ntfy_record_field "$rec" "$FM_NTFY_OUTBOX_SCHEMA" next)
    case "$next" in ''|*[!0-9]*) next=0 ;; esac
    [ "$next" -le "$now" ] || continue
    if [ "$attempts" -ge "$max_attempts" ]; then
      # Parked, never discarded: the intent stays visible in `fm-ntfy.sh status`
      # so a lost notification is an operator-visible fact, not a silent gap.
      [ -n "$report" ] \
        || report="ntfy: a notification has not been accepted after $attempts attempts and is parked in state/ntfy/outbox"
      continue
    fi

    attempted=$((attempted + 1))
    attempts=$((attempts + 1))
    payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ntfy-payload.XXXXXX") || continue
    if ! fm_ntfy_payload "$type" "$(_fm_ntfy_scope_id_of "$identity")" "$link" "$key" > "$payload"; then
      rm -f -- "$payload" "$rec"
      continue
    fi
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then rm -f -- "$payload"; break; fi
    timeout=$FM_NTFY_TIMEOUT_DEFAULT
    [ "$timeout" -le "$remaining" ] || timeout=$remaining
    result=$(_fm_ntfy_publish "$payload" "$timeout")
    rc=$?
    now=$(_fm_ntfy_now)
    rm -f -- "$payload"

    case "$rc" in
      0) ;;
      3)
        [ -n "$report" ] || report='ntfy: the token file named by FM_NTFY_TOKEN_FILE could not be read'
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$attempts")" "$now"
        continue
        ;;
      127)
        [ -n "$report" ] || report='ntfy: curl is not installed, so notifications cannot be published'
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$attempts")" "$now"
        continue
        ;;
      *)
        # Transport failure: DNS, TLS, connection refused, or a timeout. The
        # request may or may not have been accepted, so the intent is kept and
        # retried, accepting a possible duplicate over a possible loss.
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$attempts")" "$now"
        continue
        ;;
    esac

    code=${result%%$'\t'*}
    retry_after=${result#*$'\t'}
    message_id=${retry_after#*$'\t'}
    now=${message_id##*$'\t'}
    message_id=${message_id%%$'\t'*}
    retry_after=${retry_after%%$'\t'*}

    case "$code" in
      2*)
        if _fm_ntfy_receipt_write "$root" "$key" "$identity" "$type" "$now" "$message_id" \
          && [ -f "$root/receipts/$key.rec" ]; then
          rm -f -- "$rec"
          recovered=1
        else
          report='ntfy: publication accepted but its receipt could not be saved; the intent is retained'
        fi
        ;;
      401|403)
        # Treat as revoked or misdirected rather than transient: back off hard
        # instead of hammering an endpoint that is refusing this token, keep the
        # event, and report the credential once.
        [ -n "$report" ] \
          || report="ntfy: the server refused this home's token (HTTP $code); check FM_NTFY_TOKEN_FILE and the topic's access rules"
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$max_attempts")" "$now"
        ;;
      429)
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$attempts" "$retry_after")" "$now"
        ;;
      5*)
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$attempts")" "$now"
        ;;
      *)
        [ -n "$report" ] \
          || report="ntfy: the server rejected a notification (HTTP $code); check FM_NTFY_URL and FM_NTFY_TOPIC"
        _fm_ntfy_reschedule "$rec" "$attempts" "$(_fm_ntfy_backoff "$max_attempts")" "$now"
        ;;
    esac
  done

  if [ -n "$report" ] || [ "$recovered" -eq 1 ]; then
    _fm_ntfy_report_emit "$root" "$report"
  fi
  return 0
}

# Count intents still waiting, for an operator-facing status line.
fm_ntfy_pending_count() {
  local root rec n=0
  root=$(fm_ntfy_root)
  [ -d "$root/outbox" ] || { printf '0'; return 0; }
  for rec in "$root"/outbox/*.rec; do
    [ -f "$rec" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}
