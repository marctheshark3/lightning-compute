# Lightning Compute — Implementation Plan

**Goal**: Tailscale-secured private network fabric for all local GPU/CPU nodes. Unified access via LiteLLM proxy. Easy handoff/bootstrap for new machines (starting with the RTX 3090 rig). Hermes can run anywhere and consume the cluster safely.

**Current State (as of 2026-07)**
- DGX Spark: Primary/central. llama.cpp containers + vLLM containers (including NVFP4 Qwen3.6 variants launched via repo-style or generic) + LiteLLM on 4000. Example: `qwen36-nvfp4` already wired to a vLLM backend.
- litellm_config.yaml defines aliases (tron, heavy-coder, yori/light-general, ornith-*, embeddings).
- Tailscale active (DGX at 100.110.151.120 / spark-adb4.tailf9bab6.ts.net).
- Docs: README.md + architecture.html (diagram showing Tailscale boundary, central LiteLLM, DGX primary, 3090 specialist TBD, capacity nodes).
- Operational: docker-compose.llm-pair.yml, health scripts, llm-recipes/ with downloads + benchmarks.
- Hermes (tron profile): Points to localhost:4000/v1 + sk-dgx-local. Local models available via aliases.
- 3090 (24GB VRAM / 72GB RAM): Documented for ~13B-class models. Not yet on tailnet or running inference.

**Key Principles**
- Everything private on Tailscale (no public exposure).
- Role-based nodes (heavy on capable hardware, specialist/light/batch on others).
- Single source of truth for routing: central LiteLLM (or small set of routers).
- Bootstrap must be trivial for fresh machines.
- Skills-first: Reusable procedures for Hermes (management, bootstrap assistance, health).
- Isolation: Hermes on any device (laptop, phone, work machine) only talks to the proxy. Compute nodes stay protected.

## Architecture (Refined)

### Network Fabric
- Tailscale (or Headscale self-hosted later) as the only connectivity layer.
- Magic DNS preferred: `dgx-spark.tailnet.ts.net`, `3090-rig.tailnet.ts.net`.
- Stable 100.x IPs as fallback.
- ACLs (via Tailscale admin or policy file):
  - LLM nodes can reach each other on inference ports.
  - Hermes clients (tagged devices) can reach LiteLLM proxy port only.
  - No direct internet required for inference after join.

### Compute Nodes
- **Primary (DGX Spark)**: Heavy models, high context, multi-session. Current stack.
- **Specialist (RTX 3090)**: Lighter/faster models, coding specialist, batch jobs, overflow when primary busy. ~13B Q5_K_M sweet spot.
- **Future**: Additional GPUs, CPU-only overflow, Raspberry Pi cluster for tiny models, etc.
- Each node runs one or more inference backends (llama.cpp or vLLM) on Tailscale-only ports.
- Nodes can announce capabilities (VRAM, arch, loaded models) for smart routing.

### Routing Layer (Singular Access)
- **Preferred**: One central LiteLLM (on DGX or dedicated gateway node) that proxies to all backends.
  - `api_base: http://3090-rig.tailnet.ts.net:8080/v1`
  - Aliases + tags + fallbacks in config.
- Alternative: LiteLLM per node + thin higher router (another LiteLLM or simple proxy).
- Config lives in this repo (versioned). Central node pulls on deploy or uses git + restart.

### Hermes Layer
- Any Hermes instance (any device) points `base_url` to the central proxy's Tailscale address + `sk-dgx-local`.
- Full power of Hermes (tools, delegation, skills, memory) while heavy lifting stays on protected nodes.
- Bonus: Run Hermes *on* a compute node for lowest latency when local.
- Malware / isolation win: Compromised client device only sees the proxy. No model weights, no direct GPU access.

## Bootstrap / Handoff for Fresh Nodes (incl. 3090)

**Target UX**:
```bash
# On the 3090 machine (fresh Ubuntu or whatever)
curl -fsSL https://raw.githubusercontent.com/youruser/lightning-compute/main/bootstrap/join-node.sh | bash -s -- --role=specialist --hardware=3090
# Or with explicit Tailscale key
TS_AUTHKEY=tskey-... curl ... | bash
```

