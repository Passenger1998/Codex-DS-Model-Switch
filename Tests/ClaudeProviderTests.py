#!/usr/bin/env python3
"""Unit tests for the Claude Desktop provider manager (Support/claude-provider).

These tests exercise the manager in-process against temporary ``~/.claude``
and temporary Claude Application-Support directories.  The real macOS
Keychain, the real Claude Desktop and the real Claude Code binary are never
used: detection and keychain functions are stubbed, and no model is called.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROVIDER = ROOT / "Support" / "claude-provider"
MODULE = SourceFileLoader("claude_provider_test", str(PROVIDER)).load_module()

FAKE_HELPER = "/fake/claude-gateway-cred-helper"


class ClaudeProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="claude-provider-tests-"))
        self.claude_home = self.temp / "home"
        self.app_support = self.temp / "app-support"
        self.claude_home.mkdir(parents=True)
        self.app_support.mkdir(parents=True)
        # Deterministic stubs.
        self._orig_keychain_ready = MODULE.keychain_ready
        self._orig_desktop = MODULE.detect_claude_desktop
        self._orig_engine = MODULE.detect_bundled_claude_code
        self._orig_cli = MODULE.detect_claude_cli
        MODULE.keychain_ready = lambda *a, **k: True
        MODULE.detect_claude_desktop = lambda: (True, "1.34493.1", "/Applications/Claude.app")
        MODULE.detect_bundled_claude_code = lambda: (True, "2.1.237", "/fake/engine/claude")
        MODULE.detect_claude_cli = lambda *a, **k: (False, "", "")

    def tearDown(self) -> None:
        MODULE.keychain_ready = self._orig_keychain_ready
        MODULE.detect_claude_desktop = self._orig_desktop
        MODULE.detect_bundled_claude_code = self._orig_engine
        MODULE.detect_claude_cli = self._orig_cli
        shutil.rmtree(self.temp, ignore_errors=True)

    def settings(self) -> Path:
        return self.claude_home / "settings.json"

    def dev_settings(self) -> Path:
        return MODULE.developer_settings_path(self.app_support)

    def write_settings(self, data: dict[str, Any]) -> None:
        self.settings().parent.mkdir(parents=True, exist_ok=True)
        self.settings().write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def write_dev_settings(self, data: dict[str, Any]) -> None:
        self.dev_settings().parent.mkdir(parents=True, exist_ok=True)
        self.dev_settings().write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def read_settings(self) -> dict[str, Any]:
        return json.loads(self.settings().read_text(encoding="utf-8"))

    def read_dev_settings(self) -> dict[str, Any]:
        return json.loads(self.dev_settings().read_text(encoding="utf-8"))

    def switch(self, mode: str) -> dict[str, str]:
        # Deterministic default: no system proxy for the generic tests.
        return self.switch_with_proxy(mode, {})

    def switch_with_proxy(
        self, mode: str, proxy_env: dict[str, str] | None
    ) -> dict[str, str]:
        return MODULE.switch_mode(
            mode,
            self.claude_home,
            claude_app_support=self.app_support,
            helper_command=FAKE_HELPER,
            proxy_env=proxy_env,
        )

    def status_values(self) -> dict[str, str]:
        text = MODULE.status(self.claude_home, claude_app_support=self.app_support)
        result: dict[str, str] = {}
        for line in text.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                result[key] = value
        return result

    # --- detection -----------------------------------------------------

    def test_status_default_when_missing(self) -> None:
        values = self.status_values()
        self.assertEqual(values["current_state"], "default")
        self.assertEqual(values["state_consistent"], "yes")
        self.assertEqual(values["desktop_installed"], "yes")
        self.assertEqual(values["desktop_version"], "1.34493.1")
        self.assertEqual(values["claude_code_installed"], "yes")
        self.assertEqual(values["claude_code_version"], "2.1.237")
        self.assertEqual(values["cli_installed"], "no")
        self.assertEqual(values["desktop_provider"], "anthropic")

    def test_status_cli_installed_is_separate_from_desktop(self) -> None:
        MODULE.detect_claude_cli = lambda *a, **k: (True, "1.2.3", "/usr/local/bin/claude")
        values = self.status_values()
        self.assertEqual(values["cli_installed"], "yes")
        self.assertEqual(values["desktop_installed"], "yes")

    # --- status classification (settings + developer layers) -----------

    def test_status_deepseek_pro(self) -> None:
        env = MODULE.deepseek_env("claude-opus-5")
        self.write_settings({"env": env, "apiKeyHelper": MODULE.API_KEY_HELPER_COMMAND})
        self.write_dev_settings(
            MODULE.deepseek_developer_settings("deepseek-pro", FAKE_HELPER)
        )
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-pro")
        self.assertEqual(values["state_label"], "DeepSeek V4 Pro")
        self.assertEqual(values["state_consistent"], "yes")
        self.assertEqual(values["auth"], "keychain-helper")
        self.assertEqual(values["api_key_helper"], "present")
        self.assertEqual(values["desktop_provider"], "gateway")
        self.assertEqual(values["desktop_default_model"], "claude-opus-5")

    def test_status_deepseek_flash(self) -> None:
        env = MODULE.deepseek_env("claude-sonnet-5")
        self.write_settings({"env": env, "apiKeyHelper": MODULE.API_KEY_HELPER_COMMAND})
        self.write_dev_settings(
            MODULE.deepseek_developer_settings("deepseek-flash", FAKE_HELPER)
        )
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-flash")
        self.assertEqual(values["state_consistent"], "yes")
        self.assertEqual(values["desktop_default_model"], "claude-sonnet-5")

    def test_status_haiku_default_counts_as_flash(self) -> None:
        env = MODULE.deepseek_env("claude-haiku-4-5-20251001")
        self.write_settings({"env": env, "apiKeyHelper": MODULE.API_KEY_HELPER_COMMAND})
        dev = MODULE.deepseek_developer_settings("deepseek-flash", FAKE_HELPER)
        dev["models"]["list"] = [dev["models"]["list"][2]] + dev["models"]["list"][:2]
        self.write_dev_settings(dev)
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-flash")
        self.assertEqual(values["desktop_default_model"], MODULE.HAIKU_MODEL)

    def test_status_inconsistent_unknown_model(self) -> None:
        self.write_settings(
            {
                "env": {
                    "ANTHROPIC_BASE_URL": MODULE.DEEPSEEK_ANTHROPIC_BASE_URL,
                    "ANTHROPIC_MODEL": "deepseek-v4-pro",
                }
            }
        )
        self.write_dev_settings(
            MODULE.deepseek_developer_settings("deepseek-pro", FAKE_HELPER)
        )
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertEqual(values["state_consistent"], "no")
        self.assertTrue(values["inconsistency_reason"])

    def test_status_works_without_deepseek_developer_config(self) -> None:
        # settings.json is the single source of truth for Claude Code: a
        # DeepSeek engine config must not be judged inconsistent merely
        # because the optional developer_settings.json lacks DeepSeek
        # inference/models blocks.
        env = MODULE.deepseek_env("claude-opus-5")
        self.write_settings({"env": env, "apiKeyHelper": MODULE.API_KEY_HELPER_COMMAND})
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-pro")
        self.assertEqual(values["state_consistent"], "yes")

    def test_status_developer_leftover_does_not_override_official(self) -> None:
        # A leftover DeepSeek developer config is optional Desktop-layer
        # information; it must not flip an official settings.json state.
        self.write_dev_settings(
            MODULE.deepseek_developer_settings("deepseek-pro", FAKE_HELPER)
        )
        values = self.status_values()
        self.assertEqual(values["current_state"], "default")
        self.assertEqual(values["state_consistent"], "yes")

    def test_status_dev_allow_devtools_only(self) -> None:
        # Real-world A/B result: developer_settings.json containing only
        # {"allowDevTools": true} still works via settings.json.
        env = MODULE.deepseek_env("claude-opus-5")
        self.write_settings({"env": env, "apiKeyHelper": MODULE.API_KEY_HELPER_COMMAND})
        self.write_dev_settings({"allowDevTools": True})
        values = self.status_values()
        self.assertEqual(values["current_state"], "deepseek-pro")
        self.assertEqual(values["state_consistent"], "yes")
        self.assertEqual(values["desktop_provider"], "anthropic")

    def test_status_official_with_user_model_preference(self) -> None:
        # A user's own model preference without a DeepSeek base URL is still
        # the official Claude configuration.
        self.write_settings({"env": {"ANTHROPIC_MODEL": "claude-opus-5"}})
        values = self.status_values()
        self.assertEqual(values["current_state"], "default")
        self.assertEqual(values["state_consistent"], "yes")

    def test_status_invalid_json(self) -> None:
        self.settings().write_text("{ not valid json", encoding="utf-8")
        values = self.status_values()
        self.assertEqual(values["current_state"], "inconsistent")
        self.assertIn("JSON", values["inconsistency_reason"])

    # --- switching ------------------------------------------------------

    def test_switch_pro_then_default_restores_original(self) -> None:
        original = {
            "permissions": {"allow": ["Bash(ls:*)"]},
            "hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": []}]},
            "mcpServers": {"demo": {"command": "npx", "args": ["-y", "demo"]}},
            "env": {"CUSTOM_VAR": "keep-me", "ANTHROPIC_MODEL": "claude-opus-4-1"},
            "apiKeyHelper": "/usr/bin/custom-helper",
        }
        original_dev = {
            "extensions": {"custom": {"enabled": True}},
            "plugins": {"my-plugin": True},
        }
        self.write_settings(original)
        self.write_dev_settings(original_dev)

        self.switch("deepseek-pro")
        after_pro = self.read_settings()
        self.assertEqual(
            after_pro["env"]["ANTHROPIC_BASE_URL"],
            MODULE.DEEPSEEK_ANTHROPIC_BASE_URL,
        )
        self.assertEqual(after_pro["env"]["ANTHROPIC_MODEL"], "claude-opus-5")
        self.assertEqual(after_pro["env"]["CUSTOM_VAR"], "keep-me")
        self.assertEqual(after_pro["permissions"], original["permissions"])
        self.assertEqual(after_pro["hooks"], original["hooks"])
        self.assertEqual(after_pro["mcpServers"], original["mcpServers"])
        self.assertNotIn("sk-", after_pro["apiKeyHelper"])

        after_pro_dev = self.read_dev_settings()
        self.assertEqual(after_pro_dev["inference"]["provider"], "gateway")
        self.assertEqual(
            after_pro_dev["inference"]["baseUrl"],
            MODULE.DEEPSEEK_ANTHROPIC_BASE_URL,
        )
        self.assertEqual(
            after_pro_dev["inference"]["credential"]["kind"], "helper-script"
        )
        self.assertEqual(
            after_pro_dev["inference"]["credential"]["command"], FAKE_HELPER
        )
        # Original developer keys are preserved.
        self.assertEqual(after_pro_dev["extensions"], original_dev["extensions"])
        self.assertEqual(after_pro_dev["plugins"], original_dev["plugins"])
        # First model entry is the Pro default.
        self.assertEqual(
            after_pro_dev["models"]["list"][0]["name"], "claude-opus-5"
        )
        self.assertEqual(
            after_pro_dev["models"]["list"][0]["anthropicFamilyTier"], "opus"
        )

        self.switch("default")
        after_default = self.read_settings()
        self.assertEqual(after_default["permissions"], original["permissions"])
        self.assertEqual(after_default["hooks"], original["hooks"])
        self.assertEqual(after_default["mcpServers"], original["mcpServers"])
        self.assertEqual(after_default["env"]["CUSTOM_VAR"], "keep-me")
        self.assertEqual(after_default["env"]["ANTHROPIC_MODEL"], "claude-opus-4-1")
        self.assertNotIn("ANTHROPIC_BASE_URL", after_default["env"])
        self.assertEqual(after_default["apiKeyHelper"], "/usr/bin/custom-helper")
        # Developer settings restore to the exact original object.
        self.assertEqual(self.read_dev_settings(), original_dev)

    def test_switch_creates_developer_settings_when_absent(self) -> None:
        self.write_settings({"env": {}})
        self.switch("deepseek-pro")
        self.assertTrue(self.dev_settings().exists())
        self.switch("default")
        self.assertFalse(self.dev_settings().exists())

    def test_switch_flash(self) -> None:
        self.write_settings({"env": {}})
        self.switch("deepseek-flash")
        env = self.read_settings()["env"]
        self.assertEqual(env["ANTHROPIC_MODEL"], "claude-sonnet-5")
        self.assertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "claude-opus-5")
        self.assertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"], "claude-sonnet-5")
        self.assertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], MODULE.HAIKU_MODEL)
        self.assertEqual(self.read_settings()["apiKeyHelper"], MODULE.API_KEY_HELPER_COMMAND)
        dev = self.read_dev_settings()
        self.assertEqual(dev["models"]["list"][0]["name"], "claude-sonnet-5")
        self.assertEqual(dev["models"]["list"][0]["anthropicFamilyTier"], "sonnet")

    def test_switch_without_key_fails_and_preserves_config(self) -> None:
        MODULE.keychain_ready = lambda *a, **k: False
        original = {"permissions": {"deny": ["WebFetch"]}}
        self.write_settings(original)
        with self.assertRaises(MODULE.ClaudeProviderError):
            self.switch("deepseek-pro")
        self.assertEqual(self.read_settings(), original)
        self.assertFalse(self.dev_settings().exists())

    def test_idempotent_repeated_switch(self) -> None:
        self.write_settings({"env": {}})
        self.switch("deepseek-pro")
        first = self.read_settings()
        first_dev = self.read_dev_settings()
        backups_before = len(list(MODULE.backup_dir(self.claude_home).glob("*.bak")))
        self.switch("deepseek-pro")
        self.assertEqual(self.read_settings(), first)
        self.assertEqual(self.read_dev_settings(), first_dev)
        # The no-op switch must not create new backups.
        backups_after = len(list(MODULE.backup_dir(self.claude_home).glob("*.bak")))
        self.assertEqual(backups_after, backups_before)
        self.switch("default")
        second = self.read_settings()
        self.switch("default")
        self.assertEqual(self.read_settings(), second)

    def test_mid_failure_rollback(self) -> None:
        original = {"permissions": {"allow": ["Read"]}, "env": {"CUSTOM": "x"}}
        self.write_settings(original)
        original_write = MODULE.atomic_write_json

        def corrupting_write(path: Path, data: Any) -> None:
            MODULE.atomic_write_json(path, {"env": {"ANTHROPIC_MODEL": "WRONG"}})

        MODULE.atomic_write_json = corrupting_write
        try:
            with self.assertRaises(Exception):
                self.switch("deepseek-pro")
        finally:
            MODULE.atomic_write_json = original_write

        self.assertEqual(self.read_settings(), original)
        self.assertFalse(self.dev_settings().exists())

    def test_cross_tool_isolation(self) -> None:
        codex_home = self.temp / "codex-home"
        codex_home.mkdir()
        codex_config = codex_home / "config.toml"
        codex_config.write_text(
            'model = "deepseek-v4-pro"\nmodel_provider = "deepseek"\n', encoding="utf-8"
        )
        self.write_settings({"env": {}})
        self.switch("deepseek-flash")
        self.assertEqual(
            codex_config.read_text(encoding="utf-8"),
            'model = "deepseek-v4-pro"\nmodel_provider = "deepseek"\n',
        )
        self.assertEqual(MODULE.KEYCHAIN_SERVICE, "claude-code-deepseek-api-key")
        self.assertNotEqual(MODULE.KEYCHAIN_SERVICE, "codex-deepseek-api-key")

    def test_secret_never_written_to_settings(self) -> None:
        self.write_settings({"env": {}})
        self.switch("deepseek-pro")
        text = self.settings().read_text(encoding="utf-8")
        self.assertNotIn("sk-", text)
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", text)
        self.assertIn("security find-generic-password", text)
        dev_text = self.dev_settings().read_text(encoding="utf-8")
        self.assertNotIn("sk-", dev_text)
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", dev_text)
        self.assertIn(FAKE_HELPER, dev_text)

    def test_default_without_prior_state_keeps_settings(self) -> None:
        original = {"env": {"CUSTOM_VAR": "x"}, "permissions": {"allow": ["Read"]}}
        self.write_settings(original)
        self.switch("default")
        self.assertEqual(self.read_settings(), original)
        self.assertFalse(self.dev_settings().exists())

    def test_classify_model_mapping(self) -> None:
        self.assertEqual(MODULE.classify_env({})[0], "default")
        pro = MODULE.deepseek_env("claude-opus-5")
        self.assertEqual(MODULE.classify_env(pro)[0], "deepseek-pro")
        flash = MODULE.deepseek_env("claude-sonnet-5")
        self.assertEqual(MODULE.classify_env(flash)[0], "deepseek-flash")
        haiku = MODULE.deepseek_env("claude-haiku-4-5-20251001")
        self.assertEqual(MODULE.classify_env(haiku)[0], "deepseek-flash")

    def test_developer_settings_classification(self) -> None:
        dev = MODULE.deepseek_developer_settings("deepseek-pro", FAKE_HELPER)
        state, tier, default_model, reason = MODULE.classify_developer_settings(dev)
        self.assertEqual(state, "deepseek")
        self.assertEqual(tier, "opus")
        self.assertEqual(default_model, "claude-opus-5")
        self.assertEqual(reason, "")
        flash_dev = MODULE.deepseek_developer_settings("deepseek-flash", FAKE_HELPER)
        self.assertEqual(
            MODULE.classify_developer_settings(flash_dev)[1], "flash"
        )
        self.assertEqual(MODULE.classify_developer_settings({})[0], "official")
        self.assertEqual(
            MODULE.classify_developer_settings(
                {"inference": {"provider": "anthropic"}}
            )[0],
            "official",
        )

    def test_switch_pro_and_flash_reorder_default_model(self) -> None:
        self.write_settings({"env": {}})
        self.switch("deepseek-pro")
        self.assertEqual(
            self.read_dev_settings()["models"]["list"][0]["name"], "claude-opus-5"
        )
        self.switch("deepseek-flash")
        self.assertEqual(
            self.read_dev_settings()["models"]["list"][0]["name"], "claude-sonnet-5"
        )

    # --- system proxy handling ------------------------------------------

    def test_parse_scutil_proxy_output_present(self) -> None:
        output = """<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7897
  HTTPSProxy : 127.0.0.1
}
"""
        env = MODULE.parse_scutil_proxy_output(output)
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")

    def test_parse_scutil_proxy_output_absent(self) -> None:
        self.assertEqual(MODULE.parse_scutil_proxy_output(""), {})
        self.assertEqual(
            MODULE.parse_scutil_proxy_output("<dictionary> {\n}\n"), {}
        )

    def test_parse_scutil_proxy_output_http_disabled_falls_back(self) -> None:
        output = """<dictionary> {
  HTTPEnable : 0
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7897
  HTTPSProxy : 127.0.0.1
}
"""
        env = MODULE.parse_scutil_proxy_output(output)
        # Same cross-fallback as the Codex bridge: http reuses the https
        # endpoint when the http proxy is disabled.
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")

    def test_parse_scutil_proxy_output_https_falls_back_to_http(self) -> None:
        output = """<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7897
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 0
}
"""
        env = MODULE.parse_scutil_proxy_output(output)
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        # Same fallback as the Codex bridge: https reuses the http endpoint.
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")

    def test_parse_scutil_proxy_output_invalid_port_and_ipv6(self) -> None:
        invalid = """<dictionary> {
  HTTPEnable : 1
  HTTPPort : 0
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7897
  HTTPSProxy : fe80::1%en0
}
        """
        env = MODULE.parse_scutil_proxy_output(invalid)
        # The invalid http endpoint (port 0) falls back to the https one.
        self.assertEqual(env["HTTP_PROXY"], "http://[fe80::1%en0]:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://[fe80::1%en0]:7897")

    def test_switch_writes_system_proxy(self) -> None:
        self.write_settings({"env": {}})
        self.switch_with_proxy(
            "deepseek-pro",
            {
                "HTTP_PROXY": "http://127.0.0.1:7897",
                "HTTPS_PROXY": "http://127.0.0.1:7897",
            },
        )
        env = self.read_settings()["env"]
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")

    def test_switch_flash_writes_system_proxy(self) -> None:
        self.write_settings({"env": {}})
        self.switch_with_proxy(
            "deepseek-flash",
            {"HTTP_PROXY": "http://10.0.0.1:3128", "HTTPS_PROXY": "http://10.0.0.1:3128"},
        )
        env = self.read_settings()["env"]
        self.assertEqual(env["ANTHROPIC_MODEL"], "claude-sonnet-5")
        self.assertEqual(env["HTTP_PROXY"], "http://10.0.0.1:3128")

    def test_switch_no_system_proxy_writes_nothing(self) -> None:
        self.write_settings({"env": {}})
        self.switch_with_proxy("deepseek-pro", {})
        env = self.read_settings()["env"]
        self.assertNotIn("HTTP_PROXY", env)
        self.assertNotIn("HTTPS_PROXY", env)

    def test_switch_no_system_proxy_keeps_existing_custom_proxy(self) -> None:
        self.write_settings(
            {"env": {"HTTP_PROXY": "http://10.0.0.1:3128", "CUSTOM": "x"}}
        )
        self.switch_with_proxy("deepseek-pro", {})
        env = self.read_settings()["env"]
        self.assertEqual(env["HTTP_PROXY"], "http://10.0.0.1:3128")
        self.assertEqual(env["CUSTOM"], "x")

    def test_switch_overrides_custom_proxy_with_system_proxy(self) -> None:
        self.write_settings(
            {"env": {"HTTP_PROXY": "http://10.0.0.1:3128", "HTTPS_PROXY": "http://10.0.0.1:3128"}}
        )
        self.switch_with_proxy(
            "deepseek-pro",
            {"HTTP_PROXY": "http://127.0.0.1:7897", "HTTPS_PROXY": "http://127.0.0.1:7897"},
        )
        env = self.read_settings()["env"]
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")

    def test_restore_original_custom_proxy_on_default(self) -> None:
        original = {"env": {"HTTP_PROXY": "http://10.0.0.1:3128", "CUSTOM": "y"}}
        self.write_settings(original)
        self.switch_with_proxy(
            "deepseek-pro",
            {"HTTP_PROXY": "http://127.0.0.1:7897", "HTTPS_PROXY": "http://127.0.0.1:7897"},
        )
        self.switch("default")
        env = self.read_settings()["env"]
        self.assertEqual(env["HTTP_PROXY"], "http://10.0.0.1:3128")
        self.assertNotIn("HTTPS_PROXY", env)
        self.assertEqual(env["CUSTOM"], "y")

    def test_restore_removes_proxy_when_original_had_none(self) -> None:
        self.write_settings({"env": {"CUSTOM": "z"}})
        self.switch_with_proxy(
            "deepseek-pro",
            {"HTTP_PROXY": "http://127.0.0.1:7897", "HTTPS_PROXY": "http://127.0.0.1:7897"},
        )
        self.switch("default")
        env = self.read_settings()["env"]
        self.assertNotIn("HTTP_PROXY", env)
        self.assertNotIn("HTTPS_PROXY", env)
        self.assertEqual(env["CUSTOM"], "z")


if __name__ == "__main__":
    unittest.main(verbosity=2)
