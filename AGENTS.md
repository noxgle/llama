# AGENTS.md

## Scope
- **Production server:** `root@192.168.200.38:/opt/llama` — RTX 4060 Ti 16 GB, Qwen3.6 35B (~30 tok/s)
- **Test/alt server:** `root@192.168.200.20:/opt/llama` — RTX A2000 6 GB, Debian 13 trixie, Qwen3.6 (~36 tok/s)
- Operational SOTs: `llama.sh`, `configs/*.env`, `deploy/install-llama.sh`, `.github/workflows/build.yml`.

## Deployment gotchas (critical)

### ~~Server path mismatch (known bug)~~ (FIXED)
`sync.sh` previously targeted `ag@...:~/llama` but has been corrected to `root@192.168.200.38:/opt/llama`. All `ssh`/`scp` commands now use the correct target. The script commands (`deploy`, `rebuild`, `restart`) work as expected.

### .env is never synced
- `.env` is in `.gitignore`.
- `sync.sh push` also `--exclude=".env"`.
- Editing `configs/*.env` locally does NOT affect the server. To switch config:
  ```bash
  # On server as root:
  cp /opt/llama/configs/<name>.env /opt/llama/.env
  docker compose down && docker compose up -d
  # OR (new approach):
  /opt/llama/llama.sh start qwen   # reads configs directly, no .env needed
  ```

### .env changes require down+up, not restart
`docker compose restart` does NOT re-read `.env`. Always do `docker compose down && docker compose up -d`.
The `llama.sh` script avoids this issue entirely — it reads configs directly via `docker run`.

### HF download bug (get_hf_plan)
- The deployed builds have a bug where `get_hf_plan` fails for certain quant names (e.g., `:UD-Q8_K_XL`, `:Q8_0`) even though the file exists in the cache. Workaround: use `MODEL_FLAG=-m` with a local symlink path and `DRAFT_FLAG=-md` for draft models.
- See `docker-compose.yml` for the dual-flag support (`-hf` for HF repos, `-m` for local files).
- Symlinks to cached HF blobs are stored in `/opt/llama/models/` on the server (bind-mounted to `/models` in container).

### Local .env != server .env
- Local `.env`: stale Gemma 4 E4B config (Unsloth).
- Server `.env`: varies — always copy from `configs/<name>.env`.
- These diverge because `.env` never syncs. The server-side `configs/` is only updated via `sync.sh push`, but `.env` must be `cp`'d manually.

