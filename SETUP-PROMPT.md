# Setup prompt (hand this to a coding agent)

Paste the block below into Claude Code, Codex, `omp`, or any agent with shell
access on the target machine. It installs the four layers in order, verifying
each. Sanitized: it never contains credentials, and it stops to ask for keys.

---

```text
You are setting up a self-hosted software factory on this machine: a memory layer
(Honcho), a persistent terminal workspace manager for coding agents (Herdr), a
deterministic Python workflow engine (SSSF/ADW), and optional memory sidecars.
Work step by step, run every verification command, and stop to ask me for
credentials. Never echo, log, or commit a secret. Never widen a service beyond
127.0.0.1.

PREREQUISITES — verify, report what is missing, then continue:
  docker --version && docker compose version    # Compose v2 required
  git --version
  python3 --version                             # 3.11+
  node --version                                # 20+
  which uv just mise pi

LAYER 1 — HONCHO (memory)

1. Clone and configure:
     git clone https://github.com/plastic-labs/honcho.git ~/honcho-memory
     cd ~/honcho-memory && git rev-parse --short HEAD    # report it
     cp docker-compose.yml.example docker-compose.yml
     cp .env.template .env

2. ASK ME for an LLM API key. Then edit .env:
   - OpenAI-compatible provider (least config):
       LLM_OPENAI_API_KEY=<key>
   - OpenRouter (also set the base URL and real provider/model slugs for EVERY
     module — deriver, summary, and all five dialectic levels):
       LLM_OPENAI_API_KEY=<key>
       LLM_OPENAI_BASE_URL=https://openrouter.ai/api/v1
       DERIVER_MODEL_CONFIG__MODEL=<provider/model>
       DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object
       SUMMARY_MODEL_CONFIG__MODEL=<provider/model>
       DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL=<provider/model>
       DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL=<provider/model>
       DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL=<provider/model>
       DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL=<provider/model>
       DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL=<provider/model>
   Validate any model id against the provider's own model list before using it.

3. Embeddings: the transport defaults to api.openai.com with no base URL, so a
   non-OpenAI key 401s on search. Set them to match the provider:
       EMBEDDING_MODEL_CONFIG__TRANSPORT=openai
       EMBEDDING_MODEL_CONFIG__MODEL=openai/text-embedding-3-small
       EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=<same base URL as above>

4. Set these explicitly:
       EMBED_MESSAGES=false
       DERIVER_ENABLED=true
       DERIVER_WORKERS=1
       DERIVER_FLUSH_ENABLED=true        # testing; false later for batching
       DREAM_ENABLED=false
       SENTRY_ENABLED=false
       AUTH_USE_AUTH=false               # turn ON before exposing anywhere (step 12)

5. Start and verify:
     docker compose up -d --build
     docker compose ps                                  # api (healthy)
     curl -s http://127.0.0.1:8000/health               # {"status":"ok"}
     docker compose logs --tail=30 deriver              # "Running main loop"

6. ACCEPTANCE — prove the memory loop (do not skip; this is the test that
   catches every wiring mistake). Use workspace name "verify-brain":
     curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"id":"verify-brain"}' http://127.0.0.1:8000/v3/workspaces
     python3 -m venv ~/.honcho-venv && ~/.honcho-venv/bin/pip -q install honcho-ai
     ~/.honcho-venv/bin/python - <<'PY'
     from honcho import Honcho
     h = Honcho(workspace_id="verify-brain", base_url="http://127.0.0.1:8000")
     a = h.peer("alice"); s = h.session("first-session")
     s.add_peers([a])
     s.add_messages([a.message("I prefer dark mode, short answers, and no emojis.")])
     print("seeded")
     PY
     curl -s "http://127.0.0.1:8000/v3/workspaces/verify-brain/queue/status"
       # expect pending 0, completed 1   (GET — POST returns 405)
     curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
       "http://127.0.0.1:8000/v3/workspaces/verify-brain/conclusions/list"
       # expect total >= 1 (model-dependent), level "explicit"
     curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"query":"What does alice prefer?"}' \
       "http://127.0.0.1:8000/v3/workspaces/verify-brain/peers/alice/chat"
       # expect prose, NOT {"detail":"An unexpected error occurred"}
   If the queue never drains: confirm DERIVER_FLUSH_ENABLED=true (otherwise a
   small unit waits up to 30 min) and check the deriver log for
   "observation_count". If chat errors, the log will name the offending model id.
   Then clean up:
     curl -s -X DELETE "http://127.0.0.1:8000/v3/workspaces/verify-brain/sessions/first-session"
     curl -s -X DELETE "http://127.0.0.1:8000/v3/workspaces/verify-brain"

7. Optional MCP server: create mcp/Dockerfile.local and mcp/wrangler.local.toml
   (see configs/mcp/ in this repo), append the "mcp" service to
   docker-compose.yml with ports 127.0.0.1:8790:8790, then:
     docker compose up -d mcp
     curl -s -o /dev/null -w '%{http_code}\n' \
       http://127.0.0.1:8790/.well-known/oauth-protected-resource    # 200

LAYER 2 — HERDR (persistent agent panes)

8.   curl -fsSL https://herdr.dev/install.sh | sh
     herdr --version
   Then, in the factory directory later, `herdr` starts or attaches the session.
   Detaching (prefix+q) or closing the terminal leaves agents running; only
   `herdr server stop` stops them. Verify with:
     herdr --session factory workspace list

LAYER 3 — SSSF / ADW (the engine)

9. The engine lives in the factory repo at ~/workspaces/agentic-dev with adws/,
   justfile, scripts/. It is a private starter: if you do not have access, build
   the shape from configs/engine/ (a roster + justfile skeleton) and the resource
   list in README §5.1. Check out the repo, then:
     cd ~/workspaces/agentic-dev
     cp .env.sample .env        # add OPENROUTER_API_KEY (or your provider key)
     just --list
     just demo                  # two read-only runs; must exit 0
     just sessions              # a session row must appear
     sqlite3 adws/adw_data/sssf.db "select count(*) from sessions"
   Confirm every model id in adws/adw_sssf_config/sssf.config.yaml exists at the
   provider — nothing validates them at startup, they fail mid-workflow.
   Also confirm the agent CLI itself is authenticated (for pi: its own provider
   credentials under ~/.pi/agent/, independent of the factory .env); an
   unauthenticated CLI fails the same way, mid-workflow.
   Confirm protected files are enforced by adws/adw_modules/permissions.py.

LAYER 4 — SIDECARS (optional)

10. Git-backed shared memory (markdown, one fact per file, git is truth):
      git clone <private shared-memory repo> ~/shared-memory
      git clone <this blueprint repo> ~/software-factory-blueprint
      mkdir -p ~/.local/bin
      install -m 0755 ~/software-factory-blueprint/configs/shared-memory-sync.sh ~/.local/bin/
      install -m 0644 ~/software-factory-blueprint/configs/shared-memory-sync.service ~/.config/systemd/user/
      install -m 0644 ~/software-factory-blueprint/configs/shared-memory-sync.timer ~/.config/systemd/user/
      systemctl --user daemon-reload
      systemctl --user enable --now shared-memory-sync.timer
      systemctl --user list-timers | grep shared

11. Note bridge (optional; bring your own, or skip). Contract: a CLI that scans
    a notes vault for files opted in via frontmatter (`honcho_sync: true`), never
    edits the vault, and uploads changed notes to Honcho as new revisions with a
    content hash. If you have such a tool:
      git clone <your bridge repo> ~/memory-bridge
      cd ~/memory-bridge && python3 -m venv .venv
      .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
      export OBSIDIAN_VAULT="/absolute/path/to/vault"
      export HONCHO_URL="http://127.0.0.1:8000"
      ./bin/obsidian-honcho scan && ./bin/obsidian-honcho status
    Only notes with frontmatter `honcho_sync: true` are uploaded.

SHARING (only when a second person or machine needs the memory)

12. Keep the API on loopback, join the machines on a private mesh (Tailscale or
    equivalent), enable auth, mint scoped tokens:
      cd ~/honcho-memory
      uv run python scripts/generate_jwt_secret.py
      # .env: AUTH_USE_AUTH=true, AUTH_JWT_SECRET=<secret>
      docker compose up -d api deriver
      # Do NOT pass --expires: 3.0.11 writes a string exp claim that PyJWT
      # rejects (401 "Invalid JWT"). Mint without it.
      uv run python scripts/generate_jwt.py --workspace <ws>
    Give each collaborator their own scoped token, never the admin token. They
    set HONCHO_URL + HONCHO_API_KEY and use the same SDK/CLI/MCP configs.

FINAL REPORT — give me:
  - the Honcho commit hash, `docker compose ps` output, /health response
  - the acceptance results: queue counters, conclusions count, and the dialectic
    answer text (or the exact error + model id that caused it)
  - `just demo` exit status and the session row it wrote
  - every place you changed a config, and anything you could not verify

RULES
  - Loopback bindings only (127.0.0.1). Never 0.0.0.0 without auth on.
  - Never print, paste, or commit secrets; confirm .env is gitignored.
  - Do not enable DREAM_ENABLED or EMBED_MESSAGES until the provider actually
    serves those models/embeddings — mismatches fail silently or 400 at runtime.
  - Back up the Postgres and Redis volumes before any upgrade.
```
