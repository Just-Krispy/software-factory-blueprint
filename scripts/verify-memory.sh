#!/usr/bin/env bash
# End-to-end memory acceptance test. It proves the whole read/write loop:
#   health -> workspace -> session -> message -> deriver -> conclusions -> dialectic
# then deletes everything it created. Uses curl + jq only (no SDK, no venv).
#
#   ./scripts/verify-memory.sh
#   HONCHO_URL=http://127.0.0.1:8000 ./scripts/verify-memory.sh
#   HONCHO_API_KEY=<token> ./scripts/verify-memory.sh      # when auth is on
#   VERIFY_TIMEOUT=300 ./scripts/verify-memory.sh          # slow models
#
# Exit 0 = the memory layer works. Exit 1 = a specific step failed and printed why.
set -uo pipefail

BASE_URL="${HONCHO_URL:-http://127.0.0.1:8000}"
TOKEN="${HONCHO_API_KEY:-}"
WS="${VERIFY_WORKSPACE:-}"
PEER="${VERIFY_PEER:-verify-peer}"
SESSION="${VERIFY_SESSION:-verify-session-$RANDOM}"

# A workspace-scoped token cannot create workspaces (and should not), so read the
# scope out of the token when the caller did not name one.
if [ -z "$WS" ] && [ -n "$TOKEN" ]; then
  claim=$(python3 -c 'import base64,json,sys
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))' "$TOKEN" 2>/dev/null || true)
  WS=$(printf '%s' "$claim" | jq -r '.w // empty' 2>/dev/null || true)
  [ -n "$WS" ] && CREATED_WS=0 && WS_SOURCE="from token scope"
fi
if [ -z "$WS" ]; then WS="verify-$$-$(date +%s)"; CREATED_WS=1; WS_SOURCE="created by this script"; else CREATED_WS="${CREATED_WS:-0}"; fi
TIMEOUT="${VERIFY_TIMEOUT:-180}"

# A single header string instead of a bash array: empty `"${arr[@]}"` trips
# `set -u` on bash 3.2 (the macOS default), and a placeholder header is harmless.
auth_hdr() { printf 'Authorization: Bearer %s' "${TOKEN:-none}"; }

step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; printf '\n--- response ---\n%s\n' "${2:-}"; exit 1; }

api_get()  { curl -fsS -m 20 -H "$(auth_hdr)" "$1" 2>&1; }
api_post() { curl -fsS -m 45 -H "$(auth_hdr)" -X POST -H 'Content-Type: application/json' -d "$2" "$1" 2>&1; }

cleanup() {
  # sessions must go before the workspace (a workspace delete returns 409 otherwise)
  curl -sS -m 20 -H "$(auth_hdr)" -X DELETE "$BASE_URL/v3/workspaces/$WS/sessions/$SESSION" >/dev/null 2>&1 || true
  # only remove the workspace if this script created it
  if [ "${CREATED_WS:-0}" = "1" ]; then
    curl -sS -m 20 -H "$(auth_hdr)" -X DELETE "$BASE_URL/v3/workspaces/$WS" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Honcho acceptance test"
echo "  url:       $BASE_URL"
echo "  workspace: $WS ($WS_SOURCE; only test data is removed)"
echo "  auth:      $([ -n "$TOKEN" ] && echo 'bearer token' || echo 'none (AUTH_USE_AUTH=false)')"

step 1 "service health"
health=$(api_get "$BASE_URL/health") || bad "no answer from $BASE_URL/health — is the stack up? (docker compose up -d)" "$health"
case "$health" in
  *'"status":"ok"'*) ok "$health";;
  *) bad "unexpected /health payload" "$health";;
esac

step 2 "workspace"
if [ "$CREATED_WS" = "1" ]; then
  out=$(api_post "$BASE_URL/v3/workspaces" "{\"id\":\"$WS\"}") || bad "workspace create failed — with auth on, pass HONCHO_API_KEY (or VERIFY_WORKSPACE=<existing>)" "$out"
  ok "created $WS"
