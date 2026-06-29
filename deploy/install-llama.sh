#!/usr/bin/env bash
# install-llama.sh — Bootstrap a Debian/Ubuntu machine (LXC or bare metal)
#                   with Docker, NVIDIA GPU support, and a llama.cpp server.
#
# Usage:
#   bash deploy/install-llama.sh qwen          # from repo checkout
#   bash deploy/install-llama.sh qwen-q5       # Q5_K_M variant
#   bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) qwen
#
# Prerequisites:
#   - Debian 12+ or Ubuntu 22.04+ (fresh install recommended)
#   - Root access
#   - For Proxmox LXC: GPU passthrough must be configured on the host
#     (see the error message below for required lxc.* entries)
#
# What it does:
#   1. Installs Docker Engine (official repo)
#   2. Installs nvidia-container-toolkit for GPU access in containers
#   3. Verifies GPU is accessible inside Docker — ABORTS if not
#   4. Clones noxgle/llama repo to /opt/llama
#   5. Creates HF cache volume + models/ directory
#   6. Pulls llama-server image from GitHub Container Registry
#   7. Checks available disk space (warns if < 25 GB)
#   8. Creates .env from the chosen config
#   9. Pre-downloads model weights (best-effort, background)
#  10. Starts the server on port 8089
#
# After reboot:  model auto-starts via Docker's restart: unless-stopped
# To switch:     cp configs/<name>.env .env && docker compose up -d
#
# Environment variables:
#   LLAMA_REPO   Git repo URL (default: https://github.com/noxgle/llama.git)
#   LLAMA_DIR    Install directory (default: /opt/llama)
#   LLAMA_IMAGE  Docker image (default: ghcr.io/noxgle/llama-server:latest)

set -euo pipefail

# ==================================================================
# Configuration
# ==================================================================
MODEL="${1:-}"

# Overridable via environment
REPO_URL="${LLAMA_REPO:-https://github.com/noxgle/llama.git}"
INSTALL_DIR="${LLAMA_DIR:-/opt/llama}"
LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/noxgle/llama-server:stable-b9770-v1}"

# Model validation
case "$MODEL" in
  qwen|gemma4|qwen-q5) ;;
  *)
    cat >&2 <<EOF
Usage: $(basename "$0") {qwen|gemma4|qwen-q5}

Installs Docker, nvidia-container-toolkit, and a llama.cpp server
with the selected model, configured for autostart on port 8089.

Examples:
  bash $(basename "$0") qwen        # Qwen3.6 Q4_K_M (production, ~31 tok/s)
  bash $(basename "$0") gemma4      # Gemma4 26B (alternative, ~27 tok/s)
  bash $(basename "$0") qwen-q5     # Qwen3.6 Q5_K_M (higher quality, ~28 tok/s)
EOF
    exit 1
    ;;
esac

