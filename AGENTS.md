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
**Never use `--gpus all`**. Use `deploy.resources.reservations.devices` (`docker-compose.yml` + `.env`) or `--runtime=nvidia` for `docker run` (llama.sh, benchmark scripts — fixed 2026-08-01). After boot, `--gpus all` triggers CPU-serialized CUDA JIT on first inference (1.5 vs 32 tok/s). Verified: docker-compose method gives 31.8 tok/s immediately. No systemd/nvidia-persistenced needed.

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
- **Key values:** `CTX=143360` | `NGLAYERS=999` | `BATCH=3072`/`UBATCH=1536` | `CACHE_RAM=4096` | `CACHE_REUSE=256` | `CTX_CHECKPOINTS=10` | `CACHE_TYPE_K/V=q8_0` | `SPEC_TYPE=draft-mtp` | `SPEC_DRAFT_N_MAX=1` | `SLOT_SAVE_PATH=/slots`
- **llama.cpp:** commit `b10213` (master, 2026-08-01 — beyond b9770/b10068). Previous build: `b10068`. Build locally with `LLAMA_REF=b10213 LLAMA_NATIVE=ON docker compose build`
- **Baseline throughput:** ~33.8 tok/s (knowledge suite, 10/10 A, 26K tok, 13.3 min), ~32.8 tok/s (long), prefill 507 t/s @ 85.8K prompt

### New flags added (2026-06-28)
- `--cache-ram 4096` — prompt cache in system RAM (4 GiB). Works with all configs.
- `--cache-reuse 256` — KV cache reuse window. **Ineffective for MTP/SWA contexts** (Qwen3.6, Gemma4) — logs `not supported by this context` / `forcing full prompt re-processing`. Flag is harmless, just ignored.
- `--chat-template-kwargs {"preserve_thinking": false}` — Qwen internal reasoning tokens hidden in API.
- `--threads-http 2` — HTTP server threads.

### llama.cpp b10213 breaking changes (2026-08-01)
- **Empty argv elements rejected** — `--hf-repo-draft ""`, `--no-mmproj ""` etc. now fail with `error: invalid argument:`. Compose workaround: entrypoint filters empty args; draft model via env `LLAMA_ARG_SPEC_DRAFT_MODEL` / `LLAMA_ARG_SPEC_DRAFT_HF_REPO`; mmproj as separate flag+path elements (`--mmproj` + path — the `--mmproj=/path` equals-form is ALSO rejected). See `docker-compose.yml` + commits `6ca93f4`, `45431b8`, `ff31f6b`.
- **Slot save/restore endpoint changed:** `POST /slots/{id}?action=save|restore` (query param), old `/slots/{id}/save` → 404. Filename is relative to `--slot-save-path`. Requires the flag to be set (else 404 `File Not Found`). Wired: `SLOT_SAVE_PATH=/slots` in config → `llama.sh` passes `--slot-save-path`.
- **Verified on dev .38 (local `GGML_NATIVE=ON` build):** knowledge 33.8 tok/s (+0.6% vs b10068), guarded short 33.8 / long 32.8, MTP sweep ordering unchanged (n1 best: 33.06; n3 29.11; n4 25.92; off 30.84), batch 85.8K prefill 507 t/s. **No regressions.**
- **Slot save/restore is SLOWER than RAM prompt cache** on this setup: restore from 100 MB disk file + reprocess ≈ 5.0–5.3 s prefill vs 1.1 s with `cache_prompt=true` + `--cache-ram 4096`. Feature works but is not beneficial here.

### docker run on Docker 26 — use `--runtime=nvidia`, NOT `--gpus all`
`llama.sh` and `scripts/benchmark-draft-mtp.sh` now use `--runtime=nvidia` (+ `NVIDIA_VISIBLE_DEVICES=all`) — `--gpus all` alone doesn't mount `libcuda.so.1` and triggers the post-reboot CPU-JIT gotcha. `llama.sh` image override: `LLAMA_IMAGE=ghcr.io/noxgle/llama-server:b10213 ./llama.sh start qwen`.

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
**OK on Docker 26** since 2026-08-01 — uses `--runtime=nvidia` (+ `NVIDIA_VISIBLE_DEVICES=all`), not `--gpus all`. Image override: `LLAMA_IMAGE=ghcr.io/noxgle/llama-server:b10213`. Mounts `/opt/llama/slots → /slots` for slot save/restore; passes `--slot-save-path` when `SLOT_SAVE_PATH` is set in config.
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
- **Build flags:** Dockerfile uses `ARG LLAMA_NATIVE=OFF` (configurable). CI pulls pre-built image (LLAMA_NATIVE=OFF, no AVX2 in generated code, relies on GGML runtime dispatch). `install-llama.sh --build-local` passes `LLAMA_NATIVE=ON` → `-march=native` on target CPU. **Do NOT use `-DCMAKE_CXX_FLAGS="-march=x86-64-v3"`** — causes SIGILL on Ryzen 5600X despite CPU feature support (root cause unclear).
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
