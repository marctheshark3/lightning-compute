#!/usr/bin/env bash
# lightning-compute/scripts/sync-to-hermes.sh
#
# Syncs the vendored Lightning Compute bundle skills from this repo
# into the active Hermes tron profile, then (re)creates the bundle.
#
# Usage:
#   bash scripts/sync-to-hermes.sh
#   bash scripts/sync-to-hermes.sh --bundle-only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_SKILLS_DIR="${HOME}/.hermes/profiles/tron/skills"
BUNDLES_DIR="${HOME}/.hermes/profiles/tron/skill-bundles"

SKILLS_TO_SYNC=(
  "tailnet-llm-node"
  "llama-cpp-local-serving"
  "vllm-local-serving"
  "skill-bundles"
)

BUNDLE_NAME="lightning-compute"
BUNDLE_SKILLS=("tailnet-llm-node" "llama-cpp-local-serving" "vllm-local-serving")

echo "=== Lightning Compute → Hermes sync ==="
echo "Repo: $REPO_ROOT"
echo "Target Hermes skills: $HERMES_SKILLS_DIR"
echo ""

# Ensure directories
mkdir -p "$HERMES_SKILLS_DIR" "$BUNDLES_DIR"

sync_skill() {
  local skill_name="$1"
  local src="$REPO_ROOT/skills/$skill_name"
  local dst="$HERMES_SKILLS_DIR/$skill_name"   # place at top level for simplicity; adjust category if needed

  if [[ ! -d "$src" ]]; then
    echo "WARNING: $src not found in repo, skipping"
    return
  fi

  echo "Syncing $skill_name ..."
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -r "$src"/* "$dst"/
  echo "  → $dst"
}

# Sync skills
if [[ "${1:-}" != "--bundle-only" ]]; then
  for skill in "${SKILLS_TO_SYNC[@]}"; do
    sync_skill "$skill"
  done
fi

# Create / update the bundle
echo ""
echo "Creating bundle: $BUNDLE_NAME"

hermes bundles create "$BUNDLE_NAME" \
  --skill tailnet-llm-node \
  --skill llama-cpp-local-serving \
  --skill vllm-local-serving \
  -d "Lightning Compute: Tailscale cluster node bootstrap + central LiteLLM registration + Hermes wiring. Supports llama.cpp and vLLM (repo images such as MiaAI-Lab NVFP4)." \
  --force 2>&1 | cat

# Also write a versioned copy of the bundle definition into the repo
cat > "$REPO_ROOT/config/lightning-compute.bundle.yaml" << EOF
name: $BUNDLE_NAME
description: 'Lightning Compute: Tailscale cluster node bootstrap + central LiteLLM registration + Hermes wiring'
skills:
- tailnet-llm-node
- llama-cpp-local-serving
- vllm-local-serving
instruction: |
  Use tailnet-llm-node + llama-cpp-local-serving + vllm-local-serving.
  Hardware detection first. Support --backend=vllm --repo=... for "select images from repos".
  On target: run join-node.sh (enhanced) or drive launch directly. Emit full registration block (Backend, port, model id, Tailnet addr).
  On central: patch litellm_config with Tailscale api_base only. Verify cross-connect.
  Prefer Tailscale DNS / 100.x. /lightning-compute for the full experience.
EOF

echo ""
echo "Bundle definition also written to repo: config/lightning-compute.bundle.yaml"
echo ""
echo "=== Sync complete ==="
echo "Run /lightning-compute in Hermes to test."
echo "Skills are now in $HERMES_SKILLS_DIR"
echo "Bundle: $BUNDLES_DIR/$BUNDLE_NAME.yaml"