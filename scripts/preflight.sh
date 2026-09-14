#!/usr/bin/env bash
# Preflight: check this machine can run the software factory before you start.
# Read-only — installs nothing, changes nothing. Prints what is missing and how
# to get it. Exit 0 when everything required is present, 1 otherwise.
#
#   ./scripts/preflight.sh          # required + optional tooling
#   ./scripts/preflight.sh --local  # also require a running Honcho on :8000
set -uo pipefail

PROBE_LOCAL=0
[ "${1:-}" = "--local" ] && PROBE_LOCAL=1

pass=0; fail=0; opt=0

req() { # name, command, hint
  if command -v "$2" >/dev/null 2>&1; then
    printf '  ok      %-14s %s\n' "$1" "$("$2" ${3:-} 2>&1 | head -1)"
    pass=$((pass+1))
  else
    printf '  MISSING %-14s %s\n' "$1" "$4"
    fail=$((fail+1))
  fi
}

optional() {
  if command -v "$2" >/dev/null 2>&1; then
    printf '  ok      %-14s %s\n' "$1" "$("$2" ${3:-} 2>&1 | head -1)"
    opt=$((opt+1))
  else
    printf '  -       %-14s not installed: %s\n' "$1" "$4"
  fi
}

echo "Required"
req docker   docker   "--version" "install Docker Engine or Docker Desktop"
req git      git      "--version" "install git"
req curl     curl     "--version" "install curl"
req jq       jq       "--version" "install jq (used by scripts and examples)"
req python3  python3  "--version" "install Python 3.11+ (Honcho runs 3.13 in-container)"

# Docker daemon: the commonest first-run failure.
if command -v docker >/dev/null 2>&1; then
  # Exit status decides; stderr only classifies the failure. A healthy daemon can
  # still write warnings (e.g. 'No swap limit support' on cgroup-v1 hosts).
  if docker info >/dev/null 2>&1; then
    printf '  ok      %-14s daemon reachable\n' "docker daemon"
    pass=$((pass+1))
  elif docker info 2>&1 | grep -qi 'permission denied'; then
    printf '  MISSING %-14s %s\n' "docker daemon" \
      "your user cannot talk to the socket: sudo usermod -aG docker \$USER, then re-login"
    fail=$((fail+1))
  else
    printf '  MISSING %-14s %s\n' "docker daemon" \
      "not running (start Docker Desktop, or: sudo systemctl enable --now docker)"
    fail=$((fail+1))
  fi
  if docker compose version >/dev/null 2>&1; then
    printf '  ok      %-14s %s\n' "compose v2" "$(docker compose version --short 2>/dev/null)"
    pass=$((pass+1))
  else
    printf '  MISSING %-14s %s\n' "compose v2" "need the 'docker compose' plugin (v2), not docker-compose v1"
    fail=$((fail+1))
  fi
fi

# Python version gate: 3.11+.
if command -v python3 >/dev/null 2>&1; then
  py=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0.0)
  case "$py" in
    3.1[1-9]|3.[2-9][0-9]) printf '  ok      %-14s %s\n' "python >= 3.11" "$py";;
    *) printf '  MISSING %-14s found %s, need 3.11+\n' "python >= 3.11" "$py"; fail=$((fail+1));;
  esac
fi

echo
echo "Optional"
optional sqlite3  sqlite3  "--version"      "trace queries (just sessions/phases/procs)"
optional node     node     "--version"      "MCP worker and the trace UI"
optional uv       uv       "--version"      "running ADW workflows; 'uv tool install honcho-cli'"
optional just     just     "--version"      "the factory engine's recipes"
optional mise     mise     "--version"      "toolchain management used in this blueprint"
optional bun      bun      "--version"      "trace UI"
optional herdr    herdr    "--version"      "persistent agent panes"

if [ "$PROBE_LOCAL" = 1 ]; then
  echo
  echo "Local Honcho (http://127.0.0.1:8000)"
  if curl -fsS -m 5 http://127.0.0.1:8000/health >/dev/null 2>&1; then
    printf '  ok      %-14s %s\n' "api /health" "$(curl -fsS -m 5 http://127.0.0.1:8000/health)"
    printf '  next            ./scripts/verify-memory.sh\n'
  else
    printf '  MISSING %-14s nothing answering on :8000 (docker compose up -d)\n' "api /health"
    fail=$((fail+1))
  fi
fi

echo
printf 'required: %d ok, %d missing   optional: %d present\n' "$pass" "$fail" "$opt"
[ "$fail" -eq 0 ] || { echo "fix the MISSING items above, then re-run"; exit 1; }
echo "preflight clean — next: read AGENTS.md (or SETUP-PROMPT.md) and start the stack"
