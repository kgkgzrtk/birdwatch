#!/usr/bin/env bats
# Codex notify adapter contract: codex invokes the adapter with its JSON
# payload as the FINAL argument (after any fixed args from config.toml).

load test_helper

setup() {
  common_setup
  ADAPTER="$REPO_ROOT/adapters/codex/notify.sh"
}

@test "agent-turn-complete maps to Stop with assistant text" {
  sid="cx1-$UID_SUFFIX"
  payload="{\"type\":\"agent-turn-complete\",\"conversation_id\":\"$sid\",\"cwd\":\"/tmp/codexproj-$UID_SUFFIX\",\"last-assistant-message\":\"Implemented the parser and added regression tests.\"}"
  run bash "$ADAPTER" "$payload"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  entry=$(last_entry "$sid")
  [ "$(jq -r .priority <<<"$entry")" = "4" ]
  [ "$(jq -r .event <<<"$entry")" = "Stop" ]
}

@test "exec-approval maps to PermissionRequest prio-1" {
  sid="cx2-$UID_SUFFIX"
  payload="{\"type\":\"exec-approval\",\"conversation_id\":\"$sid\",\"codex_cwd\":\"/tmp/codexproj-$UID_SUFFIX\",\"codex_command\":\"rm -rf build\"}"
  run bash "$ADAPTER" "$payload"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  [ "$(jq -r .priority <<<"$(last_entry "$sid")")" = "1" ]
}

@test "patch-approval maps to PermissionRequest prio-1" {
  sid="cx3-$UID_SUFFIX"
  payload="{\"type\":\"patch-approval\",\"conversation_id\":\"$sid\",\"cwd\":\"/tmp/codexproj-$UID_SUFFIX\"}"
  run bash "$ADAPTER" "$payload"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  [ "$(jq -r .priority <<<"$(last_entry "$sid")")" = "1" ]
}

@test "--chain forwards original args and payload to the chained notifier" {
  sid="cx4-$UID_SUFFIX"
  out="$BATS_TEST_TMPDIR/chain-args"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\n' "$out" > "$BATS_TEST_TMPDIR/bin/fake-notifier"
  chmod +x "$BATS_TEST_TMPDIR/bin/fake-notifier"
  payload="{\"type\":\"agent-turn-complete\",\"conversation_id\":\"$sid\",\"cwd\":\"/tmp/codexproj-$UID_SUFFIX\",\"last-assistant-message\":\"Refactored the queue worker into two stages.\"}"
  run bash "$ADAPTER" --chain fake-notifier turn-ended -- "$payload"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q "turn-ended" "$out"
  grep -q "agent-turn-complete" "$out"
  assert_queue_count "$sid" 1
}

@test "malformed JSON exits 0 without queueing" {
  run bash "$ADAPTER" "this is not json"
  [ "$status" -eq 0 ]
  [ ! -f "$(queue_file)" ]
}

@test "unknown event type exits 0 without queueing" {
  run bash "$ADAPTER" '{"type":"session-configured","conversation_id":"x"}'
  [ "$status" -eq 0 ]
  [ ! -f "$(queue_file)" ]
}
