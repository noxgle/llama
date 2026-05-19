# Llama.cpp Server with Docker

Docker Compose setup for llama.cpp with CUDA + MTP speculative decoding, optimized for running LLM models on GPU.

## Hardware

- **VM:** Debian 13 (trixie) LXC on Proxmox
- **GPU:** NVIDIA GTX 1060 6GB
- **RAM:** 24GB
- **CPU:** 6 cores
- **Server:** `root@192.168.200.38:/opt/llama`

## Quick Start

```bash
# Build and start
docker compose up -d --build

# Check status
curl http://192.168.200.38:8089/health

# View logs
docker compose logs -f
```

## Configuration

### Using .env files

**Note:** `.env` is gitignored and never synced to the server by `sync.sh`. To switch configs, you must copy the config on the server directly.

```bash
# Current production: Qwen3.6 35B-A3B with MTP (CTX=128K)
cp configs/qwen3.6-35ba3b-mtp.env .env
docker compose up -d

# Or use --env-file directly (works locally)
docker compose --env-file configs/qwen3.6-35ba3b-mtp.env up -d
```

To switch the running server config:

```bash
ssh root@192.168.200.38
cp /opt/llama/configs/<name>.env /opt/llama/.env
docker compose down && docker compose up -d
```

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `MODEL` | HuggingFace repo:quant or local path | `localweights/Qwen3.6-35B-A3B-MTP-Q4_K_M-GGUF` |
| `PORT` | Server port | `8089` |
| `HOST` | Listen address | `0.0.0.0` |
| `CTX` | Context size | `131072` |
| `N_PREDICT` | Max tokens (-1 = unlimited) | `-1` |
| `NGLAYERS` | GPU layers (999=all, 0=CPU) | `999` |
| `CPUMOE` | MoE experts on CPU | `exps=CPU` or empty |
| `FLASHATTN` | Flash Attention | `on`, `off`, `auto` |
| `BATCH` | Batch size | `1024` |
| `UBATCH` | Physical batch | `1024` |
| `THREADS` | CPU threads | `6` |
| `THREADS_BATCH` | Batch CPU threads | `6` |
| `CACHE_TYPE_K` | KV cache key quantization | `q4_0` |
| `CACHE_TYPE_V` | KV cache value quantization | `q4_0` |
| `SPEC_TYPE` | Speculative decoding type | `draft-mtp` or `none` |
| `SPEC_DRAFT_N_MAX` | Max MTP draft tokens | `1` |

### Parameters Explained

| Parameter | Description |
|-----------|-------------|
| `-hf` | Load model from HuggingFace |
| `--jinja` | Enable Jinja chat template |
| `-c` | Context size (tokens) |
| `-ngl` | Layers offloaded to GPU |
| `-ot exps=CPU` | Keep MoE experts in CPU (saves VRAM) |
| `-fa` | Flash Attention |
| `-b` / `-ub` | Batch sizes |
| `-t` / `--threads-batch` | CPU threads |
| `--mlock` | Lock model in RAM |
| `--fit off` | Disable auto-fit to VRAM |
| `--spec-type` | Speculative decoding mode (`draft-mtp`) |
| `--spec-draft-n-max` | MTP draft tokens per step |

## MTP Speculative Decoding

This server uses upstream MTP (Multi-Token Prediction) speculative decoding from [llama.cpp PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673), using the built-in MTP head in the Qwen3.6-35B-A3B model.

- **Flags:** `--spec-type draft-mtp --spec-draft-n-max 1 --no-mmproj`
- **Acceptance rate:** ~80% with `N_MAX=1`
- **Throughput:** ~21.7 tok/s (Q4_K_M, CTX=128K, GTX 1060 6GB)
- **VRAM:** ~4493/6144 MiB
- **Note:** `--no-mmproj` is required — MTP segfaults on multimodal prompts otherwise.

## Available Configs

### Current production

#### configs/qwen3.6-35ba3b-mtp.env
- Model: `localweights/Qwen3.6-35B-A3B-MTP-Q4_K_M-GGUF`
- Context: 128K (131072)
- GPU layers: 999 (all possible)
- MTP: `draft-mtp`, `SPEC_DRAFT_N_MAX=1`
- VRAM: ~4493 / 6144 MiB, RAM: ~20 / 24 GiB
- Throughput: ~21.7 tok/s
- Notes: **DEFAULT** — stable, MTP speculative decoding active

### Legacy / archived (previously tested)

All Gemma 4 and Qwen 3.5 configs are preserved for reference but no longer active:

| Config | Model | Throughput | VRAM |
|--------|-------|-----------:|-----:|
| `gemma4-e4b-ud-q4-xl.env` | `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL` | ~23.2 tok/s | 5779 / 6144 MiB |
| `gemma4-e2b-ud-q4-xl.env` | `unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL` | ~41-45 tok/s | ~6045 / 6144 MiB |
| `gemma4-26b-unsloth.env` | `unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M` | — | ~5GB VRAM |
| `qwen3.5-4b-instruct-quality.env` | `bartowski/Qwen_Qwen3.5-4B-GGUF:Q5_K_M` | ~25.9 tok/s | 5507 / 6144 MiB |
| `qwen3.5-2b-instruct-speed.env` | `bartowski/Qwen_Qwen3.5-2B-GGUF:Q4_K_M` | ~58.4 tok/s | 3971 / 6144 MiB |

