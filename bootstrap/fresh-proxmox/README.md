# Fresh Proxmox → llama.cpp MTP Server

One-shot bootstrap from bare-metal Proxmox to a working `qwen3.6-35ba3b-mtp-unsloth` OpenAI-compatible endpoint with GPU passthrough, auto-start, and GPU watchdog self-heal.

## Quickstart

```bash
cp config.env.example config.env
# Edit config.env to match your Proxmox network and storage
nano config.env

# Run the full install
bash install-all.sh

# Wait 15-45 minutes (downloads: LXC template, git clone, Docker build)
# Then:
curl http://<LXC_IP>:8089/health
```

## What gets installed

| Component | Detail |
|---|---|
| **LXC** | Debian 13 container with GPU passthrough |
| **Docker + compose** | Official Docker CE with compose plugin |
| **llama.cpp** | `ggml-org/llama.cpp:master` with MTP PR #22673 |
| **Model** | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M` |
| **Config** | `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`, `CTX=180224` |
| **Auto-start** | Systemd via `llama-compose.service` (waits for GPU + Docker) |
| **Post-boot fix** | `llama-postboot-restart.service` (90s delayed restart to avoid startup race) |
| **GPU watchdog** | `llama-gpu-watchdog.timer` — detects CPU fallback and self-heals |

## Prerequisites

- Proxmox VE 8.x with root access
- NVIDIA GPU installed and working (`nvidia-smi` shows your card)
- Internet access (downloads templates, docker images, git repos)
- About 15 GB free disk space for the LXC rootfs, Docker image, and model weights
- At least 16 GB RAM on the Proxmox host (24 GB recommended)

## Configuration

All settings in `config.env`:

| Variable | Default | Description |
|---|---|---|
| `VMID` | `1004` | LXC container ID |
| `LXC_HOSTNAME` | `llama` | Container hostname |
| `LXC_IP` | `192.168.200.38` | IP address (edit for your subnet) |
| `CIDR` | `24` | Network prefix |
| `GATEWAY` | `192.168.200.1` | Default gateway |
| `BRIDGE` | `vmbr0` | Proxmox bridge |
| `STORAGE` | `local-zfs` | Storage for container rootfs |
| `CORES` | `6` | vCPUs |
| `MEMORY_MB` | `24576` | RAM (MiB) |
| `DISK_GB` | `40` | Rootfs size |
| `PROJECT_DIR` | `/opt/llama` | Install path inside LXC |
| `APP_PORT` | `8089` | Server port (mapped to host via NAT) |
| `ACTIVE_CONFIG` | `configs/qwen3.6-35ba3b-mtp-unsloth.env` | Config profile in repo |
| `ENABLE_WATCHDOG` | `true` | Deploy GPU watchdog timer |
| `ENABLE_POSTBOOT_RESTART` | `true` | Deploy delayed restart fix |
| `SKIP_BUILD` | `false` | Skip Docker build (use prebuilt image) |

## Step by step

The installer runs six phases in sequence:

```
00-prereq-check     Validate host: root, pveversion, GPU, bridge, storage, templates
10-host-nvidia      Kernel modules auto-load + nvidia-modprobe-ensure.service
20-create-lxc       Create LXC, GPU passthrough entries, auto-start config
30-lxc-base         Install Docker, compose plugin, curl, jq, git inside LXC
40-deploy-llama     Clone repo, copy config, docker compose build + up -d
50-postboot         systemd services for auto-start, corrective restart, watchdog
60-verify           Health check, chat completion, throughput probe, VRAM check
```

On any failure, the installer stops with a clear error message. Check `install.log` for details.

## Post-install

```bash
# Check service status on the Proxmox host
pct status 1004

# Enter the container
pct enter 1004

# Inside the container:
docker ps
curl localhost:8089/health
curl localhost:8089/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}],"model":"qwen3.6","max_tokens":200}'

# Check systemd services
systemctl status llama-compose.service
systemctl status llama-postboot-restart.service
systemctl status llama-gpu-watchdog.timer

# View watchdog logs
cat /var/log/llama-gpu-watchdog.log
```

## Recovery

### Container won't start
```bash
pct start 1004
pct enter 1004
systemctl status llama-compose.service
journalctl -u llama-compose.service --no-pager
```

### CPU fallback (0 VRAM)
The GPU watchdog auto-detects and self-heals. To check:
```bash
cat /var/log/llama-gpu-watchdog.log
```

Manual fix:
```bash
pct enter 1004
cd /opt/llama
docker compose down && docker compose up -d
```

### Need to change config
```bash
pct enter 1004
cd /opt/llama
cp configs/<new-config>.env .env
docker compose down && docker compose up -d
```

### Full reinstall
```bash
# From Proxmox host
pct stop 1004
pct destroy 1004
bash install-all.sh
```

## Known issues

- **First build takes 10-15 minutes** — Docker compiles llama.cpp from source
- **GPU passthrough requires NVIDIA driver 525+** on the Proxmox host
- **LXC networking** — if DHCP is used instead of static IP, set `LXC_IP` to empty string in config
- **Template auto-detect** only works if `pveam` is configured with a working repository

## Files

```
bootstrap/fresh-proxmox/
├── config.env.example      # Configuration template (copy to config.env)
├── install-all.sh          # Main orchestrator
├── README.md               # This file
└── steps/
    ├── 00-prereq-check.sh  # Validate Proxmox host
    ├── 10-host-nvidia.sh   # NVIDIA module + service setup
    ├── 20-create-lxc.sh    # LXC creation + GPU passthrough
    ├── 30-lxc-base.sh      # Docker + tools inside LXC
    ├── 40-deploy-llama.sh  # Clone, build, start services
    ├── 50-postboot.sh      # Resilience systemd units
    └── 60-verify.sh        # Health + throughput checks
```