# ==================================================================
# Helpers
# ==================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}*${NC} $*"; }
warn()  { echo -e "  ${YELLOW}WARN${NC} $*" >&2; }
err()   { echo -e "  ${RED}ERROR${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

heading() {
  echo ""
  echo -e "${BOLD}── $* ──${NC}"
}

# ==================================================================
# Pre-flight checks
# ==================================================================
heading "Pre-flight checks"

if [ "$EUID" -ne 0 ]; then
  die "Must run as root (or via sudo)"
fi

if ! command -v apt-get &>/dev/null; then
  die "This script requires apt-get (Debian/Ubuntu)"
fi

echo ""
info "Target:  $(. /etc/os-release && echo "$ID $VERSION_CODENAME ($VERSION_ID)")"
info "Model:   $MODEL"
info "Repo:    $REPO_URL"
info "Image:   $LLAMA_IMAGE"
info "Install: $INSTALL_DIR"

# ==================================================================
# 1. Install Docker Engine
# ==================================================================
heading "Step 1/10 — Docker Engine"

if command -v docker &>/dev/null; then
  info "Docker already installed ($(docker --version 2>/dev/null || true))"
else
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git

  # Add Docker's official GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Add repository (Docker only publishes for stable Debian/Ubuntu releases)
  . /etc/os-release
  case "$ID/$VERSION_CODENAME" in
    debian/trixie|debian/forky) DOCKER_CODENAME="bookworm" ;;
    ubuntu/plucky)              DOCKER_CODENAME="noble"    ;;
    *)                          DOCKER_CODENAME="$VERSION_CODENAME" ;;
  esac
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${DOCKER_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  info "Docker $(docker --version) installed and started"
fi

# ==================================================================
# 2. Install NVIDIA Container Toolkit
# ==================================================================
heading "Step 2/10 — NVIDIA Container Toolkit"

if command -v nvidia-ctk &>/dev/null; then
  info "nvidia-container-toolkit already installed"
else
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit

  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  info "nvidia-container-toolkit installed and Docker runtime configured"
fi

# ==================================================================
# 3. Verify GPU access inside Docker (HARD FAIL if missing)
# ==================================================================
heading "Step 3/10 — GPU verification"

info "Checking NVIDIA devices..."
if [ ! -c /dev/nvidia0 ] && [ ! -c /dev/nvidiactl ]; then
  cat >&2 <<EOF

  ${RED}GPU DEVICES NOT FOUND${NC}
  No /dev/nvidia* devices detected.  This machine cannot use GPU acceleration.

  For a Proxmox LXC, add these entries to the LXC config file
  (e.g. /etc/pve/lxc/<VMID>.conf) on the PROXMOX HOST, then restart the LXC:

    lxc.cgroup2.devices.allow: c 195:* rwm
    lxc.cgroup2.devices.allow: c 510:* rwm
    lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
    lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
    lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir

  For bare metal: install NVIDIA drivers and reboot.
    See: https://developer.nvidia.com/cuda-downloads
EOF
  exit 1
fi

info "Pulling GPU verification image (nvidia/cuda:12.4.0-base-ubuntu22.04)..."
docker pull -q nvidia/cuda:12.4.0-base-ubuntu22.04 2>&1 | tail -1

info "Running nvidia-smi inside Docker..."
GPU_OUTPUT=$(docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi -L 2>&1) || true

if [ -z "$GPU_OUTPUT" ] || echo "$GPU_OUTPUT" | grep -qi "failed\|error\|could not\|not found\|NVIDIA-SMI has failed"; then
  cat >&2 <<EOF

  ${RED}GPU NOT ACCESSIBLE INSIDE DOCKER${NC}
  The nvidia-smi command failed inside a Docker container with --gpus all.

  Possible causes:
    - nvidia-container-toolkit not properly configured
    - Docker daemon needs restart after nvidia-ctk configuration
    - NVIDIA driver version mismatch between host and container

  Try:  systemctl restart docker
  Then: docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi -L

  If the issue persists, check:
    - ls -la /dev/nvidia*
    - nvidia-smi (on the host)
    - systemctl status nvidia-container-toolkit
EOF
  exit 1
fi

info "GPU detected: $GPU_OUTPUT"

# ==================================================================
# 4. Clone / pull the llama repo
# ==================================================================
heading "Step 4/10 — Clone llama repo"

if [ -d "$INSTALL_DIR/.git" ]; then
  info "Repo already cloned at $INSTALL_DIR, pulling latest..."
  git -C "$INSTALL_DIR" pull --ff-only --quiet 2>&1 | tail -1 || warn "git pull failed (continuing with existing)"
else
  info "Cloning $REPO_URL into $INSTALL_DIR ..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi

if [ ! -f "$INSTALL_DIR/llama.sh" ]; then
  die "llama.sh not found in $INSTALL_DIR — clone may have failed"
fi
chmod +x "$INSTALL_DIR/llama.sh"

# ==================================================================
# 5. Create storage (Docker volume + models dir)
# ==================================================================
heading "Step 5/10 — Storage setup"

docker volume create llama_hf-cache 2>/dev/null || true
mkdir -p "$INSTALL_DIR/models"
info "Volume llama_hf-cache ready"
info "Directory $INSTALL_DIR/models ready"

# ==================================================================
# 6. Pull llama-server image from GHCR
# ==================================================================
heading "Step 6/10 — Pull llama-server image"

info "Pulling $LLAMA_IMAGE ..."
if docker pull "$LLAMA_IMAGE" 2>&1; then
  info "Image pulled from registry"
else
  warn "Registry pull failed — trying to load locally cached image..."
  if docker images --format "{{.Repository}}:{{.Tag}}" | grep -qF "$LLAMA_IMAGE"; then
    info "Found locally cached $LLAMA_IMAGE"
  else
    cat >&2 <<EOFFALLBACK

  ${RED}CANNOT OBTAIN SERVER IMAGE${NC}
  docker pull of $LLAMA_IMAGE failed and no local image found.

  The image is public on ghcr.io — verify network connectivity and that
  the registry is reachable, then re-run this script.
EOFFALLBACK
    exit 1
  fi
fi

# ==================================================================
# 7. Disk space check
# ==================================================================
heading "Step 7/10 — Disk space check"

case "$MODEL" in
  qwen-q5) MODEL_MIN_GB=35 ;;  # Q5_K_M ~26 GB + download + buffer
  *)       MODEL_MIN_GB=25 ;;  # Q4_K_M ~22 GB, Gemma4 Q4_K_M ~16 GB
