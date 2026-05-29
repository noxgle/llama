# AGENTS.md

## Scope
- This repo runs a remote `llama.cpp` server at `root@192.168.200.38:/opt/llama`.
- Operational SOTs: `docker-compose.yml`, `Dockerfile`, `sync.sh`, `configs/*.env`.

## Deployment gotchas (critical)

### Server path mismatch (known bug)
`sync.sh` targets `ag@192.168.200.38:~/llama`. Real server is `root@192.168.200.38:/opt/llama`. **All manual `ssh`/`scp` must use `root@192.168.200.38` and `/opt/llama` paths.** `sync.sh` commands like `deploy`, `rebuild`, `restart` etc. will fail or target the wrong host — do not rely on them without fixing first.

### .env is never synced
- `.env` is in `.gitignore`.
- `sync.sh push` also `--exclude=".env"`.
- Editing `configs/*.env` locally does NOT affect the server. To switch config:
  ```bash
  # On server as root:
  cp /opt/llama/configs/<name>.env /opt/llama/.env
  docker compose down && docker compose up -d
  ```

### .env changes require down+up, not restart
`docker compose restart` does NOT re-read `.env`. Always do `docker compose down && docker compose up -d`.

### Local .env != server .env
- Local `.env`: stale Gemma 4 E4B config (Unsloth).
- Server `.env`: Qwen3.6-35B-A3B-MTP Q4_K_M with CTX=192K, MTP on.
- These diverge because `.env` never syncs. The server-side `configs/` is only updated via `sync.sh push`, but `.env` must be `cp`'d manually.

## Current production config (validated stable)
- **Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`
- **Model:** `localweights/Qwen3.6-35B-A3B-MTP-Q4_K_M-GGUF` (HF community quant)
- **Context:** 163840 (160K)
- **MTP:** `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2` (~80% accept rate, ~21.7 tok/s)
- **VRAM:** ~5653/6144 MiB, RAM: ~20/24 GiB
- Use this as the default reference. All Gemma 4 configs are legacy/archive.

## MTP speculative decoding
- Upstream PR #22673, on `ggml-org/llama.cpp:master`. Flags in `docker-compose.yml`:
  - `--spec-type ${SPEC_TYPE:-none}` (set to `draft-mtp`)
  - `--spec-draft-n-max ${SPEC_DRAFT_N_MAX:-3}`
  - `--no-mmproj` (required; MTP segfaults on multimodal prompts otherwise)
- Turboquant fork (`AtomicBot-ai/atomic-llama-cpp-turboquant`) was abandoned — MTP crashes with SIGSEGV.

## Build
- Source: `ggml-org/llama.cpp.git`, pinned by `LLAMA_REF` compose build arg (default `master`).
- `-DGGML_CUDA_NCCL=OFF` — single-GPU host, avoid `libnccl.so.2` runtime issues.
- Do not modify `Dockerfile` unless explicitly asked.

## Operational commands
```bash
# Quick throughput probe
ssh root@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars.\"}],\"model\":\"qwen3.6\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'

# Guarded benchmark (aborts on CPU fallback)
HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh

# Server health
curl -s http://192.168.200.38:8089/health
```

## GPU watchdog
- Deployed via systemd timer: `deploy/systemd/llama-gpu-watchdog.{service,timer}`.
- Detects CPU fallback (0 MiB VRAM, `ggml_cuda_init: failed` in logs).
- Self-heal: restart container → if still CPU → restart Docker + nvidia-persistenced.
- Max 2 attempts, 30 min cooldown.
- Deploy:
  ```bash
  cp scripts/gpu-watchdog.sh /opt/llama/scripts/
  cp deploy/systemd/llama-gpu-watchdog.{service,timer} /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now llama-gpu-watchdog.timer
  ```

## Config conventions
- Active configs in `configs/`. Deprecated/test-only go to `configs/archive/`.
- `docker-compose.yml` defaults assume high memory: `CTX=65536`, `NGLAYERS=40`, `BATCH=1024`, `UBATCH=1024`.
- `docker-compose.test.yml` is experimental (legacy build args not consumed by current Dockerfile).
- `sync.sh` comments/output are partly Polish; ignore for docs language policy.

## Recovery
- If container crashes or MTP segfaults: check `/var/log/llama-gpu-watchdog.log`, restart via `docker compose down && docker compose up -d`.
- If VRAM exhausted: reduce `CTX`, switch to smaller model config, or reduce `BATCH`/`UBATCH`.
