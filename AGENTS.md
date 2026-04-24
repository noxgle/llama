# AGENTS.md

## Scope
- Repository is a Dockerized `llama.cpp` server for a remote host: `ag@192.168.200.38`.
- Main operational files: `docker-compose.yml`, `sync.sh`, `configs/*.env`.

## Critical deployment behavior (easy to get wrong)
- `sync.sh` **does not sync `.env`** (`rsync` excludes it). Updating a config file alone does not change the active remote model.
- For model/config switches, do one of these explicitly on remote:
  - `cp ~/llama/configs/<config>.env ~/llama/.env && docker compose up -d`
  - `docker compose --env-file configs/<config>.env up -d`
- `docker compose up -d` without `--env-file` uses remote `~/llama/.env` (or compose defaults if missing).

## Verified commands
```bash
# Sync repo to remote
./sync.sh push

# Deploy specific config (recommended)
ssh ag@192.168.200.38 "cd ~/llama && docker compose --env-file configs/gemma4-e2b-ud-q4-xl.env up -d"

# Make config persistent default on remote
ssh ag@192.168.200.38 "cp ~/llama/configs/gemma4-e2b-ud-q4-xl.env ~/llama/.env"

# Health check
ssh ag@192.168.200.38 "curl -s http://localhost:8089/health"

# Throughput test (read predicted_per_second)
ssh ag@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars of text.\"}],\"model\":\"gemma-4\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'

# VRAM and RAM checks
ssh ag@192.168.200.38 "nvidia-smi --query-gpu=memory.used,memory.total --format=csv"
ssh ag@192.168.200.38 "free -m"
```

## Current verified baselines
- `configs/gemma4-e2b-ud-q4-xl.env` (BATCH/UBATCH=2048): ~50.8 tok/s, VRAM ~4.4 GB.
- `configs/gemma4-e4b-ud-q4-xl.env`: ~27 tok/s, VRAM ~5.0 GB.
- `configs/gemma4-26b-ud-iq2-xxs.env` (MoE partial offload): ~20 tok/s, VRAM ~5.2 GB.

## Non-obvious config caveats
- `docker-compose.yml` does **not** pass `THREADS_BATCH`, `PARALLEL`, `POLL` flags.
  - These keys in `.env`/configs are currently ignored in normal runs.
  - They are only wired in `docker-compose.test.yml`.
- Compose defaults in `docker-compose.yml` are E4B-oriented (`MODEL`, `CTX=65536`, `NGLAYERS=40`, `BATCH=1024`).

## Modification constraints
- Do not modify `Dockerfile` unless user explicitly asks.
- Keep documentation/comments in English only.
- Archive legacy test configs under `configs/archive/`; keep active runtime configs in `configs/`.
