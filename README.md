# The Software Factory — setup blueprint

A working blueprint for a **super simple software factory**: a self-hosted memory
layer (Honcho) + a terminal workspace manager for coding agents (Herdr) + a
deterministic Python workflow engine (SSSF/ADW) that drives agent CLIs through
plan → build → test → review → commit.

Every command below has been run against a live install. The failure modes in §9
are the ones that actually cost time — including two that silently break the
memory read path.

- One-page cheat sheet: [`QUICKREF.md`](QUICKREF.md)
- Hand the install to a coding agent: [`SETUP-PROMPT.md`](SETUP-PROMPT.md)
- Copy-ready configs: [`configs/`](configs/)

---

## 1. What you are building

```
                 ┌─────────────────── factory host ───────────────────┐
  your laptop    │                                                     │
  ┌─────────┐    │  herdr server ── session "factory"                  │
  │ monitor │SSH │    workspace: factory                          │
  │  (TUI)  │───►│      ├── pane: orchestrator  (pi agent)             │
  └─────────┘    │      ├── pane: reviewer      (pi agent)             │
                 │      ├── pane: team-coder    (pi agent)             │
                 │      └── pane: team-builder  (pi agent)             │
                 │                                                     │
                 │  ADW engine (adws/*.py + just recipes)              │
                 │    ├── mints a session, runs agent CLIs, gates it   │
                 │    └── traces every step to sqlite sssf.db          │
                 │                                                     │
                 │  Honcho memory stack (docker compose)               │
                 │    api :8000 ── deriver ── postgres(pgvector)       │
                 │                          └ redis                  │
                 │    mcp :8790 (optional)                             │
                 │                                                     │
                 │  shared-memory (git store, canonical, timer sync)   │
                 └─────────────────────────────────────────────────────┘
```

Four independent layers — each useful alone. Install in order, verifying each
before starting the next.

| # | Layer | What it gives you | Minimum to run |
|---|-------|-------------------|----------------|
| 1 | **Honcho** | durable cross-session memory, LLM-extracted conclusions, "ask the memory" endpoint | Docker + one LLM key |
| 2 | **Herdr** | persistent agent panes that survive detach/SSH drop, agent-state sidebar | one binary |
| 3 | **SSSF / ADW** | the engine: reproducible agent workflows with gates and tracing | Python 3.11+, uv, just, an agent CLI, a model key |
| 4 | **Sidecars** | git-backed shared memory, Obsidian→Honcho bridge, monitor TUI | optional |

### Component sources

| Component | Source | Version used |
|---|---|---|
| Honcho server / SDKs / CLI / MCP | <https://github.com/plastic-labs/honcho> (AGPL-3.0) | server `3.0.11`, API `v3`; TS SDK `@honcho-ai/sdk` 2.4.0; Python SDK `honcho-ai`; `honcho-cli` 0.1.2 |
| Herdr | <https://herdr.dev> | `0.8.2` |
| SSSF / ADW engine | private repo; the starter is stamped by the project's own `install.py` | ADW scripts + `justfile` |
| Agent CLI (`pi`) | installed via `mise` | `0.85.0` |
| Monitor TUI | optional sidecar (single-file Textual app, read-only over SSH) | Textual 8.2.8 |

---

## 2. Prerequisites (factory host)

Linux or macOS, Docker Engine + Compose v2.

```bash
docker --version && docker compose version   # Compose v2 required
git --version
python3 --version                            # 3.11+ (Honcho runs 3.13 in-container)
node --version                               # 20+ (MCP worker, trace UI)
sqlite3 --version && jq --version            # used by the trace queries and examples
```

Later layers also want `bun` (the trace UI) and systemd user services. The
sidecar sync in §6.1 is **systemd-only** — on macOS, run that script from
`launchd` or cron instead.

