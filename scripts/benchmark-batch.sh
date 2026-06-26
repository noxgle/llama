#!/usr/bin/env python3
"""Large-prompt batch size benchmark.

Generates a ~10k token synthetic prompt, sends it to the model,
and measures prefill/generation throughput.

Usage:
  python3 scripts/benchmark-batch.sh                    # localhost:8089
  HOST=root@192.168.200.38 python3 scripts/benchmark-batch.sh
  PORT=8089 python3 scripts/benchmark-batch.sh          # custom port

Output:
  Prints timing breakdown (prefill tok/s, gen tok/s, total time, VRAM)
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime

HOST = os.environ.get("HOST", "")
PORT = int(os.environ.get("PORT", 8089))
CURL_TIMEOUT = 600  # max seconds per request
N_RUNS = int(os.environ.get("N_RUNS", "1"))  # probes per config (1 is enough with large prompts)

# ---- generate ~10k token prompt ----
# Use a repetitive but sensible text to hit ~10k tokens
_BODY = """The principles of distributed computing and consensus algorithms form the backbone of modern large-scale systems. In a distributed network, multiple nodes must coordinate to achieve a common goal despite the risk of failures, network partitions, and Byzantine behavior. The Paxos protocol, first described by Leslie Lamport in 1989, provides a foundation for achieving consensus in a network of unreliable processors. It works by having proposers send prepare requests to acceptors, who promise to reject older proposals and accept newer ones. Once a quorum of acceptors promises, the proposer sends an accept request with a value. If a majority of acceptors accept the value, consensus is reached.

The Raft protocol, developed by Diego Ongaro and John Ousterhout at Stanford University, offers a more understandable alternative to Paxos. It decomposes consensus into three subproblems: leader election, log replication, and safety. In Raft, nodes are in one of three states: leader, candidate, or follower. The leader handles all client requests and replicates log entries to followers. If followers don't hear from the leader within an election timeout, they become candidates and initiate a new election. This approach has been widely adopted in production systems like etcd and Consul.

Beyond consensus, distributed systems must handle data replication across geographic regions. Conflict-free Replicated Data Types (CRDTs) offer an appealing approach: each node can update its local state independently, and changes automatically merge without conflicts. The key insight is that CRDT operations are designed to be commutative, associative, and idempotent. Examples include Grow-Only Sets (G-Set), where elements can only be added and never removed, and Last-Writer-Wins Registers, which use timestamps to resolve conflicts.

Modern database systems increasingly adopt distributed architectures. Google's Spanner is a globally distributed SQL database that uses TrueTime API (based on GPS and atomic clocks) to provide external consistency. Amazon's DynamoDB uses a multi-leader replication model with vector clocks for conflict resolution. These systems must balance consistency, availability, and partition tolerance according to the CAP theorem, which states that a distributed system can provide at most two of these three guarantees.

The Lambda Architecture, proposed by Nathan Marz, combines batch processing and stream processing to handle large-scale data. The batch layer precomputes views from historical data, while the speed layer processes real-time data incrementally. The serving layer merges results from both layers to answer queries. Apache Spark has become the de facto standard for batch processing, while Apache Flink and Kafka Streams dominate stream processing.

Machine learning at scale introduces additional challenges. Parameter servers coordinate distributed training across hundreds of GPUs, managing model parameters that can exceed available memory on a single device. Techniques like gradient compression, asynchronous SGD, and model parallelism enable training of models with trillions of parameters. The All-Reduce algorithm efficiently aggregates gradients across workers by organizing them in a ring topology, where each node communicates only with its neighbors.

Container orchestration systems like Kubernetes manage the deployment, scaling, and operation of distributed applications. They use a declarative model where users specify desired state, and the system continuously reconciles actual state with desired state. The control plane components (API server, scheduler, controller manager) run in a highly available configuration, while kubelets on each node manage container execution.

Edge computing pushes computation closer to data sources, reducing latency and bandwidth usage. This is particularly important for Internet of Things (IoT) applications, autonomous vehicles, and augmented reality. Fog computing extends this concept by providing a hierarchical architecture where processing occurs at multiple levels: edge devices, fog nodes, and cloud data centers.

Observability in distributed systems requires three pillars: metrics, logging, and tracing. Metrics provide aggregate measurements of system behavior over time. Logging records discrete events with timestamps for debugging. Distributed tracing follows requests across service boundaries using propagated context (trace IDs, span IDs). Tools like Prometheus, Grafana, OpenTelemetry, and Jaeger have become standard components of the observability stack.

Security in distributed systems encompasses authentication, authorization, encryption, and audit. Mutual TLS (mTLS) provides authenticated encrypted communication between services. OAuth 2.0 and OIDC handle delegated authorization across service boundaries. Service meshes like Istio and Linkerd offload security concerns from application code to the infrastructure layer, providing consistent policy enforcement and encryption.

