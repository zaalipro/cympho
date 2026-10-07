"""Contained wrapper and fail-closed server configuration regressions."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/validation_browser.py"
spec = importlib.util.spec_from_file_location("validation_browser", SCRIPT)
browser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browser)


class ValidationBrowserTest(unittest.TestCase):
    def launch(self, environment):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            for name in (
                "_build/test/lib/cympho/ebin/cympho.app",
                "priv/static/assets/app.js",
                "priv/static/assets/app.css",
            ):
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            captured = {}

            class Child:
                pid = 12345
                returncode = 0

                def poll(self):
                    return 0

                def wait(self, timeout):
                    return 0

            def launch_child(args, **kwargs):
                captured.update(kwargs["env"])
                Path(captured["CYMPHO_BROWSER_ROOT"], "cleanup.ok").touch()
                return Child()

            with (
                patch.object(browser, "ROOT", root),
                patch.object(browser, "REPO", repo),
                patch.object(browser, "pressure"),
                patch.object(browser.socket, "socket"),
                patch.object(browser.signal, "signal"),
                patch.object(browser, "reap"),
                patch.object(browser.subprocess, "Popen", side_effect=launch_child),
                patch.dict(os.environ, environment, clear=True),
                contextlib.redirect_stdout(io.StringIO()),
                (root / "lock").open("a+") as lock,
            ):
                browser.start(lock)
            return captured, json.loads((root / "last.json").read_text())

    def test_explicit_database_reaches_child_and_cleanup_report(self):
        env, report = self.launch({"TEST_DB_NAME": "cympho_test_browser_fixture"})
        self.assertEqual(env["TEST_DB_NAME"], "cympho_test_browser_fixture")
        self.assertEqual(report["database"], "cympho_test_browser_fixture")

    def test_portable_default_and_sanitized_child_environment(self):
        env, _ = self.launch({
            "MIX_TEST_PARTITION": "9",
            "DATABASE_URL": "postgres://not-for-fixture",
            "ANTHROPIC_API_KEY": "synthetic-not-a-secret",
            "ERL_FLAGS": "+S 16",
            "TEST_DB_USER": "fixture_role",
            "TEST_DB_PASSWORD": "synthetic-test-password",
        })
        self.assertEqual(env["TEST_DB_NAME"], "cympho_test")
        self.assertEqual(env["TEST_DB_HOST"], "127.0.0.1")
        self.assertEqual(env["ERL_FLAGS"], "+S 2:2 +SDcpu 1 +SDio 1")
        self.assertEqual(env["TEST_DB_USER"], "fixture_role")
        self.assertEqual(env["TEST_DB_PASSWORD"], "synthetic-test-password")
        for key in ("MIX_TEST_PARTITION", "DATABASE_URL", "ANTHROPIC_API_KEY"):
            self.assertNotIn(key, env)

    def test_rejects_non_test_database_before_launch(self):
        for database in ("cympho_dev", "cympho_prod", "", "cympho_test;drop"):
            with self.subTest(database=database):
                with self.assertRaisesRegex(RuntimeError, "test database"):
                    self.launch({"TEST_DB_NAME": database})

    def test_rejects_non_loopback_host_before_launch(self):
        with self.assertRaisesRegex(RuntimeError, "127.0.0.1"):
            self.launch({"TEST_DB_HOST": "db.example.test"})

    def test_server_rejects_unsafe_configuration_before_connecting(self):
        repo = SCRIPT.parent.parent
        with tempfile.TemporaryDirectory(
            prefix="cympho-browser-validation-guard-", dir="/tmp"
        ) as root:
            env = {
                key: os.environ[key]
                for key in ("PATH", "LANG", "MIX_HOME", "MIX_ARCHIVES")
                if key in os.environ
            }
            env.update(
                MIX_ENV="test", TEST_DB_NAME="cympho_test_browser_fixture",
                TEST_DB_HOST="127.0.0.1", PORT="4329",
                HTTP_BIND_IP="127.0.0.1", CYMPHO_BROWSER_ROOT=root,
                HOME=root,
                ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1",
            )
            for override in (
                {"TEST_DB_NAME": "cympho_dev"},
                {"TEST_DB_HOST": "db.example.test"},
                {"MIX_TEST_PARTITION": "9"},
            ):
                with self.subTest(override=override):
                    result = subprocess.run(
                        ["mix", "run", "--no-start", "--no-compile", "--no-deps-check",
                         str(repo / "test/support/browser_fixture_server.exs")],
                        cwd=repo, env={**env, **override}, capture_output=True,
                        text=True, timeout=20,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(
                        "unsafe browser fixture configuration", result.stderr
                    )
                    self.assertEqual(list(Path(root).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
