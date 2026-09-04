#!/usr/bin/env python3
"""Zero-cost tests for the real Claude Desktop 3P config-library switcher."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROVIDER = ROOT / "Support/claude-provider"
MODULE = SourceFileLoader("claude_provider_test", str(PROVIDER)).load_module()
CONFIG_ID = "00000000-0000-4000-8000-000000000001"


class ClaudeProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="claude-provider-tests-"))
        self.claude_home = self.temp / "home/.claude"
        self.support = self.temp / "home/Library/Application Support/Claude-3p"
        self.helper = self.claude_home / "deepseek-keychain-helper"
        self.claude_home.mkdir(parents=True)
        self.support.mkdir(parents=True)
        self.helper.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
        self.helper.chmod(0o700)

        self._original_keychain = MODULE.keychain_ready
        self._original_desktop = MODULE.detect_claude_desktop
        self._original_engine = MODULE.detect_bundled_claude_code
        self._original_cli = MODULE.detect_claude_cli
        self.keychain_accounts = {"deepseek", "profile-a", "profile-b"}
        MODULE.keychain_ready = lambda _service=MODULE.KEYCHAIN_SERVICE, account=MODULE.KEYCHAIN_ACCOUNT: account in self.keychain_accounts
        MODULE.detect_claude_desktop = lambda: (
            True,
            "1.37937.1",
            "/Applications/Claude.app",
        )
        MODULE.detect_bundled_claude_code = lambda: (
            True,
            "2.1.246",
            "/fake/Claude-3p/claude",
        )
        MODULE.detect_claude_cli = lambda *a, **k: (False, "", "")

    def tearDown(self) -> None:
        MODULE.keychain_ready = self._original_keychain
        MODULE.detect_claude_desktop = self._original_desktop
        MODULE.detect_bundled_claude_code = self._original_engine
        MODULE.detect_claude_cli = self._original_cli
        shutil.rmtree(self.temp, ignore_errors=True)

    @property
    def settings_path(self) -> Path:
        return MODULE.settings_path(self.claude_home)

    @property
    def desktop_path(self) -> Path:
        return MODULE.desktop_config_path(self.support)

    @property
    def meta_path(self) -> Path:
        return MODULE.config_library_meta_path(self.support)

    def active_path(self, config_id: str = CONFIG_ID) -> Path:
        return MODULE.config_library_entry_path(self.support, config_id)

    @property
    def profiles_path(self) -> Path:
        return MODULE.profile_path(self.claude_home)

    @staticmethod
    def write_json(path: Path, data: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    @staticmethod
    def read_json(path: Path) -> dict[str, Any]:
        return json.loads(path.read_text(encoding="utf-8"))

    def write_official_fixture(self) -> dict[str, dict[str, Any]]:
        settings = {
            "permissions": {"allow": ["Read", "Bash(ls:*)"]},
            "hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": []}]},
            "mcpServers": {"demo": {"command": "demo"}},
            "plugins": {"keep": True},
            "projects": {"/tmp/example": {"allowedTools": ["Read"]}},
            "env": {
                "CUSTOM_VAR": "keep-me",
                "ANTHROPIC_MODEL": "claude-official-choice",
                "HTTP_PROXY": "http://official.proxy:8080",
            },
            "apiKeyHelper": "/usr/local/bin/official-helper",
        }
        desktop = {"deploymentMode": "1p", "preferences": {"keep": True}}
        meta = {
            "appliedId": CONFIG_ID,
            "entries": [{"id": CONFIG_ID, "name": "Existing config"}],
            "metaUnrelated": "keep",
        }
        active = {
            "inferenceProvider": "anthropic",
            "existingConfigField": {"keep": True},
        }
        self.write_json(self.settings_path, settings)
        self.write_json(self.desktop_path, desktop)
        self.write_json(self.meta_path, meta)
        self.write_json(self.active_path(), active)
        return {
            "settings": settings,
            "desktop": desktop,
            "meta": meta,
            "active": active,
        }

    def write_deepseek_fixture(self, mode: str) -> None:
        model = MODULE.model_for_mode(mode)
        assert model
        self.write_json(
            self.settings_path,
            {
                "env": MODULE.deepseek_env(model),
                "apiKeyHelper": str(self.helper),
            },
        )
        self.write_json(self.desktop_path, {"deploymentMode": "3p"})
        self.write_json(
            self.meta_path,
            {
                "appliedId": CONFIG_ID,
                "entries": [{"id": CONFIG_ID, "name": "Default"}],
            },
        )
        self.write_json(
            self.active_path(),
            MODULE.deepseek_desktop_config({}, mode, str(self.helper)),
        )

    def write_profiles(self, active: str | None = "profile-a") -> None:
        self.write_json(
            self.profiles_path,
            {
                "version": 1,
                "profiles": [
                    {"id": "profile-a", "displayName": "Personal"},
                    {"id": "profile-b", "displayName": "Work"},
                ],
                "activeProfileId": active,
            },
        )

    def switch(
        self,
        mode: str,
        proxy: dict[str, str] | None = None,
        credential_profile: str | None = None,
    ) -> dict[str, str]:
        return MODULE.switch_mode(
            mode,
            self.claude_home,
            claude_3p_support=self.support,
            helper_command=str(self.helper),
            proxy_env={} if proxy is None else proxy,
            credential_profile=credential_profile,
        )

    def status_values(self) -> dict[str, str]:
        text = MODULE.status(
            self.claude_home,
            claude_3p_support=self.support,
            helper_command=str(self.helper),
        )
        return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)

    # --- real source-of-truth classification --------------------------

    def test_status_default_when_files_are_missing(self) -> None:
        values = self.status_values()
        self.assertEqual(values["current_state"], "default")
        self.assertEqual(values["state_consistent"], "yes")
        self.assertEqual(values["claude_3p_support_path"], str(self.support))

    def test_working_manual_config_shape_is_recognized(self) -> None:
        self.write_deepseek_fixture("deepseek-pro")
        active = self.read_json(self.active_path())
        # The verified manual file omitted these because Desktop defaults to
        # bearer and skips discovery when a sufficient model list exists.
        active.pop("inferenceGatewayAuthScheme")
        active.pop("modelDiscoveryEnabled")
        self.write_json(self.active_path(), active)
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-pro")
        self.assertEqual(values["deployment_mode"], "3p")
        self.assertEqual(values["desktop_provider"], "gateway")
        self.assertEqual(values["desktop_auth_scheme"], "bearer")

    def test_settings_json_alone_never_claims_desktop_success(self) -> None:
        self.write_json(
            self.settings_path,
            {
                "env": MODULE.deepseek_env(MODULE.PRO_MODEL),
                "apiKeyHelper": str(self.helper),
            },
        )
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertIn("Desktop=default", values["inconsistency_reason"])

    def test_desktop_alone_never_claims_direct_cli_success(self) -> None:
        self.write_deepseek_fixture("deepseek-pro")
        self.write_json(self.settings_path, {"permissions": {"allow": ["Read"]}})
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertIn("直接 CLI=default", values["inconsistency_reason"])

    def test_wrong_auth_or_discovery_is_inconsistent(self) -> None:
        self.write_deepseek_fixture("deepseek-pro")
        active = self.read_json(self.active_path())
        active["inferenceGatewayAuthScheme"] = "x-api-key"
        active["modelDiscoveryEnabled"] = True
        self.write_json(self.active_path(), active)
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertIn("bearer", values["inconsistency_reason"])

    def test_first_model_is_the_real_default_tier(self) -> None:
        pro = MODULE.deepseek_desktop_config({}, "deepseek-pro", str(self.helper))
        flash = MODULE.deepseek_desktop_config({}, "deepseek-flash", str(self.helper))
        self.assertEqual(pro["inferenceModels"][0]["anthropicFamilyTier"], "opus")
        self.assertEqual(pro["inferenceModels"][0]["name"], MODULE.PRO_MODEL)
        self.assertEqual(flash["inferenceModels"][0]["anthropicFamilyTier"], "sonnet")
        self.assertEqual(flash["inferenceModels"][0]["name"], MODULE.FLASH_MODEL)

    # --- acceptance sequence and restoration --------------------------

    def test_official_to_pro_to_flash_to_official(self) -> None:
        original = self.write_official_fixture()
        original_settings_bytes = self.settings_path.read_bytes()
        original_desktop_bytes = self.desktop_path.read_bytes()

        self.switch(
            "deepseek-pro",
            {
                "HTTP_PROXY": "http://127.0.0.1:7897",
                "HTTPS_PROXY": "http://127.0.0.1:7897",
            },
        )
        self.assertEqual(self.status_values()["current_state"], "deepseek-pro")
        after_pro = self.read_json(self.settings_path)
        active_pro = self.read_json(self.active_path())
        self.assertEqual(after_pro["env"]["ANTHROPIC_MODEL"], MODULE.PRO_MODEL)
        self.assertEqual(after_pro["apiKeyHelper"], str(self.helper))
        self.assertEqual(after_pro["permissions"], original["settings"]["permissions"])
        self.assertEqual(active_pro["inferenceGatewayAuthScheme"], "bearer")
        self.assertFalse(active_pro["modelDiscoveryEnabled"])
        self.assertEqual(active_pro["inferenceModels"][0]["name"], MODULE.PRO_MODEL)
        snapshots = list(MODULE.snapshot_root(self.claude_home).glob("*/manifest.json"))
        self.assertEqual(len(snapshots), 1)
        snapshot = MODULE.load_official_snapshot(self.claude_home)
        assert snapshot
        self.assertEqual(snapshot["files"]["settings"], original_settings_bytes)
        self.assertEqual(snapshot["files"]["desktop"], original_desktop_bytes)

        # Simulate unrelated edits while DeepSeek is active.  The restore must
        # not erase them.
        after_pro["hooks"]["newWhileDeepSeek"] = True
        self.write_json(self.settings_path, after_pro)
        active_pro["existingConfigField"]["addedWhileDeepSeek"] = True
        self.write_json(self.active_path(), active_pro)

        self.switch("deepseek-flash")
        self.assertEqual(self.status_values()["current_state"], "deepseek-flash")
        self.assertEqual(
            self.read_json(self.active_path())["inferenceModels"][0]["name"],
            MODULE.FLASH_MODEL,
        )
        self.assertEqual(
            len(list(MODULE.snapshot_root(self.claude_home).glob("*/manifest.json"))),
            1,
        )

        self.switch("default")
        values = self.status_values()
        self.assertEqual(values["current_state"], "default")
        restored = self.read_json(self.settings_path)
        self.assertEqual(restored["env"], original["settings"]["env"])
        self.assertEqual(restored["apiKeyHelper"], original["settings"]["apiKeyHelper"])
        self.assertTrue(restored["hooks"]["newWhileDeepSeek"])
        self.assertEqual(self.read_json(self.desktop_path)["deploymentMode"], "1p")
        restored_active = self.read_json(self.active_path())
        self.assertEqual(restored_active["inferenceProvider"], "anthropic")
        self.assertTrue(restored_active["existingConfigField"]["addedWhileDeepSeek"])
        self.assertNotIn("inferenceGatewayBaseUrl", restored_active)
        self.assertEqual(self.read_json(self.meta_path)["metaUnrelated"], "keep")

    def test_missing_official_files_are_recreated_then_removed(self) -> None:
        self.switch("deepseek-pro")
        self.assertTrue(self.settings_path.exists())
        self.assertTrue(self.desktop_path.exists())
        meta = self.read_json(self.meta_path)
        created_id = meta["appliedId"]
        created_active = self.active_path(created_id)
        self.assertTrue(created_active.exists())
        self.switch("default")
        self.assertFalse(self.settings_path.exists())
        self.assertFalse(self.desktop_path.exists())
        self.assertFalse(self.meta_path.exists())
        self.assertFalse(created_active.exists())
        self.assertEqual(self.status_values()["current_state"], "default")

    def test_fallback_official_preserves_manual_3p_library(self) -> None:
        self.write_deepseek_fixture("deepseek-flash")
        settings = self.read_json(self.settings_path)
        settings["permissions"] = {"allow": ["Read"]}
        self.write_json(self.settings_path, settings)
        active_before = self.active_path().read_bytes()
        self.switch("default")
        restored = self.read_json(self.settings_path)
        self.assertEqual(restored["permissions"], {"allow": ["Read"]})
        self.assertNotIn("ANTHROPIC_BASE_URL", restored.get("env", {}))
        self.assertNotIn("apiKeyHelper", restored)
        self.assertEqual(self.desktop_path and self.read_json(self.desktop_path)["deploymentMode"], "1p")
        self.assertEqual(self.active_path().read_bytes(), active_before)

    def test_restore_preserves_original_custom_proxy(self) -> None:
        original = self.write_official_fixture()
        self.switch(
            "deepseek-pro",
            {
                "HTTP_PROXY": "http://127.0.0.1:7897",
                "HTTPS_PROXY": "http://127.0.0.1:7897",
            },
        )
        env = self.read_json(self.settings_path)["env"]
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")
        self.switch("default")
        self.assertEqual(
            self.read_json(self.settings_path)["env"], original["settings"]["env"]
        )

    def test_repeated_switch_is_idempotent(self) -> None:
        self.write_official_fixture()
        self.switch("deepseek-pro")
        files_before = {
            path: path.read_bytes()
            for path in (self.settings_path, self.desktop_path, self.meta_path, self.active_path())
        }
        backups_before = len(list(MODULE.backup_dir(self.claude_home).glob("*.bak")))
        self.switch("deepseek-pro")
        self.assertEqual(
            files_before,
            {path: path.read_bytes() for path in files_before},
        )
        self.assertEqual(
            len(list(MODULE.backup_dir(self.claude_home).glob("*.bak"))),
            backups_before,
        )

    def test_profile_a_to_b_switch_is_transactional(self) -> None:
        self.write_official_fixture()
        self.write_profiles()
        self.switch("deepseek-pro")
        self.assertEqual(self.status_values()["credential_profile_id"], "profile-a")
        active_before = self.active_path().read_bytes()
        self.switch("deepseek-pro", credential_profile="profile-b")
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-pro")
        self.assertEqual(values["credential_profile_id"], "profile-b")
        self.assertEqual(values["credential_profile_name"], "Work")
        self.assertEqual(self.active_path().read_bytes(), active_before)

    def test_pro_flash_and_profiles_are_independent(self) -> None:
        self.write_official_fixture()
        self.write_profiles()
        self.switch("deepseek-pro", credential_profile="profile-b")
        self.assertEqual(self.status_values()["credential_profile_id"], "profile-b")
        self.switch("deepseek-flash", credential_profile="profile-a")
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-flash")
        self.assertEqual(values["credential_profile_id"], "profile-a")
        self.assertEqual(
            self.read_json(self.active_path())["inferenceModels"][0]["name"],
            MODULE.FLASH_MODEL,
        )

    def test_invalid_or_missing_profile_key_never_mutates_configs(self) -> None:
        self.write_official_fixture()
        self.write_profiles()
        tracked = (self.settings_path, self.desktop_path, self.meta_path, self.active_path(), self.profiles_path)
        before = {path: path.read_bytes() for path in tracked}
        with self.assertRaisesRegex(MODULE.ClaudeProviderError, "Credential Profile 不存在"):
            self.switch("deepseek-pro", credential_profile="missing-profile")
        self.assertEqual(before, {path: path.read_bytes() for path in tracked})

        self.keychain_accounts.remove("profile-b")
        with self.assertRaisesRegex(MODULE.ClaudeProviderError, "Keychain 条目缺失"):
            self.switch("deepseek-pro", credential_profile="profile-b")
        self.assertEqual(before, {path: path.read_bytes() for path in tracked})

    def test_status_explains_missing_active_profile_and_key(self) -> None:
        self.write_deepseek_fixture("deepseek-pro")
        self.write_profiles(active="missing-profile")
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertIn("不存在", values["inconsistency_reason"])

        self.write_profiles(active="profile-b")
        self.keychain_accounts.remove("profile-b")
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertIn("Keychain 条目缺失", values["inconsistency_reason"])

    def test_legacy_single_key_is_mapped_without_deletion(self) -> None:
        self.write_official_fixture()
        self.assertFalse(self.profiles_path.exists())
        self.switch("deepseek-pro")
        state = self.read_json(self.profiles_path)
        self.assertEqual(state["profiles"], [{"id": "deepseek", "displayName": "Default"}])
        self.assertEqual(state["activeProfileId"], "deepseek")
        self.assertIn("deepseek", self.keychain_accounts)

    def test_official_mode_preserves_profiles(self) -> None:
        self.write_official_fixture()
        self.write_profiles()
        self.switch("deepseek-flash", credential_profile="profile-b")
        profile_bytes = self.profiles_path.read_bytes()
        self.switch("default")
        self.assertEqual(self.profiles_path.read_bytes(), profile_bytes)
        self.assertEqual(self.status_values()["current_state"], "default")

    # --- safety / rollback --------------------------------------------

    def test_missing_keychain_fails_without_mutation(self) -> None:
        self.write_official_fixture()
        before = self.settings_path.read_bytes()
        MODULE.keychain_ready = lambda *a, **k: False
        with self.assertRaises(MODULE.ClaudeProviderError):
            self.switch("deepseek-pro")
        self.assertEqual(self.settings_path.read_bytes(), before)

    def test_missing_helper_fails_without_mutation(self) -> None:
        self.write_official_fixture()
        before = self.settings_path.read_bytes()
        self.helper.unlink()
        with self.assertRaises(MODULE.ClaudeProviderError):
            self.switch("deepseek-pro")
        self.assertEqual(self.settings_path.read_bytes(), before)

    def test_mid_transaction_failure_rolls_every_file_back(self) -> None:
        self.write_official_fixture()
        tracked = (self.settings_path, self.desktop_path, self.meta_path, self.active_path())
        before = {path: path.read_bytes() for path in tracked}
        original_atomic = MODULE.atomic_write_bytes
        failed = False

        def fail_once(path: Path, data: bytes) -> None:
            nonlocal failed
            if path == self.meta_path and not failed:
                failed = True
                raise OSError("injected write failure")
            original_atomic(path, data)

        MODULE.atomic_write_bytes = fail_once
        try:
            with self.assertRaises(OSError):
                self.switch("deepseek-pro")
        finally:
            MODULE.atomic_write_bytes = original_atomic
        self.assertEqual(before, {path: path.read_bytes() for path in tracked})

    def test_invalid_json_is_not_overwritten(self) -> None:
        self.settings_path.write_text("{ invalid", encoding="utf-8")
        with self.assertRaises(MODULE.ClaudeProviderError):
            self.switch("deepseek-pro")
        self.assertEqual(self.settings_path.read_text(encoding="utf-8"), "{ invalid")

    def test_no_secret_is_persisted_or_logged_by_config(self) -> None:
        self.write_official_fixture()
        self.switch("deepseek-pro")
        paths = [
            self.settings_path,
            self.desktop_path,
            self.meta_path,
            self.active_path(),
            MODULE.profile_path(self.claude_home),
            MODULE.snapshot_pointer_path(self.claude_home),
        ] + list(MODULE.snapshot_root(self.claude_home).glob("*/*"))
        combined = b"\n".join(path.read_bytes() for path in paths if path.is_file())
        self.assertNotIn(b"ANTHROPIC_AUTH_TOKEN", combined)
        self.assertNotIn(b"ANTHROPIC_API_KEY", combined)
        self.assertNotIn(b"sk-", combined)
        self.assertIn(str(self.helper).encode(), combined)

    def test_config_permissions_are_private(self) -> None:
        self.switch("deepseek-pro")
        for path in (self.settings_path, self.desktop_path, self.meta_path):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_codex_keychain_service_is_isolated(self) -> None:
        self.assertEqual(MODULE.KEYCHAIN_SERVICE, "claude-code-deepseek-api-key")
        self.assertNotEqual(MODULE.KEYCHAIN_SERVICE, "codex-deepseek-api-key")

    # --- proxy and path helpers ---------------------------------------

    def test_parse_scutil_proxy_output(self) -> None:
        output = """<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7897
  HTTPSProxy : 127.0.0.1
}
"""
        self.assertEqual(
            MODULE.parse_scutil_proxy_output(output),
            {
                "HTTP_PROXY": "http://127.0.0.1:7897",
                "HTTPS_PROXY": "http://127.0.0.1:7897",
            },
        )

    def test_proxy_fallback_and_ipv6(self) -> None:
        output = """<dictionary> {
  HTTPEnable : 0
  HTTPSEnable : 1
  HTTPSPort : 3128
  HTTPSProxy : fe80::1%en0
}
"""
        self.assertEqual(
            MODULE.parse_scutil_proxy_output(output),
            {
                "HTTP_PROXY": "http://[fe80::1%en0]:3128",
                "HTTPS_PROXY": "http://[fe80::1%en0]:3128",
            },
        )

    def test_path_overrides_and_helper_default(self) -> None:
        home = str(self.temp / "example")
        self.assertTrue(
            str(MODULE.resolve_claude_3p_support(home=home)).endswith(
                "Library/Application Support/Claude-3p"
            )
        )
        self.assertTrue(
            MODULE.credential_helper_command(home=home).endswith(
                ".claude/deepseek-keychain-helper"
            )
        )
        override = MODULE.resolve_claude_3p_support(
            {"CODEX_SWITCHER_CLAUDE_3P_SUPPORT": str(self.support)}
        )
        self.assertEqual(override, self.support.resolve())

    def test_status_reports_installation_layers_separately(self) -> None:
        MODULE.detect_claude_cli = lambda *a, **k: (
            True,
            "2.1.246",
            "/usr/local/bin/claude",
        )
        values = self.status_values()
        self.assertEqual(values["desktop_installed"], "yes")
        self.assertEqual(values["claude_code_installed"], "yes")
        self.assertEqual(values["cli_installed"], "yes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
