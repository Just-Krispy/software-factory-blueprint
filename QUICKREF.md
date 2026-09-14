# Quick reference

One page for the software factory. Full guide: [`README.md`](README.md).

## Components and where they live

Paths are examples — substitute your own, consistently.

| Layer | Path / endpoint | Verify with |
|---|---|---|
| Honcho API | `http://127.0.0.1:8000` | `curl -s localhost:8000/health` |
| Honcho MCP | `http://127.0.0.1:8790` | `curl -s localhost:8790/.well-known/oauth-protected-resource` |
| Honcho checkout | `~/honcho-memory` (compose project) | `docker compose ps` |
| Herdr session | `herdr --session factory` | `herdr --session factory workspace list` |
| Factory repo | `~/workspaces/agentic-dev` | `just --list` |
| Engine | `~/workspaces/agentic-dev/adws/` | `just demo` |
| Trace DB | `adws/adw_data/sssf.db` (WAL) | `just sessions` |
| Git memory | `~/shared-memory` | `systemctl --user list-timers \| grep shared` |
| CLI | `honcho` | `honcho doctor` |

## Honcho endpoints actually used

| Method | Path | Notes |
|---|---|---|
| `GET` | `/health` | `{"status":"ok"}` |
| `POST` | `/v3/workspaces` | get-or-create; body `{"id":"<ws>"}` |
| `POST` | `/v3/workspaces/list` | empty JSON body |
| `POST` | `/v3/workspaces/<ws>/sessions/list` | empty body |
| `POST` | `/v3/workspaces/<ws>/peers/list` | empty body |
| `POST` | `/v3/workspaces/<ws>/conclusions/list` | empty body; filters via `filters` |
| `POST` | `/v3/workspaces/<ws>/peers/<p>/chat` | `{"query":"…"}` → dialectic answer |
| `GET` | `/v3/workspaces/<ws>/queue/status` | **GET** — POST returns 405 |
| `DELETE` | `/v3/workspaces/<ws>/sessions/<s>` | `202`, async |
| `DELETE` | `/v3/workspaces/<ws>` | `202`; sessions must go first |
| `POST` | `/v3/keys` | mint scoped key (admin, auth on) |

## Env knobs that matter

| Variable | Default | Why you care |
|---|---|---|
| `LLM_OPENAI_API_KEY` | — | every module defaults to the openai transport |
| `LLM_OPENAI_BASE_URL` | OpenAI | point at OpenRouter/vLLM/MLX |
| `DERIVER_MODEL_CONFIG__MODEL` | `gpt-5.4-mini` | must be valid for *your* provider |
| `DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE` | — | `json_object` for providers without json_schema |
| `SUMMARY_MODEL_CONFIG__MODEL` | `gpt-5.4-mini` | same rule |
| `DIALECTIC_LEVELS__{minimal,low,medium,high,max}__MODEL_CONFIG__MODEL` | `gpt-5.4-mini` | all five must match one provider |
| `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL` | OpenAI | without it, non-OpenAI keys 401 on search |
| `EMBED_MESSAGES` | `true` | `false` = no message embedding (cheaper) and message search degrades to full-text |
| `DERIVER_FLUSH_ENABLED` | `false` | `true` = process each unit immediately (testing) |
| `DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS` | `1800` | how long a small unit waits before flushing |
| `DERIVER_WORKERS` | `1` | raise before enabling dream |
| `DREAM_ENABLED` | `true` (code default) | expensive inductive pass — set `false` on a first install |
| `AUTH_USE_AUTH` | `false` | must be `true` before exposure |
| `AUTH_JWT_SECRET` | — | required when auth is on |
| `SENTRY_ENABLED` | `false` | telemetry off |

## Factory commands

