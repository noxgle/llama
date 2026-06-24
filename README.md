# Llama.cpp Server with Docker

Docker Compose setup for a remote `llama.cpp` OpenAI-compatible server with CUDA and upstream MTP speculative decoding.

This repository operates on:
- **Proxmox host:** `root@192.168.200.7`
- **LXC runtime node:** `root@192.168.200.38:/opt/llama`

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Operations](#operations)
- [Performance](#performance)
- [Build Info](#build-info)
- [Troubleshooting](#troubleshooting)

---

## Overview

### Hardware and Topology

- **Runtime:** Debian 13 LXC on Proxmox
- **GPU:** NVIDIA RTX A2000 6GB
- **RAM:** 30 GB
- **CPU:** 6 cores
- **Active project path:** `/opt/llama`

### Current Production Profile

Canonical production config file:

- `configs/qwen3.6-35ba3b-mtp-unsloth.env`

Key values:

- `MODEL=unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M`
- `CTX=163840` (160K)
- `NGLAYERS=999`
- `SPEC_TYPE=draft-mtp`
- `SPEC_DRAFT_N_MAX=2`
- `FLASHATTN=on`
- `BATCH=512`, `UBATCH=512`

Typical steady-state (after full startup stabilization):

- Throughput: **~30.1 tok/s** (short prompts), ~18–19 tok/s (30K+ prompt prefill), ~14–15 tok/s during sustained generation of 4K+ tokens (KV cache pressure on 6 GB VRAM)
- VRAM: ~4.4–4.8 GiB / 6.0 GiB (at 160K context, BATCH=512, varies with prompt cache accumulation)

### Gemma 4 26B Alternative

Validated config file:

- `configs/gemma4-26b-q4-k-m-mtp.env`

Key values:

- `MODEL_FLAG=-m` + `MODEL=/models/gemma4-26b-q4-k-m.gguf` (local symlink to HF cache, bypasses `get_hf_plan` bug)
- `DRAFT_FLAG=-md` + `DRAFT_MODEL=/models/gemma4-26b-q8-mtp.gguf` (Q8_0-MTP draft head, 462 MB)
- `CTX=131072` (128K)
- `NGLAYERS=999` (full GPU offload of non-expert layers; MoE experts on CPU via `CPUMOE=exps=CPU`)
- `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`
- `GPU_LAYERS_DRAFT=99` (draft model fully on GPU)
- `BATCH=512`, `UBATCH=512`
- `FLASHATTN=on`

Typical steady-state:

- Throughput: **~27.4 tok/s** (RTX 4060 Ti) / **~25.5 tok/s** (RTX A2000) — short prompts
- VRAM: **~5.4 GiB / 6.0 GiB** (at 128K context, BATCH=512), RAM: ~15/30 GiB
- Draft acceptance rate: **~85%**

**Fresh install?** Follow "Post-Install: Gemma4 manual steps" below for draft model
download and symlink setup.

See `AGENTS.md` → "Gemma 4 test results" for benchmark details and the higher-quality but RAM-constrained Q8_K_XL variant (`configs/gemma4-26b-q8_0-mtp.env`).

---

## Architecture

### Proxmox Host Configuration

Host: `192.168.200.7`

#### Module auto-load

`/etc/modules-load.d/nvidia.conf`

```text
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
```

#### NVIDIA readiness service

- Service: `nvidia-modprobe-ensure.service`
- Purpose: ensure NVIDIA stack is ready before guests and Docker workloads.
- Ordering: before `pve-guests.service`, `pve-container@1004.service`, and Docker.

Quick checks:

```bash
systemctl status nvidia-modprobe-ensure.service
ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
pct status 1004
```

### LXC Configuration (VMID 1004)

- VMID: `1004`
- LXC IP: `192.168.200.38`
- Project path: `/opt/llama`
- Autostart:
  - `onboot: 1`
  - `startup: order=5,up=20`

Required GPU passthrough entries (`pct config 1004`):

```text
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 510:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir
```

### Boot Sequence and Recovery Logic

Expected order:

1. Proxmox host boots and runs `nvidia-modprobe-ensure.service`
2. LXC `1004` autostarts
3. `llama-compose.service` starts stack in LXC
4. `llama-postboot-restart.service` performs delayed corrective restart

Post-reboot validation:

```bash
# In LXC
docker ps
curl -s http://localhost:8089/health
curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Write a short sentence."}],"model":"qwen3.6","max_tokens":120}' \
  | jq '.timings.predicted_per_second'
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
```

---

## Quick Install (fresh LXC / bare metal)

Provision a Debian 12+ / Ubuntu 22.04+ machine with Docker, GPU support, and a
llama.cpp server — single command, no manual steps:

```bash
# Qwen3.6 (production, ~30 tok/s, 160K context)
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) qwen

# Gemma4 26B (alternative, ~27 tok/s, 128K context)
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) gemma4
```

The script installs Docker + nvidia-container-toolkit, pulls the server image
from GHCR, pre-caches model weights, and configures systemd autostart.
After reboot the model starts automatically on port **8089**.

**Prerequisites:**
- Debian 12+ or Ubuntu 22.04+ (fresh install)
- Root access
- NVIDIA GPU with drivers installed
- For Proxmox LXC: GPU passthrough must be configured on the host
  (script aborts with instructions if `/dev/nvidia*` is missing)

> **⚠️ Symlinks must point to container paths** — When creating GGUF symlinks in
> `/opt/llama/models/` for Gemma4 or other local models, the target must be an
> absolute path that exists **inside** the Docker container
> (e.g., `/root/.cache/huggingface/hub/...`), not on the host
> (e.g., `/var/lib/docker/volumes/...`). A symlink with a host path will silently
> fail with `No such file or directory` inside the container. See
> "Post-Install: Gemma4 manual steps" below for the correct approach.

### Post-Install: Gemma4 manual steps

The `install-llama.sh gemma4` script pre-caches the main model (UD-Q4_K_M) and
starts the server, but two manual steps are required before the model loads
successfully:

#### 1. Download the draft model (Q8_0-MTP head)

The `get_hf_plan` bug prevents downloading files from subdirectories like `MTP/`.
Download the draft model directly via curl:

```bash
curl -L -o /opt/llama/models/gemma4-26b-q8-mtp.gguf \
  https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/MTP/gemma-4-26B-A4B-it-Q8_0-MTP.gguf
```

#### 2. Create symlinks (container paths only!)

The main model blob is in the `llama_hf-cache` Docker volume. Create a symlink
that points to a path **inside the container**, not on the host:

```bash
# Find the correct blob in the HF cache Docker volume
MAIN_HASH=$(find /var/lib/docker/volumes/llama_hf-cache/_data/hub/ \
  -name "*UD-Q4_K_M*" -type f -exec basename {} \; | head -1)

# Create symlink — target is the container-side path!
ln -sf \
  "/root/.cache/huggingface/hub/models--unsloth--gemma-4-26B-A4B-it-GGUF/blobs/$MAIN_HASH" \
  /opt/llama/models/gemma4-26b-q4-k-m.gguf
```

Verify the symlink works from inside the container:
```bash
docker run --rm \
  -v /opt/llama/models:/models \
  -v llama_hf-cache:/root/.cache/huggingface \
  --entrypoint bash \
  ghcr.io/noxgle/llama-server:latest \
  -c "head -c 4 /models/gemma4-26b-q4-k-m.gguf | od -A x -t x1z"
# Expected output: 000000 47 47 55 46  >GGUF<
```

#### 3. Restart the server

```bash
/opt/llama/llama.sh restart gemma4
```

The server should load the model in ~50–60s (verify with `curl http://localhost:8089/health`).

---

## Quick Start

### New machine provisioning (from scratch)

```bash
# Debian 12+ or Ubuntu 22.04+ with root access and GPU passthrough
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) qwen

# The script installs Docker + NVIDIA + llama-server and starts on port 8089.
# Minimum disk: 70 GB (80 GB recommended for Qwen3.6 model ~22 GB).
```

### Check existing server

```bash
# Health endpoint
curl http://192.168.200.38:8089/health

# GPU status
ssh root@192.168.200.38 'nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader'

# Quick throughput probe
ssh root@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars.\"}],\"model\":\"qwen3.6\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'
```

---

## Configuration

### Local `.env` switch

```bash
# Qwen3.6-35B (production, ~30.1 tok/s, 160K)
cp configs/qwen3.6-35ba3b-mtp-unsloth.env .env

# Gemma 4 26B A4B (alternative, ~27.4 tok/s, 128K)
cp configs/gemma4-26b-q4-k-m-mtp.env .env

docker compose up -d
```

### Server-side: `llama.sh` control script (recommended)

> Replaces old compose-based `.env` switching. Uses `docker run` directly.

```bash
ssh root@192.168.200.38
# Start Qwen3.6 (production, port 8089)
/opt/llama/llama.sh start qwen

# Switch to Gemma4 (port 8089) — stops Qwen first
/opt/llama/llama.sh start gemma4

# Check status
/opt/llama/llama.sh status

# Stop all
/opt/llama/llama.sh stop

# Tail logs
/opt/llama/llama.sh logs qwen
```

The script reads model config from `configs/<model>.env` and passes the same flags as the old compose `command:` section. Image source: `ghcr.io/noxgle/llama-server:latest` (or override with `LLAMA_IMAGE`).

Systemd (optional):
```bash
cp deploy/systemd/llama@.service /etc/systemd/system/
systemctl enable --now llama@qwen   # auto-start on boot
```

> **Note:** Gemma 4 uses local GGUF symlinks (`MODEL_FLAG=-m`, `DRAFT_FLAG=-md`). Ensure the model blobs exist in the HF cache first. See `AGENTS.md` → "HF download bug" for details.

### Important environment variables

> **CPUMOE performance note:** Setting `CPUMOE=exps=CPU` (current default) routes MoE expert weights through CPU, saving VRAM but reducing throughput. Setting `CPUMOE=` (empty) keeps all experts on GPU and improves throughput by ~2–5 tok/s, but increases VRAM usage. Adjust based on your VRAM headroom: with 160K context at ~4483 MiB (BATCH=512), setting `CPUMOE=` is not recommended due to limited headroom.

| Variable | Description | Qwen3.6 (production) | Gemma4 (alternative) |
|---|---|---|---|
| `MODEL` / `MODEL_FLAG` | Model selector | `MODEL=unsloth/...:UD-Q4_K_M` (HF) | `MODEL_FLAG=-m` + `MODEL=/models/gemma4-26b-q4-k-m.gguf` (local) |
| `DRAFT_MODEL` / `DRAFT_FLAG` | Draft model | (embedded MTP head) | `DRAFT_FLAG=-md` + `DRAFT_MODEL=/models/gemma4-26b-q8-mtp.gguf` |
| `CTX` | Context length | `163840` | `131072` |
| `N_PREDICT` | Token cap (`-1` = unlimited) | `-1` | `-1` |
| `NGLAYERS` | Layers offloaded to GPU | `999` | `999` |
| `GPU_LAYERS_DRAFT` | Draft model GPU offload | (embedded) | `99` (full draft on GPU) |
| `CPUMOE` | MoE expert placement | (dense model, N/A) | `exps=CPU` |
| `FLASHATTN` | Flash Attention | `on` | `on` |
| `BATCH` / `UBATCH` | Batch settings | `512` / `512` | `512` / `512` |
| `THREADS` / `THREADS_BATCH` | CPU thread settings | `6` / `6` | `6` / `6` |
| `CTX_CHECKPOINTS` | KV context checkpoint slots per prompt | `4` | `4` |
| `SPEC_TYPE` | Speculative decoding mode | `draft-mtp` | `draft-mtp` |
| `SPEC_DRAFT_N_MAX` | MTP draft tokens per step | `2` | `2` |

---

## Operations

### Docker Commands

#### Local

```bash
docker compose build
docker compose up -d
docker compose down
docker compose logs -f
```

#### Remote (recommended)

```bash
# Health
ssh root@192.168.200.38 'curl -s http://localhost:8089/health'

# Start/stop models (llama.sh wrapper)
ssh root@192.168.200.38 '/opt/llama/llama.sh start qwen'
ssh root@192.168.200.38 '/opt/llama/llama.sh start gemma4'
ssh root@192.168.200.38 '/opt/llama/llama.sh stop'
ssh root@192.168.200.38 '/opt/llama/llama.sh status'

# Restart after config edit (sync.sh push first, then restart)
ssh root@192.168.200.38 '/opt/llama/llama.sh restart qwen'

# Guarded benchmark (fails fast on GPU fallback)
HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh
```

### `sync.sh` usage

`sync.sh` targets `root@192.168.200.38:/opt/llama` (already corrected).

- `push` — sync local repo → server (excludes `.env`, `.git/`, `*.log`, `build/`)
- `pull` — pull configs back from server
- `status` — show container + GPU status
- `health` — check health endpoint + VRAM + RAM

> **Note:** `deploy` and `rebuild` use `docker compose restart/build` — for config changes requiring `.env` reload, use `stop` + `start` manually on the server instead.

### API Endpoints

- **Health:** `http://192.168.200.38:8089/health`
- **Chat completions:** `http://192.168.200.38:8089/v1/chat/completions`

Example:

```bash
curl http://192.168.200.38:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello!"}],
    "model": "qwen3.6",
    "max_tokens": 200
  }' | jq '.choices[0].message.content, .timings.predicted_per_second'
```

### GPU Watchdog

Detects CPU fallback and applies self-heal logic.

- Script: `scripts/gpu-watchdog.sh`
- Systemd units: `deploy/systemd/llama-gpu-watchdog.{service,timer}`
- Logs: `/var/log/llama-gpu-watchdog.log`

Deploy:

```bash
cp scripts/gpu-watchdog.sh /opt/llama/scripts/
cp deploy/systemd/llama-gpu-watchdog.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now llama-gpu-watchdog.timer
```

---

## Performance

### Current profile (Qwen3.6 35B-A3B MTP Unsloth)

| Context | MTP | Throughput | VRAM |
|---|---:|---:|---:|
| 16K | N_MAX=3 | ~20.1 tok/s | ~4043 MiB |
| 32K | N_MAX=1 | ~20.9 tok/s | ~4047 MiB |
| 128K | N_MAX=1 | ~21.7 tok/s | ~4493 MiB |
| **160K** | **N_MAX=2** | **~30.1 tok/s** | **~4473 MiB** |
| 176K\* | N_MAX=2 | ~23.1 tok/s | ~5555 MiB |
| 192K† | N_MAX=2 | ~22.4 tok/s | ~5650 MiB |

MTP acceptance rate is typically ~76–80% (measured: 679/844 = 80% at 30K context; 380/500 = 76% at short context 17.06.2026).
Upstream improvements (PR #23287) enable `backend_sampling=1` — MTP draft sampling offloaded to CUDA backend, reducing host synchronisation overhead.
Throughput degrades to ~14–15 tok/s during sustained generation of 4K+ tokens per slot (KV cache pressure). Recovers to ~23 tok/s after slot release.
\* 176K deprecated — reduced to 160K due to MTP CUDA OOM on 6 GB.
† 192K deprecated — reduced due to VRAM pressure.
‡ GPU upgraded from GTX 1060 6GB (Pascal) to RTX A2000 6GB (Ampere, Tensor Cores). Prefill speed improved from ~130 to ~442 tok/s (~3.4×). Throughput improved from ~24.1 to ~30.1 tok/s.

### Gemma 4 26B profile

| Config | MTP | Context | Throughput | VRAM | RAM | Notes |
|---|---|---|---:|---:|---:|---|
| `gemma4-26b-q4-k-m-mtp.env` | `draft-mtp` N_MAX=2 | 128K | **~27.4 tok/s** | ~5415 MiB | ~15 GiB | 🏆 Recommended |
| `gemma4-26b-q8_0-mtp.env` | `draft-mtp` N_MAX=2 | 16K | **~11.3 tok/s** | ~4000 MiB | ~27 GiB | Near-lossless, RAM-tight |

### Historical profiles

| Profile | Throughput | VRAM |
|---|---:|---:|
| Qwen 3.5 2B Q4_K_M (64K) | ~58.4 tok/s | 3971 / 6144 MiB |
| Qwen 3.5 4B Q5_K_M (64K tuned) | ~25.9 tok/s | 5507 / 6144 MiB |

---

## Build Info

- Source: `ggml-org/llama.cpp.git`
- Ref: `LLAMA_REF=b9770` (commit `75ad0b2`, 2026-06-23)
- Previous commit: `8086439` (2026-06-17, replaced with b9770)
- CUDA base image: `nvidia/cuda:12.4.0-devel-ubuntu22.04`
- Build flag: `-DGGML_CUDA_NCCL=OFF`
- **b9770 key PRs:** flash mtp3 (#24340), CUDA PDL MoE (#24087), Step3.5 MTP fix (#24060), MTP verify batch (#21845)
- **A/B benchmark vs 8086439:** Qwen3.6 +3% (29.2→30.1), Gemma4 +7.5% (25.5→27.4)

---

## CI/CD (GitHub Container Registry)

Build workflow: `.github/workflows/build.yml`

| Trigger | Tags pushed |
|---|---|
| Push to `master` | `ghcr.io/noxgle/llama-server:latest`, `:sha-<commit>` |
| Tag `b*` | `ghcr.io/noxgle/llama-server:<tag>` |

**First-time setup:**
1. On the server, authenticate Docker with GHCR:
   ```bash
   echo <GITHUB_TOKEN> | docker login ghcr.io -u <user> --password-stdin
   ```
2. The `llama.sh` script uses `ghcr.io/noxgle/llama-server:latest` by default.

**Self-hosted runner (recommended):**
Build on Proxmox (6-core, ~60-90 min) → push to GHCR → pull on target LXCs.
Install runner:
```bash
# On Proxmox host, as root:
mkdir /opt/actions-runner && cd /opt/actions-runner
curl -O -L https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64-2.322.0.tar.gz
tar xzf actions-runner-linux-x64-*.tar.gz
./config.sh --url https://github.com/noxgle/llama --token <TOKEN>
./run.sh
```
Set repository variable `SELF_HOSTED_RUNNER=self-hosted` to use it.
Without this variable, the workflow falls back to `ubuntu-latest` (no GPU, slower build).

---

## Troubleshooting

### Post-Reboot Throughput Incident (Resolved)

#### Symptom

- After host/LXC reboot, service was healthy and GPU was visible, but throughput dropped to ~1.5–2 tok/s.

#### Not the root cause

- Not classic CPU fallback (GPU devices and VRAM were present).
- Not a direct CTX root cause.

#### Root-cause category

- Startup race / degraded runtime state after boot.
- Manual `systemctl restart llama-compose.service` immediately restored ~22 tok/s.

#### Resolution

- Keep host NVIDIA readiness guard active.
- Keep deterministic LXC compose startup service.
- Add delayed post-boot corrective restart service.

#### Verified result

- After reboot, throughput returns to ~22–23 tok/s.

### Check GPU

```bash
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv
```

### Check logs

```bash
docker compose logs --tail=80
```

### Rebuild

```bash
docker compose build --no-cache
docker compose up -d
```

### Recovery

- If MTP segfaults: check watchdog logs and restart stack (`down && up -d`).
- If VRAM is saturated: reduce `CTX` or batch settings.

### Stale CUDA contexts (VRAM leak after container crash-loop)

After a crash-looping container (e.g., model load failures with `--restart unless-stopped`),
`nvidia-smi` may report high VRAM usage but show **"No running processes found"**.
This happens because stale `llama-server` processes holding CUDA contexts survive
container restart; Docker does not always clean them up.

**Symptoms:**
- `nvidia-smi` shows `Used: 4765 MiB` but no listed processes
- GPU is unreachable by new containers until the VRAM is freed
- `docker logs` shows `cudaMalloc failed: out of memory`

**Fix:**
```bash
# Find stale processes holding GPU devices
fuser -v /dev/nvidia*
# Kill every llama-server process found
kill -9 <PID>
# Verify VRAM is freed
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
```

**Prevention:** Avoid repeated `docker stop` + `docker rm` on crash-looping
containers; use `docker compose down` or `systemctl stop` to ensure clean
teardown. The `llama.sh` wrapper handles this automatically.

### Empty response from Qwen models

Qwen uses internal reasoning tokens (`reasoning_content`) before generating the visible response. If `max_tokens` is set too low, all tokens are consumed by reasoning and `content` comes back empty.

**Fix:** Use `max_tokens >= 1024`, or set `"reasoning": false` in the request if the model supports it. For interactive use, streaming (`stream: true`) reveals content incrementally even when reasoning is active.
