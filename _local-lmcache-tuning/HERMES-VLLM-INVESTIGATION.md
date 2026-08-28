# Hermes ⇄ vLLM tool-calling investigation + coldcase fixes

**Date:** 2026-07-14 · **Rig:** .98 (club-3090 vLLM `:8010`) + .96 (Hermes + coldcase) · **Branch:** `rig-local-tuning`
**Goal (user):** make Hermes (local qwen3.6-27b agent on .96) a reliable "local super coder" on the vLLM `:8010` backend.

---

## TL;DR — **ROOT CAUSE PROVEN: MTP n=3.** (2026-07-14) → filed as [club-3090 #710](https://github.com/noonghunna/club-3090/issues/710)

**`--speculative-config '{"method":"mtp","num_speculative_tokens":3}'` on the shipped dual default corrupts
tool calls on chained-agent workloads. The agent itself poisons the KV/prefix cache; it stays poisoned until restart.
Nothing in Hermes was broken. The tool-call parser is NOT involved. MTP also costs ~44% decode TPS on this rig.**

### The 2×2 A/B (the decisive experiment)
Per arm: boot → probe fresh → **3 real autonomous agent runs** → probe again → TPS.
Arms differ ONLY in `--speculative-config` and `--tool-call-parser`. Raw log: `AB-RESULTS.txt` (scratchpad).

| Arm | MTP | Parser | Probe fresh | Autonomous | **Probe post-agentic** | **Decode TPS** |
|---|---|---|---|---|---|---|
| **A — SHIPPED DEFAULT** | n=3 | qwen3_coder | 6/6 | 2/3 | **0/6** ❌ | 36.9 |
| B | n=3 | qwen3_xml | 6/6 | 2/3 | **0/6** ❌ | 36.1 |
| C | **off** | qwen3_coder | 6/6 | **3/3** | **6/6** ✅ | **65.1** |
| D | **off** | qwen3_xml | 6/6 | **3/3** | **6/6** ✅ | **66.0** |

- **MTP is the sole variable** (A≈B, C≈D). Parser swap changes nothing → the `qwen3_xml` half of
  mgabor3141's known workaround is **unnecessary**; MTP-off alone suffices.
- **The agent poisons its own cache**: every arm 6/6 fresh; only MTP arms collapse to 0/6 after 3 agent runs.
- **MTP-off is +79% decode TPS** (36.5 → 65.5). MTP here is negative on *both* correctness and speed.

