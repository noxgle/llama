# AGENTS.md

## Scope

| Role | Host | GPU | Purpose |
|------|------|:---:|---------|
| **Dev** | `root@192.168.200.38:/opt/llama` | RTX A2000 6 GB | Compilation, config/model testing |
| **Prod Qwen** | `root@192.168.200.20:/opt/llama` | RTX A2000 6 GB | Qwen3.6 35B A3B MTP Q4_K_M (~33 tok/s) |
| **Prod Gemma4** | `root@192.168.200.21:/opt/llama` | RTX A2000 6 GB | Gemma4 26B Q4_K_M MTP (~27 tok/s) |
| **Prod Qwen Q5** | `root@192.168.200.19:/opt/llama` | RTX A2000 6 GB | Qwen3.6 35B A3B MTP Q5_K_M (b10665, 29.0 tok/s) |

SOTs: `llama.sh`, `configs/*.env`, `deploy/install-llama.sh`, `.github/workflows/build.yml`, `docker-compose.yml`.

## Deployment gotchas (read before touching servers)

### `--gpus all` → 1.5 tok/s after reboot (Docker 26.1.5)
**Never use `--gpus all`**. Use `deploy.resources.reservations.devices` (`docker-compose.yml` + `.env`) or `--runtime=nvidia` for `docker run` (llama.sh, benchmark scripts — fixed 2026-08-01). After boot, `--gpus all` triggers CPU-serialized CUDA JIT on first inference (1.5 vs 32 tok/s). Verified: docker-compose method gives 31.8 tok/s immediately. No systemd/nvidia-persistenced needed.

### `.env` changes require down+up, not restart
`docker compose restart` does NOT re-read `.env`. Always `docker compose down && docker compose up -d`.

### `.env` is never synced
In `.gitignore` and excluded by `sync.sh push`. Changing `configs/*.env` locally has no effect; on server: `cp configs/<name>.env .env && docker compose down && docker compose up -d`.

### HF download bug (get_hf_plan)
The `UD-*` refs were removed by unsloth on 2026-08 (repo re-uploaded as Dynamic 2.0, `main` only). Pin by commit SHA (e.g. Qwen `:5bc3e23`). Old naming `Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf` is gone; new is `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf`. Root-level files still download fine via pinned SHA; subdirectory files (e.g., `MTP/`) fail — use local symlinks with `MODEL_FLAG=-m` / `DRAFT_FLAG=-md`. See docker-compose.yml for dual-flag pattern.

### Symlinks must use container paths, not host paths
Symlink targets must be **inside the container** (`/root/.cache/huggingface/hub/...`), not on the host (`/var/lib/docker/volumes/...`). The HF cache volume mounts at `/root/.cache/huggingface`. Verify with:
```bash
docker run --rm -v /opt/llama/models:/models -v llama_hf-cache:/root/.cache/huggingface \
  --entrypoint bash ghcr.io/noxgle/llama-server:b10665 \
  -c "head -c 4 /models/model.gguf | od -A x -t x1z"
```

### `deploy/install-llama.sh` — DO NOT MODIFY
This file is a critical provisioning script shared across all deployments. Changes must be reviewed and explicitly approved — do not edit it for config tweaks, workarounds, or local experiments.

