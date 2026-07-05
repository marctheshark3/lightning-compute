# Repo-Wrapper Pattern for vLLM (Mia-style and similar)

Many community repos (MiaAI-Lab, AEON-7, etc.) publish a self-contained wrapper for a specific high-value model + quantization.

## Standard Structure in Such Repos
- start.sh (or launch)
- stop.sh
- chat_template.jinja (often critical for thinking/tool/vision)
- .gitignore for caches/logs
- README with exact recommended docker image + flags

## How Lightning Compute Uses Them

1. On target node (after Tailscale join + Docker ready):
   ```bash
   git clone https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM
   cd Qwen3.6-27B-NVFP4-vLLM
   export HF_TOKEN=...   # if needed
   ./start.sh
   ```

2. Note the port it prints (often 8888 or 8000).

3. (If the wrapper hardcodes port and you need multiple models): copy the dir, edit PORT / CONTAINER_NAME, or run the underlying docker run with different --port.

4. Produce registration block with:
   - Backend: vllm
   - Port
   - Served model id (what /v1/models returns, usually the HF id)
   - Source repo URL (for reproducibility)

5. Send block to central Hermes running tailnet-llm-node (or /lightning-compute). It patches central litellm_config.yaml using the Tailnet address and verifies.

## Tailnet Considerations
- Wrappers typically use `--network host`. This is fine.
- The host port becomes directly the Tailscale-reachable port.
- From other nodes / central LiteLLM container: reach via magic DNS `node-name.tailnet.ts.net:PORT` (not localhost).

## Making a Wrapper Tailnet-Aware (if needed)
Most "just work". If you want to drive port from outside:
```bash
PORT=8012 ./start.sh
# or temporarily:
sed -i 's/PORT="8888"/PORT="8012"/' start.sh && ./start.sh
```

Or fall back to the generic docker pattern in `generic-vllm-docker.md` using the same flags the repo recommends.

## Benefits
- Reproducible excellent defaults for that exact model (speculative, template, parsers).
- "Select image from repo" UX: user or Hermes just names a GitHub URL + desired model role.
- Still fully compatible with the rest of Lightning Compute (LiteLLM central proxy, Hermes anywhere, Tailscale isolation).

Example alias after wiring:
- `qwen27-nvfp4-specialist` → routes over tailnet to the repo-launched vLLM.