## Current production config (validated stable)
- **Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`
- **Model:** `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M` (HF Unsloth dynamic GGUF)
- **Context:** 163840 (160K)
- **MTP:** `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2` (~79% accept rate, ~30.1 tok/s)
- **VRAM:** ~4473/6144 MiB, RAM: ~20/30 GiB
- **LLama.cpp commit:** `75ad0b2` (tag `b9770`, deployed 2026-06-23, built locally & scp'd)
- **Benchmark (A/B vs 8086439):** +3% throughput (29.2→30.1 tok/s)
- Use this as the default reference. All Gemma 4 configs are legacy/archive.

## Gemma 4 test results (2026-06-23)

### Working: UD-Q4_K_M + Q8_0-MTP draft (`draft-mtp`)
- **Config file:** `configs/gemma4-26b-q4-k-m-mtp.env`
- **Model (local):** `/models/gemma4-26b-q4-k-m.gguf` (symlink to HF cache blob)
- **Draft (local):** `/models/gemma4-26b-q8-mtp.gguf` (symlink to HF cache blob)
- **Flags:** `MODEL_FLAG=-m`, `DRAFT_FLAG=-md` (bypasses `get_hf_plan` bug)
- **NGLAYERS=999** (all non-expert layers on GPU, experts on CPU via `CPUMOE=exps=CPU`)
- **Context:** 131072 (128K)
- **BATCH=512**, **UBATCH=512**
- **SPEC_TYPE=draft-mtp**, `SPEC_DRAFT_N_MAX=2` (~85% accept rate, ~27.4 tok/s)
- **VRAM:** ~5415/6138 MiB, RAM: ~15/30 GiB
- **GPU_LAYERS_DRAFT=99** — draft model (Q8_0-MTP, 462 MB) w pełni na GPU; przyspiesza inferencję z ~20.9 → **~27.4 tok/s** (+31%)
- **Benchmark (b9770 vs 8086439):** +7.5% throughput (25.5→27.4 tok/s)
- **Notes:** `draft-simple` crashes on build 8086439 and on b9770 (PR #20277 still unpatched). Use `draft-mtp` instead.

### Working: UD-Q8_K_XL + Q8_0-MTP draft (`draft-mtp`)
- **Config file:** `configs/gemma4-26b-q8_0-mtp.env`
- **Model:** UD-Q8_K_XL (~27.6 GB, near-lossless quality)
- **Throughput:** ~11.3 tok/s (90% draft accept) — not re-tested on b9770
- **RAM:** ~27/30 GiB (very tight, 4 Gi available)
- **Notes:** Higher quality than Q4_K_M, but much slower and RAM-constrained.

### Blocked
- `draft-simple` crashes on all builds tested (8086439 and b9770, PR #20277, `failed to process speculative batch`). Loads fine, crashes on first inference request.
- HF download (`get_hf_plan`) fails for non-standard quant names. Workaround: local files via symlinks (`-m` flag).

## MTP speculative decoding
- Upstream PR #22673, on `ggml-org/llama.cpp:master`. Flags in `docker-compose.yml`:
  - `--spec-type ${SPEC_TYPE:-none}` (set to `draft-mtp`)
  - `--spec-draft-n-max ${SPEC_DRAFT_N_MAX:-3}`
  - `--no-mmproj` (required; MTP segfaults on multimodal prompts otherwise)
- Turboquant fork (`AtomicBot-ai/atomic-llama-cpp-turboquant`) was abandoned — MTP crashes with SIGSEGV.
- `draft-simple` crashes on build 8086439 (PR #20277). Use `draft-mtp` for Gemma 4's separate MTP head.
- For local draft files: use `DRAFT_FLAG=-md` and `DRAFT_MODEL=/path/to/draft.gguf`.

## Build
- Source: `ggml-org/llama.cpp.git`, pinned by `LLAMA_REF` compose build arg (default `master`).
- `-DGGML_CUDA_NCCL=OFF` — single-GPU host, avoid `libnccl.so.2` runtime issues.
- Do not modify `Dockerfile` unless explicitly asked.
- **Deployment method:** build locally, compress to tar.gz, scp, pipe directly into `docker load`:
  ```bash
  docker save llama-llama-server:latest | gzip > /tmp/llama-<tag>.tar.gz
  scp /tmp/llama-<tag>.tar.gz root@192.168.200.38:/tmp/
  ssh root@192.168.200.38 'gzip -dc /tmp/llama-<tag>.tar.gz | docker load && rm /tmp/llama-<tag>.tar.gz'
  ```
  Avoids writing uncompressed tar on server (saves ~8 GB temp space). Server must have enough free disk for compressed file + Docker layer extraction (~12-13 GB for an 8.97 GB image).
- **Build benchmark (b9770 vs 8086439):**
  - **Gemma4 Q4_K_M+MTP:** 25.5 → 27.4 tok/s (+7.5%)
  - **Qwen3.6+MTP:** 29.2 → 30.1 tok/s (+3%)
  - Key PRs in b9770: flash mtp3 (#24340), CUDA PDL MoE (#24087), Step3.5 MTP fix (#24060), MTP verify batch (#21845).

## Provisioning (from scratch)

### `deploy/install-llama.sh` (LXC / bare metal bootstrap)

Installs Docker, nvidia-container-toolkit, and a complete llama.cpp server on a
fresh Debian 12+ or Ubuntu 22.04+ machine.  Run from a curl pipe — no repo
checkout needed:

```bash
# Qwen3.6 (production)
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) qwen

