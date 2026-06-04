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
  if (!event || event.type !== "message" || event.action !== "sent") return;
  const ctx = event.context || event.payload || {};
  const raw = ctx.content ?? ctx.text ?? ctx.body ?? "";
  const text = String(typeof raw === "string" ? raw : JSON.stringify(raw)).trim();
  if (!text) return;
  const session = String(ctx.sessionKey ?? ctx.sessionId ?? "openclaw");
  const project = String(
    ctx.workspaceDir ?? ctx.cwd ?? (ctx.agentId ? `openclaw/${ctx.agentId}` : "openclaw"),
  );
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
