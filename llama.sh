#!/usr/bin/env bash
# llama.sh — llama.cpp server control script (docker run, no compose)
#
# Usage:
#   ./llama.sh start qwen       Start Qwen3.6 (port 8089, default)
#   ./llama.sh start gemma4     Start Gemma4 26B (port 8089)
#   ./llama.sh stop             Stop and remove both containers
#   ./llama.sh restart qwen     Stop + start Qwen
#   ./llama.sh status           List running llama containers
#   ./llama.sh logs qwen        Tail logs
#   ./llama.sh pull             Pull latest image from GHCR
#
# Configs are read from configs/<model>.env — same files used by
# docker-compose.  The script translates the env vars into the
# equivalent docker run / llama-server flags.
#
# Image source: ghcr.io/noxgle/llama-server:latest

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${LLAMA_IMAGE:-ghcr.io/noxgle/llama-server:latest}"
CONFIG_DIR="$ROOT/configs"

# ------------------------------------------------------------------
# Model definitions
# ------------------------------------------------------------------
declare -A MODEL_CONTAINER MODEL_PORT MODEL_CONFIG
MODEL_CONTAINER[qwen]="llama-qwen"
MODEL_CONTAINER[gemma4]="llama-gemma4"
MODEL_CONTAINER[qwen-q5]="llama-qwen-q5"
MODEL_CONTAINER[router]="llama-router"

MODEL_PORT[qwen]="8089"
MODEL_PORT[gemma4]="8089"
MODEL_PORT[qwen-q5]="8089"
MODEL_PORT[router]="8089"

MODEL_CONFIG[qwen]="qwen3.6-35ba3b-mtp-unsloth.env"
MODEL_CONFIG[gemma4]="gemma4-26b-q4-k-m-mtp.env"
MODEL_CONFIG[qwen-q5]="qwen3.6-35ba3b-mtp-unsloth-q5.env"
MODEL_CONFIG[router]="router.env"

ALL_MODELS=("${!MODEL_CONTAINER[@]}")

# ------------------------------------------------------------------
# Help
# ------------------------------------------------------------------
usage() {
  echo "Usage: $(basename "$0") {start|stop|restart|status|logs|pull} [model]"
  echo ""
  echo "Commands:"
  echo "  start    <model>   Start container for model (qwen|gemma4|qwen-q5|router)"
  echo "                     router = dynamic model switching (see configs/router-preset.ini)"
  echo "  stop                Stop and remove all llama containers"
  echo "  restart  <model>   Stop + start model"
  echo "  status             Show running llama containers"
  echo "  logs     <model>   Tail container logs"
  echo "  pull               Pull $IMAGE"
  echo ""
  echo "Environment:"
  echo "  LLAMA_IMAGE   Override container image"
  exit 1
}

# ------------------------------------------------------------------
# Ensure HF cache volume exists
# ------------------------------------------------------------------
ensure_volume() {
  if ! docker volume inspect llama_hf-cache &>/dev/null; then
    docker volume create llama_hf-cache
  fi
}

# ------------------------------------------------------------------
# Stop and remove all known containers
# ------------------------------------------------------------------
stop_all() {
  # Stop all containers whose name contains "llama" (covers both old
  # compose naming llama-llama-server-1 and new llama-qwen/gemma4)
  for cid in $(docker ps -q --filter name=llama 2>/dev/null); do
    docker stop "$cid" 2>/dev/null || true
    docker rm "$cid" 2>/dev/null || true
  done
  # Also catch stopped containers
  for cid in $(docker ps -aq --filter name=llama 2>/dev/null); do
    docker rm "$cid" 2>/dev/null || true
  done
}

stop_model() {
  local name="$1"
  docker stop "$name" 2>/dev/null || true
  docker rm "$name" 2>/dev/null || true
}

