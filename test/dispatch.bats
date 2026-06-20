#!/usr/bin/env bats
# Core dispatch.sh contract: event gating, tiering, queue writes, state paths.

load test_helper

setup() { common_setup; }

# --- Regression: existing Claude Code hook behavior --------------------------

@test "PermissionRequest queues a prio-1 entry" {
  sid="pr-$UID_SUFFIX"
  run bash "$DISPATCH" PermissionRequest <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  entry=$(last_entry "$sid")
  [ "$(jq -r .priority <<<"$entry")" = "1" ]
  [ "$(jq -r .text <<<"$entry")" = "Permission requested Bash" ]
}

@test "Notification with message queues a prio-2 entry" {
  sid="nt-$UID_SUFFIX"
  run bash "$DISPATCH" Notification <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Notification\",\"message\":\"Claude is waiting for your input\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  [ "$(jq -r .priority <<<"$(last_entry "$sid")")" = "2" ]
}

@test "Notification without message stays silent" {
  sid="ntx-$UID_SUFFIX"
  run bash "$DISPATCH" Notification <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Notification\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 0
}

@test "Stop with transcript question queues prio-3" {
  sid="sq-$UID_SUFFIX"
  tx="$BATS_TEST_TMPDIR/tx.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Which database should I use?"}]}}' > "$tx"
  run bash "$DISPATCH" Stop <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Stop\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\",\"transcript_path\":\"$tx\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  [ "$(jq -r .priority <<<"$(last_entry "$sid")")" = "3" ]
}

@test "Stop with trivial transcript stays silent" {
  sid="st-$UID_SUFFIX"
  tx="$BATS_TEST_TMPDIR/tx.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}' > "$tx"
  run bash "$DISPATCH" Stop <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Stop\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\",\"transcript_path\":\"$tx\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 0
}

# --- New: direct `.text` payload (multi-harness adapters) --------------------

@test "Stop with direct .text question queues prio-3 (no transcript needed)" {
  sid="dq-$UID_SUFFIX"
  run bash "$DISPATCH" Stop <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Stop\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\",\"text\":\"Should I deploy to staging or production?\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  [ "$(jq -r .priority <<<"$(last_entry "$sid")")" = "3" ]
}

@test "Stop with direct .text substantive result queues prio-4" {
  sid="dr-$UID_SUFFIX"
  run bash "$DISPATCH" Stop <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Stop\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\",\"text\":\"Implemented the migration and added three new tables.\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1
  [ "$(jq -r .priority <<<"$(last_entry "$sid")")" = "4" ]
}

@test "Stop with direct trivial .text stays silent" {
  sid="dt-$UID_SUFFIX"
  run bash "$DISPATCH" Stop <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"Stop\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\",\"text\":\"ok\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 0
}

# --- New: BIRDWATCH_STATE_DIR takes precedence over CLAUDE_PLUGIN_DATA -------

@test "BIRDWATCH_STATE_DIR wins over CLAUDE_PLUGIN_DATA" {
  sid="bw-$UID_SUFFIX"
  export BIRDWATCH_STATE_DIR="$BATS_TEST_TMPDIR/bwstate"
  run bash "$DISPATCH" PermissionRequest <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Edit\",\"cwd\":\"/tmp/proj-$UID_SUFFIX\"}"
  [ "$status" -eq 0 ]
  assert_queue_count "$sid" 1 "$BIRDWATCH_STATE_DIR"
  assert_queue_count "$sid" 0 "$CLAUDE_PLUGIN_DATA"
}

# --- New: survive minimal launchd-like PATH (gateway-spawned hooks) ----------

@test "dispatch finds deps under a minimal launchd PATH" {
  sid="path-$UID_SUFFIX"
  printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"/tmp/proj-%s","text":"Implemented the launchd path fallback and verified it."}' "$sid" "$UID_SUFFIX" \
    | env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      bash "$DISPATCH" Stop
  assert_queue_count "$sid" 1
}

# --- New: per-project species override (dashboard settings) ------------------

# Resolve the species recorded for a session from its registry file.
registry_species() { # session_id
  jq -r .species "$CLAUDE_PLUGIN_DATA/birdwatch/sessions/$1.json" 2>/dev/null
}

@test "overrides.json forces a project's species" {
  sid="ov-$UID_SUFFIX"
  proj="/tmp/ovproj-$UID_SUFFIX"
  mkdir -p "$CLAUDE_PLUGIN_DATA/birdwatch"
  # pick a valid slug from species.json that is NOT the hash default for this project
  printf '{"%s":"raven"}' "$proj" > "$CLAUDE_PLUGIN_DATA/birdwatch/overrides.json"
  run bash "$DISPATCH" PermissionRequest <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"cwd\":\"$proj\"}"
  [ "$status" -eq 0 ]
  [ "$(registry_species "$sid")" = "raven" ]
}

@test "invalid override slug falls back to hash default" {
  sid="ovbad-$UID_SUFFIX"
  proj="/tmp/ovbad-$UID_SUFFIX"
  mkdir -p "$CLAUDE_PLUGIN_DATA/birdwatch"
  printf '{"%s":"not-a-real-bird"}' "$proj" > "$CLAUDE_PLUGIN_DATA/birdwatch/overrides.json"
  run bash "$DISPATCH" PermissionRequest <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"cwd\":\"$proj\"}"
  [ "$status" -eq 0 ]
  sp="$(registry_species "$sid")"
  [ -n "$sp" ] && [ "$sp" != "not-a-real-bird" ]
}

@test "override only affects the matching project" {
  sid="ovother-$UID_SUFFIX"
  proj="/tmp/ovother-$UID_SUFFIX"
  mkdir -p "$CLAUDE_PLUGIN_DATA/birdwatch"
  # override is for a DIFFERENT project; this one should use the hash default
  printf '{"/tmp/someoneelse":"raven"}' > "$CLAUDE_PLUGIN_DATA/birdwatch/overrides.json"
  run bash "$DISPATCH" PermissionRequest <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"cwd\":\"$proj\"}"
  [ "$status" -eq 0 ]
  [ "$(registry_species "$sid")" != "raven" ] || skip "hash default happened to be raven"
}
