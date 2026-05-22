#!/bin/bash
# ═══════════════════════════════════════════════
# 40-deploy-llama.sh — Clone repo, configure, build & start
# ═══════════════════════════════════════════════
# Runs inside: LXC container (via pct exec | bash)
# Expects env vars: PROJECT_DIR, REPO_URL, REPO_BRANCH,
#                   ACTIVE_CONFIG, APP_PORT, LLAMA_REPO, LLAMA_REF
# ═══════════════════════════════════════════════

set -euo pipefail

STEP_NAME="40-deploy-llama"
echo "=== [STEP $STEP_NAME] Deploy llama.cpp ==="

# Defaults (if not provided via env)
: "${PROJECT_DIR:=/opt/llama}"
: "${REPO_URL:=https://github.com/noxgle/llama.git}"
: "${REPO_BRANCH:=master}"
: "${ACTIVE_CONFIG:=configs/qwen3.6-35ba3b-mtp-unsloth.env}"
: "${APP_PORT:=8089}"
: "${LLAMA_REPO:=https://github.com/ggml-org/llama.cpp.git}"
: "${LLAMA_REF:=master}"
: "${SKIP_BUILD:=false}"

# ── 1. Create project directory ──
mkdir -p "$PROJECT_DIR"

# ── 2. Clone/pull the operational repo ──
if [[ -d "${PROJECT_DIR}/.git" ]]; then
  echo "  [SKIP] Repo already cloned in $PROJECT_DIR"
  echo "  [INFO] To update: cd $PROJECT_DIR && git pull"
else
  echo "  [INFO] Cloning $REPO_URL (branch: $REPO_BRANCH) into $PROJECT_DIR ..."
  git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$PROJECT_DIR" 2>&1 | tail -3 | sed 's/^/         /'
  echo "  [DONE] Repository cloned"
fi

cd "$PROJECT_DIR"

# ── 3. Set up .env from the active config ──
if [[ -f ".env" ]]; then
  echo "  [SKIP] .env already exists — keeping existing"
  echo "  [INFO] To switch config: cp configs/<name>.env .env && docker compose down && docker compose up -d"
else
  if [[ -f "$ACTIVE_CONFIG" ]]; then
    cp "$ACTIVE_CONFIG" .env
    echo "  [DONE] .env created from $ACTIVE_CONFIG"
  else
    echo "  [FAIL] Config not found: $ACTIVE_CONFIG"
    echo "  Available configs:"
    ls configs/*.env 2>/dev/null | sed 's/^/         /' || echo "         (none found)"
    exit 1
  fi
fi

# ── 4. Override LLAMA_REPO and LLAMA_REF if needed ──
# These are compose build args; ensure they're set in .env if not already
grep -q '^LLAMA_REPO=' .env 2>/dev/null || echo "LLAMA_REPO=$LLAMA_REPO" >> .env
grep -q '^LLAMA_REF=' .env 2>/dev/null || echo "LLAMA_REF=$LLAMA_REF" >> .env

# ── 5. Docker compose build (only if not skipped) ──
if [[ "$SKIP_BUILD" == "true" ]]; then
  echo "  [SKIP] Docker build skipped (SKIP_BUILD=true)"
  echo "  [INFO] Ensure image exists or run: docker compose build"
else
  echo "  [INFO] Building Docker image (this will take 5-15 minutes on first run) ..."
  docker compose build 2>&1 | tail -5 | sed 's/^/         /'
  echo "  [DONE] Docker image built"
fi

# ── 7. Docker compose up ──
echo "  [INFO] Starting services (docker compose up -d) ..."
docker compose down 2>/dev/null || true
docker compose up -d 2>&1 | sed 's/^/         /'

# ── 8. Wait for health endpoint ──
echo "  [INFO] Waiting for health endpoint (up to 300s) ..."
HEALTH_URL="http://localhost:${APP_PORT}/health"
for i in $(seq 1 300); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
  if [[ "$CODE" == "200" ]]; then
    echo "  [OK] Health endpoint ready after ~${i}s (HTTP $CODE)"
    break
  fi
  if [[ $((i % 30)) -eq 0 ]]; then
    echo "  [INFO] Still waiting... (${i}s elapsed, HTTP $CODE)"
    # Show recent logs for debugging
    docker compose logs --tail=5 2>/dev/null | sed 's/^/  LOG: /' || true
  fi
  sleep 1
done

if ! curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
  echo "  [FAIL] Health endpoint not responding after 300s"
  echo "  Check: docker compose logs --tail=40"
  docker compose logs --tail=40 2>&1 | sed 's/^/         /'
  exit 1
fi

echo ""
echo "=== [STEP $STEP_NAME] Complete ==="
echo "  Server running at http://localhost:${APP_PORT}"
