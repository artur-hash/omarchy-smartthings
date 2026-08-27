#!/usr/bin/env bash
# Backend tests. Every external command the backend touches is faked on PATH,
# so nothing here reaches the network or the real keyring.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/smartthings"
PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  export SECRET_STORE="$TMP/secret"
  export PATH="$TMP/bin:$PATH"
  mkdir -p "$TMP/bin"
  # Mirrors real libsecret: reads all of stdin, then strips exactly one trailing
  # newline. Not `cat > file`, which strips none and would let a token with an
  # embedded newline through undetected.
  cat >"$TMP/bin/secret-tool" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  store)
    data=$(cat; printf x); data="${data%x}"
    [[ $data == *$'\n' ]] && data="${data%$'\n'}"
    printf '%s' "$data" > "$SECRET_STORE" ;;
  lookup) [[ -f $SECRET_STORE ]] || exit 1; cat "$SECRET_STORE" ;;
  clear)  rm -f "$SECRET_STORE" ;;
esac
FAKE
  chmod +x "$TMP/bin/secret-tool"
}
teardown() { rm -rf "$TMP"; }

ok()    { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }

# Fake curl that records its arguments and stdin, prints a fixture, then the
# status code on its own line -- the shape real curl produces with -w.
fake_curl() {
  local status="$1" body_file="$2"
  cat >"$TMP/bin/curl" <<FAKE
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$TMP/curl.args"
cat >> "$TMP/curl.stdin"
cat "$body_file"
printf '\n%s' "$status"
FAKE
  chmod +x "$TMP/bin/curl"
}

# Routes by URL so a test can distinguish /locations from /rooms, /health from
# /status, and give each its own status code.
fake_curl_router() {
  cat >"$TMP/bin/curl" <<FAKE
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$TMP/curl.args"
cat >> "$TMP/curl.stdin"
url="\$(printf '%s ' "\$@")"
route() { cat "\$1"; printf '\n%s' "\$2"; exit 0; }
$1
printf '{}'
printf '\n200'
FAKE
  chmod +x "$TMP/bin/curl"
}

with_token() { printf 'tok-abc' | "$BIN" token set >/dev/null 2>&1; }

# ------------------------------------------------------------------- token --

test_token_comes_from_stdin_only() {
  setup
  out=$(printf 'secret-value' | "$BIN" token set 2>&1); rc=$?
  check "a token on stdin is accepted" "$rc" "0"
  check "and stored verbatim" "$(cat "$SECRET_STORE")" "secret-value"

  out=$("$BIN" token set secret-value 2>&1); rc=$?
  check "a token as an argument is refused" "$rc" "2"
  grep -q 'stdin' <<<"$out" && ok "and the refusal says why" || bad "and the refusal says why" "$out"
  teardown
}

test_token_rejects_control_characters() {
  setup
  # printf, not $(...): command substitution strips the newline and the test
  # would silently pass on a string that never contained one.
  out=$(printf 'abc\ndef' | "$BIN" token set 2>&1); rc=$?
  check "an embedded newline is refused" "$rc" "2"
  [[ -f $SECRET_STORE ]] && bad "nothing is stored on refusal" "store exists" \
                          || ok "nothing is stored on refusal"
  teardown
}

test_token_status_and_clear() {
  setup
  check "no token reports hasToken false" "$("$BIN" token status)" '{"hasToken":false}'
  with_token
  check "a stored token reports hasToken true" "$("$BIN" token status)" '{"hasToken":true}'
  "$BIN" token clear >/dev/null
  check "clearing removes it" "$("$BIN" token status)" '{"hasToken":false}'
  teardown
}