esac
AVAIL_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4+0}')
if [ "$AVAIL_GB" -lt "$MODEL_MIN_GB" ]; then
  warn "Only ${AVAIL_GB}G available on /, model needs ~${MODEL_MIN_GB}G for download + cache"
  warn "The server may fail to download model weights — consider freeing space"
  sleep 3
fi

# ==================================================================
# 8. Create .env from config
# ==================================================================
heading "Step 8/10 — docker-compose setup"

case "$MODEL" in
  qwen)    CONFIG_NAME="qwen3.6-35ba3b-mtp-unsloth.env" ;;
  gemma4)  CONFIG_NAME="gemma4-26b-q4-k-m-mtp.env" ;;
  qwen-q5) CONFIG_NAME="qwen3.6-35ba3b-mtp-unsloth-q5.env" ;;
  *)       die "Unknown model: $MODEL (bug in script)" ;;
esac
CONFIG_FILE="$INSTALL_DIR/configs/$CONFIG_NAME"

if [ ! -f "$CONFIG_FILE" ]; then
  die "Config not found: $CONFIG_FILE — expected at $CONFIG_FILE"
fi

cp "$CONFIG_FILE" "$INSTALL_DIR/.env"

# Append variables needed by docker-compose.yml that may not be in the config
grep -q "^DRAFT_MODEL=" "$INSTALL_DIR/.env" 2>/dev/null || echo "DRAFT_MODEL=" >> "$INSTALL_DIR/.env"
grep -q "^DRAFT_FLAG="  "$INSTALL_DIR/.env" 2>/dev/null || echo "DRAFT_FLAG=--hf-repo-draft" >> "$INSTALL_DIR/.env"
grep -q "^MODEL_FLAG="  "$INSTALL_DIR/.env" 2>/dev/null || echo "MODEL_FLAG=-hf" >> "$INSTALL_DIR/.env"

info ".env created from $MODEL config ($CONFIG_NAME)"

# ==================================================================
# 9. Pre-download model weights (background, best-effort)
# ==================================================================
heading "Step 9/10 — Pre-download model weights"

