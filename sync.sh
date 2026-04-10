#!/bin/bash

# Synchronizacja z serwerem llama.cpp
# Usage: ./sync.sh <command> [args]
#
# Commands:
#   push        - sync lokalne pliki -> serwer
#   pull        - sync serwer -> lokalne pliki (konfiguracje)
#   deploy      - sync + restart kontenera (bez build)
#   rebuild     - sync + build + restart kontenera
#   start       - uruchom kontener
#   stop        - zatrzymaj kontener
#   restart     - restart kontenera
#   logs        - pokaż logi kontenera
#   status      - status kontenera
#   health      - sprawdź health endpoint
#   ssh         - otwórz SSH do serwera
#   config      - pokaż aktualną konfigurację na serwerze

set -e

# Konfiguracja
SERVER="ag@192.168.200.38"
REMOTE_DIR="~/llama"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Funkcja wykonująca komendę na serwerze
ssh_exec() {
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SERVER" "$1"
}

# Funkcja rsync
rsync_push() {
    log_info "Sync: local -> server ($SERVER:$REMOTE_DIR)"
    
    # Exclude patterns
    EXCLUDE=(
        --exclude=".git/"
        --exclude=".env"
        --exclude="*.log"
        --exclude="build/"
    )
    
    rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${EXCLUDE[@]}" \
        "$LOCAL_DIR/" "$SERVER:$REMOTE_DIR/"
    
    log_ok "Sync zakończony"
}

rsync_pull() {
    log_info "Sync: server -> local ($SERVER:$REMOTE_DIR -> local)"
    
    rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=no" \
        --include="configs/" \
        --include="*.env" \
        --include="*.md" \
        --exclude="*" \
        "$SERVER:$REMOTE_DIR/" "$LOCAL_DIR/"
    
    log_ok "Pobieranie zakończone"
}

cmd_push() {
    rsync_push
}

cmd_pull() {
    rsync_pull
}

cmd_deploy() {
    rsync_push
    log_info "Restart kontenera..."
    ssh_exec "cd $REMOTE_DIR && docker compose restart"
    log_ok "Deploy zakończony"
}

cmd_rebuild() {
    rsync_push
    log_info "Budowanie i restart kontenera..."
    ssh_exec "cd $REMOTE_DIR && docker compose up -d --build"
    log_ok "Rebuild zakończony"
}

cmd_start() {
    log_info "Uruchamianie kontenera..."
    ssh_exec "cd $REMOTE_DIR && docker compose up -d"
    log_ok "Kontener uruchomiony"
}

cmd_stop() {
    log_info "Zatrzymywanie kontenera..."
    ssh_exec "cd $REMOTE_DIR && docker compose down"
    log_ok "Kontener zatrzymany"
}

cmd_restart() {
    log_info "Restart kontenera..."
    ssh_exec "cd $REMOTE_DIR && docker compose restart"
    log_ok "Kontener zrestartowany"
}

cmd_logs() {
    ssh_exec "cd $REMOTE_DIR && docker compose logs --tail=50 -f"
}

cmd_status() {
    echo -e "${BLUE}=== Status kontenera ===${NC}"
    ssh_exec "cd $REMOTE_DIR && docker compose ps"
    echo ""
    echo -e "${BLUE}=== Zużycie GPU ===${NC}"
    ssh_exec "nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader 2>/dev/null || echo 'Brak GPU'"
}

cmd_health() {
    echo -e "${BLUE}=== Health Check ===${NC}"
    RESPONSE=$(ssh_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:8089/health 2>/dev/null || echo 'failed'")
    if [ "$RESPONSE" = "200" ]; then
        log_ok "Serwer działa (HTTP 200)"
    else
        log_err "Serwer niedostępny (HTTP: $RESPONSE)"
    fi
    
    echo ""
    echo -e "${BLUE}=== VRAM (GPU) ===${NC}"
    ssh_exec "nvidia-smi --query-gpu=memory.used,memory.total,memory.free --format=csv,noheader 2>/dev/null || echo 'Brak GPU'"
    echo ""
    echo -e "${BLUE}=== Container RAM ===${NC}"
    ssh_exec "docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null || echo 'Brak kontenera'"
    echo ""
    echo -e "${BLUE}=== System RAM ===${NC}"
    ssh_exec "free -h | head -2"
    echo ""
    echo -e "${BLUE}=== Swap ===${NC}"
    ssh_exec "free -h | grep -E 'Wymiana|Swap'"
}

cmd_ssh() {
    log_info "Łączenie z serwerem..."
    ssh -o StrictHostKeyChecking=no "$SERVER"
}

cmd_config() {
    echo -e "${BLUE}=== Aktualna konfiguracja na serwerze ===${NC}"
    ssh_exec "cd $REMOTE_DIR && cat .env 2>/dev/null || echo 'Brak pliku .env'"
}

# Main
COMMAND="${1:-help}"

case "$COMMAND" in
    push)     cmd_push ;;
    pull)     cmd_pull ;;
    deploy)   cmd_deploy ;;
    rebuild)  cmd_rebuild ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    restart)  cmd_restart ;;
    logs)     cmd_logs ;;
    status)   cmd_status ;;
    health)   cmd_health ;;
    ssh)      cmd_ssh ;;
    config)   cmd_config ;;
    help|--help|-h)
        echo "Llama.cpp Server Sync Tool"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  push     - sync lokalne pliki -> serwer"
        echo "  pull     - sync serwer -> lokalne (configs)"
        echo "  deploy   - sync + restart kontenera"
        echo "  rebuild  - sync + build + restart kontenera"
        echo "  start    - uruchom kontener"
        echo "  stop     - zatrzymaj kontener"
        echo "  restart  - restart kontenera"
        echo "  logs     - pokaż logi kontenera"
        echo "  status   - status kontenera i GPU"
        echo "  health   - sprawdź health endpoint"
        echo "  ssh      - otwórz SSH do serwera"
        echo "  config   - pokaż aktualną konfigurację"
        echo ""
        echo "Examples:"
        echo "  $0 push           # sync pliki"
        echo "  $0 deploy         # sync + restart"
        echo "  $0 rebuild        # sync + build + restart"
        echo "  $0 status         # sprawdź status"
        echo "  $0 logs           # pokaż logi"
        ;;
    *)        log_err "Nieznana komenda: $COMMAND"; exit 1 ;;
esac