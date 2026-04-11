# AGENTS.md - Llama.cpp Docker Project

## Project Overview

Docker Compose setup for llama.cpp with CUDA support, optimized for running LLM models on GPU.

- **Hardware:** NVIDIA GTX 1060 6GB, 12GB RAM, 6 cores
- **System:** Debian 13 (trixie)
- **llama.cpp:** PR #21343
- **CUDA:** 12.4

## Quick Commands

```bash
# Build and start
docker compose up -d --build

# Start with specific config
docker compose --env-file configs/gemma4.env up -d

# Check status
curl http://192.168.200.38:8089/health

# View logs
docker compose logs -f

# Rebuild
docker compose build --no-cache
docker compose up -d
```

## Available Configs

| Config | Model | Context | GPU Layers | VRAM |
|--------|-------|---------|------------|------|
| gemma4.env | Gemma 4 E4B IT Q4_K_M | 32K | 50 | ~4.5GB |
| gemma4-26b.env | Gemma 4 26B MoE Q4_K_M | 8K | 30 | ~5GB |
| gemma3.env | Gemma 3 4B IT Q4_K_M | 32K | 999 | ~4GB |
| phi4.env | Phi-4 Mini Q4_K_M | 16K | 999 | ~3GB |
| gemma4-q5.env | Gemma 4 Q5_K_M | 32K | 50 | ~5GB |
| gemma4-q8.env | Gemma 4 Q8_0 | 32K | 50 | ~6GB |

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| MODEL | HuggingFace repo:quant | ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M |
| PORT | Server port | 8089 |
| HOST | Listen address | 0.0.0.0 |
| CTX | Context size | 32768 |
| NGLAYERS | GPU layers (999=all, 0=CPU) | 50 |
| CPUMOE | MoE experts on CPU | exps=CPU |
| FLASHATTN | Flash Attention | on/off/auto |
| BATCH | Batch size | 256 |
| UBATCH | Physical batch | 256 |
| THREADS | CPU threads | 6 |

## API Endpoints

- **Health:** http://192.168.200.38:8089/health
- **WebUI:** http://192.168.200.38:8089
- **OpenAI API:** http://192.168.200.38:8089/v1/chat/completions

### Example API Call

```bash
curl http://192.168.200.38:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello!"}],
    "model": "gemma-4"
  }'
```

## Troubleshooting

```bash
# Check GPU usage
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv

# Check container logs
docker compose logs --tail=50

# Restart with clean rebuild
docker compose down
docker compose build --no-cache
docker compose up -d
```