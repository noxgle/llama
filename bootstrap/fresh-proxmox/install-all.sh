#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# install-all.sh — Fresh Proxmox → llama.cpp MTP Server
# ══════════════════════════════════════════════════════════════════════
#
# Usage:
#   1. cp config.env.example config.env
#   2. Edit config.env to match your environment
#   3. bash install-all.sh
#
# What it does:
#   00 — Prerequisite checks (host)
#   10 — NVIDIA host setup (modules + systemd service)
#   20 — Create and configure LXC container with GPU passthrough
#   30 — Install Docker and base tools inside LXC
#   40 — Clone repo, build Docker image, start services
#   50 — Deploy post-boot resilience services (systemd + watchdog)
#   60 — Verify health, chat completion, throughput, VRAM
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

# ──────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEPS_DIR="${SCRIPT_DIR}/steps"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
INSTALL_LOG="${INSTALL_LOG:-${SCRIPT_DIR}/install.log}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
log()  { echo -e "$(date '+%H:%M:%S') $*" | tee -a "$INSTALL_LOG"; }
ok()   { log "${GREEN}[ OK ]${NC} $*"; }
info() { log "${YELLOW}[INFO]${NC} $*"; }
fail() { log "${RED}[FAIL]${NC} $*"; }
die()  { fail "$*"; exit 1; }

# ──────────────────────────────────────────────
# Step runner
# ──────────────────────────────────────────────
run_step() {
  local script="$1"
  local name="$2"
  local where="$3"  # "host" or "lxc"

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  >>> Running step ${name} (${where}) ..."
  echo "═══════════════════════════════════════════════════════════════"

  if [[ ! -f "$script" ]]; then
    die "Script not found: $script"
  fi

  case "$where" in
    host)
      # Run directly on Proxmox host
      if bash "$script" 2>&1 | tee -a "$INSTALL_LOG"; then
        ok "Step ${name} completed successfully"
      else
        die "Step ${name} failed — check ${INSTALL_LOG} for details"
      fi
      ;;
    lxc)
      # Run inside LXC via pct exec with config vars prepended
      if cat <(for var in "${!LXC_ENV_VARS[@]}"; do echo "export ${var}='${LXC_ENV_VARS[$var]}'"; done) "$script" \
         | pct exec "$VMID" -- bash 2>&1 | tee -a "$INSTALL_LOG"; then
        ok "Step ${name} completed inside LXC"
      else
        die "Step ${name} failed inside LXC — check ${INSTALL_LOG} for details"
      fi
      ;;
    *)
      die "Unknown target: $where"
      ;;
  esac
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║     Fresh Proxmox → llama.cpp MTP Server Installer          ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Log file: $INSTALL_LOG"
  echo ""

  # ── 0. Validate environment ──
  if [[ $EUID -ne 0 ]]; then
    die "Must run as root (this script modifies system configuration)"
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: ${CONFIG_FILE}
  Copy config.env.example to config.env and edit it first:
    cp config.env.example config.env
    nano config.env"
  fi

  # ── Load config ──
  source "$CONFIG_FILE"

  # Validate critical vars
  : "${VMID:?}${LXC_IP:?}${GATEWAY:?}${BRIDGE:?}${STORAGE:?}"
  : "${PROJECT_DIR:=/opt/llama}"

  info "Configuration loaded:"
  info "  VMID=$VMID, LXC_IP=$LXC_IP, BRIDGE=$BRIDGE"
  info "  PROJECT_DIR=$PROJECT_DIR, ACTIVE_CONFIG=$ACTIVE_CONFIG"
  info "  ENABLE_WATCHDOG=${ENABLE_WATCHDOG:-true}"
  echo ""

  # ── Build LXC env vars map ──
  declare -A LXC_ENV_VARS
  LXC_ENV_VARS["PROJECT_DIR"]="$PROJECT_DIR"
  LXC_ENV_VARS["APP_PORT"]="${APP_PORT:-8089}"
  LXC_ENV_VARS["REPO_URL"]="${REPO_URL:-https://github.com/noxgle/llama.git}"
  LXC_ENV_VARS["REPO_BRANCH"]="${REPO_BRANCH:-master}"
  LXC_ENV_VARS["ACTIVE_CONFIG"]="${ACTIVE_CONFIG:-configs/qwen3.6-35ba3b-mtp-unsloth.env}"
  LXC_ENV_VARS["LLAMA_REPO"]="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"
  LXC_ENV_VARS["LLAMA_REF"]="${LLAMA_REF:-master}"
  LXC_ENV_VARS["SKIP_BUILD"]="${SKIP_BUILD:-false}"
  LXC_ENV_VARS["ENABLE_WATCHDOG"]="${ENABLE_WATCHDOG:-true}"
  LXC_ENV_VARS["ENABLE_POSTBOOT_RESTART"]="${ENABLE_POSTBOOT_RESTART:-true}"

  # ── Phase 1: Host preparation ──
  info "Starting Phase 1: Host preparation"
  run_step "${STEPS_DIR}/00-prereq-check.sh" "00-prereq-check" "host"
  run_step "${STEPS_DIR}/10-host-nvidia-setup.sh" "10-host-nvidia-setup" "host"

  # ── Phase 2: LXC creation ──
  info "Starting Phase 2: LXC creation"
  # Pass host-specific vars to step 20 as env
  export VMID LXC_HOSTNAME LXC_IP CIDR GATEWAY BRIDGE STORAGE TEMPLATE CORES MEMORY_MB DISK_GB
  run_step "${STEPS_DIR}/20-create-lxc.sh" "20-create-lxc" "host"

  # ── Phase 3: LXC base setup ──
  info "Starting Phase 3: LXC base setup (Docker + tools)"
  run_step "${STEPS_DIR}/30-lxc-base-setup.sh" "30-lxc-base-setup" "lxc"

  # ── Phase 4: Deploy llama.cpp ──
  info "Starting Phase 4: Deploy llama.cpp"
  run_step "${STEPS_DIR}/40-deploy-llama.sh" "40-deploy-llama" "lxc"

  # ── Phase 5: Resilience services ──
  info "Starting Phase 5: Post-boot services"
  run_step "${STEPS_DIR}/50-postboot-services.sh" "50-postboot-services" "lxc"

  # ── Phase 6: Verification ──
  info "Starting Phase 6: Verification"
  run_step "${STEPS_DIR}/60-verify.sh" "60-verify" "lxc"

  # ── Done ──
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ✅ INSTALLATION COMPLETE                                   ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Server:  http://${LXC_IP}:${APP_PORT}/v1/chat/completions"
  echo "  Health:  http://${LXC_IP}:${APP_PORT}/health"
  echo "  Model:   qwen3.6 (or check logs for exact model name)"
  echo ""
  echo "  Quick test:"
  echo "    curl http://${LXC_IP}:${APP_PORT}/v1/chat/completions \\"
  echo "      -H \"Content-Type: application/json\" \\"
  echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}],\"model\":\"qwen3.6\",\"max_tokens\":200}'"
  echo ""
  echo "  Log file: ${INSTALL_LOG}"
  echo ""
}

main "$@"
