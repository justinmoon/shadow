#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


SCENE_RS = Path(__file__).resolve().parents[2] / "ui" / "crates" / "shadow-ui-core" / "src" / "scene.rs"


def read_const(name: str) -> int:
    pattern = re.compile(rf"pub const {re.escape(name)}: u32 = (\d+);")
    text = SCENE_RS.read_text(encoding="utf-8")
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"runtime_viewport.py: missing {name} in {SCENE_RS}")
    return int(match.group(1))


def fit_within(viewport_width: int, viewport_height: int, max_width: int, max_height: int) -> tuple[int, int]:
    if max_width <= 0 or max_height <= 0:
        raise SystemExit("runtime_viewport.py: fit bounds must be positive")
    if max_width * viewport_height <= max_height * viewport_width:
        fitted_width = max_width
        fitted_height = (max_width * viewport_height) // viewport_width
    else:
        fitted_width = (max_height * viewport_width) // viewport_height
        fitted_height = max_height
    if fitted_width <= 0 or fitted_height <= 0:
        raise SystemExit("runtime_viewport.py: fitted viewport collapsed to zero")
    return fitted_width, fitted_height


def parse_size(raw: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)x(\d+)", raw)
    if not match:
        raise SystemExit(f"runtime_viewport.py: invalid size {raw!r}, expected WIDTHxHEIGHT")
    return int(match.group(1)), int(match.group(2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fit", metavar="WIDTHxHEIGHT")
    args = parser.parse_args()

    shell_width = read_const("SHELL_WIDTH_PX")
    shell_height = read_const("SHELL_HEIGHT_PX")
    app_viewport_y = read_const("APP_VIEWPORT_Y_PX")
    viewport_width = shell_width
    viewport_height = shell_height - app_viewport_y

    if args.fit:
        max_width, max_height = parse_size(args.fit)
        fitted_width, fitted_height = fit_within(
            viewport_width,
            viewport_height,
            max_width,
            max_height,
        )
        print(f"viewport_width={viewport_width}")
        print(f"viewport_height={viewport_height}")
        print(f"fitted_width={fitted_width}")
        print(f"fitted_height={fitted_height}")
        return

    print(f"viewport_width={viewport_width}")
    print(f"viewport_height={viewport_height}")


if __name__ == "__main__":
    main()
