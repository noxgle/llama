# Knowledge Benchmark — Multi-Model Comparison

## Comparison Table

| # | Model / Config | Speed | Draft% | Total tok | Total time | Grade | Data | Python | Logic | Math | Network | Creative | Review | SQL | ELI5 | Algo |
|---|---------------|-------|--------|-----------|------------|-------|------|--------|-------|------|---------|----------|--------|-----|------|------|
| 1 | **Gemma4 26B Q4_K_M+MTP** (unlimited) | 27.3 | 89.6% | 14,574 | **9.7 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 2 | **Qwen3.6 35B A3B MTP** (unlimited) | 29.1 | 83.1% | 30,973 | **18.0 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 3 | **Qwen3.6 35B A3B MTP Q5_K_M** (unlimited) | 27.5 | 82.0% | 33,080 | **20.5 min** | **A** | A | A | A | A | A | A | A | A | A | A |

<!-- Add rows from #3 upwards. Columns: Speed (tok/s), Draft% (draft accept rate), Total tok, Total time, Grade (overall), Data/.../Algo (per-task grades A-F) -->

### Model Comparison Highlights

| Aspect | Gemma4 26B Q4_K_M+MTP | Qwen3.6 35B A3B MTP (Q4) | Qwen3.6 35B A3B MTP (Q5) |
|--------|----------------------|-------------------------|-------------------------|
| **Speed** | 27.3 tok/s | **29.1 tok/s** (+7%) | 27.5 tok/s (+1%) |
| **Draft accept** | **89.6%** | 83.1% | 82.0% |
| **Total tokens** | **14,574** (concise) | 30,973 (verbose) | 33,080 (most verbose) |
| **Total time** | **9.7 min** | 18.0 min | 20.5 min |
| **Tasks completed** | 10/10 (A) | 10/10 (A) | 10/10 (A) |
| **Server** | 192.168.200.21 | 192.168.200.20 | 192.168.200.19 |
| **GPU** | RTX A2000 6 GB (5415/6138 MiB used) | RTX A2000 6 GB (~4473/6144 MiB used) | RTX A2000 6 GB (~5471/6138 MiB used) |
| **CPU** | 6 cores (Intel Xeon) | 6 cores (Intel Xeon) | 6 cores (Intel Xeon) |
| **RAM** | 30 GB (~15 GiB used) | 30 GB (~20 GiB used) | 30 GB (~20 GiB used) |
| **Context** | 131K (Q4_0 KV cache) | 160K (Q4_0 KV cache) | 160K (Q4_0 KV cache) |

*Qwen Q4 is fastest in tok/s. Q5 is the most verbose (33,080 tokens), beating even Q4's verbosity. Gemma4 remains the most time-efficient.*

## Detailed Results

---

### #1  Gemma4 26B Q4_K_M + MTP (unlimited) — 2026-06-24