The evolution of distributed systems continues with serverless computing, where developers write functions that are automatically scaled and billed only when executed. AWS Lambda, Cloudflare Workers, and Azure Functions exemplify this paradigm. While serverless offers operational simplicity, it introduces challenges around cold starts, state management, and vendor lock-in.

CQRS (Command Query Responsibility Segregation) separates read and write operations into different models, optimizing each for its specific workload. Event Sourcing stores state changes as a sequence of events, enabling audit trails, temporal queries, and event-driven integrations. Together, these patterns provide the foundation for event-driven architectures that can scale independently for read and write workloads.

Database indexing strategies significantly impact query performance. B-tree indexes support efficient range queries and are the default in most relational databases. Hash indexes excel at point lookups but don't support ranges. Bitmap indexes are effective for low-cardinality columns. Covering indexes store all columns needed by a query within the index itself, eliminating the need to access the table. Partial indexes index only a subset of rows, reducing index size and maintenance overhead.

Transaction isolation levels balance consistency against concurrency. Read Uncommitted allows dirty reads but maximum concurrency. Read Committed prevents dirty reads but allows non-repeatable reads. Repeatable Read prevents both dirty and non-repeatable reads but allows phantom reads. Serializable guarantees full isolation but severely limits concurrency. Most production systems default to Read Committed, trading perfect consistency for practical throughput.

Materialized views precompute and store query results, dramatically improving read performance for complex aggregations. They must be refreshed when underlying data changes, either synchronously or asynchronously. In data warehouse environments, materialized views enable sub-second query response times over terabytes of data, making interactive analytics feasible at scale.

Sharding partitions data across multiple databases to distribute load and enable horizontal scaling. Consistent hashing assigns each key to a node by hashing both the key and the node identifiers, minimizing redistribution when nodes join or leave. Virtual nodes (vnodes) improve load distribution by mapping each physical node to multiple positions on the consistent hash ring. This approach is used by Cassandra, DynamoDB, and Riak.

Time-series databases are optimized for append-heavy workloads with time-stamped data. InfluxDB, TimescaleDB, and ClickHouse use columnar storage, compression algorithms, and retention policies to efficiently store and query billions of data points. Downsampling aggregates older data to reduce storage requirements while preserving long-term trends.

Graph databases like Neo4j and Amazon Neptune excel at traversing relationships between entities. They use index-free adjacency where each node directly references its neighbors, enabling constant-time traversal regardless of graph size. This makes them ideal for social networks, recommendation engines, and fraud detection systems where relationship depth matters more than record count.

Full-text search engines like Elasticsearch and Apache Solr are built on inverted indexes that map terms to document positions. They support relevancy scoring using TF-IDF or BM25 algorithms, faceted search for drill-down navigation, and n-gram tokenizers for partial matching. These capabilities enable Google-like search experiences over application-specific data.

The actor model, popularized by Erlang and adopted by Akka and Orleans, provides a programming model for building concurrent and distributed systems. Actors are lightweight computational entities that communicate exclusively through asynchronous message passing. Each actor processes messages sequentially, eliminating shared-state concurrency issues. Supervisor hierarchies manage failure, automatically restarting failed actors according to configured strategies.

Stream processing systems operate on unbounded data streams, processing each record with low latency. Window operations (tumbling, sliding, session) group records within time or count boundaries. Watermarks track event time progress and handle late-arriving data. Exactly-once semantics ensure that each record is processed precisely once despite failures, using distributed snapshot state and transactional output commits.

