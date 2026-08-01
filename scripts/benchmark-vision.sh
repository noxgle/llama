#!/usr/bin/env python3
"""Gemma 4 E2B Vision benchmark — tests all parameter combos for multimodal speed.

Usage:
  python3 scripts/benchmark-vision.sh                          # localhost
  HOST=root@192.168.200.38 python3 scripts/benchmark-vision.sh # remote (default)
  PORT=9999 python3 scripts/benchmark-vision.sh                # custom port
  PARAMS=BATCH,THREADS python3 scripts/benchmark-vision.sh     # subset of params

Output:
  benchmark-vision-<timestamp>.txt  — human-readable report
  benchmark-vision-<timestamp>.json — machine-readable results

Flow per parameter value:
  1. Generate 5 synthetic test images (once)
  2. Apply config on server (SSH set .env + restart)
  3. Wait for model to load (health check)
  4. Warmup: 1 cycle (discarded)
  5. 5 cycles with test images
  6. Collect: total, TTFT, predict, tok/s, VRAM, MTP acceptance
"""

import json
import os
import subprocess
import sys
import time
import base64
import io
import random
from datetime import datetime

# ---- CONFIG ----
HOST = os.environ.get("HOST", "root@192.168.200.38")
PORT = int(os.environ.get("PORT", 8089))
REMOTE_DIR = "/opt/llama"
TIMEOUT = 60  # per request
WARMUP = 1
CYCLES = 5
TS = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT_TXT = f"benchmark-vision-{TS}.txt"
OUT_JSON = f"benchmark-vision-{TS}.json"

# Generate 5 test images once
try:
    from PIL import Image, ImageDraw
except ImportError:
    print("[ERROR] pip install Pillow")
    sys.exit(1)

TEST_IMAGES = []
for i in range(5):
    r, g, b = random.randint(200, 255), random.randint(200, 255), random.randint(200, 255)
    img = Image.new("RGB", (640, 480), color=(r, g, b))
    draw = ImageDraw.Draw(img)
    c = (random.randint(0, 100), random.randint(0, 100), random.randint(0, 100))
    draw.ellipse([100, 100, 540, 380], fill=c, outline="black")
    draw.text((250, 220), f"Frame {i+1}", fill="white")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=60)
    TEST_IMAGES.append(base64.b64encode(buf.getvalue()).decode())

# ---- SSH helpers ----
def ssh(cmd):
    """Run command on remote, return stdout."""
    full = ["ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no",
            HOST, f"cd {REMOTE_DIR} && {cmd}"]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=30)
        return (r.stdout or "").strip()
    except Exception as e:
        return f"[exception] {e}"


def set_env(key, val):
    """Set key=val in .env via sed."""
    k = key.replace("/", r"\/")
    v = str(val).replace("/", r"\/")
    ssh(f"sed -i 's/^{k}=.*/{k}={v}/' .env")


def restart():
    """Docker compose restart, wait for health."""
    ssh("docker compose down && docker compose up -d")
    for _ in range(40):
        time.sleep(2)
        r = ssh("curl -s -o /dev/null -w '%{{http_code}}' http://localhost:{0}/health 2>/dev/null || echo wait".format(PORT))
        if r.strip() == "200":
            time.sleep(2)
            return True
        st = ssh("docker inspect --format='{{.State.Status}}' llama-llama-server-1 2>/dev/null")
        if "exited" in st:
            logs = ssh("docker compose logs --tail=5 2>/dev/null")
            print(f"  [FAIL] container exited:\n  {logs[:300]}")
            return False
    print(f"  [FAIL] health timeout")
    return False


def vram():
    r = ssh("nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null || echo err")
    try:
        return int(r.replace(" MiB", ""))
    except:
        return -1


def run_cycle(b64):
    """Send image request, return metrics dict."""
    pid = os.getpid()
    rf = f"/tmp/vp-{pid}.json"
    payload = json.dumps({
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            {"type": "text", "text": "Describe this image in 1 short sentence."}
        ]}],
        "max_tokens": 50,
    })
    try:
        subprocess.run(["ssh", HOST, f"cat > {rf}"], input=payload, text=True, timeout=10)
    except Exception as e:
        return {"error": f"write:{e}"}

    t0 = time.time()
    try:
        r = subprocess.run(
            ["ssh", HOST, f"curl -sS --max-time {TIMEOUT} 'http://localhost:{PORT}/v1/chat/completions' -H 'Content-Type: application/json' -d '@{rf}'"],
            capture_output=True, text=True, timeout=TIMEOUT + 10)
        raw, elapsed = r.stdout, round(time.time() - t0, 3)
    except subprocess.TimeoutExpired:
        subprocess.run(["ssh", HOST, f"rm -f {rf}"], capture_output=True, timeout=5)
        return {"error": "timeout", "total_s": round(time.time() - t0, 3)}
    except Exception as e:
        subprocess.run(["ssh", HOST, f"rm -f {rf}"], capture_output=True, timeout=5)
        return {"error": str(e), "total_s": round(time.time() - t0, 3)}
    subprocess.run(["ssh", HOST, f"rm -f {rf}"], capture_output=True, timeout=5)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {"error": "bad JSON", "total_s": elapsed}
    if "error" in data:
        return {"error": str(data["error"]), "total_s": elapsed}
    choices = data.get("choices", [])
    if not choices:
        return {"error": "no choices", "total_s": elapsed}

    tim = data.get("timings", {})
    msg = choices[0].get("message", {})
    return {
        "total_s": elapsed,
        "ttft_s": round(tim.get("prompt_ms", 0) / 1000, 3),
        "predict_s": round(tim.get("predicted_ms", 0) / 1000, 3),
        "tok_s": tim.get("predicted_per_second", 0),
        "n_pred": tim.get("predicted_n", 0),
        "n_prompt": tim.get("prompt_n", 0),
        "draft_n": tim.get("draft_n", 0),
        "draft_acc": tim.get("draft_n_accepted", 0),
        "text": (msg.get("content") or "")[:80],
        "finish": choices[0].get("finish_reason", ""),
    }


