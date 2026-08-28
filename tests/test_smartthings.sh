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
  # A real CLI session on the developer's machine would otherwise be picked up
  # ahead of the keyring and quietly change what half these tests exercise.
  export XDG_DATA_HOME="$TMP/share"
  export XDG_CONFIG_HOME="$TMP/config"
  # A minimal PATH, not the caller's. With the real one inherited, whether a
  # test passes depends on what the developer happens to have installed -- and
  # "smartthings is not on PATH" is a state these tests must be able to create.
  export PATH="$TMP/bin:/usr/bin:/bin"
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

# A CLI session, which is the only credential this backend accepts.
with_token() { fake_cli_credentials "2099-01-01T00:00:00.000Z" "cli-token-xyz"; }

# ------------------------------------------------------------------- token --




# The single most important property in this backend: the token must never
# reach argv, where /proc/<pid>/cmdline exposes it to every process on the
# session for the life of the call.

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
  printf '{"items":[{"locationId":"11111111-2222-3333-4444-555555555555","name":"Home"}]}' > "$TMP/loc.json"
  printf '{"items":[{"roomId":"r1","name":"Attic"},{"roomId":"r2","name":"Quarto"}]}' > "$TMP/rooms.json"
  fake_curl_router '
    case "$url" in
      *"/rooms"*)     route "'"$TMP"'/rooms.json" 200 ;;
      *"/locations"*) route "'"$TMP"'/loc.json" 200 ;;
    esac'
  out=$("$BIN" rooms 2>&1); rc=$?
  check "a scoped token exits 0" "$rc" "0"
  check "and reports itself scoped" "$(jq -r '.scoped' <<<"$out")" "true"
  check "with the room named" "$(jq -r '.rooms.r1.name' <<<"$out")" "Attic"
  check "and its location alongside it" "$(jq -r '.rooms.r1.location' <<<"$out")" "Home"
  check "and the locations counted" "$(jq -r '.locations' <<<"$out")" "1"
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


# Two credential sources. The CLI's OAuth session renews itself and is the only
# one that lasts; a personal access token is what anyone can make in a minute
# and dies 24 hours later. Which one is in use changes what the panel says and
# what a 401 is allowed to delete, so the source travels with the token.
fake_cli_credentials() {
  local expires="$1" token="${2:-cli-token-xyz}"
  export XDG_DATA_HOME="$TMP/share"
  mkdir -p "$XDG_DATA_HOME/@smartthings/cli"
  jq -n --arg e "$expires" --arg t "$token" \
    '{"default:api.smartthings.com": {accessToken: $t, refreshToken: "r", expires: $e}}' \
    > "$XDG_DATA_HOME/@smartthings/cli/credentials.json"
}



# The source has to survive the call. Written as a global set inside $( ), it is
# assigned in a subshell and never reaches the caller -- which reported a CLI
# session as a pasted token, and would have let a 401 delete a keyring entry
# over a credential the CLI owns.

# A 401 on the CLI's credential must not delete the keyring's, which belongs to
# a different mechanism the user may still be relying on.


# Reading only .items[0] left every device in every other location permanently
# ungrouped -- an air conditioner in a second location looked like it belonged
# to the first location's room, because the unnamed group renders under it.
test_every_location_is_walked() {
  setup
  with_token
  printf '{"items":[{"locationId":"11111111-2222-3333-4444-555555555555","name":"Home"},{"locationId":"22222222-3333-4444-5555-666666666666","name":"Office"}]}' > "$TMP/loc.json"
  printf '{"items":[{"roomId":"rA","name":"Attic"}]}' > "$TMP/r1.json"
  printf '{"items":[{"roomId":"rB","name":"Boardroom"}]}' > "$TMP/r2.json"
  fake_curl_router '
    case "$url" in
      *"11111111"*"/rooms"*) route "'"$TMP"'/r1.json" 200 ;;
      *"22222222"*"/rooms"*) route "'"$TMP"'/r2.json" 200 ;;
      *"/locations"*)        route "'"$TMP"'/loc.json" 200 ;;
    esac'
  out=$("$BIN" rooms 2>&1)
  check "both locations counted" "$(jq -r '.locations' <<<"$out")" "2"
  check "the first location's room" "$(jq -r '.rooms.rA.name' <<<"$out")" "Attic"
  check "and the second's" "$(jq -r '.rooms.rB.name' <<<"$out")" "Boardroom"
  check "each labelled with its own location" "$(jq -r '.rooms.rB.location' <<<"$out")" "Office"
  teardown
}

