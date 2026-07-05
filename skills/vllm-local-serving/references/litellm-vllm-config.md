# LiteLLM Config Snippets for vLLM Backends

## Local vLLM (same host as LiteLLM container, using host networking)

```yaml
- model_name: qwen36-nvfp4
  litellm_params:
    model: openai/nvidia/Qwen3.6-35B-A3B-NVFP4
    api_base: http://host.docker.internal:8093/v1
    api_key: sk-dummy
    merge_reasoning_content: true
  model_info:
    max_input_tokens: 262144
    max_output_tokens: 32768
```

## Remote vLLM node (via Tailscale)

```yaml
- model_name: rig-qwen27-nvfp4
  litellm_params:
    model: openai/nvidia/Qwen3.6-27B-NVFP4
    api_base: http://3090-rig.tailf9bab6.ts.net:8888/v1
    api_key: sk-dummy
    merge_reasoning_content: true
  model_info:
    max_input_tokens: 262144
```

## Mixed Cluster Example (llama.cpp + vLLM + ollama)

See the main litellm_config.yaml in use on the DGX primary. vLLM entries coexist with GGUF llama-heavy / light entries and host.docker.internal ollama entries.

## Tips
- Always use a stable `model_name` alias in LiteLLM for Hermes / agents.
- The `model:` field under litellm_params should be `openai/<exact-id-reported-by-/v1/models>`.
- For Qwen3 reasoning models, `merge_reasoning_content: true` is often useful.
- Central LiteLLM can load-balance or fallback between a heavy vLLM node and lighter GGUF nodes using router settings (future).
