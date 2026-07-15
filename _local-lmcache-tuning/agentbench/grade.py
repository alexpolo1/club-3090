"""Grade a task workdir. Usage: grade.py <task> <dir>  -> prints PASS/FAIL."""
import json, re, sys
from pathlib import Path

G = json.loads(Path("/tmp/agentbench/graders.json").read_text(encoding="utf-8"))

def grade(task, d):
    g = G[task]
    f = Path(d) / g["file"]
    if not f.exists():
        return False, "file missing"
    t = f.read_text(encoding="utf-8")

    if g.get("forbid") and re.search(g["forbid"], t):
        return False, f"buggy pattern still present: {g['forbid']}"

    if "want_count" in g:
        pat, n = g["want_count"]
        got = len(re.findall(pat, t))
        if got != n:
            return False, f"expected {n}x /{pat}/, got {got}"

    if "want_counts" in g:
        for pat, n in g["want_counts"]:
            got = len(re.findall(pat, t))
            if got != n:
                return False, f"expected {n}x /{pat}/, got {got}"

    if "want_all" in g:
        for pat in g["want_all"]:
            if not re.search(pat, t):
                return False, f"missing required: {pat}"

    if "want_any" in g:
        if not any(re.search(p, t) for p in g["want_any"]):
            return False, f"none of the accepted fixes present: {g['want_any']}"

    return True, "ok"

if __name__ == "__main__":
    ok, why = grade(sys.argv[1], sys.argv[2])
    print(f"{'PASS' if ok else 'FAIL'} ({why})")
    sys.exit(0 if ok else 1)
