#!/usr/bin/env bash
# lightning-compute / bootstrap/join-node.sh
# One-liner friendly handoff for fresh nodes (3090, future machines, etc.)
# into the Tailscale-secured LLM cluster.
#
# Quick start (on target machine):
#   curl -fsSL https://.../join-node.sh | bash -s -- --role=specialist --hardware=3090
#
# With Tailscale key (recommended for headless):
#   TS_AUTHKEY=tskey-... bash join-node.sh --role=3090-specialist
#
# After success: it will print the backend URL to wire into central LiteLLM.

set -euo pipefail

ROLE="${1:-auto}"
HARDWARE="${2:-auto}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

echo "[bootstrap] Lightning Compute node join"
echo "[bootstrap] Target role: $ROLE | hardware hint: $HARDWARE"

# 1. Basic detection (expand this)
ARCH=$(uname -m)
echo "[bootstrap] Arch: $ARCH"

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "[bootstrap] NVIDIA GPU detected:"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
  VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
else
  echo "[bootstrap] No nvidia-smi — CPU or non-NVIDIA path"
  VRAM=0
fi

RAM=$(free -g | awk '/^Mem:/{print $2}')
echo "[bootstrap] System RAM: ${RAM}G"

# 2. Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
  echo "[bootstrap] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if [ -n "$TS_AUTHKEY" ]; then
  echo "[bootstrap] Joining Tailscale with authkey..."
  sudo tailscale up --authkey="$TS_AUTHKEY" --accept-routes --hostname="$(hostname)-llm" || true
else
  echo "[bootstrap] Starting Tailscale interactive login (or use TS_AUTHKEY env)..."
  sudo tailscale up --accept-routes --hostname="$(hostname)-llm" || true
fi

TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
echo "[bootstrap] Tailscale IP: $TS_IP"
echo "[bootstrap] Magic DNS example: $(hostname).your-tailnet.ts.net"

# 3. Docker + NVIDIA (idempotent)
if ! command -v docker >/dev/null 2>&1; then
  echo "[bootstrap] Installing Docker..."
  # Add proper distro-specific install here (Ubuntu example)
  sudo apt-get update -qq
  sudo apt-get install -y docker.io
fi

if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ]; then
  if ! docker info 2>/dev/null | grep -q "nvidia"; then
    echo "[bootstrap] Installing NVIDIA Container Toolkit (example for Ubuntu)..."
    # distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    # ... (standard NVIDIA toolkit steps)
    echo "[bootstrap] (NVIDIA toolkit install steps go here — see llm-recipes or official docs)"
  fi
fi

# 4. Clone/update repo (or minimal bootstrap)
REPO_DIR="$HOME/lightning-compute"
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone https://github.com/marctheshark/lightning-compute.git "$REPO_DIR" || echo "[warn] clone failed — manual step later"
fi

# 5. Launch inference
# Reuse patterns from existing llama-cpp-local-serving skill + docker-compose
# For 3090 (x86, 24GB): lighter models, Q5_K_M etc.
# For DGX (aarch64): current heavy setups

echo "[bootstrap] Launch step (skeleton)"
echo "  - Use llama.cpp or vLLM in Docker"
echo "  - Bind to 0.0.0.0 on tailnet port (e.g. 8080)"
echo "  - Example backend URL once running: http://${TS_IP}:8080/v1  or http://$(hostname).your-tailnet.ts.net:8080/v1"

# 6. Register hint
echo ""
echo "[bootstrap] SUCCESS SKETCH"
echo "1. Note the backend URL above."
echo "2. On central (DGX) machine, add to litellm_config.yaml:"
echo "   - model_name: 3090-specialist"
echo "     litellm_params:"
echo "       model: openai/your-model"
echo "       api_base: http://YOUR-3090-HOSTNAME:8080/v1"
echo "3. Restart LiteLLM."
echo "4. Test: curl -H 'Authorization: Bearer sk-dgx-local' http://central:4000/v1/models"
echo ""
echo "[bootstrap] Full logic will be expanded. See IMPLEMENTATION-PLAN.md and llama-cpp-local-serving skill references."
echo "[bootstrap] Done (skeleton)."