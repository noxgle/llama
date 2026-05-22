#!/bin/bash
# ═══════════════════════════════════════════════
# 50-postboot-services.sh — Systemd services for resilience
# ═══════════════════════════════════════════════
# Runs inside: LXC container (via pct exec | bash)
# Creates:
#   - llama-compose.service    (docker compose up at boot)
#   - llama-postboot-restart.service (delayed corrective restart)
#   - GPU watchdog (scripts + systemd timer)
# ═══════════════════════════════════════════════

set -euo pipefail

STEP_NAME="50-postboot-services"
echo "=== [STEP $STEP_NAME] Post-boot resilience services ==="

: "${PROJECT_DIR:=/opt/llama}"
: "${APP_PORT:=8089}"
: "${ENABLE_WATCHDOG:=true}"
: "${ENABLE_POSTBOOT_RESTART:=true}"

# ──────────────────────────────────────────────
# Helper: write systemd unit file
# ──────────────────────────────────────────────
install_unit() {
  local path="$1"
  local content="$2"
  if [[ -f "$path" ]]; then
    echo "  [SKIP] $path already exists"
  else
    echo "$content" > "$path"
    echo "  [DONE] Created $path"
  fi
}

# ──────────────────────────────────────────────
# 1. llama-compose.service
# ──────────────────────────────────────────────
COMPOSE_UNIT="/etc/systemd/system/llama-compose.service"
install_unit "$COMPOSE_UNIT" "\
[Unit]
Description=llama.cpp Docker Compose stack
After=docker.service dev-nvidia0.device network-online.target
Wants=docker.service network-online.target
BindsTo=dev-nvidia0.device
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=${PROJECT_DIR}
ExecStartPre=/bin/bash -c 'while [ ! -e /dev/nvidia-uvm ]; do sleep 1; done'
ExecStartPre=/bin/bash -c 'while ! docker info >/dev/null 2>&1; do sleep 1; done'
ExecStart=/usr/bin/docker compose down --remove-orphans && /usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"

# ──────────────────────────────────────────────
# 2. llama-postboot-restart.service (optional)
# ──────────────────────────────────────────────
if [[ "$ENABLE_POSTBOOT_RESTART" == "true" ]]; then
  RESTART_UNIT="/etc/systemd/system/llama-postboot-restart.service"
  install_unit "$RESTART_UNIT" "\
[Unit]
Description=Delayed corrective docker compose restart (workaround for startup race)
After=llama-compose.service
Requires=llama-compose.service

[Service]
Type=oneshot
User=root
WorkingDirectory=${PROJECT_DIR}
ExecStartPre=/bin/sleep 90
ExecStart=/usr/bin/docker compose down --remove-orphans && /usr/bin/docker compose up -d
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"
  systemctl enable llama-postboot-restart.service 2>&1 | sed 's/^/         /'
  echo "  [DONE] llama-postboot-restart.service enabled"
else
  echo "  [SKIP] Post-boot restart disabled (ENABLE_POSTBOOT_RESTART != true)"
fi

# ──────────────────────────────────────────────
# 3. Enable llama-compose.service
# ──────────────────────────────────────────────
systemctl enable llama-compose.service 2>&1 | sed 's/^/         /'
echo "  [DONE] llama-compose.service enabled"

# ──────────────────────────────────────────────
# 4. GPU watchdog (optional)
# ──────────────────────────────────────────────
if [[ "$ENABLE_WATCHDOG" == "true" ]]; then
  echo "  [INFO] Deploying GPU watchdog ..."

  # Ensure scripts directory exists
  mkdir -p "${PROJECT_DIR}/scripts"

  # The watchdog script and systemd units should already be in the cloned repo
  # Copy them into place if present, otherwise create them

  WATCHDOG_SCRIPT="${PROJECT_DIR}/scripts/gpu-watchdog.sh"
  if [[ -f "$WATCHDOG_SCRIPT" ]]; then
    echo "  [OK] Watchdog script found at $WATCHDOG_SCRIPT"
    chmod +x "$WATCHDOG_SCRIPT"
  else
    echo "  [WARN] Watchdog script not found in repo — GPU watchdog will not be available"
    ENABLE_WATCHDOG="false"
  fi

  if [[ "$ENABLE_WATCHDOG" != "false" ]]; then
    # Install systemd units
    WATCHDOG_SERVICE="${PROJECT_DIR}/deploy/systemd/llama-gpu-watchdog.service"
    WATCHDOG_TIMER="${PROJECT_DIR}/deploy/systemd/llama-gpu-watchdog.timer"

    if [[ -f "$WATCHDOG_SERVICE" && -f "$WATCHDOG_TIMER" ]]; then
      cp "$WATCHDOG_SERVICE" /etc/systemd/system/
      cp "$WATCHDOG_TIMER" /etc/systemd/system/
      systemctl daemon-reload
      systemctl enable --now llama-gpu-watchdog.timer 2>&1 | sed 's/^/         /'
      echo "  [DONE] GPU watchdog timer enabled"
    else
      echo "  [WARN] Watchdog systemd units not found in repo"
    fi
  fi
else
  echo "  [SKIP] GPU watchdog disabled (ENABLE_WATCHDOG != true)"
fi

# ──────────────────────────────────────────────
# 5. Reload systemd ──
# ──────────────────────────────────────────────
systemctl daemon-reload

echo ""
echo "=== [STEP $STEP_NAME] Complete ==="
echo "  Active services:"
systemctl is-enabled llama-compose.service 2>&1 | sed 's/^/         llama-compose: /' || true
if [[ "$ENABLE_POSTBOOT_RESTART" == "true" ]]; then
  systemctl is-enabled llama-postboot-restart.service 2>&1 | sed 's/^/         llama-postboot-restart: /' || true
fi
if [[ "$ENABLE_WATCHDOG" == "true" ]]; then
  systemctl is-enabled llama-gpu-watchdog.timer 2>&1 | sed 's/^/         llama-gpu-watchdog: /' || true
fi
