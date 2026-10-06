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
# Image source: ghcr.io/noxgle/llama-server:stable-b11096-v1 (current stable).
# Override per invocation: LLAMA_IMAGE=<tag> ./llama.sh start <model>.
# NOTE: :latest tracks untested upstream master — never deploy it (see AGENTS.md).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${LLAMA_IMAGE:-ghcr.io/noxgle/llama-server:stable-b11096-v1}"
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
# Stop and remove all known containers (used ONLY by cmd_stop —
# never on the start path, so a healthy container is not destroyed
# by systemd boot / restart / start).
# ------------------------------------------------------------------
stop_all() {
  # Consistent filter "llama-" (covers llama-qwen, llama-gemma4,
  # llama-qwen-q5, llama-router and old compose llama-llama-server-1).
  for cid in $(docker ps -q --filter name=llama- 2>/dev/null); do
    docker stop "$cid" 2>/dev/null || true
    docker rm "$cid" 2>/dev/null || true
  done
  # Also catch stopped containers
  for cid in $(docker ps -aq --filter name=llama- 2>/dev/null); do
    docker rm "$cid" 2>/dev/null || true
  done
}

stop_model() {
  local name="$1"
  docker stop "$name" 2>/dev/null || true
  docker rm "$name" 2>/dev/null || true
}

# Start-path cleanup: free the port by STOPPING other llama containers
# (no rm — their restart policy / metadata stays intact), and remove
# ONLY the container we are about to recreate (docker --name conflict).
stop_for_start() {
  local container="$1"
  for cid in $(docker ps -q --filter name=llama- 2>/dev/null); do
    local cname
    cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    if [ "$cname" != "$container" ]; then
      docker stop "$cid" 2>/dev/null || true
    fi
  done
  docker rm "$container" 2>/dev/null || true
}

