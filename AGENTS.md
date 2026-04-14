# AGENTS.md - Llama.cpp Docker Project

## Project Overview

Docker Compose setup for llama.cpp with CUDA support, optimized for running LLM models on GPU. The project builds a Docker container with llama.cpp server compiled with CUDA acceleration and provides configuration files for various Gemma 4 model quantizations.

- **Hardware:** NVIDIA GTX 1060 6GB, 12GB RAM, 6 cores
- **System:** Debian 13 (trixie) — remote server
- **llama.cpp:** PR #21343 + PR #20050 patch (KV cache retry fix)
- **CUDA:** 12.4

## Tech Stack

| Component | Technology |
|-----------|------------|
| Container Runtime | Docker |
| Orchestration | Docker Compose |
| Build System | CMake (in Dockerfile) |
| GPU Acceleration | CUDA 12.4 |
| Base Image | nvidia/cuda:12.4.0-devel-ubuntu22.04 (builder), ubuntu:24.04 (runtime) |
| LLM Server | llama.cpp (ggml-org) |
| Models | Gemma 4 (unsloth/bartowski quantizations) |
| Scripting | Bash (sync.sh) |

## Architecture

The project follows a single-service Docker architecture:

1. **llama-server** — Docker container running llama.cpp server with CUDA
2. **Remote Deployment** — Server runs on remote host (192.168.200.38)
3. **Sync Mechanism** — rsync + SSH for deployment (sync.sh)
4. **Configuration** — Environment-based (configs/*.env files)

```
┌─────────────┐      rsync       ┌──────────────────┐
│  Local Dev  │ ─────────────► │  Remote Server    │
│  (llama/)   │                │  (ag@192.168.200.38) │
└─────────────┘                │  - Docker         │
                               │  - llama-server  │
                               │  - GPU (GTX1060) │
                               └──────────────────┘
```

## Directory Structure

```
llama/
├── .env.example          # Example environment variables
├── .gitignore           # Git ignore patterns
├── AGENTS.md            # This file
├── README.md            # Project documentation
├── Dockerfile          # Multi-stage Docker build
├── docker-compose.yml   # Docker Compose service definition
├── sync.sh              # Remote server management script
├── LICENSE             # Apache 2.0 license
└── configs/            # Model configuration files
    ├── gemma4-e4b-q4-unsloth.env
    ├── gemma4-e4b-q5-unsloth.env
    ├── gemma4-e4b-q5-bartowski.env
    ├── gemma4-e4b-q6-unsloth.env
    ├── gemma4-e4b-q6-bartowski.env
    ├── gemma4-e4b-q6-bartowski-L.env
    ├── gemma4-e4b-q8-unsloth.env
    ├── gemma4-26b-unsloth.env
    └── test-gemma4.env
```

## Development Workflow

### Local Development

1. Edit configuration files in `configs/` directory
2. Test locally (optional)
3. Use `sync.sh` to deploy to remote server

### Remote Server Management

```bash
# Sync files to server
./sync.sh push

# Deploy and restart
./sync.sh deploy

# Full rebuild
./sync.sh rebuild

# Check status
./sync.sh status

# View logs
./sync.sh logs

# Health check
./sync.sh health

# SSH to server
./sync.sh ssh
```

## Build Instructions

### Build Docker Image

```bash
# Build and start
docker compose up -d --build

# Or with custom PR
GH_TOKEN=xxx docker compose up -d --build
```

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| PR_NUMBER | 21343 | llama.cpp PR to build |
| BUILD_JOBS | 6 | Parallel build jobs |
| GH_TOKEN | (empty) | GitHub token for private PRs |

**Note:** Dockerfile automatically applies PR #20050 patch (KV cache retry fix) on top of PR #21343.

## Run Instructions

### Starting the Server

```bash
# Using environment file
docker compose --env-file configs/gemma4-e4b-q4-unsloth.env up -d

# Or copy to .env
cp configs/gemma4-e4b-q4-unsloth.env .env
docker compose up -d

# Check health
curl http://192.168.200.38:8089/health
```

### Using sync.sh

```bash
# Start with specific config (on remote)
ssh ag@192.168.200.38 "cd ~/llama && docker compose --env-file configs/gemma4-e4b-q5-bartowski.env up -d"
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| MODEL | ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M | HuggingFace model (repo:quant) |
| PORT | 8089 | Server port |
| HOST | 0.0.0.0 | Listen address |
| CTX | 32768 | Context size (tokens) |
| NGLAYERS | 50 | GPU layers (999=all, 0=CPU) |
| CPUMOE | exps=CPU | MoE experts on CPU |
| FLASHATTN | off | Flash Attention |
| BATCH | 256 | Batch size |
| UBATCH | 256 | Physical batch |
| THREADS | 6 | CPU threads |
| CACHE_TYPE_K | f16 | KV cache type (K) |
| CACHE_TYPE_V | f16 | KV cache type (V) |

## Configuration Files

### Available Configs (configs/)

| File | Model | Context | Layers | VRAM | Tokens/sec |
|------|-------|--------|--------|------|------------|
| gemma4-e4b-q4-unsloth.env | unsloth/gemma-4-E4B-it-GGUF:Q4_K_M | 32K | 50 | ~4.5GB | - |
| gemma4-e4b-q5-unsloth.env | unsloth/gemma-4-E4B-it-GGUF:Q5_K_M | 64K | 42 | ~5GB | - |
| gemma4-e4b-q6-unsloth.env | unsloth/gemma-4-E4B-it-GGUF:Q6_K | 64K | 15 | ~5.5GB | - |
| gemma4-e4b-q8-unsloth.env | unsloth/gemma-4-E4B-it-GGUF:Q8_K_M | 64K | 30 | ~6GB | - |
| gemma4-e4b-q5-bartowski.env | bartowski/google_gemma-4-E4B-it-GGUF:Q5_K_M | 64K | 42 | ~5.7GB | **~24** |
| gemma4-e4b-q6-bartowski.env | bartowski/google_gemma-4-E4B-it-GGUF:Q6_K | 64K | 42 | ~6.3GB | ~22.7 |
| gemma4-e4b-q6-bartowski-L.env | bartowski/google_gemma-4-E4B-it-GGUF:Q6_K_L | 64K | 25 | ~7.2GB | OOM (za dużo VRAM) |
| gemma4-26b-unsloth.env | unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M | 32K | 30 | ~5GB | - |

### Naming Convention

Config files follow pattern: `{model}-{variant}-{quant}-{provider}.env`

Examples:
- `gemma4-e4b-q4-unsloth.env` — Gemma 4 E4B, Q4 quantization, unsloth provider
- `gemma4-e4b-q5-bartowski.env` — Gemma 4 E4B, Q5 quantization, bartowski provider

## Linting & Formatting

No code linting or formatting tools are used in this project. The project consists of:
- Configuration files (Bash, YAML, ENV)
- No application code requiring linting
- No test files

## Testing Instructions

### Basic Health Check

No formal test suite exists. To verify the setup:

```bash
# Check server health
./sync.sh health

# Test API
curl http://192.168.200.38:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello!"}],
    "model": "gemma-4"
  }'
```

### Model Performance Testing

To test model speed (tokens per second):

#### 1. Deploy Configuration

```bash
# Sync and start with specific config
cd /home/picon/workspace/llama
./sync.sh push
ssh ag@192.168.200.38 "cd ~/llama && docker compose --env-file configs/gemma4-e4b-q5-bartowski.env up -d"
```

#### 2. Wait for Model Load

```bash
# Check health - wait until "status": "ok"
ssh ag@192.168.200.38 "curl -s http://localhost:8089/health"
```

#### 3. Run Performance Test

```bash
# Test generation speed (500 tokens)
ssh ag@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\": [{\"role\": \"user\", \"content\": \"Napisz krótką historię o smoku (około 500 znaków)\"}], \"model\": \"gemma-4\", \"max_tokens\": 500, \"temperature\": 0.7}"'
```

#### 4. Extract Metrics

From the response JSON, extract:
- `timings.predicted_ms` - generation time in ms
- `timings.predicted_per_second` - tokens per second

Or from server logs:
```bash
ssh ag@192.168.200.38 "docker logs llama-llama-server-1 --tail 10 | grep 'eval time'"
```

#### 5. Verify No KV Cache Errors

```bash
# Check for errors
ssh ag@192.168.200.38 "docker logs llama-llama-server-1 --tail 20 | grep -iE 'kv|cache|batch|error|failed'"
```

### Expected Results (GTX 1060 6GB)

| Config | Tokens/sec | Notes |
|--------|------------|-------|
| Q5_K_M | ~24 | Current best |
| Q6_K | ~22.7 | Slightly slower |

### VRAM Check

```bash
ssh ag@192.168.200.38 "nvidia-smi --query-gpu=memory.used,memory.total --format=csv"
```

## CI/CD

No CI/CD pipeline is configured. The project uses:

1. **GitHub PR Builds** — Dockerfile fetches PR #21343 from ggml-org/llama.cpp
2. **Manual Deployment** — sync.sh for deployment to remote server
3. **Docker Layer Caching** — Managed by Docker Hub/Registry

## Coding Conventions

### Shell Scripts (sync.sh)

- Use bash with `set -e`
- Color output using printf format codes
- Functions prefixed with `cmd_` for commands, `ssh_` for SSH, `rsync_` for rsync
- Use long options (e.g., `--progress`) for clarity

### Configuration Files (.env)

- Comma-separated key=value pairs
- Comments start with `#`
- Empty line between sections
- Sort variables alphabetically within sections

### Docker Files

- Use multi-stage builds
- Labels in comments format

## Git Workflow

### Branch Strategy

- Single branch: `master`
- Direct commits to master (small team project)
- No pull request enforcement required

### Commit Messages

Follow conventional commit format:

```
<type>: <subject>

[<body>]

[<footer>]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring
- `chore`: Maintenance
- `docs`: Documentation

Example:
```
refactor: Rename configs with provider suffix

- Add provider suffix to config files (unsloth/bartowski)
- Remove deprecated gemma3.env and phi4.env configs
- Update documentation

Closes #123
```

### Pull Request Guidelines

Not applicable — small team project with direct commits.

## File Modification Rules

### Allowed Modifications

1. **configs/*.env** — Add new model configurations
2. **README.md** — Update documentation
3. **AGENTS.md** — Update agent instructions
4. **sync.sh** — Add new management commands
5. **docker-compose.yml** — Add new services or modify existing

### Prohibited Modifications

1. **Dockerfile** — Do not modify without explicit approval
2. **.gitignore** — Minimal changes only
3. **LICENSE** — Never modify

### Adding New Configs

1. Create new file in `configs/` following naming convention
2. Add entry to table in README.md and AGENTS.md
3. Update sync.sh help if needed

## Code Generation Rules

As this is a configuration-based project (no application code), agents should:

1. Generate shell scripts with proper error handling (`set -e`)
2. Use environment variables for configuration
3. Document all new files in README.md/AGENTS.md

## Testing Requirements

For any changes that affect the server:

1. Verify container builds: `docker compose build`
2. Verify container starts: `docker compose up -d`
3. Verify health endpoint: `curl http://localhost:8089/health`
4. Check logs: `docker compose logs --tail=20`

## Documentation Rules

1. All configuration files must be documented in README.md
2. New features must be documented in AGENTS.md
3. Use clear, descriptive comments in config files
4. Include examples for CLI commands

## Security Notes

1. Never commit credentials or tokens to git
2. Use `.env` files for secrets (not committed to git)
3. `.gitignore` excludes `.env`, `*.log`, `build/`
4. SSH keys stored in `~/.ssh/` (not in project)

## Performance Notes

1. Use Q4/Q5 quantizations for GTX 1060 6GB
2. Set NGLAYERS according to available VRAM
3. Use `--fit off` to disable auto-VRAM fitting
4. Use Q4 KV cache to save VRAM

## Known Constraints

- **VRAM Limited** — GTX 1060 6GB can only run Q4-Q6 quantizations
- **Context Size** — Limited by VRAM (32K-64K typical)
- **No SSL** — Server runs on HTTP (local network only)
- **Remote Access** — Requires SSH access to 192.168.200.38

## Agent Instructions

### How to Modify Code

1. Understand the task first — ask clarifying questions if needed
2. Use the planning mode for complex multi-step tasks
3. Make specific, targeted changes
4. Test changes when possible

### Critical Files

| File | Priority | Description |
|------|----------|-------------|
| configs/*.env | HIGH | Model configurations |
| docker-compose.yml | HIGH | Service definition |
| Dockerfile | CRITICAL | Build process (don't modify) |
| sync.sh | MEDIUM | Server management |

### What NOT to Do

1. Do not modify Dockerfile without explicit approval
2. Do not add new programming languages
3. Do not add system-level dependencies
4. Do not remove existing configurations without approval
5. Do not push to remote without user confirmation

### Adding New Features

1. Create a plan first
2. Show the plan to user for approval
3. Execute only after approval
4. Test the feature
5. Update documentation

### Writing Tests

Since there are no automated tests:

1. Manual testing via curl commands
2. Log verification
3. Health endpoint checks

### Updating Documentation

1. Update AGENTS.md for agent-specific info
2. Update README.md for user-facing docs
3. Keep files in sync
4. Use clear headings and examples