# Knowledge Benchmark — Quality Evaluation

**Model:** Gemma4 26B A4B (UD-Q4_K_M) + Q8_0-MTP draft
**Server:** 192.168.200.21 (RTX A2000 6 GB)
**Date:** 2026-06-24

---

## Task 1: Data Analysis — 💲

**Request:** Calculate avg salary, list under-32 employees, find department with highest avg salary.

**Response quality:** Model methodically calculates each part. Average salary: ✅ $54,250 correct. Employees under 32: ✅ John, Jane, Alice correct. Department question: ⚠️ starts talking about Engineering but gets cut off (max_tokens=400). The average payroll per department logic is only partially shown.

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Wszystkie obliczenia OK |
| Kompletność | ⚠️ Truncated przed odpowiedzią o departament |
| Struktura | ✅ Przejrzysty step-by-step |
| **Ocena** | **B+** |

---

## Task 2: Python Programming — 🐍

**Request:** Write `analyze_text()` function returning a dict with word count, char count, unique words, longest word, word frequency.

**Response quality:** Model demonstrates excellent understanding — identifies edge cases (empty string), plans to use `collections.Counter`, regex for punctuation handling, discusses case-sensitivity trade-offs. But the actual code is cut off mid-function at `def analyze_`. The reasoning is thorough but the deliverable (code) is incomplete.

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Algorytmicznie poprawny plan |
| Kompletność | ❌ Kod nie został wygenerowany (truncated) |
| Design | ✅ Dobre decyzje (Counter, edge case handling) |
| **Ocena** | **C+** |

---

## Task 3: Logic Puzzle — 🧩

**Request:** Classic "3 boxes mislabeled" puzzle — pick one fruit from one box, determine all labels.

**Response quality:** The model attempts to reason through scenarios but gets tangled. The correct solution (pick from Box C "Apples and Oranges" — whatever fruit you get tells you which single-fruit box it is, then deduce the rest) is never reached. Instead the model goes through multiple ambiguous scenarios without converging. The thinking shows effort but the reasoning doesn't reach the right conclusion within the token budget.

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ❌ Nie doszedł do poprawnego rozwiązania |
| Kompletność | ❌ Analiza przerwana, brak konkluzji |
| Struktura | ⚠️ Próbuje ale gubi się w scenariuszach |
| **Ocena** | **C** |

---

## Task 4: Mathematics — ∫

**Request:** Calculate ∫₀² (3x² + 2x + 1) dx step by step.

**Response quality:** Correct antiderivative (x³ + x² + x), correct application of Power Rule, correct setup of Fundamental Theorem. But the response is cut off before plugging in the limits (F(2) - F(0) = 8 + 4 + 2 = 14). The approach is perfect but truncated.

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Wszystkie kroki poprawne |
| Kompletność | ⚠️ Brak finalnego wyniku (truncated) |
| Przejrzystość | ✅ Dobrze rozpisane |
| **Ocena** | **B** |

---

## Task 5: Networking Knowledge — 🌐

**Request:** Compare TCP vs UDP (connection, reliability, 2 applications each).

**Response quality:** Excellent! Model clearly separates TCP and UDP sections. For TCP: correctly describes 3-way handshake, ACKs, retransmission, flow control. Applications: web browsing (HTTP), email (SMTP), file transfer (FTP). For UDP: connectionless, best-effort. Applications: streaming/VoIP, gaming, DNS. Well-structured and accurate. Slightly cut off near the end of the UDP section.

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Wyczerpujące i dokładne |
| Kompletność | ✅ Oba protokoły omówione |
| Struktura | ✅ Przejrzysty podział |
| **Ocena** | **B+** |

---

## Task 6: Creative Writing — 📝

**Request:** Short story about a dreaming robot, contemplative & melancholy.

**Response quality:** Zaskakująco dobre! Opowieść o "Unit 7" który zamiast diagnostyki śni o fioletowych polach, rtęciowych oceanach, melodii z ciszy i światła gwiazd. Język poetycki, nastrojowy. Świetne imagery — "the cobalt faded into the dull, grey reality of the charging bay", "a ghost in the machine, mourning a dream". Ton idealnie trafiony: melancholijny, kontemplacyjny.

| Aspekt | Ocena |
|--------|-------|
| Kreatywność | ✅ Wysoki poziom literacki |
| Styl/Ton | ✅ Idealnie melancholijny |
| Struktura | ✅ Ma początek, rozwinięcie, cliffhanger |
| **Ocena** | **A** |

---

## Task 7: Code Review — 🔍

**Request:** Review Python code with bugs (empty list division, negative numbers, style issues).