def avg(cycles, key):
    vals = [c.get(key, 0) for c in cycles if "error" not in c]
    return sum(vals) / len(vals) if vals else 0


def fmt(sec):
    return f"{sec*1000:.0f}ms"


# ---- PARAMETER GRID ----
BASELINE = {
    "IMAGE_MAX_TOKENS": "128",
    "IMAGE_MIN_TOKENS": "66",
    "BATCH": "2048",
    "UBATCH": "512",
    "SPEC_DRAFT_N_MAX": "3",
    "REASONING": "off",
    "POLL": "0",
    "NO_HOST": "--no-host",
    "CTX": "16384",
    "THREADS": "4",
    "THREADS_BATCH": "4",
    "CACHE_RAM": "512",
    "MTMD_BATCH_MAX_TOKENS": "256",
}

VARIANTS = {
    "IMAGE_MAX_TOKENS":  ["64", "256", "512"],
    "BATCH":             ["512", "1024", "4096"],
    "UBATCH":            ["256", "1024"],
    "SPEC_DRAFT_N_MAX":  ["1", "2"],
    "REASONING":         ["on"],
    "POLL":              ["50"],
    "NO_HOST":           [""],           # empty = remove flag
    "CTX":               ["8192"],
    "THREADS":           ["2", "6"],
    "THREADS_BATCH":     ["2", "6"],
}

FILTER = os.environ.get("PARAMS", "")
if FILTER:
    wanted = {p.strip() for p in FILTER.split(",")}
    VARIANTS = {k: v for k, v in VARIANTS.items() if k in wanted}


def apply_config(changes: dict):
    """Copy baseline config + apply overrides. Then restart."""
    ssh("cp configs/gemma4-e2b-q4-k-m-mtp-fast-v2.env .env")
    for k, v in BASELINE.items():
        set_env(k, v)
    for k, v in changes.items():
        set_env(k, v)
    # Extra: IMAGE_MAX_TOKENS must not be < IMAGE_MIN_TOKENS
    imax = changes.get("IMAGE_MAX_TOKENS")
    imin = changes.get("IMAGE_MIN_TOKENS", BASELINE["IMAGE_MIN_TOKENS"])
    if imax and int(imax) < int(imin):
        set_env("IMAGE_MIN_TOKENS", imax)  # lower min to match max
    return restart()


