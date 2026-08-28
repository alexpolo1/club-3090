#!/usr/bin/env bash
# ===========================================================================
# l1-ab-run.sh — does the 60 GB of L1 RAM actually buy anything, or is it
# pure headroom the L2 disk makes moot?
# ---------------------------------------------------------------------------
# The L2=0 experiment already showed L2 disk (not L1 RAM) delivers RETENTION.
# This asks the sharper question with L2 left ON (production shape): at a
# 50 GB working set, does a 60 GB L1 give FASTER warm reads than a 30 GB L1?
#
#   - If L1 RAM serves reads:  L1=60 holds all 8 sessions -> every Round-2 read
#     is L1-fast; L1=30 spills the oldest ~3 to L2 -> those read slower.
#   - If L1 read is inert (the L2=0=0/8 hypothesis): both legs read everything
#     from L2 -> identical Round-2 TTFTs -> the extra 30 GB is reclaimable.
#
# Method: for L1 in {30, 60}, recreate the container (L2 stays 1), run the
# retention test with a UNIQUE salt (fresh cache keys — cannot hit the 49 GB
# already on L2 disk, nor the other leg's blocks), capture the Round-2 curve.
# The L1=60 leg doubles as the restore to production. Compares raw Round-2
# TTFTs (NOT pass/fail — with L2 on both legs "pass" the 8 s threshold).
# ===========================================================================
set -uo pipefail
cd /home/alex/club-3090
C=vllm-qwen36-27b-lmcache
SLUG=vllm/qwen-27b-dual-lmcache
DIR=_local-lmcache-tuning
STAMP=$(date +%s)

run_leg() {
  local L1="$1"
  local log="$DIR/l1ab-L1${L1}.log"
  echo "===================================================================="
  echo "LEG L1=${L1}GB  (L2 stays 1) — $(date '+%H:%M:%S')"
  echo "===================================================================="
  # inline prefix: only THIS switch.sh sees the override; L2 comes from .env (=1).
  LMCACHE_L1_GB="$L1" bash scripts/switch.sh "$SLUG" --force 2>&1 | tail -8
  local got_l1 got_l2
  got_l1=$(docker exec "$C" printenv LMCACHE_L1_GB 2>/dev/null || echo MISSING)
  got_l2=$(docker exec "$C" printenv LMCACHE_L2   2>/dev/null || echo MISSING)
  echo ">> container LMCACHE_L1_GB=$got_l1  LMCACHE_L2=$got_l2  (want L1=$L1 L2=1)"
  if [ "$got_l1" != "$L1" ] || [ "$got_l2" != "1" ]; then
    echo "!! ABORT leg: env did not match. Skipping test for L1=$L1." | tee "$log"
    return 1
  fi
  # Unique salt per leg => byte-different prefixes => guaranteed-cold Round 1,
  # no contamination from L2 disk or the other leg.
  SALT="abL1${L1}-${STAMP}" stdbuf -oL -eL \
    bash scripts/lmcache-retention-test.sh 2>&1 | tee "$log"
  echo ">> leg L1=$L1 done, log=$log"
}

echo "== L1 A/B START $(date '+%H:%M:%S')  salt-stamp=$STAMP =="
run_leg 30
run_leg 60   # <- also the restore to production (.env L1=60)

# Safety net: the RAM gate reads MemAvailable once (no settle-retry); if a slow
# reclaim after the L1=30 teardown tripped it, production could be left DOWN.
# Retry the plain (.env L1=60) restore up to twice before giving up.
for attempt in 1 2; do
  FL1=$(docker exec "$C" printenv LMCACHE_L1_GB 2>/dev/null || echo MISSING)
  up=$(docker ps --filter "name=$C" --format '{{.Names}}')
  [ "$FL1" = "60" ] && [ -n "$up" ] && break
  echo "!! production not at L1=60/up (got L1=$FL1, up='$up') — restore retry $attempt after 20s"
  sleep 20
  bash scripts/switch.sh "$SLUG" --force 2>&1 | tail -6
done

# Final production sanity.
FL1=$(docker exec "$C" printenv LMCACHE_L1_GB 2>/dev/null || echo MISSING)
FL2=$(docker exec "$C" printenv LMCACHE_L2   2>/dev/null || echo MISSING)
echo ">> FINAL production state: LMCACHE_L1_GB=$FL1  LMCACHE_L2=$FL2  (want 60 / 1)"

# ---- Compare the two Round-2 curves --------------------------------------
echo "===================================================================="
echo "COMPARISON — Round-2 (warm) TTFT per session, L1=30 vs L1=60"
echo "===================================================================="
python3 - "$DIR/l1ab-L130.log" "$DIR/l1ab-L160.log" <<'PY'
import re, sys, statistics as st
def curve(path):
    # Round-2 lines look like: "  session  1: TTFT   2.13s  WARM  retained"
    out=[]
    try:
        txt=open(path,encoding="utf-8").read()
    except FileNotFoundError:
        return out
    seg=txt.split("Round 2",1)
    body=seg[1] if len(seg)>1 else ""
    for m in re.finditer(r"session\s+(\d+):\s+TTFT\s+([\d.]+)s", body):
        out.append((int(m.group(1)), float(m.group(2))))
    return out
a=curve(sys.argv[1]); b=curve(sys.argv[2])
da=dict(a); db=dict(b)
print(f"{'sess':>4} {'L1=30 s':>9} {'L1=60 s':>9}   {'faster':>8}")
for s in sorted(set(da)|set(db)):
    x=da.get(s); y=db.get(s)
    xs=f"{x:.2f}" if x is not None else "  --"
    ys=f"{y:.2f}" if y is not None else "  --"
    fast = ""
    if x is not None and y is not None:
        fast = "L1=60" if y < x*0.85 else ("L1=30" if x < y*0.85 else "~tie")
    print(f"{s:>4} {xs:>9} {ys:>9}   {fast:>8}")
def summ(v):
    xs=[t for _,t in v]
    return f"n={len(xs)} mean={st.mean(xs):.2f}s median={st.median(xs):.2f}s max={max(xs):.2f}s" if xs else "no data"
print("\nL1=30 warm:", summ(a))
print("L1=60 warm:", summ(b))
if a and b:
    ma,mb=st.mean(t for _,t in a),st.mean(t for _,t in b)
    if mb < ma*0.85:
        print(f"\nVERDICT: L1=60 warm reads ~{ma/mb:.1f}x faster => the RAM IS doing work.")
    elif ma < mb*0.85:
        print(f"\nVERDICT: L1=30 faster (unexpected) — investigate.")
    else:
        print("\nVERDICT: warm reads ~identical => extra 30 GB L1 is HEADROOM (reclaimable);"
              " L2 disk is serving the reads either way.")
PY
echo "== L1 A/B DONE $(date '+%H:%M:%S') =="
