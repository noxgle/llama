#!/bin/bash
# Guarded remote benchmark for llama-server.
# Aborts immediately if GPU fallback is detected.

set -euo pipefail

HOST="${HOST:-root@192.168.200.38}"
PROJECT_DIR="${PROJECT_DIR:-/opt/llama}"
CONTAINER="${CONTAINER:-llama-llama-server-1}"
API_URL="${API_URL:-http://localhost:8089/v1/chat/completions}"
RUNS="${RUNS:-5}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-30}"

check_gpu_or_abort() {
  local host_vram
  host_vram=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$HOST" \
    "nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | tr -d ' MiB' | head -1 || echo -1")

  if [[ -z "${host_vram}" || "${host_vram}" == "-1" ]]; then
    echo "[ABORT] Could not read host VRAM usage"
    exit 20
  fi

  if [[ "${host_vram}" -eq 0 ]]; then
    echo "[ABORT] CPU fallback detected: host VRAM is 0 MiB"
    exit 21
  fi

  local in_vram
  in_vram=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$HOST" \
    "docker exec ${CONTAINER} nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | tr -d ' MiB' | head -1 || echo -1")

  if [[ -z "${in_vram}" || "${in_vram}" == "-1" ]]; then
    echo "[ABORT] Could not read container VRAM usage"
    exit 22
  fi

  if [[ "${in_vram}" -eq 0 ]]; then
    echo "[ABORT] CPU fallback detected: container VRAM is 0 MiB"
    exit 23
  fi

  if ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$HOST" \
    "docker logs --tail=80 ${CONTAINER} 2>&1 | grep -E 'ggml_cuda_init: failed|no usable GPU found' >/dev/null"; then
    echo "[ABORT] CPU fallback signature found in logs"
    exit 24
  fi
}

check_service_or_abort() {
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$HOST" \
    "cd ${PROJECT_DIR} && docker compose ps --status running | grep -q ${CONTAINER}" || {
      echo "[ABORT] Container ${CONTAINER} is not running"
      exit 10
    }

  local code
  code=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$HOST" \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:8089/health || true")
  if [[ "${code}" != "200" ]]; then
    echo "[ABORT] Health endpoint is not 200 (got ${code})"
    exit 11
  fi
}

run_case() {
  local name="$1"
  local prompt="$2"

  echo ""
  echo "=== CASE: ${name} ==="
  for i in $(seq 1 "$RUNS"); do
    check_service_or_abort
    check_gpu_or_abort

    echo "run ${i}/${RUNS}..."

    python3 - "$HOST" "$API_URL" "$REQUEST_TIMEOUT" "$prompt" <<'PY'
import json, subprocess, sys, time

host, url, timeout_s, prompt = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
payload = json.dumps({
  "messages": [{"role": "user", "content": prompt}],
  "model": "gemma-4",
  "temperature": 0.1
})
cmd = [
  "ssh", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=no", host,
  f"curl -sS --max-time {timeout_s} {url} -H 'Content-Type: application/json' -d '{payload}'"
]
t0 = time.time()
p = subprocess.run(cmd, capture_output=True, text=True)
dt = time.time() - t0
if p.returncode != 0:
  print(f"ERROR rc={p.returncode} elapsed={dt:.2f}s")
  sys.exit(30)
try:
  obj = json.loads(p.stdout)
except Exception as e:
  print(f"ERROR json_parse elapsed={dt:.2f}s msg={e}")
  sys.exit(31)
tim = obj.get("timings") or {}
usage = obj.get("usage") or {}
choice = (obj.get("choices") or [{}])[0]
print("OK",
      f"elapsed={dt:.2f}s",
      f"tps={tim.get('predicted_per_second')}",
      f"comp_tokens={usage.get('completion_tokens')}",
      f"finish={choice.get('finish_reason')}")
PY

    check_gpu_or_abort
    sleep 2
  done
}

run_smoke_hello() {
  echo ""
  echo "=== SMOKE: hello ==="

  check_service_or_abort
  check_gpu_or_abort

  python3 - "$HOST" "$API_URL" "$SMOKE_TIMEOUT" <<'PY'
import json, subprocess, sys, time

host, url, timeout_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
payload = json.dumps({
  "messages": [{"role": "user", "content": "hello"}],
  "model": "gemma-4",
  "temperature": 0.1
})
cmd = [
  "ssh", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=no", host,
  f"curl -sS --max-time {timeout_s} {url} -H 'Content-Type: application/json' -d '{payload}'"
]
t0 = time.time()
p = subprocess.run(cmd, capture_output=True, text=True)
dt = time.time() - t0
if p.returncode != 0:
  print(f"SMOKE ERROR rc={p.returncode} elapsed={dt:.2f}s")
  sys.exit(40)
try:
  obj = json.loads(p.stdout)
except Exception as e:
  print(f"SMOKE ERROR json_parse elapsed={dt:.2f}s msg={e}")
  sys.exit(41)

tim = obj.get("timings") or {}
usage = obj.get("usage") or {}
choice = (obj.get("choices") or [{}])[0]
print("SMOKE OK",
      f"elapsed={dt:.2f}s",
      f"tps={tim.get('predicted_per_second')}",
      f"comp_tokens={usage.get('completion_tokens')}",
      f"finish={choice.get('finish_reason')}")
PY

  check_gpu_or_abort
  echo "SMOKE PASSED: GPU path looks healthy."
}

SHORT_PROMPT="Explain what a neural network is in 2-3 sentences."
LONG_PROMPT="You are writing a concise technical note for engineers. Compare supervised learning, unsupervised learning, and reinforcement learning. Include practical use-cases, typical failure modes, and when each is a bad fit. Keep it structured with short sections."

echo "Running guarded benchmark on ${HOST}"
echo "Runs per case: ${RUNS}, request timeout: ${REQUEST_TIMEOUT}s"
echo "Smoke timeout: ${SMOKE_TIMEOUT}s"

run_smoke_hello

run_case "short" "${SHORT_PROMPT}"
run_case "long" "${LONG_PROMPT}"

echo ""
echo "Benchmark finished without CPU fallback."
