#!/usr/bin/env bash
# Claude Code birdwatch dispatcher
# stdin: hook JSON. Plays a bird call only for high-signal events
# (approvals / substantive results / questions). Each project gets a different
# real bird species; pan reflects session "location".
#
# Axes:
#   project  → bird species  — every session in the same project shares a species
#   session  → home pan      — each session has a fixed home position
#   activity → pan drift     — pan jitters around home during bursts
#   tier     → distance/vol  — Tier A (approvals) close & loud, Tier B (reports) far & quiet
#
# Samples + attribution: ${CLAUDE_PLUGIN_ROOT}/assets/birds/  (see birds-bootstrap.sh)
# Disable: BIRDWATCH_OFF=1

[[ -n "${BIRDWATCH_OFF:-}" ]] && exit 0
command -v sox  >/dev/null || exit 0
command -v jq   >/dev/null || exit 0

# Plugin layout: read-only assets under CLAUDE_PLUGIN_ROOT, runtime state under
# CLAUDE_PLUGIN_DATA. Both fall back so the script also runs standalone.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/state}/birdwatch"
BIRD_DIR="$PLUGIN_ROOT/assets/birds"
SAMP_DIR="$BIRD_DIR/samples"
SPECIES_JSON="$BIRD_DIR/species.json"
[[ -d "$SAMP_DIR" && -f "$SPECIES_JSON" ]] || exit 0

json=$(cat)
sid=$(jq -r  '.session_id     // "x"'                <<<"$json" 2>/dev/null)
evt=$(jq -r  '.hook_event_name // "'"${1:-x}"'"'     <<<"$json" 2>/dev/null)
msg=$(jq -r  '.message         // empty'             <<<"$json" 2>/dev/null)
tx=$( jq -r  '.transcript_path // empty'             <<<"$json" 2>/dev/null)
tool=$(jq -r '.tool_name       // empty'             <<<"$json" 2>/dev/null)
cwd=$( jq -r '.cwd             // empty'             <<<"$json" 2>/dev/null)
if [[ -z "$cwd" && -n "$tx" ]]; then
  cwd=$(dirname "$tx" 2>/dev/null | sed -E 's|.*/projects/||; s|/.*||; s|-|/|g')
fi
project=${cwd:-unknown}

# Harden: session_id flows into file paths and /tmp lock names below. Strip any
# character that could traverse directories or inject a path separator, so a
# malformed/hostile session_id can never write outside the state dirs.
sid=${sid//[^A-Za-z0-9._-]/_}
[[ -z "$sid" ]] && sid=x

# --- Activity tracking (all events, silent or not) ---------------------------
ACT_DIR="$STATE_DIR/activity"
REG_DIR="$STATE_DIR/sessions"
mkdir -p "$ACT_DIR" "$REG_DIR"
NOW=$(date +%s)
echo "$NOW $evt" >> "$ACT_DIR/$sid.log"
awk -v now="$NOW" 'now - $1 <= 120' "$ACT_DIR/$sid.log" > "$ACT_DIR/$sid.log.tmp" \
  && mv "$ACT_DIR/$sid.log.tmp" "$ACT_DIR/$sid.log"

# --- Identity axes -----------------------------------------------------------
h_sid=$( printf '%s' "$sid"     | cksum | awk '{print $1}')
h_proj=$(printf '%s' "$project" | cksum | awk '{print $1}')
p_home=$(awk -v h="$h_sid"  'BEGIN{printf "%.3f", (h % 10000)/10000}')

# Map project → bird species (stable for the life of species.json's ordering).
N_SPECIES=$(jq 'length' "$SPECIES_JSON" 2>/dev/null || echo 0)
(( N_SPECIES > 0 )) || exit 0
SP_IDX=$(awk -v h="$h_proj" -v n="$N_SPECIES" 'BEGIN{printf "%d", h % n}')
SP_SLUG=$(jq -r --argjson i "$SP_IDX" '.[$i].slug // empty' "$SPECIES_JSON")
BIRD_WAV="$SAMP_DIR/$SP_SLUG.wav"
[[ -f "$BIRD_WAV" ]] || exit 0
# Back-compat: spread species index into the 30..75 range that dashboard.py
# treats as `pbas` for fairy coloring. Each project still maps to a distinct hue.
pbas=$(awk -v i="$SP_IDX" -v n="$N_SPECIES" 'BEGIN{printf "%d", 30 + (i * 45 / (n>1?n-1:1))}')

# --- Session registry (for dashboard) ---------------------------------------
SREG="$REG_DIR/$sid.json"
if [[ -f "$SREG" ]]; then
  FIRST=$(jq -r '.first_seen // '"$NOW"'' "$SREG" 2>/dev/null || echo "$NOW")
else
  FIRST=$NOW
fi
jq -n --arg sid "$sid" --arg project "$project" \
      --arg species "$SP_SLUG" --argjson pbas "$pbas" --arg home "$p_home" \
      --argjson first "$FIRST" --argjson last "$NOW" \
      --arg evt "$evt" \
  '{sid:$sid, project:$project, species:$species, pbas:$pbas,
    pan_home:($home|tonumber),
    first_seen:$first, last_seen:$last, last_event:$evt}' \
  > "$SREG"

