# Generic vLLM Docker Launch (Lightning Compute)

Minimal working command for a vLLM OpenAI server. Adapt MODEL, PORT, gpu-mem etc.

```bash
MODEL="nvidia/Qwen3.6-27B-NVFP4"
PORT=8000
CACHE_DIR="$HOME/.cache/vllm-$(echo $MODEL | tr '/:' '-')"

mkdir -p "$CACHE_DIR/hf" "$CACHE_DIR/triton"

docker run -d \
  --name "vllm-$(basename $MODEL | tr ':/' '-')" \
  --network host \
  --ipc host \
  --gpus all \
  -e VLLM_TARGET_DEVICE=cuda \
  -e HF_HOME=/root/.cache/huggingface \
  -e TRITON_CACHE_DIR=/root/.triton \
  -v "$CACHE_DIR/hf:/root/.cache/huggingface" \
  -v "$CACHE_DIR/triton:/root/.triton" \
  vllm/vllm-openai:v0.24.0 \
  "$MODEL" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --trust-remote-code \
    --gpu-memory-utilization 0.40 \
    --max-model-len 131072 \
    --enable-prefix-caching \
    --enable-chunked-prefill
```

After ready:
```bash
curl http://localhost:$PORT/v1/models
```

For LiteLLM (if co-located in Docker):
```yaml
api_base: http://host.docker.internal:$PORT/v1
```

For remote Tailscale node registration use the node's Tailnet DNS or 100.x IP + port.

Common production flags seen in this env (Qwen NVFP4):
- `--reasoning-parser qwen3`
- `--speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}'`
- `--chat-template` + template file when advanced behavior needed
- `--tool-call-parser qwen3_coder --enable-auto-tool-choice`
- `--load-format fastsafetensors`
- `--attention-backend flashinfer --moe-backend marlin`

Adjust `--gpu-memory-utilization` and `--max-num-seqs` based on VRAM and desired concurrency.
