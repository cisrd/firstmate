#!/usr/bin/env bash
# tests/fm-ntfy.test.sh - behavior tests for the outbound ntfy notifier
# (bin/fm-ntfy-lib.sh and bin/fm-ntfy.sh) and the producers that feed it.
#
# The notifier must be INERT by default (no configuration -> no state, no
# network, no record) and, when a home opts in, must publish only the fixed
# generic projection through a durable at-least-once path that firstmate itself
# deduplicates. The network is stubbed with a fakebin `curl` so these stay
# hermetic: no ntfy server, no ports, deterministic in CI. Everything here is
# asserted through the executable interface - the scripts, their records, and
# the exact request the client would have sent - never against source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-ntfy-tests)
NTFY="$ROOT/bin/fm-ntfy.sh"
LIB="$ROOT/bin/fm-ntfy-lib.sh"

# A fakebin `curl` standing in for an ntfy server. It answers with FAKE_CODE,
# optionally adds a Retry-After header, records the full argv plus the request
# body and auth header to FAKE_CURL_LOG, and can simulate a transport failure
# (FAKE_CURL_FAIL) the way a DNS, TLS, or timeout error reaches the client.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile=""; hdrfile=""; datafile=""; url=""; auth=""; timeout=10
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -D) hdrfile=$2; shift 2 ;;
    --data-binary) datafile=${2#@}; shift 2 ;;
    -H)
      case "$2" in
        @*) while IFS= read -r h; do case "$h" in Authorization:*) auth=$h ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m) timeout=$2; shift 2 ;;
    -w|-X) shift 2 ;;
    -s|-sS|-S) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  {
    echo "argv=$argv"
    echo "url=$url"
    echo "auth=$auth"
    echo "payload=$(cat "$datafile" 2>/dev/null)"
  } >> "$FAKE_CURL_LOG"
fi
if [ -n "${CRASH_PID:-}" ]; then
  kill -KILL "$CRASH_PID"
  exit 7
fi
if [ -n "${FAKE_RESPONSE_TIME:-}" ]; then printf '%s' "$FAKE_RESPONSE_TIME" > "$FM_HOME/clock"; fi
if [ -n "${FAKE_CURL_DELAY:-}" ]; then
  if [ "$FAKE_CURL_DELAY" -ge "$timeout" ]; then sleep "$timeout"; exit 28; fi
  sleep "$FAKE_CURL_DELAY"
fi
if [ -n "${FAKE_CURL_FAIL:-}" ]; then
  exit 7
fi
if [ -n "$hdrfile" ]; then
  {
    printf 'HTTP/1.1 %s X\r\n' "${FAKE_CODE:-200}"
    [ -n "${FAKE_RETRY_AFTER:-}" ] && printf 'Retry-After: %s\r\n' "$FAKE_RETRY_AFTER"
    printf '\r\n'
  } > "$hdrfile"
