#!/bin/bash
# Verify NVIDIA GPU is accessible after boot.
# Called by gpu-ready.service. The primary fix for the
# "Post-Reboot Throughput Incident" is nvidia-persistenced.service
# keeping GPU driver state initialized across reboots.
# This script is a safety net.
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
exit 0