case "$MODEL" in
  qwen)
    info "Pre-caching Qwen3.6 MTP GGUF from HuggingFace (may take a few minutes)..."
    docker run --rm -d --name llama-predownload \
      -v llama_hf-cache:/root/.cache/huggingface \
      "$LLAMA_IMAGE" \
      -hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M \
      -c 4096 --no-mmap --no-mmproj 2>/dev/null || true
    sleep 60
    docker stop llama-predownload 2>/dev/null || true
    docker rm llama-predownload 2>/dev/null || true
    info "Pre-download initiated (continues in background if partial)"
    ;;
  gemma4)
    info "Pre-caching Gemma4 UD-Q4_K_M GGUF from HuggingFace..."
    docker run --rm -d --name llama-predownload \
      -v llama_hf-cache:/root/.cache/huggingface \
      "$LLAMA_IMAGE" \
      -hf unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M \
      -c 4096 --no-mmap --no-mmproj 2>/dev/null || true
    sleep 60
    docker stop llama-predownload 2>/dev/null || true
    docker rm llama-predownload 2>/dev/null || true

    warn "================================================================"
    warn "Gemma4 requires local GGUF symlinks in $INSTALL_DIR/models/"
    warn "After the cache download completes (check docker logs), create"
    warn "symlinks in $INSTALL_DIR/models/:"
    echo ""
    warn "  HF_CACHE=/root/.cache/huggingface/hub"
    warn "  HF_HASH=\$(ls \"\$HF_CACHE\" | grep gemma-4-26b | head -1)"
    warn '  SNAP="$HF_CACHE/$HF_HASH/snapshots/$(ls "$HF_CACHE/$HF_HASH/snapshots/" | head -1)"'
  warn '  ln -sf "$SNAP/gemma4-26b-q4-k-m.gguf" '"$INSTALL_DIR/models/"
  warn '  ln -sf "$SNAP/gemma4-26b-q8-mtp.gguf" '"$INSTALL_DIR/models/"
    warn ""
    warn "See $INSTALL_DIR/AGENTS.md for details."
    warn "================================================================"
    ;;
  qwen-q5)
    Q5_URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q5_K_M.gguf"
    Q5_PATH="$INSTALL_DIR/models/qwen-q5-k-m.gguf"
    info "Downloading Q5_K_M GGUF (26 GB) directly to $Q5_PATH ..."
    info "This will take 15-30 minutes depending on your connection."
    if curl -L -o "$Q5_PATH" "$Q5_URL" 2>&1; then
      info "Q5_K_M model downloaded successfully ($(ls -lh "$Q5_PATH" | awk '{print $5}'))"
    else
      warn "Download failed or was interrupted."
      warn "To resume later:  curl -C - -L -o $Q5_PATH $Q5_URL"
      warn ""
      warn "The server won't start until the file is present."
    fi
    ;;
esac

# ==================================================================
# 10. Start the model
# ==================================================================
heading "Step 10/10 — Starting $MODEL server"

cd "$INSTALL_DIR"
docker compose up -d 2>&1 | grep -v "WARNING\|already exists"

info "Waiting for server to become ready (model load may take 2-5 min)..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:8089/health 2>/dev/null | grep -q '"ok"'; then
    echo ""
    info "Server READY"
    break
  fi
  if [ $((i % 6)) -eq 0 ]; then
    echo "  still loading (${i}s)..."
  fi
  sleep 5
done

# ==================================================================
# Summary
# ==================================================================
heading "Installation complete"

echo ""
info "Model:     $MODEL"
info "Port:      8089"
info "Image:     $LLAMA_IMAGE"
info "Directory: $INSTALL_DIR"
echo ""
info "Manage:"
info "  docker compose down && docker compose up -d   (restart)"
info "  docker compose logs -f                        (logs)"
info "  cd $INSTALL_DIR && docker compose ...         (from install dir)"
echo ""
info "Health check:"
info "  curl http://localhost:8089/health"
echo ""
info "Quick benchmark:"
info "  curl -s http://localhost:8089/v1/chat/completions \\"
info "    -H 'Content-Type: application/json' \\"
info "    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Write 500 chars.\"}],\"max_tokens\":500}' \\"
info "    | jq '.timings.predicted_per_second'"
echo ""

# Give a final status
docker ps --filter name=llama --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
info "Reboot test:  systemctl reboot  →  model auto-starts on port 8089 (Docker restart: unless-stopped)"