fi
[ -n "$ofile" ] && printf '%s' "${FAKE_BODY:-{\"id\":\"msg-1\"\}}" > "$ofile"
printf '%s' "${FAKE_CODE:-200}"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# A home with a usable notifier: a 0600 token file and the four .env values.
make_home() {  # <name> [extra .env lines...]
  local name=$1 home
  shift
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf 'tok-secret-value\n' > "$home/ntfy-token"
  chmod 600 "$home/ntfy-token"
  {
    printf 'FM_NTFY_URL=https://ntfy.test\n'
    printf 'FM_NTFY_TOPIC=opaquetopic\n'
    printf 'FM_NTFY_TOKEN_FILE=%s/ntfy-token\n' "$home"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$home/.env"
  printf '%s\n' "$home"
}

# Run one library call in a subshell with the home, fakebin, and stub responses
# applied, so each case gets a clean process.
# FM_NTFY_NOW is forwarded so a case can pin the clock across both the record
# and the drain; empty means the library reads the real clock.
run_lib() {  # <home> <fakebin> <bash-snippet>
  local home=$1 fakebin=$2 snippet=$3
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_NTFY_NOW="${FM_NTFY_NOW:-}" \
    bash -c ". \"\$1\"; $snippet" _ "$LIB"
}

outbox_count() { find "$1/state/ntfy/outbox" -name '*.rec' 2>/dev/null | wc -l | tr -d ' '; }
receipt_count() { find "$1/state/ntfy/receipts" -name '*.rec' 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# Inert by default

test_absent_config_is_inert() {
  local home fakebin log out
  home="$TMP_ROOT/inert"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" status)
  assert_contains "$out" 'ntfy: off' 'an unconfigured home reports off'
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required task-a'
  run_lib "$home" "$fakebin" 'fm_ntfy_drain'
  assert_absent "$home/state/ntfy" 'an unconfigured home must create no ntfy state'
  [ ! -f "$log" ] || fail 'an unconfigured home must make no network request'
  pass 'no configuration means no state, no record, and no network request'
}

test_disabled_record_never_blocks_its_producer() {
  local home fakebin rc
  home="$TMP_ROOT/inert-rc"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  run_lib "$home" "$fakebin" 'fm_ntfy_record pr-ready task-a; exit $?'
  rc=$?
  expect_code 0 "$rc" 'recording in a disabled home'
  pass 'a producer calling the notifier in a disabled home still succeeds'
}

# ---------------------------------------------------------------------------
# Configuration validation

assert_config_refused() {  # <label> <needle> <env assignment>...
  local label=$1 needle=$2 home out
  shift 2
  home="$TMP_ROOT/cfg-$label"
  mkdir -p "$home/state"
  printf 'tok\n' > "$home/ntfy-token"
  chmod 600 "$home/ntfy-token"
  printf '%s\n' "FM_NTFY_TOKEN_FILE=$home/ntfy-token" "$@" > "$home/.env"
  out=$(env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$NTFY" status 2>&1) || true
  assert_contains "$out" "$needle" "$label must be refused"
}

test_config_validation() {
  assert_config_refused remote-http 'must be an https base URL' \
    FM_NTFY_URL=http://ntfy.example.test FM_NTFY_TOPIC=t
  assert_config_refused url-credentials 'must be an https base URL' \
    FM_NTFY_URL=https://user:pass@ntfy.test FM_NTFY_TOPIC=t
  assert_config_refused url-query 'must be an https base URL' \
    FM_NTFY_URL='https://ntfy.test/?auth=abc' FM_NTFY_TOPIC=t
  assert_config_refused empty-topic 'FM_NTFY_TOPIC must be' \
    FM_NTFY_URL=https://ntfy.test FM_NTFY_TOPIC=
  assert_config_refused bad-topic 'FM_NTFY_TOPIC must be' \
    FM_NTFY_URL=https://ntfy.test FM_NTFY_TOPIC='a/b'
  assert_config_refused inline-token 'FM_NTFY_TOKEN is not accepted' \
    FM_NTFY_URL=https://ntfy.test FM_NTFY_TOPIC=t FM_NTFY_TOKEN=inline-secret
  assert_config_refused bad-scope 'FM_NTFY_SCOPE must be' \
    FM_NTFY_URL=https://ntfy.test FM_NTFY_TOPIC=t FM_NTFY_SCOPE=loud
  assert_config_refused bad-links 'FM_NTFY_PR_LINKS must be' \
    FM_NTFY_URL=https://ntfy.test FM_NTFY_TOPIC=t FM_NTFY_PR_LINKS=maybe
  pass 'insecure, credential-bearing, and malformed configuration is refused'
}

test_loopback_http_is_refused() {
  assert_config_refused loopback 'must be an https base URL' \
    FM_NTFY_URL=http://127.0.0.1:8080 FM_NTFY_TOPIC=t
  pass 'production loopback HTTP is refused'
}

test_token_file_permissions_are_enforced() {
  local home out
  home="$TMP_ROOT/cfg-token-mode"; mkdir -p "$home/state"
  printf 'tok\n' > "$home/ntfy-token"
  chmod 644 "$home/ntfy-token"
  printf 'FM_NTFY_URL=https://ntfy.test\nFM_NTFY_TOPIC=t\nFM_NTFY_TOKEN_FILE=%s/ntfy-token\n' "$home" > "$home/.env"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$NTFY" status 2>&1) || true
  assert_contains "$out" 'mode 600' 'a world-readable token file is refused'
  chmod 600 "$home/ntfy-token"
  printf 'FM_NTFY_URL=https://ntfy.test\nFM_NTFY_TOPIC=t\nFM_NTFY_TOKEN_FILE=ntfy-token\n' > "$home/.env"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$NTFY" status 2>&1) || true
  assert_contains "$out" 'absolute path' 'a relative token path is refused'
  pass 'the token file must be absolute and owner-only'
}

# ---------------------------------------------------------------------------
# Secrets never leak

test_token_and_topic_stay_out_of_argv_and_records() {
  local home fakebin log argv
  home=$(make_home secrets)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required task-a'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" FAKE_CODE=200 "$NTFY" check >/dev/null
  assert_grep 'auth=Authorization: Bearer tok-secret-value' "$log" \
    'the bearer token must reach the server'
  argv=$(grep '^argv=' "$log")
  assert_not_contains "$argv" 'tok-secret-value' 'the token must not appear in curl argv'
  assert_not_contains "$argv" 'opaquetopic' 'the topic must not appear in curl argv'
  assert_grep 'url=https://ntfy.test/' "$log" 'the topic must not appear in the request URL'
  ! grep -rlF 'tok-secret-value' "$home/state" >/dev/null 2>&1 \
    || fail 'the token must never be written into firstmate state'
  ! grep -rlF 'opaquetopic' "$home/state" >/dev/null 2>&1 \
    || fail 'the topic must never be written into firstmate state'
  pass 'the token and topic never reach argv or any firstmate record'
}

test_failure_diagnostics_never_quote_the_secret() {
  local home fakebin out
  home=$(make_home secrets-error)
  fakebin=$(make_fake_curl "$home")
  run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed task-a'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=403 "$NTFY" check 2>&1)
  assert_contains "$out" 'refused' 'a refused token is reported'
  assert_not_contains "$out" 'tok-secret-value' 'the report must not quote the token'
  assert_not_contains "$out" 'opaquetopic' 'the report must not quote the topic'
  pass 'a credential failure is reported without quoting the token or topic'
}

# ---------------------------------------------------------------------------
# Event allowlist and minimal projection

test_only_catalog_types_are_publishable() {
  local home fakebin rc
  home=$(make_home allowlist)
  fakebin=$(make_fake_curl "$home")
  run_lib "$home" "$fakebin" 'fm_ntfy_record routine-progress task-a; exit $?'
  rc=$?
  expect_code 2 "$rc" 'an off-catalog type is refused'
  assert_equals 0 "$(outbox_count "$home")" 'an off-catalog type records nothing'
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required task-a'
  assert_equals 1 "$(outbox_count "$home")" 'a catalog type records one intent'
  pass 'only the central event catalog can be published'
}

test_status_projection_keeps_only_the_verb() {
  local home fakebin out
  home=$(make_home projection)
  fakebin=$(make_fake_curl "$home")
  out=$(run_lib "$home" "$fakebin" \
    'fm_ntfy_status_types "needs-decision [key=k]: use ACME Corp secret sk-LEAK ; working: still going"')
  assert_equals 'decision-required' "$out" 'a needs-decision span projects one decision type'
  out=$(run_lib "$home" "$fakebin" \
    'fm_ntfy_status_types "blocked: cannot reach acme-prod
failed: build broke"')
  assert_equals 'work-failed' "$out" 'blocked and failed collapse to one failure type'
  out=$(run_lib "$home" "$fakebin" 'fm_ntfy_status_types "working: rebased onto merged #76"')
  assert_equals '' "$out" 'a routine line projects nothing'
  out=$(run_lib "$home" "$fakebin" 'fm_ntfy_status_types "paused: waiting on a release"')
  assert_equals '' "$out" 'a declared wait projects nothing'
  pass 'the status projection reads the verb and discards worker text'
}

test_minimal_scope_body_is_generic() {
  local home fakebin log payload
  home=$(make_home minimal)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required acme-prod-migration'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  payload=$(grep '^payload=' "$log")
  assert_contains "$payload" 'A decision is waiting for you in firstmate.' \
    'the minimal body is the generic sentence'
  assert_not_contains "$payload" 'acme-prod-migration' \
    'the minimal body must not name the task'
  assert_contains "$payload" '"title":"Firstmate"' 'the title is constant'
  assert_contains "$payload" '"priority":4' 'a decision is high priority'
  pass 'the default minimal scope publishes a generic, project-free body'
}

test_detail_scope_adds_only_the_task_id() {
  local home fakebin log payload
  home=$(make_home detail FM_NTFY_SCOPE=detail)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed alpha-task'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  payload=$(grep '^payload=' "$log")
  assert_contains "$payload" '(alpha-task)' 'the detail body names the task'
  assert_contains "$payload" 'Work stopped and needs you in firstmate.' \
    'the detail body keeps the generic sentence'
  pass 'the opt-in detail scope adds the task id and nothing else'
}

# ---------------------------------------------------------------------------
# Links: allowlisted, view-only

test_links_are_off_by_default() {
  local home fakebin log payload
  home=$(make_home nolinks)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" \
    'fm_ntfy_record pr-ready t1 https://github.com/acme/private/pull/7 pr1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  payload=$(grep '^payload=' "$log")
  assert_not_contains "$payload" 'github.com' 'no link is published with links off'
  assert_not_contains "$payload" '"actions"' 'no action button is published with links off'
  ! grep -rlF 'acme/private' "$home/state" >/dev/null 2>&1 \
    || fail 'a suppressed link must not be stored either'
  pass 'PR links are off by default and are not even recorded'
}

test_allowlisted_link_becomes_a_view_action() {
  local home fakebin log payload
  home=$(make_home links FM_NTFY_PR_LINKS=on)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" \
    'fm_ntfy_record pr-ready t1 https://github.com/acme/widgets/pull/7 pr1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  payload=$(grep '^payload=' "$log")
  assert_contains "$payload" '"click":"https://github.com/acme/widgets/pull/7"' \
    'an allowlisted PR URL becomes the click target'
  assert_contains "$payload" '"action":"view"' 'the only action is view'
  assert_not_contains "$payload" '"action":"http"' 'an http action button is never published'
  pass 'an allowlisted forge URL becomes a view action, never an http button'
}

test_non_forge_links_are_dropped() {
  local home fakebin log payload target
  home=$(make_home badlinks FM_NTFY_PR_LINKS=on)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  for target in \
    'https://evil.test/steal' \
    'http://github.com/acme/widgets/pull/7' \
    'javascript:alert(1)' \
    'https://github.com/acme/widgets/pull/7?token=abc'
  do
    run_lib "$home" "$fakebin" "fm_ntfy_record pr-ready t1 '$target' d-$RANDOM"
  done
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  payload=$(grep -c '^payload=' "$log")
  [ "$payload" -ge 1 ] || fail 'the notifications themselves must still be published'
  assert_no_grep '"actions"' "$log" 'a link outside the forge allowlist is dropped'
  assert_no_grep 'evil.test' "$log" 'a non-forge host never reaches the notification'
  pass 'only firstmate canonical forge URLs survive the link allowlist'
}

# ---------------------------------------------------------------------------
# Durability, duplicates, and restart windows

test_intent_is_durable_before_the_network_call() {
  local home fakebin rec
  home=$(make_home durable)
  fakebin=$(make_fake_curl "$home")
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required t1'
  assert_equals 1 "$(outbox_count "$home")" 'recording writes one durable intent'
  assert_equals 0 "$(receipt_count "$home")" 'no receipt exists before publication'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  assert_grep 'fm-ntfy-outbox-v1' "$rec" 'the intent carries its schema'
  assert_grep 'type=decision-required' "$rec" 'the intent carries its type'
  pass 'a publication intent is durable before any network call happens'
}

test_receipt_suppresses_republication_across_restart() {
  local home fakebin log first
  home=$(make_home dedup)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record merged t1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  first=$(grep -c '^url=' "$log")
  assert_equals 1 "$first" 'the first drain publishes once'
  assert_equals 0 "$(outbox_count "$home")" 'a published intent is retired'
  assert_equals 1 "$(receipt_count "$home")" 'a receipt records the publication'
  # A producer re-running the same event, and a later drain, must both be no-ops.
  run_lib "$home" "$fakebin" 'fm_ntfy_record merged t1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  assert_equals 1 "$(grep -c '^url=' "$log")" \
    'a repeated producer call and a later drain publish nothing more'
  pass 'an identity-bound receipt suppresses republication, including after restart'
}

test_crash_after_receipt_does_not_republish() {
  local home fakebin log rec key
  home=$(make_home crash-window)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record pr-ready t1'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  key=$(basename "$rec" .rec)
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  # Reconstruct the window where the receipt landed but the intent removal did
  # not: both records exist. The receipt is the authority, so the next drain
  # retires the intent without a second publish.
  cp "$home/state/ntfy/receipts/$key.rec" "$home/state/ntfy/receipts/$key.rec.bak"
  printf 'fm-ntfy-outbox-v1\nidentity=pr-ready|t1|\ntype=pr-ready\nlink=\ncreated=1\nattempts=1\nnext=1\n' \
    > "$rec"
  chmod 600 "$rec"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  assert_equals 1 "$(grep -c '^url=' "$log")" \
    'an intent left beside its receipt never publishes again'
  assert_equals 0 "$(outbox_count "$home")" 'the stale intent is retired'
  pass 'the receipt is the authority across the publish-then-record crash window'
}

test_retry_reuses_the_same_sequence_id() {
  local home fakebin log seqs
  home=$(make_home resend)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed t1'
  # First attempt: the transport fails the way an ambiguous timeout does.
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" FAKE_CURL_FAIL=1 "$NTFY" check >/dev/null
  assert_equals 1 "$(outbox_count "$home")" 'an unacknowledged intent is kept'
  assert_equals 0 "$(receipt_count "$home")" 'no receipt is written without a response'
  # Retry once its backoff has elapsed.
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" FM_NTFY_NOW=9999999999 "$NTFY" check >/dev/null
  seqs=$(grep -o '"sequence_id":"[^"]*"' "$log" | sort -u | wc -l | tr -d ' ')
  assert_equals 1 "$seqs" 'the retry reuses the first attempt sequence id'
  assert_equals 1 "$(receipt_count "$home")" 'the retry is acknowledged'
  pass 'an ambiguous failure is retried under the same sequence id, never dropped'
}

# ---------------------------------------------------------------------------
# Server responses

test_auth_failure_keeps_the_event_and_reports_once() {
  local home fakebin out rec next
  home=$(make_home auth-fail)
  fakebin=$(make_fake_curl "$home")
  FM_NTFY_NOW=1000 run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required t1'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=401 FM_NTFY_NOW=1000 "$NTFY" check 2>&1)
  assert_contains "$out" 'HTTP 401' 'a 401 is reported'
  assert_equals 1 "$(outbox_count "$home")" 'a 401 keeps the event'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  next=$(grep '^next=' "$rec" | cut -d= -f2)
  [ "$next" -gt 2000 ] || fail "a 401 must back off hard, got next=$next"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=401 FM_NTFY_NOW=1001 "$NTFY" check 2>&1)
  assert_equals '' "$out" 'a deferred attempt is silent'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=401 FM_NTFY_NOW=99999 "$NTFY" check 2>&1)
  assert_equals '' "$out" 'the same outage stays reported after deferral'
  pass 'a refused token keeps the event, backs off hard, and reports the credential'
}

test_rate_limit_honours_retry_after() {
  local home fakebin rec next
  home=$(make_home rate-limit)
  fakebin=$(make_fake_curl "$home")
  FM_NTFY_NOW=1000 run_lib "$home" "$fakebin" 'fm_ntfy_record merged t1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=429 FAKE_RETRY_AFTER=86400 FM_NTFY_NOW=1000 "$NTFY" check >/dev/null
  assert_equals 1 "$(outbox_count "$home")" 'a 429 keeps the event'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  next=$(grep '^next=' "$rec" | cut -d= -f2)
  [ "$next" -ge 87400 ] || fail "a 429 must wait at least Retry-After, got next=$next"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=429 FAKE_RETRY_AFTER='Sun, 06 Nov 1994 08:49:37 GMT' FM_NTFY_NOW=90000 "$NTFY" check >/dev/null
  next=$(grep '^next=' "$rec" | cut -d= -f2)
  assert_equals 784111777 "$next" 'HTTP-date preserves its full timestamp'
  pass 'a rate limit honours Retry-After and never retries in a loop'
}

test_server_error_backs_off_and_recovers() {
  local home fakebin
  home=$(make_home server-error)
  fakebin=$(make_fake_curl "$home")
  FM_NTFY_NOW=1000 run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed t1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=503 FM_NTFY_NOW=1000 "$NTFY" check >/dev/null
  assert_equals 1 "$(outbox_count "$home")" 'a 5xx keeps the event'
  assert_equals 0 "$(receipt_count "$home")" 'a 5xx writes no receipt'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=200 FM_NTFY_NOW=9999999999 "$NTFY" check >/dev/null
  assert_equals 1 "$(receipt_count "$home")" 'the event is delivered once the server recovers'
  pass 'a server outage defers the event and delivers it after recovery'
}

test_parked_event_reports_but_is_never_discarded() {
  local home fakebin rec out
  home=$(make_home parked)
  fakebin=$(make_fake_curl "$home")
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required t1'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  printf 'fm-ntfy-outbox-v1\nidentity=decision-required|t1|\ntype=decision-required\nlink=\ncreated=1\nattempts=99\nnext=1\n' \
    > "$rec"
  chmod 600 "$rec"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_NTFY_NOW=1000 "$NTFY" check 2>&1)
  assert_contains "$out" 'parked' 'an exhausted event is reported'
  assert_equals 1 "$(outbox_count "$home")" 'an exhausted event is kept, never discarded'
  pass 'an event that exhausts its retries is reported and retained, never lost'
}

test_standing_condition_reports_once() {
  local home fakebin first second third
  home=$(make_home report-once)
  fakebin=$(make_fake_curl "$home")
  printf 'FM_NTFY_URL=https://ntfy.test\nFM_NTFY_TOPIC=t\n' > "$home/.env"
  first=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" check 2>&1)
  second=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" check 2>&1)
  assert_contains "$first" 'FM_NTFY_TOKEN_FILE' 'the condition is reported the first time'
  assert_equals '' "$second" 'an unchanged standing condition does not report again'
  # A different condition is a new fact and must be reported.
  printf 'FM_NTFY_URL=https://ntfy.test\nFM_NTFY_TOPIC=not a topic\nFM_NTFY_TOKEN_FILE=%s/ntfy-token\n' \
    "$home" > "$home/.env"
  third=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" check 2>&1)
  assert_contains "$third" 'FM_NTFY_TOPIC' 'a changed condition is reported'
  pass 'a standing notifier problem wakes firstmate once, not on every check'
}

test_resolved_condition_can_report_again() {
  local home fakebin out
  home=$(make_home report-recurrence)
  fakebin=$(make_fake_curl "$home")
  FM_NTFY_NOW=1000 run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required t1'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=401 FM_NTFY_NOW=1000 "$NTFY" check 2>&1)
  assert_contains "$out" 'HTTP 401' 'the credential failure is reported'
  # Recover, then break again: the second outage must be reported, not swallowed
  # by the first one's record.
  FM_NTFY_NOW=2000 run_lib "$home" "$fakebin" 'fm_ntfy_record merged t2'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=200 FM_NTFY_NOW=2000 "$NTFY" check >/dev/null 2>&1
  FM_NTFY_NOW=3000 run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed t3'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=401 FM_NTFY_NOW=3000 "$NTFY" check 2>&1)
  assert_contains "$out" 'HTTP 401' 'a condition that returns after recovery is reported again'
  pass 'a notifier problem that clears and returns is reported again'
}

test_healthy_drain_is_silent() {
  local home fakebin out
  home=$(make_home silent)
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" check 2>&1)
  assert_equals '' "$out" 'a drain with nothing to do prints nothing'
  run_lib "$home" "$fakebin" 'fm_ntfy_record merged t1'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=200 "$NTFY" check 2>&1)
  assert_equals '' "$out" 'a successful drain prints nothing'
  pass 'the standing delivery check is silent unless an operator must act'
}

