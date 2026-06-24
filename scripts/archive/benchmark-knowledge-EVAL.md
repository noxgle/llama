# Knowledge Benchmark Evaluation v2 — Unlimited Tokens

**Date:** 2026-06-24  
**Model:** Gemma4 26B Q4_K_M + MTP (draft-mtp)  
**Server:** 192.168.200.21 (Debian 13, RTX A2000 6 GB)  
**Context:** 131072 (128K)  
**Flags:** `MODEL_FLAG=-m`, `DRAFT_FLAG=-md`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`  
**Timeout:** 300s per task (was 180s)  
**Max tokens:** Unlimited (was 200-500 per task)

## Results

| # | Task | tok/s | tokens | Grade | Change vs v1 |
|---|------|-------|--------|-------|-------------|
| 1 | Data Analysis | 29.1 | 696 | **A** | B- → **A** |
| 2 | Python Programming | 26.8 | 1769 | **A** | A → A (=) |
| 3 | Logic Puzzle | 26.3 | 1418 | **A** | C → **A** (+2) |
| 4 | Mathematics | 29.0 | 997 | **A** | B- → **A** |
| 5 | Networking Knowledge | 24.6 | 1632 | **A** | B+ → **A** |
| 6 | Creative Writing | 24.1 | 916 | **A** | A → A (=) |
| 7 | Code Review | 26.2 | 1809 | **A** | A → A (=) |
| 8 | SQL Query | 25.9 | 2543 | **A** | truncated → **A** (new) |
| 9 | Explain Like I'm 5 | 26.4 | 879 | **A** | B → **A** |
| 10 | Algorithm Design | 26.0 | 1889 | **A** | A → A (=) |

## Summary

| Metric | v1 (truncated) | v2 (unlimited) | Change |
|--------|:--------------:|:--------------:|:------:|
| Avg speed | 26.6 tok/s | 26.4 tok/s | -0.2 |
| Avg draft acc | 89.7% | 89.3% | -0.4% |
| Total tokens | ~4,500 | **14,548** | +223% |
| Finish reasons | stop+length | **stop (100%)** | ✅ |
| Tasks fully completed | 4/10 | **10/10** | +6 |
| Overall grade | B+ (3.20) | **A (4.00)** | +0.80 |

## Key Findings

1. **Głównym problemem był brak tokenów, nie jakość modelu.** Model zawsze generował poprawne treści — ale był ucinany w połowie chain-of-thought. Po usunięciu limitu wszystkie 10 zadań dostało A.

2. **Największy skok:** Logic Puzzle (C → A). Poprzednio model miał tylko 400 tokenów na rozwiązanie — z 1418 tokenami rozwiązał je perfekcyjnie krok po kroku.

3. **Speed stability:** Generowanie 3× więcej treści nie wpłynęło na speed (26.4 vs 26.6 tok/s). Draft acceptance spadł minimalnie (89.7% → 89.3%).

4. **SQL Query** (2543 tokeny) — najdłuższe zadanie. Wcześniej ucięte po ~500 tokenach, teraz pełne zapytanie z CTE, GROUP BY, HAVING, window functions.

5. **ELI5** (879 tokenów) — poprzednio limit 200 tokenów zmuszał do urwania mid-sentence. Teraz pełne wytłumaczenie z analogiami.

## Konkluzja

Gemma4 26B Q4_K_M + MTP **nie ma problemów z jakością odpowiedzi** przy odpowiedniej przestrzeni na generowanie. Chain-of-thought i kod wymagają 1000-2500 tokenów na zadanie. Dotychczasowe benchmarki z max_tokens=200-500 zaniżały rzeczywistą jakość modelu.

**Rekomendacja:** Przy testowaniu modeli (zwłaszcza code/math/logic) zawsze używać max_tokens ≥ 2000 lub bez limitu, z timeoutem ≥ 5 min.
