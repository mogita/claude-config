---
name: fanout-opencode
description: "Fan out mechanical, execution-only work to parallel opencode workers (sisyphus + deepseek), one git worktree each, while Claude Code stays the planner and reviewer. Use when the user says 'fanout', 'fan out to opencode', 'dispatch these shards', or has a repetitive multi-file job whose plan is already settled."
license: MIT
version: "1.0.0"
user_invocable: true
---

# fanout-opencode

You plan, shard, review and merge. opencode workers execute. One git worktree per shard, so concurrent writes cannot collide.

Depends on the `dispatch` skill for worker lifecycle (plan checklists, IPC questions, non-blocking monitoring). This skill adds sharding, worktree isolation, and a deterministic opencode backend.

## When not to use this

- The job needs judgment, design decisions, or reading unfamiliar code to decide what to do. Workers run a cheap model: give them decided work, not decisions.
- Shards would touch the same files. Re-shard, or run sequentially in your own session.
- One shard. Just use `/dispatch "have flash do X"`.

## Step 0: Preflight

Three checks, every invocation. Fail loudly, never silently degrade.

1. **opencode present** — `command -v opencode`. Missing: stop, tell the user to install it (`brew install sst/tap/opencode`), do nothing else.

2. **dispatch skill present** — check `~/.claude/skills/dispatch/SKILL.md` and `~/.agents/skills/dispatch/SKILL.md`. Missing: stop and ask the user to install it, naming it as this skill's hard dependency. Do not reimplement dispatch inline and do not proceed without it.

3. **`~/.dispatch/config.yaml` wired for opencode** — it must contain an `opencode` backend pointing at this skill's wrapper, plus a `flash` alias. If the file is absent, lacks the backend, or points somewhere else, show the user the exact block below and ask before writing it. Never silently rewrite their config; preserve every existing backend, model and alias.

```yaml
backends:
  # Wrapper takes the prompt as its last arg, so an appended --model <id> is harmless.
  opencode:
    command: >
      zsh ~/.claude/skills/fanout-opencode/oc-worker.sh

models:
  opencode-go/deepseek-v4-flash: { backend: opencode }

aliases:
  flash:
    model: opencode-go/deepseek-v4-flash
```

Agent, model, variant and timeout live in `oc-worker.sh` as explicit flags, not inherited from the machine's `opencode.json`. To change them for one run, set `OC_AGENT` / `OC_MODEL` / `OC_VARIANT` / `OC_TIMEOUT` in the worker's environment.

## Step 1: Shard

Write the shard list before touching git. A shard is one unit of work whose file set is disjoint from every other shard. State the shard count and the file set of each to the user, then proceed.

Prefer few fat shards over many thin ones: each worker pays roughly 60-90s of startup and model latency.

## Step 2: Worktree per shard

From the repo root, one worktree per shard, semantic branch prefix, never the user's name:

```bash
git worktree add ../$(basename $PWD)-fanout-1 -b feat/<slug>-1
```

## Step 3: Dispatch one worker per shard

Follow the `dispatch` skill's procedure, with three deltas:

- Keep every plan file and IPC directory under the **main repo** at `.dispatch/tasks/<shard-id>/`, so you watch one place instead of N. Reference them by **absolute path** in worker prompts, since the worker's cwd is its worktree.
- The generated wrapper script must `cd <worktree-abs-path> &&` before invoking the command.
- Use the `flash` alias.

Stagger spawns by ~3s. Simultaneous starts hit `database is locked` on opencode's shared SQLite store.

Each worker's prompt states: the shard's file list, the exact mechanical change, the absolute plan path to tick off, and "do not touch files outside your list."

## Step 4: Collect, review, merge, clean up

1. Read each plan file for completion. A worker that exits 1 has already retried 3x: report it, never quietly re-run.
2. `git -C <worktree> diff` per shard and review it yourself. The workers are cheap; the review is not optional.
3. Merge shard branches into the working branch, resolve, run the project's tests once over the merged result.
4. `git worktree remove <path>` per shard, and delete the shard branches.

Commit or push only if the user explicitly allowed it.

## Observed failure modes

- **Stall before first token**: roughly 1 in 3 runs hung with no output on the free tier. The wrapper caps each attempt at 900s and retries 3x. Never invoke `opencode run` bare in a fan-out.
- **Paid models live under the `opencode-go/` provider, not `opencode/`.** The `opencode/` prefix returns an opaque server error for paid ids, and `opencode models` lists only free ones even with a Go credential loaded.
- **`database is locked`**: concurrent session-store writes. Staggered spawns are the mitigation.
- **`.omo/` directories**: workers drop these in their cwd. Add to global gitignore, and do not let them reach a commit.
