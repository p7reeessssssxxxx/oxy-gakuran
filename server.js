// oxy-relay — cross-hub presence + troll command bus.
// Also serves the shared client module at GET /client.lua.
//
// Env:
//   PORT           - provided by Railway (defaults 8080 locally)
//   HUB_KEYS       - JSON map of { "hubId": "secretKey", ... }. Each partner hub gets its
//                    own key. ANY valid key may list + troll free users; the key identifies
//                    which hub sent a command. e.g.  {"oxy":"oxy_ab12","voidhub":"void_9x7"}
//   ADMIN_TOKEN    - (legacy / single-hub) one key, registered as hub "oxy". Still works.
//   PRESENCE_TTL_MS- how long a client stays "online" after last sync (default 15000)
//   MAX_QUEUE      - max pending commands per target (default 20)

import express from "express";
import { WebSocketServer } from "ws";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const PORT            = parseInt(process.env.PORT || "8080", 10);
const PRESENCE_TTL_MS = parseInt(process.env.PRESENCE_TTL_MS || "15000", 10);
const MAX_QUEUE       = parseInt(process.env.MAX_QUEUE || "20", 10);

// key(secret) -> hubId. Three ways to configure keys (all can be combined):
//   1. One variable per hub  -> name it after the hub, value MUST start with "key_"
//      e.g.  Oxy = key_bnjk3458bks   ·   Citra = key_3452345bfg      <-- easiest in Railway
//   2. HUB_KEYS               -> a single JSON var {"oxy":"key_...","citra":"key_..."}
//   3. ADMIN_TOKEN            -> legacy single key, registered as hub "oxy"
const RESERVED_ENV = new Set([
  "PORT", "HUB_KEYS", "ADMIN_TOKEN", "PRESENCE_TTL_MS", "MAX_QUEUE", "NODE_ENV", "PATH", "PWD",
]);
function loadHubKeys() {
  const keys = new Map();
  // (2) HUB_KEYS json
  if (process.env.HUB_KEYS) {
    try {
      const o = JSON.parse(process.env.HUB_KEYS);
      for (const [hub, tok] of Object.entries(o)) if (tok) keys.set(String(tok), String(hub));
    } catch { console.warn("[oxy-relay] HUB_KEYS is not valid JSON — ignoring it"); }
  }
  // (3) legacy single ADMIN_TOKEN
  if (process.env.ADMIN_TOKEN) keys.set(process.env.ADMIN_TOKEN, "oxy");
  // (1) one variable per hub: any env var whose VALUE starts with "key_"  (var name = hub id)
  for (const [name, val] of Object.entries(process.env)) {
    if (RESERVED_ENV.has(name) || name.startsWith("RAILWAY_") || name.startsWith("npm_")) continue;
    if (typeof val === "string" && val.startsWith("key_") && !keys.has(val)) {
      keys.set(val, name.toLowerCase());
    }
  }
  return keys;
}
const HUB_KEYS = loadHubKeys();

// Commands a paid client is allowed to send. No far/teleport movement (no fling/launch/bring).
const ACTIONS = new Set([
  "ping",      // harmless: victim shows a small toast. Used for testing the pipe.
  "notify",    // fake admin message toast / banner
  "fakekick",  // fake "you were kicked" overlay (does not actually kick)
  "spin",      // rotate the victim in place for args.duration
  "freeze",    // anchor the victim in place for args.duration
  "unfreeze",  // release a freeze early
  "sit",       // force-sit / trip
  "explode",   // visual explosion on the victim (no blast force)
]);

if (HUB_KEYS.size === 0) {
  console.warn("[oxy-relay] WARNING: no keys configured (HUB_KEYS / ADMIN_TOKEN) — paid endpoints are OPEN. Set HUB_KEYS.");
}

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------
// presence: userId(string) -> { userId, name, displayName, placeId, jobId,
//                               tier, hubId, ip, firstSeen, lastSeen, queue:[] }
const presence = new Map();
let cmdCounter = 0;

const now = () => Date.now();

function wsOpen(p) {
  return p && p.ws && p.ws.readyState === 1; // 1 === WebSocket.OPEN
}
function isOnline(p) {
  return p && (wsOpen(p) || now() - p.lastSeen <= PRESENCE_TTL_MS);
}

function prune() {
  const t = now();
  for (const [id, p] of presence) {
    if (!wsOpen(p) && t - p.lastSeen > PRESENCE_TTL_MS * 3) presence.delete(id);
  }
}
setInterval(prune, 5000).unref?.();

// ---------------------------------------------------------------------------
// tiny per-IP rate limiter (token bucket)
// ---------------------------------------------------------------------------
const buckets = new Map(); // ip -> { tokens, last }
function rateLimit(ip, ratePerSec, burst) {
  const t = now();
  let b = buckets.get(ip);
  if (!b) { b = { tokens: burst, last: t }; buckets.set(ip, b); }
  b.tokens = Math.min(burst, b.tokens + ((t - b.last) / 1000) * ratePerSec);
  b.last = t;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}
