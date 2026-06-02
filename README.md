![birdwatch](assets/banner.svg)

# birdwatch

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757) ![Platform: macOS](https://img.shields.io/badge/platform-macOS-000?logo=apple&logoColor=white)

Spatial audio monitoring for Claude Code. Every project sings as a different
**real bird species**, so you can hear which of your sessions needs you without
looking. Approvals lean in close to your ear; background reports drift far away
and quiet. Built as hooks — no model tokens, no chat noise.

- **project → bird species** — each project gets a distinct call (28 species, Wikimedia Commons)
- **session → pan** — each session has a fixed left/right home position
- **event → distance** — approvals (Tier A) up close & loud; reports (Tier B) far, soft, low-pass
- **storm control** — same-project reports are throttled to one chirp / 15s

A live dashboard visualizes sessions as birds orbiting you, approaching when they speak.

![birdwatch dashboard](assets/dashboard.png)

## Install (private marketplace)

```
/plugin marketplace add kgkgzrtk/birdwatch
/plugin install spatial-audio@birdwatch
```

## Requirements

- `sox` and `jq` on `PATH` (the dispatcher exits silently if missing)
- macOS `afplay` for playback
- `python3` for the dashboard

## Commands

- `/spatial-audio:dashboard` — launch the orbit dashboard at http://localhost:8765
- `/spatial-audio:inbox` — list pending approvals/questions across all sessions

## Tuning

| Env | Effect |
|---|---|
| `SPATIAL_AUDIO_OFF=1` | mute everything |
| `SPATIAL_AUDIO_RATE_LIMIT` | per-session min seconds between chirps (default 4) |
| `SPATIAL_TIER_B_COOLDOWN` | per-project report cooldown seconds (default 15) |
| `SPATIAL_DASH_PORT` | dashboard port (default 8765) |

Runtime state lives in `${CLAUDE_PLUGIN_DATA}/spatial`. To add or refresh species,
edit the `SPECIES` list in `scripts/birds-bootstrap.sh` and re-run it (appends to the
end so existing project→bird mappings stay stable).

## License

This repository is **mixed-license**:

- **Code** — scripts, manifests, dashboard, and banner artwork — is MIT, see [`LICENSE`](LICENSE).
- **Bird recordings** in `assets/birds/samples/` are sourced from Wikimedia Commons and
  individually licensed **CC BY-SA 4.0 / 3.0**, **CC BY 2.5**, or **Public Domain** (none
  NonCommercial or NoDerivatives). They are modified excerpts (trimmed, normalized) and are
  **not** covered by the MIT license. Redistribution must preserve attribution and share-alike
  per [`assets/birds/ATTRIBUTIONS.md`](assets/birds/ATTRIBUTIONS.md).