## Current production config (Qwen3.6 Q4_K_M)
- **Config:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`
- **Model:** `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:5bc3e23` (HF, pinned commit — Dynamic 2.0, 22.7 GB; unsloth removed the `UD-Q4_K_M` ref on 2026-08, new filename `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf`)
- **Key values:** `CTX=143360` | `NGLAYERS=999` | `BATCH=3072`/`UBATCH=1536` | `CACHE_RAM=4096` | `CACHE_REUSE=256` | `CTX_CHECKPOINTS=10` | `CACHE_TYPE_K/V=q8_0` | `SPEC_TYPE=draft-mtp` | `SPEC_DRAFT_N_MAX=1` | `SLOT_SAVE_PATH=/slots`
- **llama.cpp:** commit `b10068` (master, 2026-06-29 — beyond b9770). Previous build: `8c146a8`. b10213 tested 2026-08-01 but **deferred** — see "b10213 status" below.
- **Baseline throughput:** ~33.6 tok/s (knowledge suite, 10/10 A, 24K tok, 13.2 min), ~32.8 tok/s (long), prefill 507 t/s @ 85.8K prompt

## Stable b10665 line (2026-09-05)
- **Stable refs:** branch `stable/2026-09-05`, tag `stable-b10665-v1`; CI extracts `b10665` from that stable tag, so the resulting GHCR image is built from the pinned llama.cpp ref rather than current `master`.
- **Production Q5 (.19):** local `GGML_NATIVE=ON` build, `ghcr.io/noxgle/llama-server:b10665`; `CTX=122880`, `CACHE_RAM=3072`, `CTX_CHECKPOINTS=8`, `REASONING_BUDGET=8192`, `SPEC_DRAFT_N_MAX=1`.
- **Q5 result:** knowledge suite 10/10, **29.0 tok/s** average, 84–96% draft acceptance. Runtime uses ~5.3 GiB VRAM and 24–27 GiB RAM on the 6 GB A2000 / 31 GiB LXC.
- **Scope limit:** b10665 remains unsuitable for Gemma 4 E2B vision: 97.8 tok/s vs b10068 control 114.3 tok/s (−14.4%). Keep b10068 available as the vision rollback image.
- **New warnings:** b10665 deprecates `--mlock` and `--no-mmap` in favor of `--load-mode`; existing flags remain functional.

### New flags added (2026-06-28)
- `--cache-ram 4096` — prompt cache in system RAM (4 GiB). Works with all configs.
- `--cache-reuse 256` — KV cache reuse window. **Ineffective for MTP/SWA contexts** (Qwen3.6, Gemma4) — logs `not supported by this context` / `forcing full prompt re-processing`. Flag is harmless, just ignored.
- `--chat-template-kwargs {"preserve_thinking": false}` — Qwen internal reasoning tokens hidden in API.
- `--threads-http 2` — HTTP server threads.

### llama.cpp b10213 status (tested 2026-08-01, then reverted)
b10213 was fully tested on dev .38 (local `GGML_NATIVE=ON` build) and then **reverted to b10068** — text workloads showed no regression (+0.6% knowledge: 33.8 tok/s, guarded short 33.8 / long 32.8, MTP sweep ordering unchanged, batch 85.8K prefill 507 t/s), **BUT Gemma 4 E2B vision regressed: −10% gen speed (102.9 vs 114.3 tok/s) and +28% TTFT (213 vs 167 ms)** vs b10068 (07-30 run). Vision is the deciding factor — revert. Re-test after upstream fixes; b10213 image stays cached on .38.

### llama.cpp b10428 status (tested 2026-08-14, then reverted — vision regression persists)
b10428 (master @ `885c5bbe8`, 215 commits after b10213, incl. #26802 CUDA graphs for quantized MoE) was fully tested on dev .38 and then **reverted to b10068**. Results:
- **Text: no regression.** Knowledge avg 33.8 tok/s (10/10 tasks, vs 33.6 baseline), guarded short 33.8–34.5 / long 32.8–33.3, batch 85.8K prefill 504 t/s (vs 507), CUDA graphs active (`graphs reused = N`).
- **MTP sweep: ordering unchanged.** n_max=1 still optimal: n1 32.42 (+4.8% vs off), n2 32.26 (+4.3%), off 30.94, n3 29.01 (−6.2%, same as b10068), n4 27.36 (−11.6%).
- **Vision E2B: FAIL.** Baseline gen **99.8 tok/s vs 114.6 control on b10068 same day/same script (−12.9%)**, TTFT 168 ms vs 167 (FIXED vs b10213's 213 ms, but gen speed still −13%). Threshold gen ≥110 tok/s not met → bump rejected (ADR-002). #26802 did NOT fix the E2B vision path (dense model, not MoE).
- Breaking changes from b10213 confirmed unchanged on b10428: empty argv rejection (entrypoint filter works), slot API `?action=save|restore` + `filename` body (old `/slots/{id}/save` → 404), `--mmproj` as separate flag+path.
- **`-hf repo:commit` failure is NOT a b10428 regression** — identical `common_download_get_hf_plan: no GGUF files found` on b10068 (known unsloth repo re-upload issue, see HF download bug above). Workaround `MODEL_FLAG=-m` + local file/symlink works on both.
- b10428 image stays cached on .38. Re-test after upstream fixes the E2B generation regression.

### b10213 breaking changes (worth knowing for the next bump)
- **Empty argv elements rejected** — `--hf-repo-draft ""`, `--no-mmproj ""` etc. now fail with `error: invalid argument:`. Compose workaround (b10068-compatible): entrypoint filters empty args; draft model via env `LLAMA_ARG_SPEC_DRAFT_MODEL` / `LLAMA_ARG_SPEC_DRAFT_HF_REPO`; mmproj as separate flag+path elements (`--mmproj` + path — the `--mmproj=/path` equals-form is ALSO rejected). See `docker-compose.yml` + commits `6ca93f4`, `45431b8`, `ff31f6b`.
- **Slot save/restore endpoint changed:** `POST /slots/{id}?action=save|restore` (query param), old `/slots/{id}/save` → 404. Filename is relative to `--slot-save-path`. Requires the flag to be set (else 404 `File Not Found`). Wired: `SLOT_SAVE_PATH=/slots` in config → `llama.sh` passes `--slot-save-path`.
- **Slot save/restore is SLOWER than RAM prompt cache** on this setup: restore from 100 MB disk file + reprocess ≈ 5.0–5.3 s prefill vs 1.1 s with `cache_prompt=true` + `--cache-ram 4096`. Feature works but is not beneficial here.

### docker run on Docker 26 — use `--runtime=nvidia`, NOT `--gpus all`
`llama.sh` and `scripts/benchmark-draft-mtp.sh` now use `--runtime=nvidia` (+ `NVIDIA_VISIBLE_DEVICES=all`) — `--gpus all` alone doesn't mount `libcuda.so.1` and triggers the post-reboot CPU-JIT gotcha. `llama.sh` defaults to b10665; to use the vision rollback image: `LLAMA_IMAGE=ghcr.io/noxgle/llama-server:b10068 ./llama.sh start gemma4`.

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
**OK on Docker 26** since 2026-08-01 — uses `--runtime=nvidia` (+ `NVIDIA_VISIBLE_DEVICES=all`), not `--gpus all`. Image override: `LLAMA_IMAGE=ghcr.io/noxgle/llama-server:b10665`. Mounts `/opt/llama/slots → /slots` for slot save/restore; passes `--slot-save-path` when `SLOT_SAVE_PATH` is set in config.
```bash
/opt/llama/llama.sh start qwen       # reads configs/qwen3.6-35ba3b-mtp-unsloth.env
/opt/llama/llama.sh start gemma4     # reads configs/gemma4-26b-q4-k-m-mtp.env
/opt/llama/llama.sh stop             # kills all llama containers
/opt/llama/llama.sh status           # list running
```

### Router mode (experimental)
`/opt/llama/llama.sh start router` — loads models from `configs/router-preset.ini`. Switch via `POST /models/load {"model": "qwen-q4"}`. VRAM leak between swaps on 6 GB: `docker restart llama-router` sometimes needed.

## Build
- Source: `ggml-org/llama.cpp.git`, pinned by `LLAMA_REF` (default `b10665`).
- `-DGGML_CUDA_NCCL=OFF` — single GPU, no libnccl.so.2 dependency.
- **Image:** `ghcr.io/noxgle/llama-server:b10665` (public, no auth to pull). The locally built .19 image uses `GGML_NATIVE=ON`; GHCR images use `OFF`.
- CI/CD: `.github/workflows/build.yml` — push to `master` or tag `b*` / `stable*`. A stable tag such as `stable-b10665-v1` builds its embedded b-tag. Self-hosted runner via `SELF_HOSTED_RUNNER=self-hosted` repo variable.
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
