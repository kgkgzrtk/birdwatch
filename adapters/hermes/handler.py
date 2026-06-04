"""birdwatch hook for Hermes — forwards agent:end to the birdwatch dispatcher.

Install: copy this directory to ~/.hermes/hooks/birdwatch/ and restart the
gateway. The dispatcher path defaults to a clone at ~/github/birdwatch;
override with the BIRDWATCH_DISPATCH environment variable.
"""

import asyncio
import json
import os
from pathlib import Path

DISPATCH = os.environ.get(
    "BIRDWATCH_DISPATCH",
    str(Path.home() / "github/birdwatch/scripts/dispatch.sh"),
)


async def handle(event_type, context):
    if event_type != "agent:end":
        return None
    text = (context.get("response") or "").strip()
    if not text:
        return None
    platform = context.get("platform") or "hermes"
    chat = context.get("chat_id") or context.get("user_id") or "chat"
    payload = json.dumps(
        {
            "session_id": str(context.get("session_id") or f"{platform}-{chat}"),
            "hook_event_name": "Stop",
            "cwd": f"hermes/{platform}-{chat}",
            "text": text[:500],
        }
    )
    try:
        proc = await asyncio.create_subprocess_exec(
            "bash",
            DISPATCH,
            "Stop",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.communicate(payload.encode()), timeout=10)
    except Exception:
        pass  # never block the gateway
    return None