# --- Content extraction (used only for dashboard log + gating, never spoken) -
last_text() {
  [[ -f "$tx" ]] || return 0
  tail -n 80 "$tx" 2>/dev/null \
    | jq -rs 'map(select(.type=="assistant")) | last | .message.content[]?
              | select(.type=="text") | .text' 2>/dev/null \
    | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}
strip_md() {
  sed -E \
      -e 's/```[^`]*```//g' \
      -e 's/`([^`]+)`/\1/g' \
      -e 's/\*\*([^*]+)\*\*/\1/g' \
      -e 's/\*([^*]+)\*/\1/g' \
      -e 's/__([^_]+)__/\1/g' \
      -e 's/\[([^]]+)\]\([^)]+\)/\1/g' \
      -e 's/[#>_~]//g' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}
is_question() {
  grep -qiE '[?？]|\b(which|should i|shall i|do you want|would you like|let me know|please (confirm|choose|select|decide))\b' <<<"$1"
}
is_substantive() {
  local t=$1
  (( ${#t} >= 20 )) || return 1
  grep -qiE '^(done|ok|okay|finished|complete|completed|success|thanks|thank you|all set)[.!]?$' <<<"$t" && return 1
  return 0
}

# --- Event gating: only chirp when the event carries real signal -------------
# `text` is logged to the dashboard queue (questions.jsonl) but never played.
text=""; tier=""
case "$evt" in
  PermissionRequest|Permission)
    tier=A; text="Permission requested ${tool:-}"
    ;;
  Notification)
    [[ -n "$msg" ]] || exit 0
    tier=A; text="$msg"
    ;;
  Stop)
    raw=$(last_text | strip_md)
    if [[ -n "$raw" ]] && is_question "$raw"; then
      tier=A; text=$(cut -c1-100 <<<"$raw")
    elif [[ -n "$raw" ]] && is_substantive "$raw"; then
      tier=B; text=$(cut -c1-80 <<<"$raw")
    else
      exit 0
    fi
    ;;
  SubagentStop|PreToolUse|PostToolUse|SessionStart|SessionEnd|UserPromptSubmit)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

# --- Rate limit (per session, 4s) --------------------------------------------
LOCK="/tmp/cc-birdwatch-${sid}.lock"
if [[ -f "$LOCK" ]]; then
  LAST=$(stat -f %m "$LOCK" 2>/dev/null || echo 0)
  (( NOW - LAST < ${BIRDWATCH_RATE_LIMIT:-4} )) && exit 0
fi
touch "$LOCK"

