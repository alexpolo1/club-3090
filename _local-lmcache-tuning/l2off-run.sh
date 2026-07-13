#!/usr/bin/env bash
# One-shot: recreate endpoint with L2 OFF, run the clean L1 retention test,
# then restore production (L2=1). Verifies each flip; aborts safely if L2!=0.
set -uo pipefail
cd /home/alex/club-3090
C=vllm-qwen36-27b-lmcache
SLUG=vllm/qwen-27b-dual-lmcache

echo "===================================================================="
echo "STEP 1 — recreate with LMCACHE_L2=0 ($(date '+%H:%M:%S'))"
echo "===================================================================="
# inline prefix (NOT exported) so only THIS switch.sh sees L2=0; the restore
# switch.sh below reads .env (LMCACHE_L2=1). shell env wins over .env (#425).
LMCACHE_L2=0 bash scripts/switch.sh "$SLUG" --force 2>&1 | tail -15

L2=$(docker exec "$C" printenv LMCACHE_L2 2>/dev/null || echo MISSING)
echo ">> container LMCACHE_L2=$L2"
if [ "$L2" = "0" ]; then
  echo "===================================================================="
  echo "STEP 2 — clean retention test, L2 OFF, fresh L1 ($(date '+%H:%M:%S'))"
  echo "  (Round 1 = true cold ~52s; Round 2 warm<8s = held in L1, cold = evicted)"
  echo "===================================================================="
  stdbuf -oL -eL bash scripts/lmcache-retention-test.sh 2>&1
  echo ">> test exit rc=$?"
else
  echo "!! ABORT: L2 did not flip to 0 (got '$L2'). Skipping test; restoring only."
fi

echo "===================================================================="
echo "STEP 3 — restore production (LMCACHE_L2=1) ($(date '+%H:%M:%S'))"
echo "===================================================================="
bash scripts/switch.sh "$SLUG" --force 2>&1 | tail -15
R=$(docker exec "$C" printenv LMCACHE_L2 2>/dev/null || echo MISSING)
echo ">> restored container LMCACHE_L2=$R  (expect 1)"
echo "== DONE $(date '+%H:%M:%S') =="
