"""Replay the EXACT captured Hermes request N times; report tool-call rate.

This is the corruption probe: the same bytes a real agent sends, so a drop here
is the same drop the agent experiences.
"""
import json, copy, re, sys, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
_t = (HERE / "capture.log").read_text(encoding="utf-8")
base = json.JSONDecoder().raw_decode(_t[_t.find("{"):])[0]
base["max_tokens"] = 200
URL = "http://192.168.1.98:8010/v1/chat/completions"
LEAK = re.compile(r"<arg_key>|<arg_value>|<argument_channels>|<arg_end>")
NAKED = re.compile(r"\w+\(\s*\w+\s*[=:]")

N = int(sys.argv[1]) if len(sys.argv) > 1 else 6

def once():
    req = urllib.request.Request(URL, data=json.dumps(base).encode(),
                                 headers={"Content-Type": "application/json"})
    tcs, content = 0, ""
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            l = raw.decode("utf-8").strip()
            if not l.startswith("data: ") or l[6:] == "[DONE]":
                continue
            for ch in json.loads(l[6:]).get("choices", []):
                d = ch.get("delta", {})
                content += d.get("content") or ""
                if d.get("tool_calls"):
                    tcs += 1
    return tcs, content

ok = leak = naked = 0
for _ in range(N):
    try:
        tcs, c = once()
    except Exception:
        continue
    if tcs:
        ok += 1
    else:
        if LEAK.search(c):
            leak += 1
        if NAKED.search(c):
            naked += 1
print(f"{ok}/{N} tool-calls  (arg_key-leak={leak}, naked-imitation={naked})")
