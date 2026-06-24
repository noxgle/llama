#!/usr/bin/env python3
"""Knowledge benchmark — multiple tasks, one prompt each, results to file.

Usage:
  python3 scripts/benchmark-knowledge.sh          # local, port 8089
  HOST=root@192.168.200.21 python3 scripts/benchmark-knowledge.sh  # remote
  PORT=8089 python3 scripts/benchmark-knowledge.sh                 # custom port

Output:
  ./benchmark-kb-<timestamp>.txt  — human-readable report
  ./benchmark-kb-<timestamp>.json — machine-readable results (incl. full content)

After running:
  1. Add a row to scripts/benchmark-knowledge-compare.md comparison table
  2. Add a detailed section with the results
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime

# ---- config ----
HOST = os.environ.get("HOST", "")        # e.g. "root@192.168.200.21"
PORT = int(os.environ.get("PORT", 8089))
MODEL = os.environ.get("MODEL", "gemma4")
TIMESTAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT_TXT = f"benchmark-kb-{TIMESTAMP}.txt"
OUT_JSON = f"benchmark-kb-{TIMESTAMP}.json"
TIMEOUT = 300  # 5 minutes per request (unlimited tokens)

# ---- tasks ----
TASKS = [
    {
        "name": "Data Analysis",
        "category": "data_analysis",
        "prompt": (
            "Given this CSV data:\n"
            "Name,Age,Salary,Department\n"
            "John,30,50000,Engineering\n"
            "Jane,25,60000,Marketing\n"
            "Bob,35,55000,Engineering\n"
            "Alice,28,52000,Sales\n\n"
            "Calculate the average salary. List all employees under age 32. "
            "What department has the highest average salary?"
        ),
    },
    {
        "name": "Python Programming",
        "category": "programming",
        "prompt": (
            "Write a Python function called `analyze_text` that takes a string "
            "and returns a dictionary with:\n"
            "1. word_count - total number of words\n"
            "2. char_count - total characters (excluding spaces)\n"
            "3. unique_words - number of unique words (case-insensitive)\n"
            "4. longest_word - the longest word in the string\n"
            "5. word_freq - a dict of the 3 most common words with their counts\n\n"
            "Include a brief docstring and an example usage."
        ),
    },
    {
        "name": "Logic Puzzle",
        "category": "logic",
        "prompt": (
            "Solve this puzzle step by step:\n\n"
            "There are three boxes: one contains only apples, one contains only oranges, "
            "and one contains both apples and oranges. Each box is labeled, but all labels "
            "are wrong. Box A says 'Apples', Box B says 'Oranges', Box C says 'Apples and Oranges'.\n\n"
            "You can pick one fruit from one box without looking inside. "
            "Which box do you pick from, and how do you determine the correct labels?"
        ),
    },
    {
        "name": "Mathematics",
        "category": "math",
        "prompt": (
            "Calculate the following definite integral step by step:\n\n"
            "\u222b\u2080\u00b2 (3x\u00b2 + 2x + 1) dx\n\n"
            "Show each step of your work and give the final answer."
        ),
    },
    {
        "name": "Networking Knowledge",
        "category": "knowledge",
        "prompt": (
            "Explain the differences between TCP and UDP protocols in networking. "
            "For each protocol, provide:\n"
            "1. How it establishes connections\n"
            "2. Reliability guarantees\n"
            "3. Two real-world applications and why that protocol is appropriate"
        ),
    },
    {
        "name": "Creative Writing",
        "category": "creative",
        "prompt": (
            "Write a short story (about 200 words) about a robot that develops "
            "the ability to dream. The tone should be contemplative and "
            "slightly melancholic. Use vivid imagery."
        ),
    },
    {
        "name": "Code Review",
        "category": "code_review",
        "prompt": (
            "Review this Python code. Identify bugs, style issues, and potential "
            "improvements. Provide corrected code.\n\n"
            "```python\n"
            "def calculate_average(nums):\n"
            "    total = 0\n"
            "    for i in range(len(nums)):\n"
            "        total = total + nums[i]\n"
            "    return total / len(nums)\n\n"
            "def find_max(nums):\n"
            "    max_num = 0\n"
            "    for n in nums:\n"
            "        if n > max_num:\n"
            "            max_num = n\n"
            "    return max_num\n\n"
            "def process_data(data):\n"
            "    result = {}\n"
            "    for item in data:\n"
            "        if item['category'] not in result:\n"
            "            result[item['category']] = []\n"
            "        result[item['category']].append(item['value'])\n"
            "    return result\n"
            "```"
        ),
    },
    {
        "name": "SQL Query",
        "category": "sql",
        "prompt": (
            "Given these tables:\n\n"
            "```sql\n"
            "CREATE TABLE employees (\n"
            "  id INT PRIMARY KEY,\n"
            "  name VARCHAR(100),\n"
            "  department_id INT,\n"
            "  salary DECIMAL(10,2),\n"
            "  hire_date DATE\n"
            ");\n\n"
            "CREATE TABLE departments (\n"
            "  id INT PRIMARY KEY,\n"
            "  name VARCHAR(100),\n"
            "  location VARCHAR(100)\n"
            ");\n"
            "```\n\n"
            "Write an SQL query that returns each department name with: "
            "the number of employees, average salary, highest salary, "
            "and the employee with the most recent hire date (their name). "
            "Only include departments with at least 3 employees. "
            "Order by average salary descending."
        ),
    },
    {
        "name": "Explain Like I'm 5",
        "category": "eli5",
        "prompt": (
            "Explain how the internet works to a 5-year-old child. "
            "Use simple analogies and avoid technical jargon. "
            "Keep it under 150 words."
        ),
    },
    {
        "name": "Algorithm Design",
        "category": "algorithms",
        "prompt": (
            "Design an algorithm to detect if a string is a valid palindrome "
            "permutation. A palindrome permutation is a string that can be "
            "rearranged to form a palindrome.\n\n"
            "Provide:\n"
            "1. The approach in plain English\n"
            "2. Time and space complexity analysis\n"
            "3. Python implementation\n\n"
            "Example: 'tact coa' \u2192 True (arranges to 'taco cat' or 'atco cta')"
        ),
    },
]


# ---- helpers ----
def run_curl(payload: str) -> str:
    """Send request to the model API, return raw JSON response."""
    if HOST:
        # Remote: SSH to host and curl localhost inside
        cmd = [
            "ssh", HOST,
            "curl", "-sS", "--max-time", str(TIMEOUT),
            f"http://localhost:{PORT}/v1/chat/completions",
            "-H", "Content-Type: application/json",
            "-d", payload,
        ]
    else:
        # Local: curl directly
        cmd = [
            "curl", "-sS", "--max-time", str(TIMEOUT),
            f"http://localhost:{PORT}/v1/chat/completions",
            "-H", "Content-Type: application/json",
            "-d", payload,
        ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT + 10)
        if result.returncode != 0:
            return json.dumps({"error": f"curl failed: {result.stderr.strip()}"})
        return result.stdout
    except subprocess.TimeoutExpired:
        return json.dumps({"error": "timeout"})
    except Exception as e:
        return json.dumps({"error": str(e)})


def extract_content(data: dict) -> str:
    """Extract content or reasoning_content from response."""
    choices = data.get("choices", [])
    if not choices:
        return ""
    msg = choices[0].get("message", {})
    return msg.get("content", "") or msg.get("reasoning_content", "")


# ---- main ----
def main():
    print(f"[{datetime.now():%H:%M:%S}] Starting knowledge benchmark")
    print(f"[{datetime.now():%H:%M:%S}] Target: {HOST or 'localhost'}:{PORT}, model: {MODEL}")
    print(f"[{datetime.now():%H:%M:%S}] Output: {OUT_TXT} / {OUT_JSON}")

    results = []
    total_tps = 0.0
    total_count = 0

    for i, task in enumerate(TASKS):
        tag = f"[{i+1}/{len(TASKS)}] {task['name']}"
        print(f"[{datetime.now():%H:%M:%S}] {tag}...", end=" ", flush=True)

        payload = json.dumps({
            "messages": [{"role": "user", "content": task["prompt"]}],
            "temperature": 0.1,
        })

        t0 = time.time()
        raw = run_curl(payload)
        duration_s = round(time.time() - t0, 1)

        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print("FAIL (invalid JSON)")
            results.append({
                "task": i + 1,
                "name": task["name"],
                "category": task["category"],
                "error": "invalid JSON response",
                "tps": 0,
                "duration_s": duration_s,
                "draft_n": 0,
                "draft_accepted": 0,
                "prompt_tokens": 0,
                "generated_tokens": 0,
                "finish_reason": "error",
            })
            continue

        if "error" in data:
            print(f"FAIL ({data['error'][:60]})")
            results.append({
                "task": i + 1,
                "name": task["name"],
                "category": task["category"],
                "error": data["error"],
                "tps": 0,
                "duration_s": duration_s,
                "draft_n": 0,
                "draft_accepted": 0,
                "prompt_tokens": 0,
                "generated_tokens": 0,
                "finish_reason": "error",
            })
            continue

        timings = data.get("timings", {})
        tps = timings.get("predicted_per_second", 0)
        pred_n = timings.get("predicted_n", 0)
        prompt_n = timings.get("prompt_n", 0)
        draft_n = timings.get("draft_n", 0)
        draft_acc = timings.get("draft_n_accepted", 0)
        finish = data.get("choices", [{}])[0].get("finish_reason", "")
        content = extract_content(data)

        if tps > 0:
            total_tps += tps
            total_count += 1

        draft_pct = (100 * draft_acc / draft_n) if draft_n > 0 else 0
        print(f"OK  {tps:.1f} tok/s  [{duration_s:.0f}s]  draft={draft_acc}/{draft_n} ({draft_pct:.0f}%)")

        results.append({
            "task": i + 1,
            "name": task["name"],
            "category": task["category"],
            "tps": round(tps, 1),
            "duration_s": duration_s,
            "draft_n": draft_n,
            "draft_accepted": draft_acc,
            "prompt_tokens": prompt_n,
            "generated_tokens": pred_n,
            "finish_reason": finish,
            "content_length": len(content),
            "content": content,
        })

    # ---- write JSON ----
    with open(OUT_JSON, "w") as f:
        json.dump(results, f, indent=2)

    # ---- write TXT report ----
    avg_tps = total_tps / total_count if total_count > 0 else 0
    with open(OUT_TXT, "w") as f:
        f.write("=" * 50 + "\n")
        f.write(f"  Knowledge Benchmark Report\n")
        f.write(f"  Model: {MODEL} ({HOST or 'localhost'}:{PORT})\n")
        f.write(f"  Date:  {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        f.write("=" * 50 + "\n\n")

        for r in results:
            f.write("-" * 50 + "\n")
            f.write(f"  Task {r['task']}: {r['name']} ({r['category']})\n")
            if "error" in r:
                f.write(f"  ERROR: {r['error']}\n\n")
                continue
            f.write(f"  Tokens:  {r['prompt_tokens']} out / {r['generated_tokens']} gen\n")
            f.write(f"  Speed:   {r['tps']} tok/s\n")
            f.write(f"  Time:    {r['duration_s']:.0f}s\n")
            if r['draft_n'] > 0:
                dpct = round(100 * r['draft_accepted'] / r['draft_n'])
                f.write(f"  Draft:   {r['draft_accepted']}/{r['draft_n']} ({dpct}%)\n")
            f.write(f"  Finish:  {r['finish_reason']}\n")
            f.write("\n")

        f.write("=" * 50 + "\n")
        f.write("  Summary\n")
        f.write("=" * 50 + "\n")
        f.write(f"  Tasks completed: {total_count}/{len(TASKS)}\n")
        f.write(f"  Average speed:   {avg_tps:.1f} tok/s\n")
        f.write(f"  Reports:\n")
        f.write(f"    {OUT_TXT}\n")
        f.write(f"    {OUT_JSON}\n\n")

    # ---- print table ----
    print()
    print(f"{'#':<4} {'Task':<22} {'tok/s':>8} {'draft%':>7} {'tokens':>7} {'time':>7}")
    print(f"{'---':<4} {'----------------------':<22} {'-------':>8} {'-------':>7} {'-------':>7} {'-------':>7}")
    for r in results:
        dpct = round(100 * r['draft_accepted'] / r['draft_n']) if r['draft_n'] > 0 else 0
        tps_str = f"{r['tps']:.1f}" if "error" not in r else "ERR"
        time_str = f"{r['duration_s']:.0f}s" if "duration_s" in r else ""
        print(f"{r['task']:<4} {r['name']:<22} {tps_str:>8} {dpct:>6}% {r['generated_tokens']:>7} {time_str:>7}")
    print()

    print(f"[{datetime.now():%H:%M:%S}] Done!  Avg speed: {avg_tps:.1f} tok/s")
    print(f"[{datetime.now():%H:%M:%S}] Report: {OUT_TXT}")
    print(f"[{datetime.now():%H:%M:%S}] JSON:   {OUT_JSON}")


if __name__ == "__main__":
    main()
