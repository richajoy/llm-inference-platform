# Speculative Decoding Guide

## What Is Speculative Decoding?

Speculative decoding is an inference optimization that uses a small, fast **draft model** to generate multiple candidate tokens, which are then **verified in parallel** by the larger target model. Since verification (a single forward pass over N tokens) is much faster than generating N tokens autoregressively, this can yield 2-4x latency improvements without changing output quality.

### How It Works

```
Traditional Autoregressive Decoding (5 tokens):
  Step 1: Target model --> token 1    (~40ms)
  Step 2: Target model --> token 2    (~40ms)
  Step 3: Target model --> token 3    (~40ms)
  Step 4: Target model --> token 4    (~40ms)
  Step 5: Target model --> token 5    (~40ms)
  Total: ~200ms

Speculative Decoding (5 tokens, draft generates 5 candidates):
  Step 1: Draft model --> tokens 1,2,3,4,5  (~5ms, small model is fast)
  Step 2: Target model --> verify all 5      (~45ms, one forward pass)
  Step 3: Accept 4 of 5 tokens              (1 rejected, re-draft from there)
  Total: ~50ms  (4x faster)
```

```
+-------------+     5 draft tokens      +---------------+
| Draft Model | ----------------------> | Target Model  |
| (small,fast)|                         | (large, slow) |
+-------------+                         +-------+-------+
      ^                                         |
      |                                         v
      |                                 +---------------+
      +--- re-draft from rejection <--- | Verify &      |
                                        | Accept/Reject |
                                        +---------------+
                                                |
                                                v
                                         Accepted tokens
                                         sent to user
```

### Why It Works (Ops:Byte Perspective)

Recall that decode has AI = B (batch size). Speculative decoding effectively turns N sequential decode steps into 1 prefill-like verification step:

- **Draft model decode**: Small model (e.g., 1B params), AI = 1, but only ~2 GB to stream. Very fast.
- **Target verification**: Processes N tokens simultaneously, AI = N. Moves toward the compute-bound regime.

The net effect: instead of N memory-bound decode steps, you get 1 cheap draft + 1 higher-AI verification.

## EAGLE3 vs Classic Speculative Decoding

### Classic Speculative Decoding

Uses a separate, smaller model from the same family as the draft model.

| Aspect | Detail |
|--------|--------|
| Draft model | Independent smaller model (e.g., Llama 3.2 1B) |
| Requirement | Same tokenizer as target model |
| Acceptance rate | 60-80% per token (varies with task) |
| Speedup | 1.5-2.5x typical |
| GPU memory | Draft model loaded alongside target model |
| Compatibility | Works with any model pair sharing a tokenizer |

### EAGLE3 Speculative Decoding

EAGLE3 (Efficient Autoregressive Language Generation with Enhanced Acceleration) uses a lightweight **feature-based draft head** trained on the target model's hidden states. Instead of a separate model, it reuses the target model's internal features to predict multiple future tokens.

| Aspect | Detail |
|--------|--------|
| Draft model | Lightweight head (~0.5-2B params) trained on target features |
| Requirement | Specific EAGLE3 head trained for the target model |
| Acceptance rate | 75-90% per token (higher than classic) |
| Speedup | 2-4x typical |
| GPU memory | Small overhead (~2-4 GB) |
| Compatibility | Requires pre-trained EAGLE3 head for specific target model |

### Comparison

| Feature | Classic | EAGLE3 |
|---------|---------|--------|
| Acceptance rate | 60-80% | 75-90% |
| Typical speedup | 1.5-2.5x | 2-4x |
| Draft model size | 1-8B params | 0.5-2B params |
| Memory overhead | Significant | Minimal |
| Training required | No (use existing small model) | Yes (train EAGLE3 head) |
| Quality impact | Zero (mathematically lossless) | Zero (mathematically lossless) |

Both approaches are **lossless** -- the output distribution is mathematically identical to standard autoregressive decoding. Rejected tokens are discarded and generation continues from the last accepted token.

## Draft Model Selection Criteria

### For Classic Speculative Decoding

1. **Same tokenizer**: The draft and target model MUST share the same tokenizer. Mismatched tokenizers produce invalid speculations.
2. **Same model family**: Models from the same family (e.g., both Llama 3.x) share tokenizers.
3. **Small enough**: The draft model should be 5-20x smaller than the target. Too large and the draft overhead negates the speedup.
4. **Fast enough**: Draft model decode latency should be <10% of target model decode latency.
5. **Good enough**: Higher draft quality = higher acceptance rate = better speedup.

### For EAGLE3

1. **Pre-trained head available**: Check for EAGLE3 heads trained on your specific target model.
2. **Compatible vLLM version**: EAGLE3 support requires vLLM v0.6.0+ (our platform uses v0.8.5).
3. **Matching architecture**: The EAGLE3 head must match the target model's hidden dimension and layer count.

## Recommended Configurations

### EAGLE3 for Llama 3.3 70B (Recommended)

**Draft model**: `yuhuili/EAGLE3-LLaMA3.3-Instruct-70B`

This is the recommended configuration for this platform. The EAGLE3 head is specifically trained on Llama 3.3 70B Instruct features.

**vLLM configuration** (Profile D):
```bash
vllm serve meta-llama/Llama-3.3-70B-Instruct \
  --tensor-parallel-size 4 \
  --speculative-config '{"method": "eagle3", "model": "yuhuili/EAGLE3-LLaMA3.3-Instruct-70B", "num_speculative_tokens": 5}' \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90
```