# ------------------------------------------------------------------
# Construct docker run args from a config env file
# ------------------------------------------------------------------
build_run_args() {
  local config_file="$1"
  local container="$2"
  local port="$3"

  # Source the config file (contains shell-compatible KEY=VALUE lines)
  set -a
  source "$config_file"
  set +a

  # Base docker arguments (image is passed separately — must be last)
  DOCKER_ARGS=(
    --name "$container"
    --restart unless-stopped
    --gpus all
    -p "$port:${PORT:-8089}"
    -v llama_hf-cache:/root/.cache/huggingface
    -v "$ROOT/models:/models:ro"
    -e NVIDIA_VISIBLE_DEVICES=all
    -d
  )

  # ---- llama-server arguments (mirrors docker-compose.yml command:) ----
  LLAMA_ARGS=()

  # Router mode — no fixed model, dynamic loading via INI presets
  if [ -n "${MODELS_PRESET:-}" ]; then
    DOCKER_ARGS+=(-v "$ROOT/configs:/configs:ro")
    LLAMA_ARGS+=(--models-preset "$MODELS_PRESET")
    LLAMA_ARGS+=(--models-max "${MODELS_MAX:-4}")
    LLAMA_ARGS+=(--host "${HOST:-0.0.0.0}")
    LLAMA_ARGS+=(--port "${PORT:-8089}")
    LLAMA_ARGS+=(--threads "${THREADS:-6}")
    LLAMA_ARGS+=(--threads-batch "${THREADS_BATCH:-6}")
    LLAMA_ARGS+=(--parallel "${PARALLEL:-1}")
    LLAMA_ARGS+=(--poll "${POLL:-50}")

  # Normal (single-model) mode
  else

  # Model source: local file (-m) or HuggingFace repo (-hf)
  if [ -n "${MODEL_FLAG:-}" ]; then
    LLAMA_ARGS+=("$MODEL_FLAG")
  else
    LLAMA_ARGS+=("-hf")
  fi
  LLAMA_ARGS+=("${MODEL}")

  LLAMA_ARGS+=(--jinja)
  LLAMA_ARGS+=(-c "${CTX:-65536}")
  LLAMA_ARGS+=(-n "${N_PREDICT:--1}")
  LLAMA_ARGS+=(--port "${PORT:-8089}")
  LLAMA_ARGS+=(--host "${HOST:-0.0.0.0}")
  LLAMA_ARGS+=(-ngl "${NGLAYERS:-40}")
  LLAMA_ARGS+=(-ot "${CPUMOE:-exps=CPU}")
  LLAMA_ARGS+=(-fa "${FLASHATTN:-on}")
  LLAMA_ARGS+=(-b "${BATCH:-1024}")
  LLAMA_ARGS+=(-ub "${UBATCH:-1024}")
  LLAMA_ARGS+=(-t "${THREADS:-6}")
  LLAMA_ARGS+=(--threads-batch "${THREADS_BATCH:-6}")
  LLAMA_ARGS+=(--parallel "${PARALLEL:-2}")
  LLAMA_ARGS+=(--poll "${POLL:-50}")
  LLAMA_ARGS+=(--mlock)
  LLAMA_ARGS+=(--fit off)
  LLAMA_ARGS+=(-ctk "${CACHE_TYPE_K:-q4_0}")
  LLAMA_ARGS+=(-ctv "${CACHE_TYPE_V:-q4_0}")
  LLAMA_ARGS+=(--no-mmap)
  LLAMA_ARGS+=(--ctx-checkpoints "${CTX_CHECKPOINTS:-4}")
  LLAMA_ARGS+=(--no-mmproj)

  # Speculative decoding (MTP / draft)
  if [ -n "${SPEC_TYPE:-}" ]; then
    LLAMA_ARGS+=(--spec-type "$SPEC_TYPE")
    LLAMA_ARGS+=(--spec-draft-n-max "${SPEC_DRAFT_N_MAX:-3}")

    # Draft model flag + value — skip if DRAFT_MODEL is empty
    # (e.g. Qwen3.6 A3B MTP has the MTP head embedded in the same GGUF)
    if [ -n "${DRAFT_MODEL:-}" ]; then
      LLAMA_ARGS+=("${DRAFT_FLAG:---hf-repo-draft}")
      LLAMA_ARGS+=("$DRAFT_MODEL")
      LLAMA_ARGS+=(--gpu-layers-draft "${GPU_LAYERS_DRAFT:-0}")
      LLAMA_ARGS+=(--spec-draft-n-min "${SPEC_DRAFT_N_MIN:-0}")
      LLAMA_ARGS+=(--spec-draft-p-min "${SPEC_DRAFT_P_MIN:-0.0}")
    fi
  fi
  fi
}

