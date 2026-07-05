---
name: skill-bundles
description: Create and use skill bundles as one-command groups.
version: 0.1.0
author: Hermes
metadata:
  hermes:
    tags: [Skills, Bundles, Workflow]
---

# Skill Bundles

Skill bundles are small YAML files that load several skills under one slash command. Running /<bundle-name> loads the listed skills plus any optional instruction in a single step. A bundle is only an alias; the referenced skills must already be installed.

## When to Use
- Tasks that repeatedly require the same combination of skills.
- Want a shorter single slash command for a group of skills.
- Codify recurring workflows with preloaded skills and fixed guidance.
- Group skills for cluster setup, reviews, or deployment flows.

## Prerequisites
- Hermes installed with `hermes` CLI available.
- The individual skills listed in the bundle must already exist in ~/.hermes/skills/ or external dirs.
- Write permission to ~/.hermes/skill-bundles/.
- (Optional) Python for the helper script.

## How to Run
Manage bundles by invoking hermes CLI subcommands through the `terminal` tool. Load a bundle in chat by typing /<bundle-name> or instruct the agent after loading this skill. Use the helper script in scripts/ via `terminal` or `execute_code` for YAML generation.

## Quick Reference
- hermes bundles list
- hermes bundles create <name> --skill <s1> --skill <s2> [-d "desc"]
- hermes bundles show <name>
- hermes bundles delete <name>
- hermes bundles reload
- /<bundle-name> [user instruction]
- scripts/generate-bundle.py (helper)

## Procedure
1. Ensure target skills are installed (use `skill_view` or `/skills` to confirm).
2. Create the bundle using the `terminal` tool:
   hermes bundles create lightning-compute --skill tailnet-llm-node --skill llama-cpp-local-serving -d "Tailscale LLM node + inference"
3. (Optional) Use the helper script to generate the YAML:
   python scripts/generate-bundle.py --name lightning-compute --skill tailnet-llm-node --skill llama-cpp-local-serving --desc "Tailscale LLM node + inference" --out ~/.hermes/skill-bundles/lightning-compute.yaml
4. (Optional) Edit the generated YAML to add an "instruction:" block for default guidance.
5. Invoke in chat: /lightning-compute set up the 3090 as specialist node
   The agent receives all listed skills loaded together.
6. To update: re-run create with --force or edit the YAML then run hermes bundles reload through `terminal`.

## Pitfalls
- Bundles take precedence if a bundle name matches an individual skill name.
- Any listed skill that is missing is skipped (agent reports skipped skills).
- Bundles do not install or download skills; they only group existing ones.
- Changes to the YAML directory may require `hermes bundles reload`.
- Invalid YAML will cause creation to fail; prefer the create command or the helper script.

## Verification
Through the `terminal` tool run:
hermes bundles list
hermes bundles show <name>
Then invoke the bundle in chat and confirm the referenced skills' content appears in the loaded context along with any instruction text. Confirm the .yaml file exists at ~/.hermes/skill-bundles/<name>.yaml. Verify the helper with python scripts/generate-bundle.py --help.

This is a vendored copy for Lightning Compute bundle portability.
