# Knowledge Benchmark — Multi-Model Comparison

## Comparison Table

| # | Model / Config | Speed | Draft% | Total tok | Total time | Grade | Data | Python | Logic | Math | Network | Creative | Review | SQL | ELI5 | Algo |
|---|---------------|-------|--------|-----------|------------|-------|------|--------|-------|------|---------|----------|--------|-----|------|------|
| 1 | **Gemma4 26B Q4_K_M+MTP** (unlimited) | 27.3 | 89.6% | 14,574 | **9.7 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 2 | **Qwen3.6 35B A3B MTP** (unlimited) | 29.1 | 83.1% | 30,973 | **18.0 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 3 | *(twój następny model)* | | | | | | | | | | | | | | | |

<!-- Dodawaj kolejne wiersze od #3 w górę. Kolumny: Speed (tok/s), Draft% (draft accept rate), Total tok, Total time, Grade (overall), Data/.../Algo (oceny per task, A-F) -->

### Model Comparison Highlights

| Aspekt | Gemma4 26B Q4_K_M+MTP | Qwen3.6 35B A3B MTP |
|--------|----------------------|-------------------|
| **Speed** | 27.3 tok/s | **29.1 tok/s** (+7%) |
| **Draft accept** | **89.6%** | 83.1% |
| **Total tokens** | **14,574** (concise) | 30,973 (verbose) |
| **Total time** | **9.7 min** | 18.0 min |
| **Tasks completed** | 10/10 (A) | 10/10 (A) |
| **Server** | 192.168.200.21 (RTX A2000) | 192.168.200.20 (RTX A2000) |
| **Context** | 131K | 160K |

*Qwen jest szybszy w tok/s, ale generuje 2× więcej treści przez co łącznie trwa 2× dłużej. Gemma4 jest bardziej zwięzła i efektywna czasowo.*

## Detailed Results

---

### #1  Gemma4 26B Q4_K_M + MTP (unlimited) — 2026-06-24

**Config file:** `configs/gemma4-26b-q4-k-m-mtp.env`  
**Server:** 192.168.200.21 (Debian 13 trixie, RTX A2000 6 GB)  
**Flags:** `MODEL_FLAG=-m`, `DRAFT_FLAG=-md`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`  
**Context:** 131072 (128K)  
**Timeout:** 300s | **Max tokens:** unlimited  

| # | Task | tok/s | tokens | time | Grade |
|---|------|-------|--------|------|-------|
| 1 | Data Analysis | 30.1 | 713 | 25s | **A** |
| 2 | Python Programming | 27.3 | 2584 | 96s | **A** |
| 3 | Logic Puzzle | 27.8 | 1561 | 57s | **A** |
| 4 | Mathematics | 30.5 | 1031 | 35s | **A** |
| 5 | Networking Knowledge | 25.5 | 1651 | 66s | **A** |
| 6 | Creative Writing | 25.3 | 925 | 37s | **A** |
| 7 | Code Review | 27.6 | 1827 | 67s | **A** |
| 8 | SQL Query | 26.8 | 2804 | 106s | **A** |
| 9 | Explain Like I'm 5 | 25.8 | 723 | 29s | **A** |
| 10 | Algorithm Design | 26.9 | 1755 | 66s | **A** |

**Key findings:**
- Wszystkie 10 zadań zaliczone celująco (A). Łączny czas: **9.7 min**.
- SQL Query (106s) najdłuższe zadanie; Data Analysis najszybsze (25s).
- Speed stabilny ~27.3 tok/s, draft acceptance wysoki (89.6%).

**Konkluzja:** Gemma4 26B Q4_K_M+MTP — zwięzły i efektywny. Dobry wybór gdy zależy na szybkiej odpowiedzi.

---

### #2  Qwen3.6 35B A3B MTP (unlimited) — 2026-06-24

**Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`  
**Server:** 192.168.200.20 (Debian 13 trixie, RTX A2000 6 GB)  
**Flags:** `-hf unsloth/...`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`  
**Context:** 163840 (160K)  
**Timeout:** 300s | **Max tokens:** unlimited  

| # | Task | tok/s | tokens | time | Grade |
|---|------|-------|--------|------|-------|
| 1 | Data Analysis | 31.4 | 1572 | 51s | **A** |
| 2 | Python Programming | 30.1 | 3368 | 113s | **A** |
| 3 | Logic Puzzle | 30.3 | 2371 | 79s | **A** |
| 4 | Mathematics | 31.4 | 1326 | 43s | **A** |
| 5 | Networking Knowledge | 27.3 | 2402 | 89s | **A** |
| 6 | Creative Writing | 30.3 | 6235 | 207s | **A** |
| 7 | Code Review | 29.6 | 4310 | 147s | **A** |
| 8 | SQL Query | 28.2 | 4670 | 167s | **A** |
| 9 | Explain Like I'm 5 | 26.0 | 928 | 37s | **A** |
| 10 | Algorithm Design | 26.2 | 3791 | 146s | **A** |

**Key findings:**
- Najszybszy model w benchmarku: **29.1 tok/s**.
- Łączny czas: **18 minut** na 10 zadań.
- Bardzo gadatliwy: **30,973 tokenów** vs Gemma4 14,548 — 2× więcej treści dla tych samych promptów.
- Niższy draft acceptance (83.5% vs 89.3%) — MTP mniej efektywne niż u Gemmy.
- Python Programming (5933 tok) i Creative Writing (4211 tok) — najbardziej rozbudowane odpowiedzi.
- Jakość celująca (A) we wszystkich zadaniach, podobnie jak Gemma4.

---

### #3  *(twój następny model)*

<!--
Wzór do skopiowania:

### #N  NazwaModelu — YYYY-MM-DD

**Config file:** `configs/nazwa-modelu.env`
**Server:** host (OS, GPU)
**Flags:** `...`
**Context:** ...
**Timeout:** ... | **Max tokens:** ...

| # | Task | tok/s | tokens | Grade |
|---|------|-------|--------|-------|
| 1 | Data Analysis | | | |
| ... | ... | | | |

**Key findings:**
- ...
-->

## Notes

- Wszystkie benchmarki wykonywane tym samym skryptem: `scripts/benchmark-knowledge.sh`
- Jednolite zadania (10), te same prompt'y — tylko model/config się zmienia
- Grade per task: A (celujący), B (dobry), C (słaby), D/F (niedostateczny)
- Grade overall: średnia ważona ocen per task
