---
name: weekly-report
description: Generate my weekly work update from this week's Claude Code sessions across all project directories. Use when I ask for a "weekly report", "weekly update", "what did I do this week", or run /weekly-report. Reads session logs, verifies outcomes on GitHub, and outputs in my Slack format.
---

Produce my weekly update by reading this week's Claude Code sessions across all project directories, then synthesizing them into the format below. Run it any weekday: it covers the current week (Monday through today) by default.

## Steps

1. Run the extractor to pull this week's user prompts from every main session:
   ```
   python3 ~/.claude/skills/weekly-report/extract_sessions.py
   ```
   For a specific range use `--start YYYY-MM-DD --end YYYY-MM-DD`, or `--last-week` for the previous Mon to Sun. If output exceeds the tool limit it is saved to a file; read that file in full.

2. Read the extracted prompts and reconstruct what actually happened. Group work by theme (a migration, an SDK fix, a feature), not by session or by day. Prompts ending in "coke!!" mean a commit plus push plus PR happened; "Zero!!" means merged to main. "merged"/"pr" in the text are signals, not proof.

3. Verify every "done" claim before asserting it. Use `gh` to confirm PR and release state, do not trust the prompt alone (replace `YOUR_ORG` with your GitHub org):
   ```
   gh pr view <num> --repo YOUR_ORG/<repo> --json title,state,mergedAt
   gh pr list --repo YOUR_ORG/<repo> --author "@me" --state all --limit 15 --json number,title,state,mergedAt,updatedAt
   ```
   If `gh` fails with a TLS or x509 certificate error, that is the sandbox intercepting HTTPS: retry the same command with the sandbox disabled. A PR that is OPEN goes under Planned/next, not Done.

4. Separate what shipped from what is planned or merely communicated. Only verified, completed work goes in the themed Done sections. Everything in flight (open PRs, filed-but-unfixed issues, next steps, things discussed with the team) goes under "Planned / communicated / next".

5. Exclude work whose message timestamps fall outside the week even if the session file is long-lived (a session can span weeks; the extractor already filters by date, so trust its dates).

## Output format (strict)

- Slack mrkdwn. Bold is a single asterisk: `*Header*`, never `**`.
- Bullets with `-`.
- No decorative punctuation anywhere: no em dashes, en dashes, spaced hyphens, or smart quotes. Use commas, colons, and periods.
- Links are markdown `[label](url)` (replace `YOUR_ORG` / `YOUR_WORKSPACE` with your GitHub org and Linear workspace slug):
  - PRs: `[repo#123](https://github.com/YOUR_ORG/repo/pull/123)`
  - Linear ticket, in parentheses right after the PR link: `([TICKET-123](https://linear.app/YOUR_WORKSPACE/issue/TICKET-123))`
  - Omit the PR link if there is none. Omit the Linear link if there is none. Never leave a bare or broken link.
- Inline code in backticks for identifiers, filenames, commands, versions of symbols (e.g. `ChannelConfig`, `oasdiff`).
- Structure mirrors the team's weekly update: a `*Weekly Update (<Mon date> to <Fri/today date>)*` title, then bold theme headers each with bullets, then a `*Planned / communicated / next:*` block, then one short closing paragraph that names the through-line of the week (the root cause or pattern behind the separate items). Keep the closer to two sentences, no fluff.

The structural reference is a teammate's weekly update, reproduced below as a fictional example. Match its shape (theme headers, bullets with inline ticket/PR links, an Ongoing/next block, a short reflective closer). The content is illustrative only; replace it with your real work:

```
*Weekly Update*

*Query performance & stability,* shipped a batch of perf fixes:
- Fixed a slow bulk-delete path (TICKET-101) it was doing full-partition scans; split the OR-predicate delete into two index-seekable ones, plus a production migration to codify the missing indexes.
- Joined the denormalization index migrations, part of the p99 latency push; two more services queued next.
- Denorm rollout for one service done (TICKET-102)
- A customer-blocking fix in review (TICKET-103) I applied a manual workaround in production to unblock them.
- Fixed the data import problem for another customer
*Support backlog*, got a real picture and a plan:
- Pulled a year of the queue into a burn-down: intake is outpacing closes, so it's still growing.
- Met with a colleague to understand the queue end-to-end, and posted a two-option proposal (short task force vs. quota-based rotation) to the team for feedback before we pick.
*AI assistant*, landing page & tutorials:
- Merged the website/builder skill so we can generate site updates, tutorial videos, and a short working demo, feeding the landing page (TICKET-104) and a tutorial.
*Cross-functional:*
- Added myself to CODEOWNERS for the API spec to unblock the PR pipeline.
- Meetings, 1:1, architecture discussions
*Ongoing/next:*
- Land the customer import fix
- Continue the denorm rollout across remaining services.
- Synthesize team feedback on the support-rotation proposal; pick a model and roll it out
- Dig into search architecture
- Lead the AI assistant effort
The pattern is getting clear: the support backlog, the query latency, and our cost constraints are mostly the same root problem showing up in different places. My focus is to keep shipping the immediate fixes while moving from reacting per-customer toward a few generic, proactive solutions.
```

## Notes

- Present the final report inside a fenced code block so the raw mrkdwn is copy-pasteable.
- Linear URLs follow `https://linear.app/YOUR_WORKSPACE/issue/<ID>` (the slug suffix is optional). Infer ticket IDs from PR titles like `[TICKET-123] ...`; flag any ID you inferred rather than read directly so I can double-check.
- Exclude activities in your personal GitHub repositories (`github.com/YOUR_PERSONAL_USERNAME`), they are not part of the weekly report.
