#!/usr/bin/env python3
"""Birdwatch dashboard — live 2D visualization of Claude Code "fairies".

Run:  scripts/dashboard.py   (then open http://localhost:8765)

Reads state from ${CLAUDE_PLUGIN_DATA}/birdwatch (falls back to ~/.claude/state/birdwatch):
  sessions/<sid>.json  (registry: project, pbas, pan_home)
  activity/<sid>.log   (timestamped event stream)
  questions.jsonl      (last text + priority)

Computes pan drift the same way dispatch.sh does, so positions match audio.
"""
from __future__ import annotations
import http.server
import json
import math
import os
import socketserver
import time
from pathlib import Path

PORT = int(os.environ.get("BIRDWATCH_DASH_PORT", "8765"))
_DATA = os.environ.get("CLAUDE_PLUGIN_DATA") or str(Path.home() / ".claude/state")
ROOT = Path(_DATA) / "birdwatch"

DRIFT_WINDOW = 30    # seconds — matches dispatch.sh BURST calc
ACTIVE_WINDOW = 1800 # seconds — hide sessions idle longer than 30min


def load_questions_latest_by_sid() -> dict[str, dict]:
    """Return latest queue entry per sid."""
    q = ROOT / "questions.jsonl"
    out: dict[str, dict] = {}
    if not q.exists():
        return out
    try:
        for line in q.read_text().splitlines():
            if not line.strip():
                continue
            o = json.loads(line)
            out[o["session_id"]] = o
    except (json.JSONDecodeError, OSError):
        pass
    return out


def count_burst(sid: str, now: float) -> int:
    log = ROOT / "activity" / f"{sid}.log"
    if not log.exists():
        return 0
    try:
        n = 0
        for line in log.read_text().splitlines():
            ts = line.split(None, 1)[0] if line else ""
            try:
                if now - float(ts) <= DRIFT_WINDOW:
                    n += 1
            except ValueError:
                continue
        return n
    except OSError:
        return 0


def drift(home: float, burst: int, sid_hash: int, now: float) -> tuple[float, float]:
    """Match dispatch.sh pan drift formula."""
    if burst < 2:
        amp = 0.0
    elif burst > 6:
        amp = 0.15
    else:
        amp = (burst - 2) / 4.0 * 0.15
    phase = math.sin(now / 7.0 * 2 * math.pi + (sid_hash % 100) / 15.9)
    pos = home + amp * phase
    pos = max(0.0, min(1.0, pos))
    return pos, amp


def cksum_like(s: str) -> int:
    """POSIX cksum (CRC) — used by dispatch.sh. Fall back to hash if unavailable."""
    import subprocess
    try:
        r = subprocess.run(["cksum"], input=s.encode(), capture_output=True, check=True)
        return int(r.stdout.split()[0])
    except Exception:
        return abs(hash(s)) & 0xFFFFFFFF


def fairies() -> list[dict]:
    now = time.time()
    reg_dir = ROOT / "sessions"
    if not reg_dir.exists():
        return []
    questions = load_questions_latest_by_sid()
    out: list[dict] = []
    for f in reg_dir.glob("*.json"):
        try:
            r = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        sid = r["sid"]
        last_seen = float(r.get("last_seen", 0))
        if now - last_seen > ACTIVE_WINDOW:
            continue
        h = cksum_like(sid)
        burst = count_burst(sid, now)
        pan, drift_amp = drift(float(r["pan_home"]), burst, h, now)
        q = questions.get(sid, {})
        out.append({
            "sid": sid,
            "sid_hash": h,
            "sid_short": sid[:8],
            "project": r["project"],
            "project_short": Path(r["project"]).name or r["project"],
            "pbas": r["pbas"],
            "pan_home": r["pan_home"],
            "pan": pan,
            "drift": drift_amp,
            "burst": burst,
            "last_event": r.get("last_event", ""),
            "last_seen": last_seen,
            "idle_s": int(now - last_seen),
            "text": q.get("text", "")[:80],
            "priority": q.get("priority", 9),
            "status": q.get("status", ""),
            # Dynamics: is this fairy speaking right now?
            "speaking_from": r.get("speaking_from", 0),
            "speaking_until": r.get("speaking_until", 0),
            "speaking_distance": r.get("speaking_distance", 0.85),
            "speaking_vol": r.get("speaking_vol", 0.3),
            "speaking_tier": r.get("speaking_tier", ""),
        })
    out.sort(key=lambda x: x["pan"])
    return out


INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Birdwatch</title>
<style>
  body{margin:0;background:#05070b;color:#cdd6f4;font-family:-apple-system,system-ui,sans-serif;overflow:hidden}
  #hud{position:fixed;top:8px;left:12px;font-size:12px;opacity:.7;z-index:2}
  #list{position:fixed;right:0;top:0;bottom:0;width:340px;background:rgba(14,18,26,0.92);backdrop-filter:blur(8px);border-left:1px solid #1a1f28;padding:12px;overflow:auto;font-size:12px;z-index:2}
  .row{border-bottom:1px solid #1f2430;padding:6px 0;line-height:1.4}
  .row.spk{background:rgba(249,226,175,0.08);border-left:2px solid #f9e2af;padding-left:6px}
  .proj{color:#89b4fa;font-weight:600}
  .prio1{color:#f38ba8}.prio2{color:#fab387}.prio3{color:#f9e2af}.prio4{color:#a6e3a1}
  .badge{display:inline-block;padding:0 5px;border-radius:3px;background:#313244;font-size:10px;margin-left:4px}
  canvas{display:block}
</style></head>
<body>
<div id="hud">Birdwatch · <span id="count">0</span> · speaking <span id="nspk">0</span> · <span id="t"></span></div>
<div id="list"></div>
<canvas id="c"></canvas>
<script>
const cv = document.getElementById('c'), ctx = cv.getContext('2d');
const listEl = document.getElementById('list'), countEl = document.getElementById('count'), nspkEl = document.getElementById('nspk'), tEl = document.getElementById('t');
let fairies = [];
const state = new Map(); // sid → {x, y, size, glow, speakingPrev}

function resize(){ cv.width = window.innerWidth - 340; cv.height = window.innerHeight; }
resize(); window.addEventListener('resize', resize);

function nowS(){ return Date.now() / 1000; }

async function poll(){
  try{
    const r = await fetch('/api/fairies', {cache:'no-store'}); fairies = await r.json();
  }catch(e){ /* keep stale */ }
}
setInterval(poll, 400); poll();

function pitchToColor(pbas, a=1){
  const h = 200 + ((pbas - 30) / 45) * 160;
  return `hsla(${h}deg, 75%, 62%, ${a})`;
}

function render(){
  resize();
  const t = nowS();
  const W = cv.width, H = cv.height;
  // Motion trail / fade
  ctx.fillStyle = 'rgba(5,7,11,0.30)'; ctx.fillRect(0, 0, W, H);

  // TOP-DOWN 360° view: listener at canvas center, fairies orbit around
  const cx = W / 2, cy = H / 2, R = Math.min(W, H) * 0.45;

  // Concentric range rings
  ctx.strokeStyle = 'rgba(31,39,51,0.9)'; ctx.lineWidth = 1;
  for (const rr of [0.25, 0.5, 0.85]){
    ctx.beginPath(); ctx.arc(cx, cy, R*rr, 0, 2*Math.PI); ctx.stroke();
  }
  ctx.strokeStyle = '#1f2733';
  ctx.beginPath(); ctx.arc(cx, cy, R, 0, 2*Math.PI); ctx.stroke();

  // Compass axes
  ctx.strokeStyle='rgba(31,39,51,0.5)'; ctx.setLineDash([4,6]);
  ctx.beginPath(); ctx.moveTo(cx-R,cy); ctx.lineTo(cx+R,cy); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(cx,cy-R); ctx.lineTo(cx,cy+R); ctx.stroke();
  ctx.setLineDash([]);

  // Listener at center, gently pulsing
  const pulse = 0.5 + 0.5*Math.sin(t*2);
  ctx.fillStyle = `hsla(230, 20%, ${55+pulse*15}%, 1)`;
  ctx.beginPath(); ctx.arc(cx, cy, 10, 0, 2*Math.PI); ctx.fill();
  ctx.strokeStyle='rgba(205,214,244,0.25)'; ctx.lineWidth=1;
  ctx.beginPath(); ctx.arc(cx, cy, 10 + 10*pulse, 0, 2*Math.PI); ctx.stroke();
  ctx.fillStyle = '#9aa5b1'; ctx.font='11px ui-sans-serif'; ctx.textAlign = 'center';
  ctx.fillText('you', cx, cy + 26);

  // Compass labels
  ctx.fillStyle='#45475a'; ctx.font='11px ui-sans-serif';
  ctx.fillText('front', cx, cy - R - 8);
  ctx.fillText('back',  cx, cy + R + 18);
  ctx.fillText('◂ L',   cx - R - 18, cy + 4);
  ctx.fillText('R ▸',   cx + R + 18, cy + 4);

  // Distance → volume legend (vol = 1 / (1 + 3·d²))
  // Ring labels show how audible each radius is.
  ctx.fillStyle = 'rgba(166,227,161,0.55)'; ctx.font = '9px ui-monospace';
  ctx.textAlign = 'left';
  ctx.fillText('P1 ear vol 0.96',     cx + 6, cy - R*0.15);
  ctx.fillText('P2 vol 0.57',         cx + 6, cy - R*0.40);
  ctx.fillText('P4 whisper vol 0.29', cx + 6, cy - R*0.82);

  let speakingCount = 0;
  const spkSids = [];

  // Render: inactive first (behind), active on top
  const ordered = fairies.slice().sort((a,b) => {
    const aLvl = (a.speaking_until && t < a.speaking_until) ? 2 : (a.burst > 0 ? 1 : 0);
    const bLvl = (b.speaking_until && t < b.speaking_until) ? 2 : (b.burst > 0 ? 1 : 0);
    return aLvl - bLvl;
  });

  ordered.forEach(f => {
    // Per-fairy stable orbital parameters (seeded by sid hash)
    const h = f.sid_hash;
    const ph1 = ((h % 997) / 997) * Math.PI * 2;
    const ph2 = ((h % 599) / 599) * Math.PI * 2;
    // Base angle from pan + project (so same project clusters in a wedge)
    const baseAngle = f.pan * 2 * Math.PI + ph1;
    // Orbit distance is CONTINUOUSLY shaped by pending priority.
    //   P1 (PermissionRequest pending): ~0.30 — close, waiting
    //   P2 (Notification pending):      ~0.50
    //   P3 (Stop-question pending):     ~0.60
    //   P4 (Stop-report pending):       ~0.82
    //   no pending / resolved:          ~0.92 (far rim)
    const prioBias = {1:0.30, 2:0.50, 3:0.60, 4:0.82}[f.priority] ?? 0.92;
    // Small per-fairy scatter (±0.05) so fairies at the same priority don't overlap
    const scatter = (((h % 1000) / 1000) - 0.5) * 0.10;
    const orbitDistF = Math.max(0.18, Math.min(0.97, prioBias + scatter));
    // Orbital angular velocity: slow, each fairy unique
    const omega = 0.06 + ((h % 300) / 300) * 0.10;          // 0.06..0.16 rad/s
    const dirSign = (h % 2) ? 1 : -1;                        // half clockwise, half ccw

    // Approach starts when queue reaches this fairy (speaking_from),
    // ends when its audio finishes (speaking_until). Before from: still orbiting.
    const speaking = f.speaking_from && f.speaking_until
                     && t >= f.speaking_from && t < f.speaking_until;
    if (speaking) speakingCount++;

    const fade = speaking ? 1 : Math.max(0.12, Math.min(1, 1 - f.idle_s / 300));
    const activeBoost = Math.min(1, f.burst / 4);

    // Smooth orbital motion — angle grows with time, active agents orbit faster
    const orbitAngle = baseAngle + t * omega * dirSign * (1 + 0.6*activeBoost);
    // Small radial wobble so they aren't on perfect circles
    const radialWobble = Math.sin(t*0.7 + ph2) * 0.025 + Math.cos(t*1.4 + ph1) * 0.018;

    // Speaking → pull toward listener; else keep orbiting far
    const distF = speaking
      ? f.speaking_distance + Math.sin(t*2 + ph1) * 0.015
      : orbitDistF + radialWobble + 0.03 * activeBoost * Math.sin(t*2 + ph2);
    const dist = R * Math.max(0.08, Math.min(0.97, distF));

    // When speaking, keep the current orbital angle frozen at approach start
    // so the fairy comes STRAIGHT in from where it was, not from elsewhere.
    const angle = orbitAngle;
    const tx = cx + dist * Math.cos(angle);
    const ty = cy + dist * Math.sin(angle);

    let s = state.get(f.sid);
    if (!s) { s = {x: tx, y: ty, size: 6, glow: 0, spk: false}; state.set(f.sid, s); }
    const k = speaking ? 0.18 : (s.spk ? 0.05 : 0.14);
    s.x += (tx - s.x) * k;
    s.y += (ty - s.y) * k;
    const targetSize = (speaking ? 16 : 4 + 4*fade) + Math.min(f.burst, 6) * 1.5;
    s.size += (targetSize - s.size) * 0.2;
    const targetGlow = speaking ? 1.0 : (f.burst > 0 ? 0.55 * fade : 0.10 * fade);
    s.glow += (targetGlow - s.glow) * 0.15;
    s.spk = speaking;

    const color = pitchToColor(f.pbas, fade);

    // Aura / halo
    if (s.glow > 0.08){
      const rad = s.size * (speaking ? 4.5 : 2.4);
      const grad = ctx.createRadialGradient(s.x, s.y, s.size*0.6, s.x, s.y, rad);
      grad.addColorStop(0, pitchToColor(f.pbas, 0.45 * s.glow));
      grad.addColorStop(1, pitchToColor(f.pbas, 0));
      ctx.fillStyle = grad;
      ctx.beginPath(); ctx.arc(s.x, s.y, rad, 0, 2*Math.PI); ctx.fill();
    }

    if (speaking){
      const vol = f.speaking_vol || 0.5;
      ctx.strokeStyle = pitchToColor(f.pbas, 0.35 + 0.4*vol);
      ctx.lineWidth = 1.5 + 2*vol;
      ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(s.x, s.y); ctx.stroke();
    }

    // Body
    ctx.fillStyle = color;
    ctx.beginPath(); ctx.arc(s.x, s.y, s.size, 0, 2*Math.PI); ctx.fill();
    // Core highlight
    ctx.fillStyle = `hsla(${200 + ((f.pbas-30)/45)*160}, 100%, 88%, ${(0.5 + 0.4*s.glow) * fade})`;
    ctx.beginPath(); ctx.arc(s.x - s.size*0.3, s.y - s.size*0.3, s.size*0.35, 0, 2*Math.PI); ctx.fill();

    // Labels — only for speaking / active fairies, else the canvas is unreadable
    if (speaking){
      ctx.fillStyle = '#f9e2af';
      ctx.font = 'bold 12px -apple-system'; ctx.textAlign = 'center';
      ctx.fillText(f.project_short, s.x, s.y - s.size - 8);
      if (f.text){
        ctx.font = '11px -apple-system';
        const words = f.text.length > 48 ? f.text.slice(0,48)+'…' : f.text;
        ctx.fillText(words, s.x, s.y + s.size + 16);
      }
    } else if (f.burst > 0){
      ctx.fillStyle = `rgba(205,214,244,${0.85 * fade})`;
      ctx.font = '10px -apple-system'; ctx.textAlign = 'center';
      ctx.fillText(f.project_short, s.x, s.y - s.size - 5);
    }
  });

  nspkEl.textContent = speakingCount;

  // Update sidebar — speaking items first, then idle by priority
  const byPrio = {1:'prio1',2:'prio2',3:'prio3',4:'prio4'};
  const sorted = fairies.slice().sort((a,b)=>{
    const aSpk = (a.speaking_until && t < a.speaking_until) ? 0 : 1;
    const bSpk = (b.speaking_until && t < b.speaking_until) ? 0 : 1;
    return aSpk - bSpk || (a.priority - b.priority);
  });
  const esc = s => String(s==null?'':s).replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  listEl.innerHTML = sorted.slice(0, 50).map(f => {
    const spk = (f.speaking_until && t < f.speaking_until) ? ' spk' : '';
    const remain = spk ? ` <span class="badge">${(f.speaking_until - t).toFixed(1)}s</span>` : '';
    return `<div class="row${spk}">
      <div class="proj">${esc(f.project_short)}${remain}</div>
      <div><span class="${byPrio[f.priority]||''}">P${f.priority}</span>
        · ${esc(f.sid_short)} · pan ${f.pan.toFixed(2)} · burst ${f.burst} · idle ${f.idle_s}s</div>
      <div style="color:#9aa5b1">${esc(f.last_event)}${f.text?': '+esc(f.text.slice(0,60)):''}</div>
    </div>`;
  }).join('');

  countEl.textContent = fairies.length;
  tEl.textContent = new Date().toLocaleTimeString('ja-JP');

  requestAnimationFrame(render);
}
requestAnimationFrame(render);
</script></body></html>
"""


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path == "/api/fairies":
            body = json.dumps(fairies()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ("/", "/index.html"):
            body = INDEX_HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


class ReuseTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with ReuseTCPServer(("127.0.0.1", PORT), H) as s:
        print(f"Birdwatch dashboard: http://localhost:{PORT}")
        s.serve_forever()