# ---- MAIN ----
def main():
    print(f"[{TS}] ===== Gemma 4 E2B Vision Benchmark =====")
    print(f"[{TS}] Target: {HOST}:{PORT}")
    print(f"[{TS}] Params: {', '.join(VARIANTS.keys())}")
    print(f"[{TS}] Output: {OUT_TXT} / {OUT_JSON}")

    # --- Baseline ---
    print(f"\n[{datetime.now():%H:%M:%S}] === Baseline ===")
    ok = apply_config({})
    if not ok:
        print("[ABORT] Baseline failed")
        sys.exit(1)
    print(f"[{datetime.now():%H:%M:%S}] Running {WARMUP+CYCLES} cycles...")

    base_cycles = []
    for i in range(WARMUP + CYCLES):
        img = TEST_IMAGES[i % len(TEST_IMAGES)]
        res = run_cycle(img)
        res["cycle"] = i + 1
        if i < WARMUP:
            print(f"  [warmup] {res.get('total_s',0):.3f}s  tok/s={res.get('tok_s',0):.1f}")
        else:
            base_cycles.append(res)
            e = "ERROR" if "error" in res else ""
            print(f"  [cycle {i+1}] {res.get('total_s',0):.3f}s  ttft={res.get('ttft_s',0):.3f}s  tok/s={res.get('tok_s',0):.1f}  {e}")

    v0 = vram()
    ba_total = avg(base_cycles, "total_s")
    ba_ttft = avg(base_cycles, "ttft_s")
    ba_tok = avg(base_cycles, "tok_s")
    print(f"  => avg: {fmt(ba_total)} cycle, {fmt(ba_ttft)} TTFT, {ba_tok:.1f} tok/s, {v0} MiB")

    results = [{
        "label": "baseline",
        "cycles": base_cycles,
        "vram": v0,
        "avg_total_s": ba_total,
        "avg_ttft_s": ba_ttft,
        "avg_tok_s": ba_tok,
        "delta_pct": 0,
    }]

    # --- Variants ---
    for param, values in VARIANTS.items():
        for val in values:
            label = f"{param}={val}"
            print(f"\n[{datetime.now():%H:%M:%S}] === {label} ===")
            ok = apply_config({param: val})
            if not ok:
                print(f"  [SKIP] {label} failed to load")
                continue

            print(f"  Running {WARMUP+CYCLES} cycles...")
            cycles = []
            for i in range(WARMUP + CYCLES):
                img = TEST_IMAGES[i % len(TEST_IMAGES)]
                res = run_cycle(img)
                res["cycle"] = i + 1
                if i < WARMUP:
                    print(f"  [warmup] {res.get('total_s',0):.3f}s  tok/s={res.get('tok_s',0):.1f}")
                else:
                    cycles.append(res)
                    e = "ERROR" if "error" in res else ""
                    print(f"  [cycle {i+1}] {res.get('total_s',0):.3f}s  ttft={res.get('ttft_s',0):.3f}s  tok/s={res.get('tok_s',0):.1f}  {e}")

            v1 = vram()
            a_total = avg(cycles, "total_s")
            a_ttft = avg(cycles, "ttft_s")
            a_tok = avg(cycles, "tok_s")
            dpct = round((a_tok - ba_tok) / ba_tok * 100, 1) if ba_tok else 0

            results.append({
                "label": label,
                "cycles": cycles,
                "vram": v1,
                "avg_total_s": round(a_total, 3),
                "avg_ttft_s": round(a_ttft, 3),
                "avg_tok_s": round(a_tok, 1),
                "avg_n_pred": round(avg(cycles, "n_pred"), 1),
                "delta_pct": dpct,
            })
            print(f"  => avg: {fmt(a_total)} cycle ({round((a_total-ba_total)/ba_total*100,1):+.1f}%), "
                  f"{fmt(a_ttft)} TTFT, {a_tok:.1f} tok/s ({dpct:+.1f}%), {v1} MiB")

    # --- Restore baseline ---
    print(f"\n[{datetime.now():%H:%M:%S}] Restoring baseline...")
    apply_config({})

    # --- Write outputs ---
    json_out = {"ts": TS, "host": HOST, "baseline": BASELINE, "results": results}
    with open(OUT_JSON, "w") as f:
        json.dump(json_out, f, indent=2)

    with open(OUT_TXT, "w") as f:
        f.write("=" * 65 + "\n")
        f.write(f"  Gemma 4 E2B Vision Benchmark\n")
        f.write(f"  Host: {HOST}:{PORT}  Date: {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        f.write("=" * 65 + "\n\n")
        f.write(f"{'Test':<28} {'Cycle':>8} {'TTFT':>8} {'tok/s':>8} {'tok%':>7} {'VRAM':>7}\n")
        f.write("-" * 66 + "\n")
        for r in results:
            d = f"{r['delta_pct']:+.1f}%" if r["delta_pct"] != 0 else "  —"
            f.write(f"{r['label']:<28} {fmt(r['avg_total_s']):>8} {fmt(r['avg_ttft_s']):>8} "
                    f"{r['avg_tok_s']:>7.1f} {d:>7} {r['vram']:>4}MiB\n")
        f.write("\n")
        for r in results:
            f.write(f"--- {r['label']} ---\n")
            f.write(f"  VRAM: {r['vram']} MiB\n")
            for c in r["cycles"]:
                if "error" in c:
                    f.write(f"  cycle {c['cycle']}: ERROR {c['error']}\n")
                else:
                    f.write(f"  cycle {c['cycle']}: {fmt(c['total_s'])} tot, {fmt(c['ttft_s'])} ttft, "
                            f"{c['tok_s']:.1f} tok/s, {c['n_pred']} pred\n")
            f.write("\n")

    # --- Print table ---
    print(f"\n[{datetime.now():%H:%M:%S}] ===== RESULTS =====")
    print(f"{'Test':<28} {'Cycle':>8} {'TTFT':>8} {'tok/s':>8} {'tok%':>7} {'VRAM':>7}")
    print("-" * 66)
    for r in results:
        d = f"{r['delta_pct']:+.1f}%" if r["delta_pct"] != 0 else "  —"
        print(f"{r['label']:<28} {fmt(r['avg_total_s']):>8} {fmt(r['avg_ttft_s']):>8} "
              f"{r['avg_tok_s']:>7.1f} {d:>7} {r['vram']:>4}MiB")
    print(f"\n[{datetime.now():%H:%M:%S}] Report: {OUT_TXT}")
    print(f"[{datetime.now():%H:%M:%S}] Done!")


if __name__ == "__main__":
    main()
