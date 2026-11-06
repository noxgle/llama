# Plan testów — 2026-06-29

## Stable b12167 line — 2026-11-06 ✅ (approved, deployed to prod .19)
- [x] Local `GGML_NATIVE=ON` build on .38 (`LLAMA_REF=b12167`), image `:b12167-native`, 9.14 GB.
- [x] Knowledge A/B same day: b12167 **31.7 tok/s** vs b11096 **31.3** (+1.3%), 10/10 A-grade. Historical 34.4 = host drift.
- [x] Server prefill 4.5K/18K/64K: **746/724/619 t/s** vs 631/614/541 (**+18%/+18%/+14.5%**).
- [x] MTP sweep: n1 **+7.8%** vs off, n2 +1.2% → n1 optimal unchanged; n≥3 nadal OOM przy CTX=143360.
- [x] Soak 40×~4.5K: anon 2475→3461 MiB raz, potem flat → **brak wycieku #31392**.
- [x] Vision E2B: **114.4 tok/s, TTFT 76–90 ms** (b11096: 117.7 / 167 ms) → gate PASS (≥110).
- [x] Publish `stable/2026-11-06` + `stable-b12167-v1`.
- [x] Prod `.19`: transfer native image (`docker save | docker load`, ID `51a50915265b`), Q5 config merged (prod tuning `CACHE_RAM=8192`/`CTX_CHECKPOINTS=10` kept), drop-in → `:b12167-native`, restart, health 200.
- [x] Prod Q5 validation: knowledge **30.8 tok/s** (b11096: 30.7), 10/10 `finish=stop`, draft 89.7%, 0 `sched_graph_realloc`; VRAM 5343 MiB.
- [ ] `llama.sh` default → `:stable-b12167-v1` after CI image verified (CI build still running as of 2026-11-06 15:30).
- [ ] `.38` dev LXC can be stopped (image transfer complete).

## Stable b10665 line — 2026-09-05 ✅
- [x] Local production build on .19: `LLAMA_REF=b10665`, `GGML_NATIVE=ON`.
- [x] Qwen3.6 Q5 knowledge suite: 10/10 tasks, **29.0 tok/s** average; draft acceptance 84–96%.
- [x] Q5 production profile: `CACHE_RAM=3072`, `CTX_CHECKPOINTS=8`, `REASONING_BUDGET=8192`.
- [x] .38 dev LXC stopped after the rollout.
- [x] Create and publish `stable/2026-09-05` and `stable-b10665-v1`.
- [!] b10665 is not approved for Gemma 4 E2B vision: 97.8 vs 114.3 tok/s on b10068. Retain b10068 for vision rollback.

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

## Phase 1: Rebuild image (b9770 → b9837) ✅
- [x] **Build na dev serverze** `docker compose build --no-cache` → commit `8c146a8`, ~30 min
- [x] Smoke test: health + curl — **OK** (32.9 tok/s, 500 tok)
- [x] Potwierdzone: flash-attn, cache-ram, cache-reuse, --preserve-thinking działają
- [x] **Cache reuse**: loguje `not supported by this context` (MTP/SWA) — harmless, jak poprzednio
- [x] **Nowe w logach**: `graphs reused = 264` — CUDA graph caching aktywny defaultowo
- [x] **MTP**: draft acceptance 87.2%, mean len 1.87

### Wyniki benchmarków Phase 1+2:

| Test | Konfig | tok/s | Prefill tok/s | Uwagi |
|------|--------|-------|---------------|-------|
| Short 500 tok x3 | Default | 32.3-32.9 | 45.4-45.8 | Stabilny |
| Short 500 tok x3 | `GGML_CUDA_GRAPH_OPT=0` | 32.5-33.2 | 36.2-45.7 | Identyczny! |
| Medium 1000 tok | Default | 32.4 | 54.0 | |
| Medium 1000 tok | `GGML_CUDA_GRAPH_OPT=0` | 31.7 | 51.8 | |
| Long 44K | Default | 29.7 | **669.4** | |
| Long 45K | Default | 29.9 | **673.0** | |
| Long 45K | Default | 31.8 | **687.6** | |
| Long 100K | Default | 26.5 | **477.0** | ~210s total |
| Sustained 5x300 | Default | 32.5-33.0 | 45.8-48.2 | Brak degradacji |

### Kluczowe wnioski (Phase 1+2):
1. **Prefill olbrzymi skok**: ~680 tok/s (vs stare ~505 tok/s) → **+35%** przy 45K kontekście
2. **GGML_CUDA_GRAPH_OPT=0/1 bez różnicy** na RTX A2000 — GPU memory-bandwidth-bound, kernel launch nie jest bottleneckiem
3. **Sustained throughput stabilny**: 33 tok/s bez degradacji
4. `graphs reused = N` w logach to standardowy CUDA graph caching, a nie `GGML_CUDA_GRAPH_OPT`
5. Commit `8c146a8` (branża `master` na 2026-06-29) vs poprzedni `75ad0b2` (b9770)



## Phase 3: Batch tuning Gemma4 ✅
- [x] Test na dev z Gemma4 (bez MTP): BATCH=512/1024/2048/3072
- [x] **Wynik: batch size nie wpływa na generację** — memory-bandwidth-bound (~22.8 tok/s)
- [x] Prefill poprawia się z większym batchem: 1022→1108 tok/s (3072/1536, +8.4%)
- [x] VRAM stable: 4.0-4.1 GB / 6 GB (~68%)
- [x] Rekomendacja dla Gemma4 config: podnieść `BATCH=1024` / `UBATCH=1024` zamiast 512/512

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
