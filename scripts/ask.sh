#!/usr/bin/env bash
# Birdwatch ask — inbox-style view of pending questions from all CC sessions,
# grouped by project and priority. Answer sends back via tmux send-keys.
#
# Subcommands:
#   ask.sh                  # list + interactive answer picker
#   ask.sh list             # just list pending questions, no prompt
#   ask.sh send <pane> <msg># direct send without queue (fallback: old behaviour)
set -u

Q="${BIRDWATCH_STATE_DIR:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/state}}/birdwatch/questions.jsonl"
mkdir -p "$(dirname "$Q")"
touch "$Q"

# Deliver an answer to a tmux pane. Two safety guards:
#  -l  : send the payload LITERALLY so a reply that happens to be a key name
#        (e.g. "Enter", "C-c", "C-u") is typed as text, never injected as a key.
#  pane: must match tmux's pane-id format (%N) before we target it, so a stray
#        value from questions.jsonl/argv can't retarget another session.
send_pane() {
  local pane=$1 text=$2
  [[ "$pane" =~ ^%[0-9]+$ ]] || { echo "invalid pane id: $pane" >&2; return 1; }
  tmux send-keys -t "$pane" -l -- "$text" && tmux send-keys -t "$pane" Enter
}

list_pending() {
  # Pending only, sorted by priority asc, ts asc; project-grouped
  jq -c 'select(.status=="pending")' "$Q" 2>/dev/null \
    | jq -sc 'sort_by(.priority, .ts)
              | group_by(.project)
              | map({project: .[0].project, items: .})' 2>/dev/null
}

mark_answered() {
  local idx=$1
  # Rewrite file: toggle status for the idx-th pending entry
  jq -c --argjson i "$idx" '
    def annotate: foreach . as $row (0; if $row.status=="pending" then .+1 else . end;
      {row: $row, n: .});
    [ . ] | map(annotate) | .[0][]  # placeholder — use a simpler method below
  ' "$Q" 2>/dev/null
}

pick_and_answer() {
  local groups
  groups=$(list_pending)
  if [[ -z "$groups" || "$groups" == "[]" ]]; then
    echo "No pending questions."
    return 0
  fi

  # Render menu; collect flat list of pending entries with 1-based index
  local FLAT
  FLAT=$(jq -c 'select(.status=="pending")' "$Q" \
        | jq -sc 'sort_by(.priority, .ts)')
  local N
  N=$(jq 'length' <<<"$FLAT")

  printf "\n=== Pending questions (%d) ===\n" "$N"
  printf '%s\n' "$FLAT" | jq -r '
    group_by(.project) | .[] | "\n■ " + .[0].project,
    (.[] | "  [\(.priority)] \(.text // .event)  (tool=\(.tool // "-")  sid=\(.session_id[0:8]))")
  '

  # Build flat display with indices
  echo ""
  jq -r '
    to_entries | .[] |
    "  \(.key+1) [\(.value.priority)] \(.value.project | split("/") | last) · \(.value.text // .value.event)"
  ' <<<"$FLAT"

  printf "\nNumber (question to answer) or q to cancel: "
  read -r CH
  [[ "$CH" == "q" || -z "$CH" ]] && return 0

  local ENTRY
  ENTRY=$(jq -c ".[$((CH-1))]" <<<"$FLAT")
  if [[ -z "$ENTRY" || "$ENTRY" == "null" ]]; then
    echo "Invalid number"; return 1
  fi

  local PANE SID TEXT
  PANE=$(jq -r '.pane' <<<"$ENTRY")
  SID=$(jq -r '.session_id' <<<"$ENTRY")
  TEXT=$(jq -r '.text // .event' <<<"$ENTRY")

  printf "→ reply to [%s]: " "${PANE:-$SID}"
  read -r REPLY
  [[ -z "$REPLY" ]] && { echo "Empty message, cancelled"; return 0; }

  if [[ -n "$PANE" && "$PANE" != "null" ]] && send_pane "$PANE" "$REPLY" 2>/dev/null; then
    echo "Sent: $PANE ← $REPLY"
  else
    echo "Cannot send (unknown tmux pane); type it manually: $REPLY"
  fi

  # Mark the matched entry as answered
  local TS_MATCH
  TS_MATCH=$(jq -r '.ts' <<<"$ENTRY")
  jq -c --arg ts "$TS_MATCH" --arg sid "$SID" \
    'if (.ts==$ts and .session_id==$sid) then .status="answered" else . end' \
    "$Q" > "${Q}.tmp" && mv "${Q}.tmp" "$Q"
}

MODEL=~/.whisper/ggml-large-v3-turbo-q5_0.bin

# Record one utterance using sox VAD (auto-stop on silence), then transcribe.
# Silence params: start after 0.1s @ 3% threshold; stop after 1.5s @ 3%
record_vad() {
  local WAV=$1
  rec -q -r 16000 -c 1 -b 16 "$WAV" \
    silence 1 0.1 3% 1 1.5 3% 2>/dev/null
}

transcribe_wav() {
  local WAV=$1
  whisper-cli -m "$MODEL" -l en -nt -np -f "$WAV" 2>/dev/null \
    | tr -d '\r' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | tr -d '\n'
}

