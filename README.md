# oxy-relay

Cross-hub presence + troll command bus for the oxy freemium system.
One tiny Node service does two things:

1. **Relay API** — free clients sync presence & drain a command queue; paid clients list
   trollable targets and enqueue commands against them.
2. **Serves the shared client module** at `GET /client.lua` so every hub (yours + third-party)
   just needs one loader line and always runs the latest version.

## How the pieces fit

| Build            | Embeds `/client.lua` as | Can be trolled? | Can troll? |
|------------------|-------------------------|-----------------|------------|
| oxy **free**     | `tier="free"`           | ✅ yes          | ❌ no      |
| oxy **paid**     | `tier="paid"` + token   | ❌ immune       | ✅ yes     |
| third-party hub  | `tier="free"`           | ✅ yes          | ❌ no      |

Immunity is enforced twice: the server refuses to queue a command against a `paid` presence,
and the client receiver no-ops unless `tier=="free"`. Sending requires `ADMIN_TOKEN`, which only
lives inside the Luarmor-gated paid script — so free users can never send.

## Deploy to Railway

```bash
# from this folder
railway login
railway init            # create a new project (or `railway link` an existing one)
railway up              # deploys; build = nixpacks, start = npm start
```

Then in the Railway dashboard → your service → **Variables**:

| Variable          | Value                                             |
|-------------------|---------------------------------------------------|
| `ADMIN_TOKEN`     | a long random string (paste the SAME value into the paid Lua script) |
| `PRESENCE_TTL_MS` | `15000` (optional)                                |
| `MAX_QUEUE`       | `20` (optional)                                   |

Railway gives the service a public domain (Settings → Networking → Generate Domain), e.g.
`https://oxy-relay-production.up.railway.app`. That URL is your `backendUrl`.

Open it in a browser to see the live dashboard (online / free / paid / per-hub counts).

## Loader lines

**Free hub (yours or a third party):**
```lua
loadstring(game:HttpGet("https://YOUR.up.railway.app/client.lua"))().start({
    backendUrl = "https://YOUR.up.railway.app",
    tier       = "free",
    hubId      = "oxy",     -- or the third party's tag
})
```

**Paid hub:** same, but `tier="paid"` and `adminToken="<the ADMIN_TOKEN>"`. The paid hub's Admin
Panel calls `shared.OxyNet.getTargets()` and `shared.OxyNet.sendCommand(userId, action, args)`.

## Local dev / testing

```bash
npm install
ADMIN_TOKEN=test npm start      # http://localhost:8080
```
Roblox executors can reach `http://localhost:8080` on the same machine, so you can end-to-end
test before deploying. `GET /health` → `{ok:true}`.

## API

| Method | Path           | Auth        | Purpose                                  |
|--------|----------------|-------------|------------------------------------------|
| POST   | `/api/sync`    | none        | free/paid presence heartbeat + drain queue |
| GET    | `/api/targets` | `x-oxy-token` | list online free targets               |
| POST   | `/api/command` | `x-oxy-token` | enqueue a command for a target         |
| GET    | `/client.lua`  | none        | the shared client module                 |
| GET    | `/`            | none        | live dashboard                           |