test_misconfiguration_is_reported_by_the_check() {
  local home fakebin out
  home=$(make_home broken-config)
  fakebin=$(make_fake_curl "$home")
  printf 'FM_NTFY_URL=https://ntfy.test\nFM_NTFY_TOPIC=t\n' > "$home/.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" check 2>&1)
  assert_contains "$out" 'FM_NTFY_TOKEN_FILE' 'a half-configured channel is reported'
  pass 'a half-configured notifier wakes firstmate instead of failing silently'
}

# ---------------------------------------------------------------------------
# Isolation and authority

test_homes_are_isolated() {
  local home_a home_b fakebin log_a
  home_a=$(make_home iso-a)
  home_b="$TMP_ROOT/iso-b"; mkdir -p "$home_b/state"
  fakebin=$(make_fake_curl "$home_a")
  log_a="$home_a/curl.log"
  run_lib "$home_a" "$fakebin" 'fm_ntfy_record decision-required t1'
  run_lib "$home_b" "$fakebin" 'fm_ntfy_record decision-required t1'
  assert_equals 1 "$(outbox_count "$home_a")" 'the configured home records its own event'
  assert_absent "$home_b/state/ntfy" 'an unconfigured sibling home records nothing'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home_b" FM_STATE_OVERRIDE="$home_b/state" \
    FAKE_CURL_LOG="$log_a" "$NTFY" check >/dev/null
  [ ! -f "$log_a" ] || fail 'one home must never publish another home queue'
  pass 'two homes on one machine share no configuration, records, or delivery'
}

