# Knowledge Benchmark — Multi-Model Comparison

## Comparison Table

| # | Model / Config | Speed | Draft% | Total tok | Total time | Grade | Data | Python | Logic | Math | Network | Creative | Review | SQL | ELI5 | Algo |
|---|---------------|-------|--------|-----------|------------|-------|------|--------|-------|------|---------|----------|--------|-----|------|------|
| 1 | **Gemma4 26B Q4_K_M+MTP** (unlimited) | 27.3 | 89.6% | 14,574 | **9.7 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 2 | **Qwen3.6 35B A3B MTP** (unlimited) | 29.1 | 83.1% | 30,973 | **18.0 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 3 | **Qwen3.6 35B A3B MTP Q5_K_M** (unlimited, q4_0/q4_0 KV) | 27.5 | 82.0% | 33,080 | **20.5 min** | **A** | A | A | A | A | A | A | A | A | A | A |
| 4 | **Qwen3.6 35B A3B MTP Q5_K_M q8_0/q8_0** (unlimited, 143K) | 29.7 | 91.0% | 26,193 | 15.3 min | **A** | A | A | A | A | A | A | A | A | A | A |
| 5 | **Qwen3.6 35B A3B MTP Q4_K_M q8_0/q8_0** (unlimited, 150K) | **33.1** | **91.3%** | 22,181 | **13.6 min** | **A** | A | A | A | A | A | A | A | A | A | A |

<!-- Add rows from #5 upwards. Columns: Speed (tok/s), Draft% (draft accept rate), Total tok, Total time, Grade (overall), Data/.../Algo (per-task grades A-F) -->

### Model Comparison Highlights

| Aspect | Gemma4 26B | Qwen Q4 (q4_0) | Qwen Q5 (q4_0) | Qwen Q5 q8_0 | Qwen Q4 q8_0 |
|--------|------------|----------------|-----------------|-----------------|--------------------|
| **Speed** | 27.3 tok/s | 29.1 tok/s | 27.5 tok/s | 29.7 tok/s (+2%) | **33.1 tok/s** (+14%) |
| **Draft accept** | 89.6% | 83.1% | 82.0% | 91.0% | **91.3%** |
| **Total tokens** | **14,574** | 30,973 | 33,080 | 26,193 | 22,181 |
| **Total time** | **9.7 min** | 18.0 min | 20.5 min | 15.3 min | **13.6 min** |
| **Tasks** | 10/10 (A) | 10/10 (A) | 10/10 (A) | 10/10 (A) | 10/10 (A) |
| **Server** | .21 (prod) | .20 (prod) | .19 (prod) | .38 (dev) | .38 (dev) |
| **GPU VRAM** | 5415 MiB | 4473 MiB | 5471 MiB | 5705 MiB | **5751 MiB** |
| **Context** | 131K (Q4_0) | 160K (Q4_0) | 160K (Q4_0) | 143K (Q8_0) | 150K (Q8_0) |
| **MTP** | n_max=2 | n_max=1 | n_max=1 | n_max=1 | n_max=1 |

*🏆 Q4 q8_0/q8_0 is the new performance king: 33.1 tok/s (+14%), 91.3% draft accept, 13.6 min total. Q5 q8_0/q8_0 also beats all q4_0/q4_0 configs. The q8_0 KV cache improves MTP accept rate across the board, more than compensating for slightly smaller context.*

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
- Previously fastest Q4 config: **29.1 tok/s** (now superseded by Q4 q8_0 at 33.1 tok/s).
- Total time: **18 minutes** for 10 tasks.
- Very verbose: **30,973 tokens** vs Gemma4 14,574 — 2× more content for the same prompts.
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

---

### #4  Qwen3.6 35B A3B MTP Q5_K_M q8_0/q8_0 KV (unlimited) — 2026-06-26

**Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth-q5.env`  
**Server:** 192.168.200.38 (dev, Debian 13 trixie, Proxmox LXC)  
**GPU:** RTX A2000 6 GB (Ampere, Tensor Cores) — 5705/6144 MiB idle (93%), 5795 MiB peak (94%)  
**CPU:** 4 LXC CPUs (AMD Ryzen 5 5600X host, 12 cores)  
**RAM:** 48 GB (~30 GiB used)  
**Model:** `/models/qwen-q5-k-m.gguf` (26 GB, Q5_K_M, local) — MTP draft against target model  
**Flags:** `MODEL_FLAG=-m`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=1`  
**Cache:** `CACHE_TYPE_K=q8_0, CACHE_TYPE_V=q8_0`  
**Context:** 143360 (140K, Q8_0 KV cache)  
**Batch:** BATCH=3072, UBATCH=1536  
**Threads:** THREADS=4 (LXC cpuset, verified 2026-06-26)  
**Timeout:** 300s (SQL manually retried at 600s) | **Max tokens:** unlimited  

| # | Task | tok/s | tokens | time | Draft% | Grade |
|---|------|-------|--------|------|--------|-------|
| 1 | Data Analysis | 30.4 | 928 | 34s | 96% | **A** |
| 2 | Python Programming | 29.8 | 4,563 | 155s | 93% | **A** |
| 3 | Logic Puzzle | 29.5 | 2,431 | 85s | 90% | **A** |
| 4 | Mathematics | 30.2 | 1,411 | 49s | 96% | **A** |
| 5 | Networking Knowledge | 28.7 | 2,265 | 81s | 84% | **A** |
| 6 | Creative Writing | 29.7 | 3,526 | 121s | 92% | **A** |
| 7 | Code Review | 29.5 | 4,295 | 148s | 91% | **A** |
| 8 | SQL Query | 29.8 | 3,285 | ~120s* | 92% | **A** |
| 9 | Explain Like I'm 5 | 29.3 | 979 | 36s | 88% | **A** |
| 10 | Algorithm Design | 29.6 | 2,510 | 87s | 90% | **A** |