Additional test-only configs live in `configs/archive/`.

## API Endpoints

- **Health:** http://192.168.200.38:8089/health
- **OpenAI API:** http://192.168.200.38:8089/v1/chat/completions

### Example API call

```bash
curl http://192.168.200.38:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello!"}],
    "model": "qwen3.6",
    "max_tokens": 500
  }' | jq '.choices[0].message.content, .usage, .timings.predicted_per_second'
```

### Quick throughput probe

```bash
ssh root@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars.\"}],\"model\":\"qwen3.6\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'
```

## Operational Commands

### Local

```bash
# Build locally
docker compose build

# Start
docker compose up -d

# Stop
docker compose down

# Logs
docker compose logs -f
```

### Remote (manual ssh)

Most `sync.sh` commands target the wrong host/path. Use direct SSH instead:

```bash
# Health
ssh root@192.168.200.38 'curl -s http://localhost:8089/health'

# Restart (after config change)
ssh root@192.168.200.38 'cd /opt/llama && docker compose down && docker compose up -d'

# Rebuild
ssh root@192.168.200.38 'cd /opt/llama && docker compose up -d --build'

# Throughput benchmark with GPU guard
HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh
```

### Sync Tool (`sync.sh`)

`sync.sh` provides file sync but its server target is **wrong** (`ag@...:~/llama` instead of `root@192.168.200.38:/opt/llama`). Useful commands:

```bash
# Push local files to server (configs, scripts, compose)
./sync.sh push

# Pull configs from server
./sync.sh pull

# SSH to server
./sync.sh ssh
```

**Do not use** `deploy`, `rebuild`, `restart`, `start`, `stop` — they target the wrong host.

## Benchmark Results

All benchmarks on GTX 1060 6GB, at default settings unless noted.

### Qwen3.6 35B-A3B MTP (current)

| Config | Model | MTP | Throughput | VRAM |
|--------|-------|-----|-----------:|-----:|
| `qwen3.6-35ba3b-mtp.env` (CTX=16K) | Qwen3.6 35B-A3B Q4_K_M | N_MAX=3 | ~20.1 tok/s | ~4043 MiB |
| `qwen3.6-35ba3b-mtp.env` (CTX=32K) | Qwen3.6 35B-A3B Q4_K_M | N_MAX=1 | ~20.9 tok/s | ~4047 MiB |
| `qwen3.6-35ba3b-mtp.env` (CTX=128K) | Qwen3.6 35B-A3B Q4_K_M | N_MAX=1 | ~21.7 tok/s | ~4493 MiB |

MTP acceptance rate: ~80%. Zero crashes in testing across CTX=16K, 32K, 128K.

### Historical (Gemma 4, Qwen 3.5)

| Profile | Throughput | VRAM |
|---------|-----------:|-----:|
| Gemma 4 E4B UD-Q4_K_XL (CTX=128K) | ~23.2 tok/s | 5779 / 6144 MiB |
| Gemma 4 E2B UD-Q4_K_XL (BATCH=2048) | ~41-45 tok/s | ~6045 / 6144 MiB |
| Qwen 3.5 2B Q4_K_M (CTX=64K) | ~58.4 tok/s | 3971 / 6144 MiB |
| Qwen 3.5 4B Q5_K_M (CTX=64K, tuned) | ~25.9 tok/s | 5507 / 6144 MiB |

## Build Info

- **Source:** `ggml-org/llama.cpp.git` (master branch)
- **CUDA:** 12.4
- **Build flags:** `-DGGML_CUDA_NCCL=OFF` (single-GPU host, avoids `libnccl.so.2` runtime issue)
- **Base image:** `nvidia/cuda:12.4.0-devel-ubuntu22.04`
- **Build arg:** `LLAMA_REF=master` (pins git ref; change in `.env` or `docker-compose.yml`)

## GPU Watchdog

Auto-heals CPU fallback (when GPU initialisation fails):

- Script: `scripts/gpu-watchdog.sh`
- Systemd timer: `deploy/systemd/llama-gpu-watchdog.{service,timer}`
- Detection: 0 MiB VRAM, `ggml_cuda_init: failed` or `no usable GPU found` in logs
- Self-heal: restart container → if still CPU → restart Docker + nvidia-persistenced
- Max 2 attempts, 30 min cooldown
- Logs: `/var/log/llama-gpu-watchdog.log`

Deploy on server as root:

```bash
cp scripts/gpu-watchdog.sh /opt/llama/scripts/
cp deploy/systemd/llama-gpu-watchdog.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now llama-gpu-watchdog.timer
```

## Troubleshooting

### Check GPU usage
```bash
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv
```

### Check container logs
```bash
docker compose logs --tail=50
```

### Rebuild
```bash
docker compose build --no-cache
docker compose up -d
```

### Recovery
- If MTP segfaults: check `/var/log/llama-gpu-watchdog.log`, restart via `docker compose down && docker compose up -d`.
- If VRAM exhausted: reduce `CTX`, switch to smaller model, or reduce `BATCH`/`UBATCH`.
