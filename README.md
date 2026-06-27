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

This repository is configured for **NVIDIA GPUs with 6 GB VRAM** — currently **RTX A2000** on Proxmox LXC.
All configs, benchmarks, and optimisations assume this GPU class.

- **Runtime:** Debian 13 LXC on Proxmox
- **GPU:** NVIDIA RTX A2000 6GB
- **RAM:** 30 GB
- **CPU:** 6 cores
- **Active project path:** `/opt/llama`

### Current Production Profile

Three production configurations are deployed, each on an RTX A2000 6 GB with 30 GB system RAM:

| Config | Model | File | Gen speed | RAM | VRAM (inference) |
|--------|-------|:----:|:---------:|:---:|:----------------:|
| `qwen3.6-35ba3b-mtp-unsloth.env` | Qwen3.6 Q4\_K\_M | 22.7 GB | **~33 tok/s** | 20/30 GiB | 5.2/6.0 GiB |
| `qwen3.6-35ba3b-mtp-unsloth-q5.env` | Qwen3.6 Q5\_K\_M | 26 GB | **~30 tok/s** | 25/30 GiB | 5.3/6.0 GiB |
| `gemma4-26b-q4-k-m-mtp.env` | Gemma 4 Q4\_K\_M + MTP | ~17 GB | **~27 tok/s** | 15/30 GiB | 5.4/6.0 GiB |

> **Thread count tuning:** All LXC containers are assigned exactly **4 CPUs** (`cat /sys/fs/cgroup/cpuset.cpus.effective`). Every config **must** match this count — `THREADS` and `THREADS_BATCH` set to 4. The previous default of 6 caused ~14–23% throughput loss from context switching overhead. Always verify the actual CPU count on a new target (LXC may not have all host cores).

Two quant variants of Qwen3.6 are available:

- **Q4_K_M (default)** — `configs/qwen3.6-35ba3b-mtp-unsloth.env` — ~33 tok/s (q8_0 KV), 22.7 GB model
- **Q5_K_M (higher quality)** — `configs/qwen3.6-35ba3b-mtp-unsloth-q5.env` — ~30 tok/s (q8_0 KV), 26 GB model

#### Q4_K_M (production default)

Key values:

