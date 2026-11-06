#!/usr/bin/env python3
"""MTP soak test — detect host-memory growth during draft-mtp traffic.

Issue #31392: llama-server with --spec-type draft-mtp rebuilt the
scheduler on every request (unconditional sched_need_reserve in
set_sampler) and host anonymous memory grew ~85 MiB per request,
never released.  This script sends N sequential requests with
cache_prompt=false (so the prompt cache cannot mask the leak) and
samples the container's cgroup anon memory.

A healthy server is flat: delta per request within a few MiB.
Thresholds: WARN >= 8 MiB/request or >= 300 MiB total.

Usage:
  HOST=root@192.168.200.38 python3 scripts/benchmark-mtp-soak.sh
  REQUESTS=50 PROMPT_TOKENS=8000 MAX_TOKENS=64 \
      HOST=root@192.168.200.38 python3 scripts/benchmark-mtp-soak.sh

Output:
  ./benchmark-mtp-soak-<timestamp>.txt
  ./benchmark-mtp-soak-<timestamp>.json
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

HOST = os.environ.get("HOST", "root@192.168.200.38")
PORT = int(os.environ.get("PORT", 8089))
CONTAINER = os.environ.get("CONTAINER", "")
REQUESTS = int(os.environ.get("REQUESTS", "50"))
PROMPT_TOKENS = int(os.environ.get("PROMPT_TOKENS", "8000"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "64"))
SAMPLE_EVERY = int(os.environ.get("SAMPLE_EVERY", "5"))
TIMEOUT = int(os.environ.get("TIMEOUT", 900))
TS = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT_TXT = f"benchmark-mtp-soak-{TS}.txt"
OUT_JSON = f"benchmark-mtp-soak-{TS}.json"

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
]


def ssh(cmd: str, stdin: str | None = None, timeout: int = 60) -> str:
    args = ["ssh", "-o", "ConnectTimeout=10", HOST, cmd]
    r = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"ssh exit {r.returncode}")
    return r.stdout


def post(path: str, payload: dict, timeout: int) -> dict:
    raw = json.dumps(payload)
    rf = f"/tmp/soak-{os.getpid()}.json"
    ssh(f"cat > {rf}", stdin=raw, timeout=30)
    try:
        out = ssh(
            f"curl -sS --max-time {timeout} 'http://localhost:{PORT}{path}' "
            f"-H 'Content-Type: application/json' -d '@{rf}'",
            timeout=timeout + 20,
        )
    finally:
        subprocess.run(["ssh", HOST, f"rm -f {rf}"], capture_output=True, timeout=10)
    return json.loads(out)


def detect_container() -> str:
    if CONTAINER:
        return CONTAINER
    out = ssh("docker ps --filter name=llama- --format '{{.Names}}'").strip().splitlines()
    if not out:
        raise RuntimeError("no running llama-* container found")
    return out[0]


def anon_mib(container: str) -> float:
    """Container anonymous memory in MiB (cgroup v2), -1 on failure."""
    try:
        out = ssh(
            f"docker exec {container} sh -c 'grep \"^anon \" /sys/fs/cgroup/memory.stat' 2>/dev/null",
            timeout=20,
        ).strip()
        m = re.search(r"^anon\s+(\d+)", out)
        if m:
            return int(m.group(1)) / 1048576.0
    except Exception:
        pass
    try:
        out = ssh(f"docker stats --no-stream --format '{{{{.MemUsage}}}}' {container}", timeout=20).strip()
        m = re.match(r"([\d.]+)\s*(GiB|MiB)", out)
        if m:
            val = float(m.group(1))
            return val * 1024 if m.group(2) == "GiB" else val
    except Exception:
        pass
    return -1.0


def realloc_count(container: str) -> int:
    try:
        out = ssh(f"docker logs {container} 2>&1 | grep -c sched_graph_realloc || true", timeout=30)
        return int(out.strip() or 0)
    except Exception:
        return -1


def build_text() -> str:
    parts = []
    # Corpus tokenizes at ~5.5 chars/token; slight overshoot is fine.
    target_chars = int(PROMPT_TOKENS * 5.8)
    total, i = 0, 0
    while total < target_chars:
        p = f"Section {i}. " + " ".join(
            _SENTENCES[(i + j) % len(_SENTENCES)] for j in range(len(_SENTENCES))
        )
        parts.append(p)
        total += len(p) + 2
        i += 1
    return "\n\n".join(parts)


def main() -> int:
    print(f"[{datetime.now():%H:%M:%S}] MTP soak -> {HOST}:{PORT}")
    container = detect_container()
    print(f"[{datetime.now():%H:%M:%S}] container: {container}")

    code = ssh(f"curl -s -o /dev/null -w '%{{http_code}}' http://localhost:{PORT}/health").strip()
    if code != "200":
        print(f"ERROR: /health returned {code!r}")
        return 1

    text = build_text()
    payload_base = {
        "messages": [{"role": "user", "content": text}],
        "temperature": 0.1,
        "max_tokens": MAX_TOKENS,
        "cache_prompt": False,
        "stream": False,
    }

    mem0 = anon_mib(container)
    realloc0 = realloc_count(container)
    print(f"[{datetime.now():%H:%M:%S}] start anon={mem0:.0f} MiB realloc={realloc0}")
    print(f"[{datetime.now():%H:%M:%S}] {REQUESTS} requests x {MAX_TOKENS} tok output")

    samples = [{"req": 0, "anon_mib": round(mem0, 1)}]
    results = []
    t_start = time.time()
    for i in range(1, REQUESTS + 1):
        t0 = time.time()
        try:
            data = post("/v1/chat/completions", payload_base, TIMEOUT)
        except Exception as e:
            print(f"  req {i:>3}: FAIL {e}")
            results.append({"req": i, "error": str(e)})
            continue
        elapsed = time.time() - t0
        if "error" in data:
            print(f"  req {i:>3}: FAIL {str(data['error'])[:70]}")
            results.append({"req": i, "error": str(data["error"])})
            continue
        tim = data.get("timings", {})
        r = {
            "req": i,
            "elapsed_s": round(elapsed, 2),
            "prompt_tps": round(tim.get("prompt_per_second", 0), 1),
            "gen_tps": round(tim.get("predicted_per_second", 0), 1),
            "prompt_n": tim.get("prompt_n", 0),
            "draft_n": tim.get("draft_n", 0),
            "draft_acc": tim.get("draft_n_accepted", 0),
        }
        results.append(r)

        if i % SAMPLE_EVERY == 0 or i == REQUESTS:
            m = anon_mib(container)
            samples.append({"req": i, "anon_mib": round(m, 1)})
            print(f"  req {i:>3}: {r['gen_tps']:>5.1f} gen t/s | {r['prompt_tps']:>6.0f} pp t/s | "
                  f"anon={m:7.0f} MiB | draft={r['draft_acc']}/{r['draft_n']}")

    total_time = time.time() - t_start
    mem_end = anon_mib(container)
    realloc1 = realloc_count(container)
    ok = [r for r in results if "error" not in r]
    first_gen = [r["gen_tps"] for r in ok[:5]]
    last_gen = [r["gen_tps"] for r in ok[-5:]]
    delta = mem_end - mem0
    per_req = delta / REQUESTS if REQUESTS else 0
    leak = delta >= 300 and per_req >= 8

    summary = {
        "host": HOST,
        "container": container,
        "requests": REQUESTS,
        "ok": len(ok),
        "failed": REQUESTS - len(ok),
        "prompt_tokens": ok[0]["prompt_n"] if ok else 0,
        "duration_s": round(total_time, 1),
        "anon_start_mib": round(mem0, 1),
        "anon_end_mib": round(mem_end, 1),
        "anon_delta_mib": round(delta, 1),
        "anon_per_request_mib": round(per_req, 2),
        "realloc_start": realloc0,
        "realloc_end": realloc1,
        "gen_tps_first5": round(sum(first_gen) / len(first_gen), 1) if first_gen else 0,
        "gen_tps_last5": round(sum(last_gen) / len(last_gen), 1) if last_gen else 0,
        "leak_suspected": leak,
    }

    with open(OUT_JSON, "w") as f:
        json.dump({"summary": summary, "samples": samples, "results": results}, f, indent=2)

    with open(OUT_TXT, "w") as f:
        f.write("=" * 62 + "\n")
        f.write("  MTP Soak Test (host anon memory)\n")
        f.write(f"  Host: {HOST}  container: {container}\n")
        f.write(f"  Date: {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        f.write("=" * 62 + "\n\n")
        f.write(f"  requests         : {REQUESTS} ({len(ok)} ok, {REQUESTS - len(ok)} failed)\n")
        f.write(f"  prompt tokens    : {summary['prompt_tokens']}\n")
        f.write(f"  duration         : {summary['duration_s']:.0f} s\n")
        f.write(f"  anon start / end : {summary['anon_start_mib']:.0f} / {summary['anon_end_mib']:.0f} MiB\n")
        f.write(f"  anon delta       : {summary['anon_delta_mib']:+.0f} MiB"
                f"  ({summary['anon_per_request_mib']:+.2f} MiB/request)\n")
        f.write(f"  sched_graph_realloc: {summary['realloc_start']} -> {summary['realloc_end']}\n")
        f.write(f"  gen t/s first5 / last5: {summary['gen_tps_first5']:.1f} / {summary['gen_tps_last5']:.1f}\n")
        f.write(f"  VERDICT          : {'LEAK SUSPECTED' if leak else 'FLAT (no leak detected)'}\n\n")
        f.write("  request   gen_t/s   pp_t/s   draft\n")
        f.write("  " + "-" * 42 + "\n")
        for r in results:
            if "error" in r:
                f.write(f"  {r['req']:>7}   ERROR {r['error'][:40]}\n")
            else:
                f.write(f"  {r['req']:>7}   {r['gen_tps']:>7.1f}   {r['prompt_tps']:>7.0f}   "
                        f"{r['draft_acc']}/{r['draft_n']}\n")
        f.write("\n  anon memory samples (MiB):\n")
        for s in samples:
            f.write(f"    req {s['req']:>3}: {s['anon_mib']:.0f}\n")

    print("\n" + open(OUT_TXT).read())
    print(f"[{datetime.now():%H:%M:%S}] saved: {OUT_TXT} / {OUT_JSON}")
    return 0 if not leak else 2


if __name__ == "__main__":
    sys.exit(main())