else
  out=$(api_post "$BASE_URL/v3/workspaces/$WS/sessions/list" '{}') || bad "cannot read workspace $WS — wrong token scope? pass VERIFY_WORKSPACE=<workspace>" "$out"
  ok "using existing $WS ($(printf '%s' "$out" | jq -r '.total // 0') session(s))"
fi

step 3 "get-or-create session (removed at the end)"
out=$(api_post "$BASE_URL/v3/workspaces/$WS/sessions" "{\"id\":\"$SESSION\"}") || bad "session create failed" "$out"
ok "session $SESSION"

step 4 "write a message (this is what the deriver consumes)"
out=$(api_post "$BASE_URL/v3/workspaces/$WS/sessions/$SESSION/messages" \
  "{\"messages\":[{\"peer_id\":\"$PEER\",\"content\":\"I prefer dark mode, short answers, and no emojis.\"}]}") \
  || bad "message write failed" "$out"
ok "message stored"

step 5 "wait for the deriver (timeout ${TIMEOUT}s)"
printf '  ... every 5s: '
waited=0; queued=0
while [ "$waited" -lt "$TIMEOUT" ]; do
  q=$(api_get "$BASE_URL/v3/workspaces/$WS/queue/status") || true
  pending=$(printf '%s' "$q" | jq -r '.pending_work_units // empty' 2>/dev/null)
  done_=$(printf '%s' "$q" | jq -r '.completed_work_units // empty' 2>/dev/null)
  if [ "${pending:-x}" = "0" ] && [ "${done_:-x}" != "x" ] && [ "${done_:-0}" -ge 1 ]; then queued=1; break; fi
  printf '%s ' "pending=${pending:-?}"
  sleep 5; waited=$((waited+5))
done
printf '\n'
if [ "$queued" = 1 ]; then
  ok "queue drained: completed=$done_ pending=0"
else
  cat <<EOF
  FAIL  queued work did not drain within ${TIMEOUT}s

  Most common cause: DERIVER_FLUSH_ENABLED=false. The deriver batches small
  messages until DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS (default 1800s = 30
  minutes). For a first install set  DERIVER_FLUSH_ENABLED=true  in .env and
  'docker compose up -d deriver', then re-run this script.

  Other things to check, in order:
    docker compose ps                      # api + deriver running and healthy?
    docker compose logs --tail=50 deriver  # errors, or 'observation_count=N' lines
    docker compose logs --tail=50 api      # 401s from your model provider?
EOF
  exit 1
fi

step 6 "derived memory (conclusions)"
out=$(api_post "$BASE_URL/v3/workspaces/$WS/conclusions/list" '{}') || bad "conclusions read failed" "$out"
total=$(printf '%s' "$out" | jq -r '.total // 0' 2>/dev/null)
[ "${total:-0}" -ge 1 ] 2>/dev/null || bad "no conclusions yet — the deriver ran but extracted nothing; check its log for observation_count" "$out"
ok "$total conclusion(s), e.g. $(printf '%s' "$out" | jq -r '.items[0].content // "-"' | cut -c1-60)"

step 7 "ask the memory (dialectic)"
out=$(api_post "$BASE_URL/v3/workspaces/$WS/peers/$PEER/chat" '{"query":"What does this peer prefer?"}') \
  || bad "dialectic call failed (a 400 here usually names a model id your provider rejects)" "$out"
answer=$(printf '%s' "$out" | jq -r '.content // empty' 2>/dev/null)
[ -n "$answer" ] || bad "empty answer — see README §9 for the model/base-URL pairing rules" "$out"
ok "answer: $(printf '%s' "$answer" | tr '\n' ' ' | cut -c1-90)…"

printf '\nAll steps passed — the memory layer works end to end.\n'
printf 'Cleanup runs on exit: session, then workspace (deletes return 202 and\n'
printf 'complete within a few seconds).\n'