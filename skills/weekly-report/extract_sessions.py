#!/usr/bin/env python3
"""Extract user prompts from Claude Code sessions for the current week.

Usage:
  python3 extract_sessions.py                      # Monday of this week .. today
  python3 extract_sessions.py --start 2026-06-15 --end 2026-06-19
  python3 extract_sessions.py --last-week          # previous Mon..Sun

Prints, per main session file, the user prompts timestamped in range, each
prefixed with its date, so the calling agent can reconstruct what happened.
Subagent/workflow transcripts are skipped (internal noise). Timestamps in the
logs are UTC; the week window is computed in local time, so late-night-local
work may land a day off. Good enough for a weekly summary.
"""
import json, glob, os, sys, datetime

def monday(d):
    return d - datetime.timedelta(days=d.weekday())

today = datetime.date.today()
start = monday(today)
end = today

args = sys.argv[1:]
if "--last-week" in args:
    start = monday(today) - datetime.timedelta(days=7)
    end = start + datetime.timedelta(days=6)
if "--start" in args:
    start = datetime.date.fromisoformat(args[args.index("--start") + 1])
if "--end" in args:
    end = datetime.date.fromisoformat(args[args.index("--end") + 1])

keep_days = set()
d = start
while d <= end:
    keep_days.add(d.isoformat())
    d += datetime.timedelta(days=1)

NOISE = (
    "Base directory for this skill",
    "This session is being continued",
    "Continue from where you left off",
    "Caveat: The messages below were generated",
    "<local-command",
)

base = os.path.expanduser("~/.claude/projects")
files = []
for p in glob.glob(base + "/*/*.jsonl"):
    if "/subagents/" in p:
        continue
    if datetime.date.fromtimestamp(os.path.getmtime(p)) < start:
        continue  # last activity before the window
    files.append(p)

def proj(p):
    return p.split("/projects/")[1].split("/")[0]

print("WEEK: %s .. %s  (%d session files scanned)\n" % (start, end, len(files)))

for f in sorted(files, key=lambda x: (proj(x), os.path.getmtime(x))):
    out = []
    for line in open(f, errors="ignore"):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "user":
            continue
        c = o.get("message", {}).get("content")
        ts = o.get("timestamp", "")
        text = None
        if isinstance(c, str):
            text = c
        elif isinstance(c, list):
            parts = [x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text"]
            if parts:
                text = " ".join(parts)
        if not text:
            continue
        t = text.strip()
        if not t or t.startswith("<") or any(t.startswith(n) for n in NOISE):
            continue
        if ts[:10] not in keep_days:
            continue
        out.append("  %s  %s" % (ts[:10], t.replace("\n", " ")[:300]))
    if not out:
        continue
    print("=" * 80)
    print("PROJECT: " + proj(f) + "   FILE: " + os.path.basename(f))
    print("-" * 80)
    print("\n".join(out))
