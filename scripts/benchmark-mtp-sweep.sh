#!/usr/bin/env python3
"""MTP draft-n sweep through llama.sh (production parity).

Restarts the Qwen model for each variant by editing SPEC_TYPE /
SPEC_DRAFT_N_MAX in the remote config, then runs a fixed 500-token
generation probe.  Uses llama.sh (not raw docker run) so flags match
production exactly.

NOTE: n_max >= 3 with CTX=143360 on a 6 GB A2000 is known to OOM
(cublas allocation failure).  Default variants stay at off/n1/n2.

Usage:
  HOST=root@192.168.200.38 IMAGE=ghcr.io/noxgle/llama-server:b12167-native \
      python3 scripts/benchmark-mtp-sweep.sh

  VARIANTS="off:,n1:1,n2:2,n3:3" ...   # override variants
  REPS=2                                # measured reps (warmup excluded)

The original remote config is restored on exit (also on failure).

Output:
  ./benchmark-mtp-sweep-<timestamp>.txt
  ./benchmark-mtp-sweep-<timestamp>.json
"""

import json
import os
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime

HOST = os.environ.get("HOST", "root@192.168.200.38")
IMAGE = os.environ.get("IMAGE", "ghcr.io/noxgle/llama-server:b12167-native")
MODEL = os.environ.get("MODEL", "qwen")
CONFIG = os.environ.get("CONFIG", "/opt/llama/configs/qwen3.6-35ba3b-mtp-unsloth.env")
REPO = os.environ.get("REPO", "/opt/llama")
PORT = int(os.environ.get("PORT", 8089))
VARIANTS = os.environ.get("VARIANTS", "off:,n1:1,n2:2")
REPS = int(os.environ.get("REPS", "2"))
TS = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT_TXT = f"benchmark-mtp-sweep-{TS}.txt"
OUT_JSON = f"benchmark-mtp-sweep-{TS}.json"

PROBE = {
    "messages": [{
        "role": "user",
        "content": (
            "Write a detailed analysis of why distributed consensus algorithms "
            "like Raft and Paxos are important for modern database systems. "
            "Include specific examples and technical details. Response should "
            "be thorough and well-structured."
        ),
    }],
    "max_tokens": 500,
    "temperature": 0.1,
    "cache_prompt": False,
    "stream": False,
}
BACKUP = "/tmp/qwen-config-sweep-backup.env"


def ssh(cmd: str, stdin: str | None = None, timeout: int = 120) -> str:
    args = ["ssh", "-o", "ConnectTimeout=10", HOST, cmd]
    r = subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"ssh exit {r.returncode}")
    return r.stdout


def set_variant(spec_type: str, n_max: str) -> None:
    ssh(
        f"sed -i -E 's|^SPEC_TYPE=.*|SPEC_TYPE={spec_type}|; "
        f"s|^SPEC_DRAFT_N_MAX=.*|SPEC_DRAFT_N_MAX={n_max}|' {CONFIG}"
    )


def restart_and_wait(ssh_timeout: int = 420) -> None:
    ssh(f"cd {REPO} && LLAMA_IMAGE={IMAGE} ./llama.sh restart {MODEL}", timeout=ssh_timeout)


def probe_once() -> dict:
    raw = json.dumps(PROBE)
    rf = f"/tmp/sweep-{os.getpid()}.json"
    ssh(f"cat > {rf}", stdin=raw, timeout=30)
    try:
        out = ssh(
            f"curl -sS --max-time 600 'http://localhost:{PORT}/v1/chat/completions' "
            f"-H 'Content-Type: application/json' -d '@{rf}'",
            timeout=620,
        )
    finally:
        subprocess.run(["ssh", HOST, f"rm -f {rf}"], capture_output=True, timeout=10)
    data = json.loads(out)
    if "error" in data:
        return {"error": str(data["error"])}
    tim = data.get("timings", {})
    d_n = tim.get("draft_n", 0)
    d_acc = tim.get("draft_n_accepted", 0)
    return {
        "gen_tps": round(tim.get("predicted_per_second", 0), 2),
        "prompt_tps": round(tim.get("prompt_per_second", 0), 1),
        "draft_n": d_n,
        "draft_acc": d_acc,
        "draft_pct": round(100 * d_acc / d_n, 1) if d_n else 0,
        "predicted_n": tim.get("predicted_n", 0),
    }


def vram_mib() -> int:
    try:
        out = ssh("nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits", timeout=30).strip()
        return int(out.splitlines()[0])
    except Exception:
        return -1