**Response quality:** **Best response of the benchmark.** Model identifies both critical bugs:
1. `find_max` initialized to `0` — breaks for negative numbers ✅
2. `calculate_average` divides by zero on empty list ✅
3. Un-Pythonic `range(len(...))` loops ✅
4. Suggests `sum()`, `max()`, `defaultdict` refactoring ✅
Provides corrected code for each. Comprehensive, accurate, well-prioritized (bugs vs style).

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Wszystkie bugi znalezione |
| Kompletność | ✅ Pełna analiza + poprawiony kod |
| Priorytetyzacja | ✅ Krytyczne bugi vs kosmetyka |
| **Ocena** | **A** |

---

## Task 8: SQL Query — 📊

**Request:** Write SQL with JOIN, aggregation, most recent employee, HAVING, ORDER BY.

**Response quality:** Model correctly identifies all needed components. Discusses multiple approaches: window functions (ROW_NUMBER), correlated subqueries, CTEs. The analysis of the "most recent hire" problem is correct and shows understanding of SQL complexities. However, the final query is not completed (truncated).

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Dobra analiza wymagań |
| Kompletność | ⚠️ Końcowe zapytanie niekompletne |
| Wiedza | ✅ Znajomość window functions |
| **Ocena** | **B+** |

---

## Task 9: Explain Like I'm 5 — 🧒

**Request:** Explain internet to a 5-year-old, <150 words, simple analogies.

**Response quality:** Używa analogii pajęczyny, listów, bibliotek. Język prosty i zrozumiały. Fajne imagery: "tiny superhero running through tunnels", "big library filled with all the videos". Ton odpowiedni dla dziecka. Długość: ~100 słów (w limicie).

| Aspekt | Ocena |
|--------|-------|
| Prostota | ✅ Idealna dla 5-latka |
| Analogie | ✅ Trafne i obrazowe |
| Długość | ✅ W limicie |
| **Ocena** | **A-** |

---

## Task 10: Algorithm Design — 💻

**Request:** Palindrome permutation detection algorithm.

**Response quality:** Model correctly identifies the key insight: at most one character with odd frequency. Explains the "even length = all even counts, odd length = one odd count" rule clearly. Provides two approaches: hash map (general) and bit vector (optimized for lowercase letters). Time complexity O(N) correctly stated. Clean implementation approach. **Complete and correct!**

| Aspekt | Ocena |
|--------|-------|
| Poprawność | ✅ Kluczowa własność poprawnie zidentyfikowana |
| Kompletność | ✅ Dwa warianty, analiza złożoności |
| Implementacja | ✅ Kompletny kod |
| **Ocena** | **A** |

---

## Summary

| # | Task | tok/s | Quality | Uwagi |
|---|------|------:|:-------:|-------|
| 1 | Data Analysis | 29.2 | **B+** | Obliczenia OK, truncated |
| 2 | Python Programming | 26.7 | **C+** | Dobry plan, ale kod niegotowy |
| 3 | Logic Puzzle | 27.5 | **C** | Nie rozwiązał poprawnie |
| 4 | Mathematics | 29.7 | **B** | Dobre kroki, brak wyniku |
| 5 | Networking Knowledge | 24.9 | **B+** | Kompleksowa, truncated |
| 6 | Creative Writing | 23.0 | **A** | ⭐ WOW — świetna historia |
| 7 | Code Review | 27.0 | **A** | ⭐ Wszystkie bugi znalezione |
| 8 | SQL Query | 26.4 | **B+** | Dobra analiza, truncated |
| 9 | ELI5 | 23.4 | **A-** | Proste, obrazowe |
| 10 | Algorithm Design | 27.5 | **A** | ⭐ Kompletny i poprawny |
| | **Avg** | **26.6** | **B+** | |

### Mocne strony Gemma4 26B:
- ✅ **Code Review** — doskonałe znajdowanie bugów i refactoring
- ✅ **Creative Writing** — zaskakująco poetycki, dobry styl
- ✅ **Algorithm Design** — poprawne wnioskowanie, clean code
- ✅ **Systematic reasoning** — model ma tendencję do rozpisywania kroków

### Słabe strony:
- ❌ **Częste truncation** — model myśli zbyt długo, nie mieszcząc odpowiedzi w max_tokens
- ❌ **Logic Puzzle** — gubi się w złożonych scenariuszach bez doprowadzenia do konkluzji
- ❌ **Zmienna jakość** — od A do C w zależności od typu zadania

### Ogólna ocena: **B+ / Bardzo dobra jak na 26B (Q4_K_M)**
