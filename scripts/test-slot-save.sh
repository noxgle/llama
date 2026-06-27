#!/usr/bin/env bash
# Test persistent KV cache (--slot-save-path) vs baseline
#
# Usage:
#   HOST=root@192.168.200.38 bash scripts/test-slot-save.sh
#
# Wykonuje 3-turnową konwersację (długi prompt + 2 follow-up pytania)
# najpierw w trybie baseline (bez slot-save), potem z slot-save/restore.
# Drukuje tabelę porównawczą czasów prefillu i generacji.

set -euo pipefail

# --- Konfiguracja ---
HOST="${HOST:-root@192.168.200.38}"
PORT="${PORT:-8089}"
MODEL="${MODEL:-qwen3.6}"
BASE_URL="http://$HOST:$PORT"
SLOT_FILE="/slots/test-slot.bin"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required (apt install jq)"
  exit 1
fi

# --- Długi prompt (~8-10k tokenów) ---
read -r -d '' LONG_PROMPT << 'PROMPT_EOF' || true
You are a senior software engineer reviewing a pull request for a distributed task queue system.

Review the following Python code and identify all bugs, performance issues, and design problems:

```python
import asyncio
import json
import time
import uuid
from typing import Any, Callable, Dict, List, Optional
from dataclasses import dataclass, field
from enum import Enum
import aiohttp
import msgpack
import redis.asyncio as redis
from pydantic import BaseModel

class TaskStatus(Enum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

@dataclass
class Task:
    id: str
    name: str
    payload: dict
    priority: int = 0
    status: TaskStatus = TaskStatus.PENDING
    created_at: float = field(default_factory=time.time)
    started_at: Optional[float] = None
    completed_at: Optional[float] = None
    result: Any = None
    error: Optional[str] = None
    retry_count: int = 0
    max_retries: int = 3
    tags: List[str] = field(default_factory=list)

class TaskQueue:
    def __init__(self, redis_url: str = "redis://localhost:6379"):
        self.redis = redis.from_url(redis_url)
        self.queue_key = "task_queue"
        self.processing_key = "task_processing"
        self.result_key = "task_results"
        self.workers: Dict[str, asyncio.Task] = {}
        self.handlers: Dict[str, Callable] = {}
        
    async def enqueue(self, task: Task) -> str:
        task.id = str(uuid.uuid4())
        task.created_at = time.time()
        data = msgpack.packb(task.__dict__)
        await self.redis.lpush(self.queue_key, data)
        await self.redis.zadd(f"{self.queue_key}:priority", {task.id: task.priority})
        return task.id
    
    async def dequeue(self, timeout: int = 30) -> Optional[Task]:
        result = await self.redis.brpop(self.queue_key, timeout=timeout)
        if result is None:
            return None
        _, data = result
        task_dict = msgpack.unpackb(data)
        task = Task(**task_dict)
        await self.redis.hset(self.processing_key, task.id, data)
        return task
    
    async def process_task(self, task: Task) -> None:
        task.started_at = time.time()
        task.status = TaskStatus.RUNNING
        handler = self.handlers.get(task.name)
        if handler is None:
            task.status = TaskStatus.FAILED
            task.error = f"No handler for task type: {task.name}"
            await self._complete_task(task)
            return
        try:
            result = handler(task.payload)
            task.result = result
            task.status = TaskStatus.COMPLETED
        except Exception as e:
            task.error = str(e)
            if task.retry_count < task.max_retries:
                task.retry_count += 1
                task.status = TaskStatus.PENDING
                await self.enqueue(task)
                return
            task.status = TaskStatus.FAILED
        finally:
            await self._complete_task(task)
    
    async def worker_loop(self, worker_id: str):
        while True:
            task = await self.dequeue()
            if task is None:
                continue
            try:
                await self.process_task(task)
            except Exception as e:
                print(f"Worker {worker_id} crashed on task {task.id}: {e}")
    
    async def register_handler(self, task_type: str, handler: Callable):
        self.handlers[task_type] = handler
    
    async def get_task_result(self, task_id: str) -> Optional[Task]:
        data = await self.redis.hget(self.result_key, task_id)
        if data is None:
            return None
        return Task(**msgpack.unpackb(data))
    
    async def cancel_task(self, task_id: str) -> bool:
        await self.redis.zrem(f"{self.queue_key}:priority", task_id)
        data = await self.redis.hget(self.processing_key, task_id)
        if data:
            await self.redis.hdel(self.processing_key, task_id)
            task = Task(**msgpack.unpackb(data))
            task.status = TaskStatus.CANCELLED
            await self._complete_task(task)
            return True
        return False
    
    async def _complete_task(self, task: Task):
        task.completed_at = time.time()
        data = msgpack.packb(task.__dict__)
        await self.redis.hset(self.result_key, task.id, data)
        await self.redis.hdel(self.processing_key, task.id)

class TaskScheduler:
    def __init__(self, queue: TaskQueue):
        self.queue = queue
        self.running = False
    
    async def schedule_periodic(self, interval: int, task: Task):
        while self.running:
            await asyncio.sleep(interval)
            await self.queue.enqueue(task)
    
    async def start(self):
        self.running = True
    
    async def stop(self):
        self.running = False
    
    async def health_check(self) -> dict:
        queue_len = await self.queue.redis.llen(self.queue.key)
        processing = await self.queue.redis.hlen(self.queue.processing_key)
        return {
            "queue_length": queue_len,
            "processing": processing,
            "workers": len(self.queue.workers)
        }
```