**Expected performance:**
- TTFT: Same as non-speculative (prefill is unchanged)
- ITL (Inter-Token Latency): 2-3x lower
- Tokens/s per user: 2-3x higher
- Throughput (high batch): Slight decrease (verification has overhead)

### Classic: Llama 3.2 1B as Draft for Llama 3.3 70B

**Draft model**: `meta-llama/Llama-3.2-1B-Instruct`

Use this if the EAGLE3 head is unavailable or you want a more general approach.

**vLLM configuration:**
```bash
vllm serve meta-llama/Llama-3.3-70B-Instruct \
  --tensor-parallel-size 4 \
  --speculative-model meta-llama/Llama-3.2-1B-Instruct \
  --num-speculative-tokens 5 \
  --speculative-draft-tensor-parallel-size 1 \
  --enable-prefix-caching \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90
```

**Notes:**
- The draft model (1B) runs on a single GPU while the target (70B) uses TP=4
- `--speculative-draft-tensor-parallel-size 1` keeps the draft model on one GPU
- Llama 3.2 1B uses the same tokenizer as Llama 3.3 70B (both Llama 3.x family)

### EAGLE3 for Llama 3.1 8B

For smaller models, speculative decoding has less benefit because decode is already fast. However, if available:

**Draft model**: Check HuggingFace for `EAGLE3-LLaMA3.1-8B-Instruct` models.

**Note**: For 8B models, the draft model overhead may not justify the speedup. Benchmark before deploying.

## Performance Expectations

### Latency Improvement (Single User)

| Configuration | Llama 70B ITL (B=1) | Speedup |
|---------------|---------------------|---------|
| No speculation | ~42 ms/token | 1.0x |
| Classic (1B draft) | ~22 ms/token | ~1.9x |
| EAGLE3 | ~14 ms/token | ~3.0x |

### Throughput Impact (High Batch)

Speculative decoding has a throughput cost at high batch sizes because:
1. The draft model consumes GPU compute
2. Rejected tokens waste verification compute
3. The verification step processes more tokens than pure decode

| Batch Size | No Speculation (tok/s) | EAGLE3 (tok/s) | Difference |
|-----------|----------------------|----------------|------------|
| 1 | 24 | 72 | +3.0x |
| 8 | 190 | 380 | +2.0x |
| 32 | 762 | 900 | +1.2x |
| 64 | 1,523 | 1,400 | -8% |
| 128 | 3,048 | 2,500 | -18% |

At high batch sizes, the overhead of speculative decoding can reduce throughput. The crossover point depends on the acceptance rate and draft model overhead.

### When NOT to Use Speculative Decoding

1. **High-throughput batch processing**: When batch sizes are large (B>32) and latency is not critical, standard decoding achieves higher aggregate throughput.

2. **Very short outputs**: If the average output is <10 tokens, the overhead of loading the draft model outweighs the benefit.

3. **Prefill-dominated workloads**: Speculative decoding only helps decode. If TTFT is the bottleneck (long prompts, short outputs), focus on prefill optimization instead.

4. **Memory-constrained deployments**: The draft model (even EAGLE3's small head) consumes additional GPU memory. On MIG slices, this may not fit.

5. **High acceptance rate tasks**: If the target model already generates tokens very predictably (e.g., structured JSON output), the benefit is diminished because you would generate tokens quickly regardless.

## vLLM Configuration Reference

### EAGLE3 Parameters

```bash
--speculative-config '{
  "method": "eagle3",
  "model": "yuhuili/EAGLE3-LLaMA3.3-Instruct-70B",
  "num_speculative_tokens": 5
}'
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `method` | - | Set to `"eagle3"` for EAGLE3 speculation |
| `model` | - | HuggingFace path to EAGLE3 head |
| `num_speculative_tokens` | 5 | Number of tokens to speculate per step |

### Classic Parameters

```bash
--speculative-model meta-llama/Llama-3.2-1B-Instruct
--num-speculative-tokens 5
--speculative-draft-tensor-parallel-size 1
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--speculative-model` | - | HuggingFace path to draft model |
| `--num-speculative-tokens` | 5 | Tokens to draft per step (3-7 typical) |
| `--speculative-draft-tensor-parallel-size` | 1 | TP for draft model (usually 1) |

### Tuning num_speculative_tokens

| Value | Effect |
|-------|--------|
| 1-2 | Conservative: low rejection overhead, modest speedup |
| 3-5 | Balanced: good speedup with reasonable acceptance rate |
| 6-8 | Aggressive: highest potential speedup but more rejections |
| 9+ | Diminishing returns: later tokens have exponentially lower acceptance |

The optimal value depends on the acceptance rate. For EAGLE3 with ~85% per-token acceptance:
- `num_speculative_tokens=5`: Expected accepted = 5 x 0.85 = 4.25 tokens/step
- `num_speculative_tokens=7`: Expected accepted = 7 x 0.85 = 5.95 tokens/step (but higher verification cost)

Start with 5 and benchmark. Increase if acceptance rate is high (>85%).

## Kubernetes Deployment

Profile D (`inference/vllm/profiles/llama-70b-eagle3/`) deploys Llama 70B with EAGLE3:

```bash
# Deploy
make deploy-70b-eagle3

# Verify
kubectl get pods -n inference -l profile=llama-70b-eagle3

# Check logs for speculation stats
kubectl logs -n inference -l profile=llama-70b-eagle3 | grep -i specul

# Benchmark
make bench-70b  # Compare against non-speculative profile
```

The EAGLE3 draft model is downloaded as part of the model cache job (`inference/model-cache/download-job.yaml`) alongside the target models.
