#!/usr/bin/env bash
# Persistent monitor for the L2=0 orchestrator. Safe to leave running in tmux.
TASKOUT=/tmp/claude-1000/-home-alex-club-3090/97c1fc95-041a-4a51-aad4-6c60f82156e5/tasks/bacnmj267.output
OUT=/home/alex/club-3090/_local-lmcache-tuning/run3-L2off.log
echo "[watch] waiting for l2off-run.sh to finish... ($(date '+%H:%M:%S'))"
while pgrep -f l2off-run.sh >/dev/null 2>&1; do
  cp "$TASKOUT" "/home/alex/club-3090/_local-lmcache-tuning/run3-L2off.partial.log" 2>/dev/null
  sleep 15
done
cp "$TASKOUT" "$OUT" 2>/dev/null
echo "[watch] DONE $(date '+%H:%M:%S') — result preserved to _local-lmcache-tuning/run3-L2off.log"
echo "========================================================================"
cat "$OUT"
echo "========================================================================"
echo "[watch] leaving live tail open; Ctrl-C to exit, 'tmux detach' to background."
tail -F "$OUT" 2>/dev/null
