# Prompt for Claude Code on the Mac mini

Copy everything below the line into a fresh Claude Code session running on
the Mac mini. The model has zero prior context — it needs the goal, the
relevant facts about your setup, and what "done" looks like.

---

I'm deploying `pacerunner-server`, a TypeScript service that ingests
workout data from my iPhone and exposes it over MCP to chat sessions.
It's all checked in to the `running-tools` repo I just pulled. Here's
what I need you to help me do, in order:

## What's already done
- DNS: `pacerunner.brintontech.com` resolves to my home router's public IP.
- Router: ports 80 and 443 are forwarded TCP to this Mac mini's LAN IP.
- Repo: latest commit (`5271d5f` or newer) of branch
  `001-pace-runner-mvp` is checked out. The server lives under
  `pacerunner-server/`.

## What you should help me do
1. **Confirm Docker is installed and running** on the mini (`docker version`).
   If it isn't, stop and tell me which install path I should use (Docker
   Desktop vs Colima vs OrbStack — I'll choose).

2. **Update the Caddyfile** at `pacerunner-server/Caddyfile`:
   replace the site address `running.brintontech.com` with
   `pacerunner.brintontech.com`. Leave everything else.

3. **Bring the stack up**:
   ```
   cd pacerunner-server
   docker compose up -d --build
   docker compose logs -f
   ```
   The `pacerunner-server` container should log "listening on :8080" and
   Caddy should report a successful Let's Encrypt cert issuance for
   `pacerunner.brintontech.com`. Tail until you see both, then proceed.

4. **Verify HTTPS from outside**: have me run
   `curl -v https://pacerunner.brintontech.com/health` from a non-home
   network (LTE-tethered laptop) and report the result. Expect
   `{"ok":true}` and a valid cert chain.

5. **Bootstrap my user account and tokens** via the admin CLI inside
   the running container:
   ```
   docker compose exec pacerunner-server node dist/admin.js create-user --name "Chris" --email cbrinton@mmplatformco.com
   docker compose exec pacerunner-server node dist/admin.js create-token --user-id 1 --scope ingest --label "iPhone"
   docker compose exec pacerunner-server node dist/admin.js create-token --user-id 1 --scope mcp --label "claude-code"
   docker compose exec pacerunner-server node dist/admin.js create-token --user-id 1 --scope mcp --label "running-coach"
   ```
   The tokens print exactly once each; save them somewhere I can copy.
   I'll need the ingest token for the iPhone and one MCP token per chat
   session.

6. **Smoke-test the MCP path end-to-end** with the `claude-code` token:
   ```
   curl -X POST https://pacerunner.brintontech.com/mcp \
     -H "Authorization: Bearer <claude-code-mcp-token>" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
   Expect a JSON-RPC response listing six tools: `list_workouts`,
   `get_workout`, `get_pacerunner_log`, `get_weather`,
   `list_configurations`, `get_settings`. If you see them, the server
   is live and we're done with this phase.

## Important context
- **There are no shared bearer tokens.** Auth is per-user in SQLite,
  managed by `npm run admin` (or `node dist/admin.js` inside the
  container). The previous `INGEST_TOKEN`/`MCP_TOKEN` env-var design was
  superseded — don't add those env vars back.
- **Data lives in `pacerunner-server/data/`** (mounted as `/data` in the
  container). SQLite DB + per-user `files/<user_id>/{gpx,logs}/` plus
  Caddy ACME state. Don't `rm` this.
- **Open-Meteo weather decoration** runs asynchronously after each
  outdoor workout ingest. No API key. If you see weather errors in
  logs they're non-fatal — the workout itself still ingests fine.
- **Indoor workouts skip weather** (HKMetadataKeyIndoorWorkout=1).
- The full architecture and operational notes are in
  `pacerunner-server/README.md` — read that before making changes
  beyond what I've asked for above.

## Things I don't want you to do without asking first
- Don't open the firewall or change `pf` / network settings on the mini
  beyond what's needed for Docker.
- Don't add reverse proxies or load balancers beyond the Caddy that's
  already in the compose file.
- Don't modify `running-tools/pace-runner/**` — those are the iOS /
  watchOS sources and have nothing to do with this deploy.

When all six steps above are green, summarize: what's running, where the
tokens are saved, and what the iPhone-side hookup looks like next.

## What's next (after deploy is green)
The iPhone push side hasn't been built yet. We'll add a
`HealthKitPublisher.swift` that auto-posts each workout to
`https://pacerunner.brintontech.com/ingest/workout` with the ingest
token, plus a "Publish All" button for backfill. That work will happen
on the dev machine, not the mini — you don't need to set anything up
for it.
