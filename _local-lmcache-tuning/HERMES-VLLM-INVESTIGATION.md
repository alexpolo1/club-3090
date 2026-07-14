# Hermes ⇄ vLLM tool-calling investigation + coldcase fixes

**Date:** 2026-07-14 · **Rig:** .98 (club-3090 vLLM) + .96 (Hermes + coldcase) · **Branch:** `rig-local-tuning`
**Goal (user):** make Hermes (local qwen3.6-27b agent on .96) a reliable "local super coder" — i.e. good at using the vLLM `:8010` backend for autonomous agentic work.

---

## TL;DR
- Hermes is a **strong executor** of a handed-over fix (nailed the clue-graph bug), but an **unreliable autonomous investigator**: it intermittently loses tool calls and exits doing nothing.
- Root cause is a **tool-call FORMAT mismatch**, NOT model intelligence and NOT a vLLM server misconfig. On the failing turns the model emits GLM-style markup (`<arg_key>`, `<argument_channels>`) that neither vLLM's `qwen3_coder` parser nor Hermes's `<tool_call>`-only client fallback catches → zero tool calls → agent exits.
- **Still not fully reproduced in isolation.** The vLLM server parses tool calls perfectly in every direct test — **non-streaming 12/12 AND streaming 8/8**. Hermes sends a *clean* OpenAI request (standard `tools:[]`, no GLM instructions in the system prompt) with `stream:true`. So the trigger is something in Hermes's **exact** request/loop that my synthetic requests don't reproduce yet.
- **Next step:** capture Hermes's actual streaming RESPONSE (proxy now logs it) to see the exact leaked bytes in context, then fix at source.

---

## Coldcase bugs — ALL FIXED on live `/opt/coldcase` (.96)
tsx hot-reload service; each fix backed up next to the file.
1. **audio_type ENUM** — DB save crashed "Data truncated for column 'audio_type'". Fixed earlier (Hermes-assisted): `normalizeAudioType()` in `provider.ts` + applied at `generator.ts` INSERT and `multi_stage.ts` push sites. Backups `*.bak-audiofix-*`. Confirmed end-to-end (save reached).
2. **TTS `promisify is not defined`** (`generator.ts` `generateAudioTTS`, Fase 5/5) — function used `promisify`/`execFile` without the two `await import()` lines its sibling `generateMysteryImages` has. **I fixed it** (added the imports). Backup `generator.ts.bak-ttsfix-*`. tsc clean.
3. **Clue-graph saved 0 clues** (`clue_graph.ts` `buildClueGraph`) — LLM returns `required_doc_ids` as strings ("5","DOC 5"); the `typeof id === 'number'` filter dropped them all → every clue removed. **Hermes fixed it** (I handed it the diagnosis): coerce via `parseInt(String(id).replace(/\D/g,''),10)` + `Number.isFinite && >0`, plus a safety-net fallback to `generateFallbackClues` when 0 remain. Backup `clue_graph.ts.bak-cluefix-*`. tsc clean. **This was Hermes's strong showing.**
4. **Phase-counter inconsistency** — labels were `1/4, 2/4, 3/5, 4/5, 5/5` (stale `/4` from before the clue-graph "3a" phase was added → there are really 5 phases). **I fixed it** (`generator.ts:53,57` → `1/5`, `2/5`). Backup `generator.ts.bak-phasefix-manual-*`. This was the Hermes autonomous-investigation TEST bug (see below).

> Note: there's a stale duplicate tree `backend/src/src/ai/` — the LIVE served tree is `backend/src/ai/`. Hermes run 2 also edited the duplicate (harmless).

---

## Hermes agentic grading (against ground truth)

| Task | Diagnosis given? | Result |
|---|---|---|
| Clue-graph fix | YES (I handed root cause + fix) | ✅ **PASS** — correct edit, backup, honest tsc report. Indistinguishable from my work. |
| Phase-fix (no diagnosis), original prompt | NO | ❌ **FAIL** — narrated one line, 0 tool calls, exited. |
| Phase-fix, **tightened** "act don't narrate" prompt ×3 | NO | ⚠️ **1/3 PASS** (run2 perfect incl. correct 5-phase count + honest report; runs 1&3 lost tool calls and exited) |

**Conclusion:** the gap is tool-call *plumbing robustness*, not reasoning. When a tool call parses, Hermes reasons and edits correctly. When the model emits an unparseable format, the call is silently dropped and the loop ends.

---

## vLLM server verdict — NOT the problem
`:8010` launch (container `vllm-qwen36-27b-dual`, systemd `club3090-vllm-dual.service`):
```
--served-model-name qwen3.6-27b qwen3.6-27b-autoround --quantization auto_round --dtype float16
--tensor-parallel-size 2 --max-model-len 262144 --kv-cache-dtype fp8_e5m2 --max-num-seqs 4
--chat-template /etc/qwen-froggeric-chat-template.jinja --reasoning-parser qwen3
--default-chat-template-kwargs {"enable_thinking": false}
--enable-auto-tool-choice --tool-call-parser qwen3_coder --enable-prefix-caching --enable-chunked-prefill
```
Direct probes to `:8010` (`/tmp/toolprobe*.py` on .98):
- Simple tool request, non-stream: **6/6 parsed**
- Complex 5-tool "think then act" request, non-stream: **6/6 parsed**
- Same complex request, **stream:true**: **8/8 parsed**

