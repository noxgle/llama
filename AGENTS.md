# AGENTS.md - Quick Reference

## Critical Deployment Rule

**Always use `--env-file` or copy config to `.env`:**
```bash
# Wrong (uses default from docker-compose.yml):
docker compose up -d

# Correct (two options):
docker compose --env-file configs/gemma4-e2b-ud-q4-xl.env up -d
# OR
cp configs/gemma4-e2b-ud-q4-xl.env .env && docker compose up -d
```

The server has its own `.env` file at `~/llama/.env` on 192.168.200.38 that must be updated too.

## Quick Commands

```bash
# Sync and deploy
./sync.sh push
ssh ag@192.168.200.38 "cd ~/llama && docker compose --env-file configs/gemma4-e2b-ud-q4-xl.env up -d"

# Health check
curl http://192.168.200.38:8089/health

# Performance test
ssh ag@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\": [{\"role\": \"user\", \"content\": \"Test\"}], \"model\": \"gemma-4\", \"max_tokens\": 500}"' \
  | jq .timings.predicted_per_second

# VRAM check
ssh ag@192.168.200.38 "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits"
```

## Current Best Config

| Config | Model | Tokens/sec | VRAM |
|--------|-------|-----------|------|
| gemma4-e2b-ud-q4-xl.env | unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL | **~50** | ~3.2GB |
| gemma4-e4b-q5-bartowski.env | bartowski/google_gemma-4-E4B-it-GGUF:Q5_K_M | ~24 | ~5.7GB |

E2B = 2B effective params (smaller model, faster, less VRAM).

## Build Custom PR

```bash
# Build from custom PR
GH_TOKEN=ghp_xxx docker compose up -d --build

# Use --build-arg for PR number
docker build --build-arg PR_NUMBER=20050 .
```

## What NOT to Do

1. **Never modify Dockerfile** without explicit user approval
2. **Don't assume server has latest .env** — always sync AND copy to server's ~/llama/.env
3. **Don't guess server is reachable** — ping first if network issues

## Key Files

- `configs/*.env` — Model configs (don't modify Dockerfile)
- `sync.sh` — Server management
- `docker-compose.yml` — Service definition