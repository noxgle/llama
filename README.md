# Llama.cpp Server with Docker

Docker Compose setup for llama.cpp with CUDA support, optimized for running LLM models on GPU.

## Hardware

- **VM:** Debian 13 (trixie)
- **GPU:** NVIDIA GTX 1060 6GB
- **RAM:** 12GB
- **CPU:** 6 cores

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

```bash
# Use Gemma 4 E4B (DEFAULT)
cp configs/gemma4-e4b-ud-q4-xl.env .env
docker compose up -d

# Use Gemma 4 E2B (faster, lower VRAM)
cp configs/gemma4-e2b-ud-q4-xl.env .env
docker compose up -d

# Or use --env-file directly
docker compose --env-file configs/gemma4-e4b-ud-q4-xl.env up -d
```

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `MODEL` | HuggingFace repo:quant | `ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M` |
| `PORT` | Server port | `8089` |
| `HOST` | Listen address | `0.0.0.0` |
| `CTX` | Context size | `32768` |
| `NGLAYERS` | GPU layers (999=all, 0=CPU) | `50` |
| `CPUMOE` | MoE experts on CPU | `exps=CPU` or empty |
| `FLASHATTN` | Flash Attention | `on`, `off`, `auto` |
| `BATCH` | Batch size | `256` |
| `UBATCH` | Physical batch | `256` |
| `THREADS` | CPU threads | `6` |

## Parameters Explained

| Parameter | Description |
|-----------|-------------|
| `-hf` | Load model from HuggingFace |
| `--jinja` | Enable Jinja chat template (required for Gemma) |
| `-c` | Context size (tokens) |
| `-ngl` | Layers offloaded to GPU |
| `-ot exps=CPU` | Keep MoE experts in CPU (saves VRAM) |
| `-fa` | Flash Attention |
| `-b` / `-ub` | Batch sizes |
| `-t` | CPU threads |
| `--mlock` | Lock model in RAM |
| `--fit off` | Disable auto-fit to VRAM |

## Available Configs

### configs/gemma4-e4b-ud-q4-xl.env
- Model: unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL
- Context: 128K
- GPU layers: 40
- VRAM: ~5.7GB
- Tokens/sec: ~23-24 (TESTED)
- Notes: **DEFAULT** - Unsloth Dynamic 2.0

### configs/gemma4-e2b-ud-q4-xl.env
- Model: unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL
- Context: 128K
- GPU layers: 999 (all)
- VRAM: ~6.0GB (with `BATCH/UBATCH=2048`)
- Tokens/sec: ~41-45 (TESTED)
- Notes: **FASTEST** profile on this host, but lower output quality than E4B

### configs/gemma4-e4b-q4-unsloth.env (DEPRECATED)
- Model: unsloth/gemma-4-E4B-it-GGUF:Q4_K_M
- Context: 32K
- GPU layers: 50
- VRAM: ~4.5GB
- Notes: Use `gemma4-e4b-ud-q4-xl.env` instead.

### configs/gemma4-26b-unsloth.env
- Model: unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M (MoE)
- Context: 32K
- GPU layers: 30 (partial offload)
- VRAM: ~5GB / RAM: ~12GB
- Notes: MoE model with chain-of-thinking.

### configs/qwen3.5-2b-instruct-speed.env
- Model: bartowski/Qwen_Qwen3.5-2B-GGUF:Q4_K_M
- Context: 64K
- GPU layers: 999 (all)
- Notes: Stability-first speed profile for 6GB VRAM hosts.

### configs/qwen3.5-2b-instruct-quality.env
- Model: bartowski/Qwen_Qwen3.5-2B-GGUF:Q5_K_M
- Context: 64K
- GPU layers: 999 (all)
- Notes: Higher quality profile; keep VRAM under ~90% target.

### configs/qwen3.5-4b-instruct-speed.env
- Model: bartowski/Qwen_Qwen3.5-4B-GGUF:Q4_K_M
- Context: 64K
- GPU layers: 999 (all)
- Notes: 4B speed profile with conservative batch values.

### configs/qwen3.5-4b-instruct-quality.env
- Model: bartowski/Qwen_Qwen3.5-4B-GGUF:Q5_K_M
- Context: 64K
- GPU layers: 999 (all)
- Notes: 4B quality profile; reduce batch if VRAM exceeds 90%.

### Legacy / test configs (archive)

Test configuration files were moved to `configs/archive/`:

- `configs/archive/test-gemma4.env` (duplicate of the former Q5 unsloth config)
- `configs/archive/test-gemma4-tuned.env`
- `configs/archive/test-gemma4-q6-tuned.env`

## OpenWebUI Configuration

Configuration for OpenWebUI / OpenAI:

```json
{
  "llama": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "llama.cpp (remote pve2)",
    "options": {
      "baseURL": "http://192.168.200.38:8089/v1",
      "toolParser": [
        { "type": "raw-function-call" },
        { "type": "json" }
      ]
    },
    "models": {
      "gemma4:e4b": {
        "name": "Gemma 4 E4B",
        "tool_call": true,
        "limit": {
          "context": 65536,
          "output": 8192
        },
        "modalities": {
          "input": ["text","image"],
          "output": ["text"]
        }
      },
      "gemma4:26b": {
        "name": "Gemma 4 26B",
        "tool_call": true,
        "limit": {
          "context": 32768,
          "output": 8192
        }
      }
    }
  }
}
```

## Sync Tool

Use `sync.sh` to manage the remote server:

