#!/usr/bin/env bash
# One shard, one worktree, one runner. Stagger, cap, retry, log, mark.
# usage: worker.sh <shard-dir> <worktree> <delay-seconds> <runner> [runner-args...]
# <shard-dir> holds prompt.md (input) and gets log + status (output).
# The prompt is appended as the runner's last argument.
set -u

shard=$1; worktree=$2; delay=$3; shift 3
[ $# -gt 0 ] || { echo "worker.sh: no runner command" >&2; exit 2; }

exec >>"$shard/log" 2>&1
sleep "$delay"
cd "$worktree" || { echo "[fanout] cannot cd $worktree"; echo failed >"$shard/status"; exit 1; }

# Absent on a bare macOS box; without it a stalled runner hangs the whole fan-out.
cap=$(command -v timeout || command -v gtimeout || true)
[ -n "$cap" ] || echo "[fanout] no timeout(1) found, running uncapped"

prompt=$(cat "$shard/prompt.md")
attempt=1
while [ "$attempt" -le "${FANOUT_RETRIES:-3}" ]; do
  echo "[fanout] attempt $attempt: $*"
  if ${cap:+$cap ${FANOUT_TIMEOUT:-900}} "$@" "$prompt"; then
    echo ok >"$shard/status"
    exit 0
  fi
  echo "[fanout] attempt $attempt stalled or failed"
  attempt=$((attempt + 1))
  sleep 3
done

echo failed >"$shard/status"
exit 1