This concludes the overview of distributed systems concepts and modern data infrastructure patterns that enable building reliable, scalable, and maintainable systems at internet scale.
"""

def build_prompt(run_id: str = "") -> str:
    """Build a ~10k token prompt by repeating the body and adding a task.
    Args:
        run_id: unique identifier woven into the body to prevent KV cache reuse
    """
    repeats = max(1, 35)  # ~350k chars → ~10k tokens for technical English
    body = _BODY
    if run_id:
        # Weave run_id into the first paragraph to make each prompt unique
        body = body.replace("distributed computing", f"distributed computing ({run_id})", 1)
    text = "\n\n".join([body] * repeats)
    prompt = (
        text
        + "\n\n"
        + "-" * 60
        + "\n\nSummarize the key points from this document in 3-5 bullet points. "
        "Focus on the most important concepts and their relationships."
    )
    return prompt


def run_curl(payload: str) -> str:
    """Send request via curl with payload written to temp file (avoids arg length limits)."""
    # Write payload to a temp file
    tmp = tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json")
    try:
        tmp.write(payload)
        tmp.close()
        
        if HOST:
            # Need to scp the payload file first, then ssh curl with -d @file
            remote_tmp = f"/tmp/benchmark-payload-{os.getpid()}.json"
            subprocess.run(["sshpass", "-p", "123456", "scp", tmp.name, 
                           f"{HOST}:{remote_tmp}"], capture_output=True, timeout=30)
            # Use single string to avoid SSH argument splitting on header value
            cmd = [
                "ssh", HOST,
                f"curl -sS --max-time {CURL_TIMEOUT} "
                f"'http://localhost:{PORT}/v1/chat/completions' "
                f"-H 'Content-Type: application/json' "
                f"-d '@{remote_tmp}'",
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=CURL_TIMEOUT + 10)
            # Clean up remote file
            subprocess.run(["ssh", HOST, "rm", "-f", remote_tmp], capture_output=True, timeout=10)
        else:
            cmd = [
                "curl", "-sS", "--max-time", str(CURL_TIMEOUT),
                f"http://localhost:{PORT}/v1/chat/completions",
                "-H", "Content-Type: application/json",
                "-d", f"@{tmp.name}",
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=CURL_TIMEOUT + 10)
        
        if result.returncode != 0:
            return json.dumps({"error": f"curl failed: {result.stderr.strip()}"})
        return result.stdout
    except subprocess.TimeoutExpired:
        return json.dumps({"error": "timeout"})
    except Exception as e:
        return json.dumps({"error": str(e)})
    finally:
        os.unlink(tmp.name)


def get_vram(host: str = "") -> int:
    """Get used VRAM in MiB. Returns 0 on error."""
    try:
        if host:
            cmd = ["ssh", host, "nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader"]
        else:
            cmd = ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return int(re.sub(r"[^0-9]", "", r.stdout.strip()))
    except Exception:
        pass
    return 0


def main():
    # Build a unique prompt for this run (weaves run_id into body to prevent KV cache reuse)
    run_id = f"{os.getpid()}-{time.time_ns()}"
    prompt = build_prompt(run_id)
    prompt_len = len(prompt)
    print(f"Prompt length: {prompt_len} chars (~{prompt_len // 4} tokens)")
    print()

    # Collect VRAM before
    vram_before = get_vram(HOST)
    print(f"VRAM before: {vram_before} MiB")
    print()

    probe_times = []
    probe_tps = []
    probe_pps = []
    probe_prefill = []

    for run in range(N_RUNS):
        payload = json.dumps({
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.1,
        })

        t0 = time.time()
        raw = run_curl(payload)
        elapsed = round(time.time() - t0, 1)

        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print(f"  [{run+1}/{N_RUNS}] FAIL (invalid JSON)")
            continue

        if "error" in data:
            print(f"  [{run+1}/{N_RUNS}] FAIL ({data['error'][:80]})")
            continue

        timings = data.get("timings", {})
        usage = data.get("usage", {})
        tps = timings.get("predicted_per_second", 0)
        pps = timings.get("prompt_per_second", 0)
        prompt_n = timings.get("prompt_n", 0)
        pred_n = usage.get("completion_tokens", timings.get("predicted_n", 0))
        prompt_usage = usage.get("prompt_tokens", 0)
        cached = usage.get("prompt_tokens_details", {}).get("cached_tokens", 0)

        # Extract finish reason
        finish = data.get("choices", [{}])[0].get("finish_reason", "")

        probe_times.append(elapsed)
        probe_tps.append(tps)
        probe_pps.append(pps)
        probe_prefill.append(prompt_n)

        print(f"  [{run+1}/{N_RUNS}]  prefill={pps:.0f} tok/s  gen={tps:.1f} tok/s  "
              f"prompt_t={prompt_n}  prompt_u={prompt_usage}  "
              f"cached={cached}  gen_t={pred_n}  "
              f"time={elapsed}s  finish={finish}")

        # Small delay between probes
        if run < N_RUNS - 1:
            time.sleep(3)

    vram_after = get_vram(HOST)
    print()
    print(f"VRAM after:  {vram_after} MiB  (Δ {vram_after - vram_before} MiB)")

    if probe_tps:
        avg_tps = sum(probe_tps) / len(probe_tps)
        avg_pps = sum(probe_pps) / len(probe_pps)
        avg_time = sum(probe_times) / len(probe_times)
        print()
        print("=" * 60)
        print(f"  AVERAGES ({len(probe_tps)} probes):")
        print(f"    Prefill:     {avg_pps:.0f} tok/s")
        print(f"    Generation:  {avg_tps:.1f} tok/s")
        print(f"    Total time:  {avg_time:.0f}s")
        print(f"    VRAM used:   {vram_after} MiB")
        print("=" * 60)
    else:
        print("No successful probes.")


if __name__ == "__main__":
    main()