test_ntfy_state_never_mutates_firstmate() {
  local home fakebin before after
  home=$(make_home no-mutation)
  fakebin=$(make_fake_curl "$home")
  mkdir -p "$home/state"
  printf 'needs-decision [key=k]: choose\n' > "$home/state/t1.status"
  printf '' > "$home/state/.wake-queue"
  before=$(cd "$home/state" && find . -maxdepth 1 -type f -exec cksum {} + | sort)
  run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required t1'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CODE=200 "$NTFY" check >/dev/null
  after=$(cd "$home/state" && find . -maxdepth 1 -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" \
    'publishing must not touch the status log, the wake queue, or any other record'
  assert_equals 1 "$(receipt_count "$home")" 'the publication itself did happen'
  pass 'recording and publishing change no firstmate record outside state/ntfy'
}

test_self_test_never_fabricates_a_fleet_event() {
  local home fakebin log out payload
  home=$(make_home selftest)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" FAKE_CODE=200 "$NTFY" test)
  assert_contains "$out" 'accepted' 'a successful self-test reports acceptance'
  assert_contains "$out" 'not delivered' 'acceptance is distinguished from delivery'
  payload=$(grep '^payload=' "$log")
  assert_contains "$payload" 'self-test' 'the self-test says what it is'
  assert_not_contains "$payload" 'decision' 'the self-test cannot look like a real event'
  assert_equals 0 "$(outbox_count "$home")" 'the self-test leaves no intent behind'
  assert_equals 0 "$(receipt_count "$home")" 'the self-test leaves no receipt behind'
  pass 'the transport self-test proves delivery without inventing a fleet event'
}

test_arm_requires_a_usable_configuration() {
  local home fakebin out rc=0
  home="$TMP_ROOT/arm-unconfigured"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" arm 2>&1) || rc=$?
  expect_code 1 "$rc" 'arming an unconfigured home'
  assert_contains "$out" 'no notifier configured' 'the refusal names the missing setup'
  assert_absent "$home/state/ntfy.check.sh" 'no shim is left behind by a refused arm'
  pass 'arming refuses a home that cannot publish, leaving no unbound shim'
}

test_arm_and_disarm_round_trip() {
  local home fakebin out
  home=$(make_home arm-ok)
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" arm)
  assert_contains "$out" 'armed: state/ntfy.check.sh' 'arming reports the shim'
  assert_present "$home/state/ntfy.check.sh" 'the shim exists'
  assert_present "$home/state/ntfy.check-trust" 'the shim is bound'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" status)
  assert_contains "$out" 'armed=yes' 'status reports the armed check'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$NTFY" disarm)
  assert_contains "$out" 'disarmed' 'disarming reports it'
  assert_absent "$home/state/ntfy.check.sh" 'the shim is gone'
  assert_absent "$home/state/ntfy.check-trust" 'the binding is gone'
  pass 'the standing delivery check arms and disarms through the trusted check path'
}

# ---------------------------------------------------------------------------
# Producers

test_pr_registration_records_pr_ready() {
  local home fakebin task
  home=$(make_home producer-pr FM_NTFY_PR_LINKS=on)
  fakebin=$(make_fake_curl "$home")
  task=pr-producer
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-$task" "worktree=$home" "project=p" "mode=no-mistakes" "yolo=off"
  chmod 600 "$home/state/$task.meta"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-check.sh" "$task" https://github.com/acme/widgets/pull/42 >/dev/null
  assert_equals 1 "$(outbox_count "$home")" 'registering a PR records one notification'
  assert_grep 'type=pr-ready' \
    "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" \
    'the recorded type is pr-ready'
  assert_grep 'link=https://github.com/acme/widgets/pull/42' \
    "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" \
    'the canonical PR URL is carried as the link'
  pass 'registering a ready PR records exactly one pr-ready notification'
}

test_merge_outcome_records_merged() {
  local home fakebin task
  home=$(make_home producer-merge)
  fakebin=$(make_fake_curl "$home")
  task=merge-producer
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_merge_outcome_report "$2" "$2/state" "$3" "$4" self' \
    _ "$ROOT/bin/fm-merge-outcome-lib.sh" "$home" "$task" \
    https://github.com/acme/widgets/pull/42 >/dev/null
  assert_equals 1 "$(outbox_count "$home")" 'a confirmed merge records one notification'
  assert_grep 'type=merged' \
    "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" \
    'the recorded type is merged'
  pass 'a confirmed merge records exactly one delivery notification'
}

test_watcher_projects_a_captain_relevant_span() {
  local home fakebin out
  home=$(make_home producer-watch)
  fakebin=$(make_fake_curl "$home")
  printf 'working: started\nneeds-decision [key=k]: ACME Corp wants option B\n' \
    > "$home/state/watch-task.status"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" bash -c \
    '. "$1"; signal_files_actionable "$2/state/watch-task.status"; echo "rc=$?"' \
    _ "$ROOT/bin/fm-watch.sh" "$home")
  assert_contains "$out" 'rc=0' 'the span classifies as actionable'
  assert_equals 1 "$(outbox_count "$home")" 'one decision notification is recorded'
  assert_grep 'type=decision-required' \
    "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" \
    'the recorded type is decision-required'
  assert_no_grep 'ACME Corp' \
    "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" \
    'the worker text must not be recorded'
  pass 'the watcher projects a captain-relevant span without copying worker text'
}

test_away_mode_publishes_the_same_taxonomy() {
  local home fakebin log away_payload
  home=$(make_home away)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # The away posture record is the posture in every harness. It changes how
  # firstmate informs the captain, never what authority anything has, so the
  # pager must publish exactly the same event with exactly the same body.
  printf 'away\n' > "$home/state/.afk-contract"
  printf 'needs-decision [key=k]: pick one\n' > "$home/state/away-task.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" bash -c \
    '. "$1"; signal_files_actionable "$2/state/away-task.status" || true' \
    _ "$ROOT/bin/fm-watch.sh" "$home" >/dev/null 2>&1
  assert_equals 1 "$(outbox_count "$home")" 'the away posture still records the decision'
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_LOG="$log" "$NTFY" check >/dev/null
  away_payload=$(grep '^payload=' "$log")
  assert_contains "$away_payload" 'A decision is waiting for you in firstmate.' \
    'the away body is the same generic sentence'
  assert_contains "$away_payload" '"priority":4' 'the away priority is unchanged'
  assert_not_contains "$away_payload" '"action"' 'away mode grants no extra affordance'
  pass 'the away posture publishes the same taxonomy with no extra authority'
}

test_watcher_records_nothing_for_a_routine_span() {
  local home fakebin
  home=$(make_home producer-watch-routine)
  fakebin=$(make_fake_curl "$home")
  printf 'working: still going\n' > "$home/state/routine-task.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" bash -c \
    '. "$1"; signal_files_actionable "$2/state/routine-task.status" || true' \
    _ "$ROOT/bin/fm-watch.sh" "$home" >/dev/null 2>&1
  assert_equals 0 "$(outbox_count "$home")" 'routine progress records nothing'
  pass 'routine progress never reaches the pager'
}

# ---------------------------------------------------------------------------

test_interrupted_delivery_replays() {
  local home fakebin log window snippet expected
  for window in before during after; do
    home=$(make_home "interrupted-$window")
    fakebin=$(make_fake_curl "$home")
    log="$home/curl.log"
    printf 'needs-decision: retained source\n' > "$home/state/t1.status"
    cp "$home/state/t1.status" "$home/source-before"
    run_lib "$home" "$fakebin" 'fm_ntfy_record decision-required t1'
    case "$window" in
      before) snippet='_fm_ntfy_publish() { kill -KILL $$; }; fm_ntfy_drain'; expected=1 ;;
      during) snippet='export CRASH_PID=$$; fm_ntfy_drain'; expected=2 ;;
      after) snippet='_fm_ntfy_receipt_write() { kill -KILL $$; }; fm_ntfy_drain'; expected=2 ;;
    esac
    FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" "$snippet" >/dev/null 2>&1 || true
    assert_equals 1 "$(outbox_count "$home")" "$window crash retains intent"
    assert_equals 0 "$(receipt_count "$home")" "$window crash has no receipt"
    FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" 'fm_ntfy_drain'
    assert_equals "$expected" "$(grep -c '^url=' "$log")" "$window crash replays on restart"
    assert_equals 1 "$(grep -o '"sequence_id":"[^"]*"' "$log" | sort -u | wc -l | tr -d ' ')" 'replay preserves sequence identity'
    assert_equals 1 "$(receipt_count "$home")" 'restart saves receipt'
    cmp "$home/source-before" "$home/state/t1.status" || fail 'source state changed'
  done
  pass 'all three interrupted delivery windows replay without consuming source state'
}

