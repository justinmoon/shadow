#!/usr/bin/env python3
import argparse
import re
from functools import lru_cache
from pathlib import Path


SCENE_RS = Path(__file__).resolve().parents[2] / "ui" / "crates" / "shadow-ui-core" / "src" / "scene.rs"


@lru_cache(maxsize=1)
def const_expressions() -> dict[str, str]:
    pattern = re.compile(r"pub const (\w+): u32 =\s*([^;]+);", re.MULTILINE)
    return {
        name: expression.strip()
        for name, expression in pattern.findall(SCENE_RS.read_text(encoding="utf-8"))
    }


def read_const(name: str) -> int:
    return eval_const(name, ())


def eval_const(name: str, stack: tuple[str, ...]) -> int:
    expression = const_expressions().get(name)
    if expression is None:
        raise SystemExit(f"runtime_viewport.py: missing {name} in {SCENE_RS}")
    if name in stack:
        cycle = " -> ".join((*stack, name))
        raise SystemExit(f"runtime_viewport.py: const cycle detected: {cycle}")

    tokens = expression.split()
    if not tokens:
        raise SystemExit(f"runtime_viewport.py: empty expression for {name}")

    value = eval_token(tokens[0], stack + (name,))
    index = 1
    while index < len(tokens):
        if index + 1 >= len(tokens):
            raise SystemExit(f"runtime_viewport.py: malformed expression for {name}: {expression!r}")
        operator = tokens[index]
        rhs = eval_token(tokens[index + 1], stack + (name,))
        if operator == "+":
            value += rhs
        elif operator == "-":
            value -= rhs
        else:
            raise SystemExit(f"runtime_viewport.py: unsupported operator {operator!r} in {name}")
        index += 2
    return value


def eval_token(token: str, stack: tuple[str, ...]) -> int:
    if token.isdigit():
        return int(token)
    return eval_const(token, stack)


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

    viewport_width = read_const("APP_VIEWPORT_WIDTH_PX")
    viewport_height = read_const("APP_VIEWPORT_HEIGHT_PX")

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