# ------------------------------------------------------------------
# warmup_model — send synthetic requests to warm up CUDA compute graphs
# ------------------------------------------------------------------
warmup_model() {
  local port="$1"
  local model="$2"
  local url="http://localhost:$port"

  echo ">>> Waiting for model to load (health check)..."
  local waited=0
  while [ "$waited" -lt 120 ]; do
    if curl -sf -m 3 "$url/health" 2>/dev/null | grep -q '"status":"ok"'; then
      echo "    Model loaded after ${waited}s"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if [ "$waited" -ge 120 ]; then
    echo "    WARNING: Model did not become healthy within 120s" >&2
    return 1
  fi

  # Warmup requests — 3 iterations to fully populate CUDA JIT cache.
  # First warmup generates ~200 tokens (slow ~1.5 tok/s on cold GPU) to
  # trigger compilation of all common CUDA kernels. After JIT cache is
  # populated, subsequent warmups and real requests run at full ~32 tok/s.
  echo ">>> Warming up CUDA compute graphs (this may take ~2 min)..."
  local speeds=()
  local prompt="Write a story"
  for i in 1 2 3; do
    local result
    result=$(curl -sf --max-time 300 "$url/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$prompt $i\"}],\"max_tokens\":200}" 2>/dev/null)

    if [ -n "$result" ]; then
      local tok_s
      tok_s=$(echo "$result" | python3 -c "
import sys, json
d=json.load(sys.stdin)
t=d.get('timings',{})
tok = round(t.get('predicted_per_second',0), 1)
print(tok)
" 2>/dev/null || echo "?")
      speeds+=("$tok_s")
      echo "    Warmup $i/3: ${tok_s} tok/s"
    else
      echo "    WARNING: Warmup $i/3 failed" >&2
    fi
    prompt="$prompt."
  done

  # Print summary
  local joined
  joined=$(IFS=" → "; echo "${speeds[*]}")
  echo "    Warmup complete: ${joined} tok/s"
}

# ------------------------------------------------------------------
# start — stop existing, pull, run
# ------------------------------------------------------------------
cmd_start() {
  local model="${1:-}"
  if [ -z "$model" ] || [ -z "${MODEL_CONTAINER[$model]:-}" ]; then
    echo "Valid models: ${ALL_MODELS[*]}"
    exit 1
  fi

  local config_file="$CONFIG_DIR/${MODEL_CONFIG[$model]}"
  local container="${MODEL_CONTAINER[$model]}"
  local port="${MODEL_PORT[$model]}"

  if [ ! -f "$config_file" ]; then
    echo "Config not found: $config_file"
    exit 1
  fi

  echo ">>> Stopping any existing llama containers..."
  stop_all

  echo ">>> Ensuring HF cache volume..."
  ensure_volume

  # Pull only if image not cached locally (supports local dev images too)
  if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo ">>> Pulling $IMAGE ..."
    docker pull "$IMAGE" 2>&1 | tail -3
  else
    echo ">>> Using cached image $IMAGE"
  fi

  echo ">>> Starting $model ($container) on port $port ..."
  build_run_args "$config_file" "$container" "$port"

  docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${LLAMA_ARGS[@]}"

  echo ">>> Container $container started."

  # Warmup CUDA compute graphs — first 2-3 inference requests after model
  # load run at ~1.5 tok/s (cold CUDA graphs). By sending synthetic requests
  # here, the first real user request gets full throughput (~32 tok/s).
  warmup_model "$port" "$model"

  echo "    Health: http://localhost:$port/health"
  echo "    Logs:   $(basename "$0") logs $model"
}

# ------------------------------------------------------------------
# stop
# ------------------------------------------------------------------
cmd_stop() {
  echo ">>> Stopping and removing all llama containers..."
  stop_all
  echo ">>> Done."
}

# ------------------------------------------------------------------
# restart
# ------------------------------------------------------------------
cmd_restart() {
  cmd_start "$@"
}

# ------------------------------------------------------------------
# status
# ------------------------------------------------------------------
cmd_status() {
  docker ps --filter name=llama- --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo ""
  echo "Containers (including stopped):"
  docker ps -a --filter name=llama- --format "table {{.Names}}\t{{.Status}}" 2>/dev/null
}

# ------------------------------------------------------------------
# logs
# ------------------------------------------------------------------
cmd_logs() {
  local model="${1:-}"
  if [ -z "$model" ] || [ -z "${MODEL_CONTAINER[$model]:-}" ]; then
    echo "Valid models: ${ALL_MODELS[*]}"
    exit 1
  fi
  docker logs -f "${MODEL_CONTAINER[$model]}"
}

# ------------------------------------------------------------------
# pull
# ------------------------------------------------------------------
cmd_pull() {
  docker pull "$IMAGE"
}

# ------------------------------------------------------------------
# Main dispatch
# ------------------------------------------------------------------
CMD="${1:-help}"
ARG="${2:-}"

case "$CMD" in
  start)    cmd_start "$ARG" ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart "$ARG" ;;
  status)   cmd_status ;;
  logs)     cmd_logs "$ARG" ;;
  pull)     cmd_pull ;;
  help|--help|-h) usage ;;
  *)
    echo "Unknown command: $CMD"
    usage
    ;;
esac
