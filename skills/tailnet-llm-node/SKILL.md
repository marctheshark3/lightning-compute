---
name: tailnet-llm-node
description: "Bootstrap and manage Tailscale-backed LLM nodes for the Lightning Compute cluster. Extends llama.cpp launches, handles registration, central LiteLLM wiring, and Hermes integration."
version: 0.1.0
author: Tron + Lightning Compute
license: MIT
metadata:
  hermes:
    tags: [tailscale, llm-cluster, bootstrap, node-management, litellm, hermes-integration]
    related_skills: [llama-cpp-local-serving, vllm-local-serving, serving-llms-vllm, skill-bundles]
---

# Tailnet LLM Node (Lightning Compute Cluster Skill)

## Overview
Orchestrates adding compute nodes (DGX Spark, RTX 3090, laptops, future hardware) to a private Tailscale network for distributed local models. Supports **both** llama.cpp (GGUF) and **vLLM** (generic + "select image from repo" wrappers such as MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM).

Extends `llama-cpp-local-serving` and `vllm-local-serving` patterns with higher-level flows for target bootstrap, structured registration, central LiteLLM patching, and Hermes connectivity.

**Goal:** Turn a fresh machine into a registered cluster node reachable by any Hermes via the central proxy. Any backend (llama.cpp or vLLM) appears as a first-class model alias through the unified LiteLLM.

This skill is designed to be used via the **lightning-compute bundle** (`/lightning-compute`) which loads it together with `llama-cpp-local-serving` for a single-slash-command experience.

## When to Use
- Adding a new node (e.g. 3090 rig) to the Lightning Compute cluster.
- Bootstrapping inference on a target machine over Tailscale.
- Registering a backend with central LiteLLM.
- Configuring any Hermes instances to use the cluster via the proxy's Tailscale address.
- Generating connection artifacts for other agents or Hermeses.

Don't use for pure single-node non-Tailscale setups (use `llama-cpp-local-serving` directly) or public/cloud models.

## Prerequisites
- Tailscale installed and authenticated on the network (ACLs allowing LLM node tags).
- Docker + NVIDIA toolkit on target nodes.
- Central LiteLLM config writable (usually on DGX).
- Hermes profile with `skill-bundles` available for creating/using `/lightning-compute`.

## Hardware Detection & Role Suggestion (Critical)
Before launching inference, always perform hardware detection to choose the right model size, quant, context length, **backend** (llama.cpp vs vLLM), and whether to use a repo-wrapper.

Recommended commands (run via `terminal` or in bootstrap):

```bash
# Architecture
ARCH=$(uname -m)
echo "Arch: $ARCH"   # x86_64 or aarch64

# GPU / VRAM
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total --format=csv
  VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
else
  VRAM_GB=0
fi

# System RAM
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
echo "RAM: ${RAM_GB}G"

# Suggested mapping examples (tailnet-llm-node logic)
if [ "$ARCH" = "aarch64" ] && [ "$VRAM_GB" -gt 60 ]; then
  ROLE="heavy-coder"
  BACKEND="vllm"
  SUGGESTED="vLLM + NVFP4 27B-35B class or high-context (Mia repo or generic)"
  CONTEXT=131072
elif [ "$VRAM_GB" -ge 20 ] && [ "$VRAM_GB" -lt 30 ]; then
  ROLE="specialist"
  BACKEND="vllm"   # or llama.cpp for GGUF
  SUGGESTED="vLLM NVFP4 ~13-27B or GGUF Q5 13B"
  CONTEXT=32768
else
  ROLE="light-general"
  BACKEND="llama.cpp"
  SUGGESTED="7B-9B GGUF or small vLLM"
  CONTEXT=8192
fi
```

The `llama-cpp-local-serving` and `vllm-local-serving` patterns are parameterized from detection.

**vLLM bias**: NVFP4 / ModelOpt quants, Qwen3.6 family with reasoning/tool/vision, high context dense models, or when a polished repo wrapper exists → choose vLLM + the repo URL.

## How to Run
**Recommended (single command feel):**
```
/lightning-compute set up the 3090 as specialist node
```

**Manual loading (if not using the bundle):**
```
/skill tailnet-llm-node
/skill llama-cpp-local-serving
```
Then give natural language instructions such as "Run the full bundled setup for a new node" or "Register this backend using the following details..."

For headless targets, fall back to the standalone script in the repo.

## Quick Reference
- `/lightning-compute` — loads the bundle (tailnet-llm-node + llama-cpp-local-serving)
- Target: guide `bootstrap/join-node.sh` + output Registration Block (include hardware summary)
- Central: patch litellm_config.yaml + verify
- Generate handoff: "create agent prompt file for this node"