def main() -> int:
    print(f"[{datetime.now():%H:%M:%S}] MTP sweep -> {HOST}")
    print(f"  image={IMAGE} config={CONFIG} variants={VARIANTS} reps={REPS}")

    code = ssh(f"curl -s -o /dev/null -w '%{{http_code}}' http://localhost:{PORT}/health").strip()
    if code != "200":
        print(f"ERROR: /health returned {code!r}")
        return 1

    ssh(f"cp {CONFIG} {BACKUP}")
    results = []
    try:
        for spec in VARIANTS.split(","):
            name, _, n_max = spec.partition(":")
            spec_type = "" if name == "off" else "draft-mtp"
            n_max = n_max or "1"

            print(f"\n[{datetime.now():%H:%M:%S}] variant {name}: SPEC_TYPE={spec_type or '(none)'} "
                  f"SPEC_DRAFT_N_MAX={n_max}")
            set_variant(spec_type, n_max)
            try:
                restart_and_wait()
            except Exception as e:
                print(f"  RESTART FAILED: {e}")
                results.append({"variant": name, "error": f"restart: {e}"})
                continue

            vram = vram_mib()
            runs = []
            for rep in range(REPS + 1):
                print(f"  probe {rep + 1}/{REPS + 1} ...", end=" ", flush=True)
                try:
                    r = probe_once()
                except Exception as e:
                    print(f"FAIL {e}")
                    runs.append({"error": str(e)})
                    continue
                if "error" in r:
                    print(f"FAIL {r['error'][:70]}")
                    runs.append(r)
                    continue
                print(f"{r['gen_tps']} gen t/s, {r['prompt_tps']} pp t/s, "
                      f"draft {r['draft_acc']}/{r['draft_n']} ({r['draft_pct']}%)")
                if rep > 0:
                    runs.append(r)

            good = [r for r in runs if "error" not in r]
            entry = {
                "variant": name,
                "spec_type": spec_type or "off",
                "n_max": 0 if name == "off" else int(n_max),
                "vram_mib": vram,
                "gen_tps": round(statistics.median([r["gen_tps"] for r in good]), 2) if good else 0,
                "prompt_tps": round(statistics.median([r["prompt_tps"] for r in good]), 1) if good else 0,
                "draft_pct": round(statistics.median([r["draft_pct"] for r in good]), 1) if good else 0,
                "runs": runs,
            }
            if not good:
                entry["error"] = "all probes failed"
            results.append(entry)
            print(f"  => {name}: {entry['gen_tps']} gen t/s "
                  f"(draft {entry['draft_pct']}%, VRAM {vram} MiB)")
    finally:
        ssh(f"cp {BACKUP} {CONFIG}")
        print(f"\n[{datetime.now():%H:%M:%S}] restored {CONFIG}")

    ok = [r for r in results if r.get("gen_tps")]
    base = next((r["gen_tps"] for r in ok if r["variant"] == "off"), None)
    with open(OUT_JSON, "w") as f:
        json.dump(results, f, indent=2)

    with open(OUT_TXT, "w") as f:
        f.write("=" * 66 + "\n")
        f.write("  MTP Draft-n Sweep (llama.sh, server probe)\n")
        f.write(f"  Host: {HOST}  image: {IMAGE}\n")
        f.write(f"  Date: {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        f.write("=" * 66 + "\n\n")
        f.write(f"  {'variant':>8}  {'n_max':>5}  {'gen_t/s':>8}  {'pp_t/s':>8}  "
                f"{'draft%':>7}  {'vs off':>7}  {'VRAM':>6}\n")
        f.write("  " + "-" * 62 + "\n")
        for r in results:
            if "error" in r:
                f.write(f"  {r['variant']:>8}  ERROR: {r['error'][:50]}\n")
                continue
            rel = f"{(r['gen_tps'] / base - 1) * 100:+.1f}%" if base and r["variant"] != "off" else "-"
            f.write(f"  {r['variant']:>8}  {r['n_max']:>5}  {r['gen_tps']:>8.2f}  "
                    f"{r['prompt_tps']:>8.0f}  {r['draft_pct']:>7.1f}  {rel:>7}  {r['vram_mib']:>6}\n")
        f.write("\n")
        best = max(ok, key=lambda r: r["gen_tps"], default=None)
        if best:
            f.write(f"  Best variant: {best['variant']} ({best['gen_tps']} gen t/s)\n")

    print("\n" + open(OUT_TXT).read())
    print(f"[{datetime.now():%H:%M:%S}] saved: {OUT_TXT} / {OUT_JSON}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
