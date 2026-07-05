---
name: vllm-local-serving
description: "Launch and manage vLLM inference servers (generic or from ready-made GitHub repo wrappers like MiaAI-Lab NVFP4) via Docker on NVIDIA Linux (aarch64/x86_64). OpenAI-compatible, proxy via central LiteLLM, integrate with Lightning Compute cluster over Tailscale. Supports NVFP4, high context, speculative decoding, custom chat templates."
version: 0.1.0
author: Lightning Compute + Hermes
license: MIT
metadata:
  hermes:
    tags: [vllm, docker, inference, tailscale, litellm, nvfp4, qwen]
    related_skills: [tailnet-llm-node, llama-cpp-local-serving, skill-bundles]
---

# vLLM Local Serving (Docker + LiteLLM + Repo Images)

Class-level skill for running vLLM (especially quantized models like nvidia/*-NVFP4, Qwen3.6 family) with Docker on NVIDIA hardware. Supports both:

- **Generic**: `vllm/vllm-openai` image + explicit serve flags.
- **Repo-wrapper** (recommended for complex tuned deployments): Clone a repo such as https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM that bundles `start.sh`, custom `chat_template.jinja`, tuned flags (MTP speculative, flashinfer, etc.), then run it.

Everything stays OpenAI-compatible so central LiteLLM can route and any Hermes (anywhere on tailnet) can consume via the single proxy.

## When to Choose vLLM vs llama.cpp

Use vLLM when:
- Model is published as HF safetensors + quantized for vLLM (NVFP4 / ModelOpt / FP8).
- You want high throughput, prefix caching, chunked prefill, speculative decoding (MTP), async scheduling.
- Vision / multi-modal + advanced tool calling / reasoning parsers (Qwen3 specific).
- Large context (128k–262k) dense models on capable hardware (GB10/DGX Spark, 3090 24GB for ~27B NVFP4 at low gpu-mem-util, etc.).
- The providing repo gives a tuned wrapper (e.g. MiaAI-Lab style).

Use llama.cpp (GGUF) for:
- Maximum compatibility, low VRAM with aggressive quants, CPU fallback, simpler GGUF workflow.

Lightning Compute supports **both** side-by-side on the same node or across nodes. LiteLLM unifies them.

## Core Launch Patterns

### 1. Generic vLLM (no wrapper repo)

```bash
docker run -d \
  --name my-vllm-model \
  --network host \
  --ipc host \
  --gpus all \
  -e VLLM_TARGET_DEVICE=cuda \
  -e HF_HOME=/root/.cache/huggingface \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  -v "$HOME/.cache/triton:/root/.triton" \
  vllm/vllm-openai:v0.24.0 \
  nvidia/Qwen3.6-27B-NVFP4 \
    --host 0.0.0.0 \
    --port 8000 \
    --trust-remote-code \
    --gpu-memory-utilization 0.40 \
    --max-model-len 131072 \
    --enable-prefix-caching \
    --enable-chunked-prefill \
    --reasoning-parser qwen3 \
    ...
```

Key flags from production examples in this cluster:
- `--network host --ipc host` (performance on DGX Spark / high-mem unified setups)
- `--gpu-memory-utilization 0.32–0.45` (leave headroom, especially unified memory)
- `--max-model-len 131072` or `262144`
- Speculative: `--speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}'`
- Qwen3: `--reasoning-parser qwen3 --tool-call-parser qwen3_coder --enable-auto-tool-choice`
- Custom template when needed: `--chat-template /workspace/chat_template.jinja`

### 2. Repo-Wrapper Pattern ("select image from repo")

This is the primary new capability for things like MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM.

Typical flow on a target node:

```bash
# 1. Clone the repo that provides the tuned container + template + start/stop
git clone https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM.git
cd Qwen3.6-27B-NVFP4-vLLM

# 2. (Optional) HF token if gated/private
export HF_TOKEN=...

# 3. Optionally override port before running (edit start.sh or export if supported)
# PORT=8888 ./start.sh   # many wrappers hard-code; you may sed or copy+edit

# 4. Run the provided launcher
./start.sh
```

What the good wrappers do:
- Create local HF + Triton caches (mounted into container).
- Mount custom chat_template.jinja.
- Use `--network host`.
- Poll `/v1/models` until ready.
- Write `.vllm.log` and `.vllm.pid`.

After success you get:
```
OpenAI base URL: http://0.0.0.0:8888/v1
```

Then in Lightning Compute:
- Note the actual listening port.
- Wire it via tailnet address into central LiteLLM (see registration below).

**Advantages of repo-wrapper**:
- Owner already tuned speculative decoding, template for thinking/tool use, vision limits, sampling overrides, load-format etc.
- Includes the exact `chat_template.jinja` needed for full feature parity.
- Reproducible "one repo = one great serving experience".

You can treat any GitHub repo that publishes a `start.sh` + vLLM docker invocation + template the same way.

## Hardware Detection + Role Suggestion (with vLLM bias)

Run before choosing:

```bash
ARCH=$(uname -m)
nvidia-smi --query-gpu=name,memory.total --format=csv
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
```

Rough guidance (update with real VRAM):

- DGX Spark / GB10 (aarch64, ~120GB+ unified, high VRAM headroom): Excellent for 27B–35B+ NVFP4 dense or MoE with vLLM + MTP. High context.
- RTX 3090 24GB: 13B–27B NVFP4 or FP8 at conservative gpu-mem-util (0.35–0.45). Good specialist.
- Laptop / smaller: 7B–9B at full precision or light quant, or stick to GGUF llama.cpp for efficiency.

In tailnet-llm-node flows, detection now suggests backend + example repo/image.

## LiteLLM Integration (Local + Cross-Node)

**Local backends** (same machine as LiteLLM, e.g. this DGX):
```yaml
- model_name: qwen36-nvfp4
  litellm_params:
    model: openai/nvidia/Qwen3.6-35B-A3B-NVFP4
    api_base: http://host.docker.internal:8093/v1   # or localhost:8093 if LiteLLM not containerized
    api_key: sk-dummy
  model_info:
    max_input_tokens: 262144
```

**Remote node** (Tailscale):
```yaml
- model_name: 3090-qwen27-nvfp4
  litellm_params:
    model: openai/nvidia/Qwen3.6-27B-NVFP4
    api_base: http://3090-rig.tailf9bab6.ts.net:8888/v1
    api_key: sk-dummy
  model_info:
    max_input_tokens: 262144
```

Central LiteLLM (usually on primary) is the only thing Hermes clients point at:
```
base_url: http://spark-adb4.tailf9bab6.ts.net:4000/v1
key: sk-dgx-local
```

All cross-connect happens over Tailscale. No public exposure.

## Registration Block Additions for vLLM / Repo Images

When bootstrapping a vLLM node, produce (or have the skill output):

```
=== TAILNET LLM NODE REGISTRATION ===
Hostname (Tailnet DNS): ...
Tailscale IP: 100.x.x.x
Backend: vllm
Inference Port: 8888
Health / Models URL: http://.../v1/models
Served model id (as vLLM reports): nvidia/Qwen3.6-27B-NVFP4
Source: repo https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM (or generic)
Hardware summary: ...
LiteLLM snippet:
- model_name: 3090-qwen27-nvfp4-specialist
  litellm_params:
    model: openai/nvidia/Qwen3.6-27B-NVFP4
    api_base: http://<tailnet>:8888/v1
    api_key: sk-dummy
  ...
```

## Common Pitfalls & Fixes

- Port conflict or wrapper hard-codes 8888 → choose distinct ports per model or per node; use host networking carefully.
- Missing chat_template or bad Jinja → the wrapper repo should provide it; mount correctly.
- OOM / low gpu-mem-util → start at 0.35–0.40, increase only after stable.
- host.docker.internal vs tailnet → local containers use host.docker.internal (or service name in compose). Remote nodes always use Tailscale DNS/IP from central LiteLLM.
- Container not reachable from central LiteLLM → check Tailscale ACLs, firewall, confirm `curl http://<tailnet-ip>:PORT/v1/models` works from central.
- ARM64 specific → use images known to work (vllm/vllm-openai with aarch64 support) or the wrapper's recommended tag.
- Readiness polling → wrappers do this; for raw docker run, poll `/v1/models` yourself.

## How to Use With Lightning Compute

**Preferred (easiest)**: Run the wizard directly:

```bash
curl -fsSL https://raw.githubusercontent.com/marctheshark/lightning-compute/main/bootstrap/join-node.sh | bash -s -- --backend=vllm --repo=https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM
```

Or via bundle:
```
/lightning-compute set up a vLLM node using the Mia Qwen repo
```

The wizard (bootstrap/join-node.sh) now has the polished UX (detection, colors, validation, registration file).

Typical flows (via skills or wizard):
- "Set up a vLLM node for the MiaAI Qwen3.6-27B-NVFP4 repo on the 3090"
- Paste registration block to central Hermes to wire into LiteLLM
- Add a small 7B on a laptop node

The tailnet-llm-node skill + wizard together handle the full target → registration → central wiring story.

See also `llama-cpp-local-serving` for the GGUF side and mixed clusters.

## References (in-repo)

- `references/generic-vllm-docker.md`
- `references/repo-wrapper-pattern.md`
- `references/litellm-vllm-config.md`

This skill makes "pick a cool vLLM repo image, run it anywhere in the cluster, and have it appear in the unified Hermes proxy" reliable and repeatable.