# Gemma4 26B (alternative)
bash <(curl -fsSL https://raw.githubusercontent.com/noxgle/llama/master/deploy/install-llama.sh) gemma4
```

**What it does:**
1. Installs Docker Engine (official repo)
2. Installs nvidia-container-toolkit
3. Verifies GPU access inside Docker — **aborts if GPU is not available**
4. Clones the repo to `/opt/llama`
5. Creates HF cache Docker volume + `models/` directory
6. Pulls server image from GHCR
7. Checks disk space (warns if < 25 GB for model)
8. Enables systemd service for autostart (`llama@<model>`)
9. Pre-caches model weights from HuggingFace
10. Starts the server on port 8089

After reboot the model auto-starts via systemd.  GPU passthrough for Proxmox LXC
is a prerequisite — the script prints the required `lxc.*` entries if missing.

### Provisioning gotchas

1. **Debian 13 trixie** — Docker only has repos for bookworm. The script maps
   `trixie` → `bookworm` for both Docker and NVIDIA CTK repos.
2. **Disk space** — Qwen3.6 model needs ~22 GB for weights, Docker image is ~18 GB,
   plus system overhead. Minimum disk: **70 GB** (80 GB recommended).
3. **Systemd Type=oneshot** — `llama.sh start` returns immediately (detached Docker).
   The systemd service uses `Type=oneshot` with `RemainAfterExit=yes`.
4. **GHCR auth** — The image is private by default. CI/CD pushes via `GITHUB_TOKEN`
   with `packages: write` permission. For external pulls, either make the package
   public or authenticate with a `read:packages` token.
5. **Model download** — The server downloads model weights on first start via `-hf`.
   The install script initiates the download and runs for 60s before returning.
   The systemd service's `--restart unless-stopped` and systemd's restart policy
   ensure the download resumes until complete.

---

## Production scripts

### `llama.sh` (docker run wrapper, replaces compose)
- **Location:** `/opt/llama/llama.sh` (synced via `sync.sh push`)
- **Usage:**
  ```bash
  ./llama.sh start qwen       # Qwen3.6 on port 8089
  ./llama.sh start gemma4     # Gemma4 on port 8090
  ./llama.sh stop             # Stop both
  ./llama.sh restart qwen     # Stop + start
  ./llama.sh status           # List containers
  ./llama.sh logs qwen        # Tail logs
  ./llama.sh pull             # Pull latest image
  ```
- Reads `configs/<model>.env` and translates to `docker run` flags.
- Image: `ghcr.io/noxgle/llama-server:latest` (override with `LLAMA_IMAGE`).
- Stops ALL containers named `llama*` before start (safe switching).

### Systemd (optional)
```bash
cp deploy/systemd/llama@.service /etc/systemd/system/
systemctl enable --now llama@qwen
```
Note: Uses `Type=oneshot` + `RemainAfterExit=yes` because `llama.sh start`
returns immediately (the container runs detached).

### CI/CD
- `.github/workflows/build.yml` — build on push to `master` or tag `b*`.
- Pushes to `ghcr.io/noxgle/llama-server`.
- CUDA cross-compile on standard runner; self-hosted runner recommended (6-core).
- Set `SELF_HOSTED_RUNNER=self-hosted` repo variable to use Proxmox runner.

## Operational commands
```bash
# Quick throughput probe
ssh root@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write ~500 chars.\"}],\"model\":\"qwen3.6\",\"max_tokens\":500}"' \
  | jq '.timings.predicted_per_second'

# Guarded benchmark (aborts on CPU fallback)
HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh

# Server health
curl -s http://192.168.200.38:8089/health
```

## GPU watchdog
- Deployed via systemd timer: `deploy/systemd/llama-gpu-watchdog.{service,timer}`.
- Detects CPU fallback (0 MiB VRAM, `ggml_cuda_init: failed` in logs).
- Self-heal: restart container → if still CPU → restart Docker + nvidia-persistenced.
- Max 2 attempts, 30 min cooldown.
- Deploy:
  ```bash
  cp scripts/gpu-watchdog.sh /opt/llama/scripts/
  cp deploy/systemd/llama-gpu-watchdog.{service,timer} /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now llama-gpu-watchdog.timer
  ```

## Config conventions
- Active configs in `configs/`. Deprecated/test-only go to `configs/archive/`.
- `docker-compose.yml` defaults assume high memory: `CTX=65536`, `NGLAYERS=40`, `BATCH=1024`, `UBATCH=1024`.
- `docker-compose.test.yml` is experimental (legacy build args not consumed by current Dockerfile).
- `sync.sh` comments/output are partly Polish; ignore for docs language policy.

## Recovery
- If container crashes or MTP segfaults: check `/var/log/llama-gpu-watchdog.log`, restart via `docker compose down && docker compose up -d`.
- If VRAM exhausted: reduce `CTX`, switch to smaller model config, or reduce `BATCH`/`UBATCH`.
