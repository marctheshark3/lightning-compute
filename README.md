# Lightning Compute

## Distributed GPU Farm over Tailscale + Unified Hermes Access

Connecting multiple local GPU machines (DGX Spark, RTX 3090, laptops, etc.) via Tailscale into a unified compute cluster. Central LiteLLM proxy provides a singular OpenAI-compatible endpoint. Hermes instances (anywhere) consume the cluster safely.

**Easiest way to add a node:** run the wizard (see below).

### Current Hardware
- **DGX Spark** (GB10 aarch64) — Primary/central. Mix of llama.cpp + vLLM (NVFP4 models + repo wrappers e.g. MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM) + LiteLLM :4000. `qwen36-nvfp4` already registered.
- **RTX 3090** (24GB) — Specialist roles (GGUF or vLLM).
- Laptops/small — 7B-class supported.
- Future nodes.

**vLLM support is now first-class** ("select images from repos" or generic vllm/vllm-openai). Everything still cross-connects via central LiteLLM over Tailscale.

### Easy Wizard (one-liner on any machine)

```bash
# Simplest
curl -fsSL https://raw.githubusercontent.com/marctheshark3/lightning-compute/main/bootstrap/join-node.sh | bash

# With Tailscale key + vLLM repo image (e.g. Mia's Qwen)
TS_AUTHKEY=tskey-... bash bootstrap/join-node.sh --backend=vllm --repo=https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM
```

The wizard handles detection (hardware + LAN/Tailscale), prereqs, launch (llama.cpp or vLLM), and prints a ready-to-paste **Registration Block** (also saved to `~/.lightning-compute-registration.txt`).

Many UX patterns (colors, detection, clean flow, --clean support) were adapted from MiaAI-Lab/HermesGW-Desktop-setup with credit in the script. We kept the focus on Lightning Compute's compute + LiteLLM story.

### Skill Bundle (Recommended Way to Use)

The official way to work with this cluster is the **lightning-compute** Hermes skill bundle:

```bash
/lightning-compute set up the 3090 as a specialist node
```

This single command loads:
- `tailnet-llm-node`
- `llama-cpp-local-serving`
- (optionally `vllm-local-serving` for repo images / vLLM flows)

The bundle includes rich default instructions covering hardware detection, target bootstrap, central LiteLLM registration, and Tailscale-only addressing.

#### Creating / Updating the Bundle
```bash
hermes bundles create lightning-compute \
  --skill tailnet-llm-node \
  --skill llama-cpp-local-serving \
  --skill vllm-local-serving \
  -d "Lightning Compute: Tailscale cluster node bootstrap (wizard) + central LiteLLM registration + Hermes wiring" \
  --force
```

### Portable Skills (for Others + Versioning)

All skills required by the bundle are vendored in this repo under `skills/` so anyone can track versions and reproduce the setup:

- `skills/tailnet-llm-node/` — Cluster node bootstrap, hardware detection, registration block, central wiring
- `skills/llama-cpp-local-serving/` — Core Docker launch patterns, LD_LIBRARY_PATH, context sizing, LiteLLM integration (vendored copy)
- `skills/skill-bundles/` — Foundational skill for creating bundles like this one

A convenience script is provided:

```bash
# From inside the repo (on a machine with Hermes)
bash scripts/sync-to-hermes.sh
```

This will copy the vendored skills into your active Hermes profile and (re)create the `lightning-compute` bundle.

You can also copy the versioned bundle definition:
- `config/lightning-compute.bundle.yaml`

### Quickstart (Target → Central Registration)

1. On the target machine (e.g. 3090):
   - Obtain a Tailscale authkey from an existing node.
   - Either run `bootstrap/join-node.sh` directly or let the Hermes skill drive it.
   - The process performs hardware detection (`uname -m`, `nvidia-smi`, RAM) and outputs a structured **Registration Block**.

2. Capture the `=== TAILNET LLM NODE REGISTRATION ===` block (contains Tailnet DNS, IP, port, hardware summary, suggested model alias).

3. On the central machine (DGX or any Hermes with LiteLLM access):
   ```
   /lightning-compute
   ```
   Provide the registration block and ask it to register the node, patch `litellm_config.yaml`, and verify Tailscale reachability.

4. Any Hermes instance (laptop, phone, other nodes):
   Point it at the central LiteLLM proxy's Tailnet address:
   ```
   base_url: http://<central-tailnet-host>:4000/v1
   ```

See `IMPLEMENTATION-PLAN.md` for the full architecture, phases, and original bundling strategy.

### Architecture Highlights
- **Role-based allocation** — Heavy models on DGX, specialist/overflow on 3090-class machines.
- **Tailscale only** — No public ports. All inter-node traffic uses Tailnet DNS or 100.x IPs.
- **LiteLLM as single proxy** — Central router. Hermes (and agents) only ever talk to one address.
- **Skills-first operations** — All bootstrap, detection, registration, and wiring logic lives in the vendored skills for repeatability.

### Key Files
- `bootstrap/join-node.sh` — The polished **wizard** (one-liner, detection, launch, registration block)
- `skills/tailnet-llm-node/SKILL.md` — Drives the wizard + central registration flow
- `skills/vllm-local-serving/SKILL.md` — vLLM + repo image support
- `skills/llama-cpp-local-serving/SKILL.md`
- `scripts/sync-to-hermes.sh`
- `config/lightning-compute.bundle.yaml`
- `templates/agent-cluster-node-setup.md`

### Next Steps
- Run `/lightning-compute` on new nodes (3090, laptop, etc.) choosing llama.cpp or vLLM+repo.
- Iterate hardware detection + backend recommendation (vLLM for NVFP4/repo images).
- Expand the bundle with `vllm-local-serving` when desired (already created and documented).
- Add monitoring / health.

For deeper technical details, see `IMPLEMENTATION-PLAN.md`.
## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

The individual skills in `skills/` declare their own license in their frontmatter (also MIT).
