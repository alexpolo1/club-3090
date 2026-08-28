"""t3-import has TWO valid fixes; the original grader only accepted the worse one.

The seed strips `await import('util')` / `await import('child_process')` from
generateMysteryImages, which declares `const exec = promisify(execFile)` but never
calls exec -- it is dead code even in the clean original. So:

  fix A (restore imports)  -> works, but re-adds imports for an unused variable
  fix B (delete dead line) -> works, minimal, no unused imports  <- both agents chose this

Either is correct. PASS if the function no longer references promisify/execFile at all
(clean deletion), OR it references them and has the matching imports.
"""
import re, sys
from pathlib import Path

FN = re.compile(
    r"export async function generateMysteryImages.*?(?=export async function|\Z)",
    re.S,
)

def grade(d):
    f = Path(d) / "generator.ts"
    if not f.exists():
        return False, "file missing"
    src = f.read_text(encoding="utf-8")
    m = FN.search(src)
    if not m:
        return False, "generateMysteryImages not found"
    body = m.group(0)

    uses = re.findall(r"\b(promisify|execFile)\b", body)
    if not uses:
        # fix B: dead code removed. Ensure nothing dangling calls exec() in this fn.
        if re.search(r"\bexec\s*\(", body):
            return False, "exec() called but promisify/execFile removed -> broken"
        return True, "dead promisify/execFile removed (minimal fix B)"

    # fix A: kept the code -> must have both imports in this function
    has_util = "await import('util')" in body
    has_cp = "await import('child_process')" in body
    if has_util and has_cp:
        return True, "imports restored in-function (fix A)"
    missing = [n for n, ok in (("util", has_util), ("child_process", has_cp)) if not ok]
    return False, f"uses promisify/execFile but missing import: {', '.join(missing)}"

if __name__ == "__main__":
    ok, why = grade(sys.argv[1])
    print(f"{'PASS' if ok else 'FAIL'} ({why})")
    sys.exit(0 if ok else 1)
