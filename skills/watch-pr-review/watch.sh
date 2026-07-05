#!/usr/bin/env bash
# Watch BOTH PR auto-reviewers in parallel and print one combined verdict when
# both have settled (or on a shared timeout). Meant to run in the background right
# after a push to a PR branch. Detects, per reviewer, whether the review is still
# running, finished clean, or finished with comments to handle.
#
#   Codex (chatgpt-codex-connector[bot]): reaction on the PR body
#     👀 eyes = in progress | 👍 +1 = done clean | none+new comments = has comments
#   CodeRabbit (coderabbitai[bot]): its "CodeRabbit" commit status on the head SHA
#     pending = in progress | success/failure = done -> then new comments/reviews?
#
# Per-reviewer state token: pending | clean | absent | nN  (nN = N new items to handle)
# Verdict: "RESULT since=<ts> codex=<state> coderabbit=<state>"
#          "TIMEOUT since=<ts> codex=<state> coderabbit=<state>" | NO_PR | NO_REPO
# Usage: watch.sh [minutes] [pr-number]
#   minutes:   shared timeout across both reviewers (default 7)
#   pr-number: watch this PR explicitly instead of the current branch's PR. Lets you
#              watch an agent-authored PR whose branch is checked out in another worktree.
set -u

CODEX_PREFIX="chatgpt-codex-connector"
CR_PREFIX="coderabbitai"
MINUTES="${1:-7}"
PR_ARG="${2:-}"
POLL=25
GRACE=90 # seconds a reviewer can stay silent before it's treated as not-running (absent); must exceed a reviewer's START latency (Codex can take >30s just to post its first 👀), else a slow-but-present reviewer is falsely skipped

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
MAX_COMMITS=30
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
seen_cr=0

echo "watching repo=$repo pr=$pr sha=${sha:0:7} since=$since timeout=${MINUTES}m (codex + coderabbit)"

# count of a reviewer's NEW items (inline comments [+ reviews]) created after start
codex_new() {
  gh api "repos/$repo/pulls/$pr/comments" --paginate \
    -q ".[] | select((.user.login|startswith(\"$CODEX_PREFIX\")) and .created_at > \"$since\") | .id" 2>/dev/null | grep -c .
}
cr_new() {
  local c r
  c=$(gh api "repos/$repo/pulls/$pr/comments" --paginate \
    -q ".[] | select((.user.login|startswith(\"$CR_PREFIX\")) and .created_at > \"$since\") | .id" 2>/dev/null | grep -c .)
  r=$(gh api "repos/$repo/pulls/$pr/reviews" --paginate \
    -q ".[] | select((.user.login|startswith(\"$CR_PREFIX\")) and .submitted_at > \"$since\") | .id" 2>/dev/null | grep -c .)
  echo $((c + r))
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

  # ---- CodeRabbit ("CodeRabbit" commit status; fall back to a check-run) ----
  crstate=$(gh api "repos/$repo/commits/$sha/status" \
    -q '.statuses[] | select(.context|test("coderabbit";"i")) | .state' 2>/dev/null | head -1)
  if [ -z "$crstate" ]; then
    crstate=$(gh api "repos/$repo/commits/$sha/check-runs" \
      -q '.check_runs[] | select(.name|test("coderabbit";"i")) | (if .status=="completed" then (.conclusion // "done") else "pending" end)' 2>/dev/null | head -1)
  fi
  if [ -n "$crstate" ]; then seen_cr=1; fi
  if [ "$crstate" = "pending" ]; then
    cr=pending
  elif [ -n "$crstate" ]; then
    m=$(cr_new)
    if [ "${m:-0}" -gt 0 ]; then cr="n$m"; else cr=clean; fi
  elif [ "$elapsed" -ge "$GRACE" ]; then
    cr=absent
  else
    cr=pending
  fi

  # ---- settle when BOTH are non-pending, or on the shared timeout ----
  if [ "$cx" != pending ] && [ "$cr" != pending ]; then
    echo "RESULT since=$since codex=$cx coderabbit=$cr"
    exit 0
  fi
  if [ "$now" -ge "$deadline" ]; then
    echo "TIMEOUT since=$since codex=$cx coderabbit=$cr"
    exit 0
  fi
  sleep "$POLL"
done
