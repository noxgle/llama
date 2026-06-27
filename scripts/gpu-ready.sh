#!/bin/bash
# Wait for NVIDIA GPU to be fully initialized after boot.
# Called by gpu-ready.service before llama@.service starts the container.
# Without this, the model may load while GPU is in low-power state,
# causing degraded throughput (~1.5 tok/s) — the "Post-Reboot Throughput Incident".
set -e

TIMEOUT=180  # max seconds to wait
INTERVAL=2   # poll interval

# Step 1: wait for nvidia-smi to respond
elapsed=0
while ! nvidia-smi -L 2>/dev/null; do
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "ERROR: NVIDIA GPU did not become available within ${TIMEOUT}s" >&2
    nvidia-smi -L 2>&1 || true
    exit 1
  fi
done
echo "OK: NVIDIA GPU detected (${elapsed}s)"

# Step 2: enable persistence mode — keeps GPU initialized across processes,
# prevents re-init delay when Docker container starts
nvidia-smi -pm 1 2>/dev/null || echo "WARN: could not set persistence mode"

# Step 3: wait for memory clock to leave zero/low-power state
for i in $(seq 30); do
  clk=$(nvidia-smi --query-gpu=memory.clock --format=csv,noheader 2>/dev/null | head -1)
  case "$clk" in
    ""|"0 MHz"|"[Not Supported]")
      sleep 2
      continue
      ;;
    *)
      echo "OK: GPU ready, memory clock=${clk}"
      exit 0
      ;;
  esac
done

# Timed out waiting for clock — GPU still likely usable
echo "WARN: GPU memory clock not reported, continuing"
exit 0
