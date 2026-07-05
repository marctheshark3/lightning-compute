---
name: llama-cpp-local-serving
description: "Launch and manage llama.cpp GGUF inference servers via Docker on NVIDIA Linux (including aarch64/Grace), proxy via LiteLLM, integrate with Hermes / Cursor / agents. Handles LD_LIBRARY_PATH, context sizing, networking, and repeated bootstrap pitfalls."
version: 1.0.0
author: Hermes (from 2026-06-26 session)
license: MIT
---

# llama.cpp Local Serving (Docker + LiteLLM)

Class-level skill for running GGUF models with llama.cpp server in Docker containers on NVIDIA hardware (especially DGX Spark / aarch64), fronted by LiteLLM for OpenAI-compatible access, and consumed by Hermes or other clients.

## Core Pattern

1. Mount the built `llama.cpp/build/bin` and GGUF models.
2. Always set `LD_LIBRARY_PATH=/llama-bin` (or equivalent) when the binary is launched from a volume mount.
3. Use `-c 32768` (or higher) for modern MoE models; never rely on the 8k default.
4. Expose ports to host; LiteLLM reaches them via `host.docker.internal:<port>`.
5. LiteLLM config uses `host.docker.internal` (Linux) or service DNS (compose network).
6. Avoid re-running heavy `apt-get` on every container start — either use a richer base image or accept one-time bootstrap cost.

## Common Pitfalls

- Missing `libllama-server-impl.so` → always export `LD_LIBRARY_PATH`.
- LiteLLM "Connection error" to `llama-heavy` → use `host.docker.internal` when containers are standalone (not compose services).
- ContextWindowExceeded (8192 vs requested 32k+) → relaunch with explicit `-c 32768`.
- Slow container starts on aarch64 → the minimal CUDA base triggers repeated apt installs; consider a pre-baked image for production.

## Hermes Integration

After LiteLLM is healthy on :4000 with master key `sk-dgx-local`:
- `hermes model` → Custom / OpenAI-compatible → base_url `http://localhost:4000/v1`, key `sk-dgx-local`.
- Models appear as the aliases defined in `litellm_config.yaml` (e.g. `tron`, `yori`).

## Tailscale Multi-Node / Cluster Extension

Extend the single-node pattern to a private Tailscale-backed cluster (e.g. DGX Spark primary + 3090 specialist + future nodes). Central LiteLLM proxy (on one node) routes to backends by Tailscale hostname or 100.x IP. Hermes (or any client) points at the proxy's Tailscale address for unified access.

**Core additions to the single-node pattern:**
1. Run inference on each node using the same Docker launch pattern (llama.cpp or vLLM), but bind to 0.0.0.0 and reference via Tailscale DNS/IP in LiteLLM config.
2. Central LiteLLM config uses remote api_base:
   ```yaml
   - model_name: 3090-specialist
     litellm_params:
       model: openai/...
       api_base: http://3090-rig.tailnet.ts.net:8080/v1   # or 100.x.x.x
       api_key: sk-dummy
   ```
3. Hermes config (any device): base_url to the central proxy's Tailscale address (e.g. http://spark-adb4.tailnet.ts.net:4000/v1).
4. Bootstrap for fresh nodes: one-liner script that installs Tailscale, joins with authkey, detects hardware (arch/VRAM), launches the server using the docker patterns above, and prints the backend URL to wire into central config.

**Handoff / bootstrap flow (condensed):**
- Generate Tailscale key on existing node: `tailscale auth key create --reusable --tags=tag:llm-node`.
- On fresh machine (e.g. 3090): `TS_AUTHKEY=... bash join-node.sh --role=specialist --hardware=3090`.
- Script responsibilities: Tailscale join, Docker/NVIDIA setup, model download, launch (reuse LD_LIBRARY_PATH / -c / -ngl patterns), announce backend.
- Differentiate by hardware (aarch64 high-context on Spark vs x86 lighter models on 3090).

**Pitfalls specific to multi-node:**
- Use Tailscale magic DNS or stable IPs (never localhost).
- Central LiteLLM must be able to reach node ports over the tailnet (ACLs).
- Detect and branch launch (aarch64 sbsa CUDA paths vs x86).
- Keep bootstrap idempotent and re-runnable.
- For Hermes "anywhere": client only needs proxy address + key; compute stays isolated behind tailnet.

See `references/tailscale-node-bootstrap.md` for the session-derived bootstrap skeleton, example config additions, and Hermes-over-tailnet setup.

## References

- `references/docker-launch-pattern.md` — minimal working `docker run` command with all flags.
- `references/litellm-config-snippet.md` — example model_list entries using host.docker.internal.
- `references/hermes-provider-setup.md` — exact steps for `hermes model` + config.yaml.
- `references/tailscale-node-bootstrap.md` — Tailscale cluster bootstrap, multi-node routing, fresh-node handoff script patterns, and Hermes remote consumption.

## Related

- Tron-themed naming convention used in this environment (tron = heavy 35B coder, yori = light 14B general).
- Use the skills approach for operational patterns like node bootstrap and cluster wiring (user preference for capturing these as reusable skills).

This is a vendored copy of the official Hermes skill for Lightning Compute portability and versioning.
