#!/usr/bin/env bash
# End-to-end memory acceptance test. It proves the whole read/write loop:
#   health -> workspace -> session -> message -> deriver -> conclusions -> dialectic
#
#   ./scripts/verify-memory.sh
#   HONCHO_URL=http://127.0.0.1:8000 ./scripts/verify-memory.sh
#   HONCHO_API_KEY="$(cat ~/.honcho-token)" ./scripts/verify-memory.sh   # auth on
#   VERIFY_WORKSPACE=factory-brain ./scripts/verify-memory.sh            # stay in one workspace
#   VERIFY_VERBOSE=1 ./scripts/verify-memory.sh                          # print memory content
#   VERIFY_TIMEOUT=300 VERIFY_CHAT_TIMEOUT=600 ./scripts/verify-memory.sh   # slow models
#
# Safety and side effects:
#   - it deletes only resources the API confirmed it created (session create that
#     answered 201, workspace create that answered 201). A session that already
#     existed (200) is left in place, and so is a workspace it did not create.
#   - it writes one test message as peer "verify-peer". If the target session
#     already existed, that message and peer stay behind: point it at a scratch
#     workspace (or let it use a throwaway one) rather than a live conversation.
#   - a workspace-scoped token works: the target workspace is read from the
#     token's own scope. Nothing here needs the Python SDK.
set -uo pipefail

BASE_URL="${HONCHO_URL:-http://127.0.0.1:8000}"
TOKEN="${HONCHO_API_KEY:-}"
TIMEOUT="${VERIFY_TIMEOUT:-180}"          # step-5 poll budget
HTTP_TIMEOUT="${VERIFY_HTTP_TIMEOUT:-60}"  # per-request cap
CHAT_TIMEOUT="${VERIFY_CHAT_TIMEOUT:-300}" # dialectic is a multi-iteration LLM call
VERBOSE="${VERIFY_VERBOSE:-0}"

WS="${VERIFY_WORKSPACE:-}"
SESSION="${VERIFY_SESSION:-}"      # a pre-existing session is never deleted (see below)
PEER="${VERIFY_PEER:-verify-peer}"

CREATED_WS=0        # set only once the API confirms this run created the workspace
SESSION_OWNED=0     # ... and this one, for the session (201, not 200)
WS_SOURCE=

die_usage() { printf 'invalid %s %s: use letters, digits, dot, dash, underscore\n' "$1" "$2" >&2; exit 2; }
valid_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1;; esac; return 0; }

step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { # message, optional body
  printf '  FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '\n--- response (%s) ---\n' "${HTTP_STATUS:-no status}"
    printf '%s\n' "$2" | head -c 300
    printf '\n'
  fi
  exit 1
}

# One header string, not an array: an empty "${arr[@]}" trips `set -u` on bash 3.2
# (the macOS default), and a placeholder is harmless when auth is off.
auth_hdr() { printf 'Authorization: Bearer %s' "${TOKEN:-none}"; }

HTTP_STATUS=""
BODY=""
request() { # method url [json-body] [timeout]
  local out
  local t="${4:-$HTTP_TIMEOUT}"
  if [ -n "${3:-}" ]; then
    out=$(curl -sS -m "$t" -w '\n%{http_code}' -H "$(auth_hdr)" \
      -X "$1" -H 'Content-Type: application/json' -d "$3" "$2" 2>&1)
  else
    out=$(curl -sS -m "$t" -w '\n%{http_code}' -H "$(auth_hdr)" -X "$1" "$2" 2>&1)
  fi
  HTTP_STATUS=$(printf '%s' "$out" | tail -n 1)
  BODY=$(printf '%s' "$out" | sed '$d')
}

