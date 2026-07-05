#!/usr/bin/env bash
# lightning-compute / bootstrap/join-node.sh
# Lightning Compute Node Wizard
#
# One-liner friendly wizard to turn a machine (DGX Spark, 3090, laptop, etc.)
# into a Tailscale-secured LLM compute node.
#
# Supports:
#   - llama.cpp (GGUF via Docker)
#   - vLLM (generic or "select image from repo" wrappers, e.g. MiaAI-Lab NVFP4)
#
# Quick start (target machine):
#   curl -fsSL https://raw.githubusercontent.com/marctheshark3/lightning-compute/master/bootstrap/join-node.sh | bash
#
# With options:
#   curl ... | bash -s -- --backend=vllm --repo=https://github.com/MiaAI-Lab/Qwen3.6-27B-NVFP4-vLLM
#   TS_AUTHKEY=... bash join-node.sh --backend=vllm --model=... --port=8000
#
# Inspiration & UX patterns: Many thanks to MiaAI-Lab for the excellent design
# in https://github.com/MiaAI-Lab/HermesGW-Desktop-setup (colors, detection,
# prereqs, --clean, clear output, systemd-friendly thinking, Tailscale awareness).
# We adapted similar ideas here while staying focused on compute node + LiteLLM wiring.
#
# After success: prints + writes a REGISTRATION BLOCK for easy central LiteLLM wiring.
# Works great driven by Hermes /lightning-compute skills or standalone.
#
# Run on this machine or your other machines (3090, laptop with 7B, etc.) when ready.

set -euo pipefail

# ── Colors & helpers (inspired by MiaAI-Lab/HermesGW-Desktop-setup) ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INFO()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
OK()    { echo -e "${GREEN}[  OK  ]${NC}  $*"; }
WARN()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ERROR() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
HEADING() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

CLEAN=0
INTERACTIVE="${INTERACTIVE:-0}"

# Parse args
ROLE="auto"
HARDWARE="auto"
BACKEND="auto"
REPO=""
MODEL=""
PORT=""
TS_AUTHKEY="${TS_AUTHKEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1 ;;
    --role=*) ROLE="${1#*=}" ;;
    --hardware=*) HARDWARE="${1#*=}" ;;
    --backend=*) BACKEND="${1#*=}" ;;
    --repo=*) REPO="${1#*=}" ;;
    --model=*) MODEL="${1#*=}" ;;
    --port=*) PORT="${1#*=}" ;;
    --role) ROLE="$2"; shift ;;
    --hardware) HARDWARE="$2"; shift ;;
    --backend) BACKEND="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    *) WARN "Ignoring unknown arg: $1" ;;
  esac
  shift
done

HEADING "Lightning Compute Node Wizard"
INFO "Role: $ROLE | Hardware hint: $HARDWARE | Backend: $BACKEND"
[ -n "$REPO" ] && INFO "Repo image: $REPO"
[ -n "$MODEL" ] && INFO "Model: $MODEL"

# Simple existing run guard (like Mia's --clean)
check_existing() {
  if [[ -f "$HOME/.lightning-compute-registration.txt" && $CLEAN -eq 0 ]]; then
    WARN "Previous registration found at ~/.lightning-compute-registration.txt"
    if [[ "$INTERACTIVE" == "1" ]]; then
      echo -n "  Re-run wizard anyway? [y/N] "
      read -r -t 10 ans || ans=N
      [[ ! "$ans" =~ ^[Yy]$ ]] && { INFO "Exiting (use --clean to force)"; exit 0; }
    else
      INFO "Existing setup detected. Use --clean to overwrite or reconfigure."
    fi
  fi
}
check_existing

# ── Hardware + Network Detection ──
HEADING "Hardware & Network Detection"

ARCH=$(uname -m)
INFO "Architecture: $ARCH"

if command -v nvidia-smi >/dev/null 2>&1; then
  INFO "NVIDIA GPU(s):"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
  VRAM_RAW=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
  # Handle cases like N/A or empty
  if [[ "$VRAM_RAW" =~ ^[0-9]+$ ]]; then
    VRAM_MB=$VRAM_RAW
    VRAM_GB=$(( VRAM_MB / 1024 ))
  else
    VRAM_MB=0
    VRAM_GB=0
  fi
else
  WARN "No nvidia-smi found. CPU-only or NVIDIA drivers not ready."
  VRAM_MB=0
  VRAM_GB=0
