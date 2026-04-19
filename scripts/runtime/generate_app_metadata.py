#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


VALID_ICON_COLORS = {
    "ICON_BLUE",
    "ICON_GREEN",
    "ICON_ORANGE",
    "ICON_RED",
    "ICON_PINK",
    "ICON_CYAN",
    "ICON_YELLOW",
    "ICON_PURPLE",
}
VALID_APP_MODELS = {"typescript", "rust"}
VALID_PROFILES = {"vm-shell", "pixel-shell"}
ENV_KEY_PATTERN = re.compile(r"[A-Z][A-Z0-9_]*")
RESERVED_LAUNCH_ENV_KEYS = frozenset(
    {
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "SHADOW_COMPOSITOR_CONTROL",
        "SHADOW_BLITZ_PLATFORM_CONTROL_SOCKET",
        "SHADOW_RUNTIME_APP_BUNDLE_PATH",
        "SHADOW_SYSTEM_BINARY_PATH",
        "SHADOW_APP_TITLE",
        "SHADOW_BLITZ_APP_TITLE",
        "SHADOW_APP_WAYLAND_APP_ID",
        "SHADOW_BLITZ_WAYLAND_APP_ID",
        "SHADOW_APP_WAYLAND_INSTANCE_NAME",
        "SHADOW_BLITZ_WAYLAND_INSTANCE_NAME",
        "SHADOW_APP_SURFACE_WIDTH",
        "SHADOW_BLITZ_SURFACE_WIDTH",
        "SHADOW_APP_SURFACE_HEIGHT",
        "SHADOW_BLITZ_SURFACE_HEIGHT",
        "SHADOW_APP_SAFE_AREA_LEFT",
        "SHADOW_BLITZ_SAFE_AREA_LEFT",
        "SHADOW_APP_SAFE_AREA_TOP",
        "SHADOW_BLITZ_SAFE_AREA_TOP",
        "SHADOW_APP_SAFE_AREA_RIGHT",
        "SHADOW_BLITZ_SAFE_AREA_RIGHT",
        "SHADOW_APP_SAFE_AREA_BOTTOM",
        "SHADOW_BLITZ_SAFE_AREA_BOTTOM",
        "SHADOW_GUEST_KEYBOARD_SEAT",
        "SHADOW_BLITZ_SOFTWARE_KEYBOARD",
    }
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_manifest_path() -> Path:
    return repo_root() / "runtime" / "apps.json"


def default_rust_out_path() -> Path:
    return repo_root() / "ui" / "crates" / "shadow-ui-core" / "src" / "generated_apps.rs"


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"{path}: invalid JSON: {error}") from error
    validate_manifest(manifest, path)
    return manifest