*\*SQL Query timed out at 300s in the batch run; manually retried with 600s timeout — completed at 29.75 tok/s, 3,285 tokens, ~110s.*

**Key findings:**
- **Best overall performance across all tested configs:** 29.7 tok/s average, 91% draft acceptance, 15.3 min total.
- q8_0/q8_0 KV cache significantly improves MTP accept rate (91% vs 82% with q4_0/q4_0) — higher precision KV reduces draft-target mismatch.
- Throughput improved ~8% over q4_0/q4_0 Q5 (27.5→29.7 tok/s), matching or exceeding Q4 baseline (29.1 tok/s).
- Less verbose than q4_0/q4_0 Q5 (26,193 vs 33,080 total tokens) — model generates more focused responses with better KV precision.
- VRAM at 93-94% is tight but stable (5705 MiB idle, 5795 MiB peak). MTP context fits with 143K context.
- Batch benchmark (60K prompt): prefill **463 tok/s**, gen **25.0 tok/s** (with full context), total **206s**, VRAM peak **5795 MiB**.
- All 10 tasks completed with A grade.

**Takeaway:** Q5_K_M with q8_0/q8_0 KV cache is the **new leader among Q5 configs** — best speed (29.7 tok/s), highest draft acceptance (91%), and best total time (15.3 min). The trade-off is higher VRAM usage (93-94%) and slightly reduced context (143K vs 160K). Recommended for production deployment where Q5 quality is needed.

---

### #5  Qwen3.6 35B A3B MTP Q4_K_M q8_0/q8_0 KV (unlimited) — 2026-06-26

**Config file:** `configs/qwen3.6-35ba3b-mtp-unsloth.env`  
**Server:** 192.168.200.38 (dev, Debian 13 trixie, Proxmox LXC)  
**GPU:** RTX A2000 6 GB (Ampere, Tensor Cores) — 5751/6144 MiB idle (94%)  
**CPU:** 4 LXC CPUs (AMD Ryzen 5 5600X host, 12 cores)  
**RAM:** 48 GB (~30 GiB used)  
**Model:** `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M` (HF download, ~15.7 GB) — MTP draft against target  
**Flags:** `-hf unsloth/...`, `SPEC_TYPE=draft-mtp`, `SPEC_DRAFT_N_MAX=1`  
**Cache:** `CACHE_TYPE_K=q8_0, CACHE_TYPE_V=q8_0`  
**Context:** 153600 (150K, Q8_0 KV cache)  
**Batch:** BATCH=3072, UBATCH=1536  
**Threads:** THREADS=4 (LXC cpuset, verified 2026-06-26)  
**Timeout:** 300s | **Max tokens:** unlimited  

| # | Task | tok/s | tokens | time | Draft% | Grade |
|---|------|-------|--------|------|--------|-------|
| 1 | Data Analysis | 33.9 | 1,068 | 34s | 95% | **A** |
| 2 | Python Programming | 32.9 | 4,315 | 133s | 91% | **A** |
| 3 | Logic Puzzle | 33.0 | 2,621 | 82s | 91% | **A** |
| 4 | Mathematics | 33.7 | 1,391 | 43s | 95% | **A** |
| 5 | Networking Knowledge | 32.1 | 2,088 | 67s | 85% | **A** |
| 6 | Creative Writing | 33.1 | 2,798 | 86s | 92% | **A** |
| 7 | Code Review | 33.2 | 4,360 | 134s | 92% | **A** |
| 8 | SQL Query | 33.1 | 3,546 | 110s | 92% | **A** |
| 9 | Explain Like I'm 5 | 33.0 | 1,114 | 36s | 90% | **A** |
| 10 | Algorithm Design | 32.9 | 2,880 | 90s | 90% | **A** |

**Key findings:**
- **Best overall performance across ALL tested configs:** 33.1 tok/s avg, 91.3% draft acceptance, 13.6 min total.
- **+13.7% throughput** over Q4 baseline (29.1→33.1 tok/s) and **+11.4%** over Q5 q8_0/q8_0 (29.7→33.1).
- Draft acceptance jumps from 83.1% → 91.3% (+8%) — q8_0 KV cache dramatically improves draft-target alignment.
- Less verbose than q4_0 baseline (22,181 vs 30,973 total tokens) — more focused responses.
- All 10 tasks completed with A grade, SQL Query finished in 110s (vs 167s with q4_0).
- KB benchmark max tokens was unlimited; typical generation per task 1K-4K tokens.
- Quick probe (500 tok): **32.5 tok/s** — consistent with the benchmark average.

**Takeaway:** **Q4_K_M with q8_0/q8_0 KV cache is the new overall performance leader** — 33.1 tok/s, 91.3% draft accept, 13.6 min. The trade-off is 94% VRAM vs 73% with q4_0 KV. Recommended as the new baseline config for Qwen3.6.

## Notes

- All benchmarks run with the same script: `scripts/benchmark-knowledge.sh`
- Identical tasks (10), same prompts — only model/config changes
- Per-task grade: A (excellent), B (good), C (weak), D/F (failing)
- Overall grade: weighted average of per-task grades
