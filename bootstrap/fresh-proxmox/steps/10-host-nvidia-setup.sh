#!/bin/bash
# ═══════════════════════════════════════════════
# 10-host-nvidia-setup.sh — NVIDIA readiness on Proxmox host
# ═══════════════════════════════════════════════
# Runs on: Proxmox host
# Creates:
#   - /etc/modules-load.d/nvidia.conf (auto-load modules)
#   - /etc/systemd/system/nvidia-modprobe-ensure.service
# ═══════════════════════════════════════════════

set -euo pipefail

STEP_NAME="10-host-nvidia-setup"
echo "=== [STEP $STEP_NAME] NVIDIA host setup ==="

# ── 1. Kernel module auto-load ──
MODULES_CONF="/etc/modules-load.d/nvidia.conf"
if [[ -f "$MODULES_CONF" ]]; then
  echo "  [SKIP] $MODULES_CONF already exists"
else
  echo "  [INFO] Creating $MODULES_CONF ..."
  cat > "$MODULES_CONF" << 'EOF'
# Load NVIDIA kernel modules at boot — required for LXC GPU passthrough
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
EOF
  echo "  [DONE] Created $MODULES_CONF"
fi

# ── 2. Ensure modules are loaded now ──
for mod in nvidia nvidia_uvm nvidia_modeset nvidia_drm; do
  if lsmod | grep -q "^${mod} "; then
    echo "  [OK] Module $mod already loaded"
  else
    echo "  [INFO] Loading module $mod ..."
    modprobe "$mod" || echo "  [WARN] Could not load $mod (may need reboot)"
  fi
done

# ── 3. nvidia-modprobe-ensure.service ──
SERVICE_FILE="/etc/systemd/system/nvidia-modprobe-ensure.service"
if [[ -f "$SERVICE_FILE" ]]; then
  echo "  [SKIP] $SERVICE_FILE already exists"
else
  echo "  [INFO] Creating $SERVICE_FILE ..."
  cat > "$SERVICE_FILE" << 'SERVICEEOF'
[Unit]
Description=Ensure NVIDIA modules + device nodes ready before guests
Before=pve-guests.service pve-container@*.service docker.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  modprobe nvidia && \
  modprobe nvidia_uvm && \
  modprobe nvidia_modeset && \
  modprobe nvidia_drm && \
  for d in nvidia0 nvidiactl nvidia-uvm nvidia-uvm-tools; do \
    [ -e "/dev/$d" ] && echo "OK /dev/$d" || echo "WARN /dev/$d missing"; \
  done && \
  nvidia-smi -L | head -5'
ExecStopPost=/bin/true

[Install]
WantedBy=multi-user.target
SERVICEEOF
  systemctl daemon-reload
  systemctl enable nvidia-modprobe-ensure.service
  echo "  [DONE] Created and enabled $SERVICE_FILE"
fi

# ── 4. Quick validation ──
echo ""
echo "  [INFO] Verifying NVIDIA device nodes:"
ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm 2>&1 | sed 's/^/         /'

echo ""
echo "  [INFO] nvidia-smi check:"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>&1 | sed 's/^/         /' || echo "         (nvidia-smi not available yet)"

echo ""
echo "=== [STEP $STEP_NAME] Complete ==="