**What the bootstrap does** (idempotent, re-runnable):
1. Detect hardware (arch: x86_64 vs aarch64, GPU via nvidia-smi + VRAM, RAM, CUDA version).
2. Install/ensure Tailscale.
3. Join tailnet (using provided authkey or interactive).
4. Install Docker + NVIDIA Container Toolkit (or confirm existing).
5. Clone or update this repo.
6. Select role + recommended model(s) (or accept --model).
7. Download required GGUF (or HF for vLLM).
8. Launch appropriate inference server(s) via Docker (using patterns from llama-cpp-local-serving skill).
9. (Optional) Health check + announce to central (simple curl to a registration endpoint on the proxy or a small registry service).
10. Print the exact backend URL to add to central LiteLLM config and test command.

**Differentiators by hardware**:
- DGX Spark (aarch64/Grace): Current sbsa CUDA paths, high context, current compose.
- 3090 (x86_64 discrete): Standard CUDA, lower context/shm if needed, lighter models.
- Script branches on detection.

**Tailscale key generation (on any existing tailnet machine)**:
```bash
tailscale login --authkey=$(tailscale auth key create --reusable --tags=tag:llm-node --expiry=90d)
```
Store the key securely; share one-time or reusable with ACL scoping.

**Deliverables for bootstrap**:
- `bootstrap/join-node.sh` (main handoff script).
- `bootstrap/Dockerfile.node` (optional fully containerized path).
- `bootstrap/detect.sh` (hardware + role logic).
- Role configs in `nodes/3090/`, `nodes/dgx-spark/`, etc.
- Update to llama-cpp-local-serving patterns for cross-arch.

## Central LiteLLM & Config Management