- `MODEL=unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M`
- `CTX=143360` (140K)
- `NGLAYERS=999`
- `SPEC_TYPE=draft-mtp`
- `SPEC_DRAFT_N_MAX=1`
- `FLASHATTN=on`
- `BATCH=3072`, `UBATCH=1536` (baseline was 512/512; optimized 2026-06-25, see [Batch optimization](#batch-optimization))

Typical steady-state (after full startup stabilization):

- Throughput: **~33 tok/s** (short prompts, q8_0 KV cache), ~25 tok/s (60K+ prompt prefill at 505 t/s), ~23–24 tok/s during sustained generation of 4K+ tokens
- VRAM: ~5.2–5.8 GiB / 6.0 GiB during inference (at 143K context, q8_0 KV cache, BATCH=3072), RAM: ~20/30 GiB

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

- Throughput: **~27 tok/s** (RTX A2000, short prompts)
- VRAM: **~5.4 GiB / 6.0 GiB** (at 128K context, BATCH=512), RAM: ~15/30 GiB
- Draft acceptance rate: **~82%**

### Router mode (experimental)

Dynamically load/unload models via API — no restart needed. Start with `llama.sh start router`,
then switch between Q4 and Q5 with `POST /models/load`. See [Router mode](#router-mode--dynamic-model-switching) below.

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

# Qwen3.6 Q5_K_M (higher quality, ~28 tok/s, 26 GB model file)
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) qwen-q5
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

# Q5_K_M variant (higher quality, 26 GB model, needs ≥35 GB free)
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) qwen-q5

# The script installs Docker + NVIDIA + llama-server and starts on port 8089.
# Minimum disk: 70 GB (80 GB recommended for Qwen3.6 model ~22 GB; ≥35 GB for Q5 variant).
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

# Qwen3.6-35B Q5_K_M (higher quality, ~28.6 tok/s, local file)
cp configs/qwen3.6-35ba3b-mtp-unsloth-q5.env .env

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

# Switch to Qwen3.6 Q5_K_M (higher quality, port 8089)
/opt/llama/llama.sh start qwen-q5

# Switch to Gemma4 (port 8089) — stops previous model first
/opt/llama/llama.sh start gemma4

# Check status
/opt/llama/llama.sh status

# Stop all
/opt/llama/llama.sh stop

# Tail logs
/opt/llama/llama.sh logs qwen-q5
```

The script reads model config from `configs/<model>.env` and passes the same flags as the old compose `command:` section. Image source: `ghcr.io/noxgle/llama-server:latest` (or override with `LLAMA_IMAGE`).

Systemd (optional):
```bash
cp deploy/systemd/llama@.service /etc/systemd/system/
systemctl enable --now llama@qwen   # auto-start on boot
```

> **Important:** `nvidia-persistenced.service` is a **separate system service** (not part of `llama.sh`).
> It must be enabled once to prevent degraded GPU throughput after reboot:
> ```bash
> cp deploy/systemd/nvidia-persistenced.service /etc/systemd/system/
> systemctl daemon-reload
> systemctl enable --now nvidia-persistenced.service
> ```
> The `install-llama.sh` script does this automatically. See "Post-Reboot Throughput Incident" in Troubleshooting.

> **Note:** Gemma 4 uses local GGUF symlinks (`MODEL_FLAG=-m`, `DRAFT_FLAG=-md`). Ensure the model blobs exist in the HF cache first. See `AGENTS.md` → "HF download bug" for details.

### Router mode — dynamic model switching

> **Experimental** — tested on b9770 (RTX A2000). Child processes inherit all per-model settings.

Starts a model router that loads/unloads models on demand via API — no restart needed.

```bash
# Start router
/opt/llama/llama.sh start router

# Load Q4 (or send a chat request with "model": "qwen-q4")
curl -X POST http://localhost:8089/models/load \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-q4"}'

# Switch to Q5 when coding — models load in ~50-60s
curl -X POST http://localhost:8089/models/load \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-q5"}'
```

Models are defined in [`configs/router-preset.ini`](configs/router-preset.ini) with per-model settings
(ctx, batch, MTP, GPU layers, etc.). The router spawns child processes for each model and
proxies requests. Least Recently Used (LRU) models are unloaded when memory fills up.
Maximum simultaneous models: 4 (default, adjust with `MODELS_MAX`).

Two Qwen3.6 variants are pre-configured:

| Preset name | Source | Quality | Throughput | VRAM (inference) |
|---|---|---|---|---:|
| `qwen-q4` | `-hf unsloth/...:UD-Q4_K_M` | Good | ~28.4 tok/s | ~5231 MiB |
| `qwen-q5` | `-m /models/qwen-q5-k-m.gguf` | Higher | ~28.2 tok/s | ~5393 MiB |

The Q5 model file (26 GB) must be downloaded first — see `install-llama.sh qwen-q5`.

#### ⚠️ Poznane ograniczenia routera (stan na b9770, RTX A2000 6 GB)

- **VRAM leak przy przełączaniu modeli** — `POST /models/load` nie zwalnia w pełni VRAM
  poprzedniego modelu. Przełączenie Q4↔Q5 na karcie 6 GB wymaga
  `docker restart llama-router` pomiędzy switchami, inaczej nowy model dostaje OOM.
  Potwierdzone w testach 2026-06-25: Q5 zajmuje ~5393 MiB, Q4 ~5231 MiB — łączny
  VRAM obu modeli (~10.5 GB) przekracza fizyczną pamięć karty.
  Patrz [Stale CUDA contexts](#stale-cuda-contexts-vram-leak-after-container-crash-loop).

- **Brak auto-restartu child processów** — gdy `llama-server` dziecka padnie (np. OOM
  przy alokacji MTP context), router loguje błąd (`instance … exited with status 1`)
  ale nie próbuje automatycznie przeładować modelu. W osobnym LXC `--restart unless-stopped`
  + systemd załatwiają to bez konfiguracji.

- **Single point of failure** — restart routera (`docker restart`) restartuje wszystkie
  child processy, nie tylko wybrany model. Przy osobnych kontenerach można restartować
  modele niezależnie.

- **Brak izolacji GPU** — oba modele współdzielą tę samą kartę. W osobnym LXC każdy
  dostaje własne urządzenia CUDA, co zapobiega przypadkowemu wyczerpaniu VRAM przez
  drugi model.

**Rekomendacja:** Router sprawdza się na dev do szybkiego przełączania między wariantami
kwantyzacji (Q4↔Q5) przy okazji benchmarków. W produkcji (6 GB VRAM) zalecane są
**osobne LXC / osobne maszyny** — każdy model ma własny watchdog,
auto-restart i izolację zasobów. Router nabiera sensu na kartach ≥24 GB VRAM (RTX 4090,
A5000), gdzie 2-3 modele mogą wisieć załadowane współbieżnie i przełączanie jest
natychmiastowe.

### Important environment variables

> **CPUMOE performance note:** Setting `CPUMOE=exps=CPU` (current default) routes MoE expert weights through CPU, saving VRAM but reducing throughput. Setting `CPUMOE=` (empty) keeps all experts on GPU and improves throughput by ~2–5 tok/s, but increases VRAM usage. Adjust based on your VRAM headroom: with 160K context at ~4483 MiB (BATCH=512), setting `CPUMOE=` is not recommended due to limited headroom.

| Variable | Description | Qwen3.6 (production) | Qwen3.6 Q5_K_M | Gemma4 (alternative) |
|---|---|---|---|---|
| `MODEL` / `MODEL_FLAG` | Model selector | `MODEL=unsloth/...:UD-Q4_K_M` (HF) | `MODEL_FLAG=-m` + `MODEL=/models/qwen-q5-k-m.gguf` (local) | `MODEL_FLAG=-m` + `MODEL=/models/gemma4-26b-q4-k-m.gguf` (local) |
| `DRAFT_MODEL` / `DRAFT_FLAG` | Draft model | (embedded MTP head) | (embedded MTP head) | `DRAFT_FLAG=-md` + `DRAFT_MODEL=/models/gemma4-26b-q8-mtp.gguf` |
| `CTX` | Context length | `143360` | `143360` | `131072` |
| `N_PREDICT` | Token cap (`-1` = unlimited) | `-1` | `-1` | `-1` |
| `NGLAYERS` | Layers offloaded to GPU | `999` | `999` | `999` |
| `GPU_LAYERS_DRAFT` | Draft model GPU offload | (embedded) | (embedded) | `99` (full draft on GPU) |
| `CPUMOE` | MoE expert placement | (dense model, N/A) | (dense model, N/A) | `exps=CPU` |
| `FLASHATTN` | Flash Attention | `on` | `on` | `on` |
| `BATCH` / `UBATCH` | Batch settings | `3072` / `1536` | `3072` / `1536` | `512` / `512` |
| `THREADS` / `THREADS_BATCH` | CPU thread settings | `4` / `4` | `4` / `4` | `4` / `4` |
| `CTX_CHECKPOINTS` | KV context checkpoint slots per prompt | `4` | `4` | `4` |
| `CACHE_TYPE_K` / `CACHE_TYPE_V` | KV cache quantization | `q8_0` / `q8_0` | `q8_0` / `q8_0` | `q4_0` / `q4_0` |
| `SPEC_TYPE` | Speculative decoding mode | `draft-mtp` | `draft-mtp` | `draft-mtp` |
| `SPEC_DRAFT_N_MAX` | MTP draft tokens per step | `1` | `1` | `2` |

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
ssh root@192.168.200.38 '/opt/llama/llama.sh start qwen-q5'
ssh root@192.168.200.38 '/opt/llama/llama.sh start gemma4'
ssh root@192.168.200.38 '/opt/llama/llama.sh start router'
ssh root@192.168.200.38 '/opt/llama/llama.sh stop'
ssh root@192.168.200.38 '/opt/llama/llama.sh status'

# Restart after config edit (sync.sh push first, then restart)
ssh root@192.168.200.38 '/opt/llama/llama.sh restart qwen-q5'

# Router mode: switch models without restart
ssh root@192.168.200.38 'curl -X POST http://localhost:8089/models/load \
  -H "Content-Type: application/json" \
  -d '\''{"model": "qwen-q5"}'\'
```

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

### Current profile (Qwen3.6 35B-A3B MTP Unsloth, BATCH=3072/UBATCH=1536)

Two quant variants available — Q4\_K\_M (default, ~33 tok/s with q8\_0 KV) and Q5\_K\_M (higher quality, ~30 tok/s, see [Q5 profile](#qwen36-q5_k_m-profile)).

| Context | KV Cache | MTP | Throughput | VRAM |
|---|---|---|---|---|
| 143K | q8\_0 | N\_MAX=1 | ~29.7 tok/s | ~5705 MiB |
| **150K** | **q8\_0** | **N\_MAX=1** | **~33.1 tok/s** ⭐ | **~5751 MiB** |
| 160K | q4\_0 | N\_MAX=1 | ~29.1 tok/s | ~4473 MiB |
| 160K | q4\_0 | N\_MAX=2 | ~27.5 tok/s | ~4473 MiB |

MTP acceptance rate is typically ~76–91% depending on KV cache precision (measured: 91% at 150K with q8\_0 KV cache; 80% at 160K with q4\_0 KV; 82% at 160K Q5).
Upstream improvements (PR #23287) enable `backend_sampling=1` — MTP draft sampling offloaded to CUDA backend, reducing host synchronisation overhead.
Throughput degrades to ~14–15 tok/s during sustained generation of 4K+ tokens per slot (KV cache pressure). Recovers to ~23 tok/s after slot release.
⭐ Q4\_K\_M with q8\_0/q8\_0 KV cache is the new performance leader (2026-06-26 benchmark).
‡ GPU upgraded from GTX 1060 6GB (Pascal) to RTX A2000 6GB (Ampere, Tensor Cores). Prefill speed improved from ~130 to ~505 tok/s (~3.9×). Throughput improved from ~24.1 to ~33.1 tok/s with q8\_0 KV optimization.
§ BATCH=3072/UBATCH=1536 optimized 2026-06-25: prefill +88% (269→505 t/s), total time −35% (294→192s) for ~60K prompts. See [Batch optimization](#batch-optimization).

### Qwen3.6 Q5_K_M profile

| Config | MTP | KV Cache | Context | Throughput | Prefill | VRAM (idle) | VRAM (inference) | Notes |
|---|---|---|---|---:|---:|---:|---:|---|
| `qwen3.6-35ba3b-mtp-unsloth-q5.env` | `draft-mtp` N_MAX=1 | q8\_0 | 143K | **~30 tok/s** (short 500 tk) · 25.0 tok/s (60K prompt sustained) | 463 t/s (60K prompt) | ~5705 MiB | ~5795 MiB | −9% vs Q4 q8\_0 |
| `qwen3.6-35ba3b-mtp-unsloth-q5.env` | `draft-mtp` N_MAX=1 | q4\_0 | 160K | ~27.5 tok/s (short 500 tk) | — | ~5399 MiB | ~5471 MiB | Legacy |

Q5\_K\_M provides marginally higher quality than Q4\_K\_M at the cost of ~10% lower throughput
and ~908 MiB more VRAM usage. Best suited when quality is prioritised over speed and
headroom is adequate (93–94% VRAM usage during inference). MTP draft acceptance rate:
~91% (q8\_0 KV, measured: 91.0%) / ~82% (q4\_0 KV). The model file is 26 GB (vs 22.7 GB for Q4\_K\_M).

Benchmarked on standalone server (192.168.200.38, RTX A2000 6 GB, BATCH=3072/UBATCH=1536, THREADS=4).

### Gemma 4 26B profile

| Config | MTP | Context | Throughput | VRAM | RAM | Notes |
|---|---|---|---:|---:|---|---|
| `gemma4-26b-q4-k-m-mtp.env` | `draft-mtp` N_MAX=2 | 128K | **~27.3 tok/s** | ~5415 MiB | ~15 GiB | 🏆 Recommended |
| `gemma4-26b-q8_0-mtp.env` | `draft-mtp` N_MAX=2 | 16K | ~~**~11.3 tok/s**~~ | ~4000 MiB | ~27 GiB | Deprecated, RAM-tight |

### Historical profiles

| Profile | Throughput | VRAM |
|---|---:|---:|
| Qwen 3.5 2B Q4_K_M (64K) | ~58.4 tok/s | 3971 / 6144 MiB |
| Qwen 3.5 4B Q5_K_M (64K tuned) | ~25.9 tok/s | 5507 / 6144 MiB |

### Knowledge benchmark

10 knowledge tasks (data analysis, programming, logic, math, networking, creative writing, code review, SQL, ELI5, algorithms) tested with unlimited tokens and 300s timeout.

| Model | KV Cache | Speed | Draft% | Tokens | Time | Grade |
|-------|----------|:----:|:------:|:------:|:----:|:-----:|
| **Gemma 4 26B Q4_K_M+MTP** | q4\_0 | 27.3 tok/s | 89.6% | 14,574 | 9.7 min | **A** |
| **Qwen3.6 35B Q4\_K\_M+MTP** | q4\_0 | 29.1 tok/s | 83.1% | 30,973 | 18.0 min | **A** |
| **Qwen3.6 35B Q5\_K\_M+MTP** | q4\_0 | 27.5 tok/s | 82.0% | 33,080 | 20.5 min | **A** |
| **Qwen3.6 35B Q5\_K\_M+MTP** | q8\_0 | 29.7 tok/s | 91.0% | 26,193 | 15.3 min | **A** |
| **Qwen3.6 35B Q4\_K\_M+MTP** | **q8\_0** | **33.1 tok/s** | **91.3%** | 22,181 | **13.6 min** | **A** |

All models scored A in all 10 tasks. Gemma4 is the most concise (14,574 tokens — 2× fewer than Q4). Q4\_K\_M with q8\_0/q8\_0 KV cache is the fastest config (33.1 tok/s, 13.6 min total). Q5\_K\_M is the most verbose (33,080 tokens).
Full details: [`scripts/benchmark-knowledge-compare.md`](scripts/benchmark-knowledge-compare.md).

### Batch optimization

Large-prompt benchmark (~60K tokens Qwen tokenized) tested 8 BATCH/UBATCH combinations on RTX A2000 6 GB with Qwen3.6 35B A3B MTP. Each config tested after clean server restart with a unique prompt to avoid KV cache contamination.

| BATCH | UBATCH | Prefill | Gen | Total | VRAM | Gain |
|-------|--------|:-:|:-:|:-:|:-:|:-:|
| 512 | 512 | 269 t/s | 25.1 t/s | 294s | 4527 MiB | baseline |
| 1024 | 256 | 164 t/s | 25.5 t/s | 445s | 4403 MiB | −39% |
| 1536 | 512 | 269 t/s | 26.2 t/s | 294s | 4527 MiB | 0% |
| 2048 | 1024 | 416 t/s | 25.0 t/s | 210s | 4911 MiB | −29% |
| 2560 | 1280 | 462 t/s | 24.9 t/s | 200s | 5111 MiB | −32% |
| **3072** | **1536** | **505 t/s** | **25.5 t/s** | **192s** | **5311 MiB** | **−35% ★** |
| 4096 | 2048 | 569 t/s | 25.8 t/s | 181s | 5717 MiB | −38% |
| 5120 | 2560 | — | — | OOM | OOM | — |

**Key findings:**
- **UBATCH must be close to BATCH.** Config 1024/UBATCH=256 was 39% _slower_ than baseline (164 vs 269 t/s prefill) despite larger BATCH — the micro-batch overhead outweighs any gain.
- **Prefill scales linearly with BATCH** up to ~4096 on RTX A2000 (269 → 569 t/s, +112%). Each doubling of BATCH roughly doubles prefill throughput.
- **Chosen config: 3072/1536** — best balance of speed (+88% prefill, −35% total time) vs VRAM headroom (5311/6138 MiB ≈ 86%).
- **Danger zone:** 4096/2048 works (93% VRAM, fastest), but 5120/2560 causes OOM during MTP draft context allocation.
- **Generation speed is unaffected** by batch size (~25 t/s across all configs) — it's dominated by memory bandwidth on the A2000 for the 22 GB model.

Benchmark script: [`scripts/benchmark-batch.sh`](scripts/benchmark-batch.sh) (generates ~60K-token prompt, measures prefill/gen speed and VRAM; set `N_RUNS=1` for single probe, requires clean server restart between configs).

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

The `llama.sh` script uses `ghcr.io/noxgle/llama-server:latest` by default.

> **Note:** The image is public — no authentication required for pull.

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

After host/LXC reboot, the container was healthy and GPU was visible (`nvidia-smi`),
but throughput dropped to ~1.5–2 tok/s instead of the expected 32–34 tok/s.
A `docker restart llama-qwen` (or `systemctl restart llama@qwen`) immediately
restored full throughput.

#### Root cause

The NVIDIA GPU driver state was not initialized after boot. When the first Docker
container loaded the model, it created CUDA contexts with the driver in a "cold"
state. These contexts ran in degraded mode (~1.5 tok/s). A container restart
created a second set of CUDA contexts with the driver fully warmed, restoring
full throughput (~32 tok/s).

Specifically, the `nvidia-persistenced.service` (NVIDIA Persistence Daemon) was
**not enabled** on the system. Without it, the GPU device files are not held open
after boot, and the driver unloads GPU state between reboots. The daemon opens
the device files at boot and keeps them open, ensuring the driver state persists.

Note: legacy `nvidia-smi -pm 1` (kernel-level persistence mode) is **not sufficient**
— the user-space daemon is required for reliable state retention. See
[NVIDIA docs](https://docs.nvidia.com/deploy/driver-persistence/persistence-daemon.html).

#### Resolution

Enable `nvidia-persistenced.service` at boot:

```bash
# If the service file exists from NVIDIA driver package:
systemctl enable --now nvidia-persistenced.service

# If missing (e.g., LXC with manual driver install), deploy from repo:
cp /opt/llama/deploy/systemd/nvidia-persistenced.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now nvidia-persistenced.service
```

The `install-llama.sh` script handles this automatically for fresh installs.
Existing installs should add the service manually as shown above.

`llama@.service` depends on `nvidia-persistenced.service` via `Requires=` and
`After=`, so the daemon starts before the model container.

Additionally, `gpu-ready.service` acts as a safety net — it polls `nvidia-smi -L`
with a 30-second timeout to confirm the GPU is accessible before `llama@` starts.

#### Verified result

After reboot with `nvidia-persistenced.service` enabled, first inference request
produces full throughput immediately:

```
tok/s: 32.7
GPU clocks: 1200 MHz / 5701 MHz
draft accept: 47/52 (90%)
```

No container restart or corrective action needed after boot.

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