```bash
# memory
cd ~/honcho-memory
docker compose up -d --build          # api deriver database redis (mcp optional)
docker compose ps
docker compose logs -f api deriver

# ask the memory (dialectic)
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"query":"what did we decide about gates?"}' \
  http://127.0.0.1:8000/v3/workspaces/factory-brain/peers/team-coder/chat

# engine
cd ~/workspaces/agentic-dev
just demo                             # read-only smoke test
just sessions | just phases <id> | just procs <id> | just tail <id>
just prompt "…" | just scout "…" | just plan "…"
just sdlc "…" | just simple-sdlc "…" | just sdlc-plus "…"
./sssf-run.py adw_simple_sdlc "…" --pr

# panes
herdr --session factory workspace list
herdr --session factory pane list
herdr --session factory agent list

# git memory
cd ~/shared-memory && git pull --rebase && git add -A && git commit -m "…" && git push

# CLI
uv tool install honcho-cli
honcho init && honcho doctor
honcho workspace list | honcho peer list | honcho workspace inspect
```

## SDK one-liners

```python
from honcho import Honcho
h = Honcho(workspace_id="factory-brain", base_url="http://127.0.0.1:8000")
alice = h.peer("alice"); s = h.session("s1")
s.add_peers([alice])
s.add_messages([alice.message("prefers short answers")])
print(h.peer("alice").chat("what does alice prefer?"))   # str
print(len(h.peer("alice").conclusions.list()))
```

## Ports

| Port | Service | Bind |
|---|---|---|
| 8000 | Honcho API | `127.0.0.1` |
| 8790 | Honcho MCP | `127.0.0.1` |
| 5432 | Postgres (example compose) | `127.0.0.1` |
| 6379 | Redis (example compose) | `127.0.0.1` |
| 4601 / 4600 | trace visualizer (`just obs`; needs the private app) | localhost |

## Health sequence (fastest triage)

```bash
curl -s http://127.0.0.1:8000/health                              # 1. service up?
docker compose ps                                                 # 2. healthy?
curl -s "http://127.0.0.1:8000/v3/workspaces/<ws>/queue/status"   # 3. draining?
docker compose logs --tail=20 deriver | grep observation_count    # 4. deriving?
curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:8000/v3/workspaces/<ws>/conclusions/list"     # 5. memory there?
```

## Sharing the memory with another machine (tailnet)

```bash
# on the factory host — keep containers on loopback, proxy to the tailnet IP
cp configs/tailnet-proxy.service ~/.config/systemd/user/honcho-tailnet-api.service
sed -i 's/%PORT%/8000/g; s/%NAME%/api/g' ~/.config/systemd/user/honcho-tailnet-api.service
systemctl --user daemon-reload && systemctl --user enable --now honcho-tailnet-api.service

# from any tailnet device
curl -s http://<node>.<tailnet>.ts.net:8000/health
```

- Docker-published ports do **not** traverse the tailscale interface — bind
  containers to `127.0.0.1` and forward with the unit above (or `tailscale serve`
  if you have root).
- Collaborator access = Tailscale node share / ACL (admin console).
- **Auth is required before any non-loopback exposure** (§6.4): `AUTH_USE_AUTH=true`
  + `AUTH_JWT_SECRET`, then a scoped token per consumer. The monitor reads
  `~/.honcho-token` (mode 600) on the factory host; clients send
  `Authorization: Bearer …`.
- Mint with `generate_jwt.py --workspace <ws>` and **no `--expires`** — expiring
  tokens are broken in 3.0.11. Never hand out the admin token.

## Gotchas in one line each

- `queue/status` is **GET**; `sessions|peers|conclusions/list` are empty-body **POST**.
- Small messages wait up to **30 min** unless `DERIVER_FLUSH_ENABLED=true`.
- Embeddings default to **api.openai.com** — set `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL`.
- Model ids are **provider-specific** and unvalidated at startup.
- `DELETE workspace` needs its **sessions deleted first**; both return `202`.
- `docker compose up -d` creates **every** declared service — name them.
- Herdr panes survive detach; only `herdr server stop` kills them.