test_receipt_write_failure_retains_intent() {
  local home fakebin rec key out
  home=$(make_home receipt-failure)
  fakebin=$(make_fake_curl "$home")
  run_lib "$home" "$fakebin" 'fm_ntfy_record pr-ready t1'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  key=$(basename "$rec")
  mkdir "$home/state/ntfy/receipts/$key"
  out=$(run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_contains "$out" 'receipt could not be saved' 'receipt failure is reported'
  assert_present "$rec" 'receipt failure retains intent'
  rmdir "$home/state/ntfy/receipts/$key"
  run_lib "$home" "$fakebin" 'fm_ntfy_drain'
  assert_equals 1 "$(receipt_count "$home")" 'receipt recovery succeeds'
  pass 'failed atomic receipt creation preserves replay'
}

test_queued_link_opt_out() {
  local home fakebin log
  home=$(make_home queued-link FM_NTFY_PR_LINKS=on)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record pr-ready t1 https://github.com/acme/private/pull/1'
  make_home queued-link FM_NTFY_PR_LINKS=off >/dev/null
  FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" 'fm_ntfy_drain'
  assert_no_grep 'github.com\|"click"\|"actions"' "$log" 'opt-out removes queued repository links'
  pass 'publication reapplies current link privacy'
}

test_ambient_config_is_inert() {
  local home fakebin donor log
  donor=$(make_home ambient-donor)
  home="$TMP_ROOT/ambient-recipient"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  FM_NTFY_URL=https://ntfy.test FM_NTFY_TOPIC=donor FM_NTFY_TOKEN_FILE="$donor/ntfy-token" \
    FM_NTFY_SCOPE=detail FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" \
    'fm_ntfy_record decision-required private-task; fm_ntfy_drain'
  assert_absent "$home/state/ntfy" 'ambient donor configuration cannot opt in another home'
  assert_absent "$log" 'ambient donor configuration makes no request'
  pass 'home opt-in cannot leak through ambient configuration'
}

test_drain_budget() {
  local home fakebin start elapsed log
  home=$(make_home budget)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'for id in a b c d; do fm_ntfy_record work-failed "$id"; done'
  start=$SECONDS
  FAKE_CURL_DELAY=10 FAKE_CURL_FAIL=1 FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" 'fm_ntfy_drain'
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 27 ] || fail "drain exceeded reserved budget: $elapsed"
  [ "$(grep -c '^url=' "$log")" -le 2 ] || fail 'too many slow requests'
  assert_equals 4 "$(outbox_count "$home")" 'outage retains all intents'
  assert_grep 'attempts=1' "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" 'attempt results persist before returning'
  pass 'drain reserves watcher time for persistent results'
}

