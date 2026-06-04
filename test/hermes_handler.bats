#!/usr/bin/env bats
# Hermes hook handler contract: handler.handle(event_type, context) shells out
# to dispatch.sh, never raises, and maps agent:end -> Stop with response text.

load test_helper

setup() {
  common_setup
  HANDLER_DIR="$REPO_ROOT/adapters/hermes"
  export BIRDWATCH_DISPATCH="$DISPATCH"
}

run_handler() { # event_type context_json
  run python3 - "$1" "$2" <<PY
import asyncio, json, sys
sys.path.insert(0, "$HANDLER_DIR")
import handler
asyncio.run(handler.handle(sys.argv[1], json.loads(sys.argv[2])))
PY
}

@test "agent:end question maps to Stop prio-3 with hermes project" {
  sid="hm1-$UID_SUFFIX"
  run_handler "agent:end" "{\"session_id\":\"$sid\",\"platform\":\"telegram\",\"chat_id\":\"$UID_SUFFIX\",\"response\":\"Should I send the weekly report now?\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  entry=$(last_entry "$sid")
  [ "$(jq -r .priority <<<"$entry")" = "3" ]
  [[ "$(jq -r .project <<<"$entry")" == hermes/telegram-* ]]
}

@test "agent:end trivial response stays silent" {
  sid="hm2-$UID_SUFFIX"
  run_handler "agent:end" "{\"session_id\":\"$sid\",\"platform\":\"telegram\",\"chat_id\":\"$UID_SUFFIX\",\"response\":\"ok\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 0
}

@test "other events are ignored" {
  sid="hm3-$UID_SUFFIX"
  run_handler "agent:start" "{\"session_id\":\"$sid\",\"platform\":\"telegram\",\"chat_id\":\"$UID_SUFFIX\",\"message\":\"hi\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 0
}

@test "missing dispatch never raises" {
  export BIRDWATCH_DISPATCH="/nonexistent/dispatch.sh"
  run_handler "agent:end" "{\"session_id\":\"hm4\",\"platform\":\"telegram\",\"chat_id\":\"1\",\"response\":\"Should I retry the failed job?\"}"
  [ "$status" -eq 0 ]
}
