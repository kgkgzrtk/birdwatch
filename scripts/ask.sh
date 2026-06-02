#!/usr/bin/env bash
# Spatial ask — inbox-style view of pending questions from all CC sessions,
# grouped by project and priority. Answer sends back via tmux send-keys.
#
# Subcommands:
#   ask.sh                  # list + interactive answer picker
#   ask.sh list             # just list pending questions, no prompt
#   ask.sh send <pane> <msg># direct send without queue (fallback: old behaviour)
set -u

Q="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/state}/spatial/questions.jsonl"
mkdir -p "$(dirname "$Q")"
touch "$Q"

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
    echo "未回答の質問はありません。"
    return 0
  fi

  # Render menu; collect flat list of pending entries with 1-based index
  local FLAT
  FLAT=$(jq -c 'select(.status=="pending")' "$Q" \
        | jq -sc 'sort_by(.priority, .ts)')
  local N
  N=$(jq 'length' <<<"$FLAT")

  printf "\n=== 未回答の質問 (%d 件) ===\n" "$N"
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

  printf "\n番号 (回答する質問) または q で中止: "
  read -r CH
  [[ "$CH" == "q" || -z "$CH" ]] && return 0

  local ENTRY
  ENTRY=$(jq -c ".[$((CH-1))]" <<<"$FLAT")
  if [[ -z "$ENTRY" || "$ENTRY" == "null" ]]; then
    echo "無効な番号"; return 1
  fi

  local PANE SID TEXT
  PANE=$(jq -r '.pane' <<<"$ENTRY")
  SID=$(jq -r '.session_id' <<<"$ENTRY")
  TEXT=$(jq -r '.text // .event' <<<"$ENTRY")

  printf "→ [%s] に回答: " "${PANE:-$SID}"
  read -r REPLY
  [[ -z "$REPLY" ]] && { echo "空のメッセージ、中止"; return 0; }

  if [[ -n "$PANE" ]]; then
    tmux send-keys -t "$PANE" -- "$REPLY" 2>/dev/null && tmux send-keys -t "$PANE" Enter
    echo "送信: $PANE ← $REPLY"
  else
    echo "tmux pane が分からないため送信できません（手動で入力してください）: $REPLY"
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
  whisper-cli -m "$MODEL" -l ja -nt -np -f "$WAV" 2>/dev/null \
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
    echo "(未回答なし) 転写: $TEXT"
    return 0
  fi
  PANE=$(jq -r '.pane' <<<"$ENTRY")
  SID=$( jq -r '.session_id' <<<"$ENTRY")
  TS=$(  jq -r '.ts'         <<<"$ENTRY")
  if [[ -n "$PANE" && "$PANE" != "null" ]]; then
    tmux send-keys -t "$PANE" -- "$TEXT" && tmux send-keys -t "$PANE" Enter
    printf '→ %s ← %s\n' "$PANE" "$TEXT"
    jq -c --arg ts "$TS" --arg sid "$SID" \
      'if (.ts==$ts and .session_id==$sid) then .status="answered" else . end' \
      "$Q" > "${Q}.tmp" && mv "${Q}.tmp" "$Q"
  else
    printf '(pane 不明) 転写: %s\n' "$TEXT"
  fi
}

case "${1:-}" in
  list)
    pick_and_answer_mode=no
    FLAT=$(jq -c 'select(.status=="pending")' "$Q" | jq -sc 'sort_by(.priority, .ts)')
    N=$(jq 'length' <<<"$FLAT" 2>/dev/null || echo 0)
    if (( N == 0 )); then echo "未回答の質問はありません。"; exit 0; fi
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
    tmux send-keys -t "$PANE" -- "$MSG" && tmux send-keys -t "$PANE" Enter
    ;;
  mic)
    # Record + transcribe + answer picker
    WAV=/tmp/cc-ptt-single.wav
    printf "🎤 話してください (VAD で自動停止)…\n" >&2
    record_vad "$WAV"
    TEXT=$(transcribe_wav "$WAV"); rm -f "$WAV"
    if [[ -z "${TEXT:-}" ]]; then
      echo "転写結果なし"; exit 1
    fi
    echo "転写: $TEXT"
    # Pick target question then send transcribed text as the answer
    FLAT=$(jq -c 'select(.status=="pending")' "$Q" | jq -sc 'sort_by(.priority, .ts)')
    N=$(jq 'length' <<<"$FLAT" 2>/dev/null || echo 0)
    if (( N == 0 )); then
      echo "対象の未回答質問がありません（手動で ask.sh send <pane> \"$TEXT\" を使ってください）"
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
    printf "\n送信先の番号 (q で中止): "
    read -r CH
    [[ "$CH" == "q" || -z "$CH" ]] && exit 0
    ENTRY=$(jq -c ".[$((CH-1))]" <<<"$FLAT")
    PANE=$(jq -r '.pane' <<<"$ENTRY")
    SID=$(jq -r '.session_id' <<<"$ENTRY")
    TS=$(jq -r '.ts' <<<"$ENTRY")
    if [[ -n "$PANE" && "$PANE" != "null" ]]; then
      tmux send-keys -t "$PANE" -- "$TEXT" && tmux send-keys -t "$PANE" Enter
      echo "送信: $PANE ← $TEXT"
    else
      echo "tmux pane 不明のため送信不可: $TEXT"
    fi
    jq -c --arg ts "$TS" --arg sid "$SID" \
      'if (.ts==$ts and .session_id==$sid) then .status="answered" else . end' \
      "$Q" > "${Q}.tmp" && mv "${Q}.tmp" "$Q"
    ;;
  watch)
    # Always-open microphone loop: speak → auto-stop → transcribe → route → loop
    # Ctrl-C to exit. Each utterance is auto-sent to the highest-priority pending question.
    trap 'echo ""; echo "watch 終了"; exit 0' INT TERM
    if ! command -v whisper-cli >/dev/null; then
      echo "whisper-cli が必要 (brew install whisper-cpp)" >&2; exit 1
    fi
    [[ -f "$MODEL" ]] || { echo "モデルが無い: $MODEL" >&2; exit 1; }
    echo "常時マイク ON。話し始めたら自動録音、1.5秒の無音で停止。Ctrl-C で終了。"
    while :; do
      WAV=/tmp/cc-ptt-watch.wav
      printf "\n🎤 listening… "
      record_vad "$WAV"
      if [[ ! -s "$WAV" ]]; then
        printf "(音声なし) 再待機\n"
        continue
      fi
      printf "転写中…\n"
      TEXT=$(transcribe_wav "$WAV"); rm -f "$WAV"
      [[ -z "$TEXT" ]] && { echo "(転写空) スキップ"; continue; }
      # Ignore common Whisper silent-input hallucinations
      case "$TEXT" in
        "ご視聴ありがとうございました"*|"ありがとうございました"*|"Thank you"*|" Thank you"*)
          echo "(無音ハルシネーション) 無視: $TEXT"
          continue ;;
      esac
      auto_send "$TEXT"
    done
    ;;
  *)
    pick_and_answer
    ;;
esac
