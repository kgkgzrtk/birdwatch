// birdwatch hook for OpenClaw — forwards outbound agent messages to the
// birdwatch dispatcher as a Stop event so each agent sings as a bird.
// Kept logic-free: extract text/session/project defensively, spawn, detach.
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const DISPATCH =
  process.env.BIRDWATCH_DISPATCH ||
  join(homedir(), "github/birdwatch/scripts/dispatch.sh");

const handler = async (event) => {
  // message:sent — event: {type, action, sessionKey, context:{to, content, success, channelId}}
  if (!event || event.type !== "message" || event.action !== "sent") return;
  const ctx = event.context || {};
  const raw = ctx.content ?? "";
  const text = String(typeof raw === "string" ? raw : JSON.stringify(raw)).trim();
  if (!text) return;
  const session = String(event.sessionKey ?? "openclaw");
  // sessionKey format: agent:<agentId>:<channel>:<chatType>:<peer>
  const agentId = session.startsWith("agent:") ? session.split(":")[1] : "";
  const project = agentId ? `openclaw/${agentId}` : "openclaw";
  const payload = JSON.stringify({
    session_id: session,
    hook_event_name: "Stop",
    cwd: project,
    text: text.slice(0, 500),
  });
  try {
    const child = spawn("bash", [DISPATCH, "Stop"], {
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    });
    child.stdin.end(payload);
    child.unref();
  } catch {
    // never block the gateway
  }
};

export default handler;
