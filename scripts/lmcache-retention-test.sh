#!/usr/bin/env bash
# ===========================================================================
# lmcache-retention-test.sh — prove L1 *retention*, not just warm-cache-works.
# ---------------------------------------------------------------------------
# scripts/bench.sh's PREFILL_PROBE salts every request FRESH, so it measures
# COLD prefill and (by re-sending) the immediate warm hit — but it never fills
# past L1 capacity, so it can't show what a BIGGER L1 buys. That "bigger L1"
# question is the whole reason to spend host RAM on LMCACHE_L1_GB.
#
# This wrapper closes that gap. It inserts N distinct large prefixes whose
# combined KV exceeds a small L1 but fits a large one, then re-reads them:
#
#   Round 1 (cold insert):  send N distinct ~SESSION_TOKENS prefixes once each,
#                           small max_tokens so each request COMPLETES (LMCache
#                           only banks a session's blocks on completion — see
#                           lmcache.yml "run to COMPLETION" note). Fills L1.
#   Round 2 (retention read): re-send the SAME N prefixes in the SAME order.
#                           Session 1 is the LRU-oldest, so Round-2 TTFT per
#                           session IS the retention curve:
#                             - L1 big enough  -> every session WARM (retained)
#                             - L1 too small   -> earliest sessions COLD (evicted)
#
# PASS = all N warm in Round 2. On THIS rig (LMCACHE_L1_GB=60) a set sized
# between the 30 GB and 60 GB capacity lines should be 8/8 warm — and would
# have evicted its earliest sessions at the default L1=30.
#
# Prereq: the LMCache compose is serving (vllm/qwen-27b-dual-lmcache). Bring it
# up with scripts/switch.sh first; confirm the served id at /v1/models.
#
# Env vars (all optional):
#   PORT               Endpoint port. Default: 8017 (the slug's default_port)
#   URL                Full base URL. Default: http://localhost:${PORT}
#   MODEL              Served model id. Default: qwen3.6-27b
#                      (a WRONG id is a silent 404 — confirm via /v1/models)
#   NUM_SESSIONS       Distinct prefixes to insert. Default: 8
#   SESSION_TOKENS     Approx prompt tokens per prefix. Default: 48000
#                      (8 x 48K ~= 384K tok ~= 50 GB @ 131 KB/tok: inside a
#                       60 GB L1, past a 30 GB L1 — the discriminating window)
#   WARM_THRESHOLD_S   TTFT at/below this = warm hit. Default: 8.0
#                      (L1 rehydrate is sub-second..~few s per #423; cold
#                       re-prefill is ~35-45 s — 8 s cleanly separates them)
#   KV_KB_PER_TOKEN    LMCache cache rate for the GB math. Default: 131 (measured)
#   PROBE_MAX_TOKENS   Output cap per request (just enough to complete). Default: 8
#
# Exit 0 = all sessions retained (PASS). Exit 1 = one or more evicted.
# ===========================================================================
set -euo pipefail

PORT="${PORT:-8017}"
URL="${URL:-http://localhost:${PORT}}"
MODEL="${MODEL:-qwen3.6-27b}"
NUM_SESSIONS="${NUM_SESSIONS:-8}"
SESSION_TOKENS="${SESSION_TOKENS:-48000}"
WARM_THRESHOLD_S="${WARM_THRESHOLD_S:-8.0}"
KV_KB_PER_TOKEN="${KV_KB_PER_TOKEN:-131}"
PROBE_MAX_TOKENS="${PROBE_MAX_TOKENS:-8}"

command -v python3 >/dev/null || { echo "Fix: python3 not found on PATH." >&2; exit 2; }

python3 - "$URL" "$MODEL" "$NUM_SESSIONS" "$SESSION_TOKENS" \
           "$WARM_THRESHOLD_S" "$KV_KB_PER_TOKEN" "$PROBE_MAX_TOKENS" <<'PY'
import json, random, string, sys, time, urllib.request
# Community rigs run non-UTF-8 locales; a piped stdout defaults to ASCII (repo
# convention: pin utf-8 on both read and write).
sys.stdout.reconfigure(encoding="utf-8")

URL, MODEL, N, STOK, WARM, KVKB, PMAX = sys.argv[1:]
N = int(N); STOK = int(STOK); WARM = float(WARM); KVKB = float(KVKB); PMAX = int(PMAX)


