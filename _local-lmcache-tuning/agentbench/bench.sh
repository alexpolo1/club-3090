#!/bin/bash
# Pi (.98) vs Hermes (.96) — same backend :8010, same tasks, same grading.
set -u
B=/tmp/agentbench
OUT=$B/BENCH-RESULTS.txt
RUNS=${RUNS:-2}
TASKS="t1-phase t2-stringids t3-import t4-truncate"
: > "$OUT"

echo "=== Pi vs Hermes — same model (qwen3.6-27b @ :8010, MTP-off), $(date -u) ===" | tee -a "$OUT"
echo "tasks: $TASKS   runs/task: $RUNS" | tee -a "$OUT"
echo | tee -a "$OUT"

file_for () { case "$1" in t1-phase|t3-import) echo generator.ts;; *) echo clue_graph.ts;; esac; }

run_pi () {  # $1=task $2=run
  local task=$1 run=$2 f; f=$(file_for "$task")
  local d=$B/work/pi/$task/$run
  rm -rf "$d"; mkdir -p "$d"; cp "$B/seeds/$task/$f" "$d/"
  sed "s|{D}|$d|g" "$B/tasks/$task.txt" > "$d/task.txt"
  ( cd "$d" && timeout 420 pi -p "$(cat "$d/task.txt")" > "$d/agent.log" 2>&1 )
  python3 "$B/grade.py" "$task" "$d" 2>&1
}

run_hermes () {  # $1=task $2=run
  local task=$1 run=$2 f; f=$(file_for "$task")
  local d=$B/work/hermes/$task/$run
  ssh ai96 "rm -rf $d && mkdir -p $d" 2>/dev/null
  scp -q "$B/seeds/$task/$f" "ai96:$d/" 2>/dev/null
  sed "s|{D}|$d|g" "$B/tasks/$task.txt" > /tmp/_t.txt
  scp -q /tmp/_t.txt "ai96:$d/task.txt" 2>/dev/null
  ssh ai96 "source ~/.hermes-remote/venv/bin/activate; cd $d && timeout 420 hermes -z \"\$(cat $d/task.txt)\" -t file,terminal --yolo > $d/agent.log 2>&1" 2>/dev/null
  # grade remotely-produced file locally
  mkdir -p "$B/work/hermes/$task/$run"
  scp -q "ai96:$d/$f" "$B/work/hermes/$task/$run/" 2>/dev/null
  python3 "$B/grade.py" "$task" "$B/work/hermes/$task/$run" 2>&1
}

declare -A SCORE
for agent in pi hermes; do
  for task in $TASKS; do
    for run in $(seq 1 "$RUNS"); do
      if [ "$agent" = pi ]; then r=$(run_pi "$task" "$run"); else r=$(run_hermes "$task" "$run"); fi
      v=$(echo "$r" | grep -q PASS && echo PASS || echo FAIL)
      SCORE[$agent-$task]="${SCORE[$agent-$task]:-}$([ "$v" = PASS ] && echo '✅' || echo '❌')"
      printf "  %-7s %-14s run%s  %s  %s\n" "$agent" "$task" "$run" "$v" "$(echo "$r" | sed 's/^[A-Z]* //')" | tee -a "$OUT"
    done
  done
done

echo | tee -a "$OUT"
echo "=== SUMMARY (per task, $RUNS runs each) ===" | tee -a "$OUT"
printf "  %-14s %-10s %s\n" "TASK" "PI" "HERMES" | tee -a "$OUT"
for task in $TASKS; do
  printf "  %-14s %-10s %s\n" "$task" "${SCORE[pi-$task]:-}" "${SCORE[hermes-$task]:-}" | tee -a "$OUT"
done
tot () { local a=$1 p=0; for t in $TASKS; do p=$((p+$(grep -o '✅' <<<"${SCORE[$a-$t]:-}" | wc -l))); done; echo $p; }
N=$((4*RUNS))
echo | tee -a "$OUT"
echo "  PI     total: $(tot pi)/$N" | tee -a "$OUT"
echo "  HERMES total: $(tot hermes)/$N" | tee -a "$OUT"
echo "=== DONE $(date -u) ===" | tee -a "$OUT"
