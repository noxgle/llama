# AGENTS.md

## Scope
- This repo runs a remote `llama.cpp` server on `ag@192.168.200.38`.
- Operational sources of truth: `docker-compose.yml`, `Dockerfile`, `sync.sh`, `configs/*.env`.

## Deployment gotchas (critical)
- `sync.sh push` excludes `.env` (`--exclude=".env"`). Editing `configs/*.env` locally does not switch the active remote model.
- Remote `docker compose up -d` without `--env-file` uses `~/llama/.env` if present; otherwise compose defaults from `docker-compose.yml`.
- Safe model switch patterns on remote:
  - `cp ~/llama/configs/<config>.env ~/llama/.env && docker compose up -d`
  - `docker compose --env-file configs/<config>.env up -d`

## Fast operational commands
```bash
# Sync repo only (no restart)
./sync.sh push

# Restart current remote setup
./sync.sh deploy

# Rebuild image + restart remotely
./sync.sh rebuild

# Health / status
./sync.sh health
./sync.sh status

# Throughput probe (predicted_per_second)
ssh ag@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars of text.\"}],\"model\":\"gemma-4\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'
```

## Runtime/build facts agents usually miss
- Compose default model is E4B Unsloth (`MODEL` default in `docker-compose.yml`).
- Compose defaults are high-memory oriented: `CTX=65536`, `NGLAYERS=40`, `BATCH=1024`, `UBATCH=1024`.
- `docker-compose.yml` does not pass `THREADS_BATCH`, `PARALLEL`, `POLL`; these are only wired in `docker-compose.test.yml`.
- Build is pinned by `LLAMA_REF` (`docker-compose.yml` -> build arg, default `b9009`).
- Docker build sets `-DGGML_CUDA_NCCL=OFF`; keep it unless you intentionally rework CUDA/NCCL runtime.

## File-level caveats
- `docker-compose.test.yml` still uses legacy build args (`PR_NUMBER`, `GH_TOKEN`) not consumed by current `Dockerfile`; treat this file as experimental unless updated.
- `sync.sh` output/comments are partly Polish; do not infer docs language policy from it.

## Constraints
- Do not modify `Dockerfile` unless the user explicitly asks.
- Keep documentation/comments in English.
- Keep active runtime configs in `configs/`; move deprecated/test-only configs to `configs/archive/`.