# ------------------------------------------------------------------
# C5 helper: version-appropriate memory-lock flags.
# --load-mode replaced --mlock/--no-mmap (deprecated in b10665, REMOVED
# in b11096). Old style is known-good on b10068–b10665; new style is
# REQUIRED for b11096+. b10213/b10428 take the old path (unverified but
# safe: old flags were only removed in b11096).
# ------------------------------------------------------------------
append_mem_flags() {
  case "${IMAGE:-}" in
    *b10068*|*b9770*|*8c146a8*|*b10213*|*b10428*)
      LLAMA_ARGS+=(--mlock --no-mmap)
      ;;
    *)
      LLAMA_ARGS+=(--load-mode mlock)
      ;;
  esac
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
  # NOTE: use --runtime=nvidia (nvidia container toolkit) instead of --gpus all —
  # on Docker 26.1.5, --gpus all triggers CPU-serialized CUDA JIT after boot
  # (~1.5 tok/s vs 32 tok/s). See AGENTS.md "Deployment gotchas".
  DOCKER_ARGS=(
    --name "$container"
    --restart unless-stopped
    --runtime=nvidia
    -p "$port:${PORT:-8089}"
    -v llama_hf-cache:/root/.cache/huggingface
    -v "$ROOT/models:/models:ro"
    -v "$ROOT/slots:/slots"
    -e NVIDIA_VISIBLE_DEVICES=all
    -e LLAMA_ARG_THINK_BUDGET="${REASONING_BUDGET:--1}"
    -e LLAMA_ARG_THINK_BUDGET_MESSAGE="${REASONING_BUDGET_MESSAGE:-}"
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
    # M6: router mode gets the same runtime/memory flags as single-model
    # mode (--no-mmproj avoids loading a projector for text presets).
    append_mem_flags
    LLAMA_ARGS+=(--fit off)
    LLAMA_ARGS+=(--no-mmproj)
    LLAMA_ARGS+=(--cache-ram "${CACHE_RAM:-4096}")
    LLAMA_ARGS+=(--cache-reuse "${CACHE_REUSE:-256}")
    LLAMA_ARGS+=(--chat-template-kwargs '{"preserve_thinking": false}')
    LLAMA_ARGS+=(--threads-http "${THREADS_HTTP:-2}")

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
  append_mem_flags
  LLAMA_ARGS+=(--fit off)
  LLAMA_ARGS+=(-ctk "${CACHE_TYPE_K:-q4_0}")
  LLAMA_ARGS+=(-ctv "${CACHE_TYPE_V:-q4_0}")
  LLAMA_ARGS+=(--ctx-checkpoints "${CTX_CHECKPOINTS:-4}")
  LLAMA_ARGS+=(--no-mmproj)
  LLAMA_ARGS+=(--cache-ram "${CACHE_RAM:-4096}")
  LLAMA_ARGS+=(--cache-reuse "${CACHE_REUSE:-256}")
  LLAMA_ARGS+=(--chat-template-kwargs '{"preserve_thinking": false}')
  LLAMA_ARGS+=(--threads-http "${THREADS_HTTP:-2}")

  # Slot save/restore (KV cache persistence via /slots/{id}/save|restore)
  if [ -n "${SLOT_SAVE_PATH:-}" ]; then
    LLAMA_ARGS+=(--slot-save-path "$SLOT_SAVE_PATH")
  fi

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
# Wait for llama-server /health to return 200 (model load takes
# ~60-90 s for 35B models). Returns 0 on ready, 1 on timeout.
# ------------------------------------------------------------------
wait_for_health() {
  local port="$1"
  local timeout_s="${2:-240}"
  for ((i = 0; i < timeout_s; i += 5)); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/health" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      echo ">>> Healthy after ~${i}s: http://localhost:${port}/health"
      return 0
    fi
    if [ $((i % 30)) -eq 0 ] && [ "$i" -gt 0 ]; then
      echo "    ... still loading (${i}s, health=${code:-unreachable})"
    fi
    sleep 5
  done
  echo "ERROR: server did not become healthy within ${timeout_s}s (last health=${code:-unreachable})" >&2
  return 1
}

# ------------------------------------------------------------------
# start — stop existing, pull, run (then wait for /health)
# ------------------------------------------------------------------
cmd_start() {
  local model="${1:-}"
  if [ -z "$model" ] || [ -z "${MODEL_CONTAINER[$model]:-}" ]; then
    echo "Valid models: ${ALL_MODELS[*]}"
    exit 1
  fi

  # C4: :latest tracks untested upstream master — loud warning.
  case "$IMAGE" in
    *":latest")
      echo "WARNING: image ':latest' tracks untested upstream master — use a stable tag (e.g. :stable-b11096-v1) for production." >&2
      ;;
  esac

  local config_file="$CONFIG_DIR/${MODEL_CONFIG[$model]}"
  local container="${MODEL_CONTAINER[$model]}"
  local port="${MODEL_PORT[$model]}"

  if [ ! -f "$config_file" ]; then
    echo "Config not found: $config_file"
    exit 1
  fi

  # M1: fail fast if the port is already taken (all models default to 8089).
  if (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    echo "ERROR: port ${port} is already in use — stop the other model first (or check for a stray process)." >&2
    exit 1
  fi

  echo ">>> Freeing port ${port} (stopping other containers, removing only ${container})..."
  stop_for_start "$container"

  echo ">>> Ensuring HF cache volume..."
  ensure_volume

  # Pull only if image not cached locally (supports local dev images too).
  # M4: fail loudly if the pull fails (e.g. unknown tag → 404) instead of
  # running docker run against a missing image.
  if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo ">>> Pulling $IMAGE ..."
    local pull_out
    if ! pull_out=$(docker pull "$IMAGE" 2>&1); then
      echo "$pull_out" | tail -5 >&2
      echo "ERROR: failed to pull $IMAGE — check the tag exists and the registry is reachable." >&2
      exit 1
    fi
    echo "$pull_out" | tail -2
    docker image inspect "$IMAGE" &>/dev/null || {
      echo "ERROR: image $IMAGE still missing after pull." >&2
      exit 1
    }
  else
    echo ">>> Using cached image $IMAGE"
  fi

  echo ">>> Starting $model ($container) on port $port ..."
  build_run_args "$config_file" "$container" "$port"

  docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${LLAMA_ARGS[@]}"

  echo ">>> Container $container created."
  echo "    Health: http://localhost:$port/health"
  echo "    Logs:   $(basename "$0") logs $model"

  # C3: do not declare success until the server actually serves.
  wait_for_health "$port" 240
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
# restart — stop ONLY this model, then start (unlike the old behavior
# which wiped every llama container via stop_all).
# Stopping first also frees the port for cmd_start's M1 port check.
# ------------------------------------------------------------------
cmd_restart() {
  local model="${1:-}"
  if [ -z "$model" ] || [ -z "${MODEL_CONTAINER[$model]:-}" ]; then
    echo "Valid models: ${ALL_MODELS[*]}"
    exit 1
  fi
  echo ">>> Restarting $model (stopping only ${MODEL_CONTAINER[$model]})..."
  stop_model "${MODEL_CONTAINER[$model]}"
  sleep 2
  cmd_start "$@"
}

# ------------------------------------------------------------------
# status
# ------------------------------------------------------------------
cmd_status() {
  docker ps --filter name=llama- --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
  echo ""
  echo "Containers (including stopped):"
  docker ps -a --filter name=llama- --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null
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