test_captain_hold_projection() {
  local home fakebin variant
  for variant in hold transfer; do
    home=$(make_home "captain-$variant")
    fakebin=$(make_fake_curl "$home")
    if [ "$variant" = transfer ]; then
      printf 'needs-decision [key=k]: private choice\n' > "$home/state/t1.status"
    fi
    printf 'captain-held [key=k]: private choice\n' >> "$home/state/t1.status"
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1"; signal_files_actionable "$2/state/t1.status"; signal_files_actionable "$2/state/t1.status"' \
      _ "$ROOT/bin/fm-watch.sh" "$home"
    assert_equals 1 "$(outbox_count "$home")" 'captain hold gets one stable decision identity'
    assert_grep 'type=decision-required' "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" 'hold projects a decision'
  done
  pass 'captain holds project even when classifier event text is empty'
}

test_short_watcher_budget() {
  local home fakebin log out rec
  home=$(make_home short-budget)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed t1'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECK_TIMEOUT=5 FAKE_CURL_DELAY=10 FAKE_CURL_LOG="$log" \
    bash -c '. "$1"; ( run_check_process "$2" check ); printf "rc=%s" "$?"' \
    _ "$ROOT/bin/fm-watch.sh" "$NTFY")
  assert_contains "$out" 'rc=0' 'short watcher deadline does not kill the drain'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  assert_grep 'attempts=1' "$rec" 'short-budget timeout persists its attempt'
  run_lib "$home" "$fakebin" 'fm_ntfy_drain'
  assert_grep 'attempts=1' "$rec" 'next cadence respects persisted backoff'
  awk '/^argv=/ { for (i=1; i<NF; i++) if ($i == "-m") { seen=1; if ($(i+1) <= 0 || $(i+1) > 3) bad=1 } } END { exit (!seen || bad) }' \
    "$log" || fail 'request must fit actual watcher budget'
  pass 'custom watcher timeout reserves time to persist failures'
}

