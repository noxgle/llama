#!/usr/bin/env python3
"""Prompt-processing (prefill) benchmark through llama-server.

Measures prompt processing tok/s for several prompt sizes with
cache_prompt=false, i.e. one cold prefill per request.  This is the
metric that caught the SYCL MoE-offload regression (#31262) and the
HIP MMQ grid-order regression (#31603) — llama-bench does NOT reproduce
server-path prefill changes, so always measure through the server.

Usage:
  HOST=root@192.168.200.38 python3 scripts/benchmark-prefill.sh
  SIZES=6000,24000,85000 REPS=2 python3 scripts/benchmark-prefill.sh
  HOST= PORT=8089 python3 scripts/benchmark-prefill.sh   # local server

Output:
  ./benchmark-prefill-<timestamp>.txt
  ./benchmark-prefill-<timestamp>.json
"""

import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime

HOST = os.environ.get("HOST", "root@192.168.200.38")
PORT = int(os.environ.get("PORT", 8089))
SIZES = [int(x) for x in os.environ.get("SIZES", "6000,24000,85000").split(",")]
REPS = int(os.environ.get("REPS", "2"))
TIMEOUT = int(os.environ.get("TIMEOUT", 900))
TS = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT_TXT = f"benchmark-prefill-{TS}.txt"
OUT_JSON = f"benchmark-prefill-{TS}.json"

# Deterministic English corpus.  Content does not matter for prefill
# throughput; only the token count does.  Sentences are varied enough to
# avoid degenerate BPE merges.
_SENTENCES = [
    "The scheduler assigns work to threads and waits for completion.",
    "Memory bandwidth limits token generation on small GPUs.",
    "A quantized cache reduces video memory pressure at long context.",
    "Prompt processing is compute bound while decoding is bandwidth bound.",
    "Network packets travel through several layers of the protocol stack.",
    "The compiler optimizes loops and vectorizes the inner multiplication.",
    "Careful measurement separates real regressions from noise.",
    "A checkpoint stores the recurrent state so it can be restored later.",
    "Experts are routed per token in a mixture of experts architecture.",
    "Flash attention tiles the score matrix to fit in shared memory.",
    "The draft model proposes tokens that the target model then verifies.",
    "Graph reuse avoids rebuilding the execution plan on every batch.",
    "Quantization maps floating point weights onto a compact integer grid.",
    "The server keeps a prompt cache in host memory for fast reuse.",
    "Batch size and micro batch size interact with available video memory.",
    "Long conversations stress the key value cache and the scheduler.",
    "Numerical stability matters when accumulating many products in a row.",
    "The watchdog restarts the service when the GPU is not being used.",
    "Latency budgets are usually dominated by the first generated token.",
    "Version pinning keeps a known good binary in production.",
]


def _corpus(target_tokens: int) -> str:
    """Build deterministic text comfortably longer than `target_tokens`."""
    parts = []
    i = 0
    # This corpus tokenizes at ~5.5 chars/token; overshoot so the trim
    # loop below can always reach the target (it can only shrink text).
    target_chars = int(target_tokens * 6.0)
    while sum(len(p) for p in parts) < target_chars:
        parts.append(f"Section {i}. " + " ".join(
            _SENTENCES[(i + j) % len(_SENTENCES)] for j in range(len(_SENTENCES))
        ))
        i += 1
    return "\n\n".join(parts)


def build_prompt(target: int) -> tuple[str, int]:
    text = _corpus(target)
    n = count_tokens(text)
    for _ in range(6):
        if n <= 0:
            break
        ratio = target / n
        if abs(1.0 - ratio) <= 0.01:
            break
        if ratio > 1.0:
            text = text + "\n\n" + text  # still short: double, then trim next pass
        else:
            text = text[: max(1000, int(len(text) * ratio))]
        n = count_tokens(text)
    return text, n


def ssh(cmd: str, stdin: str | None = None, timeout: int = 60) -> str:
    args = ["ssh", "-o", "ConnectTimeout=10", HOST, cmd]
    r = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"ssh exit {r.returncode}")
    return r.stdout


def post(path: str, payload: dict, timeout: int) -> dict:
    raw = json.dumps(payload)
    if HOST:
        rf = f"/tmp/prefill-{os.getpid()}.json"
        ssh(f"cat > {rf}", stdin=raw, timeout=30)
        try:
            out = ssh(
                f"curl -sS --max-time {timeout} 'http://localhost:{PORT}{path}' "
                f"-H 'Content-Type: application/json' -d '@{rf}'",
                timeout=timeout + 20,
            )
        finally:
            subprocess.run(["ssh", HOST, f"rm -f {rf}"], capture_output=True, timeout=10)
    else:
        out = subprocess.run(
            ["curl", "-sS", "--max-time", str(timeout),
             f"http://localhost:{PORT}{path}",
             "-H", "Content-Type: application/json", "-d", raw],
            capture_output=True, text=True, timeout=timeout + 20,
        ).stdout
    return json.loads(out)