Also review this test suite:

```python
import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch
from task_queue import TaskQueue, Task, TaskStatus

@pytest.fixture
async def queue():
    q = TaskQueue(redis_url="redis://localhost:6379")
    yield q
    await q.redis.flushall()

@pytest.mark.asyncio
async def test_enqueue_dequeue(queue):
    task = Task(name="test", payload={"data": 1})
    task_id = await queue.enqueue(task)
    assert task_id is not None
    dequeued = await queue.dequeue(timeout=5)
    assert dequeued is not None
    assert dequeued.id == task_id

@pytest.mark.asyncio
async def test_task_processing(queue):
    async def handler(payload):
        return payload["data"] * 2
    await queue.register_handler("math", handler)
    task = Task(name="math", payload={"data": 21})
    await queue.enqueue(task)
    dequeued = await queue.dequeue()
    await queue.process_task(dequeued)
    result = await queue.get_task_result(dequeued.id)
    assert result.status == TaskStatus.COMPLETED
    assert result.result == 42

@pytest.mark.asyncio
async def test_task_failure(queue):
    async def failing_handler(payload):
        raise ValueError("Error")
    await queue.register_handler("fail", failing_handler)
    task = Task(name="fail", payload={})
    await queue.enqueue(task)
    dequeued = await queue.dequeue()
    await queue.process_task(dequeued)
    result = await queue.get_task_result(dequeued.id)
    assert result.status == TaskStatus.FAILED

@pytest.mark.asyncio
async def test_task_retry(queue):
    attempt_count = 0
    async def flaky_handler(payload):
        nonlocal attempt_count
        attempt_count += 1
        if attempt_count < 3:
            raise ConnectionError("Temp failure")
        return "success"
    await queue.register_handler("flaky", flaky_handler)
    task = Task(name="flaky", payload={}, max_retries=5)
    await queue.enqueue(task)
    for _ in range(3):
        dequeued = await queue.dequeue(timeout=1)
        if dequeued is None:
            break
        await queue.process_task(dequeued)
        if dequeued.status in [TaskStatus.COMPLETED, TaskStatus.FAILED]:
            break
    result = await queue.get_task_result(task.id)
    assert result.status == TaskStatus.COMPLETED
    assert result.retry_count == 2
```

Please provide a comprehensive code review covering:
1. ALL bugs (logic errors, race conditions, resource leaks) — be thorough
2. Performance issues (blocking calls, unnecessary operations, memory leaks)
3. Security concerns (injection, data exposure, auth issues)
4. Architecture problems (coupling, single points of failure, scalability)
5. Missing features (monitoring, graceful shutdown, dead letter queue)
6. Test coverage gaps and test design issues

For each issue, give severity (CRITICAL/HIGH/MEDIUM/LOW), explain why, and provide the fix.
PROMPT_EOF

# --- Pytania follow-up ---
Q1_TEXT="Review the code above and focus specifically on comparing async vs sync handlers. The process_task function uses handler(task.payload) — is that correct for an async handler? What should be changed? Also check whether register_handler properly validates callable signatures."
Q2_TEXT="Looking at the same code, analyze the redis connection lifetime. When does TaskQueue close its redis connection? Is this a resource leak? How would you fix it? Also check the serialization — msgpack for priority set but json elsewhere. Is this consistent?"