Toolchain via [mise](https://mise.jdx.dev) or your package manager:

```bash
mise use -g node@latest uv@latest just@latest gh@latest pi@latest
uv --version && just --version && pi --version
```

Optional:

```bash
uv tool install honcho-cli                                     # shell inspection
curl -fsSL https://herdr.dev/install.sh | sh && herdr --version
```

---

## 3. Layer 1 — Honcho memory

### 3.1 Get the server

```bash
git clone https://github.com/plastic-labs/honcho.git ~/honcho-memory
cd ~/honcho-memory
git rev-parse --short HEAD      # record it — upstream ships no release pinning
cp docker-compose.yml.example docker-compose.yml
cp .env.template .env
```

The example compose brings up four services, all published on loopback:

| Service | Image / build | Loopback port | Role |
|---|---|---|---|
| `api` | local `Dockerfile` | `127.0.0.1:8000` | FastAPI surface, `/health`, `/v3/*` |
| `deriver` | same image, `python -m src.deriver` | — | queue worker: messages → observations → conclusions |
| `database` | `pgvector/pgvector:pg15` | `127.0.0.1:5432` | storage + vectors |
| `redis` | `redis:8.2` | `127.0.0.1:6379` | deriver queue + cache |

The API entrypoint runs `scripts/provision_db.py` (migrations) before starting
FastAPI, so schema upgrades happen on `docker compose up --build`.

### 3.2 Configure `.env`

Models are addressed as **transport + model (+ optional base URL)**. Transports:
`openai`, `anthropic`, `gemini`. The **openai transport means "any
OpenAI-compatible endpoint"** — OpenAI, OpenRouter, vLLM, LM Studio, an MLX
server. Defaults route deriver, summary, and all five dialectic levels to the
openai transport, so one OpenAI-compatible key is the least-config path.

Minimal working config (OpenAI direct):

```env
LLM_OPENAI_API_KEY=<your key>
```

Minimal working config (OpenRouter):

```env
LLM_OPENAI_API_KEY=<your key>
LLM_OPENAI_BASE_URL=https://openrouter.ai/api/v1

# Model ids are provider-specific: `gpt-5.4-mini` is an OpenAI id, while
# OpenRouter wants `provider/model`. Set every module explicitly so nothing
# falls back to a default id your provider rejects.
DERIVER_MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object   # providers without json_schema
SUMMARY_MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL=deepseek/deepseek-v4-flash-0731
```

[`configs/honcho.env.example`](configs/honcho.env.example) is the full annotated
reference, including a local-model variant.

**Embeddings.** Semantic search, observation dedup, and vector retrieval embed
text through the `EMBEDDING_*` settings — whose transport defaults to openai with
**no base URL**, so they hit `api.openai.com` even when your chat traffic goes to
another provider, and 401 with a non-OpenAI key:

```env
EMBEDDING_MODEL_CONFIG__TRANSPORT=openai
EMBEDDING_MODEL_CONFIG__MODEL=openai/text-embedding-3-small
EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=https://openrouter.ai/api/v1
```

`EMBED_MESSAGES=false` keeps message-body embedding off (cheaper); embeddings are
then used for search queries and dedup only. `EMBEDDING_VECTOR_DIMENSIONS` must match the
embedding model (1536 for `text-embedding-3-small`).

**Deriver batching — the setting that confuses everyone.** By default the deriver
does *not* process a small message immediately. Work units accumulate until they
cross `DERIVER_REPRESENTATION_BATCH_WORK_UNIT_TARGET_TOKENS`, or until the oldest pending
unit is older than `DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS` (default `1800` = 30
minutes). A single test message therefore sits `pending` for up to half an hour
and it looks like memory is broken.

```env
# Development / verification: process each work unit immediately.
# Production: leave false — batching means fewer, cheaper LLM calls.
DERIVER_FLUSH_ENABLED=true
```

**Keep disabled on a first install:** `DREAM_ENABLED=false` (the expensive
inductive pass), `SENTRY_ENABLED=false`, `AUTH_USE_AUTH=false` (§7).

### 3.3 Start and verify

```bash
docker compose up -d --build
docker compose ps                             # api must report (healthy)
curl -s http://127.0.0.1:8000/health          # {"status":"ok"}
docker compose logs --tail=30 deriver         # "Running main loop"
```

Name services (`docker compose up -d api deriver`) when you do not want every
declared service created at once.

### 3.4 Prove the memory loop works

This acceptance test catches every wiring mistake. Run it with
`DERIVER_FLUSH_ENABLED=true`, otherwise step 3 takes up to 30 minutes.

```bash
WS=my-brain

# 1. get-or-create a workspace  (POST — not a GET)
curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"id\":\"$WS\"}" http://127.0.0.1:8000/v3/workspaces

# 2. seed a message through the SDK
python3 -m venv ~/.honcho-venv && ~/.honcho-venv/bin/pip -q install honcho-ai
~/.honcho-venv/bin/python - <<PY
from honcho import Honcho
h = Honcho(workspace_id="$WS", base_url="http://127.0.0.1:8000")
alice = h.peer("alice"); s = h.session("first-session")
s.add_peers([alice])
s.add_messages([alice.message("I prefer dark mode, short answers, and no emojis.")])
print("seeded")
PY

# 3. queue drains  (GET — POST returns 405)
curl -s "http://127.0.0.1:8000/v3/workspaces/$WS/queue/status"

# 4. the derived memory  (POST, empty body)
curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:8000/v3/workspaces/$WS/conclusions/list"

# 5. "ask the memory" (dialectic) — must answer in natural language
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"query":"What does alice prefer?"}' \
  "http://127.0.0.1:8000/v3/workspaces/$WS/peers/alice/chat"
```

Observed on a healthy install:

```
(queue)  {"total_work_units":1,"completed_work_units":1,"in_progress_work_units":0,"pending_work_units":0}
(deriver) PERFORMANCE minimal_deriver_5_alice | llm_call_duration=3905ms |
          total_processing_time=6065ms | observation_count=3
(concl.)  {"total":3,"page":1,"size":50,"pages":1,"items":[
           {"content":"alice prefers dark mode","observer_id":"alice",
            "observed_id":"alice","session_id":"first-session",
            "level":"explicit"}, …]}
```

Pass criteria: the queue completes, step 4 returns `total >= 1` (the exact
count depends on the model; three is typical for that sentence) with
`level: "explicit"`, and step 5 returns prose — **not**
`{"detail":"An unexpected error occurred"}`. If step 4 is empty, check §9 rows 1–2.

Cleanup — sessions before the workspace:

```bash
curl -s -X DELETE "http://127.0.0.1:8000/v3/workspaces/$WS/sessions/first-session"
curl -s -X DELETE "http://127.0.0.1:8000/v3/workspaces/$WS"     # 202, async
```

### 3.5 SDK snippets

```python
# Python — honcho-ai
from honcho import Honcho
h = Honcho(workspace_id="my-brain", base_url="http://127.0.0.1:8000")
peer = h.peer("team-coder")
print(peer.chat("What did we decide about the build gates?"))   # returns str
print(len(peer.conclusions.list()))
```

```ts
// TypeScript — @honcho-ai/sdk
import { Honcho } from "@honcho-ai/sdk";
const honcho = new Honcho({ baseURL: "http://127.0.0.1:8000", workspaceId: "my-brain" });
const peer = await honcho.peer("team-coder");
const session = await honcho.session("s1");
await session.addPeers([peer]);
await session.addMessages([{ peerId: "team-coder", content: "gate 3 passed" }]);
```

---

## 4. Layer 2 — Herdr (persistent agent panes)

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

That is a first-party installer, but read it before piping it into a shell (or
install via Homebrew/mise/Nix — see <https://herdr.dev/docs/install/>). Version in
use here: `0.8.2`; `herdr update` follows the channel you choose.

Once the factory repo exists (§5), `cd ~/workspaces/agentic-dev && herdr`
launches or attaches the default session.

Concept model, in this order: **session** (background server namespace) →
**workspace** (one per repo/task) → **tab** (layout) → **pane** (a real terminal
that survives detach) → **agent** (a detected process:
`working|blocked|done|idle|unknown`).

The factory shape:

```bash
herdr --session factory workspace list
# {"workspaces":[{"label":"factory","workspace_id":"w2","tab_count":5,"pane_count":5}]}
herdr --session factory pane list      # panes carry agent, agent_session, status
```

Nothing creates that layout automatically. Build it once, by hand:

```bash
herdr --session factory                       # create/attach the session
# inside: create a workspace per project, a tab per concern, a pane per agent
herdr integration install pi                  # native session restore + state
# then start the agent in each pane, e.g. `pi` in the pane named team-coder
herdr --session factory workspace create --label factory   # if scripting it
```

Each pane runs the `pi` coding agent under a stable identity (`team-coder`,
`team-builder`, `reviewer`, `orchestrator`), and those identities are reused as
Honcho peer ids — so a pane and its memory are named alike.

Remote use is the point: run `herdr` on the factory host over SSH (tmux-style),
or attach a thin local client with `herdr --remote <host>`. Detaching
(`prefix+q`) or dropping SSH leaves every agent running. Teach an agent inside a
pane to drive Herdr itself:

```bash
npx skills add herdrdev/herdr --skill herdr -g
```

Reference: <https://herdr.dev/agent-guide.md> · CLI:
<https://herdr.dev/docs/cli-reference/>

---

## 5. Layer 3 — SSSF / ADW (the factory engine)

A deterministic Python driver for agent CLIs. It owns control flow; the model
only fills in the thinking steps.

**Obtaining it.** The engine used here is a private repo — this section documents
its shape rather than shipping it. To reproduce it you need, at minimum: the ADW
scripts listed below, `adw_modules/` (runner, sessions, git, prompts, permissions,
quality), a `sssf.config.yaml` roster, and a `justfile` entry point.
[`configs/engine/`](configs/engine/) contains a roster and a justfile skeleton to
start from; the behavioural contract that matters is in §5.4-§5.6 (trace every
step to sqlite, gate writes through `permissions.py`, one envelope per agent).

### 5.1 Layout

```
~/workspaces/agentic-dev/          # factory repo (also the agents' cwd)
├── justfile                       # entry points: demo, sdlc, sdlc-plus, sandbox…
├── adws/                          # THE ENGINE
│   ├── adw_prompt.py              # one agent, one prompt
│   ├── adw_scout.py               # read-only recon
│   ├── adw_plan.py                # planner only
│   ├── adw_plan_build.py          # plan → build → commit
│   ├── adw_plan_build_test.py     # + test
│   ├── adw_simple_sdlc.py         # plan → build → test → review → docs
│   ├── adw_sdlc_plus.py           # + audit → changelog → PR
│   ├── adw_quality.py             # deterministic quality gates
│   ├── adw_modules/               # runner, sessions, git, prompts, permissions
│   └── adw_sssf_config/
│       └── sssf.config.yaml       # THE ROSTER (agents, models, tools, protected files)
├── scripts/                       # PR / audit / changelog / dispatch helpers
├── specs/                         # planner output (writable by the planner only)
├── .worktrees/                    # isolated checkouts for sandboxed runs
├── adws/adw_data/
│   ├── sssf.db                    # sqlite trace: sessions, phases, processes, events
│   ├── prompt_engineering/        # per-agent system + user prompt templates
│   └── sessions/<adw_id>/         # per-run envelopes + agent transcripts
├── sssf-run.py                    # branch-isolated run wrapper (--pr to open one)
└── sssf-sandbox.sh                # sandbox create/list/cleanup
```

### 5.2 The roster

`adws/adw_sssf_config/sssf.config.yaml` declares each agent as `provider/model`
with a purpose, a tool allowlist, and a write scope. A working roster (models
illustrative — the `openrouter/` prefix is part of the id, and §5.3 explains why):

| Agent | Model | Thinking | Writes | Purpose |
|---|---|---|---|---|
| planner | `openrouter/deepseek/deepseek-v4-pro` | high | `specs/` | turn a request into a plan the builder can execute without questions |
| coder | `openrouter/~z-ai/glm-flash-latest` | medium | `src/`, `tests/` | primary implementer |
| builder | `openrouter/deepseek/deepseek-v4-flash-0731` | medium | repo (gated) | implement the plan exactly, report every changed file |
| scout | `openrouter/deepseek/deepseek-v4-flash-0731` | low | — | find and report where things live; change nothing |
| reviewer | `openrouter/deepseek/deepseek-v4-pro` | high | — | confirm what was built is what was asked; change nothing |
| documenter | `openrouter/deepseek/deepseek-v4-flash-0731` | low | `docs/`, `*.md` | write up the change from the diff |

`protected_files` (the engine, the roster, the ADW scripts) is enforced by the
permission gate in `adw_modules/permissions.py` — agents cannot edit their own
driver.

**Model ids are provider-specific, and nothing validates them at startup.** A
roster entry naming an unknown id fails when that agent runs — minutes into a
workflow. Check before the first real run:

```bash
curl -s https://openrouter.ai/api/v1/models | jq -r '.data[].id' \
  | grep -x 'deepseek/deepseek-v4-flash-0731'
```

### 5.3 Provider keys

`.env` at the factory root, loaded automatically (`set dotenv-load` in the
`justfile`). The **provider half** of each model id selects the key:

```env
OPENROUTER_API_KEY=<your key>
# optional
PI_PATH=pi
ENGINEER_NAME=                 # lane label; defaults to git user.name
HONCHO_ENVIRONMENT_URL=http://127.0.0.1:8000
HONCHO_API_KEY=                # only meaningful when AUTH_USE_AUTH=true
```

See [`configs/factory.env.example`](configs/factory.env.example). `HONCHO_*` is
read by the agents and the bridge, not by the ADW engine itself.

### 5.4 First run

```bash
cd ~/workspaces/agentic-dev
just --list
just demo          # two cheap READ-ONLY runs: one prompt, one scout
just sessions      # last 10 runs: id, status, request, tokens, cost
just obs           # optional trace UI on http://localhost:4601 (needs bun)
```

`just demo` is the smoke test: config validated, session minted, agent ran,
envelope parsed, gates checked, trace written — and nothing in your repo changed.

### 5.5 Real workflows

```bash
just prompt      "summarize this repo"
just scout       "where is auth handled"
just plan        "add a /health endpoint"
just sdlc        "add a /health endpoint"      # plan → build → test → commit
just simple-sdlc "add a /health endpoint"      # + review + docs
just sdlc-plus   "add a /health endpoint"      # + audit + changelog + PR

# isolated branch + git worktree, optional PR
./sssf-run.py adw_simple_sdlc "Add a /health endpoint" --pr

# named sandboxes
./sssf-sandbox.sh create demo && ./sssf-sandbox.sh list
```

### 5.6 Observability

The sqlite trace is the source of truth for what happened, in WAL mode — safe to
poll while a run is in flight.

```bash
just phases <adw_id>   # seq, name, kind, owner, status, attempt
just procs  <adw_id>   # still-running processes with pids
just tail   <adw_id>   # newest events
sqlite3 adws/adw_data/sssf.db "select status, count(*) from sessions group by status;"
```

Optional monitor: a read-only Textual TUI that SSHes to the factory host and
renders five panels — agents (`/proc` scan), pipeline queue (`sssf.db`), Honcho
health + sessions/peers/conclusions, Herdr workspace/tab/pane state, and logs
(byte-offset tail with rotation detection). It never writes to the remote and
sanitizes every string it renders.

---

## 6. Layer 4 — Memory sidecars

### 6.1 `shared-memory` — git-backed canonical store

Deliberately *not* a vector store: markdown, one fact per file, git as the source
of truth, so any harness reads and writes it with no SDK, and every change is
diffable and mergeable. Complements Honcho rather than replacing it: Honcho holds
derived, queryable memory; this holds intentional, human-readable notes.

```
~/shared-memory/
├── facts/           # durable, verified facts (one per file)
├── decisions/       # ADR-style: decisions/YYYY-MM-DD-<slug>.md
├── context/         # standing context: environment, infra, conventions
└── agents/<name>/   # per-agent namespace: pi/, hermes/, openclaw/, …
```

Fact format:

```markdown
---
source: pi
verified: true
added: 2026-09-14
---
# Honcho workspace name

The factory memory workspace is `factory-brain`; peers are named after agent
roles (team-coder, team-builder, reviewer, orchestrator).
```

Sync on every host with a systemd user timer (10 min) running
`shared-memory-sync.sh` — vendored at
[`configs/shared-memory-sync.sh`](configs/shared-memory-sync.sh): pull
`--rebase --autostash` → commit if dirty → push → log the revision.

```bash
install -m 0755 configs/shared-memory-sync.sh ~/.local/bin/shared-memory-sync.sh
systemctl --user enable --now shared-memory-sync.timer
systemctl --user list-timers | grep shared
```

### 6.2 Obsidian → Honcho bridge

Human-readable notes stay in Obsidian (source of truth for prose); explicitly
opted-in notes are mirrored into Honcho for semantic recall. Opt in with
frontmatter — the bridge never edits the vault:

```yaml
---
honcho_sync: true
---
```

```bash
export OBSIDIAN_VAULT="/absolute/path/to/vault"
export HONCHO_URL="http://127.0.0.1:8000"
export FORGE_FLOW_HONCHO_PEERS="team-coder,team-builder"

./bin/obsidian-honcho scan      # local, read-only
./bin/obsidian-honcho sync      # uploads changed notes as revisions + sha256
./bin/obsidian-honcho status
```

Deleted notes are never deleted from Honcho automatically; `sync --all` is the
deliberate "import everything" switch. Keep secrets and private folders out of
the opt-in set. `HONCHO_URL` and the peer list are shell settings, deliberately
not loaded from `.env`.

### 6.3 Honcho MCP server

An MCP wrapper over the Honcho HTTP API, so any MCP client (Claude Desktop,
Cursor, an agent harness) can read and write memory as tools. Upstream ships a
Cloudflare-Worker config; for a local stack you need a plain container, and the
two files that make it build are **not in upstream**:

```
configs/mcp/Dockerfile.local
configs/mcp/wrangler.local.toml
```

[`configs/mcp/compose-snippet.yml`](configs/mcp/compose-snippet.yml) is the
drop-in service block. Append it to `docker-compose.yml`:

```yaml
  mcp:
    build: { context: ./mcp, dockerfile: Dockerfile.local }
    depends_on: { api: { condition: service_healthy } }
    ports: ["127.0.0.1:8790:8790"]
    restart: unless-stopped
```

```bash
docker compose up -d mcp
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8790/.well-known/oauth-protected-resource   # 200
```

Two hygiene notes before you wire a client: the image is built from `npm install`
with no lockfile and runs as root, and `bunx mcp-remote` plus the `ai` dependency
are unpinned — a reproducible deployment wants pinned versions in both. Also, the
token below lands in a client config file and in the `mcp-remote` argv; treat that
file as a secret, and prefer a client that can read the value from an environment
variable rather than pasting a long-lived token into JSON.

Client config (`claude_desktop_config.json` or equivalent):

```json
{
  "mcpServers": {
    "honcho": {
      "command": "bunx",
      "args": ["mcp-remote", "http://127.0.0.1:8790",
               "--header", "Authorization:${AUTH_HEADER}"],
      "env": { "AUTH_HEADER": "Bearer <your-key>" }
    }
  }
}
```

Optional header `X-Honcho-Workspace-ID: my-brain` selects the workspace
(default `default`). Tools exposed: workspace inspect/list/search/metadata, peer
CRUD + chat/card/context/representation, session CRUD + messages/context/clone,
conclusions list/query/create/delete, `schedule_dream`, `get_queue_status`.

### 6.4 Sharing one memory workspace with a collaborator

Two people, one memory: keep the API on loopback, join the machines on a private
mesh (Tailscale or equivalent), **turn auth on**, and mint a scoped token per
person. Auth is not optional once anything but this host can reach the API —
that is the rule in §7, and the recipe below assumes it.

```bash
# 1. On the host: enable auth, generate the signing secret
cd ~/honcho-memory
uv run python scripts/generate_jwt_secret.py        # prints the secret
```

```env
AUTH_USE_AUTH=true
AUTH_JWT_SECRET=<generated secret>
```

```bash
docker compose up -d api deriver      # both read AUTH_*
curl -s http://127.0.0.1:8000/health                                      # 200, no auth
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' http://127.0.0.1:8000/v3/workspaces/factory-brain/sessions/list # 401 without a token
```

```bash
# 2. Mint a token per consumer, scoped as tightly as the work allows
uv run python scripts/generate_jwt.py --workspace factory-brain    # collaborator
uv run python scripts/generate_jwt.py --workspace factory-brain    # your own host
uv run python scripts/generate_jwt.py --admin                      # rare, debugging only
```

**Do not pass `--expires` in this version.** Upstream 3.0.11 writes the `exp`
claim as an ISO-8601 string and verifies tokens with PyJWT, which rejects a
non-numeric `exp`:

| Token | Result |
|---|---|
| `--expires 90d` (string `exp`) | `401 {"detail":"Invalid JWT"}` |
| hand-built numeric `exp` | `500` — the server parses the claim as a date string |
| no `exp` claim | works |

Mint **without** `--expires` until that is fixed upstream and treat the token as
long-lived: store it like a password; rotate by minting a new one, or by issuing
a new `AUTH_JWT_SECRET`, which invalidates every token at once.

```bash
# 3. Hand the token to consumers on the host
install -m 600 /dev/null ~/.honcho-token
cat > ~/.honcho-token <<< '<token>'          # the monitor reads this file
# agents launched with an env file:
#   HONCHO_ENVIRONMENT_URL=http://127.0.0.1:<port>
#   HONCHO_API_KEY=<token>
```

```bash
# 4. Collaborator side: point every Honcho-aware tool at the shared host
export HONCHO_URL="http://<mesh-hostname>:8000"
export HONCHO_API_KEY="<scoped token>"
curl -s -X POST -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $HONCHO_API_KEY" -d '{"id":"factory-brain"}' \
  "$HONCHO_URL/v3/workspaces"          # get-or-create; POST, not GET
```

Workspace-scoped tokens reach only their workspace — enough for the SDK, the CLI
(`honcho init` → paste URL + key), the note bridge, and the MCP server
(`Authorization: Bearer <token>`). They cannot call `/v3/workspaces/list`
(admin-only) and get `401` on any other workspace; both are worth checking once
when you hand a token over:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{}' "$HONCHO_URL/v3/workspaces/factory-brain/sessions/list"   # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{}' "$HONCHO_URL/v3/workspaces/some-other-workspace/sessions/list"  # 401
```

Rules that keep this sane:

- **One writer per fact.** Git-backed notes merge; derived Honcho memory can
  duplicate. Give each agent and human a distinct peer id.
- **Never share the admin token.** One scoped token per person, each on their own
  device, each revocable by rotating the secret.
- **Auth off + anything but loopback = anyone who can route to the port can read,
  write, and delete the memory.** That is the whole reason step 1 exists.

#### Reaching the memory from another machine (verified recipe)

Two gotchas, both hit in practice:

1. **Docker-published ports are not reachable over the tailscale interface.**
   Publishing `-p 100.x.y.z:8000:8000` makes the port reachable from the host
   itself, but a connection from another tailnet machine times out (Tailscale's
   netfilter rules and Docker's DNAT do not compose). Plain, non-Docker listeners
   on the same address work fine — so keep containers on loopback and proxy.
2. **`tailscale serve` is the tidy fix but needs root** (`tailscale set
   --operator=<user>` must be run once by an admin, otherwise `tailscale serve`
   requires sudo). If you have root, `tailscale serve --bg 8000` publishes the
   loopback service on `https://<node>.<tailnet>.ts.net` with TLS, and is the
   preferred option.

Without root, a user-level forwarder is enough. Template in
[`configs/tailnet-proxy.service`](configs/tailnet-proxy.service):

```bash
mkdir -p ~/.config/systemd/user
cp configs/tailnet-proxy.service ~/.config/systemd/user/honcho-tailnet-api.service
sed -i 's/%PORT%/8000/g; s/%NAME%/api/g' \
  ~/.config/systemd/user/honcho-tailnet-api.service
# repeat for 8790 (MCP) if you want the MCP endpoint on the tailnet too
systemctl --user daemon-reload
systemctl --user enable --now honcho-tailnet-api.service
systemctl --user is-active honcho-tailnet-api.service        # active
```

The service binds `$(tailscale ip -4)` — the node's tailnet address, resolved at
start — and forwards to `127.0.0.1:<port>`. Nothing is exposed on the LAN.

```bash
# from any other tailnet machine
curl -s http://<node>.<tailnet>.ts.net:8000/health                 # {"status":"ok"}
curl -s -X POST -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" -d '{}' \
  http://<node>.<tailnet>.ts.net:8000/v3/workspaces/factory-brain/sessions/list
```

`/v3/workspaces/list` is admin-only — a collaborator's workspace-scoped token gets
`401` there, which is expected and not a misconfiguration.

To let a specific collaborator in, share this node with their tailnet identity
(admin console → Machines → Share), or add their device to the tailnet with an
ACL that allows the port. They then use the MagicDNS name above.

**Auth stays on** (§6.4). A tailnet limits *who can route* to the port; it does
not authorise *what they may do* — every device on the tailnet, including a node
shared with someone else or a compromised laptop, would otherwise have full read,
write, and delete access to the memory. Treat the tailnet as defence in depth,
not as the access-control layer: scoped tokens are what actually gate access, and
the monitor reads its own from `~/.honcho-token` (mode 600) on the factory host.

---

## 7. Security

The default posture is "loopback only, auth off". Fine on one host; it stops
being fine the moment anything else can reach the service.

- **Bind to `127.0.0.1`.** The Honcho API and the MCP worker both default to
  loopback. Never widen to `0.0.0.0` on a shared or LAN-exposed machine.
- **`AUTH_USE_AUTH=false` accepts any key, including none.** Before exposing the
  service anywhere (tailnet, reverse proxy, port forward), set
  `AUTH_USE_AUTH=true` and `AUTH_JWT_SECRET=<generated>` — the server refuses to
  start with auth on and no secret.
- **The example compose exposes more than the API.** It publishes Postgres on
  `127.0.0.1:5432` with `POSTGRES_HOST_AUTH_METHOD=trust` (any local user, no
  password) and Redis on `127.0.0.1:6379` with no password, and gives Postgres
  the password `postgres`. Loopback-only makes that survivable; it stops being
  survivable the moment you publish those ports or run on a shared host. Drop the
  `ports:` blocks for `database` and `redis` if you do not need host access.
- **Never commit `.env`.** Verify with `git check-ignore .env` in every repo that
  touches a key; keep `.env.template` placeholder-only. When you keep a rollback
  copy, name it `.env.backup-<timestamp>`: upstream's `.gitignore` matches
  `.env.backup*` but **not** `.env.bak-*`, so `cp .env .env.bak-$(date +%F)`
  leaves a file full of keys one `git add -A` away from being committed.
- **The MCP worker forwards any `Bearer` it is given** to the upstream API. With
  auth off that is an open proxy to the memory store.
- **Do not leave the model endpoint open.** If you serve models locally
  (MLX/vLLM/ollama), bind to loopback or set an API key — an unauthenticated
  OpenAI-compatible endpoint on your LAN lets anyone spend your GPU.
- **Scoped tokens, not shared secrets.** Per-collaborator, per-workspace,
  expiring. See §6.4.

---

## 8. Operations

**Backups.** Two volumes hold all memory: the Postgres data (`pgdata` in the
upstream example compose; `honcho-pgdata` in a renamed one) and `redis-data`.
Snapshot before every upgrade:

```bash
cd ~/honcho-memory

# Who owns the database: the example compose uses postgres/postgres, a renamed
# one may use honcho/<password>. Read it from the running container instead of
# guessing:
DB_USER=$(docker compose exec -T database printenv POSTGRES_USER | tr -d '\r')
DB_NAME=$(docker compose exec -T database printenv POSTGRES_DB | tr -d '\r')
docker compose exec -T database pg_dump -U "$DB_USER" "$DB_NAME" \
  | gzip > "honcho-$(date +%F).sql.gz"

# Volume names are project-prefixed (compose project + declared name), so list
# them rather than composing the name by hand:
docker volume ls --format '{{.Name}}' | grep -E 'pgdata|redis' | while read -r v; do
  docker run --rm -v "$v":/v -v "$PWD":/b alpine \
    tar czf "/b/${v}-$(date +%F).tgz" -C /v .
done
ls -lh ./*.tgz ./*.sql.gz
```

A tarball of an empty volume is silent, so check the sizes printed above are
non-trivial before trusting a backup.

**Upgrades.** Upstream publishes no pinned release artifact; the running version
is whatever commit you cloned. Record it, `git pull`, read `CHANGELOG.md`, then
`docker compose up -d --build` (the API entrypoint migrates). Keep a copy of
`.env` (e.g. `.env.bak-<timestamp>`) so rollback is one `cp` away.

**Health.**

```bash
curl -s http://127.0.0.1:8000/health                    # {"status":"ok"}
docker compose ps                                       # api (healthy)
curl -s "http://127.0.0.1:8000/v3/workspaces/my-brain/queue/status"   # GET
```

**Logs.** `docker compose logs -f api deriver`. The deriver logs one
`PERFORMANCE ... observation_count=N` line per processed work unit — that is the
signal memory is being written. A periodic `Queue cleanup completed, deleted N
items` line is routine pruning.

**Config drift.** Two hosts with two `.env` copies will diverge. Keep the memory
config in one versioned file (this repo's `configs/`) and treat each host's
`.env` as a rendered artifact.

---

## 9. Failure modes (read this before debugging)

| Symptom | Cause | Fix |
|---|---|---|
| `POST /peers/<p>/chat` → `{"detail":"An unexpected error occurred"}`; log shows `BadRequestError ... is not a valid model ID` | a dialectic level kept a **local** model slug while its base URL pointed at a remote provider | set every `DIALECTIC_LEVELS__*__MODEL_CONFIG__MODEL` to a real slug for that provider — all five levels, one provider per base URL |
| Memory never appears: queue stays `pending`, `conclusions/list` is `[]` | deriver batching: a small work unit waits for `DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS` (30 min) by default | set `DERIVER_FLUSH_ENABLED=true` while testing, or wait out the age-out |
| `search_messages` logs `401 Incorrect API key provided: sk-or-…` while chat works | embedding transport defaults to `api.openai.com` with no base URL, but the key belongs to another provider | set `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL`; keep model/dimensions matched |
| Everything 401s after copying a `.env` between hosts | key from provider A, base URL from provider B, or a stale local-model URL | pair each model id with its own provider's key + base URL |
| Collaborator gets `401` on everything | auth was turned on and they are using an old or missing token | mint a token (§6.4); the API accepts any key **only** while `AUTH_USE_AUTH=false` |
| `401 {"detail":"Invalid JWT"}` on a freshly minted token | it was minted with `--expires`, and 3.0.11 writes a string `exp` PyJWT rejects | mint without `--expires` (§6.4) |
| `500` on a token you built by hand | numeric `exp` passes PyJWT, then the server parses the claim as a date string | omit `exp` entirely |
| Monitor's memory panel goes empty after enabling auth | it could not enumerate workspaces with a scoped token | it now infers existence from workspace-scoped reads and reads its token from `~/.honcho-token` |
| `POST .../queue/status` → `405 Method Not Allowed` | it is a **GET** route (only `sessions/list`, `peers/list`, `conclusions/list` take an empty POST body) | use GET without a body |
| `DELETE .../workspaces/<id>` → `409 Conflict` | sessions still exist | delete `.../sessions/<id>` first; deletes return `202` (async) |

| `docker: Cannot connect to the Docker daemon` | daemon not running or not enabled at login | `systemctl enable --now docker`, or start Docker Desktop |
| `host.docker.internal` unresolvable on Linux | that name is a Docker Desktop convenience | add `--add-host=host.docker.internal:host-gateway`, or address the host directly |
| `mcp` service has no build target | `Dockerfile.local` / `wrangler.local.toml` are local-only, absent upstream | vendor them from `configs/mcp/` |
| A workflow fails minutes in, on one agent only | roster model id unavailable to the key's provider (nothing validates this at startup) | check each id against the provider model list before the run |
| `docker compose up -d` starts services you did not ask for | bare `up` creates every declared service | name them: `docker compose up -d api deriver` |
| Panes die when you close the terminal | the Herdr **server** was stopped, not the client | detach (`prefix+q`) or close the window; `herdr server stop` is the only real stop |
| Agent state shows `? unknown` | no detector matched, or the integration is not installed | `herdr agent list`, `herdr agent explain <target> --json`, `herdr integration status` |

---

## 10. Verification checklist

Run in order on a fresh host. Every line must pass before the factory is trusted.

```bash
# L1 — memory service
curl -s http://127.0.0.1:8000/health
docker compose ps

# L1 — memory loop (needs DERIVER_FLUSH_ENABLED=true for the fast path).
# Seed it in §3.4 and do NOT clean it up until this checklist passes; every line
# below reads the workspace that section created.
curl -s "http://127.0.0.1:8000/v3/workspaces/my-brain/queue/status"
curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:8000/v3/workspaces/my-brain/conclusions/list"
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"query":"What does alice prefer?"}' \
  "http://127.0.0.1:8000/v3/workspaces/my-brain/peers/alice/chat"

# L1 — auth (only if you enabled it, §6.4)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/health            # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' http://127.0.0.1:8000/v3/workspaces/my-brain/sessions/list              # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $HONCHO_API_KEY" -d '{}' \
  http://127.0.0.1:8000/v3/workspaces/my-brain/sessions/list                      # 200"

# L2 — workspace manager
herdr --version
herdr --session factory workspace list

# L3 — engine
cd ~/workspaces/agentic-dev && just demo && just sessions
sqlite3 adws/adw_data/sssf.db "select count(*) from sessions"

# L4 — sidecars
systemctl --user list-timers | grep shared-memory
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8790/.well-known/oauth-protected-resource
```

Expected: `{"status":"ok"}`; `api (healthy)`; queue completes and conclusions
list is non-empty; a natural-language chat answer; herdr reports the factory
workspace; `just demo` exits 0 and writes a session row; the timer is listed; the
MCP endpoint returns `200`.

---

## 11. Day-two direction

- **Turn auth on** (§6.4) and share the workspace over a private mesh before a
  second person or machine touches it.
- **Scale the deriver** (`DERIVER_WORKERS`) before enabling `DREAM_ENABLED`; the
  inductive pass is the expensive one.
- **One peer id per role** — memory becomes queryable as "what does `reviewer`
  know about this repo" instead of one undifferentiated blob.
- **Review the roster regularly.** Model ids and prompt templates are the highest
  leverage, lowest risk knobs in the factory.
- **Version the config.** Host `.env` files drift; keep the shared, non-secret
  shape in git and render it per host.

---

*Blueprint compiled from a live install: five containerised services, five agent
panes, one git-backed memory store. Corrections welcome — every claim here was
verified against a running system, and the failure-mode table is the fastest path
to reproducing that state.*
