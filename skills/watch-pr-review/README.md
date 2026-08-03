# watch-pr-review

A Claude Code skill that turns a PR push into a closed review loop: after you push, it watches the auto-reviewer, and when it posts comments it handles them, pushes once, and watches again, so you don't have to relay messages back and forth.

## What it watches

One reviewer that runs automatically on every PR push:

- **Codex** (`chatgpt-codex-connector`): signals via a reaction on the PR body: 👀 = reviewing, 👍 = done with nothing to say, no reaction = finished and left comments.

It waits for it to finish under a timeout, then handles everything in a **single** commit + push (a push re-triggers the reviewer, so batching avoids spamming it).

## The loop

```
push ─▶ watch (codex) ─▶ verdict
                              │
      ┌── comments ────────-──┤
      │   handle all, one push ┘   (then watch again)
      │
      └── clean / timeout / stop ─▶ tell the human, stop
```

## Verdicts

- `RESULT ... codex=<state>`: state is `clean` (nothing), `nN` (N items to handle), or `absent` (reviewer not running on this repo).
- `STOP commits=N max=M`: the PR passed the commit cap; the loop pauses and asks a human to step in.
- `TIMEOUT ...`: the reviewer didn't finish in time; leaves a notice.
- `NO_PR` / `NO_REPO`: the current branch has no PR.

## Config (edit `watch.sh`)

- **Timeout**: passed as an argument, `watch.sh 7` (minutes). Default 7.
- **`POLL`**: seconds between checks (default 25). Higher = fewer GitHub API calls.
- **`MAX_COMMITS`**: stop auto-looping once the PR exceeds this many commits (default 30), a safety valve against endless back-and-forth.
- **`GRACE`**: seconds the reviewer can stay silent before it's treated as `absent` / not-running (default 90), so a reviewer that isn't set up on the repo doesn't hold the loop for the full timeout. Keep it above Codex's start latency (it can take >30s just to post its first 👀) or a slow-but-present reviewer gets falsely skipped.

## Files

- `SKILL.md`: the instructions Claude follows (how to run the watcher and handle each verdict, including the review-comment handling process).
- `watch.sh`: the background poller; resolves the repo + PR from the current branch, so it works in any repo. Needs an authenticated `gh` CLI.

## Notes

- Run it right after a push, so "new comments" (created after it starts) line up with the review your push triggered; a prior review's comments are never re-handled.
- It runs as a background process and prints one verdict line when done.