# --- Funkcja: request + pomiar ---
do_request() {
  local payload="$1"
  local label="$2"

  local start=$(date +%s%N)
  local response
  response=$(curl -s --max-time 600 "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1) || {
    echo "ERROR|$label|curl failed: $response"
    return
  }

  local end=$(date +%s%N)
  local total_ms=$(( (end - start) / 1000000 ))

  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    local err
    err=$(echo "$response" | jq -r '.error.message // .error')
    echo "ERROR|$label|$err"
    return
  fi

  local prompt_ms; prompt_ms=$(echo "$response" | jq -r '.timings.prompt_ms // 0')
  local predicted_ms; predicted_ms=$(echo "$response" | jq -r '.timings.predicted_ms // 0')
  local prompt_n; prompt_n=$(echo "$response" | jq -r '.usage.prompt_tokens // 0')
  local pred_n; pred_n=$(echo "$response" | jq -r '.usage.completion_tokens // 0')
  local total_n; total_n=$(echo "$response" | jq -r '.usage.total_tokens // 0')
  local tok_s; tok_s=$(echo "$response" | jq -r '.timings.predicted_per_second // "N/A"')

  echo "OK|$label|$total_ms|$prompt_ms|$predicted_ms|$prompt_n|$pred_n|$total_n|$tok_s"
}

slot_save() {
  curl -s -X POST "$BASE_URL/slots/0/save" \
    -H "Content-Type: application/json" \
    -d "{\"filename\":\"$SLOT_FILE\"}" > /dev/null 2>&1
}

slot_restore() {
  curl -s -X POST "$BASE_URL/slots/0/restore" \
    -H "Content-Type: application/json" \
    -d "{\"filename\":\"$SLOT_FILE\"}" > /dev/null 2>&1
}

wait_for_health() {
  echo -n ">>> Waiting for model to load..."
  for i in $(seq 1 120); do
    if curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
      echo " ready after ${i}s"
      return 0
    fi
    sleep 1
    echo -n "."
  done
  echo " timeout!"
  return 1
}

# --- Pomocnicze: generowanie payloadów z jq (unikamy problemów z quoting) ---
LONG_JSON=$(echo "$LONG_PROMPT" | jq -Rs .)

gen_payload() {
  local msg_json="$1"
  jq -n --arg model "$MODEL" --argjson msg "$msg_json" '{
    "messages": $msg,
    "model": $model,
    "max_tokens": 1500,
    "cache_prompt": true
  }'
}

# Wyniki
TEMP_DIR=$(mktemp -d)
RES_B="$TEMP_DIR/results_baseline.txt"
RES_S="$TEMP_DIR/results_slots.txt"

ALL_RESULTS=""

# ====================================================================
# TEST 1: BASELINE (bez slot-save)
# ====================================================================
echo ""
echo "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
echo "▓  TEST 1: BASELINE (bez slot-save)"
echo "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
echo ""

# Restart — wyłącz SLOT_SAVE_PATH na czas baseline testu
echo ">>> Disabling SLOT_SAVE_PATH and restarting..."
ssh "$HOST" "cd /opt/llama && sed -i 's/^SLOT_SAVE_PATH/#SLOT_SAVE_PATH/' configs/qwen3.6-35ba3b-mtp-unsloth.env && ./llama.sh restart qwen" 2>&1
wait_for_health
# Przywróć config
ssh "$HOST" "cd /opt/llama && sed -i 's/^#SLOT_SAVE_PATH/SLOT_SAVE_PATH/' configs/qwen3.6-35ba3b-mtp-unsloth.env"

echo ""
echo "--- Turn 1: Initial prompt ---"
MSG1=$(jq -n --argjson prompt "$LONG_JSON" '[{"role":"user","content":$prompt}]')
PAYLOAD1=$(gen_payload "$MSG1")
R1=$(do_request "$PAYLOAD1" "BASELINE-T1")
echo "  $R1"
echo "$R1" >> "$RES_B"

echo "--- Turn 2: Follow-up Q1 ---"
MSG2=$(jq -n \
  --argjson prompt "$LONG_JSON" \
  --arg q1 "$Q1_TEXT" \
  '[{"role":"user","content":$prompt},{"role":"assistant","content":"Understood, reviewing now."},{"role":"user","content":$q1}]')
PAYLOAD2=$(gen_payload "$MSG2")
R2=$(do_request "$PAYLOAD2" "BASELINE-T2")
echo "  $R2"
echo "$R2" >> "$RES_B"

echo "--- Turn 3: Follow-up Q2 ---"
MSG3=$(jq -n \
  --argjson prompt "$LONG_JSON" \
  --arg q2 "$Q2_TEXT" \
  '[{"role":"user","content":$prompt},{"role":"assistant","content":"Understood, reviewing now."},{"role":"user","content":"The async handler question first."},{"role":"assistant","content":"Good point about async handlers."},{"role":"user","content":$q2}]')
PAYLOAD3=$(gen_payload "$MSG3")
R3=$(do_request "$PAYLOAD3" "BASELINE-T3")
echo "  $R3"
echo "$R3" >> "$RES_B"

echo ""

