---
description: Launch the spatial-audio bird dashboard (localhost:8765)
---

Start the live dashboard that visualizes active Claude Code sessions as birds
orbiting the listener. Run it in the background and tell the user the URL:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/dashboard.py"
```

Then open http://localhost:8765 (override the port with `SPATIAL_DASH_PORT`).