test_response_time_retry_deadlines() {
  local home fakebin form after rec next
  for form in seconds date; do
    home=$(make_home "response-time-$form")
    fakebin=$(make_fake_curl "$home")
    printf '1000' > "$home/clock"
    run_lib "$home" "$fakebin" '_fm_ntfy_now() { cat "$FM_HOME/clock"; }; fm_ntfy_record merged t1'
    after=60
    [ "$form" != date ] || after='Thu, 01 Jan 1970 00:17:50 GMT'
    FAKE_CODE=429 FAKE_RESPONSE_TIME=1010 FAKE_RETRY_AFTER="$after" run_lib "$home" "$fakebin" \
      '_fm_ntfy_now() { cat "$FM_HOME/clock"; }; fm_ntfy_drain'
    rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
    next=$(grep '^next=' "$rec" | cut -d= -f2)
    assert_equals 1070 "$next" "$form Retry-After is anchored at response receipt"
  done
  pass 'both Retry-After forms use response-time timestamps'
}

test_configuration_recovery_without_publication() {
  local home fakebin first out
  home=$(make_home config-recovery)
  fakebin=$(make_fake_curl "$home")
  mv "$home/ntfy-token" "$home/saved-token"
  first=$(run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_contains "$first" 'FM_NTFY_TOKEN_FILE' 'missing token reports configuration failure'
  mv "$home/saved-token" "$home/ntfy-token"
  out=$(run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_equals '' "$out" 'healthy empty drain clears configuration failure silently'
  mv "$home/ntfy-token" "$home/saved-token"
  out=$(run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_equals "$first" "$out" 'configuration relapse reports again without a publication'
  pass 'configuration validation independently proves configuration recovery'
}

test_decision_opening_survives_transfer() {
  local home fakebin log count phase
  home=$(make_home decision-opening)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf 'needs-decision [key=k]: private choice\n' > "$home/state/t1.status"
  for phase in open transfer reopen; do
    case "$phase" in
      transfer) printf 'captain-held [key=k]: private choice\n' >> "$home/state/t1.status" ;;
      reopen) printf 'resolved [key=k]: answered\nneeds-decision [key=k]: new choice\n' >> "$home/state/t1.status" ;;
    esac
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1"; signal_files_actionable "$2/state/t1.status"; fm_wake_status_mark_current "$2/state" "$2/state/t1.status"' \
      _ "$ROOT/bin/fm-watch.sh" "$home"
    FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" 'fm_ntfy_drain'
    count=1
    [ "$phase" != reopen ] || count=2
    assert_equals "$count" "$(grep -c '^url=' "$log")" "$phase preserves or advances decision-opening identity"
  done
  assert_equals 2 "$(grep -o '"sequence_id":"[^"]*"' "$log" | sort -u | wc -l | tr -d ' ')" 'reopened key has a new sequence identity'
  pass 'decision transfer reuses its opening receipt while reopening publishes anew'
}

test_unusable_delivery_budget_reports_once() {
  local home fakebin log first second rec
  home=$(make_home unusable-budget)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  run_lib "$home" "$fakebin" 'fm_ntfy_record work-failed t1'
  first=$(FM_CHECK_TIMEOUT=1 FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_contains "$first" 'FM_CHECK_TIMEOUT cannot accommodate notification delivery' 'unusable budget is explicit'
  second=$(FM_CHECK_TIMEOUT=1 run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_equals '' "$second" 'unchanged timeout diagnostic is deduplicated'
  assert_absent "$log" 'unusable budget makes no request'
  rec=$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)
  assert_grep 'attempts=0' "$rec" 'unattempted intent is retained unchanged'
  FM_CHECK_TIMEOUT=5 FAKE_CURL_LOG="$log" run_lib "$home" "$fakebin" 'fm_ntfy_drain'
  assert_equals 1 "$(receipt_count "$home")" 'restoring usable timeout delivers pending intent'
  second=$(FM_CHECK_TIMEOUT=1 run_lib "$home" "$fakebin" 'fm_ntfy_drain')
  assert_equals "$first" "$second" 'timeout relapse is reported after recovery'
  pass 'unusable timeout reports once and delivery resumes after recovery'
}

test_status_prose_cannot_invent_events() {
  local home fakebin
  home=$(make_home prose-delimiter)
  fakebin=$(make_fake_curl "$home")
  printf 'done: checks complete ; failed: 0 ; blocked: 0\n' > "$home/state/t1.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; signal_files_actionable "$2/state/t1.status"' _ "$ROOT/bin/fm-watch.sh" "$home"
  assert_equals 0 "$(outbox_count "$home")" 'verbs in worker prose never become failure events'
  printf 'failed: actual failure ; done: cleanup complete\n' >> "$home/state/t1.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; signal_files_actionable "$2/state/t1.status"' _ "$ROOT/bin/fm-watch.sh" "$home"
  assert_equals 1 "$(outbox_count "$home")" 'a separate classified failure record still notifies'
  assert_grep 'type=work-failed' "$(find "$home/state/ntfy/outbox" -name '*.rec' | head -1)" 'actual failure retains its event type'
  pass 'projection uses classified record boundaries instead of presentation delimiters'
}

test_absent_config_is_inert
test_disabled_record_never_blocks_its_producer
test_unusable_delivery_budget_reports_once
test_status_prose_cannot_invent_events
test_short_watcher_budget
test_response_time_retry_deadlines
test_configuration_recovery_without_publication
test_decision_opening_survives_transfer
test_config_validation
test_loopback_http_is_refused
test_token_file_permissions_are_enforced
test_token_and_topic_stay_out_of_argv_and_records
test_failure_diagnostics_never_quote_the_secret
test_only_catalog_types_are_publishable
test_status_projection_keeps_only_the_verb
test_minimal_scope_body_is_generic
test_detail_scope_adds_only_the_task_id
test_links_are_off_by_default
test_allowlisted_link_becomes_a_view_action
test_non_forge_links_are_dropped
test_intent_is_durable_before_the_network_call
test_receipt_suppresses_republication_across_restart
test_crash_after_receipt_does_not_republish
test_interrupted_delivery_replays
test_receipt_write_failure_retains_intent
test_queued_link_opt_out
test_ambient_config_is_inert
test_drain_budget
test_captain_hold_projection
test_retry_reuses_the_same_sequence_id
test_auth_failure_keeps_the_event_and_reports_once
test_rate_limit_honours_retry_after
test_server_error_backs_off_and_recovers
test_parked_event_reports_but_is_never_discarded
test_healthy_drain_is_silent
test_standing_condition_reports_once
test_resolved_condition_can_report_again
test_misconfiguration_is_reported_by_the_check
test_homes_are_isolated
test_ntfy_state_never_mutates_firstmate
test_self_test_never_fabricates_a_fleet_event
test_arm_requires_a_usable_configuration
test_arm_and_disarm_round_trip
test_pr_registration_records_pr_ready
test_merge_outcome_records_merged
test_watcher_projects_a_captain_relevant_span
test_watcher_records_nothing_for_a_routine_span
test_away_mode_publishes_the_same_taxonomy
