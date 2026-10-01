"""
Locust load test for vLLM OpenAI-compatible chat completion endpoints.

Tracks custom metrics for TTFT (Time to First Token) and TPOT (Time Per Output Token)
by parsing streaming SSE responses.

Usage:
    locust -f locustfile.py --host http://localhost:8000 --users 10 --spawn-rate 2

Environment Variables:
    VLLM_MODEL          Model name (default: meta-llama/Llama-3.1-70B-Instruct)
    VLLM_MAX_TOKENS     Maximum output tokens (default: 256)
    VLLM_TEMPERATURE    Sampling temperature (default: 0.7)
"""

import json
import os
import time

from locust import HttpUser, between, events, task

# Configuration from environment
MODEL = os.environ.get("VLLM_MODEL", "meta-llama/Llama-3.1-70B-Instruct")
MAX_TOKENS = int(os.environ.get("VLLM_MAX_TOKENS", "256"))
TEMPERATURE = float(os.environ.get("VLLM_TEMPERATURE", "0.7"))

# Sample prompts categorized by length
SHORT_PROMPTS = [
    "What is the capital of France?",
    "Explain what a neural network is in one sentence.",
    "Write a haiku about programming.",
    "What is 2 + 2?",
    "Define machine learning.",
]

MEDIUM_PROMPTS = [
    "Explain the differences between supervised, unsupervised, and reinforcement learning. "
    "Provide a brief example of each.",
    "Write a Python function that implements binary search on a sorted list. "
    "Include proper error handling and docstrings.",
    "Describe the key architectural differences between transformers and RNNs. "
    "Why have transformers become dominant in NLP?",
]

LONG_PROMPTS = [
    # RAG-style: context + question
    "Given the following context about distributed systems:\n\n"
    "Distributed systems are collections of independent computers that appear to users as a single "
    "coherent system. Key challenges include handling partial failures, maintaining consistency across "
    "replicas, and managing network partitions. The CAP theorem states that a distributed system "
    "cannot simultaneously provide all three of: Consistency, Availability, and Partition tolerance. "
    "Common consistency models include strong consistency, eventual consistency, and causal consistency. "
    "Consensus protocols like Paxos and Raft help distributed nodes agree on values despite failures. "
    "Modern distributed databases like CockroachDB use Raft for consensus, while systems like "
    "DynamoDB opt for eventual consistency with conflict resolution.\n\n"
    "Question: Compare and contrast strong consistency and eventual consistency. "
    "When would you choose each approach?",
    "You are analyzing a production Kubernetes cluster with the following metrics:\n\n"
    "- CPU utilization: 78% average across 16 nodes\n"
    "- Memory pressure: 3 nodes showing OOMKill events\n"
    "- Pod restart count: 47 restarts in last hour for inference pods\n"
    "- GPU utilization: 45% on A100 nodes, 92% on H100 nodes\n"
    "- Network: 2.3 Gbps inter-node traffic\n"
    "- Storage: PVC at 87% capacity for model cache\n\n"
    "Provide a detailed diagnosis and remediation plan. Prioritize by impact.",
]


def parse_streaming_response(response):
    """Parse SSE streaming response and extract timing metrics.

    Returns:
        dict with keys: ttft_ms, total_ms, output_tokens, tpot_ms
    """
    start_time = time.monotonic()
    first_token_time = None
    output_tokens = 0

    for line in response.iter_lines():
        if not line:
            continue

        decoded = line.decode("utf-8") if isinstance(line, bytes) else line

        if not decoded.startswith("data: "):
            continue

        data_str = decoded[6:]  # Strip "data: " prefix
        if data_str.strip() == "[DONE]":
            break

        try:
            data = json.loads(data_str)
            choices = data.get("choices", [])
            if choices:
                delta = choices[0].get("delta", {})
                content = delta.get("content", "")
                if content:
                    if first_token_time is None:
                        first_token_time = time.monotonic()
                    output_tokens += 1
        except json.JSONDecodeError:
            continue

    end_time = time.monotonic()

    total_ms = (end_time - start_time) * 1000
    ttft_ms = (first_token_time - start_time) * 1000 if first_token_time else total_ms

    tpot_ms = 0.0
    if output_tokens > 1 and first_token_time is not None:
        decode_time_ms = (end_time - first_token_time) * 1000
        tpot_ms = decode_time_ms / (output_tokens - 1)

    return {
        "ttft_ms": ttft_ms,
        "total_ms": total_ms,
        "output_tokens": output_tokens,
        "tpot_ms": tpot_ms,
    }


class VLLMUser(HttpUser):
    """Simulates users sending chat completion requests to a vLLM endpoint."""

    wait_time = between(1, 3)

    def _send_chat_request(self, prompt, max_tokens, request_name):
        """Send a streaming chat completion request and track metrics."""
        payload = {
            "model": MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": TEMPERATURE,
            "stream": True,
        }

        start_time = time.monotonic()

        with self.client.post(
            "/v1/chat/completions",
            json=payload,
            stream=True,
            catch_response=True,
            name=request_name,
        ) as response:
            if response.status_code != 200:
                response.failure(f"HTTP {response.status_code}: {response.text[:200]}")
                return

            metrics = parse_streaming_response(response)
            total_time = (time.monotonic() - start_time) * 1000

            # Report custom metrics via Locust events
            events.request.fire(
                request_type="TTFT",
                name=request_name,
                response_time=metrics["ttft_ms"],
                response_length=0,
                exception=None,
                context={},
            )

            if metrics["tpot_ms"] > 0:
                events.request.fire(
                    request_type="TPOT",
                    name=request_name,
                    response_time=metrics["tpot_ms"],
                    response_length=0,
                    exception=None,
                    context={},
                )

            if metrics["output_tokens"] == 0:
                response.failure("No tokens generated")
            else:
                response.success()

    @task(weight=3)
    def chat_completion_short(self):
        """Short prompt, short response."""
        import random

        prompt = random.choice(SHORT_PROMPTS)
        self._send_chat_request(prompt, min(MAX_TOKENS, 64), "short_completion")

    @task(weight=5)
    def chat_completion_medium(self):
        """Medium prompt, medium response."""
        import random

        prompt = random.choice(MEDIUM_PROMPTS)
        self._send_chat_request(prompt, min(MAX_TOKENS, 256), "medium_completion")

    @task(weight=1)
    def chat_completion_long(self):
        """Long prompt (RAG-style), medium response."""
        import random

        prompt = random.choice(LONG_PROMPTS)
        self._send_chat_request(prompt, min(MAX_TOKENS, 512), "long_completion")
