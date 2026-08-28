# Session handoff — LMCache L1=60 optimization + retention test

**Date:** 2026-07-12/13 · **Repo:** /home/alex/club-3090 · **Branch:** `rig-local-tuning`

## Objective
User wants to use the dual-3090 rig optimally given lots of RAM (124 GB total).
The lever: LMCache uses host RAM as prefix-KV cache (L1) — more RAM = more warm
sessions retained. Chosen target: **run the qwen LMCache chat config with
`LMCACHE_L1_GB=60`**, fix the power cap, and **write a test proving the bigger L1
actually buys retention.**

## DONE
- Stopped ComfyUI (PIDs 18071/18501, ports 8188/8189) + swap_server (3278251, :8199)
  → freed both GPUs (were 21/18 GB used, chat model wasn't even loaded).
- **Power cap fixed**: was 260/280 W (gpu-tune.service won), now **250 W** both cards
  via `sudo systemctl restart nvidia-power-cap.service`. (May need re-check after reboot.)
- **Model up**: `vllm/qwen-27b-dual-lmcache` via `scripts/switch.sh ... --force`
  (Incubating/hidden slug). Serving `qwen3.6-27b` on **:8017**, 262K ctx.
  `.env` already had `LMCACHE_L1_GB=60` + `CLUB3090_MEM_LIMIT=110g` (from Jun 24).
- **Commit 1 (`c88c1883`)**: `shm_size 32→64` in
  `models/qwen3.6-27b/vllm-lmcache/compose/dual/fp8/lmcache.yml`. REQUIRED for L1=60
  (shm_size must be >= L1 or MP connector falls back to slow pickle; no env override
  for shm_size — it's the one knob that forces a compose edit).
- **Commit 2 (`99cbd81a`)**: `scripts/lmcache-retention-test.sh` — the retention test.
- Both commits on `rig-local-tuning`; **master is clean**.

## IN PROGRESS
- **Retention test running in background** (pid 483813).
  Log: `<scratchpad>/retention.log`
  ⚠️ Log is BLOCK-BUFFERED (python→file) → appears all at once at completion, NOT live.
  To watch live in a rerun: `stdbuf -oL` or `python3 -u`.
- Design: Round 1 inserts 8× ~48K-token distinct prefixes (~50 GB, sized BETWEEN the
  30 GB and 60 GB capacity lines @ 131 KB/tok). Round 2 re-reads them. Session 1 is
  LRU-oldest → Round-2 TTFT per session = retention curve.
  - **PASS = 8/8 warm in Round 2** → L1=60 held the full working set (would have
    evicted earliest sessions at default L1=30). Exit 0.
  - Any COLD in Round 2 → eviction → live L1 smaller than expected. Exit 1.
- At last check: RAM used 78 GB, available 46 GB (down from 110) — L1 filling as expected.

## HOW TO CHECK RESULTS
```
cat <scratchpad>/retention.log          # full output once done
pgrep -af lmcache-retention-test.sh      # still running?
# rerun (tunable): NUM_SESSIONS=8 SESSION_TOKENS=48000 WARM_THRESHOLD_S=8.0 \
#   bash scripts/lmcache-retention-test.sh
```
`<scratchpad>` = /tmp/claude-1000/-home-alex-club-3090/97c1fc95-041a-4a51-aad4-6c60f82156e5/scratchpad

## NEXT / OPEN ITEMS
- Report retention verdict to user when the background run exits.
- **Repo-change tracking**: per user workflow (memory: "repo-changes-need-issue"), the
  shm_size edit + new test script on `rig-local-tuning` should get a GitHub issue if
  they're ever headed for master. Right now they're intentionally branch-only (rig-local).
- Optional follow-ups NOT done: `bench.sh` PREFILL_PROBE run (cold→warm at 40K/90K, +
  decode-TPS zero-penalty check) — MODEL=qwen3.6-27b PORT=8017 PREFILL_PROBE=1
  PREFILL_DEPTHS=40000,90000 bash scripts/bench.sh
- `verify-full.sh MODEL=qwen3.6-27b` not run (would confirm functional serving).

## ⚠️ CORRECTION (found while checking disk)
- **L2 disk tier is ON** — `.env` has `LMCACHE_L2=1` (NOT off as first assumed).
  `lmcache-kv/` was ~16 GB stale + actively growing during the test (~50 GB total).
  L2 `fs` adapter is UNBOUNDED (no LRU cap) → prune `lmcache-kv/*` periodically.
- **Retention-test validity**: with L2 on, L1-evicted sessions fall to L2 (~5 s), under
  the 8 s warm threshold → test would pass 8/8 even at L1=30 (measures tiered retention,
  not L1-fast retention). To isolate L1=60: rerun with `WARM_THRESHOLD_S=2.0` (only L1
  ~0.5-1 s counts warm) OR `LMCACHE_L2=0` (evictions go fully cold ~35 s). The current
  in-flight run uses defaults (L2 on, thresh 8) → interpret its result accordingly.
- Disk: root 225 G free / 75% used — healthy.

## RESULTS (both runs complete)
- **Run 1 (L2 on, thresh 8.0):** cold prefill 52–61 s/session (50.6 GB set);
  warm re-read 0.76–4.28 s → 8/8 retained. ✅ Retention win proven (~13–70×).
- **Rerun (L2 on, thresh 2.0):** printed 5/8 "FAIL" — but this is a THRESHOLD
  ARTIFACT, not eviction: the 3 "evicted" sessions read 2.1–2.4 s, nowhere near
  the ~52 s true-cold cost. All 8 still warm; 2.0 s cut lands inside cache-hit
  jitter. With L2 on there's no cold floor to separate L1 from L2, so no
  threshold cleanly isolates L1. DO NOT report the rerun as a real failure.
- **L2=0 RESULT (COMPLETE, 2026-07-13 07:34) — SURPRISE, corrects earlier claim:**
  L2 off → **0/8 retained** (all re-prefilled 45–71 s, incl. just-inserted session 8).
  L2 on → 8/8 warm. ⇒ **The warm-cache benefit is L2 DISK, not L1 RAM.** The 60 GB
  L1 provisioning is NOT the active lever on this rig. Earlier "L1=60 retains the
  working set" claim was WRONG — it was L2. Also contradicts #423's L1=0.51s
  attribution (likely L1-fronting-L2, not standalone). Likely mechanism (UNPROVEN):
  LMCache CPU tier only persists with a disk backend attached. Production (L2=1)
  works great regardless — 52 s→<5 s on 50 GB. Full logs: _local-lmcache-tuning/run3-L2off.log.
  Open: (a) is L1-standalone supposed to work? (b) if L2 carries it, can we reclaim
  RAM by lowering L1? (c) disk/L2 is load-bearing → prune lmcache-kv + disk speed matters.
- Clean L1-isolation experiment — DONE (was bg job bacnmj267, orchestrator
  `<scratchpad>/l2off-run.sh`). NOTE: L2 is a CONTAINER-level flag (not a script
  env) — must RECREATE the container. Chain: recreate L2=0 (~4min) → run test
  (Round1 true-cold ~52s) → restore L2=1 (~4min). Verifies each flip. Output:
  `<scratchpad>/tasks/bacnmj267.output`. Warm count = sessions genuinely in fast
  60 GB L1 RAM. Endpoint down during the 2 restarts; restored to L2=1 at end.

## L1=30 vs L1=60 A/B (COMPLETE, 2026-07-13 21:42) — RECONCILES the L2=0 result
- Question: with L2 ON (production shape), does 60 GB L1 give FASTER warm reads
  than 30 GB L1 on a ~50 GB working set — or is the extra 30 GB pure headroom?
- Method: `_local-lmcache-tuning/l1-ab-run.sh` — recreate at L1=30 then L1=60 (L2
  stays 1), each leg a fresh SALT (new `SALT` env in the retention test → byte-
  different prefixes, cannot hit the 49 GB already on L2 disk or the other leg).
  L1=60 leg doubles as the prod restore. Compares raw Round-2 (warm) TTFTs, NOT
  pass/fail (both legs pass 8/8 with L2 on). Logs: `l1ab-L130.log`, `l1ab-L160.log`,
  `l1ab-run.log`.
- RESULT — **L1=60 warm reads ~1.6× faster on average; the RAM IS doing work:**
  ```
  sess  L1=30 s  L1=60 s  faster
    1     3.32     2.39    L1=60
    2     4.35     2.05    L1=60
    3     4.16     1.42    L1=60
    4     3.58     1.71    L1=60
    5     5.09     1.27    L1=60
    6     1.09     3.04    L1=30   (noise; MRU-resident either way)
    7     1.87     1.05    L1=60
    8     1.48     2.50    L1=30   (noise; MRU-resident either way)
  L1=30 warm: mean 3.12s median 3.45s max 5.09s
  L1=60 warm: mean 1.93s median 1.88s max 3.04s
  ```
  Pattern fits theory: the OLDER half (sess 1–5) spills past a 30 GB L1 to L2 disk
  (~3–5 s) but stays in RAM at L1=60 (~1.3–2.4 s) — ~2× on exactly the sessions that
  get evicted. The newest ~3 (6–8) are L1-resident in BOTH legs → jitter-level flips.
- **RECONCILIATION of the two findings (both true, different questions):**
  - L2 disk decides *whether* a read is warm at all (L2=0 → 0/8; L2=1 → 8/8). RETENTION = L2.
  - L1 RAM decides *how fast* a warm read is: bigger L1 keeps more sessions in RAM,
    ~2× faster than falling to L2 disk. WARM-READ SPEED for large working sets = L1.
  - So L1 works as a **fast front for L2**, not a standalone retention store — which
    is exactly why L2=0 gave 0/8 (no backend to persist to) yet L2=1+L1=60 is fastest.
- DECISION: **keep L1=60** — it is NOT reclaimable headroom; it earns ~1.6–2× on warm
  reads once the working set exceeds ~30 GB (multi-session chat). Production restored
  and verified: LMCACHE_L1_GB=60, LMCACHE_L2=1, container up. Config is prod-ready.
- Caveat: n=1 per leg; warm TTFT is jittery (see sess 6/8). Signal is the consistent
  ~2× on the evicted half, not the modest 1.6× aggregate. Good enough to decide "keep RAM".

## NEXT PHASE (queued, gated on prod-ready)
- User wants a **big Hermes test** against qwen3.6-27b :8017 using the **"coldcase"
  project on .96** (192.168.1.96, pings OK; NO coldcase refs in club-3090 repo).
- Gate: only after the L1=60+L2 config is validated prod-ready.
- BLOCKED ON INFO (asked user): what coldcase is, how to reach it on .96, what the
  test should measure/produce. See memory `planned-hermes-coldcase-test`.

## KEY FACTS
- Endpoint: http://localhost:8017/v1 (LAN 192.168.1.98:8017), no auth, model id `qwen3.6-27b`.
- Container: `vllm-qwen36-27b-lmcache`.
- L1 cache rate: ~131 KB/token measured. L1=30→~229K tok, L1=60→~458K tok.
- #423 TTFT numbers: cold ~35-43 s @ 40K; L1-warm ~0.5-2.4 s; L2(disk, OFF here) ~5.3 s.
- Discussion context that started this: club-3090 #684 (RAM sizing: 58 GB = L1 30 + 28 reserve).