# ====================================================================
# TEST 2: Z SLOT-SAVE/RESTORE
# ====================================================================
echo "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
echo "▓  TEST 2: Z SLOT-SAVE/RESTORE"
echo "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
echo ""

# Restart — SLOT_SAVE_PATH włączony (config już przywrócony wyżej)
echo ">>> Restarting with SLOT_SAVE_PATH enabled..."
ssh "$HOST" "cd /opt/llama && ./llama.sh restart qwen" 2>&1
wait_for_health

# Usuń stary slot
ssh "$HOST" "rm -f /opt/llama/slots/test-slot.bin" 2>/dev/null || true

echo ""
echo "--- Turn 1: Initial prompt ---"
R1=$(do_request "$PAYLOAD1" "SLOT-T1")
echo "  $R1"
echo "$R1" >> "$RES_S"
echo "  → Saving slot..."
slot_save
if ssh "$HOST" "test -f /opt/llama/slots/test-slot.bin" 2>/dev/null; then
  echo "  → Slot saved OK"
else
  echo "  → WARNING: Slot file not found!"
fi

echo ""
echo "--- Turn 2: Restore slot → Follow-up Q1 ---"
slot_restore
R2=$(do_request "$PAYLOAD2" "SLOT-T2")
echo "  $R2"
echo "$R2" >> "$RES_S"
echo "  → Saving slot..."
slot_save

echo ""
echo "--- Turn 3: Restore slot → Follow-up Q2 ---"
slot_restore
R3=$(do_request "$PAYLOAD3" "SLOT-T3")
echo "  $R3"
echo "$R3" >> "$RES_S"

echo ""

# ====================================================================
# WYNIKI — TABELA PORÓWNAWCZA
# ====================================================================
echo "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
echo "▓  WYNIKI"
echo "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
echo ""

printf "+-----------+----------+------------+------------+------------+------------+--------+\n"
printf "| Turn      | Mode     | Total (ms) | Prompt (ms)| Gen (ms)   | Tokens     | tok/s  |\n"
printf "+-----------+----------+------------+------------+------------+------------+--------+\n"

table_row() {
  local file="$1"
  local prefix="$2"
  local mode="$3"
  for turn in "T1" "T2" "T3"; do
    local line
    line=$(grep "^OK|${prefix}-${turn}" "$file" 2>/dev/null || true)
    if [ -n "$line" ]; then
      IFS='|' read -r _ _ total prompt gen p_n c_n total_n tps <<< "$line"
      printf "| %-9s | %-8s | %10s | %10s | %10s | %10s | %-6s |\n" \
        "${prefix}-${turn}" "$mode" "${total}ms" "${prompt}ms" "${gen}ms" "${total_n}" "$tps"
    fi
  done
}

table_row "$RES_B" "BASELINE" "BASE"
printf "+-----------+----------+------------+------------+------------+------------+--------+\n"
table_row "$RES_S" "SLOT" "SLOT"
printf "+-----------+----------+------------+------------+------------+------------+--------+\n"

echo ""

# --- Podsumowanie oszczędności ---
extract() {
  local file="$1"
  local turn="$2"
  local field="$3"  # 4=prompt_ms, 3=total_ms
  local line
  line=$(grep "^OK|${turn}" "$file" 2>/dev/null || true)
  if [ -n "$line" ]; then
    echo "$line" | cut -d'|' -f"$field"
  else
    echo "0"
  fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PODSUMOWANIE OSZCZĘDNOŚCI (Prefill time)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BP1=$(extract "$RES_B" "BASELINE-T1" 4)
BP2=$(extract "$RES_B" "BASELINE-T2" 4)
BP3=$(extract "$RES_B" "BASELINE-T3" 4)
SP1=$(extract "$RES_S" "SLOT-T1" 4)
SP2=$(extract "$RES_S" "SLOT-T2" 4)
SP3=$(extract "$RES_S" "SLOT-T3" 4)

printf "  %-20s %15s %15s %15s\n" "" "BASELINE" "SLOT-SAVE" "SAVING"
printf "  %-20s %15s %15s %15s\n" "Initial prompt (T1)" "${BP1}ms" "${SP1}ms" "~similar"
printf "  %-20s %15s %15s %15s\n" "Follow-up Q1 (T2)" "${BP2}ms" "${SP2}ms" "$((BP2 - SP2))ms"
printf "  %-20s %15s %15s %15s\n" "Follow-up Q2 (T3)" "${BP3}ms" "${SP3}ms" "$((BP3 - SP3))ms"

echo ""
echo " Slot file:"
ssh "$HOST" "ls -lh /opt/llama/slots/test-slot.bin 2>/dev/null || echo '  (none)'"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "=== Done ==="
