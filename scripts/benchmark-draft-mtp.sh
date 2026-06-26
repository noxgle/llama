#!/usr/bin/env bash
"""MTP / speculative decoding parameter benchmark runner.

Usage:
  HOST=root@192.168.200.38 bash scripts/benchmark-draft-mtp.sh

Runs a series of tests varying SPEC_DRAFT_N_MAX and MTP on/off,
compares generation speed via a 500-token curl probe.
"""

set -euo pipefail

HOST="${HOST:-root@192.168.200.38}"
IMAGE="ghcr.io/noxgle/llama-server:latest"
CONFIG_DIR="/opt/llama/configs"

SSH="sshpass -p '123456' ssh $HOST"
SCP="sshpass -p '123456' scp"

RESULTS_DIR="/tmp/mtp-benchmark-results"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/results.txt"

echo "MTP Draft Benchmark Results" > "$RESULTS_FILE"
echo "===========================" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# ---- helper: run one test ----
# Args: test_name, env_modifications (semicolon-separated KEY=VAL statements)
run_test() {
  local name="$1"
  local env_mods="$2"

  echo ""
  echo "=============================================="
  echo "  TEST: $name"
  echo "=============================================="

  # Copy base config to a temporary file with modifications
  $SSH "
    cp /opt/llama/.env.backup /opt/llama/.env 2>/dev/null || true
    cp $CONFIG_DIR/qwen3.6-35ba3b-mtp-unsloth.env /opt/llama/.env
  "

  # Apply modifications
  IFS=';' read -ra MODS <<< "$env_mods"
  for mod in "${MODS[@]}"; do
    if [ -n "$mod" ]; then
      local key="${mod%%=*}"
      local val="${mod#*=}"
      echo "  Setting: $key=$val"
      $SSH "
        if grep -q '^${key}=' /opt/llama/.env; then
          sed -i 's|^${key}=.*|${key}=${val}|' /opt/llama/.env
        else
          echo '${key}=${val}' >> /opt/llama/.env
        fi
      "
    fi
  done

  # Stop any existing containers
  $SSH "
    docker ps --filter name=llama --format '{{.Names}}' | xargs -r docker stop 2>/dev/null || true
    docker ps --filter name=llama -a --format '{{.Names}}' | xargs -r docker rm 2>/dev/null || true
    sleep 1
  "

  # Read back the full .env
  $SSH "cat /opt/llama/.env" > /tmp/test_env.txt

  # Build docker run command
  local ctn_name="llama-mtp-test-$name"
  local ctx=$(grep '^CTX=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local model=$(grep '^MODEL=' /tmp/test_env.txt | head -1 | cut -d= -f2-)
  local model_flag=$(grep '^MODEL_FLAG=' /tmp/test_env.txt | head -1 | cut -d= -f2-)
  local ngl=$(grep '^NGLAYERS=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local cpumoe=$(grep '^CPUMOE=' /tmp/test_env.txt | head -1 | cut -d= -f2-)
  local fa=$(grep '^FLASHATTN=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local batch=$(grep '^BATCH=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local ubatch=$(grep '^UBATCH=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local threads=$(grep '^THREADS=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local threads_batch=$(grep '^THREADS_BATCH=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local parallel=$(grep '^PARALLEL=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local poll=$(grep '^POLL=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local ctk=$(grep '^CACHE_TYPE_K=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local ctv=$(grep '^CACHE_TYPE_V=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local ckpt=$(grep '^CTX_CHECKPOINTS=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local n_pred=$(grep '^N_PREDICT=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local spec_type=$(grep '^SPEC_TYPE=' /tmp/test_env.txt | head -1 | cut -d= -f2)
  local spec_n=$(grep '^SPEC_DRAFT_N_MAX=' /tmp/test_env.txt | head -1 | cut -d= -f2)

  # Build LLAMA_ARGS
  local args=()
  if [ -n "$model_flag" ]; then
    args+=("$model_flag")
  else
    args+=("-hf")
  fi
  args+=("$model")
  args+=(--jinja)
  args+=(-c "${ctx:-65536}")
  args+=(-n "${n_pred:--1}")
  args+=(--port "8089")
  args+=(--host "0.0.0.0")
  args+=(-ngl "${ngl:-40}")
  args+=(-ot "${cpumoe:-exps=CPU}")
  args+=(-fa "${fa:-on}")
  args+=(-b "${batch:-1024}")
  args+=(-ub "${ubatch:-1024}")
  args+=(-t "${threads:-6}")
  args+=(--threads-batch "${threads_batch:-6}")
  args+=(--parallel "${parallel:-2}")
  args+=(--poll "${poll:-50}")
  args+=(--mlock)
  args+=(--fit off)
  args+=(-ctk "${ctk:-q4_0}")
  args+=(-ctv "${ctv:-q4_0}")
  args+=(--no-mmap)
  args+=(--ctx-checkpoints "${ckpt:-4}")
  args+=(--no-mmproj)

  if [ -n "$spec_type" ]; then
    args+=(--spec-type "$spec_type")
    args+=(--spec-draft-n-max "${spec_n:-3}")

    # Draft model (same as usual, no separate draft for Qwen)
    args+=(--hf-repo-draft "")
    args+=(--gpu-layers-draft 0)
    args+=(--spec-draft-n-min 0)
    args+=(--spec-draft-p-min 0.0)
  fi

  # Mount HF cache volume
  local docker_args=(
    -d --name "$ctn_name"
    --gpus all
    --restart no
    -p 8089:8089
    -v llama_hf-cache:/root/.cache/huggingface
  )

  echo "  Starting container $ctn_name ..."
  $SSH "docker run ${docker_args[*]} $IMAGE ${args[*]}" > /dev/null

  # Wait for health
  echo "  Waiting for health endpoint..."
  local max_attempts=60
  local attempt=0
  local ready=0
  while [ $attempt -lt $max_attempts ]; do
    if $SSH "curl -sf http://localhost:8089/health > /dev/null 2>&1"; then
      ready=1
      break
    fi
    sleep 2
    attempt=$((attempt + 1))
    if [ $((attempt % 10)) -eq 0 ]; then
      echo "    ... still waiting (${attempt}s)"
    fi
  done

  if [ "$ready" -ne 1 ]; then
    echo "  ERROR: Container not ready after ${max_attempts}s"
    $SSH "docker logs $ctn_name 2>/dev/null | tail -20"
    echo "FAILED: $name" >> "$RESULTS_FILE"
    $SSH "docker stop $ctn_name 2>/dev/null; docker rm $ctn_name 2>/dev/null" || true
    return
  fi

  echo "  Container ready! Running probe..."

  # Send probe: 500 tokens generation
  local result
  result=$($SSH "curl -sf http://localhost:8089/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Write a detailed analysis of why distributed consensus algorithms like Raft and Paxos are important for modern database systems. Include specific examples and technical details. Response should be thorough and well-structured.\"}],\"model\":\"qwen3.6\",\"max_tokens\":500}'" 2>&1) || {
    echo "  ERROR: curl failed"
    echo "FAILED: $name" >> "$RESULTS_FILE"
    $SSH "docker stop $ctn_name 2>/dev/null; docker rm $ctn_name 2>/dev/null" || true
    return
  }

  # Parse timing
  local prompt_tok_s=$(echo "$result" | jq -r '.timings.prompt_per_second // "N/A"')
  local gen_tok_s=$(echo "$result" | jq -r '.timings.predicted_per_second // "N/A"')
  local draft_accept=$(echo "$result" | jq -r '.timings.draft_acceptance_rate // "N/A"')
  local prompt_tok=$(echo "$result" | jq -r '.usage.prompt_tokens // "N/A"')
  local comp_tok=$(echo "$result" | jq -r '.usage.completion_tokens // "N/A"')
  local total_ms=$(echo "$result" | jq -r '.timings.predicted_ms // 0')
  local vram_mib=$(echo "$result" | jq -r '.timings.vram_mib // "N/A"')

  # Also get VRAM from nvidia-smi inside container
  local vram_smi=$($SSH "docker exec $ctn_name nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo 'N/A'")

  echo "  Results: prompt=$prompt_tok_s t/s, gen=$gen_tok_s t/s, accept=$draft_accept, VRAM=$vram_smi MiB"

  # Save results
  {
    echo "Test: $name"
    echo "  Spec type: ${spec_type:-none}"
    echo "  Spec draft n max: ${spec_n:-N/A}"
    echo "  Prompt speed: ${prompt_tok_s} t/s"
    echo "  Gen speed: ${gen_tok_s} t/s"
    echo "  Draft accept: ${draft_accept}"
    echo "  VRAM: ${vram_smi} MiB"
    echo "  Tokens: ${prompt_tok} prompt + ${comp_tok} generated"
    echo "  Gen time: ${total_ms} ms"
    echo ""
  } >> "$RESULTS_FILE"

  # Stop and remove
  echo "  Cleaning up..."
  $SSH "docker stop $ctn_name 2>/dev/null; docker rm $ctn_name 2>/dev/null" || true

  echo "  DONE: $name"
}

# ====================================================================
# MAIN
# ====================================================================

# Create backup of existing .env first
$SSH "cp /opt/llama/.env /opt/llama/.env.backup 2>/dev/null; echo 'Backup created'"

# ---- TEST 0: Baseline (SPEC_DRAFT_N_MAX=2) ----
run_test "baseline-n2" ""

# ---- TEST A: SPEC_DRAFT_N_MAX=1 ----
run_test "draft-n1" "SPEC_DRAFT_N_MAX=1"

# ---- TEST B: SPEC_DRAFT_N_MAX=3 ----
run_test "draft-n3" "SPEC_DRAFT_N_MAX=3"

# ---- TEST C: SPEC_DRAFT_N_MAX=4 ----
run_test "draft-n4" "SPEC_DRAFT_N_MAX=4"

# ---- TEST D: MTP OFF ----
run_test "mtp-off" "SPEC_TYPE="

# Restore backup
$SSH "mv /opt/llama/.env.backup /opt/llama/.env 2>/dev/null; echo 'Restored .env'"

echo ""
echo "=============================================="
echo "  ALL TESTS COMPLETE"
echo "=============================================="
cat "$RESULTS_FILE"
