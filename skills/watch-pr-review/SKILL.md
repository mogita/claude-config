---
name: watch-pr-review
description: "Run right after pushing to a PR branch. Watches BOTH auto-reviewers (Codex / chatgpt-codex-connector and CodeRabbit / coderabbitai) in parallel, waits for both to conclude (or a shared timeout), then auto-handles all their comments in one batch so push -> review -> fix -> push loops without the human relaying messages. Works in any repo; targets the PR of the current branch."
---

Turn a PR push into a closed feedback loop with both auto-reviewers. A push triggers Codex and CodeRabbit at once; watch them in parallel (Promise.all: wait for BOTH to settle, or the shared timeout), then handle every comment from both in a single fix and a single push. The human only steps in for a clean pass, a timeout, or an ambiguous state.

## When to run

Right after any `git push` to a PR branch (the push triggers a fresh review from each reviewer). Reviews take roughly 7 minutes.

## Steps

1. **Start the watcher in the background** with `run_in_background: true`:

   ```
   bash "$SKILL_DIR/watch.sh" 7
   ```

   `$SKILL_DIR` is this skill's directory. `7` is the shared timeout in minutes (the human tweaks this; it cuts both reviewers). It resolves the repo + PR from the current branch, so no other args are needed. Append a PR number (`watch.sh 7 256`) to watch a specific PR without checking out its branch, e.g. an agent-authored PR whose branch lives in another worktree. It prints one verdict line when both reviewers settle or the timeout hits.

2. **Do not busy-wait.** The background process polls; you'll be notified when it exits. Don't poll GitHub yourself or start a second watcher (one at a time).

3. **Act on the verdict.** The last line is `RESULT since=<ts> codex=<state> coderabbit=<state>` (or `TIMEOUT ...`), where each state is:
   - `clean` — that reviewer finished with no new comments.
   - `nN` — that reviewer posted N new items to handle.
   - `absent` — that reviewer isn't running on this repo (no sign within the grace window).
   - `pending` — only appears with `TIMEOUT` (didn't conclude in time).

   Then:
   - **Any reviewer is `nN`** -> handle ALL new comments from BOTH reviewers now, without asking the human, in ONE batch (do NOT push per reviewer — a push re-triggers both reviews):
     1. Fetch new items created after `<ts>`:
        - Codex inline comments (author starts with `chatgpt-codex-connector`).
        - CodeRabbit inline comments (author starts with `coderabbitai`) **and** its latest review body. CodeRabbit puts real findings in the body, not just inline threads: parse EVERY collapsible section (`Actionable comments`, `🧹 Nitpick comments`, `⚠️ Outside diff range comments` — comments it couldn't post inline due to platform limits — and any others) and handle each. Do not enumerate a fixed allow-list of section names; treat any file/line finding in the body as a comment to handle. Body-only findings have no inline thread to reply to, so reply on the PR conversation or note the fix in the commit instead.
     2. **Handling process (canonical, applies to every review comment):** for each comment, either **address it with a fix or justify** why it needs none, and **reply to every comment** (don't leave any unanswered).
     3. Run the repo's checks (typecheck / tests / lint / e2e as the project requires).
     4. **One commit, one push** with all fixes.
     5. That push starts fresh reviews, so **run this skill again** to continue the loop.
   - **Both `clean`/`absent`** -> reviews passed with nothing to handle; tell the human briefly. Loop done.
   - **`STOP commits=N max=M`** -> the PR has churned past the commit cap handling reviews. Do NOT loop. Stop and tell the human the auto-loop is paused (too many review-handling commits); they should review/merge or raise the cap.
   - **`TIMEOUT`** -> at least one reviewer didn't conclude in the timeout. Stop and leave a short notice naming which is still `pending`, e.g. "CodeRabbit still pending after 7m on PR #<n>; re-run watch-pr-review or check manually." Don't keep waiting silently.
   - **`NO_PR` / `NO_REPO`** -> current branch has no PR / not a GitHub repo. Report and stop.

## Lifecycle

- You own the watcher process; it exits on its own at a verdict or the timeout. If the human interrupts the loop, stop the background task.
- Exactly one watcher per push. When looping after handling comments, the prior watcher has already exited, so a new one after the next push is correct.

## Detection notes

- Codex signals via its reaction on the PR **body**: 👀 = in progress, 👍 = done-clean, none = finished (check its new comments).
- CodeRabbit signals via its `CodeRabbit` commit status on the head SHA: `pending` = in progress, otherwise done (check its new comments + review nitpicks).
- "New" = created after the watcher started (i.e. after this push), so a prior review's comments are never re-handled.
- The timeout is a hard stop with a human-facing notice; a stuck/absent review shouldn't hang the loop.
