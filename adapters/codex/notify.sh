#!/usr/bin/env bash
# birdwatch adapter for the OpenAI Codex CLI `notify` mechanism.
#
# Codex invokes the configured notify program with its JSON payload appended
# as the FINAL argument. Point codex at this script in ~/.codex/config.toml:
#
#   notify = ["bash", "/path/to/birdwatch/adapters/codex/notify.sh"]
#
# To keep an existing notifier working, chain it (it receives the payload too):
#
#   notify = ["bash", ".../adapters/codex/notify.sh", "--chain", "<prog>", "<arg>", "--"]
#
# Event mapping:
#   agent-turn-complete / turn-ended  -> Stop (last-assistant-message as text)
#   exec-approval / patch-approval    -> PermissionRequest
# Anything else (or unparsable input) exits 0 silently — never break codex.
set -u

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH="${BIRDWATCH_DISPATCH:-$PLUGIN_ROOT/scripts/dispatch.sh}"

# argv: [--chain prog [args...] --] payload
chain=()
if [[ "${1:-}" == "--chain" ]]; then
  shift
  while [[ $# -gt 1 && "$1" != "--" ]]; do
    chain+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
fi
payload="${1:-}"

command -v jq >/dev/null || exit 0
type=$(jq -r '.type // empty' <<<"$payload" 2>/dev/null) || true
if [[ -n "$type" ]]; then
  sid=$(jq -r '.conversation_id // ."conversation-id" // ."turn-id" // "codex"' <<<"$payload" 2>/dev/null)
  cwd=$(jq -r '.cwd // .codex_cwd // ."codex-cwd" // empty' <<<"$payload" 2>/dev/null)

  case "$type" in
    agent-turn-complete | turn-ended)
      text=$(jq -r '."last-assistant-message" // .last_assistant_message // empty' <<<"$payload" 2>/dev/null)
      if [[ -n "$text" ]]; then
        jq -nc --arg sid "$sid" --arg cwd "$cwd" --arg text "$text" \
          '{session_id:$sid, hook_event_name:"Stop", cwd:$cwd, text:$text}' \
          | bash "$DISPATCH" Stop
      fi
      ;;
    exec-approval | patch-approval)
      cmd=$(jq -r '.codex_command // ."codex-command" // empty' <<<"$payload" 2>/dev/null \
        | tr '\n' ' ' | cut -c1-40)
      jq -nc --arg sid "$sid" --arg cwd "$cwd" --arg tool "codex ${type%%-*} ${cmd}" \
        '{session_id:$sid, hook_event_name:"PermissionRequest", cwd:$cwd, tool_name:$tool}' \
        | bash "$DISPATCH" PermissionRequest
      ;;
    *) ;;
  esac
fi

# Forward to the chained notifier last so a slow chain never delays the chirp.
if [[ ${#chain[@]} -gt 0 ]]; then
  "${chain[@]}" "$payload" >/dev/null 2>&1 || true
fi
exit 0