Mechanism (inferred): MTP rejects draft tokens; if rollback doesn't invalidate the cached KV blocks, bad KV
persists in the prefix cache and is re-served to every later request sharing that prefix. Consistent with the
rollback family in `docs/UPSTREAM.md` (vllm#39931, #40831). **Not proven at vLLM internals level.**

### Fix
```bash
# remove --speculative-config from the compose -> correct AND ~79% faster
# arms kept (untracked) next to the shipped compose:
#   models/qwen3.6-27b/vllm/compose/dual/autoround-int4/ab-mtpoff-{coder,xml}.yml, ab-mtp-xml.yml
```
A `docker restart` is the *temporary* mitigation (clears the poisoned cache); MTP-off is the real one.

### What the failure looks like
The model stops emitting the template's XML tool format and instead:
- narrates naked calls — `search_files(target='files', path='/tmp', pattern='*')`
- leaks GLM-ish fragments — `<arg_key>think</arg_key>`, `<arg_value>`, `<arg_end>`
- occasionally degenerates entirely — `Klar.`, `Klik!`

vLLM's `qwen3_coder` parser finds no `<tool_call>` → returns zero `tool_calls` → Hermes's client fallback
(`agent_loop.py` ~line 268) only fires on `<tool_call>` → the call is silently dropped → the agent exits having done nothing.

### Operational fix (today)
```bash
docker restart vllm-qwen36-27b-dual     # ~80 s to healthy; tool calling restored
```
Verified: multi-turn chained agentic run (read file → list dir → report) succeeded cleanly post-restart.

---

## ❌ HYPOTHESES TESTED AND DISPROVEN (do not re-chase)

| Hypothesis | Verdict | Evidence |
|---|---|---|
| **GLM vs Qwen model/parser mismatch** | ❌ WRONG | Same model+server emits perfect `qwen3_coder` XML 20/20 under other prompts. Weights know the format. GLM fragments are a *symptom* of degeneration. |
| **Hermes's `skill_view(name='hermes-agent')` exemplar poisons the format** | ❌ **CONFOUND — my own false positive** | Looked airtight (0/8 orig vs 8/8 "fixed", 36/36 vs 0/20). **Interleaved randomized A/B destroyed it:** ORIG **8/8** and FIXED **8/8** on a cache miss; ORIG **0/8** and FIXED **0/8** on a cache hit. The "fix" only worked because *changing any bytes mints a new cache entry*. The edit was applied, disproven, then **reverted** — `prompt_builder.py` is stock. |
| **Chat template is wrong / mismatched with the parser** | ❌ NO | `froggeric` template teaches `<tool_call><function=…><parameter=…>`; server runs `--tool-call-parser qwen3_coder`. Matched. Template is a deliberate load-bearing fix (`patches.yml:238`) for 7 defects. |
| **`enable_thinking:false` conflicts with the template's mandatory `<think>` block** | ❌ NOT CAUSAL | Real conflict *exists* (template lines 74–102 demand `<think>`; line 258 prefills `<think>\n</think>` shut) and plausibly explains the `<arg_key>think</arg_key>` flavour — but `enable_thinking=true` did **not** fix it (0/10). |
| **Sampling / temperature** | ❌ NO | Hermes sends no sampling params → server default `temp 0.6, top_k 20` (`override_generation_config`). Forcing 0.2 → still 0/6. |
| **System-prompt length / attention dilution** | ❌ NO | 6000 chars of neutral filler → **6/6**. Length is irrelevant. |
| **`tool_choice` absent** | ❌ NO | Adding `tool_choice:auto` → 0/6. |
| **Prefix-cache *reuse* per se** | ❌ NO | A novel prompt sent 5× (1 miss + 4 hits) → **20/20**. Fresh blocks cache fine. It's *aged/degraded* blocks that break. |

**The one real signal:** any perturbation that forces a **new cache entry** (nonce at the *start* of the system prompt, even `"x\n"`) restored 8/8 — while a nonce at the *end* (prefix still hits) stayed 0/6. That's what pointed at the cache.

---

## Method lesson (worth keeping)

**Sequential-block A/B fabricated a fix that did not exist.** Running all-ORIG then all-FIXED let time-varying
server state masquerade as a prompt effect. The repo's own `drift_guard` warns about exactly this
(*"An asymmetric-restart harness fabricated a phantom -7%"* — `patches.yml:264`).
**Interleaved + randomized arms, with the known-good control re-run every session**, is what exposed it.
Also: a control that only ever passed *before* the change is not a control.

---

## Repo implications (worth an issue)

1. **Banked benchmark numbers may be contaminated.** `hermesagent-20` = **60%** and the **v21.3 template rejection**
   (30%, *"scenarios STALLING in multi-turn tool loops"*, `PROVENANCE.md`) are the exact signature of cache degradation.
   Multi-turn agents hold a stable prefix → they hit aged blocks hardest. **A template may have been rejected on contaminated evidence.**
   → Re-run those on a **freshly restarted** server before trusting either number.
2. **The `drift_guard` can't see this.** Its streaming tool-call smoke runs short/novel prompts on a fresh-ish server → always green,
   while real agents fail. It needs a **post-soak** tool-call check.
3. **`benchlocal-cli` hermesagent-20 shares the code path** (`sandboxes/hermes/Dockerfile:9` clones upstream `nousresearch/hermes-agent`).

---

## Coldcase bugs — ALL FIXED on live `/opt/coldcase` (.96)
tsx hot-reload service; each fix backed up next to the file; all tsc-clean.
1. **audio_type ENUM** — `normalizeAudioType()` in `provider.ts` + 3 call sites. Save confirmed end-to-end.
2. **TTS `promisify is not defined`** (`generator.ts` `generateAudioTTS`) — added the two `await import()` lines its sibling has.
3. **Clue-graph saved 0 clues** (`clue_graph.ts`) — string doc-ids (`"5"`, `"DOC 5"`) dropped by a `typeof id === 'number'` filter →
   every clue filtered out. Fixed (parseInt coercion + `generateFallbackClues` safety net). **Hermes wrote this fix; independently verified.**
4. **Phase-counter `1/4,2/4` vs `3/5,4/5,5/5`** → all `/5` (`generator.ts:53,57`).

> Live served tree is `backend/src/ai/`; `backend/src/src/ai/` is a stale duplicate.

---

## Hermes grading (updated)

| Task | Diagnosis given? | Result |
|---|---|---|
| Clue-graph fix | YES | ✅ **PASS** — correct edit, backup, honest tsc report. |
| Phase-fix, no diagnosis, original prompt | NO | ❌ FAIL (measured on a degraded cache — **not a fair test**) |
| Phase-fix, tightened prompt ×3 | NO | ⚠️ 1/3 (measured on a degraded cache — **not a fair test**) |
| Phase-fix, tightened prompt ×3, **fresh cache** | NO | ⏳ see `/tmp/hermes-tight-summary.txt` on .96 |

**The earlier grades understate Hermes.** Reasoning was never the bottleneck; the tool calls were being destroyed
by the server before they could parse.

---

## Next steps
1. **Determine the degradation trigger + time constant.** A single multi-turn run does *not* re-poison (tested). It took ~3 h of mixed use.
   Needs a soak that samples a fixed tool-call probe every N minutes until it flips → gives the real MTTF.
2. **A/B the config knobs on a fresh server** (each needs a restart):
   `--tool-call-parser qwen3_xml` (the fix UPSTREAM.md#113 already floats) · MTP off · `--no-enable-prefix-caching` · `--kv-cache-dtype auto`.
   On Ampere, fp8 KV is storage-only (AGENTS.md) — if it costs tool calling, it's a bad trade.
3. **File/attach to club-3090 #178** with this repro (same fingerprint).
4. **Re-run `hermesagent-20` post-restart** to get an uncontaminated number.

### Repro (self-contained)
```bash
# .98 — capture a real Hermes request first (proxy on .96 tmux 'hproxy' -> /tmp/hermes-proxy-capture.log)
cd <scratchpad>            # replay.py reads capture.log and replays the EXACT bytes
python3 replay.py 10 default        # degraded server: 0/10
docker restart vllm-qwen36-27b-dual && sleep 90
python3 replay.py 10 default        # fresh server: 8/8+
```
Scripts (scratchpad): `replay.py` (exact replay) · `ab_interleaved.py` (the harness that caught the confound) ·
`prefix_cache_test.py` (nonce-at-start vs end) · `miss_then_hit.py` · `render.py` (renders the jinja template + diffs prompts).

## CURRENT STATE
- **vLLM `:8010` restarted 2026-07-14 ~13:04 CEST — tool calling VERIFIED WORKING** (8/8 replay + live multi-turn agentic run).
- **Hermes config → direct `:8010`**; `~/.hermes-remote/hermes-agent-repo` **clean/stock** (disproven edit reverted).
- **coldcase:** 4 bugs fixed live, tsc clean, hot-reloaded; `generator.ts` restored to the FIXED baseline (`/tmp/generator.fixed.ts`).
- `:8017` LMCache DOWN (only one of :8010/:8017 can run).
- tmux on .96: `hproxy` (req+resp capture), `hermes-work`, `hermesfinal` (3-run autonomous test).