def validate_manifest(manifest: dict[str, Any], path: Path) -> None:
    if manifest.get("schemaVersion") != 1:
        raise SystemExit(f"{path}: expected schemaVersion 1")
    shell = manifest.get("shell")
    if not isinstance(shell, dict):
        raise SystemExit(f"{path}: shell must be an object")
    require_string(shell, "id", f"{path}: shell")
    require_string(shell, "waylandAppId", f"{path}: shell")

    apps = manifest.get("apps")
    if not isinstance(apps, list) or not apps:
        raise SystemExit(f"{path}: apps must be a non-empty array")

    seen_ids: set[str] = set()
    seen_wayland_ids: set[str] = {shell["waylandAppId"]}
    seen_bundle_envs: set[str] = set()
    seen_bundle_filenames: set[str] = set()
    for index, app in enumerate(apps):
        if not isinstance(app, dict):
            raise SystemExit(f"{path}: apps[{index}] must be an object")
        label = f"{path}: apps[{index}]"
        app_id = require_string(app, "id", label)
        if not re.fullmatch(r"[a-z][a-z0-9-]*", app_id):
            raise SystemExit(f"{label}: invalid app id {app_id!r}")
        if app_id == shell["id"]:
            raise SystemExit(f"{label}: app id must not duplicate shell.id {app_id!r}")
        if app_id in seen_ids:
            raise SystemExit(f"{label}: duplicate app id {app_id!r}")
        seen_ids.add(app_id)
        model = require_string(app, "model", label)
        if model not in VALID_APP_MODELS:
            valid = ", ".join(sorted(VALID_APP_MODELS))
            raise SystemExit(f"{label}: model must be one of {valid}")
        for field in (
            "title",
            "iconLabel",
            "subtitle",
            "lifecycleHint",
            "binaryName",
            "waylandAppId",
            "windowTitle",
        ):
            require_string(app, field, label)
        if app["waylandAppId"] in seen_wayland_ids:
            raise SystemExit(f"{label}: duplicate waylandAppId {app['waylandAppId']!r}")
        seen_wayland_ids.add(app["waylandAppId"])
        validate_launch_env(app.get("launchEnv"), label)

        profiles = app.get("profiles")
        if not isinstance(profiles, list) or not profiles:
            raise SystemExit(f"{label}: profiles must be a non-empty array")
        unknown_profiles = set(profiles) - VALID_PROFILES
        if unknown_profiles:
            unknown = ", ".join(sorted(unknown_profiles))
            raise SystemExit(f"{label}: unsupported profiles: {unknown}")
        if model == "rust" and "pixel-shell" in profiles:
            raise SystemExit(f"{label}: rust apps must not declare pixel-shell")

        runtime = app.get("runtime")
        if model == "rust":
            if runtime is not None:
                raise SystemExit(f"{label}: rust apps must not declare runtime")
        else:
            if not isinstance(runtime, dict):
                raise SystemExit(f"{label}: runtime must be an object")
            for field in ("bundleEnv", "bundleFilename", "inputPath"):
                require_string(runtime, field, f"{label}.runtime")
            if runtime["bundleEnv"] in seen_bundle_envs:
                raise SystemExit(
                    f"{label}.runtime: duplicate bundleEnv {runtime['bundleEnv']!r}"
                )
            seen_bundle_envs.add(runtime["bundleEnv"])
            if runtime["bundleFilename"] in seen_bundle_filenames:
                raise SystemExit(
                    f"{label}.runtime: duplicate bundleFilename {runtime['bundleFilename']!r}"
                )
            seen_bundle_filenames.add(runtime["bundleFilename"])
            cache_dirs = runtime.get("cacheDirs")
            if not isinstance(cache_dirs, dict):
                raise SystemExit(f"{label}.runtime: cacheDirs must be an object")
            for profile in profiles:
                require_string(cache_dirs, profile, f"{label}.runtime.cacheDirs")
            config_env = runtime.get("configEnv")
            if config_env is not None and not isinstance(config_env, str):
                raise SystemExit(
                    f"{label}.runtime: configEnv must be a string when present"
                )
            asset_resolver = runtime.get("assetResolver")
            if asset_resolver is not None and asset_resolver != "podcast-demo":
                raise SystemExit(
                    f"{label}.runtime: unsupported assetResolver {asset_resolver!r}"
                )
            optional_bundle = runtime.get("optionalBundle")
            if optional_bundle is not None and not isinstance(optional_bundle, bool):
                raise SystemExit(
                    f"{label}.runtime: optionalBundle must be a boolean when present"
                )

        ui = app.get("ui")
        if not isinstance(ui, dict):
            raise SystemExit(f"{label}: ui must be an object")
        icon_color = require_string(ui, "iconColor", f"{label}.ui")
        if icon_color not in VALID_ICON_COLORS:
            valid = ", ".join(sorted(VALID_ICON_COLORS))
            raise SystemExit(f"{label}.ui: iconColor must be one of {valid}")


def require_string(data: dict[str, Any], field: str, label: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"{label}: {field} must be a non-empty string")
    return value


def validate_launch_env(env_map: Any, label: str) -> None:
    if env_map is None:
        return
    if not isinstance(env_map, dict):
        raise SystemExit(f"{label}: launchEnv must be an object when present")
    for key, value in env_map.items():
        if not isinstance(key, str) or not key:
            raise SystemExit(f"{label}.launchEnv: env keys must be non-empty strings")
        if not ENV_KEY_PATTERN.fullmatch(key):
            raise SystemExit(
                f"{label}.launchEnv: unsupported env key {key!r}; expected SHOUTY_CASE"
            )
        if key in RESERVED_LAUNCH_ENV_KEYS:
            raise SystemExit(
                f"{label}.launchEnv: env key {key!r} is reserved for launcher-managed configuration"
            )
        if not isinstance(value, str):
            raise SystemExit(
                f"{label}.launchEnv[{key!r}]: env values must be strings"
            )


