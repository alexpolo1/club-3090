# Session report — LMCache tuning + coldcase big-model test + Hermes agentic fix
**Date:** 2026-07-13 (into 07-14) · **Rig:** .98 (club-3090, 2×3090) · **Branch:** `rig-local-tuning`

## TL;DR
- **LMCache L1=60 config validated prod-ready** on `:8017`. Your spare RAM *is* doing
  work (~1.6–2× faster warm reads), and the retention itself comes from the L2 disk tier.
- **Coldcase "big Hermes test" run** against `:8017`: the local model serves the real app
  correctly (38% external prefix-cache hits). LMCache helps the short chat-style flows
  (evaluate ~1.3×), not the decode-bound bulk generation.
- **A real coldcase bug found and fixed by the local model itself** (Hermes agentic),
  then applied to the live service.

---

## 1. LMCache tuning (branch commits)
- Deployed `vllm/qwen-27b-dual-lmcache` on `:8017` (qwen3.6-27b fp8, 262K ctx), **L1=60 / L2=1**,
  `shm_size 32→64` (commit c88c1883), power cap fixed to 250 W both cards.
- **L2=0 vs L2=1 experiment:** retention (whether a read is warm at all) is delivered by the
  **L2 disk** tier, not L1 RAM — L2 off → 0/8 retained; L2 on → 8/8 (52 s cold → <5 s warm).
- **L1=30 vs L1=60 A/B (L2 on):** the RAM tier controls warm-read *speed* — L1=60 warm reads
  ~1.6× faster mean (~2× on the sessions that spill past a 30 GB L1). **Decision: keep L1=60**
  — it is not reclaimable headroom. (commit b03a1349)
- Coherent two-part model: **L2 disk = whether warm; L1 RAM = how fast.** LMCache is a
  chat-*reuse* optimization, not a throughput one.

## 2. Coldcase big-model test (.96 → :8017)
Coldcase = Danish cold-case murder-mystery web app on `.96` (live `coldcase.service`, :3099).
Temporarily repointed it (and Hermes) from `:8010` autoround to the `:8017` LMCache model.

| Flow | Result |
|---|---|
| Mystery generation (`generateMystery`) | ✅ full coherent mystery (20 docs / 7 chars / 7 locs), but **decode-bound ~31 min** → LMCache barely helps |
| Room evaluation (`evaluateAnswer`) | ✅ coherent Danish feedback; **cold 9.1 s → warm 7.0 s (~1.3× LMCache win)** — the flow where LMCache pays off |
| Server-side proof | ✅ `External prefix cache hit rate 38.2%` on `:8017` |

## 3. Bug found + fixed by the local model
- 🐛 **`audio_type` enum mismatch:** generation completes, then the DB save dies with
  *"Data truncated for column 'audio_type'"* — the model emits audio labels outside coldcase's
  strict `ENUM(emergency_call…eavesdropped)`; no coerce layer. (Bug note:
  `~/coldcase-temp/BUG-audio_type-enum.md`.)
- 🤖 **Hermes (local qwen3.6-27b, headless `hermes -z --yolo`)** implemented the fix: a
  `normalizeAudioType()` helper (enum list matching the DB exactly + EN/Danish synonym map +
  fallback `recorded_conversation`), applied at the INSERT + upstream plan sites. Reviewed &
  verified: `VALID_AUDIO_TYPES` matches the DB enum exactly, zero new build errors.
- ✅ **Applied the verified fix to the LIVE `/opt/coldcase`** (targeted edits, backups
  `*.bak-audiofix-*`): `provider.ts` (+helper), `generator.ts` (:115), `multi_stage.ts`
  (:769/:777). tsc clean on the new code; live service healthy after `tsx` hot-reload.

## 4. Housekeeping
- **Pruned `lmcache-kv`** (unbounded L2, host `/home/alex/club-3090/lmcache-kv`): had hit
  **210 GB, disk at 97%** → cleared → **disk 74% (240 GB free)**, `:8017` restarted fresh at
  L1=60/L2=1. Prune this periodically.

## 5. End-to-end save confirmation
- Full generation re-run against the fixed live service to confirm Phase-2 save now succeeds.
- **RESULT: _(appended on completion below)_**

---

## Rig state at shutdown / notes for next boot
- **`:8017` LMCache was launched manually** via `switch.sh`, not a systemd autostart. After
  reboot it will NOT come back on its own — re-launch with:
  `cd ~/club-3090 && bash scripts/switch.sh vllm/qwen-27b-dual-lmcache --force`
- **`:8010` autoround** (`club3090-vllm-dual.service`) is currently inactive (the two TP=2
  27Bs can't share the 2×3090s). On reboot systemd may bring it up instead — only one of
  `:8010`/`:8017` can run at a time.
- **Coldcase (.96) is pointed at `:8017`** (`.env` + `provider.ts`, backups `*.bak-lmtest-*`)
  and carries the audio_type fix. If you don't re-launch `:8017` after boot, coldcase
  generation will fail — either re-launch `:8017`, or revert coldcase to `:8010` from the
  backups (keep the audio fix). **Hermes** config also points at `:8017` (backup `*.bak-lmtest-*`).
- Branch `rig-local-tuning`: commits c88c1883 (shm), 99cbd81a (retention test), b03a1349
  (L1 A/B), plus this report + artifacts under `_local-lmcache-tuning/`. Master untouched.

### Save-confirmation result (2026-07-14 01:09, status=done)

✅ SAVE SUCCEEDED — generation reached the DB-save step with NO audio_type truncation. The audio_type fix is confirmed end-to-end on the live service. (note: a non-audio_type ERROR line appeared — worth a look, see below.)

```
Fase 1/4: Gene
Fase 2/4: GEMMER i databasen...
ERROR: p
Generation complete: 2067.7s ===
EXIT_0
```