```bash
# Sync local files -> server
./sync.sh push

# Sync + container restart
./sync.sh deploy

# Sync + rebuild + restart
./sync.sh rebuild

# Stop container
./sync.sh stop

# Start container
./sync.sh start

# Restart container
./sync.sh restart

# Container and GPU status
./sync.sh status

# Check health
./sync.sh health

# Container logs
./sync.sh logs

# SSH to server
./sync.sh ssh

# Show current configuration
./sync.sh config
```

## Benchmark & quality test summary

All tests below were executed on the remote host (`192.168.200.38`, GTX 1060 6GB) via the OpenAI-compatible endpoint.

### Throughput snapshots (~500-character generation)

| Profile | Model | Throughput (tok/s) | VRAM | Host RAM |
|---|---|---:|---:|---:|
| Gemma E4B default | `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL` | ~23.24 | 5779 / 6144 MiB | 4510 / 11966 MiB |
| Gemma E2B fast | `unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL` | ~41-45 | ~6045 / 6144 MiB | ~4510 / 11966 MiB |

### Qwen 3.5 Instruct profile tests (stability target: <=90% VRAM)

| Config | Model | Throughput (tok/s) | VRAM | Result |
|---|---|---:|---:|---|
| `qwen3.5-2b-instruct-speed.env` | `bartowski/Qwen_Qwen3.5-2B-GGUF:Q4_K_M` | 58.42 | 3971 / 6144 MiB (~64.6%) | Stable |
| `qwen3.5-2b-instruct-quality.env` | `bartowski/Qwen_Qwen3.5-2B-GGUF:Q5_K_M` | 50.44 | 3651 / 6144 MiB (~59.4%) | Stable |
| `qwen3.5-4b-instruct-speed.env` | `bartowski/Qwen_Qwen3.5-4B-GGUF:Q4_K_M` | 27.72 | 5445 / 6144 MiB (~88.6%) | Stable |
| `qwen3.5-4b-instruct-quality.env` (initial) | `bartowski/Qwen_Qwen3.5-4B-GGUF:Q5_K_M` | 25.96 | 5629 / 6144 MiB (~91.6%) | Above target |
| `qwen3.5-4b-instruct-quality.env` (tuned: `BATCH/UBATCH=640`) | `bartowski/Qwen_Qwen3.5-4B-GGUF:Q5_K_M` | 25.93 | 5507 / 6144 MiB (~89.6%) | Stable |

### Quality comparisons

#### Gemma family comparison (same prompts, deterministic settings)

Compared models:
- `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL`
- `unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL`
- `bartowski/google_gemma-4-E4B-it-GGUF:Q4_K_M`

Result:
- **Best overall quality and stability:** `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL`
- **Fastest but less reliable quality:** `unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL`
- **Good alternative:** `bartowski/google_gemma-4-E4B-it-GGUF:Q4_K_M`

#### Head-to-head (50/50 coding/general): Gemma 4B vs Qwen 3.5 4B

Compared models:
- `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL`
- `bartowski/Qwen_Qwen3.5-4B-GGUF:Q5_K_M`

Operational outcome:
- Gemma 4B: ~22.9 tok/s, ~5769 / 6144 MiB VRAM
- Qwen 3.5 4B Q5: ~26.35 tok/s, ~5505 / 6144 MiB VRAM

Quality outcome from test prompts:
- **Gemma 4B produced complete final answers consistently**.
- **Qwen 3.5 4B was faster, but in multiple prompts consumed output budget in `reasoning_content` and returned empty final `content`** (`finish_reason=length`).

Practical recommendation (current settings):
- For mixed 50/50 coding + general chat, use **Gemma 4B E4B UD-Q4_K_XL** as default quality/stability profile.
- Use **Qwen 3.5 4B Q5** when speed/VRAM headroom is prioritized and occasional response-finalization issues are acceptable.

Status: **OK** (model endpoint ready and serving responses).

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

## API Endpoints

- **WebUI:** http://192.168.200.38:8089
- **Health:** http://192.168.200.38:8089/health
- **OpenAI API:** http://192.168.200.38:8089/v1/chat/completions

### Example API call
```bash
curl http://192.168.200.38:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello!"}],
    "model": "gemma-4"
  }'
```

## Build Info

- **llama.cpp:** b9009 (`0754b7b`)
- **CUDA:** 12.4
- **Build flags:** `GGML_CUDA_NCCL=OFF` (single-GPU host, avoids `libnccl.so.2` runtime issue)
- **Base image:** nvidia/cuda:12.4.0-devel-ubuntu22.04

## Recovery / GPU self-heal

- GPU watchdog (`scripts/gpu-watchdog.sh`) detects CPU fallback:
  - `nvidia-smi` shows 0 MiB used by container,
  - logs contain `ggml_cuda_init: failed` or `no usable GPU found`.
- Self-heal attempts (max `MAX_ATTEMPTS=2`, cooldown `COOLDOWN_MINUTES=30`):
  1. `docker compose restart llama-server`
  2. Wait for `/health` → `200`
  3. If still CPU fallback: restart Docker + nvidia-persistenced
- Logs: `/var/log/llama-gpu-watchdog.log` + `logger -t llama-gpu-watchdog`
- Deploy:
  ```bash
  cp scripts/gpu-watchdog.sh /root/llama/scripts/
  cp deploy/systemd/llama-gpu-watchdog.{service,timer} /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now llama-gpu-watchdog.timer
  ```
