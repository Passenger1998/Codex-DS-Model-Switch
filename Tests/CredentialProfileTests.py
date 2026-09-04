#!/usr/bin/env python3
"""Credential Profile and Codex provider transaction tests (no real API calls)."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "Support/credential_profiles.py"
SPEC = spec_from_file_location("credential_profiles_test", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CredentialProfileMetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="credential-profile-tests-"))

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_multiple_profiles_resolve_by_id_and_name(self) -> None:
        state = {
            "version": 1,
            "profiles": [
                {"id": "profile-a", "displayName": "Personal"},
                {"id": "profile-b", "displayName": "Work"},
                {"id": "profile-c", "displayName": "Backup"},
            ],
            "activeProfileId": "profile-a",
        }
        self.assertEqual(MODULE.resolve_profile(state, None)["id"], "profile-a")
        self.assertEqual(MODULE.resolve_profile(state, "Work")["id"], "profile-b")
        self.assertEqual(MODULE.resolve_profile(state, "profile-c")["displayName"], "Backup")

    def test_missing_active_and_missing_key_have_explicit_reasons(self) -> None:
        path = MODULE.profile_path(self.temp)
        MODULE.atomic_write(
            path,
            MODULE.state_bytes(
                {
                    "version": 1,
                    "profiles": [{"id": "profile-a", "displayName": "Personal"}],
                    "activeProfileId": "missing-profile",
                }
            ),
        )
        status = MODULE.active_status("codex", self.temp, lambda *_: False)
        self.assertEqual(status["valid"], "no")
        self.assertIn("不存在", status["reason"])

        MODULE.atomic_write(
            path,
            MODULE.state_bytes(
                {
                    "version": 1,
                    "profiles": [{"id": "profile-a", "displayName": "Personal"}],
                    "activeProfileId": "profile-a",
                }
            ),
        )
        status = MODULE.active_status("codex", self.temp, lambda *_: False)
        self.assertEqual(status["key"], "missing")
        self.assertIn("Keychain", status["reason"])

    def test_legacy_mapping_is_non_destructive(self) -> None:
        checks: list[tuple[str, str]] = []

        def exists(service: str, account: str) -> bool:
            checks.append((service, account))
            return account == "deepseek"

        state, migrated = MODULE.load_effective_state("codex", self.temp, exists)
        self.assertTrue(migrated)
        self.assertEqual(state["profiles"], [{"id": "deepseek", "displayName": "Default"}])
        self.assertEqual(state["activeProfileId"], "deepseek")
        self.assertFalse(MODULE.profile_path(self.temp).exists())
        self.assertEqual(checks, [("codex-deepseek-api-key", "deepseek")])


class CodexProviderCredentialTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="codex-provider-profile-tests-"))
        self.codex_home = self.temp / "codex"
        self.codex_home.mkdir()
        self.bin_dir = self.temp / "bin"
        self.bin_dir.mkdir()
        self.config = self.codex_home / "config.toml"
        self.catalog = self.codex_home / "deepseek.models.json"
        self.plist = self.temp / "proxy.plist"
        self.plist.write_text("fixture", encoding="utf-8")
        self.catalog.write_text('{"models":[]}', encoding="utf-8")
        self.config.write_text(
            '''model = "gpt-5"
model_provider = "openai"
model_reasoning_effort = "high"

[model_providers.deepseek]
name = "fixture"
''',
            encoding="utf-8",
        )
        MODULE.atomic_write(
            MODULE.profile_path(self.codex_home),
            MODULE.state_bytes(
                {
                    "version": 1,
                    "profiles": [
                        {"id": "profile-a", "displayName": "Personal"},
                        {"id": "profile-b", "displayName": "Work"},
                    ],
                    "activeProfileId": "profile-a",
                }
            ),
        )
        self.fake_codex = self._script(
            "codex",
            "#!/bin/zsh\n[[ \"$*\" == \"debug models\" ]] && print '{\"slug\":\"deepseek-v4-pro\"}'\n",
        )
        self.fake_security = self._script(
            "security",
            '''#!/bin/zsh
account=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-a" ]]; then account="$2"; shift 2; else shift; fi
done
if [[ -z "$account" && "${FAKE_LEGACY_SERVICE_READY:-no}" == yes ]]; then exit 0; fi
[[ ",$FAKE_KEYCHAIN_ACCOUNTS," == *",$account,"* ]]
''',
        )
        self.fake_curl = self._script(
            "curl",
            "#!/bin/zsh\nprint '{\"status\":\"ok\",\"models\":[\"deepseek-v4-pro\"],\"elapsed_ms\":1}'\n",
        )
        self.env = os.environ.copy()
        self.env.update(
            {
                "CODEX_SWITCHER_CODEX_HOME": str(self.codex_home),
                "CODEX_SWITCHER_CODEX_BIN": str(self.fake_codex),
                "CODEX_SWITCHER_PROXY_PLIST": str(self.plist),
                "CODEX_SWITCHER_CREDENTIAL_PROFILES_TOOL": str(MODULE_PATH),
                "CODEX_SWITCHER_SECURITY_BIN": str(self.fake_security),
                "CODEX_SWITCHER_CURL_BIN": str(self.fake_curl),
                "FAKE_KEYCHAIN_ACCOUNTS": "profile-a,profile-b",
            }
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

    def _script(self, name: str, contents: str) -> Path:
        path = self.bin_dir / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o700)
        return path

    def run_provider(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(ROOT / "Support/codex-provider"), *arguments],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(result.stdout)
        return result

    def test_codex_profile_a_to_b_and_idempotency(self) -> None:
        first = self.run_provider("deepseek", "--credential", "profile-a")
        self.assertIn("credential_profile_id=profile-a", first.stdout)
        state = json.loads(MODULE.profile_path(self.codex_home).read_text(encoding="utf-8"))
        self.assertEqual(state["activeProfileId"], "profile-a")

        second = self.run_provider("deepseek", "--credential", "Work")
        self.assertIn("credential_profile_id=profile-b", second.stdout)
        state = json.loads(MODULE.profile_path(self.codex_home).read_text(encoding="utf-8"))
        self.assertEqual(state["activeProfileId"], "profile-b")
        before = sorted((self.codex_home / "provider-switch-backups").iterdir())

        repeated = self.run_provider("deepseek", "--credential", "profile-b")
        self.assertIn("already active", repeated.stdout)
        self.assertEqual(before, sorted((self.codex_home / "provider-switch-backups").iterdir()))

    def test_invalid_or_missing_key_profile_does_not_change_active_state(self) -> None:
        before_config = self.config.read_bytes()
        before_profiles = MODULE.profile_path(self.codex_home).read_bytes()
        activation = self.codex_home / "chatgpt.activation.toml"
        self.assertFalse(activation.exists())
        invalid = self.run_provider("deepseek", "--credential", "missing", check=False)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("Credential Profile", invalid.stdout)
        self.assertEqual(self.config.read_bytes(), before_config)
        self.assertEqual(MODULE.profile_path(self.codex_home).read_bytes(), before_profiles)
        self.assertFalse(activation.exists())

        self.env["FAKE_KEYCHAIN_ACCOUNTS"] = "profile-a"
        missing_key = self.run_provider("deepseek", "--credential", "profile-b", check=False)
        self.assertNotEqual(missing_key.returncode, 0)
        self.assertIn("Keychain", missing_key.stdout)
        self.assertEqual(self.config.read_bytes(), before_config)
        self.assertEqual(MODULE.profile_path(self.codex_home).read_bytes(), before_profiles)
        self.assertFalse(activation.exists())

    def test_no_fake_secret_reaches_config_backup_or_output(self) -> None:
        sentinel = "fixture-secret-that-must-not-persist"
        self.env["FAKE_KEYCHAIN_ACCOUNTS"] = "profile-a,profile-b," + sentinel
        result = self.run_provider("deepseek", "--credential", "profile-a")
        persisted = b"\n".join(
            path.read_bytes()
            for path in self.codex_home.rglob("*")
            if path.is_file()
        )
        self.assertNotIn(sentinel.encode(), persisted)
        self.assertNotIn(sentinel, result.stdout)

    def test_codex_service_only_legacy_key_maps_to_default(self) -> None:
        MODULE.profile_path(self.codex_home).unlink()
        self.env["FAKE_KEYCHAIN_ACCOUNTS"] = ""
        self.env["FAKE_LEGACY_SERVICE_READY"] = "yes"
        result = self.run_provider("deepseek")
        self.assertIn("credential_profile_id=deepseek", result.stdout)
        state = json.loads(MODULE.profile_path(self.codex_home).read_text(encoding="utf-8"))
        self.assertEqual(
            state,
            {
                "version": 1,
                "profiles": [{"id": "deepseek", "displayName": "Default"}],
                "activeProfileId": "deepseek",
            },
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
