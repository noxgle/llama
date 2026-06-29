# Plan testów — 2026-06-29

Wyniki websearch: llama.cpp b9837 (vs obecny b9770, ~60 release'ów dalej),
GGML_CUDA_GRAPH_OPT (concurrent streams, +30-40% TG na 4090), SoA prefill opt,
Unsloth Gemma4 QAT, TurboQuant fork.

---

## Phase 0: Git snapshot — tag + stabilna gałąź ✅
- [x] `git tag stable-b9770-v1 && git push origin stable-b9770-v1`
      → ghcr.io/noxgle/llama-server:stable-b9770-v1 (rollback image) ✅
- [x] `git checkout -b stable/2026-06-29 && git push origin stable/2026-06-29`
- [x] `git checkout master`
- [x] CI fix: dodane `stable*` tagi, Node 24 actions
- [!] Uwaga: build na GitHub-hosted runner (brak self-hosted), obraz z cache.
      Stable tag OK do rollbacku, ale do Phase 1 trzeba świeżego builda.

## Phase 1: Rebuild image (b9770 → b9837)
- [ ] **Build na dev serverze** `root@192.168.200.38`:
      ```
      ssh root@192.168.200.38
      cd /opt/llama
      docker compose build --no-cache
      ```
      (lub przez CI z `no-cache: true` w workflow_dispatch)
- [ ] Jeśli build przez CI: `gh workflow run build.yml --ref master -f llama_ref=master -f build_jobs=6`
- [ ] Zweryfikować nowy image: `docker compose pull` na dev (jeśli CI)
- [ ] Smoke test: health endpoint + `curl` probe (short prompt)
- [ ] GPU guard: `scripts/benchmark-guarded-remote.sh` na dev
- [ ] Knowledge benchmark: `scripts/benchmark-knowledge.sh` (obecne baseline: Qwen ~33 tok/s, Gemma4 ~27.8 tok/s)
- [ ] MTP draft benchmark: `scripts/benchmark-draft-mtp.sh`
- [ ] Potwierdzić: flash-attn, cache-ram, cache-reuse, --preserve-thinking działają
- [ ] Jeśli OK: deploy na prod Qwen (192.168.200.20), Gemma4 (192.168.200.21), Q5 (192.168.200.19)

## Phase 2: GGML_CUDA_GRAPH_OPT=1
- [ ] Dodać `CUDAGRAPH_OPT=1` do `docker-compose.yml` jako `GGML_CUDA_GRAPH_OPT`
- [ ] Dodać do `configs/*.env`:
      ```
      CUDAGRAPH_OPT=1
      ```
- [ ] Test na dev: Qwen3.6 Q4_K_M — porównanie TG tok/s (przed/po)
- [ ] Test na dev: Gemma4 26B Q4_K_M — porównanie TG tok/s
- [ ] Sprawdzić VRAM usage (nvidia-smi) — czy nie zwiększa footprintu
- [ ] Knowledge benchmark z `CUDAGRAPH_OPT=1`
- [ ] Jeśli stabilne: deploy na prod

## Phase 3: Batch tuning Gemma4
- [ ] Obecnie: `BATCH=512/UBATCH=512`. Przetestować:
      - `BATCH=1024/UBATCH=1024` — sprawdzić VRAM (%)
      - `BATCH=2048/UBATCH=1024` — sprawdzić czy się mieści (6 GB VRAM)
- [ ] Knowledge benchmark dla każdej konfiguracji
- [ ] Wybrać optymalną, zaktualizować `configs/gemma4-26b-q4-k-m-mtp.env`

## Phase 4: SoA prefill test
- [ ] Porównać prefill tok/s na Qwen3.6 Q4_K_M przed/po update
- [ ] Benchmark z długim promptem (~10k toków): `scripts/benchmark-batch.sh`
- [ ] Jeśli SoA wspiera tylko dense modele — ew. test z Qwen3-8B Q4_K_M (opcjonalnie)

## Phase 5: Nowe modele (opcjonalnie)
- [ ] Gemma4 12B QAT (Unsloth) — sprawdzić czy mieści się na A2000 6GB
      - `unsloth/gemma-4-12B-it-qat-GGUF`
- [ ] Gemma4 E4B QAT — porównanie jakości vs zwykły Q4_K_M
      - `unsloth/gemma-4-E4B-it-qat-mobile-GGUF`
- [ ] Knowledge benchmark na każdym nowym modelu
- [ ] Jeśli dobrze działa — stworzyć configi w `configs/`

## Phase 6: MTP re-verify
- [ ] Potwierdzić `SPEC_DRAFT_N_MAX=1` nadal optymalne na nowym buildzie
- [ ] Benchmark: n_max=0 (MTP off) vs 1 vs 2 vs 3
- [ ] Sprawdzić draft acceptance rate — czy się zmienił

## Phase 7: TurboQuant fork (eksperymentalne)
- [ ] Fork: `NJannasch/llama.cpp` — branch `mtp-turboquant`
- [ ] Stworzyć osobny Dockerfile (np. `Dockerfile.turboquant`)
- [ ] Zbudować testowo
- [ ] Benchmark: porównanie TG tok/s z mainline
- [ ] Ryzyko: brak wsparcia w CI, trzeba buildować ręcznie
