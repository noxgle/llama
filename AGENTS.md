# AGENTS.md

## Scope

| Role | Host | GPU | Purpose |
|------|------|:---:|---------|
| **Dev** | `root@192.168.200.38:/opt/llama` | RTX A2000 6 GB | Compilation, config/model testing |
| **Prod Qwen** | `root@192.168.200.20:/opt/llama` | RTX A2000 6 GB | Qwen3.6 35B A3B MTP Q4_K_M (~33 tok/s) |
| **Prod Gemma4** | `root@192.168.200.21:/opt/llama` | RTX A2000 6 GB | Gemma4 26B Q4_K_M MTP (~27 tok/s) |
| **Prod Qwen Q5** | `root@192.168.200.19:/opt/llama` | RTX A2000 6 GB | Qwen3.6 35B A3B MTP Q5_K_M (~30 tok/s) |

SOTs: `llama.sh`, `configs/*.env`, `deploy/install-llama.sh`, `.github/workflows/build.yml`, `docker-compose.yml`.

## Deployment gotchas (read before touching servers)

### `--gpus all` → 1.5 tok/s after reboot (Docker 26.1.5)
**Never use `--gpus all`** (`llama.sh`'s `docker run`). Use `deploy.resources.reservations.devices` (`docker-compose.yml` + `.env`). After boot, `--gpus all` triggers CPU-serialized CUDA JIT on first inference (1.5 vs 32 tok/s). Verified: docker-compose method gives 31.8 tok/s immediately. No systemd/nvidia-persistenced needed.

### `.env` changes require down+up, not restart
`docker compose restart` does NOT re-read `.env`. Always `docker compose down && docker compose up -d`.

### `.env` is never synced
In `.gitignore` and excluded by `sync.sh push`. Changing `configs/*.env` locally has no effect; on server: `cp configs/<name>.env .env && docker compose down && docker compose up -d`.

### HF download bug (get_hf_plan)
`:UD-Q4_K_M` works via HF, but `:UD-Q8_K_XL` and subdirectory files (e.g., `MTP/gemma-...-Q8_0-MTP.gguf`) fail. Workaround: local symlinks with `MODEL_FLAG=-m` / `DRAFT_FLAG=-md`. See docker-compose.yml for dual-flag pattern.

### Symlinks must use container paths, not host paths
Symlink targets must be **inside the container** (`/root/.cache/huggingface/hub/...`), not on the host (`/var/lib/docker/volumes/...`). The HF cache volume mounts at `/root/.cache/huggingface`. Verify with:
```bash
docker run --rm -v /opt/llama/models:/models -v llama_hf-cache:/root/.cache/huggingface \
  --entrypoint bash ghcr.io/noxgle/llama-server:latest \
  -c "head -c 4 /models/model.gguf | od -A x -t x1z"
```

### `deploy/install-llama.sh` — DO NOT MODIFY
This file is a critical provisioning script shared across all deployments. Changes must be reviewed and explicitly approved — do not edit it for config tweaks, workarounds, or local experiments.

## Current production config (Qwen3.6 Q4_K_M)
- **Config:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`
- **Model:** `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M` (HF)
- **Key values:** `CTX=143360` | `NGLAYERS=999` | `BATCH=3072`/`UBATCH=1536` | `CACHE_RAM=4096` | `CACHE_REUSE=256` | `CTX_CHECKPOINTS=8` | `CACHE_TYPE_K/V=q8_0` | `SPEC_TYPE=draft-mtp` | `SPEC_DRAFT_N_MAX=1`
- **llama.cpp:** commit `75ad0b2` (tag `b9770`), built and scp'd
- **Baseline throughput:** ~33 tok/s (short, q8_0 KV), ~25 tok/s (60K prefill at 505 t/s)

### New flags added (2026-06-28)
- `--cache-ram 4096` — prompt cache in system RAM (4 GiB). Works with all configs.
- `--cache-reuse 256` — KV cache reuse window. **Ineffective for MTP/SWA contexts** (Qwen3.6, Gemma4) — logs `not supported by this context` / `forcing full prompt re-processing`. Flag is harmless, just ignored.
- `--chat-template-kwargs {"preserve_thinking": true}` — returns `reasoning_content` in API responses (Qwen thinking tokens visible).
- `--threads-http 2` — HTTP server threads.

### Batch tuning (RTX A2000 6 GB)
`UBATCH` must ≈ `BATCH` (1024/256 was −39%). Optimal: **BATCH=3072, UBATCH=1536** (+88% prefill, −35% total time, ~86% VRAM). 4096/2048 works at 93% VRAM but 5120/2560 OOMs. Generation speed (~25 tok/s) is memory-bandwidth-bound, unaffected by batch size.

### MTP n_max tuning
`SPEC_DRAFT_N_MAX=1` is optimal (vs n_max=2: +2%, vs n_max=3: −6%, vs MTP off: +10%). Each extra draft token triggers MoE expert computation on CPU — overhead outweighs acceptance gains.

## Operational commands
```bash
# Quick throughput probe on any server
ssh root@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars.\"}],\"model\":\"qwen3.6\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'

# Guarded benchmark (fails on CPU fallback)
HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh

# Guarded health
curl -s http://192.168.200.38:8089/health

# Sync + restart (sync.sh)
./sync.sh push          # sync local → server (excludes .env)
./sync.sh deploy        # push + docker compose down && up -d
./sync.sh health        # HTTP 200 + VRAM + RAM
./sync.sh status        # container + GPU processes
```

## Production scripts

### `docker-compose.yml` (recommended)
- `restart: unless-stopped` for auto-recovery.
- GPU via `deploy.resources.reservations.devices` (not `--gpus all`).
- Reads `.env` — copy from `configs/<name>.env` then `down && up -d`.

### `llama.sh` (docker run wrapper, testing only)
**Do not use on Docker 26** — `--gpus all` causes 1.5 tok/s post-reboot. Fine for local testing.
```bash
/opt/llama/llama.sh start qwen       # reads configs/qwen3.6-35ba3b-mtp-unsloth.env
/opt/llama/llama.sh start gemma4     # reads configs/gemma4-26b-q4-k-m-mtp.env
/opt/llama/llama.sh stop             # kills all llama containers
/opt/llama/llama.sh status           # list running
```

### Router mode (experimental)
`/opt/llama/llama.sh start router` — loads models from `configs/router-preset.ini`. Switch via `POST /models/load {"model": "qwen-q4"}`. VRAM leak between swaps on 6 GB: `docker restart llama-router` sometimes needed.

## Build
- Source: `ggml-org/llama.cpp.git`, pinned by `LLAMA_REF` (default `master`).
- `-DGGML_CUDA_NCCL=OFF` — single GPU, no libnccl.so.2 dependency.
- **Image:** `ghcr.io/noxgle/llama-server:latest` (public, no auth to pull).
- CI/CD: `.github/workflows/build.yml` — push to `master` or tag `b*`. Self-hosted runner via `SELF_HOSTED_RUNNER=self-hosted` repo variable.
- Do not modify `Dockerfile` unless explicitly asked.

## Provisioning gotchas (install-llama.sh)
- **Debian trixie:** Docker/NVIDIA repos don't exist — script maps `trixie` → `bookworm`.
- **Minimum disk:** 70 GB (80 GB recommended for Q5 variant).
- **GPU passthrough (Proxmox LXC):** Script aborts if `/dev/nvidia*` missing and prints required `lxc.*` config entries.
- **Model download:** First start downloads via `-hf`; script waits 60s, Docker restart policy takes over.

## GPU watchdog
- `deploy/systemd/llama-gpu-watchdog.{service,timer}` — detects CPU fallback (0 MiB VRAM, `ggml_cuda_init: failed`).
- Self-heals: restart container → if still CPU → restart Docker. Max 2 attempts, 30 min cooldown.
- Deploy on new server: `cp scripts/gpu-watchdog.sh deploy/systemd/llama-gpu-watchdog.{service,timer} /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now llama-gpu-watchdog.timer`

## Recovery
- Container crash / MTP segfault: `docker compose down && docker compose up -d`.
- VRAM exhausted: reduce `CTX`, reduce `BATCH`/`UBATCH`, or switch config.
- Stale CUDA contexts after crash-loop: `fuser -v /dev/nvidia*` → `kill -9 <PID>`.

## Config conventions
- Active configs in `configs/`. Deprecated go to `configs/archive/`.
- `docker-compose.yml` defaults: `CTX=65536`, `NGLAYERS=40`, `BATCH=1024`, `UBATCH=1024`.
- `sync.sh` comments are partly Polish; ignore — script commands are in English.
- **Qwen models** use thinking tokens (`reasoning_content`) — set `max_tokens >= 1024` or `"reasoning": false` to get visible content.