setInterval(() => { if (buckets.size > 5000) buckets.clear(); }, 60000).unref?.();

// ---------------------------------------------------------------------------
// app
// ---------------------------------------------------------------------------
const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "16kb" }));
app.set("trust proxy", true);

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "content-type, x-oxy-token");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

function clientIp(req) {
  return (req.headers["x-forwarded-for"]?.split(",")[0] || req.ip || "0.0.0.0").trim();
}

// Returns the hubId owning the presented key, or null (and writes 401). "" in open mode.
function adminHub(req, res) {
  const tok = req.headers["x-oxy-token"] || req.query.token || "";
  if (HUB_KEYS.size === 0) return ""; // open mode (dev only) — warned at boot
  const hub = HUB_KEYS.get(tok);
  if (!hub) {
    res.status(401).json({ ok: false, error: "bad key" });
    return null;
  }
  return hub;
}

function cleanStr(v, max = 64) {
  if (typeof v !== "string") v = String(v ?? "");
  return v.slice(0, max);
}

// --- serve the shared client module ----------------------------------------
let CLIENT_LUA_CACHE = null;
let CLIENT_LUA_MTIME = 0;
function readClientLua() {
  const p = join(__dirname, "client.lua");
  if (!existsSync(p)) return "-- client.lua missing on server";
  // re-read if changed (cheap; file is small)
  try {
    const src = readFileSync(p, "utf8");
    CLIENT_LUA_CACHE = src;
    return src;
  } catch {
    return CLIENT_LUA_CACHE || "-- client.lua read error";
  }
}
app.get("/client.lua", (req, res) => {
  res.setHeader("Content-Type", "text/plain; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.send(readClientLua());
});

// --- health / dashboard -----------------------------------------------------
app.get("/health", (req, res) => res.json({ ok: true, t: now() }));

app.get("/", (req, res) => {
  const list = [...presence.values()].filter(isOnline);
  const free = list.filter(p => p.tier !== "paid");
  const paid = list.filter(p => p.tier === "paid");
  const byHub = {};
  for (const p of list) byHub[p.hubId || "?"] = (byHub[p.hubId || "?"] || 0) + 1;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.send(`<!doctype html><meta charset=utf-8><title>oxy-relay</title>
<meta http-equiv=refresh content=3>
<style>body{background:#14161a;color:#d8dee9;font:14px ui-monospace,Menlo,monospace;padding:24px}
h1{color:#6ec8ff;margin:0 0 4px}small{color:#787878}.row{display:flex;gap:24px;margin:16px 0}
.card{background:#1b2b34;border:1px solid #343d46;border-radius:8px;padding:12px 16px}
.n{font-size:28px;color:#5dde7a}.p{color:#ffb49a}b{color:#fff}
table{border-collapse:collapse;margin-top:8px;width:100%}td,th{border-bottom:1px solid #2a2f36;padding:4px 8px;text-align:left}</style>
<h1>oxy relay</h1><small>presence + troll bus · ttl ${PRESENCE_TTL_MS}ms · ${HUB_KEYS.size} hub key(s)${HUB_KEYS.size ? "" : " · OPEN ⚠"}</small>
<div class=row>
  <div class=card><div class=n>${list.length}</div>online</div>
  <div class=card><div class=n>${free.length}</div>free (trollable)</div>
  <div class=card><div class="n p">${paid.length}</div>paid (immune)</div>
  <div class=card><div class=n>${Object.keys(byHub).length}</div>hubs</div>
</div>
<table><tr><th>user</th><th>tier</th><th>hub</th><th>place</th><th>queued</th><th>age</th></tr>
${list.sort((a,b)=>a.lastSeen-b.lastSeen).map(p=>`<tr><td><b>${cleanStr(p.name,24)}</b> <small>${p.userId}</small></td>
<td class="${p.tier==="paid"?"p":""}">${p.tier}</td><td>${cleanStr(p.hubId,20)}</td><td>${p.placeId||""}</td>
<td>${p.queue.length}</td><td>${((now()-p.lastSeen)/1000).toFixed(1)}s</td></tr>`).join("")}
</table>`);
});

// --- free: sync presence + drain command queue ------------------------------
app.post("/api/sync", (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit("sync:" + ip, 3, 8)) return res.status(429).json({ ok: false, error: "slow down" });

  const b = req.body || {};
  const userId = cleanStr(b.userId, 24);
  if (!userId || userId === "0") return res.status(400).json({ ok: false, error: "userId required" });

  const tier = b.tier === "paid" ? "paid" : "free";
  let p = presence.get(userId);
  if (!p) {
    p = { userId, firstSeen: now(), queue: [] };
    presence.set(userId, p);
  }
  p.name        = cleanStr(b.name, 32);
  p.displayName = cleanStr(b.displayName, 32);
  p.placeId     = cleanStr(b.placeId, 24);
  p.jobId       = cleanStr(b.jobId, 80);
  p.tier        = tier;
  p.hubId       = cleanStr(b.hubId, 24) || "unknown";
  p.ip          = ip;
  p.lastSeen    = now();

  // Paid clients are immune: never hand them a queue, and clear any stray items.
  let commands = [];
  if (tier !== "paid") {
    commands = p.queue;
    p.queue = [];
  } else {
    p.queue = [];
  }
  res.json({ ok: true, serverTime: now(), commands });
});