**Config file:** `configs/gemma4-26b-q4-k-m-mtp.env`  
**Server:** 192.168.200.21 (Debian 13 trixie, Proxmox LXC)  
**GPU:** RTX A2000 6 GB (Ampere, Tensor Cores) — 5415/6138 MiB used  
**CPU:** 6 cores (Intel Xeon)  
**RAM:** 30 GB (~15 GiB used)  
**Flags:** `MODEL_FLAG=-m`, `DRAFT_FLAG=-md`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`  
**Context:** 131072 (128K, Q4_0 KV cache)  
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
- All 10 tasks completed with top marks (A). Total time: **9.7 min**.
- SQL Query (106s) the longest; Data Analysis fastest (25s).
- Stable speed ~27.3 tok/s, high draft acceptance (89.6%).

**Takeaway:** Gemma4 26B Q4_K_M+MTP — concise and efficient. A good choice when fast response time matters.

---

### #2  Qwen3.6 35B A3B MTP (unlimited) — 2026-06-24

**Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`  
**Server:** 192.168.200.20 (Debian 13 trixie, Proxmox LXC)  
**GPU:** RTX A2000 6 GB (Ampere, Tensor Cores) — ~4473/6144 MiB used  
**CPU:** 6 cores (Intel Xeon)  
**RAM:** 30 GB (~20 GiB used)  
**Flags:** `-hf unsloth/...`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`  
**Context:** 163840 (160K, Q4_0 KV cache)  
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
- Fastest model in the benchmark: **29.1 tok/s**.
- Total time: **18 minutes** for 10 tasks.
- Very verbose: **30,973 tokens** vs Gemma4 14,548 — 2× more content for the same prompts.
- Lower draft acceptance (83.5% vs 89.3%) — MTP less effective than Gemma4.
- Python Programming (5933 tok) and Creative Writing (4211 tok) — the most elaborate responses.
- Top quality (A) across all tasks, same as Gemma4.

---

### #3  Qwen3.6 35B A3B MTP Q5_K_M (unlimited) — 2026-06-26

**Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth-q5.env`
**Server:** 192.168.200.19 (Debian 13 trixie, Proxmox LXC)
**GPU:** RTX A2000 6 GB (Ampere, Tensor Cores) — ~5471/6138 MiB used
**CPU:** 6 cores (Intel Xeon)
**RAM:** 30 GB (~20 GiB used)
**Flags:** `MODEL_FLAG=-m /models/qwen-q5-k-m.gguf`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=2`
**Context:** 163840 (160K, Q4_0 KV cache)
**Timeout:** 300s | **Max tokens:** unlimited

| # | Task | tok/s | tokens | time | Grade |
|---|------|-------|--------|------|-------|
| 1 | Data Analysis | 29.3 | 948 | 34s | **A** |
| 2 | Python Programming | 27.6 | 4242 | 155s | **A** |
| 3 | Logic Puzzle | 27.6 | 3587 | 132s | **A** |
| 4 | Mathematics | 28.9 | 1290 | 46s | **A** |
| 5 | Networking Knowledge | 25.3 | 2058 | 82s | **A** |
| 6 | Creative Writing | 26.8 | 2517 | 95s | **A** |
| 7 | Code Review | 27.5 | 3466 | 128s | **A** |
| 8 | SQL Query | 26.7 | 10,905 | 408s | **A** |
| 9 | Explain Like I'm 5 | 27.5 | 976 | 37s | **A** |
| 10 | Algorithm Design | 27.3 | 3091 | 114s | **A** |

**Key findings:**
- All 10 tasks completed with top marks (A). SQL Query took 408s and generated 10,905 tokens — the most verbose response in the whole benchmark.
- Average speed: **27.5 tok/s** — 5% slower than Qwen Q4 (29.1), but similar throughput per-task.
- SQL Query was the longest task (408s, 10,905 tok) — the model went into great detail with CTE, correlated subquery, and multiple explanation sections. Previous timeout (300s) was simply not enough for this level of verbosity.
- Draft acceptance (82.0%) slightly lower than Q4 (83.1%) and significantly lower than Gemma4 (89.6%).
- Highest draft rates on simple tasks: Data Analysis (92%), Mathematics (91%).
- Lowest draft rate: Networking Knowledge (71%) — likely due to structured list-style output.
- Total tokens: **33,080** — the most verbose of any benchmarked model (Q4: 30,973, Gemma4: 14,574).
- Q5 gen speed is ~26-29 tok/s across tasks, consistent and stable.
- VRAM usage higher than Q4 (5471 vs 4473 MiB — +998 MiB), leaving less headroom for long contexts.

**Takeaway:** Q5_K_M is a quality upgrade, matching Q4 in completeness (10/10 A). However, it is the most verbose model tested — 33,080 total tokens, beating even Q4's verbosity (30,973). The SQL Query alone produced 10,905 tokens with multiple alternative solutions. Best suited when quality is prioritised and response length is not a concern.

## Notes

- All benchmarks run with the same script: `scripts/benchmark-knowledge.sh`
- Identical tasks (10), same prompts — only model/config changes
- Per-task grade: A (excellent), B (good), C (weak), D/F (failing)
- Overall grade: weighted average of per-task grades
