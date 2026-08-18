# Project: Re-test bumpu llama.cpp b10068 → b10428 (master @ 885c5bbe8)

## Goal
Przetestować najnowszy llama.cpp (master HEAD `885c5bbe8` = release **b10428**, 2026-08-14; 215 commitów za odrzuconym b10213) z pełną bramką porównawczą vs b10068 i **podjąć decyzję: pin b10428 na produkcji albo zostać na b10068**. Decydującą bramką jest vision (Gemma 4 E2B) — to ona odrzuciła b10213.

## Context
- Produkcja pinowana na **b10068** (2026-06-29): `docker-compose.yml` → `ghcr.io/noxgle/llama-server:b10068`.
- **b10213** (2026-08-01) testowane i **odrzucone**: tekst bez regresji (+0.6% knowledge), ALE vision E2B: gen 102.9 vs 114.3 tok/s (−10%), TTFT 213 vs 167 ms (+28%).
- Od b10213 upstream zrobił 215 commitów. Kluczowy kandydat: **#26802** (2026-08-11) — CUDA graphs przywrócone dla skwantowanych MoE (MUL_MAT_ID w ścieżce MMQ); poprzedni check (era b10213) wyłączał graphy szerzej. Prawdopodobny mechanizm regresji z b10213 → szansa, że b10428 ją leczy (nasz Qwen3.6 A3B to skwantowany MoE, E2B ma własną ścieżkę vision).
- Master HEAD = `885c5bbe8e04dc78db25beb911a2715312ad7b54` (2026-08-14T08:32:59Z), otagowany b10428.

## Scope

### In Scope
- Build obrazu b10428 (SHA `885c5bbe8`) na dev .38, tag `:b10428`.
- Bramki na dev .38 (Qwen3.6 Q4_K_M + Gemma 4 E2B vision):
  1. Smoke test (GPU aktywny, guarded health)
  2. Tekst: knowledge suite + long-context
  3. MTP sweep `SPEC_DRAFT_N_MAX` 0/1/2/3
  4. **Vision E2B — bramka decydująca**
- Decyzja + (jeśli PASS) pin na produkcji .20/.21/.19 z aktualizacją `docker-compose.yml`, `AGENTS.md`, configów; (jeśli FAIL) zostajemy na b10068 + dokumentacja wyników.
- Zweryfikowanie przy okazji, czy b10213-breaking changes (empty argv, slot save API, `--mmproj` osobno) są nadal aktualne na b10428 — tylko dokumentacyjnie, compose już je obsługuje.