fi

RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [[ $VRAM_GB -eq 0 && $RAM_GB -gt 60 ]]; then
  # Unified memory systems (e.g. DGX Spark / GB10)
  WARN "GPU memory reported as N/A (common on unified memory systems). Using system RAM for suggestions."
  VRAM_GB=$(( RAM_GB / 2 ))   # conservative
fi
OK "System RAM: ${RAM_GB}GB | Effective GPU-ish: ${VRAM_GB}GB"

# Network detection (LAN + Tailscale) - borrowed & adapted from Mia's approach
detect_network() {
  LAN_IP=$(ip -4 addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | grep -vE 'docker|virbr|veth|tailscale|lo' | head -1 | awk '{print $2}' | cut -d/ -f1 || true)
  [[ -z "$LAN_IP" ]] && LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)

  TAILSCALE_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}' | cut -d/ -f1 || true)

  HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
}

detect_network
INFO "LAN IP: ${LAN_IP:-not detected}"
INFO "Tailscale IP: ${TAILSCALE_IP:-not connected}"
INFO "Hostname: $HOSTNAME"

# ── Tailscale ──
HEADING "Tailscale Setup"

if ! command -v tailscale >/dev/null 2>&1; then
  INFO "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! tailscale status >/dev/null 2>&1; then
  HOSTNAME_SUFFIX="lc-$(echo ${ROLE} | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]' | cut -c1-8)"
  [[ "$HOSTNAME_SUFFIX" == "lc-" ]] && HOSTNAME_SUFFIX="lc-node"

  if [ -n "$TS_AUTHKEY" ]; then
    INFO "Joining Tailscale with authkey..."
    sudo tailscale up --authkey="$TS_AUTHKEY" --accept-routes --hostname="${HOSTNAME}-${HOSTNAME_SUFFIX}" || true
  else
    INFO "Starting Tailscale (interactive or use TS_AUTHKEY=...)"
    sudo tailscale up --accept-routes --hostname="${HOSTNAME}-${HOSTNAME_SUFFIX}" || true
  fi
else
  OK "Already on Tailscale"
fi

TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
TAILNET_HOST=$(tailscale status --json 2>/dev/null | python3 -c '
import sys, json
try:
  d = json.load(sys.stdin)
  dns = d.get("Self", {}).get("DNSName", "").rstrip(".")
  if dns:
    print(dns)
  else:
    hn = d.get("Self", {}).get("HostName", "")
    print(hn + ".tailnet.ts.net" if hn else "unknown")
except:
  print("unknown")
' 2>/dev/null || echo "${HOSTNAME}.tailnet.ts.net")

OK "Tailscale IP: $TS_IP"
OK "Tailnet DNS: $TAILNET_HOST"

# ── Prerequisites & Docker ──
HEADING "Prerequisites"

check_prereqs() {
  local missing=0

  if ! command -v docker >/dev/null 2>&1; then
    WARN "Docker not found. Attempting install..."
    sudo apt-get update -qq || true
    sudo apt-get install -y docker.io || true
  else
    OK "Docker: $(docker --version | head -1)"
  fi

  if command -v docker >/dev/null 2>&1; then
    if ! docker info 2>/dev/null | grep -q "nvidia"; then
      WARN "NVIDIA Container Toolkit not detected in Docker."
      WARN "For best results on GPU nodes: install nvidia-container-toolkit (see NVIDIA docs)."
    else
      OK "Docker has NVIDIA support"
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    ERROR "curl is required"; missing=1
  fi

  if ! command -v git >/dev/null 2>&1; then
    WARN "git not found (needed for repo images). Installing..."
    sudo apt-get install -y git || true
  fi

  if [[ $missing -eq 1 ]]; then
    ERROR "Missing critical prerequisites. Fix and re-run."
    exit 1
  fi
}

check_prereqs

# Clone this repo for reference (idempotent)
REPO_DIR="$HOME/lightning-compute"
if [ ! -d "$REPO_DIR/.git" ]; then
  INFO "Cloning lightning-compute for patterns and future updates..."
  git clone https://github.com/marctheshark3/lightning-compute.git "$REPO_DIR" 2>/dev/null || WARN "Clone skipped (non-fatal)"
fi

# ── Backend Suggestion & Launch ──
HEADING "Inference Backend & Launch"

DEFAULT_LLAMA_PORT=8080
DEFAULT_VLLM_PORT=8000

# Auto-suggest backend if not specified
if [[ "$BACKEND" == "auto" ]]; then
  if [[ $VRAM_GB -ge 20 ]]; then
    BACKEND="vllm"
    SUGGESTED_PORT=${DEFAULT_VLLM_PORT}
    INFO "Auto-selected vLLM (good VRAM detected)"
  else
    BACKEND="llama.cpp"
    SUGGESTED_PORT=${DEFAULT_LLAMA_PORT}
    INFO "Auto-selected llama.cpp (lighter footprint)"
  fi
else
  SUGGESTED_PORT=$([[ "$BACKEND" == "vllm" ]] && echo $DEFAULT_VLLM_PORT || echo $DEFAULT_LLAMA_PORT)
fi

INFERENCE_PORT="${PORT:-$SUGGESTED_PORT}"

# Role-based model suggestion (expand as needed)
suggest_model() {
  if [[ "$BACKEND" == "vllm" ]]; then
    if [[ -n "$REPO" ]]; then
      echo "from-repo"
    elif [[ $VRAM_GB -ge 40 ]]; then
      echo "nvidia/Qwen3.6-27B-NVFP4"
    else
      echo "${MODEL:-Qwen/Qwen2.5-7B-Instruct}"
    fi
  else
    echo "${MODEL:-Qwen2.5-14B-Instruct-Q5_K_M.gguf}"
  fi
}

if [[ "$BACKEND" == "vllm" ]]; then
  HEADING "vLLM Launch (port ${INFERENCE_PORT})"

  if [[ -n "$REPO" ]]; then
    INFO "Repo-wrapper mode: $REPO"
    WRAPPER_DIR="$HOME/$(basename "$REPO" .git | tr -cd '[:alnum:]-_')"
    if [[ ! -d "$WRAPPER_DIR" ]]; then
      git clone "$REPO" "$WRAPPER_DIR" || { ERROR "Failed to clone repo"; exit 1; }
    fi
    cd "$WRAPPER_DIR"

    if [[ -f start.sh ]]; then
      # Robust port + container name overrides
      if grep -q 'PORT=' start.sh 2>/dev/null; then
        sed -i 's/PORT="[0-9]\+"/PORT="'"${INFERENCE_PORT}"'"/g' start.sh || true
        sed -i 's/PORT=[0-9]\+/PORT='"${INFERENCE_PORT}"'/g' start.sh || true
      fi
      export PORT="${INFERENCE_PORT}"

      # Avoid name collisions on re-runs
      sed -i 's/CONTAINER_NAME="\([^"]*\)"/CONTAINER_NAME="\1-'"${INFERENCE_PORT}"'"/' start.sh || true

      INFO "Running wrapper ./start.sh (first run may download large model)..."
      ./start.sh || WARN "start.sh finished (check .vllm.log in wrapper dir)"
    else
      WARN "No start.sh — falling back to generic vLLM"
      REPO=""
    fi
  fi

  if [[ -z "$REPO" ]]; then
    VLLM_MODEL=$(suggest_model)
    VLLM_IMAGE="vllm/vllm-openai:v0.24.0"
    CONTAINER_NAME="vllm-$(echo "$VLLM_MODEL" | tr '/:' '-')-${INFERENCE_PORT}"

    INFO "Generic vLLM for ${VLLM_MODEL}"

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
      --name "$CONTAINER_NAME" \
      --network host \
      --ipc host \
      --gpus all \
      -e VLLM_TARGET_DEVICE=cuda \
      -e HF_HOME=/root/.cache/huggingface \
      -e TRITON_CACHE_DIR=/root/.triton \
      -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
      -v "$HOME/.cache/triton:/root/.triton" \
      "$VLLM_IMAGE" \
      "$VLLM_MODEL" \
        --host 0.0.0.0 \
        --port "${INFERENCE_PORT}" \
        --trust-remote-code \
        --gpu-memory-utilization 0.40 \
        --max-model-len 32768 \
        --enable-prefix-caching || WARN "docker run had issues — inspect logs"

    INFO "Waiting for readiness..."
    for i in {1..40}; do
      if curl -fsS "http://127.0.0.1:${INFERENCE_PORT}/v1/models" >/dev/null 2>&1; then
        OK "vLLM ready on :${INFERENCE_PORT}"
        break
      fi
      sleep 5
      [[ $((i % 5)) -eq 0 ]] && INFO "  still starting ($i/40)..."
    done
  fi

  SERVED_MODEL="${MODEL:-$([ -n "$REPO" ] && echo 'see-repo' || suggest_model)}"
  OK "vLLM reachable at http://${TS_IP}:${INFERENCE_PORT}/v1"

else
  # llama.cpp path
  HEADING "llama.cpp Launch (port ${INFERENCE_PORT})"
  INFO "Launch driven by tailnet-llm-node + llama-cpp-local-serving skill patterns."
  INFO "Typical: docker run with proper LD_LIBRARY_PATH, -c context, -ngl layers, bind 0.0.0.0"
  SERVED_MODEL="${MODEL:-GGUF-model-configured-via-skill}"
  # For now we leave actual launch to the skill / manual for GGUF consistency
  WARN "llama.cpp launch is skeleton here. Use the skills for full Docker command on this node."
fi

# ── Validation & Registration ──
HEADING "Validation & Registration Block"

REG_FILE="$HOME/.lightning-compute-registration.txt"

MODEL_NAME_SUGGESTED="$( [ "$ROLE" != "auto" ] && echo "${ROLE}-$(echo $BACKEND | tr '[:upper:]' '[:lower:]' | tr -d ' ')" || echo "node-specialist" )"

# Basic validation
VALID_OK=1
if curl -fsS "http://127.0.0.1:${INFERENCE_PORT}/v1/models" >/dev/null 2>&1; then
  OK "Local endpoint responding on :${INFERENCE_PORT}"
else
  WARN "Local /v1/models not yet responding (may still be loading)"
  VALID_OK=0
fi

if [[ -n "$TS_IP" && "$TS_IP" != "unknown" ]]; then
  OK "Tailscale connectivity looks good"
else
  WARN "Tailscale IP not detected — cross-node routing may be limited"
fi

# Write rich registration
cat > "$REG_FILE" << REG
=== LIGHTNING COMPUTE NODE REGISTRATION ===
Generated: $(date)
Hostname: ${HOSTNAME}
Tailnet DNS: ${TAILNET_HOST}
Tailscale IP: ${TS_IP}
LAN IP (for reference): ${LAN_IP:-unknown}

Backend: ${BACKEND}
Inference Port: ${INFERENCE_PORT}
Models URL: http://${TS_IP}:${INFERENCE_PORT}/v1/models

Served model: ${SERVED_MODEL}
${REPO:+Source: ${REPO}}

Hardware: Arch=${ARCH} | VRAM≈${VRAM_GB}GB | RAM=${RAM_GB}GB
Suggested LiteLLM alias: ${MODEL_NAME_SUGGESTED}
Role hint: ${ROLE}

--- LiteLLM config snippet (paste on central) ---
- model_name: ${MODEL_NAME_SUGGESTED}
  litellm_params:
    model: openai/${SERVED_MODEL}
    api_base: http://${TAILNET_HOST}:${INFERENCE_PORT}/v1
    api_key: sk-dummy
  model_info:
    max_input_tokens: 32768

--- Test from central (after wiring) ---
curl -H "Authorization: Bearer sk-dgx-local" http://<central-tailnet-host>:4000/v1/models
curl -H "Authorization: Bearer sk-dgx-local" http://<central-tailnet-host>:4000/v1/chat/completions \
  -d '{"model":"'${MODEL_NAME_SUGGESTED}'","messages":[{"role":"user","content":"hello"}],"max_tokens":16}'

--- Next steps ---
1. Copy the block above (or cat $REG_FILE).
2. On central machine / Hermes with LiteLLM access:
   /lightning-compute
   # or load tailnet-llm-node + vllm-local-serving
   "Register this node using the details below and update litellm_config.yaml"
3. Any Hermes instance points only at the central LiteLLM:
   base_url: http://<central-tailnet>:4000/v1
REG

cat "$REG_FILE"

echo ""
OK "Registration written to: $REG_FILE"
echo ""
INFO "Wizard complete."
if [[ $VALID_OK -eq 1 ]]; then
  OK "This node is ready to be registered centrally."
else
  WARN "Node launched but may need more time to become fully ready."
fi
INFO "For full skill-driven experience: load tailnet-llm-node + vllm-local-serving + llama-cpp-local-serving and run /lightning-compute"
INFO "To run the wizard again (e.g. different backend): bash $0 --clean ..."