- Keep current docker-compose + litellm_config.yaml as base.
- Make config templated or use environment + node labels.
- When adding a node:
  1. Bootstrap runs on new machine.
  2. Note the Tailscale hostname/port.
  3. Edit `config/litellm_config.yaml` (or use a skill/tool to patch).
  4. Redeploy LiteLLM on central (or use LiteLLM's hot-reload if enabled).
- Future: Simple registration endpoint (FastAPI sidecar on central) that nodes POST capabilities to; script or skill updates the config.

## New Hermes Skill: tailnet-llm-node (or llm-cluster)

**Why this is perfect**:
- You love skills.
- Skills give persistent, versioned, reusable procedures across all your Hermes instances.
- Can be loaded on a "manager" Hermes (laptop) or even on nodes themselves.
- Ties directly to existing `llama-cpp-local-serving` and `serving-llms-vllm`.

**What the skill provides** (tools + commands):
- `bootstrap-node` — generate the exact curl command + authkey instructions for a target machine.
- `register-backend` — add/update a model's api_base in central litellm_config (with validation).
- `cluster-status` — query health of all known nodes via Tailscale + health endpoints.
- `suggest-role` — based on detected hardware (or passed specs).
- `pull-config` / `sync-config` — help nodes or central pull latest from repo.
- Integration with existing launch patterns (reuse the docker commands from the skill).

**Implementation**:
- Create in this repo under `skills/tailnet-llm-node/SKILL.md`.
- Reference the llama-cpp-local-serving references for launch patterns.
- Can call out to terminal/docker on the machine where Hermes runs (when bootstrapping remotely or locally).
- Later: MCP server exposure for other agents.

## Phased Implementation

**Phase 0 — Repo & Docs (now)**
- This repo (private).
- Move/enhance current docs + add IMPLEMENTATION-PLAN.md, bootstrap skeletons.
- Update README with Tailscale focus and "Hermes anywhere" story.

**Phase 1 — 3090 Handoff**
- Generate Tailscale key.
- Develop/test join-node.sh on a test machine or the 3090.
- Launch a light model server on 3090.
- Manually add to DGX LiteLLM config + test routing.
- Update PORT_REGISTRY, health scripts.
- Document exact steps.

**Phase 2 — Skills & Automation**
- Author `tailnet-llm-node` skill.
- Make bootstrap use the skill patterns where possible.
- Add simple registration or config patch helper.
- Test Hermes from another device pointing at tailnet proxy address.

**Phase 3 — Polish & Expansion**
- Advanced LiteLLM routing (model tags, fallbacks by capability, load awareness).
- Per-node LiteLLM option + discovery.
- Monitoring dashboard updates.
- vLLM vs llama.cpp decision matrix per role.
- ACL policy file in repo.
- Support for more node types.

**Phase 4 — Safety & Future**
- Formalize isolation story (Hermes clients vs compute nodes).
- Optional Headscale for full self-hosting.
- Model registry + capability advertisement.
- Integration with fine-tuning / batch jobs routing to appropriate nodes.

## Risks & Mitigations
- Tailscale key leakage → Use short-lived or tightly ACL'd keys; document revocation.
- Config drift → Version in git; make redeploy trivial.
- Model download bandwidth on new nodes → Pre-stage or use shared NFS/NAS over tailnet (advanced).
- Auth for LiteLLM → Keep master key simple for now (or add per-client keys later).
- Arch differences → Strong detection + templates in bootstrap.

## Success Metrics
- New node joins and serves a model in <30-60 min with one command.
- Hermes on laptop can use "heavy-coder" and it routes correctly (possibly to DGX or 3090 depending on load).
- All inference traffic stays on tailnet.
- Docs + scripts are the only thing needed for a fresh machine.

## Open Questions / Decisions
- Central LiteLLM on DGX or move to a dedicated lightweight gateway node?
- Use magic DNS everywhere or mix with IPs?
- Store master key in Tailscale + env or separate secret?
- vLLM (generic or "select from repo" like MiaAI-Lab NVFP4 wrappers) vs llama.cpp decision per role/hardware. Both supported and coexist via LiteLLM.
- How much auto-discovery vs explicit config in litellm_config?

Update this plan as we execute. Track progress in repo.

---

**Next concrete steps after repo is live**:
1. Fix gh auth on this machine if needed (`gh auth login`).
2. Push initial content.
3. Generate Tailscale key for 3090.
4. Develop/test bootstrap script.
5. Author the tailnet-llm-node skill.
6. Wire the 3090.

This gives you a clean, private, skills-driven, Tailscale-native distributed local compute fabric that grows with your hardware and keeps Hermes flexible and safe.

## Updated: Bundled Hermes Skill + Practical Target-to-Central Flow (as of 2026-07-01)

### The Skill: tailnet-llm-node
- Lives in-repo at `skills/tailnet-llm-node/SKILL.md`.
- Explicitly extends/bundles `llama-cpp-local-serving` + `vllm-local-serving`.
- Supports "select image from repo" (clone + start.sh of things like MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM) as well as generic vLLM and GGUF.
- Provides target bootstrap guidance, structured REGISTRATION BLOCK output, central registration, and agent handoff file generation.
- Loading for bundled "single flow":
  /skill tailnet-llm-node
  /skill llama-cpp-local-serving
  Then instruct: "run the full bundled tailnet-llm-node setup..."

### Practical Workflow (user-described)
1. Run skill (or bootstrap/join-node.sh) on the target compute machine → gets Tailscale + inference + details.
2. Capture the registration block / generated file.
3. Add the details to shared folder or pass to central Hermes instance.
4. Run the bundled skill on central (or appropriate Hermes) to update LiteLLM config, create the Tailscale-backed connection, and wire Hermes.

### Generated Files for Agents
- templates/agent-cluster-node-setup.md (self-contained prompt another agent can follow).

### Bundling & Easy Invocation
Skills are loaded then driven by natural language for the "run these bundled skills to setup everything" experience. The generated template file provides a portable artifact when direct skill loading on the receiver is not immediate.

See skills/tailnet-llm-node/SKILL.md for the full definition and recipes.

**Wizard UX note**: The primary user entrypoint is now the polished `bootstrap/join-node.sh` wizard (one-liner + flags). UX patterns (structured logging, detection, prereqs, clean output) were adapted from MiaAI-Lab/HermesGW-Desktop-setup with credit. The wizard is the "easy" path; the skills provide the Hermes-orchestrated version of the same flow.
