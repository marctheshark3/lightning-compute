# Lightning Compute

## Distributed GPU Farm
Connecting multiple GPU machines via Tailscale into a unified compute cluster.

### Current Hardware
- **DGX Spark** — Primary node, running 12+ models
- **RTX 3090** (24GB VRAM, 72GB RAM) — Can run ~13B models at Q5_K_M
- **Unknown GPU** — TBD hardware spec

### Architecture
- **Role-based node allocation** — Each machine handles workloads based on hardware capacity
- **Tailscale networking** — Secure, no port forwarding, all nodes on same tailnet
- **LiteLLM proxy routing** — Routes requests to appropriate node based on capability

### RTX 3090 Archetype Options
1. **Coding specialist** — Dedicated to code generation/review (Ornith 13B, Qwen Coder)
2. **Batch processor** — Fine-tuning, evaluation runs, benchmark sweeps
3. **Overflow node** — Handles requests when DGX Spark at capacity
4. **General purpose** — Mixed workload based on demand

### Next Steps
1. Define RTX 3090's consistent role/archetype
2. Install Tailscale on RTX 3090 machine
3. Set up llama.cpp with assigned model
4. Extend LiteLLM routing logic
5. Build cluster monitoring dashboard