cleanup() {
  # Delete only what the API confirmed this run created (201). A reused session
  # (200) or a workspace that already existed (200) is left in place.
  if [ "$SESSION_OWNED" = 1 ]; then
    request DELETE "$BASE_URL/v3/workspaces/$WS/sessions/$SESSION"
    case "$HTTP_STATUS" in
      200|202|204) printf '\ncleanup: session %s removed (HTTP %s)\n' "$SESSION" "$HTTP_STATUS";;
      *) printf '\ncleanup: session %s NOT removed (HTTP %s) — it may be left over\n' "$SESSION" "$HTTP_STATUS";;
    esac
  else
    printf '\ncleanup: session %s left in place (not created by this script)\n' "$SESSION"
  fi
  if [ "$CREATED_WS" = 1 ]; then
    request DELETE "$BASE_URL/v3/workspaces/$WS"
    case "$HTTP_STATUS" in
      200|202|204) printf 'cleanup: workspace %s removal accepted (HTTP %s; deletes are async)\n' "$WS" "$HTTP_STATUS";;
      *) printf 'cleanup: workspace %s NOT removed (HTTP %s) — nothing was created if this is 401/404\n' "$WS" "$HTTP_STATUS";;
    esac
  fi
}
trap cleanup EXIT

echo "Honcho acceptance test"
echo "  url:       $BASE_URL"
echo "  auth:      $([ -n "$TOKEN" ] && echo 'bearer token' || echo 'none (AUTH_USE_AUTH=false)')"

# Resolve the workspace: explicit > the token's own scope > a throwaway we create.
# WS_TO_CREATE means "this run intends to create it"; CREATED_WS is only set once
# the API actually says so (201), so an abort before step 2 deletes nothing.
WS_TO_CREATE=0
if [ -n "$WS" ]; then
  WS_SOURCE="named by VERIFY_WORKSPACE"
elif [ -n "$TOKEN" ]; then
  claim=$(printf '%s' "$TOKEN" | python3 -c 'import base64,json,sys
p=sys.stdin.read().strip().split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("w") or "")' 2>/dev/null || true)
  if [ -n "$claim" ]; then
    WS="$claim"; WS_SOURCE="from the token's scope"
  fi
fi
if [ -z "$WS" ]; then
  WS="verify-$$-$(date +%s)"
  WS_TO_CREATE=1
  WS_SOURCE="throwaway, deleted on exit"
fi
[ -z "$SESSION" ] && SESSION="verify-session-$$-$RANDOM"

valid_id "$WS" workspace || die_usage workspace "$WS"
valid_id "$SESSION" session || die_usage session "$SESSION"
valid_id "$PEER" peer || die_usage peer "$PEER"

echo "  workspace: $WS ($WS_SOURCE)"
echo "  session:   $SESSION"
[ "$VERBOSE" = 1 ] || echo "  note:      memory content is hidden; VERIFY_VERBOSE=1 to print it"

step 1 "service health"
request GET "$BASE_URL/health" "" 20
case "$BODY" in
  *'"status":"ok"'*) ok "$BODY";;
  *) bad "no usable answer from $BASE_URL/health — is the stack up? (docker compose up -d)" "$BODY";;
esac

step 2 "workspace"
if [ "$WS_TO_CREATE" = 1 ]; then
  request POST "$BASE_URL/v3/workspaces" "{\"id\":\"$WS\"}"
  case "$HTTP_STATUS" in
    201) CREATED_WS=1; ok "created $WS (it will be removed at the end)";;
    200) CREATED_WS=0; ok "workspace $WS already existed (left untouched)";;
    *)   bad "workspace create failed (HTTP $HTTP_STATUS) — with auth on, pass HONCHO_API_KEY (or VERIFY_WORKSPACE=<existing>)" "$BODY";;
  esac
else
  request POST "$BASE_URL/v3/workspaces/$WS/sessions/list" '{}'
  [ "$HTTP_STATUS" = 200 ] \
    || bad "cannot read workspace $WS (HTTP $HTTP_STATUS) — wrong token scope? pass VERIFY_WORKSPACE=<workspace>" "$BODY"
  ok "using existing $WS ($(printf '%s' "$BODY" | jq -r '.total // 0' 2>/dev/null) session(s))"
fi

