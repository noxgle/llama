#!/bin/bash
# ══════════════════════════════════════════════
# 00-prereq-check.sh — Validate Proxmox host
# ══════════════════════════════════════════════
# Runs on: Proxmox host
# Checks: root, pveversion, GPU, bridge, storage, LXC template, IOMMU
# ══════════════════════════════════════════════

set -euo pipefail

PASS() { echo "  [PASS] $*"; }
FAIL() { echo "  [FAIL] $*"; }
SKIP() { echo "  [SKIP] $*"; }
INFO() { echo "  [INFO] $*"; }

errors=0

# ── Root ──
if [[ $EUID -eq 0 ]]; then
  PASS "Running as root"
else
  FAIL "Must run as root (try: sudo bash install-all.sh)"
  errors=$((errors + 1))
fi

# ── pveversion / Proxmox ──
if command -v pveversion &>/dev/null; then
  PASS "Proxmox detected: $(pveversion 2>/dev/null || echo 'unknown')"
else
  FAIL "pveversion not found — is this a Proxmox host?"
  errors=$((errors + 1))
fi

# ── NVIDIA GPU ──
if command -v nvidia-smi &>/dev/null; then
  GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true)
  if [[ -n "$GPU_INFO" ]]; then
    PASS "NVIDIA GPU detected: $GPU_INFO"
  else
    FAIL "nvidia-smi found but no GPU data — driver issue?"
    errors=$((errors + 1))
  fi
else
  FAIL "nvidia-smi not found — install NVIDIA drivers first"
  errors=$((errors + 1))
fi

# ── NVIDIA UVM device nodes ──
if [[ -e /dev/nvidia0 && -e /dev/nvidiactl && -e /dev/nvidia-uvm ]]; then
  PASS "NVIDIA device nodes present"
else
  FAIL "Missing NVIDIA device nodes (/dev/nvidia0, /dev/nvidiactl, /dev/nvidia-uvm)"
  FAIL "Run step 10 first or manually: modprobe nvidia_uvm; modprobe nvidia_drm"
  errors=$((errors + 1))
fi

# ── IOMMU ──
if dmesg 2>/dev/null | grep -qi "DMAR\|IOMMU\|Intel(R) VT-d\|AMD-Vi" || [[ -d /sys/kernel/iommu_groups ]]; then
  PASS "IOMMU/VT-d detected"
else
  SKIP "IOMMU not detected — GPU passthrough to VMs may not work, but LXC passthrough is OK"
fi

# ── Bridge ──
BRIDGE="${BRIDGE:-vmbr0}"
if ip link show "$BRIDGE" &>/dev/null; then
  PASS "Bridge $BRIDGE exists: $(ip -4 addr show "$BRIDGE" | grep -oP 'inet \K[\d.]+' || echo 'no IP')"
else
  FAIL "Bridge $BRIDGE not found — check BRIDGE in config.env"
  errors=$((errors + 1))
fi

# ── Storage ──
STORAGE="${STORAGE:-local-zfs}"
if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF "$STORAGE"; then
  PASS "Storage $STORAGE available"
else
  FAIL "Storage $STORAGE not found — available: $(pvesm status 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')"
  errors=$((errors + 1))
fi

# ── LXC template ──
TEMPLATE="${TEMPLATE:-}"
if [[ -z "$TEMPLATE" ]]; then
  AVAIL=$(pveam available --section system 2>/dev/null | grep -i 'debian-13' | head -3 | awk '{print $2}' | tr '\n' ' ')
  INSTALLED=$(pveam list local 2>/dev/null | grep -i 'debian-13' | awk '{print $1}' | tr '\n' ' ')
  if [[ -n "$INSTALLED" ]]; then
    PASS "Debian 13 template(s) already downloaded: $INSTALLED"
  elif [[ -n "$AVAIL" ]]; then
    SKIP "No Debian 13 template installed yet — found available: $AVAIL"
    SKIP "Step 20 will download one automatically"
  else
    FAIL "No Debian 13 template available or installed"
    FAIL "Run: pveam update && pveam available --section system | grep debian"
    errors=$((errors + 1))
  fi
else
  if pveam list local 2>/dev/null | awk '{print $1}' | grep -qxF "$TEMPLATE"; then
    PASS "Template $TEMPLATE already downloaded"
  else
    SKIP "Template $TEMPLATE not downloaded yet — step 20 will fetch it"
  fi
fi

# ── Summary ──
echo ""
if [[ $errors -eq 0 ]]; then
  echo "  ✅ All prerequisites met."
else
  echo "  ❌ $errors prerequisite error(s) found. Fix them before proceeding."
  exit 1
fi
