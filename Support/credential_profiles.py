#!/usr/bin/env python3
"""Non-secret DeepSeek credential-profile metadata helpers.

API keys never pass through this module.  It stores only stable profile IDs,
display names, and the active profile ID.  Keychain presence checks never ask
``security`` to return a password.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable


VERSION = 1
LEGACY_PROFILE_ID = "deepseek"
DEFAULT_PROFILE_NAME = "Default"
PROFILE_FILE_NAME = "deepseek-credential-profiles.json"
SERVICES = {
    "codex": "codex-deepseek-api-key",
    "claude": "claude-code-deepseek-api-key",
}
PROFILE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class CredentialProfileError(Exception):
    pass


def profile_path(home: Path) -> Path:
    return home / PROFILE_FILE_NAME


def empty_state() -> dict[str, Any]:
    return {"version": VERSION, "profiles": [], "activeProfileId": None}


def _validated_display_name(value: Any) -> str:
    name = str(value or "").strip()
    if not name:
        raise CredentialProfileError("Credential Profile 名称不能为空")
    if len(name) > 80 or any(ord(character) < 32 for character in name):
        raise CredentialProfileError("Credential Profile 名称无效")
    return name


def validate_state(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("version") != VERSION:
        raise CredentialProfileError("Credential Profile 元数据版本无效")
    raw_profiles = value.get("profiles")
    if not isinstance(raw_profiles, list):
        raise CredentialProfileError("Credential Profile 元数据缺少 profiles")
    profiles: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    seen_names: set[str] = set()
    for raw in raw_profiles:
        if not isinstance(raw, dict):
            raise CredentialProfileError("Credential Profile 条目无效")
        profile_id = str(raw.get("id") or "")
        if not PROFILE_ID_PATTERN.fullmatch(profile_id):
            raise CredentialProfileError("Credential Profile ID 无效")
        display_name = _validated_display_name(raw.get("displayName"))
        folded_name = display_name.casefold()
        if profile_id in seen_ids or folded_name in seen_names:
            raise CredentialProfileError("Credential Profile ID 或名称重复")
        seen_ids.add(profile_id)
        seen_names.add(folded_name)
        profiles.append({"id": profile_id, "displayName": display_name})
    raw_active = value.get("activeProfileId")
    active = None if raw_active in (None, "") else str(raw_active)
    if active is not None and not PROFILE_ID_PATTERN.fullmatch(active):
        raise CredentialProfileError("当前 Credential Profile ID 无效")
    return {"version": VERSION, "profiles": profiles, "activeProfileId": active}


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return empty_state()
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CredentialProfileError(f"无法读取 Credential Profile 元数据：{exc}") from exc
    return validate_state(value)


def state_bytes(state: dict[str, Any]) -> bytes:
    validated = validate_state(state)
    return (json.dumps(validated, ensure_ascii=False, indent=2) + "\n").encode()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        if path.read_bytes() != data:
            raise CredentialProfileError("Credential Profile 写后字节验证失败")
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def keychain_ready(service: str, account: str) -> bool:
    security = os.environ.get("CODEX_SWITCHER_SECURITY_BIN", "/usr/bin/security")
    try:
        result = subprocess.run(
            [security, "find-generic-password", "-s", service, "-a", account],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def keychain_service_ready(service: str) -> bool:
    security = os.environ.get("CODEX_SWITCHER_SECURITY_BIN", "/usr/bin/security")
    # The old Codex lookup selected by service only.  This fallback is used
    # only until the Swift migration has copied that item to account=deepseek.
    try:
        legacy = subprocess.run(
            [security, "find-generic-password", "-s", service],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return legacy.returncode == 0


def migrated_state(
    tool: str,
    state: dict[str, Any],
    key_exists: Callable[[str, str], bool] = keychain_ready,
    legacy_exists: Callable[[str], bool] = keychain_service_ready,
) -> tuple[dict[str, Any], bool]:
    if tool not in SERVICES:
        raise CredentialProfileError(f"未知工具：{tool}")
    validated = validate_state(state)
    legacy_ready = key_exists(SERVICES[tool], LEGACY_PROFILE_ID) or (
        tool == "codex" and legacy_exists(SERVICES[tool])
    )
    if validated["profiles"] or not legacy_ready:
        return validated, False
    migrated = {
        "version": VERSION,
        "profiles": [{"id": LEGACY_PROFILE_ID, "displayName": DEFAULT_PROFILE_NAME}],
        "activeProfileId": LEGACY_PROFILE_ID,
    }
    return migrated, True


def load_effective_state(
    tool: str,
    home: Path,
    key_exists: Callable[[str, str], bool] = keychain_ready,
    legacy_exists: Callable[[str], bool] = keychain_service_ready,
) -> tuple[dict[str, Any], bool]:
    return migrated_state(tool, load_state(profile_path(home)), key_exists, legacy_exists)


def profile_key_ready(
    tool: str,
    state: dict[str, Any],
    profile: dict[str, str],
    key_exists: Callable[[str, str], bool] = keychain_ready,
    legacy_exists: Callable[[str], bool] = keychain_service_ready,
) -> bool:
    if key_exists(SERVICES[tool], profile["id"]):
        return True
    return (
        tool == "codex"
        and profile["id"] == LEGACY_PROFILE_ID
        and len(state["profiles"]) == 1
        and legacy_exists(SERVICES[tool])
    )


def resolve_profile(state: dict[str, Any], reference: str | None) -> dict[str, str]:
    validated = validate_state(state)
    profiles: list[dict[str, str]] = validated["profiles"]
    wanted = (reference or "").strip()
    if not wanted:
        wanted = str(validated.get("activeProfileId") or "")
    if not wanted and len(profiles) == 1:
        return profiles[0]
    if not wanted:
        raise CredentialProfileError("未选择 Credential Profile")
    for profile in profiles:
        if profile["id"] == wanted:
            return profile
    matches = [profile for profile in profiles if profile["displayName"].casefold() == wanted.casefold()]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise CredentialProfileError(f"Credential Profile 名称不唯一：{wanted}")
    raise CredentialProfileError(f"Credential Profile 不存在：{wanted}")


def state_with_active(state: dict[str, Any], profile_id: str) -> dict[str, Any]:
    validated = validate_state(state)
    if not any(profile["id"] == profile_id for profile in validated["profiles"]):
        raise CredentialProfileError(f"Credential Profile 不存在：{profile_id}")
    return {**validated, "activeProfileId": profile_id}


def active_status(
    tool: str,
    home: Path,
    key_exists: Callable[[str, str], bool] = keychain_ready,
    legacy_exists: Callable[[str], bool] = keychain_service_ready,
) -> dict[str, str]:
    try:
        state, migrated = load_effective_state(tool, home, key_exists, legacy_exists)
        active_id = str(state.get("activeProfileId") or "")
        if not active_id:
            return {
                "id": "",
                "name": "",
                "valid": "no",
                "key": "missing",
                "reason": "未选择 Credential Profile",
                "legacy": "no",
            }
        try:
            profile = resolve_profile(state, active_id)
        except CredentialProfileError:
            return {
                "id": active_id,
                "name": "",
                "valid": "no",
                "key": "missing",
                "reason": f"当前 Credential Profile 不存在：{active_id}",
                "legacy": "no",
            }
        present = profile_key_ready(tool, state, profile, key_exists, legacy_exists)
        return {
            "id": profile["id"],
            "name": profile["displayName"],
            "valid": "yes" if present else "no",
            "key": "present" if present else "missing",
            "reason": "" if present else f"Credential Profile {profile['displayName']} 的 Keychain 条目缺失",
            "legacy": "yes" if migrated else "no",
        }
    except CredentialProfileError as exc:
        return {
            "id": "",
            "name": "",
            "valid": "no",
            "key": "missing",
            "reason": str(exc),
            "legacy": "no",
        }


def _resolve_for_cli(tool: str, home: Path, reference: str | None) -> tuple[dict[str, Any], dict[str, str]]:
    state, _ = load_effective_state(tool, home)
    profile = resolve_profile(state, reference)
    if not profile_key_ready(tool, state, profile):
        raise CredentialProfileError(
            f"Credential Profile {profile['displayName']} 的 Keychain 条目缺失"
        )
    return state, profile


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="credential_profiles.py")
    parser.add_argument("command", choices=["resolve", "candidate", "status", "list"])
    parser.add_argument("tool", choices=sorted(SERVICES))
    parser.add_argument("home", type=Path)
    parser.add_argument("--credential")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "resolve":
            _, profile = _resolve_for_cli(args.tool, args.home, args.credential)
            sys.stdout.write(profile["id"] + "\t" + profile["displayName"] + "\n")
        elif args.command == "candidate":
            if args.output is None:
                parser.error("candidate requires --output")
            state, profile = _resolve_for_cli(args.tool, args.home, args.credential)
            atomic_write(args.output, state_bytes(state_with_active(state, profile["id"])))
            sys.stdout.write(profile["id"] + "\t" + profile["displayName"] + "\n")
        elif args.command == "status":
            result = active_status(args.tool, args.home)
            for key, value in result.items():
                sys.stdout.write(f"credential_profile_{key}={value}\n")
        else:
            state, _ = load_effective_state(args.tool, args.home)
            active_id = state.get("activeProfileId")
            for profile in state["profiles"]:
                marker = "yes" if profile["id"] == active_id else "no"
                present = "yes" if profile_key_ready(args.tool, state, profile) else "no"
                sys.stdout.write(
                    f"{profile['id']}\t{profile['displayName']}\t{marker}\t{present}\n"
                )
    except CredentialProfileError as exc:
        sys.stderr.write(f"credential-profiles: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
