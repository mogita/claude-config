#!/usr/bin/env bash
# Watch the PR auto-reviewer and print one verdict when it has settled (or on a
# timeout). Meant to run in the background right after a push to a PR branch.
# Detects whether the review is still running, finished clean, or finished with
# comments to handle.
#
#   Codex (chatgpt-codex-connector[bot]): reaction on the PR body
#     👀 eyes = in progress | 👍 +1 = done clean | none+new comments = has comments
#
# Reviewer state token: pending | clean | absent | nN  (nN = N new items to handle)
# Verdict: "RESULT since=<ts> codex=<state>"
#          "TIMEOUT since=<ts> codex=<state>" | NO_PR | NO_REPO
# Usage: watch.sh [minutes] [pr-number]
#   minutes:   timeout for the review (default 7)
#   pr-number: watch this PR explicitly instead of the current branch's PR. Lets you
#              watch an agent-authored PR whose branch is checked out in another worktree.
set -u

CODEX_PREFIX="chatgpt-codex-connector"
MINUTES="${1:-7}"
PR_ARG="${2:-}"
POLL=25
GRACE=90 # seconds the reviewer can stay silent before it's treated as not-running (absent); must exceed Codex's START latency (it can take >30s just to post its first 👀), else a slow-but-present reviewer is falsely skipped

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || repo=""
[ -n "$repo" ] || {
  echo "NO_REPO"
  exit 0
}
if [ -n "$PR_ARG" ]; then
  pr="$PR_ARG"
else
  pr=$(gh pr view --json number -q .number 2>/dev/null) || pr=""
fi
[ -n "$pr" ] || {
  echo "NO_PR"
  exit 0
}

# Circuit-breaker: stop the auto-loop once a PR has churned through too many
# commits handling review comments. Uses total PR commit count as the proxy.
MAX_COMMITS=10
commits=$(gh pr view "$pr" --json commits -q '.commits | length' 2>/dev/null || echo 0)
if [ "${commits:-0}" -gt "$MAX_COMMITS" ]; then
  echo "STOP pr=$pr commits=$commits max=$MAX_COMMITS"
  exit 0
fi

sha=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null) || sha=""

since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start=$(date +%s)
deadline=$((start + MINUTES * 60))
seen_eye=0

echo "watching repo=$repo pr=$pr sha=${sha:0:7} since=$since timeout=${MINUTES}m (codex)"

# count of the reviewer's NEW inline comments created after start
codex_new() {
  gh api "repos/$repo/pulls/$pr/comments" --paginate \
    -q ".[] | select((.user.login|startswith(\"$CODEX_PREFIX\")) and .created_at > \"$since\") | .id" 2>/dev/null | grep -c .
}

while :; do
  now=$(date +%s)
  elapsed=$((now - start))

  # ---- Codex (PR-body reaction) ----
  reactions=$(gh api "repos/$repo/issues/$pr/reactions" \
    -q ".[] | select(.user.login|startswith(\"$CODEX_PREFIX\")) | .content" 2>/dev/null)
  if echo "$reactions" | grep -qx -- "+1"; then
    cx=clean
  elif echo "$reactions" | grep -qx -- "eyes"; then
    seen_eye=1
    cx=pending
  else
    n=$(codex_new)
    if [ "${n:-0}" -gt 0 ]; then
      cx="n$n"
    elif [ "$seen_eye" = 1 ]; then
      cx=clean # eye appeared then cleared with no comments
    elif [ "$elapsed" -ge "$GRACE" ]; then
      cx=absent
    else
      cx=pending
    fi
  fi

  # ---- settle when the reviewer is non-pending, or on the timeout ----
  if [ "$cx" != pending ]; then
    echo "RESULT since=$since codex=$cx"
    exit 0
  fi
  if [ "$now" -ge "$deadline" ]; then
    echo "TIMEOUT since=$since codex=$cx"
    exit 0
  fi
  sleep "$POLL"
done
