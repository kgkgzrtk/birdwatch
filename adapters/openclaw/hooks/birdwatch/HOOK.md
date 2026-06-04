---
name: birdwatch
description: "Chirp a per-agent bird call when the agent sends a message (birdwatch spatial audio)"
metadata: { "openclaw": { "emoji": "🐦", "events": ["message:sent"], "requires": { "bins": ["bash", "jq", "sox"] }, "os": ["darwin"] } }
---

# birdwatch

Forwards `message:sent` events to the birdwatch dispatcher so every OpenClaw
agent sings as a real bird — questions arrive near your ear, routine reports
chirp far away.

Install (the parent directory is an npm hook pack):

    openclaw plugins install /path/to/birdwatch/adapters/openclaw
    openclaw hooks enable birdwatch
    openclaw gateway restart

The dispatcher path defaults to a clone at `~/github/birdwatch`; override with
the `BIRDWATCH_DISPATCH` environment variable.
