# Llama.cpp Server with Docker

Docker Compose setup for a remote `llama.cpp` OpenAI-compatible server with CUDA and upstream MTP speculative decoding.

This repository operates on:
- **Proxmox host:** `root@192.168.200.7`
- **LXC runtime node:** `root@192.168.200.38:/opt/llama`

## Table of Contents

- [Hardware and Topology](#hardware-and-topology)
- [Current Production Profile](#current-production-profile)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [API Endpoints](#api-endpoints)
- [Operational Commands](#operational-commands)
- [Post-Reboot Throughput Incident (Resolved)](#post-reboot-throughput-incident-resolved)
- [LXC Configuration (VMID 1004)](#lxc-configuration-vmid-1004)
- [Proxmox Host Configuration](#proxmox-host-configuration)
- [Boot Sequence and Recovery Logic](#boot-sequence-and-recovery-logic)
- [Benchmark Results](#benchmark-results)
- [Build Info](#build-info)
- [GPU Watchdog](#gpu-watchdog)
- [Troubleshooting](#troubleshooting)

## Hardware and Topology

- **Runtime:** Debian 13 LXC on Proxmox
- **GPU:** NVIDIA GTX 1060 6GB
- **RAM:** 24 GB
- **CPU:** 6 cores
- **Active project path:** `/opt/llama`

## Current Production Profile

Canonical production config file:

- `configs/qwen3.6-35ba3b-mtp-unsloth.env`

Key values:

- `MODEL=unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M`
- `CTX=131072` (128K)
- `NGLAYERS=999`
- `SPEC_TYPE=draft-mtp`
- `SPEC_DRAFT_N_MAX=1`
- `FLASHATTN=on`
- `BATCH=1024`, `UBATCH=1024`

Typical steady-state (after full startup stabilization):

- Throughput: ~20–23 tok/s
- VRAM: ~4.4–5.2 GiB / 6.0 GiB

## Quick Start

```bash
# Build and start locally
docker compose up -d --build

# Check health
curl http://192.168.200.38:8089/health

# Tail logs
docker compose logs -f
```

## Configuration

### Local `.env` switch

```bash
cp configs/qwen3.6-35ba3b-mtp-unsloth.env .env
docker compose up -d
```

### Server-side `.env` switch (authoritative)

> `.env` is gitignored and excluded by `sync.sh push`, so active runtime must be switched directly on the server.

```bash
ssh root@192.168.200.38
cp /opt/llama/configs/qwen3.6-35ba3b-mtp-unsloth.env /opt/llama/.env
docker compose down && docker compose up -d
```

### Important environment variables

| Variable | Description | Production value |
|---|---|---|
| `MODEL` | Hugging Face model selector | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M` |
| `CTX` | Context length | `131072` |
| `N_PREDICT` | Token cap (`-1` = unlimited) | `-1` |
| `NGLAYERS` | Layers offloaded to GPU | `999` |
| `FLASHATTN` | Flash Attention | `on` |
| `BATCH` / `UBATCH` | Batch settings | `1024` / `1024` |
| `THREADS` / `THREADS_BATCH` | CPU thread settings | `6` / `6` |
| `SPEC_TYPE` | Speculative decoding mode | `draft-mtp` |
| `SPEC_DRAFT_N_MAX` | MTP draft tokens per step | `1` |

## API Endpoints

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

## Operational Commands

### Local

```bash
docker compose build
docker compose up -d
docker compose down
docker compose logs -f
```

### Remote (recommended)

```bash
# Health
ssh root@192.168.200.38 'curl -s http://localhost:8089/health'

# Restart after config change
ssh root@192.168.200.38 'cd /opt/llama && docker compose down && docker compose up -d'

# Rebuild remotely
ssh root@192.168.200.38 'cd /opt/llama && docker compose up -d --build'

# Guarded benchmark (fails fast on GPU fallback)
HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh
```

### `sync.sh` caveat

`sync.sh` still points to the wrong host/path (`ag@...:~/llama`).

- You can still use `push/pull/ssh` carefully.
- Do **not** rely on `deploy/rebuild/restart/start/stop` from `sync.sh` until it is corrected.

## Post-Reboot Throughput Incident (Resolved)

### Symptom

- After host/LXC reboot, service was healthy and GPU was visible, but throughput dropped to ~1.5–2 tok/s.

### Not the root cause

- Not classic CPU fallback (GPU devices and VRAM were present).
- Not a direct CTX root cause.

### Root-cause category

- Startup race / degraded runtime state after boot.
- Manual `systemctl restart llama-compose.service` immediately restored ~22 tok/s.

### Resolution

- Keep host NVIDIA readiness guard active.
- Keep deterministic LXC compose startup service.
- Add delayed post-boot corrective restart service.

### Verified result

- After reboot, throughput returns to ~22–23 tok/s.

## LXC Configuration (VMID 1004)

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

## Proxmox Host Configuration

Host: `192.168.200.7`

### Module auto-load

`/etc/modules-load.d/nvidia.conf`

```text
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
```

### NVIDIA readiness service

- Service: `nvidia-modprobe-ensure.service`
- Purpose: ensure NVIDIA stack is ready before guests and Docker workloads.
- Ordering: before `pve-guests.service`, `pve-container@1004.service`, and Docker.

Quick checks:

```bash
systemctl status nvidia-modprobe-ensure.service
ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
pct status 1004
```

## Boot Sequence and Recovery Logic

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

## Benchmark Results

### Current profile (Qwen3.6 35B-A3B MTP Unsloth)

| Context | MTP | Throughput | VRAM |
|---|---|---:|---:|
| 16K | N_MAX=3 | ~20.1 tok/s | ~4043 MiB |
| 32K | N_MAX=1 | ~20.9 tok/s | ~4047 MiB |
| 128K | N_MAX=1 | ~21.7 tok/s | ~4493 MiB |

MTP acceptance rate is typically ~80%.

### Historical profiles

| Profile | Throughput | VRAM |
|---|---:|---:|
| Gemma 4 E4B UD-Q4_K_XL (128K) | ~23.2 tok/s | 5779 / 6144 MiB |
| Gemma 4 E2B UD-Q4_K_XL (BATCH=2048) | ~41–45 tok/s | ~6045 / 6144 MiB |
| Qwen 3.5 2B Q4_K_M (64K) | ~58.4 tok/s | 3971 / 6144 MiB |
| Qwen 3.5 4B Q5_K_M (64K tuned) | ~25.9 tok/s | 5507 / 6144 MiB |

## Build Info

- Source: `ggml-org/llama.cpp.git`
- Ref: `master` (via `LLAMA_REF`)
- CUDA base image: `nvidia/cuda:12.4.0-devel-ubuntu22.04`
- Build flag: `-DGGML_CUDA_NCCL=OFF`

## GPU Watchdog

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

## Troubleshooting

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