def tokenize_count(text):
    """Exact prompt-token count via vLLM's /tokenize; None if unavailable."""
    for path in ("/tokenize", "/v1/tokenize"):
        try:
            body = json.dumps({"model": MODEL, "prompt": text}).encode()
            req = urllib.request.Request(URL + path, data=body,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r).get("count")
        except Exception:
            continue
    return None


def rand_words(rng, n):
    # Seeded random words tokenize near ~1 token/word and do NOT BPE-compress
    # the way repeated filler does — so the prefix actually fills L1.
    return [''.join(rng.choice(string.ascii_lowercase)
            for _ in range(rng.randint(3, 9))) for _ in range(n)]


def make_prefix(idx, target_tokens):
    """Deterministic per idx -> byte-identical across rounds -> real cache hit.
       Calibrated against the live tokenizer so token count is ~on target."""
    rng = random.Random(idx * 7919 + 13)
    sample = " ".join(rand_words(random.Random(idx), 400))
    c = tokenize_count(sample)
    tpw = (c / 400.0) if c else 1.4          # tokens-per-word for this stream
    n_words = max(64, int(target_tokens / tpw))
    header = f"SESSION-{idx:03d}-anchor-{idx * 7919}\n"
    body = header + " ".join(rand_words(rng, n_words))
    return body + "\n\nReply with only: OK"


def run_once(prompt):
    """Stream a completion; return (ttft_seconds, prompt_tokens). Mirrors
       bench.sh's streaming-TTFT method (first content delta = TTFT)."""
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": PMAX,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(f"{URL}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t = time.time(); ttft = None; ptok = 0
    with urllib.request.urlopen(req, timeout=600) as r:
        for line in r:
            line = line.decode("utf-8", errors="ignore").rstrip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            choices = chunk.get("choices") or []
            if choices:
                delta = choices[0].get("delta", {})
                content = delta.get("content") or delta.get("reasoning_content")
                if content and ttft is None:
                    ttft = time.time() - t
            usage = chunk.get("usage")
            if usage:
                ptok = usage.get("prompt_tokens", ptok)
    if ttft is None:
        ttft = time.time() - t
    return ttft, ptok


print(f"LMCache L1 retention probe -> {URL}   model={MODEL}")
print(f"  sessions={N}  target_tokens/session~={STOK}  "
      f"warm_threshold={WARM:.1f}s  kv={KVKB:.0f}KB/tok\n")

# Build all prefixes ONCE (identical objects reused across both rounds).
print("Building calibrated haystacks (one /tokenize probe each)...")
prefixes = [make_prefix(i, STOK) for i in range(1, N + 1)]

print("\nRound 1 - cold insert (fills L1):")
actual = []
for i, pfx in enumerate(prefixes, 1):
    ttft, ptok = run_once(pfx)
    actual.append(ptok)
    print(f"  session {i:2d}: cold TTFT {ttft:7.2f}s  (prompt_tokens={ptok})")

tot = sum(actual)
gb = tot * KVKB / 1e6
cap30 = 30e9 / (KVKB * 1e3)
cap60 = 60e9 / (KVKB * 1e3)
print(f"\n  inserted ~{tot} tokens ~= {gb:.1f} GB of L1")
print(f"  capacity lines: L1=30 -> ~{cap30/1000:.0f}K tok (~30 GB), "
      f"L1=60 -> ~{cap60/1000:.0f}K tok (~60 GB)")
if gb < 32:
    print("  NOTE: inserted set < ~32 GB — too small to distinguish L1=30 from 60."
          " Raise NUM_SESSIONS/SESSION_TOKENS.")
elif gb > 58:
    print("  NOTE: inserted set > ~58 GB — may exceed even L1=60. Lower it a touch.")

print("\nRound 2 - retention read (same prefixes; warm = retained):")
warm = 0
for i, pfx in enumerate(prefixes, 1):
    ttft, _ = run_once(pfx)
    hit = ttft <= WARM
    warm += 1 if hit else 0
    tag = "WARM  retained" if hit else "COLD  evicted / re-prefill"
    print(f"  session {i:2d}: TTFT {ttft:7.2f}s  {tag}")

print(f"\n  retained warm: {warm}/{N}")
if warm == N:
    print("\n  PASS - all sessions retained. L1 held the full working set;")
    print("         this set would have evicted its earliest sessions at L1=30.")
    sys.exit(0)
else:
    print(f"\n  FAIL - {N - warm} session(s) evicted. Working set exceeded the live L1,")
    print("         or L1 is smaller than expected. Check LMCACHE_L1_GB and that")
    print("         shm_size >= L1 (else the MP connector falls back to slow pickle).")
    sys.exit(1)
PY