# The single most important property in this backend: the token must never
# reach argv, where /proc/<pid>/cmdline exposes it to every process on the
# session for the life of the call.
test_token_never_reaches_curl_argv() {
  setup
  with_token
  printf '{"items":[]}' > "$TMP/empty.json"
  fake_curl 200 "$TMP/empty.json"
  "$BIN" devices >/dev/null 2>&1
  grep -q 'tok-abc' "$TMP/curl.args" && bad "the token is absent from curl's arguments" \
    "$(cat "$TMP/curl.args")" || ok "the token is absent from curl's arguments"
  grep -q 'tok-abc' "$TMP/curl.stdin" && ok "it arrives on stdin instead" \
    || bad "it arrives on stdin instead" "$(cat "$TMP/curl.stdin")"
  teardown
}

# -------------------------------------------------------------- http bounds --

# omarchy-shell is one long-lived process shared by every widget and the QML
# side collects this helper's whole stdout, so an unbounded response is a way
# for whatever answers on the socket to exhaust the bar rather than just this
# plugin.
test_oversized_response_is_refused() {
  setup
  with_token
  { printf '{"pad":"'; head -c 2097152 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$TMP/huge.json"
  fake_curl 200 "$TMP/huge.json"
  out=$("$BIN" devices 2>&1); rc=$?
  check "an oversized response exits 10" "$rc" "10"
  grep -q 'exceeded' <<<"$out" && ok "and says it was refused" || bad "and says it was refused" "$out"
  teardown
}

test_ordinary_response_is_untouched() {
  setup
  with_token
  printf '{"items":[{"deviceId":"a","label":"Lamp","components":[{"capabilities":[{"id":"switch"}]}]}]}' > "$TMP/d.json"
  fake_curl 200 "$TMP/d.json"
  out=$("$BIN" devices 2>&1); rc=$?
  check "an ordinary response exits 0" "$rc" "0"
  check "and is shaped" "$(jq -r '.devices[0].label' <<<"$out")" "Lamp"
  teardown
}

test_remote_strings_and_lists_are_clamped() {
  setup
  with_token
  long=$(head -c 5000 /dev/zero | tr '\0' 'L')
  jq -n --arg l "$long" '{items:[{deviceId:"a", label:$l,
    components:[{capabilities: [range(5000) | {id: ("cap" + tostring)}]}]}]}' > "$TMP/long.json"
  fake_curl 200 "$TMP/long.json"
  out=$("$BIN" devices 2>&1)
  check "a long label is clamped to MAX_STRING" "$(jq -r '.devices[0].label | length' <<<"$out")" "128"
  check "a long capability list is capped to MAX_LIST" "$(jq -r '.devices[0].caps | length' <<<"$out")" "64"
  teardown
}

test_401_clears_the_token() {
  setup
  with_token
  printf '{"error":"nope"}' > "$TMP/e.json"
  fake_curl 401 "$TMP/e.json"
  out=$("$BIN" devices 2>&1); rc=$?
  check "a rejected token exits 3" "$rc" "3"
  check "and is removed from the keyring" "$("$BIN" token status)" '{"hasToken":false}'
  teardown
}

test_429_is_named_as_rate_limiting() {
  setup
  with_token
  printf '{}' > "$TMP/e.json"
  fake_curl 429 "$TMP/e.json"
  out=$("$BIN" devices 2>&1); rc=$?
  check "rate limiting exits 7" "$rc" "7"
  grep -qi 'rate limited' <<<"$out" && ok "and is named" || bad "and is named" "$out"
  teardown
}

# ------------------------------------------------------------------- rooms --

# Room names live behind location scopes a device-only token does not have.
# That is an ordinary configuration, not a fault: the panel shows a flat list
# and says nothing about it.
test_missing_location_scope_degrades_quietly() {
  setup
  with_token
  printf '{}' > "$TMP/forbidden.json"
  fake_curl 403 "$TMP/forbidden.json"
  out=$("$BIN" rooms 2>&1); rc=$?
  check "a 403 on locations still exits 0" "$rc" "0"
  check "and reports itself unscoped" "$(jq -r '.scoped' <<<"$out")" "false"
  check "with no rooms" "$(jq -r '.rooms | length' <<<"$out")" "0"
  teardown
}