def count_tokens(text: str) -> int:
    data = post("/tokenize", {"content": text, "add_special": False}, 120)
    return len(data.get("tokens", []))


def prefill_once(text: str) -> dict:
    payload = {
        "messages": [{"role": "user", "content": text}],
        "max_tokens": 1,
        "temperature": 0,
        "cache_prompt": False,
        "stream": False,
    }
    t0 = time.time()
    data = post("/v1/chat/completions", payload, TIMEOUT)
    elapsed = time.time() - t0
    if "error" in data:
        return {"error": str(data["error"]), "elapsed_s": round(elapsed, 2)}
    tim = data.get("timings", {})
    return {
        "elapsed_s": round(elapsed, 2),
        "prompt_n": tim.get("prompt_n", 0),
        "prompt_ms": round(tim.get("prompt_ms", 0), 1),
        "prompt_tps": round(tim.get("prompt_per_second", 0), 1),
        "predicted_tps": round(tim.get("predicted_per_second", 0), 1),
    }


def main() -> int:
    print(f"[{datetime.now():%H:%M:%S}] prefill benchmark -> {HOST or 'localhost'}:{PORT}")
    print(f"[{datetime.now():%H:%M:%S}] sizes={SIZES} reps={REPS}")

    # health check
    try:
        code = ssh(f"curl -s -o /dev/null -w '%{{http_code}}' http://localhost:{PORT}/health", timeout=20).strip()
    except Exception as e:
        print(f"ERROR: health check failed: {e}")
        return 1
    if code != "200":
        print(f"ERROR: /health returned {code!r}")
        return 1

    results = []
    for target in SIZES:
        print(f"\n[{datetime.now():%H:%M:%S}] building ~{target} token prompt ...", end=" ", flush=True)
        text, n = build_prompt(target)
        print(f"tokenized to {n} tokens")

        runs = []
        for rep in range(REPS + 1):  # first run is warmup, discarded
            print(f"  run {rep + 1}/{REPS + 1} ...", end=" ", flush=True)
            r = prefill_once(text)
            if "error" in r:
                print(f"FAIL ({r['error'][:80]})")
                runs.append(r)
                continue
            print(f"{r['prompt_tps']} tok/s (prompt {r['prompt_n']} tok, "
                  f"{r['prompt_ms']:.0f} ms, elapsed {r['elapsed_s']} s)")
            if rep > 0:
                runs.append(r)

        good = [r for r in runs if "error" not in r]
        entry = {
            "target_tokens": target,
            "prompt_n": good[0]["prompt_n"] if good else 0,
            "prompt_tps": round(statistics.median([r["prompt_tps"] for r in good]), 1) if good else 0,
            "prompt_ms": round(statistics.median([r["prompt_ms"] for r in good]), 1) if good else 0,
            "predicted_tps": round(statistics.median([r["predicted_tps"] for r in good]), 1) if good else 0,
            "runs": runs,
        }
        results.append(entry)
        print(f"  => {entry['prompt_n']} tok @ {entry['prompt_tps']} tok/s")

    with open(OUT_JSON, "w") as f:
        json.dump(results, f, indent=2)

    with open(OUT_TXT, "w") as f:
        f.write("=" * 62 + "\n")
        f.write("  Server Prefill Benchmark (cache_prompt=false)\n")
        f.write(f"  Host:  {HOST or 'localhost'}:{PORT}\n")
        f.write(f"  Date:  {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        f.write("=" * 62 + "\n\n")
        f.write(f"  {'target':>8}  {'prompt_n':>9}  {'prompt_ms':>10}  {'prompt_t/s':>11}  {'gen_t/s':>8}\n")
        f.write("  " + "-" * 56 + "\n")
        for r in results:
            f.write(f"  {r['target_tokens']:>8}  {r['prompt_n']:>9}  {r['prompt_ms']:>10.0f}  "
                    f"{r['prompt_tps']:>11.1f}  {r['predicted_tps']:>8.1f}\n")
        f.write("\n")

    print(f"\n[{datetime.now():%H:%M:%S}] saved: {OUT_TXT} / {OUT_JSON}")
    print(open(OUT_TXT).read())
    return 0


if __name__ == "__main__":
    sys.exit(main())
