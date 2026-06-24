#!/usr/bin/env bash
# Knowledge benchmark — multiple tasks, one prompt each, results to file
#
# Usage:
#   bash scripts/benchmark-knowledge.sh          # local, port 8089
#   HOST=root@192.168.200.21 bash scripts/benchmark-knowledge.sh  # remote
#   PORT=8089 bash scripts/benchmark-knowledge.sh                 # custom port
#
# Output:
#   ./benchmark-kb-<timestamp>.txt  — human-readable report
#   ./benchmark-kb-<timestamp>.json — machine-readable results

set -euo pipefail

# ---- config ----
HOST="${HOST:-}"                    # e.g. root@192.168.200.21 (empty = local)
PORT="${PORT:-8089}"
MODEL="${MODEL:-gemma4}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT_TXT="benchmark-kb-${TIMESTAMP}.txt"
OUT_JSON="benchmark-kb-${TIMESTAMP}.json"

# ---- helpers ----
run_curl() {
  local payload="$1"
  if [ -n "$HOST" ]; then
    ssh "$HOST" "curl -sS --max-time 120 http://localhost:${PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}'"
  else
    curl -sS --max-time 120 "http://localhost:${PORT}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "${payload}"
  fi
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ---- tasks ----
# Each task: short name | category | prompt | max_tokens
TASKS=(
  "Data Analysis|data_analysis|Given this CSV data:\nName,Age,Salary,Department\nJohn,30,50000,Engineering\nJane,25,60000,Marketing\nBob,35,55000,Engineering\nAlice,28,52000,Sales\n\nCalculate the average salary. List all employees under age 32. What department has the highest average salary?|400"
  "Python Programming|programming|Write a Python function called `analyze_text` that takes a string and returns a dictionary with:\n1. word_count - total number of words\n2. char_count - total characters (excluding spaces)\n3. unique_words - number of unique words (case-insensitive)\n4. longest_word - the longest word in the string\n5. word_freq - a dict of the 3 most common words with their counts\n\nInclude a brief docstring and an example usage.|500"
  "Logic Puzzle|logic|Solve this puzzle step by step:\n\nThere are three boxes: one contains only apples, one contains only oranges, and one contains both apples and oranges. Each box is labeled, but all labels are wrong. Box A says \"Apples\", Box B says \"Oranges\", Box C says \"Apples and Oranges\".\n\nYou can pick one fruit from one box without looking inside. Which box do you pick from, and how do you determine the correct labels?|400"
  "Mathematics|math|Calculate the following definite integral step by step:\n\n∫₀² (3x² + 2x + 1) dx\n\nShow each step of your work and give the final answer.|300"
  "Networking Knowledge|knowledge|Explain the differences between TCP and UDP protocols in networking. For each protocol, provide:\n1. How it establishes connections\n2. Reliability guarantees\n3. Two real-world applications and why that protocol is appropriate|400"
  "Creative Writing|creative|Write a short story (about 200 words) about a robot that develops the ability to dream. The tone should be contemplative and slightly melancholic. Use vivid imagery.|500"
  "Code Review|code_review|Review this Python code. Identify bugs, style issues, and potential improvements. Provide corrected code.\n\n```python\ndef calculate_average(nums):\n    total = 0\n    for i in range(len(nums)):\n        total = total + nums[i]\n    return total / len(nums)\n\ndef find_max(nums):\n    max_num = 0\n    for n in nums:\n        if n > max_num:\n            max_num = n\n    return max_num\n\ndef process_data(data):\n    result = {}\n    for item in data:\n        if item[\"category\"] not in result:\n            result[item[\"category\"]] = []\n        result[item[\"category\"]].append(item[\"value\"])\n    return result\n```|500"
  "SQL Query|sql|Given these tables:\n\n```sql\nCREATE TABLE employees (\n  id INT PRIMARY KEY,\n  name VARCHAR(100),\n  department_id INT,\n  salary DECIMAL(10,2),\n  hire_date DATE\n);\n\nCREATE TABLE departments (\n  id INT PRIMARY KEY,\n  name VARCHAR(100),\n  location VARCHAR(100)\n);\n```\n\nWrite an SQL query that returns each department name with: the number of employees, average salary, highest salary, and the employee with the most recent hire date (their name). Only include departments with at least 3 employees. Order by average salary descending.|500"
  "Explain like I'm 5|eli5|Explain how the internet works to a 5-year-old child. Use simple analogies and avoid technical jargon. Keep it under 150 words.|200"
  "Algorithm Design|algorithms|Design an algorithm to detect if a string is a valid palindrome permutation. A palindrome permutation is a string that can be rearranged to form a palindrome.\n\nProvide:\n1. The approach in plain English\n2. Time and space complexity analysis\n3. Python implementation\n\nExample: \"tact coa\" → True (arranges to \"taco cat\" or \"atco cta\")|400"
)

# ---- run ----
log "Starting knowledge benchmark → ${OUT_TXT} / ${OUT_JSON}"
log "Target: ${HOST:-localhost}:${PORT}, model: ${MODEL}"

# CSV header for JSON
echo "[" > "$OUT_JSON"
FIRST=true
{
  echo "=========================================="
  echo "  Knowledge Benchmark Report"
  echo "  Model: ${MODEL} (${HOST:-localhost}:${PORT})"
  echo "  Date:  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  echo ""
} > "$OUT_TXT"

TOTAL_TPS=0
TOTAL_COUNT=0
ALL_RESULTS=()

for i in "${!TASKS[@]}"; do
  IFS='|' read -r short_name category prompt max_tokens <<< "${TASKS[$i]}"

  # Escape the prompt for JSON
  prompt_escaped=$(printf '%s' "$prompt" | python3 -c "
import sys, json
data = sys.stdin.read()
print(json.dumps(data))
")

  payload="{\"messages\":[{\"role\":\"user\",\"content\":${prompt_escaped}}],\"max_tokens\":${max_tokens},\"temperature\":0.1}"

  log "[$((i+1))/${#TASKS[@]}] ${short_name}... (max_tok=${max_tokens})"

  RESPONSE=$(run_curl "$payload" 2>&1 || echo '{"error":"curl failed"}')

  # Parse response
  CONTENT=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'error' in d:
        print('ERROR: ' + str(d['error']), file=sys.stderr)
        print('')
    else:
        choices = d.get('choices', [{}])
        msg = choices[0].get('message', {})
        print(msg.get('content', '') or msg.get('reasoning_content', ''))
except Exception as e:
    print('', end='')
" 2>>"$OUT_TXT")

  TIMINGS=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    t = d.get('timings', {})
    print(json.dumps(t))
except: print('{}')
")

  TPS=$(echo "$TIMINGS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('predicted_per_second',0))")
  PRED_N=$(echo "$TIMINGS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('predicted_n',0))")
  PROMPT_N=$(echo "$TIMINGS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt_n',0))")
  DRAFT_N=$(echo "$TIMINGS" | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('draft_n',0))")
  DRAFT_ACC=$(echo "$TIMINGS" | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('draft_n_accepted',0))")
  FINISH=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('choices',[{}])[0].get('finish_reason',''))")

  if [ "$(echo "$TPS > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
    TOTAL_TPS=$(echo "$TOTAL_TPS + $TPS" | bc -l)
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
  fi

  # Content preview
  CONTENT_PREVIEW=$(echo "$CONTENT" | head -c 150 | tr '\n' ' ' | sed 's/  / /g')

  # Write TXT result
  {
    echo "----------------------------------------"
    printf "  Task %d: %s (%s)\n" $((i+1)) "$short_name" "$category"
    printf "  Tokens:  %d out / %d gen\n" "$PROMPT_N" "$PRED_N"
    printf "  Speed:   %s tok/s\n" "$(echo "$TPS" | xargs printf '%.1f')"
    if [ "$DRAFT_N" -gt 0 ] 2>/dev/null; then
      printf "  Draft:   %s/%s (%.0f%%)\n" "$DRAFT_ACC" "$DRAFT_N" "$(echo "if($DRAFT_N>0) 100*$DRAFT_ACC/$DRAFT_N" | bc -l 2>/dev/null || echo 0)"
    fi
    printf "  Finish:  %s\n" "$FINISH"
    printf "  Preview: %s...\n" "$CONTENT_PREVIEW"
    echo ""
  } >> "$OUT_TXT"

  # Write JSON
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    echo "," >> "$OUT_JSON"
  fi
  {
    echo "  {"
    echo "    \"task\": $((i+1)),"
    echo "    \"name\": \"${short_name}\","
    echo "    \"category\": \"${category}\","
    echo "    \"prompt_tokens\": ${PROMPT_N},"
    echo "    \"generated_tokens\": ${PRED_N},"
    echo "    \"tps\": ${TPS},"
    echo "    \"draft_n\": ${DRAFT_N},"
    echo "    \"draft_accepted\": ${DRAFT_ACC},"
    echo "    \"finish_reason\": \"${FINISH}\","
    echo "    \"content_length\": ${#CONTENT}"
    echo "  }"
  } >> "$OUT_JSON"
done

# Close JSON
echo "]" >> "$OUT_JSON"

# Summary
AVG_TPS=0
if [ "$TOTAL_COUNT" -gt 0 ]; then
  AVG_TPS=$(echo "scale=1; $TOTAL_TPS / $TOTAL_COUNT" | bc -l)
fi

{
  echo "=========================================="
  echo "  Summary"
  echo "=========================================="
  printf "  Tasks completed: %d/%d\n" "$TOTAL_COUNT" "${#TASKS[@]}"
  printf "  Average speed:   %.1f tok/s\n" "$AVG_TPS"
  echo "  Report files:"
  echo "    ${OUT_TXT}"
  echo "    ${OUT_JSON}"
  echo ""
} >> "$OUT_TXT"

# Print summary to stdout
log "=========================================="
log "  Knowledge Benchmark — Done!"
log "  Tasks: ${TOTAL_COUNT}/${#TASKS[@]}  |  Avg speed: ${AVG_TPS} tok/s"
log "  Report: ${OUT_TXT}"
log "  JSON:   ${OUT_JSON}"
log "=========================================="

# Print quick table
echo ""
printf "%-4s %-22s %8s  %7s  %s\n" "#" "Task" "tok/s" "draft%" "tokens"
printf "%-4s %-22s %8s  %7s  %s\n" "---" "----------------------" "-------" "-------" "-------"
for i in "${!TASKS[@]}"; do
  IFS='|' read -r short_name category prompt max_tokens <<< "${TASKS[$i]}"
  # Re-extract from JSON
  ROW=$(python3 -c "
import json
with open('${OUT_JSON}') as f:
    data = json.load(f)
r = data[${i}]
tps = r.get('tps', 0)
dn = r.get('draft_n', 0)
da = r.get('draft_accepted', 0)
dpct = round(100*da/dn, 0) if dn > 0 else 0
gen = r.get('generated_tokens', 0)
print(f'{tps:.1f} {dpct:.0f} {gen}')
")
  read -r tps_val draft_pct gen_val <<< "$ROW"
  printf "%-4s %-22s %8s  %5s%%  %s\n" "$((i+1))" "$short_name" "$tps_val" "$draft_pct" "$gen_val"
done
echo ""