test_oversized_response_is_refused
test_ordinary_response_is_untouched
test_remote_strings_and_lists_are_clamped
test_429_is_named_as_rate_limiting
test_missing_location_scope_degrades_quietly
test_location_scope_returns_room_names
test_every_location_is_walked
test_status_shapes_one_device
test_several_devices_are_fetched_in_one_process
test_health_is_opt_in
test_health_marks_a_device_online
test_send_builds_the_command_body
test_send_distinguishes_numbers_from_strings
test_a_refused_command_is_not_reported_as_success
test_absent_results_array_is_still_success

# ------------------------------------------------------------- credential --

test_no_session_is_its_own_exit_code() {
  setup
  out=$("$BIN" devices 2>&1); rc=$?
  check "no CLI session exits 2" "$rc" "2"
  grep -q 'smartthings locations' <<<"$out" && ok "and says what to run" \
    || bad "and says what to run" "$out"
  teardown
}

test_the_cli_session_is_the_token_sent() {
  setup
  with_token
  printf '{"items":[]}' > "$TMP/e.json"
  fake_curl 200 "$TMP/e.json"
  "$BIN" devices >/dev/null 2>&1
  grep -q 'cli-token-xyz' "$TMP/curl.stdin" && ok "the CLI session is what goes on the wire" \
    || bad "the CLI session is what goes on the wire" "$(cat "$TMP/curl.stdin")"
  grep -q 'cli-token-xyz' "$TMP/curl.args" && bad "and never reaches argv" \
    "$(cat "$TMP/curl.args")" || ok "and never reaches argv"
  teardown
}

# The panel tells three states apart and each has a different next step, so the
# backend reports them separately rather than as one boolean.
test_credential_reports_what_is_missing() {
  setup
  out=$("$BIN" credential)
  check "nothing at all: not ready" "$(jq -r .ready <<<"$out")" "false"
  check "and no session"            "$(jq -r .session <<<"$out")" "false"
  with_token
  out=$("$BIN" credential)
  check "with a session: ready" "$(jq -r .ready <<<"$out")" "true"
  # HOME as well as PATH: the binary is now looked for where version managers
  # put it, so hiding it takes more than emptying PATH.
  out=$(HOME="$TMP/nowhere" "$BIN" credential)
  check "but not renewable without the binary" "$(jq -r .renewable <<<"$out")" "false"

  # With the CLI present it can renew, which is the difference between a
  # credential that lasts and one that quietly dies after a day.
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/smartthings"; chmod +x "$TMP/bin/smartthings"
  out=$("$BIN" credential)
  check "with the binary too: renewable" "$(jq -r .renewable <<<"$out")" "true"
  check "and the CLI is reported installed" "$(jq -r .cliInstalled <<<"$out")" "true"
  teardown
}

# A rejected session must not delete anything: it belongs to the CLI, and
# logging the user out of a tool this plugin merely reads is a side effect
# nobody asked for.
test_a_rejected_session_is_reported_not_deleted() {
  setup
  with_token
  printf '{}' > "$TMP/e.json"
  fake_curl 401 "$TMP/e.json"
  out=$("$BIN" devices 2>&1); rc=$?
  check "a rejected session exits 3" "$rc" "3"
  grep -q 'smartthings locations' <<<"$out" && ok "and says how to fix it" \
    || bad "and says how to fix it" "$out"
  check "the credentials file is untouched" \
    "$(jq -r '.["default:api.smartthings.com"].accessToken' "$XDG_DATA_HOME/@smartthings/cli/credentials.json")" \
    "cli-token-xyz"
  teardown
}

test_no_session_is_its_own_exit_code
test_the_cli_session_is_the_token_sent
test_credential_reports_what_is_missing
test_a_rejected_session_is_reported_not_deleted

# The shell that runs this plugin takes its environment from the session, not
# from the user's terminal rc, so a CLI installed through a version manager can
# be present and invisible on PATH -- and the failure is silent and delayed: the
# session works for a day and then stops renewing. The binary is therefore
# looked for where these tools actually put it.
test_the_cli_is_found_off_PATH() {
  setup
  with_token
  mkdir -p "$TMP/home/.local/share/mise/shims"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/home/.local/share/mise/shims/smartthings"
  chmod +x "$TMP/home/.local/share/mise/shims/smartthings"
  out=$(HOME="$TMP/home" "$BIN" credential)
  check "a version manager's shim counts as installed" "$(jq -r .cliInstalled <<<"$out")" "true"
  check "and the session can renew" "$(jq -r .renewable <<<"$out")" "true"
  teardown
}

test_no_cli_anywhere_is_reported() {
  setup
  with_token
  out=$(HOME="$TMP/nowhere" "$BIN" credential)
  check "with no binary at all: not installed" "$(jq -r .cliInstalled <<<"$out")" "false"
  check "and the session cannot renew" "$(jq -r .renewable <<<"$out")" "false"
  teardown
}

test_the_cli_is_found_off_PATH
test_no_cli_anywhere_is_reported

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