## Procedure
1. On target machine (e.g. fresh 3090, or laptop with 7B):
   - Get Tailscale auth key from an existing node (admin console → Keys → Generate auth key, make it reusable + tagged).
   - Perform hardware detection (see section above).
   - Choose backend:
     - llama.cpp: `TS_AUTHKEY=*** bash bootstrap/join-node.sh --role=specialist --hardware=3090`
     - vLLM generic: `... --backend=vllm --model=nvidia/Qwen3.6-27B-NVFP4 --port=8000`
     - vLLM "select image from repo": `... --backend=vllm --repo=https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM --role=specialist`
   - The enhanced join-node.sh + skills drive Tailscale, detection, launch (llama.cpp Docker patterns or vLLM wrapper/generic), and emit a rich **Registration Block** (now includes `Backend`, served model id, source repo if any).

2. Capture the block (skill can write it to a file or print cleanly).

3. On central (DGX/Hermes with LiteLLM access):
   - Use `/lightning-compute` (or load tailnet-llm-node + vllm-local-serving + llama-cpp-local-serving).
   - Provide the registration details.
   - Agent patches central `litellm_config.yaml` with Tailscale `api_base`, chooses a good alias, and verifies reachability (`curl` the remote /v1/models via tailnet).

4. Update any Hermes instances (laptop, phone, etc.) to point only at the central proxy's Tailscale address + key. They never talk directly to nodes.

5. (Optional) Generate `templates/agent-cluster-node-setup.md` or similar for another agent.

## Bundled Flow with skill-bundles
The companion `skill-bundles` skill lets you define this grouping permanently:
```
hermes bundles create lightning-compute \
  --skill tailnet-llm-node \
  --skill llama-cpp-local-serving \
  -d "Lightning Compute cluster node setup"
```
Then `/lightning-compute` always loads both with the default instruction.

## Registration Block Format (target output)
```
=== TAILNET LLM NODE REGISTRATION ===
Hostname (Tailnet DNS): ...
Tailscale IP: ...
Backend: vllm   # or llama.cpp
Inference Port: 8888
Models URL: http://.../v1/models
Served model (as reported by backend): nvidia/Qwen3.6-27B-NVFP4
Source repo: https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM   # optional
Hardware summary: Arch=aarch64 VRAM=...GB RAM=...GB
Suggested model_name: 3090-qwen27-nvfp4
...
LiteLLM config snippet (uses Tailnet DNS/IP)...
```

## Common Pitfalls
- Using localhost or non-Tailscale addresses in LiteLLM after joining.
- Missing Tailscale ACLs or key tags.
- Wrong context size or missing LD_LIBRARY_PATH on launch.
- Ignoring hardware detection (trying 35B on 24GB card, or too-small context).
- Forgetting to restart/reload LiteLLM after config changes.
- Hardware mismatch (high-context MoE on DGX vs lighter quants on 3090).

## Verification
- Target: `tailscale status`, `curl http://<tailscale-ip>:<port>/health`
- Central: Tailscale ping to node, `curl` to node backend from central, LiteLLM `/v1/models` shows the new alias.
- Hermes: Call the alias and get a valid response routed to the node.
- End-to-end: Any Hermes (even remote) can use the cluster via the central proxy.

## One-Shot Recipes
**Target bootstrap (llama.cpp):**
```
TS_AUTHKEY=*** bash bootstrap/join-node.sh --role=specialist --hardware=3090
```

**Target vLLM + Mia-style repo image (27B NVFP4 etc.):**
```
TS_AUTHKEY=*** bash bootstrap/join-node.sh --backend=vllm --repo=https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM --role=specialist
```

**Generic vLLM on a node:**
```
... --backend=vllm --model=nvidia/Qwen3.6-27B-NVFP4 --port=8888
```

**Full flow via bundle (recommended):**
```
/lightning-compute set up the 3090 (or this laptop) as vLLM specialist using the Mia Qwen3.6-27B-NVFP4 repo. Do hardware detection, launch, give registration block.
```

**Central registration:**
"Using the lightning-compute bundle, register this node: [paste full block including Backend + repo]. Patch litellm_config using the Tailnet address and verify."

**Handoff to another agent:**
"Using tailnet-llm-node + vllm-local-serving, generate a self-contained prompt for adding a vLLM repo node."

## References & Supporting Files (in this repo)
- `bootstrap/join-node.sh` — The main **wizard** (one-liner friendly, colors, prereq checks, LAN+Tailscale detection, --clean, validation, rich registration block). Run it directly or drive via skills.
- `skills/vllm-local-serving/` — vLLM generic + repo-wrapper (e.g. MiaAI-Lab) patterns.
- `skills/llama-cpp-local-serving/` — GGUF patterns.
- `templates/agent-cluster-node-setup.md`
- `config/` examples.

**Credit**: UX patterns for the wizard (structured output, network detection, clean flow, helpful messaging) were adapted from MiaAI-Lab's HermesGW-Desktop-setup with full attribution in the script header. We kept Lightning Compute focused on GPU node clustering + LiteLLM.

See the vendored skills for "select image from repo" and full cluster wiring.

This makes adding a new compute node (and wiring it) reliable whether you use the wizard standalone or the Hermes skills.
