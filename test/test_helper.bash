# Shared test setup for birdwatch bats suites.
#
# Isolation strategy:
# - State is confined to $BATS_TEST_TMPDIR via CLAUDE_PLUGIN_DATA (regression
#   tests) or BIRDWATCH_STATE_DIR (new precedence tests).
# - `sox`/`afplay` are stubbed on PATH so tests never render or play audio;
#   dispatch writes the questions.jsonl queue before rendering, which is the
#   contract these tests assert.
# - Session/project names are unique per test to dodge the /tmp rate-limit
#   and Tier-B cooldown locks shared with a live system.

common_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  DISPATCH="$REPO_ROOT/scripts/dispatch.sh"
  export DISPATCH

  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/plugdata"
  unset BIRDWATCH_STATE_DIR BIRDWATCH_OFF

  # Stub audio tools: sox "fails" so dispatch exits right after queueing,
  # afplay is a no-op. Real sox/jq behavior is covered by live verification.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/sox"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/afplay"
  chmod +x "$BATS_TEST_TMPDIR/bin/sox" "$BATS_TEST_TMPDIR/bin/afplay"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH

  # Unique ids per test run to avoid /tmp lock collisions.
  UID_SUFFIX="$(date +%s)-$$-$BATS_TEST_NUMBER"
  export UID_SUFFIX
}

queue_file() { # [base-dir]
  echo "${1:-$CLAUDE_PLUGIN_DATA}/birdwatch/questions.jsonl"
}

# Assert the queue has exactly N entries for a session.
assert_queue_count() { # session_id expected [base-dir]
  local sid=$1 expected=$2 base=${3:-$CLAUDE_PLUGIN_DATA}
  local q n
  q="$(queue_file "$base")"
  n=$(jq -c --arg sid "$sid" 'select(.session_id==$sid)' "$q" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -eq "$expected" ] || {
    echo "expected $expected queue entries for $sid, got $n" >&2
    [ -f "$q" ] && cat "$q" >&2
    return 1
  }
}

# Fetch one field from the last queue entry for a session.
queue_field() { # session_id jq-field [base-dir]
  local sid=$1 field=$2 base=${3:-$CLAUDE_PLUGIN_DATA}
  jq -r --arg sid "$sid" "[ .|select(.session_id==\$sid) ] | .${field}" \
    <<<"$(jq -cs '.[]' "$(queue_file "$base")" 2>/dev/null)" 2>/dev/null || true
}

last_entry() { # session_id [base-dir]
  local sid=$1 base=${2:-$CLAUDE_PLUGIN_DATA}
  jq -c --arg sid "$sid" 'select(.session_id==$sid)' "$(queue_file "$base")" 2>/dev/null | tail -1
}