test_location_scope_returns_room_names() {
  setup
  with_token
  printf '{"items":[{"locationId":"11111111-2222-3333-4444-555555555555"}]}' > "$TMP/loc.json"
  printf '{"items":[{"roomId":"r1","name":"Sala"},{"roomId":"r2","name":"Quarto"}]}' > "$TMP/rooms.json"
  fake_curl_router '
    case "$url" in
      *"/rooms"*)     route "'"$TMP"'/rooms.json" 200 ;;
      *"/locations"*) route "'"$TMP"'/loc.json" 200 ;;
    esac'
  out=$("$BIN" rooms 2>&1); rc=$?
  check "a scoped token exits 0" "$rc" "0"
  check "and reports itself scoped" "$(jq -r '.scoped' <<<"$out")" "true"
  check "with the room named" "$(jq -r '.rooms.r1' <<<"$out")" "Sala"
  teardown
}

# ------------------------------------------------------------------ status --

test_status_shapes_one_device() {
  setup
  with_token
  cat > "$TMP/st.json" <<'JSON'
{"components":{"main":{
  "switch":{"switch":{"value":"on"}},
  "audioVolume":{"volume":{"value":21}},
  "audioMute":{"mute":{"value":"unmuted"}},
  "mediaPlayback":{"supportedPlaybackCommands":{"value":["play","pause"]}},
  "mediaInputSource":{"supportedInputSources":{"value":[]}},
  "temperatureMeasurement":{"temperature":{"value":22,"unit":"C"}}}}}
JSON
  fake_curl 200 "$TMP/st.json"
  out=$("$BIN" status --device tv-1 2>&1)
  check "the device id is carried through" "$(jq -r '.statuses[0].id' <<<"$out")" "tv-1"
  check "switch"      "$(jq -r '.statuses[0].switch' <<<"$out")"  "on"
  check "volume"      "$(jq -r '.statuses[0].volume' <<<"$out")"  "21"
  check "temperature" "$(jq -r '.statuses[0].temperature' <<<"$out")" "22"
  check "an unpublished input list is empty, not missing" \
    "$(jq -r '.statuses[0].supported.input | length' <<<"$out")" "0"
  check "a published playback list survives" \
    "$(jq -r '.statuses[0].supported.playback | length' <<<"$out")" "2"
  teardown
}

# There is no bulk status endpoint -- both /devices/status and /devices/health
# answer HTTP 400 -- so several devices cost several requests. They are made
# sequentially inside this one process: the limit that bites is a burst limit,
# and a fan-out of concurrent children is exactly the shape to avoid.
test_several_devices_are_fetched_in_one_process() {
  setup
  with_token
  printf '{"components":{"main":{"switch":{"switch":{"value":"off"}}}}}' > "$TMP/st.json"
  fake_curl 200 "$TMP/st.json"
  out=$("$BIN" status --device a --device b --device c 2>&1)
  check "every device is returned" "$(jq -r '.statuses | length' <<<"$out")" "3"
  check "in the order asked for" "$(jq -r '[.statuses[].id] | join(",")' <<<"$out")" "a,b,c"
  check "one request each, and no more" "$(grep -o '/status' "$TMP/curl.args" | wc -l)" "3"
  teardown
}

# Reachability is a separate call, so the panel pays for it only where it
# changes what is shown.
test_health_is_opt_in() {
  setup
  with_token
  printf '{"components":{"main":{}}}' > "$TMP/st.json"
  fake_curl 200 "$TMP/st.json"
  "$BIN" status --device a >/dev/null 2>&1
  check "no health call without --health" "$(grep -c '/health' "$TMP/curl.args" || true)" "0"
  check "and online is unknown, not false" \
    "$("$BIN" status --device a 2>/dev/null | jq -r '.statuses[0].online')" "null"
  teardown
}

test_health_marks_a_device_online() {
  setup
  with_token
  printf '{"state":"ONLINE"}' > "$TMP/h.json"
  printf '{"components":{"main":{}}}' > "$TMP/st.json"
  fake_curl_router '
    case "$url" in
      *"/health"*) route "'"$TMP"'/h.json" 200 ;;
      *"/status"*) route "'"$TMP"'/st.json" 200 ;;
    esac'
  out=$("$BIN" status --health --device a 2>&1)
  check "--health resolves reachability" "$(jq -r '.statuses[0].online' <<<"$out")" "true"
  teardown
}

