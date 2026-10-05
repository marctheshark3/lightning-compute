#!/usr/bin/env python3
"""Connect a separate T3 Code / Codex instance to Spark's existing LiteLLM."""

import argparse
import getpass
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_MODELS = ["qwen36-nvfp4"]


def require_private_path(path):
    """Never place credentials or settings backups in a Git working tree."""
    if any((parent / ".git").exists() for parent in (path, *path.parents)):
        raise ValueError("Codex state and T3 settings must be outside a Git working tree")


def atomic_write(path, content):
    """Keep credentials private and let T3's settings watcher see a complete file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def request(base_url, key, route, payload=None):
    headers = {"Authorization": f"Bearer {key}"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    req = urllib.request.Request(base_url + route, data=data, headers=headers)
    # Never send the gateway credential to a redirect destination.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    return urllib.request.build_opener(NoRedirect).open(req, timeout=60)


def check_gateway(base_url, key, models):
    with request(base_url, key, "/models") as response:
        available = {row["id"] for row in json.load(response)["data"]}
    missing = set(models) - available
    if missing:
        raise ValueError("Models not advertised by LiteLLM: " + ", ".join(sorted(missing)))
    for model in models:
        # This checks the protocol Codex needs, including streamed function calls.
        payload = {
            "model": model,
            "input": "Call report_status with status SPARK_OK.",
            "max_output_tokens": 512,
            "stream": True,
            "tools": [{
                "type": "function",
                "name": "report_status",
                "description": "Report the integration test status.",
                "parameters": {
                    "type": "object",
                    "properties": {"status": {"type": "string"}},
                    "required": ["status"],
                    "additionalProperties": False,
                },
                "strict": True,
            }],
            "tool_choice": {"type": "function", "name": "report_status"},
        }
        completed = False
        called = False
        with request(base_url, key, "/responses", payload) as response:
            for line in response:
                if not line.startswith(b"data: ") or line.strip() == b"data: [DONE]":
                    continue
                event = json.loads(line[6:])
                if event.get("type") == "response.output_item.done":
                    item = event.get("item", {})
                    if item.get("type") == "function_call" and item.get("name") == "report_status":
                        called = json.loads(item["arguments"]).get("status") == "SPARK_OK"
                if event.get("type") == "response.completed":
                    completed = event.get("response", {}).get("status") == "completed"
        if not (completed and called):
            raise ValueError(f"{model}: streamed Responses tool call did not complete successfully")
        print(f"PASS {model}: Responses streaming and function calling", flush=True)


def model_entry(slug, context_window, reasoning_effort):
    names = {
        "qwen36-nvfp4": "Qwen3.6 35B A3B · Spark",
        "qwen36-think": "Qwen3.6 35B A3B · Spark Thinking",
    }
    return {
        "slug": slug,
        "display_name": names.get(slug, f"{slug} · Spark"),
        "description": "Local inference through the Spark LiteLLM gateway.",
        "default_reasoning_level": reasoning_effort,
        "supported_reasoning_levels": [{
            "effort": reasoning_effort,
            "description": "Reasoning mode configured for this local backend.",
        }],
        "default_reasoning_summary": "none",
        "shell_type": "unified_exec",
        # T3 classifies native Codex catalog entries against its OpenAI manifest.
        # Unknown entries become legacy and disappear from the normal picker.
        # Keep inference metadata here, but expose the model via T3 customModels.
        "visibility": "hide",
        "supported_in_api": True,
        "priority": 0,
        "base_instructions": (
            "You are a coding assistant running in T3 Code. Inspect the workspace, "
            "follow user and repository instructions, make requested changes, and "
            "verify them with appropriate tools. Never invent file contents or tool "
            "results. Ask before destructive actions. Keep responses concise."
        ),
        "support_verbosity": False,
        "default_verbosity": None,
        "apply_patch_tool_type": None,
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "context_window": context_window,
        "effective_context_window_percent": 95,
        "input_modalities": ["text"],
        "supports_search_tool": False,
        "experimental_supported_tools": [],
        "tool_mode": "direct",
    }


def install(args, key):
    settings_path = args.t3_settings.expanduser().resolve()
    state_dir = args.state_dir.expanduser().resolve()
    require_private_path(state_dir)
    require_private_path(settings_path)
    # Require an existing installation instead of creating a misleading settings file.
    original = settings_path.read_text()
    settings = json.loads(original)
    instances = settings.setdefault("providerInstances", {})
    previous = instances.get("spark-local")
    if previous and (previous.get("driver") != "codex" or
                     previous.get("config", {}).get("homePath") != str(state_dir)):
        raise ValueError("An unrelated spark-local instance already exists; choose a different instance ID manually")
    binary = shutil.which("codex")
    if binary is None:
        raise ValueError("Install the Codex CLI and make codex available on PATH first")
    cat = shutil.which("cat")
    if cat is None:
        raise ValueError("This installer requires a POSIX host with cat on PATH")
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_dir.chmod(0o700)
    entries = [model_entry(model, args.context_window, args.reasoning_effort) for model in args.models]
    atomic_write(state_dir / "api-key", key + "\n")
    atomic_write(state_dir / "models.json", json.dumps({"models": entries}, indent=2) + "\n")
    quote = json.dumps
    config = f'''# Generated by Lightning Compute. Used only by the Spark Local instance.
model = {quote(args.models[0])}
model_provider = "spark"
model_catalog_json = {quote(str(state_dir / "models.json"))}
model_context_window = {args.context_window}
model_auto_compact_token_limit = {args.context_window * 3 // 4}
model_reasoning_effort = {quote(args.reasoning_effort)}
model_reasoning_summary = "none"
web_search = "disabled"

[model_providers.spark]
name = "Spark Local"
base_url = {quote(args.base_url)}
wire_api = "responses"
supports_websockets = false

[model_providers.spark.auth]
command = {quote(cat)}
args = [{quote(str(state_dir / "api-key"))}]
refresh_interval_ms = 0

[features]
apps = false
multi_agent = false
code_mode = false
code_mode_only = false
'''
    atomic_write(state_dir / "config.toml", config)
    instances["spark-local"] = {
        "driver": "codex",
        "displayName": "Spark Local",
        "enabled": True,
        "config": {
            "setupMode": "existing",
            "binaryPath": binary,
            "homePath": str(state_dir),
            "launchArgs": "--strict-config",
            "customModels": [
                {"slug": entry["slug"], "name": entry["display_name"],
                 "capabilities": {"optionDescriptors": [{
                     "id": "reasoningEffort", "label": "Reasoning", "type": "select",
                     "options": [{"id": args.reasoning_effort,
                                  "label": "Off" if args.reasoning_effort == "none" else args.reasoning_effort.title(),
                                  "isDefault": True}],
                     "currentValue": args.reasoning_effort,
                 }]}}
                for entry in entries
            ],
        },
    }
    if json.loads(original) != settings:
        # Refuse to overwrite a settings edit made while files were being prepared.
        if settings_path.read_text() != original:
            raise ValueError("T3 settings changed during setup; rerun the installer")
        backup = settings_path.with_name(f"settings.before-spark-{time.time_ns()}.json")
        atomic_write(backup, original)
        atomic_write(settings_path, json.dumps(settings, indent=2) + "\n")
        print(f"Settings backup: {backup}")
    print(f"Installed Spark Local in {settings_path}")
    print(f"Private Codex configuration: {state_dir}")
    print("In T3 Code, create a thread and select Spark Local and a Qwen model.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "install"])
    parser.add_argument("--base-url", default="http://127.0.0.1:4000/v1")
    parser.add_argument("--model", dest="models", action="append", help="Repeat for each model to expose")
    parser.add_argument("--context-window", type=int, default=131072,
                        help="Must not exceed the inference server's configured context (default: 131072)")
    parser.add_argument("--reasoning-effort", choices=["none", "low", "medium", "high"], default="none",
                        help="Use none for the non-thinking Qwen alias (default); match other backends explicitly")
    parser.add_argument("--api-key-file", type=Path)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".config/lightning-compute/codex")
    parser.add_argument("--t3-settings", type=Path, default=Path.home() / ".t3/userdata/settings.json")
    args = parser.parse_args()
    args.models = list(dict.fromkeys(args.models or DEFAULT_MODELS))
    args.base_url = args.base_url.rstrip("/")
    parsed = urllib.parse.urlsplit(args.base_url)
    if parsed.scheme not in ["http", "https"] or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        parser.error("--base-url must be an HTTP(S) API URL without credentials, a query, or a fragment")
    if args.context_window < 4096:
        parser.error("--context-window must be at least 4096")
    if args.api_key_file:
        key = args.api_key_file.expanduser().read_text().strip()
    else:
        key = os.environ.get("SPARK_LITELLM_API_KEY", "").strip()
        if not key and sys.stdin.isatty():
            key = getpass.getpass("LiteLLM API key (stored privately outside the repo): ").strip()
    if not key:
        parser.error("Provide --api-key-file or SPARK_LITELLM_API_KEY, or run in a terminal to enter the key")
    if not all(33 <= ord(character) <= 126 for character in key):
        # urllib includes invalid header values in its exception message.
        parser.error("The API key must contain only printable ASCII characters without whitespace")
    check_gateway(args.base_url, key, args.models)
    if args.action == "install":
        install(args, key)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as exc:
        # Proxy error bodies can contain credentials or internal request details.
        sys.exit(f"Gateway returned HTTP {exc.code}; check the URL, key, model and LiteLLM logs")
    except (OSError, ValueError, KeyError) as exc:
        sys.exit(f"Setup failed: {exc}")
