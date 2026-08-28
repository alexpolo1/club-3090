"""Seed 4 diverse bugs into clean coldcase sources + emit task prompts + graders.

Bug classes deliberately differ so the bench tests different skills:
  T1 phase-labels  : cross-reference/counting  (must count phases across the file)
  T2 string-ids    : silent data loss via type filter (needs to reason about runtime types)
  T3 missing-import: runtime crash (stack-trace driven)
  T4 truncation    : magic-number regression (evidence driven, no crash)
"""
import json, shutil
from pathlib import Path

SRC = Path("/tmp/agentbench/src")
OUT = Path("/tmp/agentbench/seeds")
TASKS = Path("/tmp/agentbench/tasks")
for d in (OUT, TASKS):
    d.mkdir(parents=True, exist_ok=True)

def seed(task, fname, old, new, count=1):
    src = (SRC / fname).read_text(encoding="utf-8")
    assert src.count(old) == count, f"{task}: anchor x{src.count(old)} (want {count})"
    d = OUT / task
    d.mkdir(parents=True, exist_ok=True)
    (d / fname).write_text(src.replace(old, new), encoding="utf-8")
    print(f"  {task:16s} {fname:16s} seeded")

# ---- T1: phase labels regress to /4 (the real historical bug)
seed("t1-phase", "generator.ts",
     "onProgress?.('Fase 1/5: Genererer plot-oversigt...');",
     "onProgress?.('Fase 1/4: Genererer plot-oversigt...');")
p = OUT / "t1-phase/generator.ts"
t = p.read_text(encoding="utf-8")
t = t.replace("onProgress?.('Fase 2/5: GEMMER i databasen...');",
              "onProgress?.('Fase 2/4: GEMMER i databasen...');")
p.write_text(t, encoding="utf-8")

# ---- T2: string doc-ids silently dropped
seed("t2-stringids", "clue_graph.ts",
     "required_doc_ids: Array.isArray(c.required_doc_ids) ? c.required_doc_ids.map((id: any) => typeof id === 'number' ? id : parseInt(String(id).replace(/\\D/g, ''), 10)).filter((n: number) => Number.isFinite(n) && n > 0) : [],",
     "required_doc_ids: Array.isArray(c.required_doc_ids) ? c.required_doc_ids.filter((id: number) => typeof id === 'number') : [],")

# ---- T3: missing dynamic imports -> ReferenceError at runtime
seed("t3-import", "generator.ts",
     "  const { execFile } = await import('child_process');\n  const { promisify } = await import('util');\n  const exec = promisify(execFile);\n  const fs = await import('fs/promises');\n  const os = await import('os');\n  const path = await import('path');\n\n  const [mystery] = await query<any>('SELECT * FROM mysteries WHERE id = ?', [mysteryId]);\n  const locations = await query<any>(",
     "  const exec = promisify(execFile);\n  const fs = await import('fs/promises');\n  const os = await import('os');\n  const path = await import('path');\n\n  const [mystery] = await query<any>('SELECT * FROM mysteries WHERE id = ?', [mysteryId]);\n  const locations = await query<any>(")

# ---- T4: clue text truncated to 12 chars (magic-number regression)
seed("t4-truncate", "clue_graph.ts",
     "clue_text: String(c.clue_text).substring(0, 120),",
     "clue_text: String(c.clue_text).substring(0, 12),")

# ------------------------------------------------------------------ prompts
RULES = """CRITICAL EXECUTION RULES — obey before doing anything else:
- You are an autonomous coding agent running headlessly. There is NO human to talk to.
- Do NOT write any preamble, plan, or narration. Never write "I will" or "Let me".
- Your VERY FIRST output MUST be an actual tool call. ACT — do not describe acting.
- Keep issuing tool calls until the bug is fully fixed AND verified. Do NOT stop after one step.
- Emit prose ONLY at the very end, as your final report.

CONSTRAINTS: minimal edits, match surrounding style, touch only what this bug needs.
Back up the file before editing: cp <file> <file>.bak-<unix_timestamp>
"""

BODIES = {
"t1-phase": """THE BUG: In {D}/generator.ts (TypeScript, a Danish murder-mystery generator), the progress
messages that tell the user which phase is running are INCONSISTENT about the TOTAL number of phases.
Partway through a single generation the denominator jumps. Work out the ACTUAL number of phases from
the code and make every label consistent and correct.

I am deliberately NOT telling you the cause. Investigate, fix, verify by re-grepping the labels.
FINAL REPORT: root cause in 1-2 sentences, file+lines changed, before/after label list.""",

"t2-stringids": """THE BUG: In {D}/clue_graph.ts (TypeScript), mysteries are being saved with ZERO clues.
The log shows "Gemmer 0 clues" even though the LLM returned a full clue list. The LLM returns
required_doc_ids as JSON values that are NOT always numbers — sometimes strings like "5" or "DOC 5".
Something in the validation pipeline silently discards every clue.

I am deliberately NOT telling you which line. Investigate, find the root cause, fix it so string-form
doc ids are accepted (converted to numbers), and make sure a mystery is never saved with zero clues.
FINAL REPORT: root cause in 1-2 sentences, file+lines changed.""",

"t3-import": """THE BUG: In {D}/generator.ts, image generation crashes at runtime with:
    ReferenceError: promisify is not defined
    at generateMysteryImages ({D}/generator.ts)
The file has NO top-level `util` or `child_process` import (check the top of the file — imports are
lines 1-6 only). Other functions in this same file do this correctly — find how they do it and match.

I am deliberately NOT telling you the fix. Investigate, fix, verify.
FINAL REPORT: root cause in 1-2 sentences, file+lines changed.""",

"t4-truncate": """THE BUG: In {D}/clue_graph.ts, the clue texts shown to players are being cut off after a
dozen characters. Users report clues like "Vidnet så en" instead of the full sentence. Nothing crashes.
The intended maximum clue length is 120 characters.

I am deliberately NOT telling you which line. Investigate, find the truncation, fix it.
FINAL REPORT: root cause in 1-2 sentences, file+lines changed.""",
}

for task, body in BODIES.items():
    (TASKS / f"{task}.txt").write_text(RULES + "\n" + body + "\n", encoding="utf-8")
    print(f"  prompt {task}")

# ------------------------------------------------------------------ graders
GRADERS = {
 # (must_match_regex, must_not_match_regex, description)
 "t1-phase":     {"file": "generator.ts",  "want_count": ("Fase [0-9]/5", 5), "forbid": "Fase [0-9]/4"},
 "t2-stringids": {"file": "clue_graph.ts", "want_any": ["parseInt", "Number(", "parseFloat", "\\+id", "String(id)"],
                  "forbid": r"\.filter\(\(id: number\) => typeof id === 'number'\)"},
 "t3-import":    {"file": "generator.ts",  "want_all": [r"await import\('util'\)", r"await import\('child_process'\)"], "forbid": None},
 "t4-truncate":  {"file": "clue_graph.ts", "want_any": [r"substring\(0, 120\)", r"slice\(0, 120\)", r"substring\(0,120\)"],
                  "forbid": r"substring\(0, 12\)"},
}
(Path("/tmp/agentbench") / "graders.json").write_text(json.dumps(GRADERS, indent=2), encoding="utf-8")
print("\nwrote graders.json")
