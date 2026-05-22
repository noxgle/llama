#!/bin/bash
# ═══════════════════════════════════════════════
# 20-create-lxc.sh — Create and configure LXC container
# ═══════════════════════════════════════════════
# Runs on: Proxmox host
# Uses: VMID, LXC_HOSTNAME, LXC_IP, CIDR, GATEWAY, BRIDGE, STORAGE,
#       TEMPLATE, CORES, MEMORY_MB, DISK_GB from environment
# ═══════════════════════════════════════════════

set -euo pipefail

STEP_NAME="20-create-lxc"
echo "=== [STEP $STEP_NAME] Create LXC ==="

# ── Read config from environment (exported by install-all.sh) ──
: "${VMID:?}${LXC_HOSTNAME:?}${LXC_IP:?}${GATEWAY:?}${BRIDGE:?}${STORAGE:?}"
: "${CORES:=6}${MEMORY_MB:=24576}${DISK_GB:=40}"
CIDR="${CIDR:-24}"

# ── 1. Resolve/Download LXC template ──
TEMPLATE="${TEMPLATE:-}"
if [[ -z "$TEMPLATE" ]]; then
  echo "  [INFO] No template specified; searching for Debian 13 ..."
  INSTALLED=$(pveam list local 2>/dev/null | grep -i 'debian-13' | awk '{print $1}' | head -1)
  if [[ -z "$INSTALLED" ]]; then
    echo "  [INFO] No Debian 13 template installed; checking available ..."
    pveam update 2>&1 | sed 's/^/         /'
    TEMPLATE_NAME=$(pveam available --section system 2>/dev/null | grep -i 'debian-13' | head -1 | awk '{print $2}')
    if [[ -z "$TEMPLATE_NAME" ]]; then
      echo "  [FAIL] No Debian 13 template available in any Proxmox repository"
      exit 1
    fi
    echo "  [INFO] Downloading template: $TEMPLATE_NAME (this may take a minute) ..."
    pveam download local "$TEMPLATE_NAME" 2>&1 | sed 's/^/         /'
    TEMPLATE="$TEMPLATE_NAME"
  else
    TEMPLATE="$INSTALLED"
    echo "  [OK] Using installed template: $TEMPLATE"
  fi
fi

# Get full path to template
TEMPLATE_PATH=$(pveam list local 2>/dev/null | grep "$TEMPLATE" | head -1 | awk '{print $1}')
if [[ -z "$TEMPLATE_PATH" ]]; then
  TEMPLATE_PATH=$(find /var/lib/vz/template/cache /var/tmp/pve* -name "*${TEMPLATE}*" 2>/dev/null | head -1)
fi
if [[ -z "$TEMPLATE_PATH" ]]; then
  echo "  [FAIL] Could not locate template: $TEMPLATE"
  echo "  Installed templates:"
  pveam list local 2>/dev/null | awk '{print "         " $1}'
  exit 1
fi
echo "  [OK] Template path: $TEMPLATE_PATH"

# ── 2. Check if container already exists ──
if pct status "$VMID" &>/dev/null; then
  echo "  [SKIP] Container $VMID already exists (status: $(pct status "$VMID" | awk '{print $2}'))"
  echo "  [INFO] If you want to recreate it, run: pct destroy $VMID (after backup)"
else
  echo "  [INFO] Creating container $VMID ..."

  # Build network string
  NET="${BRIDGE},ip=${LXC_IP}/${CIDR},gw=${GATEWAY}"

  pct create "$VMID" "$TEMPLATE_PATH" \
    --hostname "$LXC_HOSTNAME" \
    --rootfs "$STORAGE:${DISK_GB}" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap 2048 \
    --net0 name=eth0,bridge="$NET" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --startup "order=5,up=20" \
    --password "llama" \
    --force 1 2>&1 | sed 's/^/         /'

  echo "  [DONE] Container $VMID created"
fi

# ── 3. Configure GPU passthrough entries in container config ──
LXC_CONF="/etc/pve/lxc/${VMID}.conf"
if [[ ! -f "$LXC_CONF" ]]; then
  echo "  [FAIL] Container config not found: $LXC_CONF"
  exit 1
fi

# Function to add line if not present
add_lxc_entry() {
  local key="$1"
  local value="$2"
  if grep -qF "$key" "$LXC_CONF"; then
    echo "  [SKIP] $key already in config"
  else
    echo "$key $value" >> "$LXC_CONF"
    echo "  [ADD] $key $value"
  fi
}

echo "  [INFO] Adding GPU passthrough entries to $LXC_CONF ..."
# These may already exist from previous runs
grep -q 'lxc.cgroup2.devices.allow' "$LXC_CONF" && echo "  [INFO] cgroup2 entries already present (skipping duplicate)"

# Add entries (after the [source] marker or at end of file)
# Use sed to insert before any LXC-specific entries, or append
{
  echo ""
  echo "# NVIDIA GPU passthrough"
  echo "lxc.cgroup2.devices.allow: c 195:* rwm"
  echo "lxc.cgroup2.devices.allow: c 510:* rwm"
  echo "lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file"
  echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file"
  echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file"
  echo "lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file"
  echo "lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir"
} >> "$LXC_CONF"

echo "  [DONE] GPU passthrough entries added"

# ── 4. Start container ──
echo "  [INFO] Starting container $VMID ..."
pct start "$VMID" 2>&1 | sed 's/^/         /' || {
  echo "  [INFO] Container may already be running"
}

# ── 5. Wait for container to be ready ──
echo "  [INFO] Waiting for container to finish booting ..."
for i in $(seq 1 30); do
  if pct status "$VMID" 2>/dev/null | grep -q "running"; then
    # Check if we can exec into it
    if pct exec "$VMID" -- true 2>/dev/null; then
      echo "  [OK] Container ready after ~${i}s"
      break
    fi
  fi
  if [[ $i -eq 30 ]]; then
    echo "  [FAIL] Container did not become ready within 30s"
    echo "  Check: pct status $VMID; pct enter $VMID"
    exit 1
  fi
  sleep 1
done

# ── 6. Wait for network ──
echo "  [INFO] Waiting for network (up to 60s) ..."
for i in $(seq 1 60); do
  if pct exec "$VMID" -- ping -c1 -W1 "$GATEWAY" &>/dev/null; then
    echo "  [OK] Network reachable (gateway $GATEWAY) after ~${i}s"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "  [WARN] Network not reachable after 60s — continuing anyway"
  fi
  sleep 1
done

echo ""
echo "=== [STEP $STEP_NAME] Complete ==="
echo "  Container $VMID is running at $LXC_IP"
echo "  Root password: llama (change after first login)"
