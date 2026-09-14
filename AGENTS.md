# AGENTS.md — point your coding agent here

This repo is a **setup blueprint for a self-hosted software factory**: a memory
layer (Honcho), a terminal workspace manager for coding agents (Herdr), a
deterministic Python workflow engine (SSSF/ADW), and optional memory sidecars.

You are the agent. Your job is to install and verify it **on this machine**, with
the human, and to leave behind something that works — not to touch their projects.

## Rules (do not violate these)

1. **Loopback only.** Every service binds `127.0.0.1`. Never publish on
   `0.0.0.0` or a LAN address.
2. **Secrets.** Never print, log, echo into a transcript, or commit an API key,
   token, or `.env` file. Ask the human for keys; write them into `.env` only.
   Confirm `.env` is gitignored before writing.
3. **Ask before assuming.** If a step needs a credential, a private repo, or a
   decision (which provider, whether to expose the API), stop and ask.
4. **Do not invent.** Every command you need exists in `README.md`, `QUICKREF.md`,
   or `configs/`. If a command is not there and you are not certain, run
   `--help` first and say so.
5. **Verify each layer before starting the next.** A silent failure in layer 1
   makes every later layer look broken.

## Order of work

```bash
./scripts/preflight.sh          # required tooling; fix anything MISSING first
./scripts/preflight.sh --local  # ...again once the stack is up
```

### Layer 1 — Honcho memory (the part that must work)

1. Clone and configure, per README §3.1-§3.2:
   `git clone https://github.com/plastic-labs/honcho.git ~/honcho-memory`
   then `cp docker-compose.yml.example docker-compose.yml && cp .env.template .env`
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
- A workspace-scoped token **cannot** create or list workspaces. Hand out scoped
  tokens; never the admin one.

Exposure over a private mesh: keep containers on loopback and forward with
`configs/tailnet-proxy.service` (README §6.4). Do not widen the bind.

## Acceptance — what "done" means

Report all of these, with the actual output:

| Check | Command | Expected |
|---|---|---|
| tooling present | `./scripts/preflight.sh` | exit 0 |
| memory loop works | `./scripts/verify-memory.sh` | exit 0, all 7 steps PASS |
| stack healthy | `docker compose ps` | `api` healthy, `deriver` up |
| auth (only if enabled) | `curl` data route with and without token | 401 then 200 |
| engine | `just demo && just sessions` | exit 0, one row |

Finish with: what you installed, the exact commands you ran, what you could not
verify, and anything you had to decide on the human's behalf. Do not claim a step
passed unless you ran it.