#!/usr/bin/env bash
# shared-memory-sync.sh — pull/rebase, commit, push a git-backed memory store.
#
# Install to ~/.local/bin/shared-memory-sync.sh and drive it from a systemd user
# timer (or cron) on every host that writes to the store.
#
# Design notes:
#   - pull --rebase before anything else, so two hosts never clobber each other.
#   - --autostash keeps a dirty tree from blocking the rebase.
#   - a commit is made only when the tree is actually dirty.
#   - the commit identity is set explicitly so headless/scheduled runs always
#     attribute correctly (git user.name is often unset for service accounts).
set -euo pipefail

REPO="${SHARED_MEMORY_REPO:-$HOME/shared-memory}"
GIT_AUTHOR_NAME="${SHARED_MEMORY_GIT_NAME:-shared-memory-sync}"
GIT_AUTHOR_EMAIL="${SHARED_MEMORY_GIT_EMAIL:-shared-memory-sync@localhost}"
# Label used in commit messages. Left generic on purpose: a hostname here ends up
# in a public commit log.
TIMER_NAME="${SHARED_MEMORY_LABEL:-sync}"

export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

cd "$REPO"

# Never fail the whole run because the remote was briefly unreachable; the next
# tick will pick it up.
git pull --rebase --autostash >/dev/null 2>&1 || true

if [ -n "$(git status --porcelain)" ]; then
    git add -A

    # Guard: this store is written by agents, and `git add -A` will happily stage
    # a stray .env or an API key. Refuse the commit instead of publishing it.
    SECRETS_RE='(^|/)\.env($|[._])|API_KEY=|SECRET=|PASSWORD=|PASSWD=|TOKEN=|BEGIN [A-Z ]*PRIVATE KEY|sk-or-v1-[A-Za-z0-9]{10}|sk-[A-Za-z0-9]{20}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|AKIA[0-9A-Z]{12}|xox[baprs]-[A-Za-z0-9-]{10}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    # `|| true`: under `set -e` a no-match grep (exit 1) would abort the script
    # before it ever commits the clean tree.
    HITS=$(git diff --cached | grep -En "$SECRETS_RE" | head -5 || true)
    if [ -n "$HITS" ]; then
        echo "refusing to commit: staged content matches a secret pattern" >&2
        printf '%s\n' "$HITS" >&2
        echo "nothing committed; the staging area is left as-is for inspection" >&2
        echo "remove the offending content, then re-run this script" >&2
        exit 1
    fi

    git commit -m "sync: shared-memory $TIMER_NAME $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null || true
fi

if git push origin HEAD 2>/dev/null; then
    echo "synced rev=$(git rev-parse --short HEAD) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
    echo "push failed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    exit 1
fi
