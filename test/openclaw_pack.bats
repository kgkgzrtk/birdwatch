#!/usr/bin/env bats
# OpenClaw hook-pack layout contract: adapters/openclaw must be installable
# via `openclaw plugins install <path>` — an npm package whose package.json
# exports hook directories through `openclaw.hooks`.

load test_helper

setup() {
  common_setup
  PACK="$REPO_ROOT/adapters/openclaw"
}

@test "hook pack has a valid package.json with openclaw.hooks" {
  [ -f "$PACK/package.json" ]
  run jq -e '.name and .version and (.openclaw.hooks | type == "array" and length > 0)' "$PACK/package.json"
  [ "$status" -eq 0 ]
}

@test "every openclaw.hooks entry is a hook dir inside the package" {
  while IFS= read -r entry; do
    dir="$PACK/$entry"
    [ -d "$dir" ] || { echo "missing hook dir: $entry" >&2; return 1; }
    [ -f "$dir/HOOK.md" ] || { echo "missing HOOK.md in $entry" >&2; return 1; }
    [ -f "$dir/handler.ts" ] || [ -f "$dir/handler.js" ] || { echo "missing handler in $entry" >&2; return 1; }
    case "$entry" in ..*|/*) echo "entry escapes package: $entry" >&2; return 1 ;; esac
  done < <(jq -r '.openclaw.hooks[]' "$PACK/package.json")
}

@test "pack version matches plugin.json version" {
  pkg=$(jq -r .version "$PACK/package.json")
  plg=$(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")
  [ "$pkg" = "$plg" ]
}