# ------------------------------------------------------------------- send --

test_send_builds_the_command_body() {
  setup
  with_token
  printf '{"results":[{"status":"COMPLETED"}]}' > "$TMP/r.json"
  fake_curl 200 "$TMP/r.json"
  "$BIN" send --device tv-1 --capability switch --command on >/dev/null 2>&1
  args=$(cat "$TMP/curl.args")
  grep -q '"capability":"switch"' <<<"$args" && ok "capability" || bad "capability" "$args"
  grep -q '"command":"on"'        <<<"$args" && ok "command"    || bad "command" "$args"
  grep -q '"arguments":\[\]'      <<<"$args" && ok "no arguments when none given" \
    || bad "no arguments when none given" "$args"
  teardown
}

# The API rejects a quoted number where it wants a number, and a bare number
# where it wants a string, so the caller says which it means.
test_send_distinguishes_numbers_from_strings() {
  setup
  with_token
  printf '{"results":[{"status":"COMPLETED"}]}' > "$TMP/r.json"
  fake_curl 200 "$TMP/r.json"
  "$BIN" send --device ac-1 --capability thermostatCoolingSetpoint \
    --command setCoolingSetpoint --number 23 >/dev/null 2>&1
  grep -q '"arguments":\[23\]' "$TMP/curl.args" && ok "--number goes on the wire unquoted" \
    || bad "--number goes on the wire unquoted" "$(cat "$TMP/curl.args")"

  : > "$TMP/curl.args"
  "$BIN" send --device tv-1 --capability mediaInputSource \
    --command setInputSource --arg HDMI1 >/dev/null 2>&1
  grep -q '"arguments":\["HDMI1"\]' "$TMP/curl.args" && ok "--arg stays a string" \
    || bad "--arg stays a string" "$(cat "$TMP/curl.args")"
  teardown
}

# The API answers 200 for a command it refuses and puts the verdict in
# results[].status. Reporting ok on that would tell the panel a command landed
# when the cloud had already said it did not.
test_a_refused_command_is_not_reported_as_success() {
  setup
  with_token
  printf '{"results":[{"status":"FAILED"}]}' > "$TMP/r.json"
  fake_curl 200 "$TMP/r.json"
  out=$("$BIN" send --device a --capability switch --command on 2>&1); rc=$?
  check "a FAILED verdict exits 8" "$rc" "8"
  grep -q 'FAILED' <<<"$out" && ok "and names the verdict" || bad "and names the verdict" "$out"
  teardown
}

test_absent_results_array_is_still_success() {
  setup
  with_token
  printf '{}' > "$TMP/r.json"
  fake_curl 200 "$TMP/r.json"
  rc=0; "$BIN" send --device a --capability switch --command on >/dev/null 2>&1 || rc=$?
  check "an absent results array exits 0" "$rc" "0"
  teardown
}

test_no_token_is_its_own_exit_code() {
  setup
  out=$("$BIN" devices 2>&1); rc=$?
  check "no token exits 2" "$rc" "2"
  teardown
}

test_token_comes_from_stdin_only
test_token_rejects_control_characters
test_token_status_and_clear
test_token_never_reaches_curl_argv
test_oversized_response_is_refused
test_ordinary_response_is_untouched
test_remote_strings_and_lists_are_clamped
test_401_clears_the_token
test_429_is_named_as_rate_limiting
test_missing_location_scope_degrades_quietly
test_location_scope_returns_room_names
test_status_shapes_one_device
test_several_devices_are_fetched_in_one_process
test_health_is_opt_in
test_health_marks_a_device_online
test_send_builds_the_command_body
test_send_distinguishes_numbers_from_strings
test_a_refused_command_is_not_reported_as_success
test_absent_results_array_is_still_success
test_no_token_is_its_own_exit_code

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
