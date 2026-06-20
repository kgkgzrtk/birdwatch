#!/usr/bin/env python3
"""Birdwatch dashboard — live 2D visualization of agent-session "fairies".

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
_DATA = (
    os.environ.get("BIRDWATCH_STATE_DIR")
    or os.environ.get("CLAUDE_PLUGIN_DATA")
    or str(Path.home() / ".claude/state")
)
ROOT = Path(_DATA) / "birdwatch"

# Read-only assets (species list + samples) live under the plugin root; fall
# back to this script's repo layout when run standalone.
_PLUGIN_ROOT = Path(
    os.environ.get("CLAUDE_PLUGIN_ROOT") or Path(__file__).resolve().parent.parent
)
SPECIES_JSON = _PLUGIN_ROOT / "assets/birds/species.json"
SAMPLES_DIR = _PLUGIN_ROOT / "assets/birds/samples"
OVERRIDES = ROOT / "overrides.json"

DRIFT_WINDOW = 30  # seconds — matches dispatch.sh BURST calc
ACTIVE_WINDOW = 1800  # seconds — hide sessions idle longer than 30min


def load_species() -> list[dict]:
    """Bird species available for selection (slug, common, latin)."""
    try:
        data = json.loads(SPECIES_JSON.read_text())
    except (json.JSONDecodeError, OSError):
        return []
    return [
        {
            "slug": e["slug"],
            "common": e.get("common", e["slug"]),
            "latin": e.get("latin", ""),
        }
        for e in data
        if "slug" in e
    ]


def species_slugs() -> set[str]:
    return {e["slug"] for e in load_species()}


def load_overrides() -> dict[str, str]:
    try:
        return json.loads(OVERRIDES.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def save_overrides(data: dict[str, str]) -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    tmp = OVERRIDES.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    tmp.replace(OVERRIDES)


def projects_with_species() -> list[dict]:
    """Distinct projects seen in the registry, with their effective species and
    whether it is user-overridden."""
    overrides = load_overrides()
    seen: dict[str, dict] = {}
    reg_dir = ROOT / "sessions"
    if reg_dir.exists():
        for f in reg_dir.glob("*.json"):
            try:
                r = json.loads(f.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            proj = r.get("project")
            if not proj:
                continue
            last = float(r.get("last_seen", 0))
            cur = seen.get(proj)
            if cur is None or last > cur["_last"]:
                seen[proj] = {"_last": last, "species": r.get("species", "")}
    # include override-only projects that haven't chirped recently
    for proj in overrides:
        seen.setdefault(proj, {"_last": 0, "species": overrides[proj]})
    out = []
    for proj, v in seen.items():
        out.append(
            {
                "project": proj,
                "project_short": Path(proj).name or proj,
                "species": v["species"],
                "override": overrides.get(proj),
            }
        )
    out.sort(key=lambda x: x["project_short"].lower())
    return out


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
        out.append(
            {
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
            }
        )
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
  #gear{position:fixed;top:8px;right:352px;z-index:3;cursor:pointer;background:rgba(30,36,48,.9);
        border:1px solid #2a3140;color:#cdd6f4;border-radius:6px;padding:4px 8px;font-size:14px}
  #gear:hover{background:#2a3140}
  #modal{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:4;display:none;align-items:center;justify-content:center}
  #modal.open{display:flex}
  #panel{background:#0e121a;border:1px solid #2a3140;border-radius:10px;width:min(620px,92vw);
         max-height:82vh;overflow:auto;padding:18px 20px;box-shadow:0 12px 40px rgba(0,0,0,.5)}
  #panel h2{margin:0 0 4px;font-size:16px}
  #panel .sub{color:#8b949e;font-size:12px;margin-bottom:14px}
  .prow{display:flex;align-items:center;gap:8px;padding:7px 0;border-bottom:1px solid #1a2030}
  .prow .pn{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#89b4fa}
  .prow .pn small{color:#6e7681;margin-left:6px}
  .prow select{background:#161b22;color:#cdd6f4;border:1px solid #2a3140;border-radius:5px;padding:3px 6px;font-size:12px;max-width:170px}
  .prow button{background:#1f2430;color:#cdd6f4;border:1px solid #2a3140;border-radius:5px;cursor:pointer;padding:3px 8px}
  .prow button:hover{background:#2a3140}
  #panel .close{float:right;cursor:pointer;color:#8b949e;font-size:18px;line-height:1}
  #empty{color:#6e7681;font-size:13px;padding:10px 0}
</style></head>
<body>
<div id="hud">Birdwatch · <span id="count">0</span> · speaking <span id="nspk">0</span> · <span id="t"></span></div>
<div id="gear" title="Per-project bird settings">⚙</div>
<div id="modal"><div id="panel">
  <span class="close" id="mclose">×</span>
  <h2>Per-project bird</h2>
  <div class="sub">Pick the call each project sings. ▶ previews it. "Auto" returns to the default.</div>
  <div id="prows"></div>
</div></div>
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

// --- Settings: per-project bird selection ----------------------------------
const escH = s => String(s==null?'':s).replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let speciesList = [];
const previewAudio = new Audio();

async function openSettings(){
  if(!speciesList.length){
    try{ speciesList = await (await fetch('/api/species')).json(); }catch(e){ speciesList = []; }
  }
  await renderSettings();
  document.getElementById('modal').classList.add('open');
}
function closeSettings(){ document.getElementById('modal').classList.remove('open'); previewAudio.pause(); }

async function renderSettings(){
  let projects = [];
  try{ projects = await (await fetch('/api/projects', {cache:'no-store'})).json(); }catch(e){}
  const opts = ['<option value="">Auto (default)</option>'].concat(
    speciesList.map(s => `<option value="${escH(s.slug)}">${escH(s.common)}</option>`)).join('');
  const host = document.getElementById('prows');
  if(!projects.length){ host.innerHTML = '<div id="empty">No projects yet — they appear here after their first chirp.</div>'; return; }
  host.innerHTML = projects.map(p => {
    const sel = p.override || '';
    const cur = p.species ? ` <small>now: ${escH(p.species)}</small>` : '';
    return `<div class="prow" data-proj="${escH(p.project)}">
      <span class="pn" title="${escH(p.project)}">${escH(p.project_short)}${cur}</span>
      <select class="ovsel">${opts}</select>
      <button class="prev" title="Preview">▶</button>
    </div>`;
  }).join('');
  // set current selection + wire events
  host.querySelectorAll('.prow').forEach((row,i) => {
    const sel = row.querySelector('.ovsel');
    sel.value = projects[i].override || '';
    sel.addEventListener('change', () => saveOverride(projects[i].project, sel.value || null));
    row.querySelector('.prev').addEventListener('click', () => {
      const slug = sel.value || projects[i].species;
      if(slug){ previewAudio.src = '/api/sample?slug='+encodeURIComponent(slug); previewAudio.play().catch(()=>{}); }
    });
  });
}

async function saveOverride(project, slug){
  try{
    await fetch('/api/override', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({project, slug})});
  }catch(e){}
  renderSettings();
}

document.getElementById('gear').addEventListener('click', openSettings);
document.getElementById('mclose').addEventListener('click', closeSettings);
document.getElementById('modal').addEventListener('click', e => { if(e.target.id==='modal') closeSettings(); });
window.addEventListener('keydown', e => { if(e.key==='Escape') closeSettings(); });
if(location.hash === '#settings') openSettings();  // deep-link to the panel

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
    def log_message(self, *a):
        pass

    def _send(self, body: bytes, ctype: str, code: int = 200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200):
        self._send(json.dumps(obj).encode(), "application/json; charset=utf-8", code)

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs

        path = urlparse(self.path).path
        if path == "/api/fairies":
            return self._json(fairies())
        if path == "/api/species":
            return self._json(load_species())
        if path == "/api/projects":
            return self._json(projects_with_species())
        if path == "/api/overrides":
            return self._json(load_overrides())
        if path == "/api/sample":
            slug = (parse_qs(urlparse(self.path).query).get("slug") or [""])[0]
            if slug not in species_slugs():  # validated → no path traversal
                return self.send_error(404)
            wav = SAMPLES_DIR / f"{slug}.wav"
            try:
                return self._send(wav.read_bytes(), "audio/wav")
            except OSError:
                return self.send_error(404)
        if path in ("/", "/index.html"):
            return self._send(INDEX_HTML.encode(), "text/html; charset=utf-8")
        self.send_error(404)

    def do_POST(self):
        from urllib.parse import urlparse

        if urlparse(self.path).path != "/api/override":
            return self.send_error(404)
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._json({"error": "bad request"}, 400)
        project = req.get("project")
        slug = req.get("slug") or None
        if not isinstance(project, str) or not project or len(project) > 1024:
            return self._json({"error": "invalid project"}, 400)
        if slug is not None and slug not in species_slugs():
            return self._json({"error": "unknown slug"}, 400)
        overrides = load_overrides()
        if slug is None:
            overrides.pop(project, None)  # clear → back to hash default
        else:
            overrides[project] = slug
        save_overrides(overrides)
        return self._json({"ok": True, "project": project, "slug": slug})


class ReuseTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with ReuseTCPServer(("127.0.0.1", PORT), H) as s:
        print(f"Birdwatch dashboard: http://localhost:{PORT}")
        s.serve_forever()