So the server + `qwen3_coder` parser handle tool calls reliably in both modes. The failure is on the Hermes side / triggered by Hermes's exact request.

## Hermes architecture facts (from `~/.hermes-remote/hermes-agent-repo/`)
- Hermes does **client-side** tool-call parsing via per-format parsers in `environments/tool_call_parsers/` (`hermes`, `qwen`, `qwen3_coder`, `glm45`, `glm47`, `deepseek_v3`, `mistral`, `llama`, …). Default `tool_call_parser="hermes"`.
- **Two modes** (`environments/agent_loop.py` header): Phase 1 = OpenAI server type (vLLM parses natively, client parser ignored); Phase 2 = ManagedServer `/generate` raw text (client parser used). Against `:8010/v1` Hermes is in **Phase 1**.
- **The gap** (`agent_loop.py` ~line 268): the client-side fallback that rescues raw tool markup only fires when content contains **`<tool_call>`** — so GLM-style `<argument_channels>`/`<arg_key>` output falls through both vLLM's parser and this fallback → tool call lost.
- Captured Hermes request (`/tmp/hermes-proxy-capture.log` on .96): clean OpenAI `tools:[]`, standard Hermes system prompt (no GLM format text), `stream:true`. The leaked GLM tokens come from the **model's output**, not the prompt — so WHY the model emits GLM format under Hermes's exact request is the open question.

The leaked bytes seen in failing runs:
- run1: `<arg_key>thinking</arg_key><arg_value>Let me start by reading the log file…</arg_value>`
- run3: `<argument_channels>[{"type":"function_call","name":"search_files","arguments":{…}}]</argument_channels>`

---

## OPEN QUESTION / NEXT STEPS (resume here)
1. **Reproduce with Hermes's REAL request+response.** The proxy now tees the streaming **response** to the capture log. Repoint Hermes at the proxy and run the no-diagnosis phase-fix task a few times until a failing run occurs; read `/tmp/hermes-proxy-capture.log` RESPONSE section to see the exact bytes the model emits when it leaks. (My synthetic requests are 8/8 clean, so the trigger is in Hermes's exact tools/schemas/prompt or a later turn.)
2. Hypotheses to test with that data:
   - Does the leak correlate with the model trying to "think" (note run1 leaked `<arg_key>thinking`)? `enable_thinking:false` is set — maybe Hermes/model still attempts a thinking channel that derails tool formatting.
   - Is it multi-call (`argument_channels` = parallel calls)? Maybe the model emits a parallel-tool-call format the qwen3_coder parser mishandles mid-stream.
   - Does it happen only with Hermes's specific tool schemas (V4A patch tool, etc.)?
3. **Candidate fixes** (once source is known):
   - Broaden Hermes's client fallback (`agent_loop.py`) to try ALL parsers, not just on `<tool_call>` — closes the drop-the-call hole. (User deferred this "patch" option; may revisit.)
   - Correct the model→format mapping so the model emits `qwen3_coder`/`<tool_call>` format vLLM parses natively.
   - Test `enable_thinking:true` for agentic work (planning may reduce malformed first-turn output).

### To reproduce (commands)
```bash
# on .96 (proxy already running in tmux 'hproxy', tees req+resp to /tmp/hermes-proxy-capture.log)
ssh ai96
sed -i 's#http://192.168.1.98:8010/v1#http://127.0.0.1:9010/v1#g' ~/.hermes/config.yaml   # point at proxy
: > /tmp/hermes-proxy-capture.log
# run the no-diagnosis task (prompt at /tmp/phase-tight-task.txt), repeat until a run makes 0 edits:
hermes -z "$(cat /tmp/phase-tight-task.txt)" -t file,terminal --yolo
less /tmp/hermes-proxy-capture.log     # inspect REQUEST + RESPONSE of the failing run
# WHEN DONE, restore hermes to direct:
sed -i 's#http://127.0.0.1:9010/v1#http://192.168.1.98:8010/v1#g' ~/.hermes/config.yaml
```
Direct server probes (on .98): `python3 /tmp/toolprobe.py` (non-stream), `/tmp/toolprobe2.py` (complex), `/tmp/toolprobe_stream.py` (streaming).

---

## CURRENT STATE (as of wifi drop)
- **Hermes config: restored to direct `:8010`** — works standalone, NOT dependent on the proxy. Backups: `~/.hermes/config.yaml.bak-*` (cluefix, proxy, lmtest).
- **Proxy** running in tmux `hproxy` on .96 (`/tmp/hermes-proxy.py`, port 9010, tees req+resp). Idle unless Hermes is repointed at it.
- **tmux `hermes-work`** on .96 (cwd `/opt/coldcase`) = persistent workspace to resume in. Other live sessions: `hproxy`, plus stale `hcap`/`hermesclue`/`hermesphase` (can be killed).
- **vLLM:** `:8010` autoround (systemd service) is UP and healthy. `:8017` LMCache is DOWN (stopped overnight) — relaunch only if needed: `cd ~/club-3090 && bash scripts/switch.sh vllm/qwen-27b-dual-lmcache --force` (stops :8010).
- **coldcase:** all 4 bugs fixed on live `/opt/coldcase`, tsc clean, hot-reloaded.
- Probes + logs on .98: `/tmp/toolprobe*.py`. Capture on .96: `/tmp/hermes-proxy-capture.log`, run logs `/tmp/hermes-*-run*.log`, `/tmp/hermes-tight-summary.txt`.
