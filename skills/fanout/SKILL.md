---
name: fanout
description: "Fan out mechanical, execution-only work to parallel background coding agents, one git worktree each, while you stay the coordinator: you plan, shard, review and merge. Workers default to opencode, and any headless coding CLI (claude, codex, cursor agent, ...) can be swapped in per run or in config. Use when the user says 'fanout', 'fan out', 'shard this', or has a repetitive multi-file job whose plan is already settled."
license: MIT
version: "2.0.0"
user_invocable: true
---

# fanout

You are the coordinator, and you stay central for the whole run. You decide, shard, bootstrap, dispatch, review, merge and commit. Workers only execute work you already decided, inside isolated worktrees. Nothing a worker produces reaches the working tree except through a patch you apply yourself.

Doing part of the work yourself is expected, not a violation: keep every shard that needs judgment, fan out only the mechanical remainder. A worker gets decided work, never a decision.

This skill is self-contained. Do not route it through `dispatch` or any other delegation skill: their "never do the work yourself" framing is the opposite of this one.

## When not to use this

- The job needs judgment, design decisions, or reading unfamiliar code to decide what to do.
- Shards would touch the same files. Re-shard, or run it yourself.
- One shard. Just do it, or run a single background worker directly.

## Config and runners

`~/.fanout-skill/config.json` holds three keys and nothing else:

```json
{
  "cli": "opencode",
  "model": "opencode/deepseek-v4-flash-free",
  "agent": "Sisyphus - ultraworker"
}
```

Those are also the defaults. On the first run, or whenever the file is missing a key, write the missing keys and keep every key already there. Say one line about what you wrote, then continue. This is the skill's own config, not the user's shell config: no need to ask before creating it.

The user can name a different CLI, model or agent in the invocation ("fan this out with codex", "use opus for the workers"). That wins for the run and does **not** touch the config. Persist it only if they ask for a new default.

A runner is any coding CLI that runs headless in one shot. `worker.sh` already `cd`s into the worktree and appends the prompt as the last argument, so a runner command is just: non-interactive flag + auto-approve flag + (optionally) an explicit working-dir flag. Assemble it from config:

| `cli` | runner command |
|-------|----------------|
| opencode | `opencode run --auto --agent <agent> --model <model> --variant max --dir <worktree>` |
| claude | `env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE claude -p --dangerously-skip-permissions` (ignores `model` and `agent`, the CLI picks its own) |
| codex | `codex exec --full-auto -C <worktree> --model <model>` |
| cursor | `agent -p --force --workspace <worktree> --model <model>` |

Model ids are CLI-specific. Changing `cli` without changing `model` is the one misconfiguration that looks like it should work and does not.

**The `agent` value must be exactly what the CLI's own agent list prints**, not the name you know it by. `opencode agent list` prints `Sisyphus - ultraworker`; `--agent sisyphus` does not resolve, and opencode does not fail on it, it warns `agent "..." not found. Falling back to default agent` and silently runs whatever `default_agent` points at. Any shard log containing that warning ran on an unknown agent: treat its output as unverified and re-run it.

Why the pretty name is the id: `oh-my-openagent` rewrites every agent key to its display name before opencode sees the config (`AGENT_DISPLAY_NAMES` in the plugin bundle), so the config key `sisyphus` is registered as `Sisyphus - ultraworker`. Same for the rest: `Hephaestus - Deep Agent`, `Prometheus - Plan Builder`, `Atlas - Plan Executor`, `Sisyphus-Junior`, `Metis - Plan Consultant`, `Momus - Plan Critic`, `Athena - Council`. Lowercase ones (`oracle`, `librarian`, `explore`, `multimodal-looker`) map to themselves. A `displayName` under `agents.<key>` in `~/.config/opencode/oh-my-openagent.json` overrides it, which is why `opencode agent list` is the authority and this table is only a shortcut.

`--model` beats the plugin's per-agent model pin, so the coordinator controls both the agent and the model. Nothing is inherited from the machine.

Any CLI not in the table: read its `--help` for those three flags, then smoke-test the exact command once (`<runner> "print the name of this repo and stop"`) before fanning out. A runner that has never run on this machine is unverified, and three workers failing on a bad flag costs more than one 60s check.

Pick the cheapest model that can execute the shard. Cheap is the point: if a shard needs an expensive model, it probably needed you.

## Step 0: Preflight

Fail loudly, never silently degrade.

1. Load config, filling defaults for anything missing.
2. Runner CLI on PATH, and authenticated. Missing or unverified: stop and tell the user.
3. Configured `agent` appears verbatim in the CLI's agent list (`opencode agent list`). This costs no model call and is the only thing standing between a typo and three shards silently running as the wrong agent. Not listed: stop, show the list, ask.
4. Repo is clean enough that you can tell worker output from pre-existing edits. Uncommitted work in the shard's file set: stop and ask.
5. State the runner, model, agent and shard count to the user before spawning anything.

## Step 1: Shard

Write the shard list before touching git. A shard is one unit of work whose file set is **disjoint** from every other shard's, including yours.

Prefer many narrow shards over few fat ones. One class, one module, one error category per shard. Narrow shards are unambiguous to specify, and the specification is where the real cost sits. Startup latency (~60-90s per worker) is paid in parallel and is not a reason to merge shards.

Cap concurrency at what the machine and the provider tolerate. Queue the rest.

## Step 2: Worktree per shard, and make the gate run

Every shard has a **gate**: the command that proves the change is correct (`tsc --noEmit`, the test file, a lint rule). No gate, no shard.

```bash
main=$(git rev-parse --show-toplevel)
git worktree add --detach "$main/../$(basename $main)-fanout-1" HEAD
```