# Auto-route transcribed text to the top-priority pending question's pane.
# If none, print to stdout and fall back to the regular picker.
auto_send() {
  local TEXT=$1
  local ENTRY PANE SID TS
  ENTRY=$(jq -c 'select(.status=="pending")' "$Q" | jq -sc 'sort_by(.priority, .ts) | .[0]')
  if [[ "$ENTRY" == "null" || -z "$ENTRY" ]]; then
    echo "(no pending) transcript: $TEXT"
    return 0
  fi
  PANE=$(jq -r '.pane' <<<"$ENTRY")
  SID=$( jq -r '.session_id' <<<"$ENTRY")
  TS=$(  jq -r '.ts'         <<<"$ENTRY")
  if [[ -n "$PANE" && "$PANE" != "null" ]] && send_pane "$PANE" "$TEXT"; then
    printf '→ %s ← %s\n' "$PANE" "$TEXT"
    jq -c --arg ts "$TS" --arg sid "$SID" \
      'if (.ts==$ts and .session_id==$sid) then .status="answered" else . end' \
      "$Q" > "${Q}.tmp" && mv "${Q}.tmp" "$Q"
  else
    printf '(unknown pane) transcript: %s\n' "$TEXT"
  fi
}

case "${1:-}" in
  list)
    FLAT=$(jq -c 'select(.status=="pending")' "$Q" | jq -sc 'sort_by(.priority, .ts)')
    N=$(jq 'length' <<<"$FLAT" 2>/dev/null || echo 0)
    if (( N == 0 )); then echo "No pending questions."; exit 0; fi
    jq -r '
      group_by(.project) | .[] | "\n■ " + .[0].project,
      (.[] | "  [\(.priority)] \(.text // .event)  (tool=\(.tool // "-"))")
    ' <<<"$FLAT"
    ;;
  send)
    # Direct mode: ask.sh send <pane> "<msg>"
    shift
    PANE=$1; shift
    MSG="$*"
    send_pane "$PANE" "$MSG"
    ;;
  mic)
    # Record + transcribe + answer picker
    WAV=/tmp/cc-ptt-single.wav
    printf "🎤 Speak now (auto-stops on silence)…\n" >&2
    record_vad "$WAV"
    TEXT=$(transcribe_wav "$WAV"); rm -f "$WAV"
    if [[ -z "${TEXT:-}" ]]; then
      echo "No transcript"; exit 1
    fi
    echo "Transcript: $TEXT"
    # Pick target question then send transcribed text as the answer
    FLAT=$(jq -c 'select(.status=="pending")' "$Q" | jq -sc 'sort_by(.priority, .ts)')
    N=$(jq 'length' <<<"$FLAT" 2>/dev/null || echo 0)
    if (( N == 0 )); then
      echo "No pending question to answer (use 'ask.sh send <pane> \"$TEXT\"' manually)"
      exit 0
    fi
    jq -r '
      group_by(.project) | .[] | "\n■ " + .[0].project,
      (.[] | "  [\(.priority)] \(.text // .event)")
    ' <<<"$FLAT"
    echo ""
    jq -r '
      to_entries | .[] |
      "  \(.key+1) \(.value.project | split("/") | last) · \(.value.text // .value.event)"
    ' <<<"$FLAT"
    printf "\nTarget number (q to cancel): "
    read -r CH
    [[ "$CH" == "q" || -z "$CH" ]] && exit 0
    ENTRY=$(jq -c ".[$((CH-1))]" <<<"$FLAT")
    PANE=$(jq -r '.pane' <<<"$ENTRY")
    SID=$(jq -r '.session_id' <<<"$ENTRY")
    TS=$(jq -r '.ts' <<<"$ENTRY")
    if [[ -n "$PANE" && "$PANE" != "null" ]] && send_pane "$PANE" "$TEXT"; then
      echo "Sent: $PANE ← $TEXT"
    else
      echo "Cannot send (unknown tmux pane): $TEXT"
    fi
    jq -c --arg ts "$TS" --arg sid "$SID" \
      'if (.ts==$ts and .session_id==$sid) then .status="answered" else . end' \
      "$Q" > "${Q}.tmp" && mv "${Q}.tmp" "$Q"
    ;;
  watch)
    # Always-open microphone loop: speak → auto-stop → transcribe → route → loop
    # Ctrl-C to exit. Each utterance is auto-sent to the highest-priority pending question.
    trap 'echo ""; echo "watch stopped"; exit 0' INT TERM
    if ! command -v whisper-cli >/dev/null; then
      echo "whisper-cli required (brew install whisper-cpp)" >&2; exit 1
    fi
    [[ -f "$MODEL" ]] || { echo "Model not found: $MODEL" >&2; exit 1; }
    echo "Mic always on. Recording starts when you speak, stops after 1.5s of silence. Ctrl-C to exit."
    while :; do
      WAV=/tmp/cc-ptt-watch.wav
      printf "\n🎤 listening… "
      record_vad "$WAV"
      if [[ ! -s "$WAV" ]]; then
        printf "(no audio) waiting again\n"
        continue
      fi
      printf "transcribing…\n"
      TEXT=$(transcribe_wav "$WAV"); rm -f "$WAV"
      [[ -z "$TEXT" ]] && { echo "(empty transcript) skipping"; continue; }
      # Ignore common Whisper silent-input hallucinations
      case "$TEXT" in
        "Thank you"*|" Thank you"*|"Thanks for watching"*)
          echo "(silence hallucination) ignoring: $TEXT"
          continue ;;
      esac
      auto_send "$TEXT"
    done
    ;;
  *)
    pick_and_answer
    ;;
esac
