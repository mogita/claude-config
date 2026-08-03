---
name: watch-pr-review
description: "Run right after pushing to a PR branch. Watches the auto-reviewer (Codex / chatgpt-codex-connector), waits for it to conclude (or a timeout), then auto-handles all its comments in one batch so push -> review -> fix -> push loops without the human relaying messages. Works in any repo; targets the PR of the current branch."
---

Turn a PR push into a closed feedback loop with the auto-reviewer. A push triggers Codex; watch it, then handle every comment in a single fix and a single push. The human only steps in for a clean pass, a timeout, or an ambiguous state.

## When to run

Right after any `git push` to a PR branch (the push triggers a fresh review). Reviews take roughly 7 minutes.

## Steps

1. **Start the watcher in the background** with `run_in_background: true`:

   ```
   bash "$SKILL_DIR/watch.sh" 7
   ```

   `$SKILL_DIR` is this skill's directory. `7` is the timeout in minutes (the human tweaks this). It resolves the repo + PR from the current branch, so no other args are needed. Append a PR number (`watch.sh 7 256`) to watch a specific PR without checking out its branch, e.g. an agent-authored PR whose branch lives in another worktree. It prints one verdict line when the reviewer settles or the timeout hits.

2. **Do not busy-wait.** The background process polls; you'll be notified when it exits. Don't poll GitHub yourself or start a second watcher (one at a time).

3. **Act on the verdict.** The last line is `RESULT since=<ts> codex=<state>` (or `TIMEOUT ...`), where the state is:
   - `clean` — the reviewer finished with no new comments.
   - `nN` — the reviewer posted N new items to handle.
   - `absent` — the reviewer isn't running on this repo (no sign within the grace window).
   - `pending` — only appears with `TIMEOUT` (didn't conclude in time).

   Then:
   - **`nN`** -> handle ALL new comments now, without asking the human, in ONE batch (do NOT push per comment — a push re-triggers the review):
     1. Fetch items to handle. `<ts>` is a hint, not the authority. **The authority is: every reviewer comment that has no reply from you.** Fetch all reviewer comments and filter to unreplied ones (a top-level comment whose id is not the `in_reply_to_id` of any of your replies), NOT just those created after `<ts>`. The `since` window misses comments in two common cases: a force-push/rebase whose first-pass review predates the watcher start, and a reviewer that posted several comments where only the later ones fall after `<ts>`. Always run the unreplied audit so none slip through.
        - Codex inline comments (author starts with `chatgpt-codex-connector`).
     2. **Handling process (canonical, applies to every review comment):** for each comment, either **address it with a fix or justify** why it needs none, and **reply to every comment** (don't leave any unanswered).
     3. Run the repo's checks (typecheck / tests / lint / e2e as the project requires).
     4. **One commit, one push** with all fixes.
     5. That push starts a fresh review, so **run this skill again** to continue the loop.
   - **`clean`/`absent`** -> the review passed with nothing to handle; tell the human briefly. Loop done.
   - **`STOP commits=N max=M`** -> the PR has churned past the commit cap handling reviews. Do NOT loop. Stop and tell the human the auto-loop is paused (too many review-handling commits); they should review/merge or raise the cap.
   - **`TIMEOUT`** -> the reviewer didn't conclude in the timeout. Stop and leave a short notice, e.g. "Codex still pending after 7m on PR #<n>; re-run watch-pr-review or check manually." Don't keep waiting silently.
   - **`NO_PR` / `NO_REPO`** -> current branch has no PR / not a GitHub repo. Report and stop.

## Lifecycle

- You own the watcher process; it exits on its own at a verdict or the timeout. If the human interrupts the loop, stop the background task.
- Exactly one watcher per push. When looping after handling comments, the prior watcher has already exited, so a new one after the next push is correct.
- To trigger a new review:
    - Push a new commit to the PR branch.
    - Add a new comment mentioning `@codex review` to trigger codex after a push.

## Detection notes

- Codex signals via its reaction on the PR **body**: 👀 = in progress, 👍 = done-clean, none = finished (check its new comments).
- "New" = created after the watcher started (i.e. after this push), so a prior review's comments are never re-handled.
- The timeout is a hard stop with a human-facing notice; a stuck/absent review shouldn't hang the loop.
