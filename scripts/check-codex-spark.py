#!/usr/bin/env python3
"""Exercise Spark through Codex app-server, including a real edit and test run."""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".config/lightning-compute/codex")
    parser.add_argument("--model", default="qwen36-nvfp4")
    parser.add_argument("--sandbox", choices=["read-only", "workspace-write", "danger-full-access"],
                        default="workspace-write", help="Permission mode for this temporary test session only")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    state_dir = args.state_dir.expanduser().resolve()
    if not (state_dir / "config.toml").is_file():
        parser.error("Run setup-t3-spark.py install first")
    with tempfile.TemporaryDirectory(prefix="spark-coding-test-") as directory:
        root = Path(directory)
        (root / "calculation.py").write_text("def add(a, b):\n    return a - b\n")
        (root / "test_calculation.py").write_text(
            "import unittest\nfrom calculation import add\n\n"
            "class AdditionTest(unittest.TestCase):\n"
            "    def test_positive(self):\n        self.assertEqual(add(7, 5), 12)\n"
            "    def test_negative(self):\n        self.assertEqual(add(-2, -3), -5)\n"
        )
        # Use the same dedicated Codex home that T3's homePath setting selects.
        environment = dict(os.environ, CODEX_HOME=str(state_dir))
        with tempfile.TemporaryFile(mode="w+") as stderr:
            child = subprocess.Popen(
                ["codex", "app-server", "--strict-config"], cwd=root, env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True,
            )
            messages = queue.Queue()

            def read_messages():
                for line in child.stdout:
                    try:
                        messages.put(json.loads(line))
                    except ValueError:
                        continue
                messages.put(None)

            reader = threading.Thread(target=read_messages, daemon=True)
            reader.start()
            deadline = time.monotonic() + args.timeout
            next_id = 0
            commands = []
            turn_result = None

            def send(message):
                child.stdin.write(json.dumps(message) + "\n")
                child.stdin.flush()

            def receive():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Codex app-server smoke test timed out")
                try:
                    message = messages.get(timeout=remaining)
                except queue.Empty:
                    raise TimeoutError("Codex app-server smoke test timed out") from None
                if message is None:
                    stderr.seek(0)
                    raise RuntimeError("Codex app-server exited: " + stderr.read()[-2000:])
                return message

            def handle(message):
                nonlocal turn_result
                if "id" in message and "method" in message:
                    # A test must not silently approve extra permissions or user questions.
                    send({"id": message["id"], "error": {"code": -32601, "message": "Interactive requests are unavailable in this smoke test"}})
                params = message.get("params", {})
                if message.get("method") == "item/completed":
                    item = params.get("item", {})
                    if item.get("type") == "commandExecution":
                        commands.append(item)
                        print(f"Tool exit {item.get('exitCode')}: {item.get('command', '')[:250]}", flush=True)
                    elif item.get("type") == "agentMessage":
                        print("Model: " + item.get("text", "")[:700], flush=True)
                if message.get("method") == "turn/completed":
                    turn_result = params["turn"]

            def rpc(method, params):
                nonlocal next_id
                next_id += 1
                request_id = next_id
                send({"id": request_id, "method": method, "params": params})
                while True:
                    message = receive()
                    if message.get("id") == request_id and "method" not in message:
                        if "error" in message:
                            raise RuntimeError(f"{method}: {message['error']}")
                        return message["result"]
                    handle(message)

            try:
                rpc("initialize", {"clientInfo": {"name": "lightning_compute_smoke", "version": "1.0"},
                                   "capabilities": {"experimentalApi": True}})
                send({"method": "initialized", "params": {}})
                account = rpc("account/read", {})
                if account.get("requiresOpenaiAuth"):
                    raise RuntimeError("Spark instance unexpectedly requires OpenAI authentication")
                visible_catalog = rpc("model/list", {})
                if any(model["model"] == args.model for model in visible_catalog["data"]):
                    raise RuntimeError("Local model is exposed as a built-in Codex model; T3 can hide it as legacy. Rerun setup-t3-spark.py install")
                catalog = rpc("model/list", {"includeHidden": True})
                slugs = [model["model"] for model in catalog["data"]]
                if args.model not in slugs:
                    raise RuntimeError(f"{args.model} is missing from the Codex model catalog")
                selected = next(model for model in catalog["data"] if model["model"] == args.model)
                reasoning_effort = selected["defaultReasoningEffort"]
                print("Codex inference metadata (T3 exposes custom models): " + ", ".join(slugs), flush=True)
                thread = rpc("thread/start", {"cwd": directory, "model": args.model,
                                             "ephemeral": True, "approvalPolicy": "never", "sandbox": args.sandbox})
                if thread.get("modelProvider") != "spark":
                    raise RuntimeError("Test is not using the Spark provider")
                rpc("turn/start", {
                    "threadId": thread["thread"]["id"],
                    "input": [{"type": "text", "text": (
                        "This is an integration smoke test. Read calculation.py, fix add so it adds "
                        "its arguments, and run python3 -m unittest -v. Work only within this temporary "
                        "directory. Do not modify test_calculation.py. Report the test result."
                    )}],
                    "collaborationMode": {"mode": "default", "settings": {
                        "model": args.model, "reasoning_effort": reasoning_effort, "developer_instructions": None,
                    }},
                })
                while turn_result is None:
                    handle(receive())
                if turn_result.get("status") != "completed":
                    raise RuntimeError(f"Codex turn failed: {turn_result.get('error')}")
                # Check the result independently; a model's success claim is insufficient.
                checked = subprocess.run(
                    [sys.executable, "-c", "from calculation import add; assert add(7, 5) == 12; assert add(-2, -3) == -5; assert add(0, 11) == 11"],
                    cwd=root, capture_output=True, text=True, timeout=10,
                )
                if checked.returncode or not commands:
                    raise RuntimeError("Local model did not complete the edit with working tools: " + checked.stderr[-1500:])
                if not any("unittest" in item.get("command", "") and item.get("exitCode") == 0 for item in commands):
                    raise RuntimeError("Local model did not run the requested tests successfully")
                print("PASS: local Codex app-server read, edited, and tested code; independent assertions also passed.")
            finally:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        sys.exit(f"Smoke test failed: {exc}")