Detached, no branch: workers never commit, so there is nothing to name or delete later.

**A fresh worktree cannot run the gate.** It has no `node_modules`, no `.venv`, no `.env`. Workers that cannot verify their own output are cheap models editing blind, which defeats the point of using them. Symlink what the gate needs from the main worktree:

```bash
[ -e "$wt/node_modules" ] || ln -s "$main/node_modules" "$wt/node_modules"   # and .env, .venv, vendor/, whatever the gate reads
```

The guard matters: `ln -s dir existing_dir` silently creates `existing_dir/dir` instead of failing, and you find out when the gate can't resolve an import. Only ever link paths the worktree does not already have, which is exactly the gitignored ones.

Then **run the gate yourself in the first worktree and confirm it executes.** Not "passes": a pre-existing failure list is fine, and is often exactly the work. It must run. Only dispatch once it does. Symlinked dep dirs are read-only in practice for typecheck and test; a shared build-cache dir (`target/`, `.next/`) will lock-contend instead, so copy or omit those.

## Step 3: Plan file per shard, prompt per shard

State lives outside the repo entirely, so it never shows up in `git status`, needs no ignore rule, and cannot be swept up by a worktree removal. One run dir, one subdir per shard:

```bash
fanout=~/.fanout-skill/tasks/<repo-name>-<job-slug>
mkdir -p "$fanout/<shard-id>"
```

`<repo-name>-<job-slug>` because this directory is global: two repos, or two jobs in one repo, must not land in the same run dir.

The plan file is the contract, and it is the whole reason this works. Write `$fanout/<shard-id>/plan.md` as a checklist where every item is one concrete, verifiable edit:

```markdown
# <shard-id>

- [ ] src/foo.ts:41 — `parseUser` returns `User | null`, add the null branch before `.name`
- [ ] src/foo.ts:88 — same pattern
- [ ] Run the gate: `bunx tsc --noEmit src/foo.ts`. Not done until it is clean.
```

Write `$fanout/<shard-id>/prompt.md` with, in this order: the absolute plan path, the exact file list, the gate command, and these rules verbatim:

- Tick each item `[x]` in the plan file as you finish it. Do not batch the ticks.
- Do not touch any file outside the list. Anything else you notice, write it under `## Notes` in the plan file.
- Do not commit, do not branch, do not stash. Leave your changes in the working tree.
- If an instruction is wrong, do the correct thing, tick the item, and append `deviation: <what and why>` on the line below.
- If an item is genuinely blocked, mark it `[!]` with one line of why, then continue with the remaining items.

That deviation clause is load-bearing: it is how a wrong instruction from you comes back as a verified correction instead of 50 lines of confidently wrong code.

## Step 4: Dispatch

One background call per shard. The delay argument staggers the starts, so you can fire all of them at once and let each sleep its own offset:

```bash
bash ~/.claude/skills/fanout/worker.sh "$fanout/shard-1" "$wt1" 0 <runner command>
bash ~/.claude/skills/fanout/worker.sh "$fanout/shard-2" "$wt2" 3 <runner command>
```

Stagger by ~3s. Simultaneous starts collide on some CLIs' shared SQLite session store. Per-attempt timeout and retry count: `FANOUT_TIMEOUT` (default 900s), `FANOUT_RETRIES` (default 3). Each shard gets a `log` and a `status` file (`ok` / `failed`) in its shard dir.

While they run, do your own shard. You are not a monitor.

## Step 5: Collect, review, merge, clean up

1. Read every plan file. Unchecked items, `[!]` markers and `deviation:` lines are the signal, not the log tail. A `failed` status means the runner already retried: report it, never quietly re-run.
2. Review the diff yourself, per shard: `git -C "$wt" diff`. The workers were cheap; the review is not optional.
3. Merge by scoped patch, not by branch. Restricting the patch to the shard's declared file list is what enforces the scope contract, rather than trusting the worker to have honoured it:

```bash
git -C "$wt" status --porcelain          # outside the file list and your own bootstrap symlinks: an escape, report it
git -C "$wt" add -A -- <shard file list>
git -C "$wt" diff --cached --binary -- <shard file list> | git apply -
```

Disjoint file sets never conflict, and signing stays entirely in your hands. Never let a worker commit: it runs outside your git identity and will either produce unsigned commits or hang on a credential prompt in a background process.

4. Run the gate once over the merged result, in the main worktree.
5. `git worktree remove --force "$wt"` per shard (`--force` because the shard's index is dirty), then `rm -rf "$fanout"`. Keep the run dir instead if a shard failed: its log is the only record of why.

Commit or push only if the user explicitly allowed it.

## Failure modes

- **Stall before first token.** Roughly 1 in 3 runs on free-tier endpoints hang with no output, and a burst of rapid calls makes it near-certain: throttling presents as a stall, not as an error. `worker.sh` caps and retries; never invoke a runner bare in a fan-out. If every shard stalls at once, it is the tier, not the prompt.
- **Retry after partial work.** A retried attempt restarts in a worktree the previous attempt already edited. The ticked plan file is what keeps it idempotent, which is another reason items must be concrete.
- **`database is locked`.** Concurrent session-store writes. Staggered spawns are the mitigation.
- **Tool droppings.** Workers leave `.omo/`, `.aider*`, `.codex/` and similar in their cwd. The scoped `add -A -- <files>` in step 5 keeps them out of the merge.
- **opencode specifics.** Paid models live under the `opencode-go/` provider, not `opencode/`; the `opencode/` prefix returns an opaque server error for paid ids, and `opencode models` lists only free ones even with a Go credential loaded.
