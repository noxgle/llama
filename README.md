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
# Use Gemma 4 (default)
cp configs/gemma4.env .env
docker compose up -d

# Switch to Gemma 4 26B (MoE - partial offload)
cp configs/gemma4-26b.env .env
docker compose up -d

# Switch to Gemma 3
cp configs/gemma3.env .env
docker compose up -d

# Switch to Phi-4
cp configs/phi4.env .env
docker compose up -d

# Or use --env-file directly
docker compose --env-file configs/gemma4-26b.env up -d
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
| `-fa` | Flash Attention (off for GTX 1060) |
| `-b` / `-ub` | Batch sizes |
| `-t` | CPU threads |
| `--mlock` | Lock model in RAM |
| `--fit off` | Disable auto-fit to VRAM |

## Available Configs

### configs/gemma4.env
- Model: Gemma 4 E4B IT Q4_K_M
- Context: 32K
- GPU layers: 50
- VRAM: ~4.5GB

### configs/gemma4-26b.env
- Model: unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M (MoE)
- Context: 8K
- GPU layers: 30 (partial offload)
- VRAM: ~5GB / RAM: ~12GB
- Uwagi: MoE model z chain-of-thinking

### configs/gemma3.env
- Model: Gemma 3 4B IT Q4_K_M
- Context: 32K
- GPU layers: 999 (all)
- Flash Attention: on

### configs/phi4.env
- Model: Phi-4 Mini Q4_K_M
- Context: 16K
- GPU layers: 999 (all)
- Flash Attention: on

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

- **llama.cpp:** PR #21343
- **CUDA:** 12.4
- **Base image:** nvidia/cuda:12.4.0-devel-ubuntu22.04
