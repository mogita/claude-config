# watch-pr-review

A Claude Code skill that turns a PR push into a closed review loop: after you push, it watches both auto-reviewers, and when they post comments it handles them, pushes once, and watches again, so you don't have to relay messages back and forth.

## What it watches

Two reviewers that run automatically on every PR push:

- **Codex** (`chatgpt-codex-connector`): signals via a reaction on the PR body: 👀 = reviewing, 👍 = done with nothing to say, no reaction = finished and left comments.
- **CodeRabbit** (`coderabbitai`): signals via its `CodeRabbit` commit status: `pending` = reviewing, otherwise done (then it may have inline comments and/or a review body with folded findings: nitpicks, actionable comments, and "outside diff range" comments it couldn't post inline).

It waits for **both** to finish (like `Promise.all`) under one shared timeout, then handles everything from both in a **single** commit + push (a push re-triggers the reviewers, so batching avoids spamming them).

## The loop

```
push ─▶ watch (both reviewers) ─▶ verdict
                                     │
        ┌── comments ────────-───────┤
        │   handle all, one push ────┘   (then watch again)
        │
        └── clean / timeout / stop ─▶ tell the human, stop
```

## Verdicts

- `RESULT ... codex=<state> coderabbit=<state>`: states are `clean` (nothing), `nN` (N items to handle), or `absent` (reviewer not running on this repo).
- `STOP commits=N max=M`: the PR passed the commit cap; the loop pauses and asks a human to step in.
- `TIMEOUT ...`: a reviewer didn't finish in time; leaves a notice.
- `NO_PR` / `NO_REPO`: the current branch has no PR.

## Config (edit `watch.sh`)

- **Timeout**: passed as an argument, `watch.sh 7` (minutes, shared by both reviewers). Default 7.
- **`POLL`**: seconds between checks (default 25). Higher = fewer GitHub API calls.
- **`MAX_COMMITS`**: stop auto-looping once the PR exceeds this many commits (default 30), a safety valve against endless back-and-forth.
- **`GRACE`**: seconds a reviewer can stay silent before it's treated as `absent` / not-running (default 90), so a reviewer that isn't set up on the repo doesn't hold the loop for the full timeout. Keep it above a reviewer's start latency (Codex can take >30s just to post its first 👀) or a slow-but-present reviewer gets falsely skipped.

## Files

- `SKILL.md`: the instructions Claude follows (how to run the watcher and handle each verdict, including the review-comment handling process).
- `watch.sh`: the background poller; resolves the repo + PR from the current branch, so it works in any repo. Needs an authenticated `gh` CLI.

## Notes

- Run it right after a push, so "new comments" (created after it starts) line up with the review your push triggered; a prior review's comments are never re-handled.
- It runs as a background process and prints one verdict line when done.
