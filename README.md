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

# Use Gemma 4 E2B (szybszy, mniejszy VRAM)
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
| `-fa` | Flash Attention (off for GTX 1060) |
| `-b` / `-ub` | Batch sizes |
| `-t` | CPU threads |
| `--mlock` | Lock model in RAM |
| `--fit off` | Disable auto-fit to VRAM |

## Available Configs

### configs/gemma4-e4b-ud-q4-xl.env
- Model: unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL
- Context: 128K
- GPU layers: 40
- VRAM: ~5GB
- Tokens/sec: ~27 (TESTED)
- Notes: **DEFAULT** - Unsloth Dynamic 2.0

### configs/gemma4-e2b-ud-q4-xl.env
- Model: unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL
- Context: 128K
- GPU layers: 999 (all)
- VRAM: ~3.2GB
- Tokens/sec: ~50 (TESTED)
- Notes: **ULTRA COMPACT** - fastest model (~2x faster than E4B!)

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

## Performance test (E2B UD-Q4_K_XL)

Latest test executed on the remote server (`192.168.200.38`) for ~500-character text generation:

- Model: `unsloth/gemma-4-E2B-it-GGUF:UD-Q4_K_XL`
- Wynik: **50.81 tokens/sec**
- VRAM: **4385 MiB / 6144 MiB** (~71%)
- RAM hosta: **4158 MiB / 11966 MiB** (~35%)
- Container RAM: **3.399 GiB / 11.69 GiB**

Status: **OK** (health endpoint returns `ok`).

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