### Non-Goals
- Kwantyzacja mmproj (odłożona — #26818 przywrócił możliwość, ale poza zakresem tego bumpu).
- Auto-detekcja typu MTP (#27005/#26814) — uproszczenie configu, bez wpływu na wydajność; osobna decyzja.
- Nowe modele (QAT E2B, Gemma4 12B QAT, DeepSeek V4, GLM-4.7-Flash, Qwen3-TTS/OCR itd.).
- Zmiany w `deploy/install-llama.sh` (zakazane wg AGENTS.md) i w `Dockerfile`.
- Testy backendów nie-CUDA (SYCL/OpenCL/Metal/Vulkan).
- Re-test b10213-specific issues poza dokumentacją.

## Assumptions
- Dev .38 (`root@192.168.200.38:/opt/llama`) jest dostępny i ma synced repo + cache buildowy.
- Obraz `:b10068` pozostaje dostępny (GHCR + cache na .38) jako rollback target; `:b10213` zostaje na .38.
- Bramka vision ma pierwszeństwo: jeśli E2B nie wróci do poziomu b10068 → FAIL niezależnie od wyników tekstowych.
- Progi bramek bazują na udokumentowanych baseline'ach b10068 (AGENTS.md, benchmarki 07-30 i 08-06).
- Build kompilowany na dev (jak poprzednio: `docker compose build --no-cache`, ~30 min); CI/master nie jest dotykany w tej fazie (nie pushujemy na master).

## Open Questions
- Czy regresja vision z b10213 faktycznie znika na b10428 (hipoteza #26802) — rozstrzygnie bramka 4.
- Czy `SPEC_DRAFT_N_MAX=1` pozostaje optymalne na nowym buildzie — rozstrzygnie bramka 3.
- Czy na b10428 pojawiły się nowe breaking changes względem b10213 — rozstrzygnie smoke test + dokumentacja.

## Tech Stack
- **llama.cpp:** `ggml-org/llama.cpp`, pin SHA `885c5bbe8` (b10428)
- **Obraz:** `ghcr.io/noxgle/llama-server:b10428` (budowany lokalnie na .38)
- **Hosting:** Docker Compose (`docker-compose.yml`, GPU przez `deploy.resources.reservations.devices`)
- **Dev/benchmark:** `llama.sh` (override `LLAMA_IMAGE=...:b10428`), `scripts/benchmark-guarded-remote.sh`, `scripts/benchmark-vision.sh`, `scripts/benchmark-draft-mtp.sh`
- **Konfigi:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`, `configs/gemma4-e2b-q4-k-m-mtp.env`
- **Sync:** `sync.sh push/deploy/health/status`

## Constraints
- GPU: RTX A2000 6 GB — VRAM limit jak dotąd (BATCH=3072/UBATCH=1536, ~86% VRAM dla Qwen; E2B na tej samej karcie).
- `--gpus all` ZABRONIONE (gotcha Docker 26 post-reboot) — tylko `deploy.resources.reservations.devices` / `--runtime=nvidia`.
- `.env` zmiany wymagają `docker compose down && up -d` (restart nie czyta `.env`).
- Brak push na master/CI w tej fazie; prod .20/.21/.19 nietknięte do decyzji.
- `deploy/install-llama.sh` — nie modyfikować.

## Architecture
Testowa architektura porównawcza A/B bez zmian w architekturze produkcyjnej:

```
dev .38: build b10428 (LLAMA_REF=885c5bbe8) → ghcr.io/noxgle/llama-server:b10428
  ├─ Bramka 1: smoke + guarded health (GPU aktywny, brak CPU fallback)
  ├─ Bramka 2: knowledge + long-context (Qwen3.6 Q4_K_M) vs baseline b10068
  ├─ Bramka 3: MTP sweep n_max 0/1/2/3 (Qwen3.6 Q4_K_M)
  ├─ Bramka 4: vision E2B (gen tok/s + TTFT) vs baseline 08-06 b10068  ← DECYDUJE
  └─ Decyzja → PASS: pin + rollout na .20/.21/.19 / FAIL: zostajemy na b10068
```

Baseline'y b10068 do porównania (udokumentowane w AGENTS.md):
- Knowledge: ~33.6 tok/s, 10/10 A, 24K tok; Long: ~32.8 tok/s; prefill 507 t/s @ 85.8K prompt
- Vision E2B (08-06): gen 114.3 tok/s, TTFT 167 ms

## Architecture Decisions

### ADR-001: Pin testowanego buildu do commit SHA, nie do ruchomego refa
**Decision:** Build z `LLAMA_REF=885c5bbe8` (dokładny SHA mastera; tożsamy z tagiem b10428).

**Alternatives:** `LLAMA_REF=b10428` (tag), `LLAMA_REF=master` (ruchomy ref).

**Rationale:** Powtarzalność — wynik testów musi być przypisany do jednoznacznego kodu; jak w AGENTS.md (pinowanie HF po SHA po usuniętych refach).

**Tradeoffs:** Konieczność ręcznej aktualizacji SHA przy kolejnych bumpach (koszt niski).

### ADR-002: Vision E2B jest bramką decydującą
**Decision:** Jeśli vision nie wróci do poziomu b10068 (gen ≥110 tok/s, TTFT ≤180 ms) → FAIL całego bumpu.

**Alternatives:** Decydować średnią ważoną tekst+vision; decydować tylko tekstem.

**Rationale:** To vision odrzuciło b10213; koszt utrzymania b10068 jest akceptowalny, a wdrożenie regresji vision na prod jest gorsze niż brak bumpu. Fail-fast: bramki tekstowe są tańsze, więc idą pierwsze, ale nie mogą nadpisać wyniku vision.

**Tradeoffs:** Możemy odrzucić bump z realnym zyskiem tekstowym, jeśli vision pozostanie wolniejsze (świadoma decyzja).

### ADR-003: Testy wyłącznie na dev .38, prod nietknięty do decyzji
**Decision:** Cały cykl na .38; rollout na .20/.21/.19 dopiero po PASS + akceptacji użytkownika.

**Alternatives:** Testy równolegle na prod z load-balancerem (nie istnieje); test na prod jako ostatni etap.

**Rationale:** Prod hostuje usługi (Qwen 33 tok/s, Gemma4 27 tok/s, Q5 30 tok/s); awaria bumpu na prod = przerwa dla użytkowników. Dev jest do tego przeznaczony.

**Tradeoffs:** Konfiguracja prod (Q5, warianty) może różnić się od dev — pokrywamy to przez guarded probes po wdrożeniu.

### ADR-004: b10068 pozostaje rollback target przez cały cykl
**Decision:** Nie nadpisujemy tagu `:b10068`; na .38 trzymamy obrazy b10068, b10213, b10428.

**Alternatives:** Nadpisać `:latest`; usunąć stare obrazy dla VRAM/HDD.

**Rationale:** Rollback musi być natychmiastowy (docker compose z pinem b10068 działa bez ponownego builda).

**Tradeoffs:** ~kilka GB dysku więcej na .38 (HDD ≥70 GB wg provisioning).

## Phases

### Phase 1: Build obrazu b10428 na dev .38

**Objective:** Świeży obraz b10428 (SHA `885c5bbe8`) zbudowany i oznaczony jako `ghcr.io/noxgle/llama-server:b10428`, obraz b10068 nietknięty.

**Prerequisites:** Dostęp SSH do .38, repo zsynchronizowane (`sync.sh push`), wolny dysk ≥30 GB, GPU wolne.

**Expected outcome:** `docker images` na .38 pokazuje `noxgle/llama-server:b10428` (oraz `:b10068`), brak zmian w repo poza ewentualnym plikiem wyników.

**Estimated effort:** ~30–45 min (build) + 15 min (tag/push opcjonalnie)

**Confidence:** High

- [x] **Task:** Weryfikacja refa upstream
  - **Description:** Potwierdzić, że master HEAD = `885c5bbe8e04dc78db25beb911a2715312ad7b54` (tag b10428) i że nie ma nowszych commitów w chwili startu.
  - **Files:** brak (tylko odczyt API/`git ls-remote`)
  - **Dependencies:** None
  - **Acceptance Criteria:**
    - SHA mastera zgadza się z `885c5bbe8` (lub udokumentowana nowsza wersja do akceptacji użytkownika)
  - **Verification:**
    - `git ls-remote https://github.com/ggml-org/llama.cpp.git refs/heads/master`

- [x] **Task:** Build obrazu b10428 na .38
  - **Description:** Na .38: `LLAMA_REF=885c5bbe8 docker compose build --no-cache` (docker-compose.yml przekazuje `LLAMA_REF` do Dockerfile). Następnie `docker tag` → `ghcr.io/noxgle/llama-server:b10428`. Nie dotykać `Dockerfile`, nie pushować na master.
  - **Files:** TBD na serwerze (brak zmian w repo po stronie lokalnej)
  - **Dependencies:** Task 1.1
  - **Acceptance Criteria:**
    - Build zakończony sukcesem, obraz istnieje z tagiem `:b10428`
    - Obraz `:b10068` nadal istnieje (rollback)
  - **Verification:**
    - `ssh root@192.168.200.38 'docker images | grep -E "b10068|b10428"'`
    - `ssh root@192.168.200.38 'docker run --rm ghcr.io/noxgle/llama-server:b10428 --version'` (oczekiwane `b10428` / build SHA)

- [x] **Task:** Smoke test + guarded health
  - **Description:** Uruchomić na .38 Qwen3.6 Q4_K_M z obrazem b10428 (`LLAMA_IMAGE=...:b10428 ./llama.sh start qwen` albo compose z override), sprawdzić guarded health i szybki probe throughput; zweryfikować w logach: GPU aktywny (VRAM > 0, brak `ggml_cuda_init: failed`), brak nowych błędów argumentów CLI (entrypoint filter działa jak dla b10213).
  - **Files:** `.env` na .38 (z `configs/qwen3.6-35ba3b-mtp-unsloth.env`), `llama.sh` bez zmian
  - **Dependencies:** Task 1.2
  - **Acceptance Criteria:**
    - Health HTTP 200, VRAM > 0 MiB
    - Serwer odpowiada na chat completions z sensownym `predicted_per_second` (≥25 tok/s)
    - W logach brak CPU fallback; ew. `graphs reused = N` widoczne
  - **Verification:**
    - `HOST=root@192.168.200.38 PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh` (fail = CPU fallback)
    - `ssh root@192.168.200.38 'curl -s http://localhost:8089/v1/chat/completions ...' | jq '.timings.predicted_per_second'`

### Phase 2: Bramki tekstowe (Qwen3.6 Q4_K_M)

**Objective:** Potwierdzić brak regresji tekstowej vs baseline b10068 (knowledge ~33.6 tok/s, long ~32.8 tok/s, prefill ≥500 t/s).

**Prerequisites:** Phase 1 (smoke OK)

**Expected outcome:** Raport porównawczy knowledge + long na b10428 vs b10068.

**Estimated effort:** ~60–90 min (knowledge suite ~13 min + long + powtórki)

**Confidence:** High

- [x] **Task:** Knowledge benchmark na b10428
  - **Description:** Uruchomić knowledge suite (skrypt jak w runach b10068 — `scripts/benchmark-knowledge.sh` na .38) z Qwen3.6 Q4_K_M na obrazie b10428; zapisać JSON/TXT w repo (konwencja `benchmark-kb-<ts>.json`).
  - **Files:** `benchmark-kb-<ts>.{json,txt}` (nowe pliki wyników w repo)
  - **Dependencies:** Phase 1
  - **Acceptance Criteria:**
    - Wyniki: ≥33.0 tok/s (próg −2% od baseline), jakość 10/10 A
    - Prefill ≥500 t/s przy długim prompcie
  - **Verification:**
    - Porównanie z `benchmark-kb-20260801-071412.*` (b10213) i baseline b10068 z AGENTS.md

- [x] **Task:** Long-context benchmark
  - **Description:** Benchmark długiego kontekstu (≥24K, cel ~85.8K prefill) na b10428; zapisać wyniki.
  - **Files:** `benchmark-kb-<ts>2.{json,txt}` lub sekcja w raporcie knowledge
  - **Dependencies:** Task 2.1
  - **Acceptance Criteria:**
    - ≥32.0 tok/s na long; prefill ≥500 t/s @ 85.8K
  - **Verification:**
    - Logi `llama_perf_context` / timings z benchmarku

### Phase 3: MTP sweep

**Objective:** Potwierdzić, że `SPEC_DRAFT_N_MAX=1` pozostaje optymalne i MTP nie regresowało na b10428.

**Prerequisites:** Phase 2 (lub równolegle po smoke, ale sekwencyjnie: po Phase 2 dla czystych wyników)

**Expected outcome:** Tabela tok/s + draft acceptance dla n_max 0/1/2/3 na b10428.

**Estimated effort:** ~30–45 min

**Confidence:** Medium

- [x] **Task:** Sweep `SPEC_DRAFT_N_MAX` 0/1/2/3
  - **Description:** `scripts/benchmark-draft-mtp.sh` na .38 z obrazem b10428 (skrypt używa `--runtime=nvidia`); zmieniać `SPEC_DRAFT_N_MAX` w configu/.env i mierzyć tok/s + acceptance rate.
  - **Files:** pliki wynikowe benchmarku, `.env` na .38
  - **Dependencies:** Phase 2
  - **Acceptance Criteria:**
    - n_max=1 nadal najlepsze (lub w granicach +/−2% od n_max=0)
    - Draft acceptance rate zbliżony do b10068 (~87%)
  - **Verification:**
    - Porównanie z poprzednimi wynikami w AGENTS.md (n_max=1 optymalne; n_max=2 +2%; n_max=3 −6%)

### Phase 4: Bramka vision E2B (DECYDUJĄCA)

**Objective:** Sprawdzić, czy regresja vision z b10213 zniknęła na b10428.

**Prerequisites:** Phase 1 (smoke); może być uruchamiana równolegle z Phase 2/3 jeśli GPU/konfigi na to pozwalają — sekwencyjnie dla determinizmu.

**Expected outcome:** Wyniki vision E2B na b10428 vs baseline b10068 08-06 (gen 114.3 tok/s, TTFT 167 ms).

**Estimated effort:** ~30–45 min

**Confidence:** Medium

- [x] **Task:** Vision benchmark E2B na b10428
  - **Description:** Przełączyć .38 na config `gemma4-e2b-q4-k-m-mtp.env` z obrazem b10428 (`docker compose down && up -d` po zmianie `.env` — restart NIE czyta .env), uruchomić `python3 scripts/benchmark-vision.sh` (HOST=root@192.168.200.38, PORT=8089), zapisać wyniki.
  - **Files:** `benchmark-vision-<ts>.{txt,json}` (nowe pliki wyników)
  - **Dependencies:** Phase 1
  - **Acceptance Criteria:**
    - gen ≥110 tok/s (próg −4% od 114.3) ORAZ TTFT ≤180 ms (próg ~+8% od 167)
    - Preferowane: gen ≈114 tok/s i TTFT ≈167 ms (zero regresji)
  - **Verification:**
    - Porównanie z `benchmark-vision-20260806-174717.*` (b10068) i `benchmark-vision-20260730-135338.*`
    - Ten wynik DECYDUJE o akceptacji bumpu (ADR-002)

### Phase 5: Decyzja i (opcjonalnie) rollout

**Objective:** Udokumentowana decyzja na podstawie bramek 1–4; jeśli PASS — pin b10428 i wdrożenie na prod.

**Prerequisites:** Wszystkie bramki 1–4 (wyniki zebrane), akceptacja użytkownika na rollout.

**Expected outcome:** Repo zaktualizowane (pin obrazu + AGENTS.md z nowymi baseline'ami/breaking changes) albo dokumentacja FAIL.

**Estimated effort:** 1–2 h (rollout 3 serwery + probes)

**Confidence:** High (decyzja), Medium (rollout bez regresji prod)

- [x] **Task:** Weryfikacja breaking changes b10213 vs b10428 (dokumentacja)
  - **Description:** Sprawdzić w logach smoke testów, czy: entrypoint filtruje puste argv (jak dla b10213), `--mmproj` flag+path działa, slot save/restore endpoint (`/slots/{id}?action=save`) działa na b10428; zanotować ewentualne nowe zmiany w AGENTS.md.
  - **Files:** `AGENTS.md` (sekcja o wersjach)
  - **Dependencies:** Phase 1
  - **Acceptance Criteria:**
    - Kompatybilność potwierdzona lub nowe breaking changes udokumentowane
  - **Verification:**
    - Logi serwera + `test-slot-save.sh` (jeśli dotyczy)

- [~] **Task (jeśli PASS):** Pin b10428 w repo
  - **Description:** W `docker-compose.yml` zmienić obraz na `ghcr.io/noxgle/llama-server:b10428`; zaktualizować AGENTS.md (aktualna wersja, SHA `885c5bbe8`, nowe baseliny, ewentualne gotchas); commit z konwencją repo.
  - **Files:** `docker-compose.yml`, `AGENTS.md`, ew. `configs/*.env` jeśli zmiana flag
  - **Dependencies:** Bramki 1–4 PASS + akceptacja użytkownika
  - **Acceptance Criteria:**
    - Repo pinuje b10428; AGENTS.md zawiera baseliny i SHA
  - **Verification:**
    - `git diff --stat`, `grep "b10428" docker-compose.yml AGENTS.md`

- [~] **Task (jeśli PASS):** Rollout na prod .20/.21/.19
  - **Description:** `./sync.sh deploy` na każdym serwerze prod (Qwen .20, Gemma4 .21, Qwen Q5 .19) + guarded health + probe throughput na każdym. Kolejność: najpierw jeden serwer (np. .19 Q5), potem pozostałe po potwierdzeniu.
  - **Files:** na serwerach: `.env` z `configs/*.env`, obraz b10428 (pull)
  - **Dependencies:** Task 5.2 + akceptacja użytkownika
  - **Acceptance Criteria:**
    - Na każdym serwerze: guarded health OK (HTTP 200, VRAM > 0), throughput w baseline (Qwen ~33, Gemma4 ~27, Q5 ~30 tok/s ±5%)
  - **Verification:**
    - `HOST=root@192.168.200.X PROJECT_DIR=/opt/llama bash scripts/benchmark-guarded-remote.sh` dla każdego X
    - `./sync.sh status` / `./sync.sh health`

- [x] **Task (jeśli FAIL):** Zostań na b10068 + dokumentacja
  - **Description:** Zanotować w AGENTS.md/TODO.md wyniki b10428 (w tym wyniki vision), powód FAIL, rekomendację ponownego testu po fixach upstream. Bez zmian w pinach.
  - **Files:** `AGENTS.md`, `TODO.md` (istniejący plan testów)
  - **Dependencies:** Bramka 4 FAIL
  - **Acceptance Criteria:**
    - Decyzja udokumentowana z danymi; repo bez zmian produkcyjnych
  - **Verification:**
    - `git status` — tylko pliki dokumentacyjne

## Rollout & Rollback
- **Rollout (PASS):** pull `:b10428` na .20/.21/.19 → `cp configs/<name>.env .env && docker compose down && up -d` → guarded probes. Kolejno serwer po serwerze (najpierw .19), z akceptacją użytkownika po każdym kroku.
- **Rollback:** obraz `:b10068` nadal w GHCR i cache'ach; revert pinu w `docker-compose.yml` (git revert commita z Task 5.2) + `down && up -d`. Przewidywany czas przywrócenia: <5 min/serwer.
- **GPU watchdog** (jeśli wdrożony na serwerze) sam wykryje CPU fallback — dodatkowa siatka bezpieczeństwa.

## Observability
- Guarded health: HTTP 200 + VRAM + RAM (`benchmark-guarded-remote.sh`, `sync.sh health`).
- Logi serwera: `ggml_cuda_init` (GPU aktywny), `graphs reused = N` (CUDA graph caching), MTP acceptance, `llama_perf_context` (prefill/tok/s, TTFT).
- Wyniki benchmarków: pliki `benchmark-*.{json,txt}` w repo (konwencja z timestampem).

## Security Considerations
- Brak nowych sekretów/portów; obrazy z publicznego GHCR (`ghcr.io/noxgle/llama-server`).
- Zmiany tylko na dev .38 do czasu decyzji; prod nietknięty.
- `deploy/install-llama.sh` i `Dockerfile` poza zakresem (zakaz z AGENTS.md).

## Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Regresja vision E2B utrzymuje się na b10428 | Wysoki (odrzucenie bumpu) | Średni | Decydująca bramka vision (ADR-002); zostajemy na b10068 i czekamy na fixy upstream |
| Nowe regresje w 215 commitach (MTP, prefill, API) | Średni | Niski | Bramki tekstowe + MTP sweep + smoke przed decyzją |
| Build b10428 się nie powiedzie (toolchain CUDA, dysk) | Średni | Niski | Build na .38 (znana procedura ~30 min), dysk ≥70 GB; b10068 nietknięty |
| Breaking changes CLI/API względem b10213 (empty argv itd.) | Średni | Niski | Entrypoint już filtruje puste argv (b10068-compatible); smoke test + Task 5.1 |
| `.env` nie przeczytany po `restart` | Niski | Wysoki (znana gotcha) | Zawsze `down && up -d` przy zmianach `.env` |
| Rollout na prod powoduje regresję konfiguracji (Q5, warianty) | Średni | Niski | Sekwencyjny rollout (najpierw .19), guarded probes po każdym serwerze, rollback <5 min |

## Project Acceptance Criteria
- [x] Obraz b10428 (SHA `885c5bbe8`) zbudowany na .38, b10068 zachowany (Phase 1)
- [x] Bramki 1–3 zaliczone: smoke OK, knowledge ≥33.0 tok/s 10/10 A, long ≥32.0 tok/s, prefill ≥500 t/s, MTP n_max=1 nadal optymalne (Phase 2–3)
- [x] Bramka 4 rozstrzygnięta: vision E2B gen ≥110 tok/s i TTFT ≤180 ms (Phase 4)
- [x] Decyzja udokumentowana w repo z danymi benchmarków (Phase 5)
- [x] FAIL → b10068 bez zmian produkcyjnych (vision gen 99.8 vs 114.6 = −12.9%, ADR-002)

## Results (2026-08-14) — DECISION: FAIL, stay on b10068

### Phase 1 — Build & smoke: PASS
- Master moved on: `885c5bbe8` (tag b10428) confirmed; newer `4c1a0af4`/b10429 exist — tested pinned b10428 per plan.
- Image `ghcr.io/noxgle/llama-server:b10428` built on .38 (`LLAMA_REF=885c5bbe8`, `--no-cache`, ~30 min). `:b10068` untouched (rollback OK).
- **New finding:** `-hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:5bc3e23...` fails (`get_hf_plan: no GGUF files found`) on **both** b10068 and b10428 — known unsloth repo re-upload issue, NOT a b10428 regression. Workaround `MODEL_FLAG=-m` + local symlink works. (Already documented in AGENTS.md HF download bug; now confirmed as build-independent.)
- Guarded benchmark PASS: smoke 34.6 tok/s, short 33.8–34.5, long 32.8–33.3, no CPU fallback. CUDA graphs active (`graphs reused = N`).

### Phase 2 — Text gates: PASS
- Knowledge (10/10 tasks, all stop): **avg 33.8 tok/s** (baseline 33.6; gate ≥33.0). Draft acceptance 83–97%. File: `benchmark-kb-20260814-160503.{json,txt}`.
- Long-context (85.8K prompt): prefill **504 t/s** (gate ≥500; baseline 507), gen 27.8 tok/s (vs b10213 27.6).

### Phase 3 — MTP sweep: PASS (ordering unchanged)
| n_max | tok/s | vs off |
|-------|-------|--------|
| 1 | 32.42 | +4.8% |
| 2 | 32.26 | +4.3% |
| off | 30.94 | — |
| 3 | 29.01 | −6.2% |
| 4 | 27.36 | −11.6% |

`SPEC_DRAFT_N_MAX=1` remains optimal. Script note: `benchmark-draft-mtp.sh` needs `-v /opt/llama/models:/models:ro` when running `MODEL_FLAG=-m` (used `-hf` before).

### Phase 4 — Vision E2B: **FAIL (deciding gate, ADR-002)**
Same-day control run on b10068 for a fair comparison:
| Build | gen (baseline) | TTFT | Δ gen |
|-------|---------------|------|-------|
| b10068 (control 08-14) | **114.6 tok/s** | 167 ms | — |
| b10068 (ref 07-30) | 114.3 tok/s | 167 ms | — |
| **b10428** | **99.8 tok/s** | 168 ms | **−12.9%** ❌ |
| b10213 (ref) | 102.9 tok/s | 213 ms | −10.0% |

- TTFT fixed vs b10213 (168 vs 213 ms), but **gen speed still −12.9%** (gate ≥110 tok/s NOT met).
- #26802 (CUDA graphs for quantized MoE) did NOT fix the E2B vision path — E2B is a dense model, graphs help Qwen MoE text only.
- Files: `benchmark-vision-20260814-171342.*` (b10428), `benchmark-vision-20260814-173513.*` (b10068 control).

### Phase 5 — Decision & docs: FAIL path
- b10213 breaking changes confirmed still valid on b10428: empty argv rejection (entrypoint filter OK), slot API `POST /slots/{id}?action=save|restore` + `filename` body (old `/slots/{id}/save` → 404), `--mmproj` separate flag+path. No NEW breaking changes found.
- **Decision: stay on b10068.** No repo pin changes, no prod rollout. b10428 image cached on .38 for future re-tests.
- Re-test after upstream fixes the E2B generation regression.

## Estimated Timeline
- Phase 1 (build+smoke): ~1 h
- Phase 2 (tekst): ~1.5 h
- Phase 3 (MTP): ~0.5 h
- Phase 4 (vision): ~0.5 h
- Phase 5 (decyzja/rollout): 0.5–2 h
- **Razem: ~1 dzień roboczy.** Dominująca niepewność: wynik bramki vision (determinuje PASS/FAIL i czas rolloutu).
- **Actual (2026-08-14): ~4 h incl. build; verdict FAIL on vision gate (ADR-002).**