step 3 "session (get-or-create; 201 means this run owns it)"
request POST "$BASE_URL/v3/workspaces/$WS/sessions" "{\"id\":\"$SESSION\"}"
case "$HTTP_STATUS" in
  201) SESSION_OWNED=1; ok "created $SESSION (it will be removed at the end)";;
  200) SESSION_OWNED=0; ok "reused the existing $SESSION (left untouched)";;
  *)   bad "session create failed (HTTP $HTTP_STATUS)" "$BODY";;
esac

step 4 "write a message (this is what the deriver consumes)"
request POST "$BASE_URL/v3/workspaces/$WS/sessions/$SESSION/messages" \
  "{\"messages\":[{\"peer_id\":\"$PEER\",\"content\":\"I prefer dark mode, short answers, and no emojis.\"}]}"
[ "$HTTP_STATUS" = 200 ] || [ "$HTTP_STATUS" = 201 ] || bad "message write failed (HTTP $HTTP_STATUS)" "$BODY"
ok "message stored"

step 5 "wait for the deriver (timeout ${TIMEOUT}s)"
printf '  ... every 5s: '
waited=0; drained=0; pending="?"; done_="?"
while [ "$waited" -lt "$TIMEOUT" ]; do
  request GET "$BASE_URL/v3/workspaces/$WS/queue/status" "" 20
  pending=$(printf '%s' "$BODY" | jq -r '.pending_work_units // empty' 2>/dev/null)
  done_=$(printf '%s' "$BODY" | jq -r '.completed_work_units // empty' 2>/dev/null)
  if [ "${pending:-x}" = "0" ] && [ "${done_:-x}" != "x" ] && [ "${done_:-0}" -ge 1 ]; then drained=1; break; fi
  printf '%s ' "pending=${pending:-?}"
  sleep 5; waited=$((waited + 5))
done
printf '\n'
if [ "$drained" = 1 ]; then
  ok "queue drained: completed=$done_ pending=0"
else
  cat <<EOF
  FAIL  queued work did not drain within ${TIMEOUT}s

  Most common cause: DERIVER_FLUSH_ENABLED=false. The deriver batches small
  messages until DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS (default 1800s = 30
  minutes). For a first install set  DERIVER_FLUSH_ENABLED=true  in .env and
  'docker compose up -d deriver', then re-run this script.

  Otherwise, in order:
    docker compose ps                      # api + deriver running and healthy?
    docker compose logs --tail=50 deriver  # errors, or 'observation_count=N' lines
    docker compose logs --tail=50 api      # 401s from your model provider?
EOF
  exit 1
fi

step 6 "derived memory (conclusions)"
request POST "$BASE_URL/v3/workspaces/$WS/conclusions/list" '{}'
[ "$HTTP_STATUS" = 200 ] || bad "conclusions read failed (HTTP $HTTP_STATUS)" "$BODY"
total=$(printf '%s' "$BODY" | jq -r '.total // 0' 2>/dev/null)
[ "${total:-0}" -ge 1 ] || bad "no conclusions yet — the deriver ran but extracted nothing; check its log for observation_count" "$BODY"
if [ "$VERBOSE" = 1 ]; then
  ok "$total conclusion(s), e.g. $(printf '%s' "$BODY" | jq -r '.items[0].content // "-"')"
else
  ok "$total conclusion(s) stored (content hidden)"
fi

step 7 "ask the memory (dialectic)"
request POST "$BASE_URL/v3/workspaces/$WS/peers/$PEER/chat" '{"query":"What does this peer prefer?"}' "$CHAT_TIMEOUT"
[ "$HTTP_STATUS" = 200 ] || bad "dialectic call failed (HTTP $HTTP_STATUS) — a 400 here usually names a model id your provider rejects" "$BODY"
answer=$(printf '%s' "$BODY" | jq -r '.content // empty' 2>/dev/null)
[ -n "$answer" ] || bad "empty answer — see README §9 for the model/base-URL pairing rules" "$BODY"
if [ "$VERBOSE" = 1 ]; then ok "answer: $answer"; else ok "answer received ($(printf '%s' "$answer" | wc -c | tr -d ' ') chars; VERIFY_VERBOSE=1 to print)"; fi

printf '\nAll steps passed — the memory layer works end to end.\n'