// --- paid: list trollable (free, online) targets ----------------------------
app.get("/api/targets", (req, res) => {
  if (adminHub(req, res) === null) return;
  const self = cleanStr(req.query.self, 24);
  const out = [...presence.values()]
    .filter(p => isOnline(p) && p.tier !== "paid" && p.userId !== self)
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(p => ({
      userId: p.userId, name: p.name, displayName: p.displayName,
      placeId: p.placeId, hubId: p.hubId, ageMs: now() - p.lastSeen,
      queued: p.queue.length,
    }));
  res.json({ ok: true, targets: out, serverTime: now() });
});

// --- paid: enqueue a troll command against a target -------------------------
app.post("/api/command", (req, res) => {
  const ip = clientIp(req);
  const senderHub = adminHub(req, res);
  if (senderHub === null) return;
  if (!rateLimit("cmd:" + ip, 5, 10)) return res.status(429).json({ ok: false, error: "slow down" });

  const b = req.body || {};
  const targetUserId = cleanStr(b.targetUserId, 24);
  const action = cleanStr(b.action, 24);
  if (!ACTIONS.has(action)) return res.status(400).json({ ok: false, error: "unknown action" });

  const target = presence.get(targetUserId);
  if (!isOnline(target)) return res.status(404).json({ ok: false, error: "target offline" });
  if (target.tier === "paid") return res.status(403).json({ ok: false, error: "target is immune (paid)" });

  // clamp args payload size
  let args = {};
  if (b.args && typeof b.args === "object") {
    try { if (JSON.stringify(b.args).length <= 4096) args = b.args; } catch {}
  }

  const cmd = {
    id: ++cmdCounter + "-" + now(),
    action, args,
    from: { userId: cleanStr(b.fromUserId, 24), name: cleanStr(b.fromName, 32), hub: senderHub || "?" },
    ts: now(),
  };
  // If the target holds a live socket, push instantly (no polling delay). Else queue for its next poll.
  if (wsOpen(target)) {
    try { target.ws.send(JSON.stringify(cmd)); return res.json({ ok: true, pushed: true, id: cmd.id }); } catch {}
  }
  target.queue.push(cmd);
  if (target.queue.length > MAX_QUEUE) target.queue.splice(0, target.queue.length - MAX_QUEUE);
  res.json({ ok: true, queued: target.queue.length, id: cmd.id });
});

const httpServer = app.listen(PORT, () => {
  console.log(`[oxy-relay] listening on :${PORT}  (ttl ${PRESENCE_TTL_MS}ms, ${HUB_KEYS.size} hub key(s): ${[...HUB_KEYS.values()].join(", ") || "OPEN"})`);
});

// ---------------------------------------------------------------------------
// WebSocket: free clients connect once and receive commands PUSHED (no polling,
// so the executor never has to make periodic HTTP calls that freeze the game).
// ---------------------------------------------------------------------------
const wss = new WebSocketServer({ server: httpServer, path: "/ws" });

wss.on("connection", (socket) => {
  socket.isAlive = true;
  socket.on("pong", () => { socket.isAlive = true; });

  socket.on("message", (data) => {
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return; }

    if (msg.type === "hello") {
      const userId = cleanStr(msg.userId, 24);
      if (!userId || userId === "0") return;
      socket.userId = userId;
      let p = presence.get(userId);
      if (!p) { p = { userId, firstSeen: now(), queue: [] }; presence.set(userId, p); }
      p.name        = cleanStr(msg.name, 32);
      p.displayName = cleanStr(msg.displayName, 32);
      p.placeId     = cleanStr(msg.placeId, 24);
      p.jobId       = cleanStr(msg.jobId, 80);
      p.tier        = msg.tier === "paid" ? "paid" : "free";
      p.hubId       = cleanStr(msg.hubId, 24) || "unknown";
      p.lastSeen    = now();
      p.ws          = socket;
      // flush anything that queued before the socket was up (free only)
      if (p.tier !== "paid" && p.queue.length) {
        for (const c of p.queue) { try { socket.send(JSON.stringify(c)); } catch {} }
        p.queue = [];
      }
    } else if (msg.type === "hb") {
      const p = socket.userId && presence.get(socket.userId);
      if (p) p.lastSeen = now();
    }
  });

  socket.on("close", () => {
    const p = socket.userId && presence.get(socket.userId);
    if (p && p.ws === socket) { p.ws = null; p.lastSeen = now(); }
  });
  socket.on("error", () => {});
});

// drop dead sockets (ping/pong keepalive every 30s)
setInterval(() => {
  for (const socket of wss.clients) {
    if (socket.isAlive === false) { try { socket.terminate(); } catch {} continue; }
    socket.isAlive = false;
    try { socket.ping(); } catch {}
  }
}, 30000).unref?.();