def rust_const_name(app_id: str, suffix: str) -> str:
    prefix = re.sub(r"[^A-Z0-9]+", "_", app_id.upper()).strip("_")
    return f"{prefix}_{suffix}"


def rust_str(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def rust_runtime_cache_dir(runtime: dict[str, Any]) -> str:
    cache_dirs = runtime["cacheDirs"]
    return cache_dirs.get("vm-shell") or next(iter(cache_dirs.values()))


def rust_app_model(model: str) -> str:
    if model == "typescript":
        return "AppModel::TypeScript"
    if model == "rust":
        return "AppModel::Rust"
    raise AssertionError(f"unsupported app model {model!r}")


def rust_app_array(array_name: str, app_const_names: list[str]) -> list[str]:
    lines = [f"pub const {array_name}: [DemoApp; {len(app_const_names)}] = ["]
    lines.extend(f"    {name}," for name in app_const_names)
    lines.extend(["];", ""])
    return lines


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(repo_root()))
    except ValueError:
        return str(path)


def generate_rust(manifest: dict[str, Any]) -> str:
    apps = manifest["apps"]
    icon_colors = sorted({app["ui"]["iconColor"] for app in apps})
    super_imports = ["AppId", "AppLaunchEnv", "AppModel", "DemoApp"]
    if any(app["model"] == "typescript" for app in apps):
        super_imports.append("TypeScriptAppRuntime")
    lines: list[str] = [
        "// @generated by scripts/runtime/generate_app_metadata.py; do not edit by hand.",
        f"use super::{{{', '.join(super_imports)}}};",
        f"use crate::color::{{{', '.join(icon_colors)}}};",
        "",
    ]

    shell = manifest["shell"]
    lines.extend(
        [
            f"pub const SHELL_APP_ID: AppId = AppId::new({rust_str(shell['id'])});",
            f"pub const SHELL_WAYLAND_APP_ID: &str = {rust_str(shell['waylandAppId'])};",
            "",
        ]
    )

    app_const_names: list[str] = []
    vm_shell_app_const_names: list[str] = []
    pixel_shell_app_const_names: list[str] = []
    for app in apps:
        app_id = app["id"]
        model = app["model"]
        runtime = app.get("runtime")
        id_const = rust_const_name(app_id, "APP_ID")
        app_const = rust_const_name(app_id, "APP")
        model_const = rust_const_name(app_id, "MODEL")
        app_const_names.append(app_const)
        profiles = set(app["profiles"])
        if "vm-shell" in profiles:
            vm_shell_app_const_names.append(app_const)
        if "pixel-shell" in profiles and model == "typescript":
            pixel_shell_app_const_names.append(app_const)
        lines.extend(
            [
                f"pub const {id_const}: AppId = AppId::new({rust_str(app_id)});",
                f"pub const {rust_const_name(app_id, 'WAYLAND_APP_ID')}: &str = {rust_str(app['waylandAppId'])};",
                f"pub const {rust_const_name(app_id, 'WINDOW_TITLE')}: &str = {rust_str(app['windowTitle'])};",
                f"pub const {model_const}: AppModel = {rust_app_model(model)};",
                "",
            ]
        )
        if model == "typescript":
            assert isinstance(runtime, dict)
            lines.extend(
                [
                    f"pub const {rust_const_name(app_id, 'RUNTIME_BUNDLE_ENV')}: &str = {rust_str(runtime['bundleEnv'])};",
                    f"pub const {rust_const_name(app_id, 'RUNTIME_INPUT_PATH')}: &str = {rust_str(runtime['inputPath'])};",
                    f"pub const {rust_const_name(app_id, 'RUNTIME_CACHE_DIR')}: &str = {rust_str(rust_runtime_cache_dir(runtime))};",
                    f"pub const {rust_const_name(app_id, 'TYPESCRIPT_RUNTIME')}: TypeScriptAppRuntime = TypeScriptAppRuntime {{",
                    f"    bundle_env: {rust_const_name(app_id, 'RUNTIME_BUNDLE_ENV')},",
                    f"    input_path: {rust_const_name(app_id, 'RUNTIME_INPUT_PATH')},",
                    f"    cache_dir: {rust_const_name(app_id, 'RUNTIME_CACHE_DIR')},",
                    "};",
                    "",
                ]
            )
            typescript_runtime = f"Some({rust_const_name(app_id, 'TYPESCRIPT_RUNTIME')})"
            runtime_bundle_env = rust_const_name(app_id, "RUNTIME_BUNDLE_ENV")
            runtime_input_path = rust_const_name(app_id, "RUNTIME_INPUT_PATH")
            runtime_cache_dir = rust_const_name(app_id, "RUNTIME_CACHE_DIR")
        else:
            typescript_runtime = "None"
            runtime_bundle_env = '""'
            runtime_input_path = '""'
            runtime_cache_dir = '""'
        launch_env = app.get("launchEnv") or {}
        if launch_env:
            env_const = rust_const_name(app_id, "LAUNCH_ENV")
            launch_env_entries = sorted(launch_env.items())
            if len(launch_env_entries) == 1:
                key, value = launch_env_entries[0]
                lines.extend(
                    [
                        f"pub const {env_const}: [AppLaunchEnv; 1] = [({rust_str(key)}, {rust_str(value)})];",
                        "",
                    ]
                )
            else:
                lines.append(
                    f"pub const {env_const}: [AppLaunchEnv; {len(launch_env_entries)}] = ["
                )
                for key, value in launch_env_entries:
                    lines.append(f"    ({rust_str(key)}, {rust_str(value)}),")
                lines.extend(["];", ""])
            launch_env_ref = f"&{env_const}"
        else:
            launch_env_ref = "&[]"
        lines.extend(
            [
                f"pub const {app_const}: DemoApp = DemoApp {{",
                f"    id: {id_const},",
                f"    model: {model_const},",
                f"    icon_label: {rust_str(app['iconLabel'])},",
                f"    title: {rust_str(app['title'])},",
                f"    subtitle: {rust_str(app['subtitle'])},",
                f"    lifecycle_hint: {rust_str(app['lifecycleHint'])},",
                f"    binary_name: {rust_str(app['binaryName'])},",
                f"    wayland_app_id: {rust_const_name(app_id, 'WAYLAND_APP_ID')},",
                f"    window_title: {rust_const_name(app_id, 'WINDOW_TITLE')},",
                f"    typescript_runtime: {typescript_runtime},",
                f"    runtime_bundle_env: {runtime_bundle_env},",
                f"    runtime_input_path: {runtime_input_path},",
                f"    runtime_cache_dir: {runtime_cache_dir},",
                f"    launch_env: {launch_env_ref},",
                f"    icon_color: {app['ui']['iconColor']},",
                "};",
                "",
            ]
        )

    lines.extend(rust_app_array("DEMO_APPS", app_const_names))
    lines.extend(rust_app_array("VM_SHELL_DEMO_APPS", vm_shell_app_const_names))
    lines.extend(rust_app_array("PIXEL_SHELL_DEMO_APPS", pixel_shell_app_const_names))
    return rustfmt_source("\n".join(lines))


def rustfmt_source(content: str) -> str:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".rs", delete=False
    ) as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    try:
        result = subprocess.run(
            ["rustfmt", "--edition", "2021", str(temp_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip() or "rustfmt failed without stderr output"
            raise SystemExit(f"generate_app_metadata: rustfmt failed: {stderr}")
        return temp_path.read_text(encoding="utf-8")
    finally:
        temp_path.unlink(missing_ok=True)


def check_or_write(path: Path, content: str, *, check: bool) -> int:
    if check:
        current = path.read_text(encoding="utf-8") if path.exists() else ""
        if current != content:
            print(
                f"generate_app_metadata: {display_path(path)} is stale; "
                "run scripts/runtime/generate_app_metadata.py",
                file=sys.stderr,
            )
            return 1
        print("generate_app_metadata: ok")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"wrote {display_path(path)}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=default_manifest_path())
    parser.add_argument("--rust-out", type=Path, default=default_rust_out_path())
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest = load_manifest(args.manifest)
    return check_or_write(args.rust_out, generate_rust(manifest), check=args.check)


if __name__ == "__main__":
    raise SystemExit(main())
