#!/bin/bash
# ═══════════════════════════════════════════════
# 60-verify.sh — Health check, chat completion, throughput, VRAM
# ═══════════════════════════════════════════════
# Runs inside: LXC container (via pct exec | bash)
# ═══════════════════════════════════════════════

set -euo pipefail

STEP_NAME="60-verify"
echo "=== [STEP $STEP_NAME] Verify deployment ==="

: "${APP_PORT:=8089}"
HEALTH_URL="http://localhost:${APP_PORT}/health"
CHAT_URL="http://localhost:${APP_PORT}/v1/chat/completions"
errors=0

echo ""
# ── 1. Health endpoint ──
echo "--- 1. Health check ---"
HEALTH=$(curl -sf "$HEALTH_URL" 2>/dev/null || echo '{"status":"error"}')
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  echo "  [PASS] Health endpoint returns OK"
  echo "    Response: $HEALTH"
else
  echo "  [FAIL] Health endpoint: $HEALTH"
  errors=$((errors + 1))
fi

echo ""
# ── 2. GPU check (inside container) ──
echo "--- 2. GPU check ---"
if command -v nvidia-smi &>/dev/null; then
  GPU_DATA=$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null || true)
  if [[ -n "$GPU_DATA" ]]; then
    echo "  [PASS] GPU accessible inside container: $GPU_DATA"
    VRAM_USED=$(echo "$GPU_DATA" | grep -oP '\d+ MiB' | head -1 | tr -d ' MiB')
    if [[ -n "$VRAM_USED" && "$VRAM_USED" -gt 0 ]]; then
      echo "  [PASS] VRAM usage: ${VRAM_USED} MiB (GPU working)"
    else
      echo "  [WARN] VRAM shows 0 MiB — possible CPU fallback"
    fi
  else
    echo "  [FAIL] nvidia-smi returns no data inside container"
    errors=$((errors + 1))
  fi
else
  echo "  [WARN] nvidia-smi not available inside container (check GPU passthrough)"
fi

echo ""
# ── 3. Simple chat completion ──
echo "--- 3. Chat completion (smoke test) ---"
RESP=$(
  curl -s --max-time 60 "$CHAT_URL" \
    -H "Content-Type: application/json" \
    -d '{
      "messages": [{"role": "user", "content": "Say hello in one word."}],
      "model": "qwen3.6",
      "max_tokens": 20,
      "temperature": 0.1
    }' 2>/dev/null || echo '{"error":"curl failed"}'
)

if echo "$RESP" | grep -q '"error"'; then
  echo "  [FAIL] Chat completion error: $RESP"
  errors=$((errors + 1))
else
  CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content' 2>/dev/null || echo 'parse error')
  TPS=$(echo "$RESP" | jq -r '.timings.predicted_per_second' 2>/dev/null || echo 'N/A')
  echo "  [PASS] Chat completion successful"
  echo "    Model response: $CONTENT"
  echo "    Throughput: ${TPS} tok/s"
fi

echo ""
# ── 4. Throughput probe ──
echo "--- 4. Throughput probe (longer generation) ---"
PROBE=$(
  curl -s --max-time 180 "$CHAT_URL" \
    -H "Content-Type: application/json" \
    -d '{
      "messages": [{"role": "user", "content": "Write a paragraph about the history of neural networks, approximately 500 characters."}],
      "model": "qwen3.6",
      "max_tokens": 500,
      "temperature": 0.1
    }' 2>/dev/null || echo '{"error":"curl failed"}'
)

if echo "$PROBE" | grep -q '"error"'; then
  echo "  [FAIL] Throughput probe error: $PROBE"
  errors=$((errors + 1))
else
  TPS=$(echo "$PROBE" | jq -r '.timings.predicted_per_second' 2>/dev/null || echo 'N/A')
  COMP_TOKENS=$(echo "$PROBE" | jq -r '.usage.completion_tokens' 2>/dev/null || echo 'N/A')
  PRED_TOKENS=$(echo "$PROBE" | jq -r '.timings.predicted_n' 2>/dev/null || echo 'N/A')
  echo "  [PASS] Throughput probe: ${TPS} tok/s"
  echo "    Completion tokens: $COMP_TOKENS (predicted: $PRED_TOKENS)"
fi

echo ""
# ── 5. MTP acceptance rate (from logs) ──
echo "--- 5. MTP speculative decoding check ---"
MTP_LOG=$(docker logs llama-llama-server-1 2>&1 | grep -i 'mtp\|accept\|draft' | tail -5 || true)
if [[ -n "$MTP_LOG" ]]; then
  echo "  [INFO] MTP stats from logs:"
  echo "$MTP_LOG" | sed 's/^/    /'
else
  echo "  [INFO] No MTP stats in recent logs (may need a few more requests)"
  DRAFT_SETTING=$(docker logs llama-llama-server-1 2>&1 | grep -i 'spec.*draft\|draft.*n.max\|spec.*type' | tail -3 || true)
  if [[ -n "$DRAFT_SETTING" ]]; then
    echo "  [INFO] MTP configuration:"
    echo "$DRAFT_SETTING" | sed 's/^/    /'
  fi
fi

echo ""
# ── 6. Log scan for errors ──
echo "--- 6. Error log scan ---"
ERRORS=$(docker logs llama-llama-server-1 2>&1 | grep -i 'error\|fatal\|segfault\|cuda.*fail\|abort' | grep -v 'OS error\|address already in use' | head -10 || true)
if [[ -n "$ERRORS" ]]; then
  echo "  [WARN] Potential issues found in logs:"
  echo "$ERRORS" | sed 's/^/    /'
else
  echo "  [PASS] No errors in recent logs"
fi

echo ""
# ── Summary ──
if [[ $errors -eq 0 ]]; then
  echo "  ✅ All checks passed. Deployment is operational."
  echo ""
  echo "  Server: http://localhost:${APP_PORT}/v1/chat/completions"
  echo "  Health: http://localhost:${APP_PORT}/health"
else
  echo "  ❌ $errors check(s) failed. Review output above."
  exit 1
fi

echo ""
echo "=== [STEP $STEP_NAME] Complete ==="
