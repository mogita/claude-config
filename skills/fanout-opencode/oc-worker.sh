#!/bin/zsh
# Flags are explicit, not inherited from opencode.json, so a worker behaves the same on every machine.
: ${OC_AGENT:=sisyphus}
: ${OC_MODEL:=opencode-go/deepseek-v4-flash}
: ${OC_VARIANT:=max}
: ${OC_TIMEOUT:=900}

# This model intermittently stalls before its first token and occasionally dies on
# "database is locked" when several workers start at once, so cap and retry.
prompt="${@[-1]}"
for i in 1 2 3; do
  timeout $OC_TIMEOUT opencode run --auto --agent $OC_AGENT --model $OC_MODEL --variant $OC_VARIANT --dir "$PWD" "$prompt" && exit 0
  print -u2 "[oc-worker] attempt $i stalled or failed, retrying"
  sleep 3
done
print -u2 "[oc-worker] giving up after 3 attempts"
exit 1
