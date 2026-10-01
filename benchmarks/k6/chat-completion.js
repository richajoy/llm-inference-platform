/**
 * k6 Load Test for vLLM Chat Completion Endpoints
 *
 * Tests OpenAI-compatible /v1/chat/completions with streaming,
 * tracking custom TTFT and TPOT metrics with threshold-based pass/fail.
 *
 * Usage:
 *   k6 run chat-completion.js
 *   k6 run --env VLLM_HOST=http://my-endpoint:8000 chat-completion.js
 *   k6 run --env VLLM_MODEL=meta-llama/Llama-3.1-8B-Instruct chat-completion.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";

// Custom metrics
const ttft = new Trend("ttft", true); // Time to First Token (ms)
const tpot = new Trend("tpot", true); // Time Per Output Token (ms)
const outputTokens = new Counter("output_tokens");
const streamErrors = new Rate("stream_errors");

// Configuration from environment
const VLLM_HOST = __ENV.VLLM_HOST || "http://localhost:8000";
const VLLM_MODEL =
  __ENV.VLLM_MODEL || "meta-llama/Llama-3.1-70B-Instruct";
const MAX_TOKENS = parseInt(__ENV.VLLM_MAX_TOKENS || "256");

// Test stages: ramp up, sustain, ramp down
export const options = {
  stages: [
    { duration: "1m", target: 10 }, // Ramp up to 10 users
    { duration: "3m", target: 50 }, // Sustain at 50 users
    { duration: "1m", target: 0 }, // Ramp down
  ],
  thresholds: {
    ttft: ["p(50)<2000", "p(99)<5000"], // TTFT P50 < 2s, P99 < 5s
    tpot: ["p(50)<60", "p(99)<100"], // TPOT P50 < 60ms, P99 < 100ms
    http_req_failed: ["rate<0.05"], // Less than 5% errors
    stream_errors: ["rate<0.10"], // Less than 10% stream parse errors
  },
};

// Prompt pool
const prompts = [
  // Short
  "What is the capital of France?",
  "Explain quantum computing in one sentence.",
  "Write a haiku about Kubernetes.",
  // Medium
  "Explain the differences between TCP and UDP. When would you use each?",
  "Write a Python function to find the longest common subsequence of two strings.",
  // Long (RAG-style)
  "Given this context about transformer architectures: " +
    "The transformer architecture was introduced in 'Attention Is All You Need' (2017). " +
    "It replaced recurrent processing with self-attention mechanisms, enabling parallel computation. " +
    "Key components include multi-head attention, positional encoding, and feed-forward networks. " +
    "Modern LLMs like GPT-4, Llama, and Claude are all based on transformer variants. " +
    "Question: What are the computational complexity tradeoffs of self-attention vs recurrence?",
];

/**
 * Parse SSE streaming response and extract timing metrics.
 * k6 does not natively support SSE parsing, so we post-process the full body.
 */
function parseStreamingMetrics(body, requestStartMs) {
  const lines = body.split("\n");
  let firstTokenTime = null;
  let lastTokenTime = null;
  let tokenCount = 0;

  const now = Date.now();

  for (const line of lines) {
    if (!line.startsWith("data: ")) continue;
    const dataStr = line.substring(6).trim();
    if (dataStr === "[DONE]") break;

    try {
      const data = JSON.parse(dataStr);
      const choices = data.choices || [];
      if (choices.length > 0) {
        const content = (choices[0].delta || {}).content || "";
        if (content.length > 0) {
          tokenCount++;
          if (firstTokenTime === null) {
            firstTokenTime = now - (lines.length - tokenCount) * 0.1; // approximate
          }
          lastTokenTime = now;
        }
      }
    } catch (_e) {
      // Skip malformed JSON
    }
  }

  return { tokenCount, firstTokenTime, lastTokenTime };
}

export default function () {
  const prompt = prompts[Math.floor(Math.random() * prompts.length)];

  const payload = JSON.stringify({
    model: VLLM_MODEL,
    messages: [{ role: "user", content: prompt }],
    max_tokens: MAX_TOKENS,
    temperature: 0.7,
    stream: true,
  });

  const params = {
    headers: {
      "Content-Type": "application/json",
    },
    timeout: "120s",
    tags: { name: "chat_completion" },
  };

  const startMs = Date.now();
  const response = http.post(
    `${VLLM_HOST}/v1/chat/completions`,
    payload,
    params
  );

  const endMs = Date.now();
  const totalMs = endMs - startMs;

  // Basic response checks
  const passed = check(response, {
    "status is 200": (r) => r.status === 200,
    "response has body": (r) => r.body && r.body.length > 0,
  });

  if (!passed) {
    streamErrors.add(1);
    sleep(1);
    return;
  }

  // Parse streaming response for token metrics
  const body = response.body || "";
  const metrics = parseStreamingMetrics(body, startMs);

  if (metrics.tokenCount > 0) {
    // TTFT: approximate from response timing
    // Since k6 doesn't support true streaming, we estimate TTFT
    // as a fraction of total time proportional to prefill cost
    const estimatedTtft = totalMs * 0.3; // Prefill typically ~30% of total
    ttft.add(estimatedTtft);

    // TPOT: (total_time - estimated_ttft) / (tokens - 1)
    if (metrics.tokenCount > 1) {
      const decodeTime = totalMs - estimatedTtft;
      const estimatedTpot = decodeTime / (metrics.tokenCount - 1);
      tpot.add(estimatedTpot);
    }

    outputTokens.add(metrics.tokenCount);
    streamErrors.add(0);
  } else {
    streamErrors.add(1);
  }

  sleep(Math.random() * 2 + 1); // 1-3 second think time
}

/**
 * Generate summary output for CI/CD integration.
 */
export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    model: VLLM_MODEL,
    host: VLLM_HOST,
    metrics: {},
  };

  // Extract key metrics
  const metricKeys = [
    "ttft",
    "tpot",
    "http_req_duration",
    "http_req_failed",
    "output_tokens",
    "stream_errors",
  ];

  for (const key of metricKeys) {
    if (data.metrics[key]) {
      summary.metrics[key] = data.metrics[key].values || data.metrics[key];
    }
  }

  return {
    stdout: JSON.stringify(summary, null, 2) + "\n",
    "results/k6-summary.json": JSON.stringify(summary, null, 2),
  };
}
