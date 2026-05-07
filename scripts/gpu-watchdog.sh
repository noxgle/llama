#!/bin/bash
# GPU Watchdog for llama.cpp server
# Detects CPU fallback and auto-restarts service to recover GPU usage
# Runs under systemd timer (every 2 minutes)

set -euo pipefail

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
CONTAINER="llama-llama-server-1"
LOG_FILE="/var/log/llama-gpu-watchdog.log"
LOCK_FILE="/tmp/llama-watchdog.lock"
MAX_ATTEMPTS=2
COOLDOWN_MINUTES=30
HEALTH_URL="http://localhost:8089/health"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE" | logger -t llama-gpu-watchdog 2>/dev/null || true
}

lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "WARN: another instance is running, exiting"
        exit 0
    fi
}

# ──────────────────────────────────────────────
# Detection: is llama running on CPU?
# ──────────────────────────────────────────────
is_cpu_fallback() {
    # Check 1: nvidia-smi shows 0 MiB used by llama-server container
    local vram
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | tr -d ' MiB' | head -1)
    if [[ -n "${vram}" && "$vram" -eq 0 ]]; then
        log "DETECT: VRAM usage = 0 MiB (no GPU usage)"
        return 0
    fi

    # Check 2: logs contain CUDA init failure
    if docker logs --tail=40 "$CONTAINER" 2>/dev/null | grep -q "ggml_cuda_init: failed"; then
        log "DETECT: ggml_cuda_init failed in recent logs"
        return 0
    fi

    # Check 3: logs contain 'no usable GPU found'
    if docker logs --tail=40 "$CONTAINER" 2>/dev/null | grep -q "no usable GPU found"; then
        log "DETECT: 'no usable GPU found' in recent logs"
        return 0
    fi

    # Check 4: container running but nvidia-smi inside container shows 0 MiB
    local inside_vram
    inside_vram=$(docker exec "$CONTAINER" nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | tr -d ' MiB' | head -1 || true)
    if [[ -n "$inside_vram" && "$inside_vram" -eq 0 ]]; then
        log "DETECT: inside container VRAM = 0 MiB"
        return 0
    fi

    return 1
}

# ──────────────────────────────────────────────
# Self-heal: restart service
# ──────────────────────────────────────────────
attempt_repair() {
    local attempt="$1"
    log "REPAIR: attempt $attempt -- restarting container"
    docker restart "$CONTAINER" >/dev/null 2>&1 || true

    # Wait for health
    for i in $(seq 1 60); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            log "REPAIR: health OK after restart"
            return 0
        fi
        sleep 2
    done

    log "REPAIR: health NOT OK after restart"
    return 1
}

deep_repair() {
    log "DEEP-REPAIR: restarting docker + nvidia-persistenced"
    systemctl restart docker || true
    systemctl restart nvidia-persistenced || true

    # ensure container is up again
    docker start "$CONTAINER" >/dev/null 2>&1 || true

    for i in $(seq 1 90); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            log "DEEP-REPAIR: health OK after docker/nvidia restart"
            return 0
        fi
        sleep 2
    done

    log "DEEP-REPAIR: health NOT OK after docker/nvidia restart"
    return 1
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    lock

    # Check cooldown file
    local cooldown_file="/tmp/llama-watchdog-cooldown"
    if [[ -f "$cooldown_file" ]]; then
        local cooldown_ts
        cooldown_ts=$(cat "$cooldown_file" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        local elapsed=$(( now - cooldown_ts ))
        if (( elapsed < COOLDOWN_MINUTES * 60 )); then
            log "COOLDOWN: still in cooldown ($(( elapsed / 60 ))min of ${COOLDOWN_MINUTES}min)"
            exit 0
        else
            rm -f "$cooldown_file"
            log "COOLDOWN: expired, resuming checks"
        fi
    fi

    # Check if container is running at all
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        log "ERROR: container $CONTAINER not running"
        exit 1
    fi

    # Check health endpoint (may be OK even on CPU, so we still check GPU)
    local health
    health=$(curl -s "$HEALTH_URL" 2>/dev/null || echo '{"status":"error"}')
    if ! echo "$health" | grep -q '"status":"ok"'; then
        log "WARN: health endpoint NOT ok: $health"
        # Still try repair -- maybe temporary
    fi

    # Detect CPU fallback
    if ! is_cpu_fallback; then
        log "OK: GPU is being used properly"
        exit 0
    fi

    # Read attempt counter
    local counter_file="/tmp/llama-watchdog-attempts"
    local attempts=0
    if [[ -f "$counter_file" ]]; then
        attempts=$(cat "$counter_file" 2>/dev/null || echo "0")
    fi

    if (( attempts >= MAX_ATTEMPTS )); then
        log "HARD-FAIL: reached max $MAX_ATTEMPTS attempts, entering cooldown"
        date +%s > "$cooldown_file"
        rm -f "$counter_file"
        # Optional: trigger alert here (webhook/telegram/etc.)
        exit 1
    fi

    # Attempt repair
    attempts=$(( attempts + 1 ))
    echo "$attempts" > "$counter_file"
    log "REPAIR: attempt $attempts/$MAX_ATTEMPTS"

    if attempt_repair "$attempts"; then
        # Verify GPU is actually back
        sleep 5
        if is_cpu_fallback; then
            log "REPAIR: still CPU fallback after container restart"

            # second-stage self-heal
            if deep_repair; then
                sleep 8
                if is_cpu_fallback; then
                    log "DEEP-REPAIR: still CPU fallback, will retry next cycle"
                    exit 1
                else
                    log "DEEP-REPAIR: SUCCESS -- GPU recovered"
                    rm -f "$counter_file"
                    exit 0
                fi
            else
                log "DEEP-REPAIR: failed to restore service"
                exit 1
            fi
        else
            log "REPAIR: SUCCESS -- GPU recovered"
            rm -f "$counter_file"
            exit 0
        fi
    else
        log "REPAIR: restart failed (health never came back)"
        exit 1
    fi
}

main "$@"
