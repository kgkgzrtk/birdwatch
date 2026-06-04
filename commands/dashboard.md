---
description: Launch the birdwatch dashboard (localhost:8765)
---

Start the live dashboard that visualizes active agent sessions as birds
orbiting the listener. Run it in the background and tell the user the URL:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/dashboard.py"
```

Then open http://localhost:8765 (override the port with `BIRDWATCH_DASH_PORT`).
