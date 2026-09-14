# AGENTS.md — point your coding agent here

This repo is a **setup blueprint for a self-hosted software factory**: a memory
layer (Honcho), a terminal workspace manager for coding agents (Herdr), a
deterministic Python workflow engine (SSSF/ADW), and optional memory sidecars.

You are the agent. Your job is to install and verify it **on this machine**, with
the human, and to leave behind something that works — not to touch their projects.

## Ask the human once, up front

Four questions, so you do not stop and start:

1. **LLM provider + key** for the memory layer (OpenAI, OpenRouter, or a local
   OpenAI-compatible server). If it is not OpenAI, note the base URL too.
2. **Should the memory be reachable from another machine?** "No" is the default
   and needs no extra work. "Yes" means auth plus a private mesh — README §6.4 —
   and you should do it *after* layer 1 verifies, not before.
3. **Do they have the factory engine repo** (the ADW scripts)? If not, layer 3
   stops at the skeletons in `configs/engine/`.
4. **Do they want the note bridge / git-backed shared memory?** Optional; skip
   unless asked.

## Rules (do not violate these)

1. **Loopback only.** Every service binds `127.0.0.1`. Never publish on
   `0.0.0.0` or a LAN address.
2. **Secrets.** Never print, log, echo into a transcript, or commit an API key,
   token, or `.env` file. Never `cat` an `.env` or paste a key into chat: have the
   human write the key themselves — either straight into `.env`, or into a
   `chmod 600` file you read — and confirm afterwards by naming the variable, not
   its value. Confirm `.env` is gitignored before writing.
3. **Ask before assuming.** Stop and ask if a step needs a credential, a private
   repo, a decision (which provider, whether to expose the API), **installing
   packages or using `sudo` outside this repo**, or **deleting anything that
   already exists** (an old clone, a volume, a workspace).
4. **Do not invent.** Every command you need exists in `README.md`, `QUICKREF.md`,
   or `configs/`. If a command is not there and you are not certain, run
   `--help` first and say so.
5. **Verify each layer before starting the next.** A silent failure in layer 1
   makes every later layer look broken.
6. **Never rebuild over someone's data.** Before any `docker compose up --build`
   or upgrade on an existing install, snapshot the volumes and keep a copy of
   `.env` as `.env.backup-<timestamp>` (README §8). Never run `docker compose down
   -v` and never delete a workspace that existed before you arrived.
7. **`scripts/` are fixtures, not scaffolding.** Do not edit them to make them
   pass; fix the environment, or report the failure. Paste their raw output in
   your report.

## Order of work

```bash
./scripts/preflight.sh          # required tooling; fix anything MISSING first
./scripts/preflight.sh --local  # ...again once the stack is up
```

### Layer 1 — Honcho memory (the part that must work)

1. Clone and configure, per README §3.1-§3.2. This blueprint is verified against
   **v3.0.11**, so pin it rather than tracking the default branch:
   `git clone --branch v3.0.11 --depth 1 https://github.com/plastic-labs/honcho.git ~/honcho-memory`
   (drop `--branch` only if the human wants a newer tag; say which one you took).
   Then `cp docker-compose.yml.example docker-compose.yml && cp .env.template .env`
2. **Ask the human for an LLM API key.** Then set, in `.env`:
   - `LLM_OPENAI_API_KEY` (plus `LLM_OPENAI_BASE_URL` for anything that is not OpenAI)
   - a model for the deriver, the summarizer, and **all five**
     `DIALECTIC_LEVELS__{minimal,low,medium,high,max}__MODEL_CONFIG__MODEL`
     entries — ids must belong to the provider you configured. Verify each id
     against the provider's model list before using it; nothing validates them at
     startup and a wrong id fails mid-workflow.
   - `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL` if the provider is not OpenAI
     (otherwise search and dedup 401 against api.openai.com)
   - `DERIVER_FLUSH_ENABLED=true` for a first install, so messages are processed
     immediately instead of waiting up to 30 minutes for the batch age-out
   - `DREAM_ENABLED=false` — the code default is `true`, and the inductive pass is
     the expensive one; `configs/honcho.env.example` spells out the whole set
3. `docker compose up -d --build` then confirm:
   `curl -s http://127.0.0.1:8000/health` → `{"status":"ok"}` and
   `docker compose ps` → `api` healthy.
4. **Run the acceptance test:**

   ```bash
   ./scripts/verify-memory.sh
   ```

   It creates a throwaway workspace, writes a message, waits for the deriver,
   reads the extracted memory, asks the memory a question, and cleans up. If it
   fails, its message tells you which of the above is wrong — fix that, not the
   test. Do not proceed until it exits 0.

### Layer 2 — Herdr (agent panes)

Follow README §4. Install, then build the layout **with `--session` scoping**
(`herdr --session factory pane list`). Details matter here: `herdr agent start
<name> --kind pi --pane <id>` is what gives a pane its stable identity.

### Layer 3 — SSSF / ADW (the engine)

The engine is a **private starter** (README §5.1). `configs/engine/` contains a
roster and `justfile` skeleton — the shape, not the runners. If the human does not
have the engine repo, say so plainly and stop here; do not write a fake engine.
If they do: `just demo` must exit 0 and `just sessions` must show a row.

### Layer 4 — Sidecars (optional)

Git-backed shared memory (systemd timer; `launchd`/cron on macOS) and a note
bridge. Both are bring-your-own, per README §6.1-§6.2. Skip unless asked.

## When the human asks to share the memory with someone

That means auth, and auth means tokens: README §6.4. Two traps worth repeating:

- **`generate_jwt.py --expires` is broken in 3.0.11** — the `exp` claim is written
  as a string, PyJWT rejects it, and every request 401s. Mint without `--expires`.
- A workspace-scoped token **cannot list** workspaces, and can only get-or-create
  the one workspace it is scoped to (`/v3/workspaces/list` is admin-only; a
  different workspace id 401s). Hand out scoped tokens; never the admin one.

Exposure over a private mesh: keep containers on loopback and forward with
`configs/tailnet-proxy.service` (README §6.4). Do not widen the bind.

## Acceptance — what "done" means

Report all of these, with the actual output:

| Check | Command | Expected |
|---|---|---|
| tooling present | `./scripts/preflight.sh` | exit 0 |
| memory loop works | `./scripts/verify-memory.sh` | exit 0, all 7 steps PASS |
| stack healthy | `docker compose ps` | `api` healthy, `deriver` up |
| **nothing exposed** | `docker compose port api 8000` (and `database 5432`, `redis 6379`) | every binding starts with `127.0.0.1:` |
| auth (only if enabled) | `curl -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' $HONCHO_URL/v3/workspaces/<their-ws>/sessions/list` with and without the token | 200 with, 401 without, and 401 on a workspace the token is not scoped to |
| panes (layer 2) | `herdr --session factory workspace list` | the factory workspace, with its panes |
| MCP (layer 4, if installed) | `curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8790/.well-known/oauth-protected-resource` | 200 |
| sidecar sync (layer 4, if installed) | `systemctl --user list-timers \| grep shared-memory` | timer listed |
| engine | `just demo && just sessions` + `sqlite3 adws/adw_data/sssf.db "select count(*) from sessions"` | exit 0, at least one row |

Finish with: what you installed, the exact commands you ran, what you could not
verify, and anything you had to decide on the human's behalf. Do not claim a step
passed unless you ran it.