#!/bin/bash
# ═══════════════════════════════════════════════
# 30-lxc-base-setup.sh — Base dependencies inside LXC
# ═══════════════════════════════════════════════
# Runs inside: LXC container (via pct exec | bash)
# Installs: Docker, docker-compose-plugin, curl, jq, git, python3
# ═══════════════════════════════════════════════

set -euo pipefail

STEP_NAME="30-lxc-base-setup"
echo "=== [STEP $STEP_NAME] LXC base setup ==="

# ── 1. Update package index ──
echo "  [INFO] Updating package index (apt update) ..."
apt-get update -qq 2>&1 | tail -2 | sed 's/^/         /'

# ── 2. Install essential tools ──
PACKAGES=(curl jq git python3 python3-venv ca-certificates gnupg lsb-release)
echo "  [INFO] Installing: ${PACKAGES[*]} ..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PACKAGES[@]}" 2>&1 | tail -3 | sed 's/^/         /'

# ── 3. Install Docker using official repository ──
if command -v docker &>/dev/null; then
  echo "  [SKIP] Docker already installed: $(docker --version 2>/dev/null || true)"
else
  echo "  [INFO] Installing Docker ..."

  # Add Docker's official GPG key
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq 2>&1 | tail -1 | sed 's/^/         /'
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tail -3 | sed 's/^/         /'

  systemctl enable docker
  systemctl start docker

  echo "  [DONE] Docker installed: $(docker --version)"
fi

# ── 4. Verify Docker works ──
echo "  [INFO] Verifying Docker ..."
docker info --format '{{.ServerVersion}}' 2>&1 | sed 's/^/         Docker engine: /' || {
  echo "  [FAIL] Docker engine not responding. Check: systemctl status docker"
  exit 1
}

# ── 5. Verify NVIDIA container toolkit ──
NVIDIA_TOOLKIT=$(docker info 2>/dev/null | grep -i 'nvidia' || true)
if [[ -n "$NVIDIA_TOOLKIT" ]]; then
  echo "  [OK] NVIDIA container toolkit detected: $NVIDIA_TOOLKIT"
else
  echo "  [WARN] NVIDIA container runtime not detected in Docker info"
  echo "  [WARN] GPU passthrough may not work. Install nvidia-container-toolkit:"
  echo "         apt-get install -y nvidia-container-toolkit"
  echo "  [INFO] Continuing anyway — compose will test GPU at runtime"
fi

echo ""
echo "=== [STEP $STEP_NAME] Complete ==="