# --- Distance model (fairy approaches listener when it speaks) --------------
# dist: 0 = at listener's ear, 1 = at horizon. Volume ∝ 1 / (1 + 3·dist²).
# Tier A: lean in close (whisper near ear). Tier B: stay far (background chirp).
case "$evt" in
  PermissionRequest|Permission) dist=0.12 ;;   # at the ear
  Notification)                 dist=0.22 ;;
  Stop)                         dist=$([[ "$tier" == "A" ]] && echo 0.28 || echo 0.90) ;;
  *)                            dist=0.55 ;;
esac
# Aggressive inverse-square falloff so "far" really sounds far:
#   d=0.12:0.92  d=0.22:0.78  d=0.70:0.25  d=0.90:0.17   (clamped min 0.10)
vol=$(awk -v d="$dist" 'BEGIN{
  v = 1.0 / (1.0 + 6.0*d*d)
  if (v < 0.10) v = 0.10
  printf "%.3f", v
}')

# Tier-based pan compression (A leans toward center, B pushed to edges).
case "$tier" in
  A) pan_gain=0.70 ;;
  B) pan_gain=1.00 ;;
esac

# Report-storm suppression: Tier B from the same project within 15s → silent.
# Queue entry is still logged so `ask.sh list` shows it; only the voice is muted.
if [[ "$tier" == "B" ]]; then
  PROJ_KEY=$(printf '%s' "$project" | tr -c 'A-Za-z0-9' _)
  PLOCK="/tmp/cc-birdwatch-proj-${PROJ_KEY}.tierB.lock"
  if [[ -f "$PLOCK" ]]; then
    PLAST=$(stat -f %m "$PLOCK" 2>/dev/null || echo 0)
    if (( NOW - PLAST < ${BIRDWATCH_TIER_B_COOLDOWN:-15} )); then
      silent_tier_b=1
    fi
  fi
  touch "$PLOCK"
fi

# --- Pan drift: home ± (burst-scaled amplitude) × sin(time-based phase) ------
BURST=$(awk -v now="$NOW" 'now - $1 <= 30 {c++} END{print c+0}' "$ACT_DIR/$sid.log")
AMP=$(awk -v b="$BURST" 'BEGIN{
  if (b < 2) printf "0.00";
  else if (b > 6) printf "0.15";
  else printf "%.3f", (b-2)/4.0 * 0.15
}')
PHASE=$(awk -v now="$NOW" -v h="$h_sid" 'BEGIN{
  pi=3.14159265
  printf "%.4f", sin(now/7.0 * 2*pi + (h % 100)/15.9)
}')
p=$(awk -v home="$p_home" -v amp="$AMP" -v ph="$PHASE" 'BEGIN{
  v = home + amp * ph
  if (v < 0) v = 0; if (v > 1) v = 1
  printf "%.4f", v
}')

# Equal-power pan, with tier-based compression toward center
p_eff=$(awk -v p="$p" -v g="$pan_gain" 'BEGIN{printf "%.4f", 0.5 + (p-0.5)*g}')
read L R < <(awk -v p="$p_eff" 'BEGIN{pi=3.14159265; printf "%.3f %.3f", cos(pi/2*p), sin(pi/2*p)}')

text=$(printf '%s' "$text" | tr -d '\r' | cut -c1-160)

# --- Question queue for ask.sh (Tier A/B both useful to log) ----------------
mkdir -p "$STATE_DIR"
case "$evt" in
  PermissionRequest|Permission) prio=1 ;;
  Notification)                 prio=2 ;;
  Stop)                         prio=$([[ "$tier" == "A" ]] && echo 3 || echo 4) ;;
  *)                            prio=5 ;;
