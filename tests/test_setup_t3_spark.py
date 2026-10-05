"""Credential handling and settings preservation without a live model backend."""

import contextlib
import http.server
import importlib.util
import io
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import tomllib
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/setup-t3-spark.py"
SPEC = importlib.util.spec_from_file_location("setup_t3_spark", SCRIPT)
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)


class InstallTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.key = "test-" + secrets.token_hex(24)
        self.original = {
            "theme": "dark",
            "providerInstances": {"codex": {"driver": "codex", "enabled": True}},
            "unrelatedSetting": {"preserve": True},
        }
        self.settings = self.root / "settings.json"
        self.settings.write_text(json.dumps(self.original))
        self.args = SimpleNamespace(
            t3_settings=self.settings, state_dir=self.root / "private/codex",
            models=["qwen36-nvfp4"], context_window=131072,
            reasoning_effort="none", base_url="http://127.0.0.1:4000/v1",
        )
        binaries = patch.object(setup.shutil, "which", side_effect=lambda name: "/usr/bin/" + name)
        binaries.start()
        self.addCleanup(binaries.stop)

    def install(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            setup.install(self.args, self.key)
        self.assertNotIn(self.key, output.getvalue())

    def test_private_credentials_preserved_settings_and_idempotent_update(self):
        self.install()
        state = self.args.state_dir
        self.assertEqual(state.stat().st_mode & 0o777, 0o700)
        self.assertEqual((state / "api-key").read_text().strip(), self.key)
        for path in state.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            if path.name != "api-key":
                self.assertNotIn(self.key, path.read_text())
        config = tomllib.loads((state / "config.toml").read_text())
        self.assertEqual(config["model_providers"]["spark"]["auth"]["args"], [str(state / "api-key")])
        updated = json.loads(self.settings.read_text())
        self.assertEqual(updated["theme"], self.original["theme"])
        self.assertEqual(updated["unrelatedSetting"], self.original["unrelatedSetting"])
        self.assertEqual(updated["providerInstances"]["codex"], self.original["providerInstances"]["codex"])
        custom = updated["providerInstances"]["spark-local"]["config"]["customModels"][0]
        catalog = json.loads((state / "models.json").read_text())["models"][0]
        self.assertEqual(custom["slug"], catalog["slug"])
        self.assertEqual(catalog["visibility"], "hide")
        self.assertEqual(custom["capabilities"]["optionDescriptors"][0]["currentValue"], "none")
        backups = list(self.root.glob("settings.before-spark-*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text()), self.original)
        for path in [self.settings, *backups]:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(self.key, path.read_text())
        first_write = self.settings.stat().st_mtime_ns
        self.install()
        self.assertEqual(self.settings.stat().st_mtime_ns, first_write)
        self.assertEqual(list(self.root.glob("settings.before-spark-*.json")), backups)

    def test_rejects_credentials_and_settings_inside_git_worktrees(self):
        for git_directory in [True, False]:
            repo = self.root / ("repo" if git_directory else "worktree")
            repo.mkdir()
            if git_directory:
                (repo / ".git").mkdir()
            else:
                (repo / ".git").write_text("gitdir: /unused/worktree/metadata\n")
            link = self.root / (repo.name + "-link")
            link.symlink_to(repo, target_is_directory=True)
            for target in [repo, link]:
                for setting in ["state_dir", "t3_settings"]:
                    with self.subTest(target=target.name, setting=setting):
                        original = getattr(self.args, setting)
                        setattr(self.args, setting, target / "new/private-data")
                        try:
                            with self.assertRaisesRegex(ValueError, "outside a Git working tree"):
                                self.install()
                            self.assertFalse((repo / "new").exists())
                            self.assertFalse((self.root / "private").exists())
                        finally:
                            setattr(self.args, setting, original)

    def test_rejects_conflicting_instance_without_writing_credentials(self):
        self.original["providerInstances"]["spark-local"] = {"driver": "unrelated"}
        self.settings.write_text(json.dumps(self.original))
        with self.assertRaisesRegex(ValueError, "unrelated spark-local"):
            self.install()
        self.assertFalse(self.args.state_dir.exists())
        self.assertEqual(json.loads(self.settings.read_text()), self.original)

    def test_does_not_overwrite_concurrent_settings_edit(self):
        atomic_write = setup.atomic_write

        def concurrent_edit(path, content):
            atomic_write(path, content)
            if path.name == "config.toml":
                self.settings.write_text('{"concurrentEdit": true}')

        with patch.object(setup, "atomic_write", side_effect=concurrent_edit):
            with self.assertRaisesRegex(ValueError, "settings changed"):
                self.install()
        self.assertEqual(json.loads(self.settings.read_text()), {"concurrentEdit": True})
        self.assertEqual(list(self.root.glob("settings.before-spark-*.json")), [])


class GatewaySecurityTest(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.key = "test-" + secrets.token_hex(24)
        requests = self.requests
        key = self.key

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/destination")
                else:
                    self.send_response(401)
                self.end_headers()
                self.wfile.write(("error containing " + key).encode())

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.url = "http://127.0.0.1:" + str(self.server.server_port)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_authorization_is_not_forwarded_to_redirect_destination(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            setup.request(self.url, self.key, "/redirect")
        self.assertEqual(caught.exception.code, 302)
        caught.exception.close()
        self.assertEqual(self.requests, ["/redirect"])

    def test_http_error_body_does_not_leak_credential_to_cli_output(self):
        with tempfile.TemporaryDirectory() as directory:
            credential = Path(directory) / "api-key"
            credential.write_text(self.key)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "check", "--base-url", self.url,
                 "--api-key-file", str(credential)],
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 401", result.stderr)
        self.assertNotIn(self.key, result.stdout + result.stderr)

    def test_invalid_key_is_rejected_without_printing_its_value(self):
        for suffix in ["\nmalformed", "\x00", "\u2603"]:
            with self.subTest(suffix=repr(suffix)), tempfile.TemporaryDirectory() as directory:
                credential = Path(directory) / "api-key"
                credential.write_text(self.key + suffix)
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "check", "--base-url", self.url,
                     "--api-key-file", str(credential)],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("printable ASCII", result.stderr)
                self.assertNotIn(self.key, result.stdout + result.stderr)
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
