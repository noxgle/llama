#!/bin/bash
# Verify NVIDIA GPU is accessible after boot and initialize GPU compute
# pipeline. Without CUDA compute warmup, the first CUDA context after boot
# (from llama-server with MTP speculative decoding) gets stuck in GPU P8
# idle state, resulting in ~1.2 tok/s. A subsequent docker restart fixes
# it, but the warmup avoids the need for that restart.
#
# The warmup creates a CUDA context, allocates GPU memory, and destroys the
# context — this fully initializes the GPU compute pipeline so that the
# subsequent llama-server container gets a properly initialized GPU on the
# very first start.
set -e

TIMEOUT=30
INTERVAL=2
elapsed=0

while ! nvidia-smi -L 2>/dev/null; do
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "ERROR: NVIDIA GPU not available after ${TIMEOUT}s" >&2
    nvidia-smi -L 2>&1 || true
    exit 1
  fi
done

echo "OK: NVIDIA GPU detected (${elapsed}s)"

# CUDA compute pipeline warmup — prevents the "Post-Reboot Throughput Incident"
# where the first CUDA context after boot runs MTP at ~1.2 tok/s.
echo "OK: Running CUDA compute warmup..."
/opt/llama/scripts/cuda-warmup.py 2>&1 || {
  echo "WARNING: CUDA warmup failed (non-fatal)" >&2
}

exit 0