esac
pane=$(tmux list-panes -a -F '#{pane_id}|#{pane_current_path}|#{pane_current_command}' 2>/dev/null \
         | awk -F'|' -v p="$project" '$2==p && $3 ~ /claude/ {print $1; exit}')
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg sid "$sid" --arg project "$project" \
       --arg evt "$evt" --arg text "$text" --arg tool "$tool" \
       --arg pane "${pane:-}" --argjson prio "$prio" \
       --arg species "$SP_SLUG" \
       '{ts:$ts, session_id:$sid, project:$project, event:$evt, priority:$prio,
         tool:$tool, text:$text, species:$species, pane:$pane, status:"pending"}' \
  >> "$STATE_DIR/questions.jsonl"

# Tier B storm suppression: queue was logged, but skip voice rendering.
[[ "${silent_tier_b:-0}" == "1" ]] && exit 0

# --- Render bird sample with pan/vol/distance ---------------------------------
# Tier A: full call, near.   Tier B: shorter chirp with low-pass for "distance".
OUT="/tmp/cc-birdwatch-${sid}-$$.wav"
if [[ "$tier" == "B" ]]; then
  sox "$BIRD_WAV" -c 2 -r 44100 "$OUT" \
      remix 1v"$L" 1v"$R" \
      trim 0 0.75 fade t 0.02 0 0.15 \
      lowpass 2200 \
      vol "$vol" \
      pad 0.05 0.05 2>/dev/null || exit 0
else
  sox "$BIRD_WAV" -c 2 -r 44100 "$OUT" \
      remix 1v"$L" 1v"$R" \
      vol "$vol" \
      pad 0.05 0.1 2>/dev/null || exit 0
fi

# Estimate WAV duration + queue wait, so the dashboard knows when this fairy
# will actually start speaking (not just when dispatch ran).
DUR=$(sox "$OUT" -n stat 2>&1 | awk '/^Length/ {printf "%.2f", $3+0}')
[[ -z "$DUR" ]] && DUR=2.0
# Count pending jobs (ours already moved to queue dir below; N ahead = count-1)
QDEPTH=$(ls /tmp/cc-birdwatch-queue 2>/dev/null | wc -l | tr -d ' ')
SPK_FROM=$(awk -v n="$NOW" -v q="$QDEPTH" 'BEGIN{printf "%d", n + q*2}')   # 2s/item estimate
SPK_UNTIL=$(awk -v f="$SPK_FROM" -v d="$DUR" 'BEGIN{printf "%d", f + d + 1}')
jq --argjson spkfrom "$SPK_FROM" --argjson spkuntil "$SPK_UNTIL" \
   --argjson dist "$dist" --argjson vol_dist "$vol" --arg tier "$tier" \
   '. + {speaking_from:$spkfrom, speaking_until:$spkuntil,
         speaking_distance:$dist, speaking_vol:$vol_dist, speaking_tier:$tier}' \
   "$SREG" > "${SREG}.tmp" 2>/dev/null && mv "${SREG}.tmp" "$SREG"

LOCK_DIR=/tmp/cc-birdwatch-play.lockdir
QUEUE_DIR=/tmp/cc-birdwatch-queue
mkdir -p "$QUEUE_DIR"
QJOB="${QUEUE_DIR}/$(date +%s)-$$.wav"
mv "$OUT" "$QJOB"

(
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -d "$LOCK_DIR" ]]; then
      AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || date +%s) ))
      (( AGE > 20 )) && rmdir "$LOCK_DIR" 2>/dev/null
    fi
    sleep 0.05
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
  COUNT=$(ls -1 "$QUEUE_DIR" 2>/dev/null | wc -l | tr -d ' ')
  if (( COUNT > 3 )); then
    ls -1t "$QUEUE_DIR" 2>/dev/null | tail -n +3 | while read -r f; do
      rm -f "${QUEUE_DIR}/$f"
    done
  fi
  for f in $(ls -1tr "$QUEUE_DIR" 2>/dev/null); do
    afplay "${QUEUE_DIR}/$f" 2>/dev/null
    rm -f "${QUEUE_DIR}/$f"
  done
) </dev/null >/dev/null 2>&1 &
disown %1 2>/dev/null || disown 2>/dev/null || true
exit 0
