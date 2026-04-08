#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

TEST_MINT_BIN="$("$SCRIPT_DIR/ensure_cashu_test_mint.sh")"

TEST_MINT_BIN="$TEST_MINT_BIN" python3 - <<'PY'
import html
import json
import os
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


REPO_ROOT = Path.cwd()
SCRIPT_DIR = REPO_ROOT / "scripts"
TEST_MINT_BIN = os.environ["TEST_MINT_BIN"]
FUND_AMOUNT_SATS = 100
SEND_AMOUNT_SATS = 21
PAY_AMOUNT_SATS = 7


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run(command, *, env=None, timeout=60):
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=True,
    )


def wait_for_http(url: str, *, timeout: float = 30.0, process=None, label: str = "service") -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError):
            if process is not None and process.poll() is not None:
                stderr = process.stderr.read() if process.stderr is not None else ""
                stdout = process.stdout.read() if process.stdout is not None else ""
                raise SystemExit(
                    f"runtime-app-cashu-wallet-smoke: {label} exited before {url} became ready\n"
                    f"stdout:\n{stdout}\n"
                    f"stderr:\n{stderr}",
                )
            time.sleep(0.25)
    stderr = ""
    stdout = ""
    if process is not None:
        stderr = process.stderr.read() if process.stderr is not None else ""
        stdout = process.stdout.read() if process.stdout is not None else ""
    raise SystemExit(
        f"runtime-app-cashu-wallet-smoke: timed out waiting for {url}\n"
        f"stdout:\n{stdout}\n"
        f"stderr:\n{stderr}",
    )


def send(process, request):
    assert process.stdin is not None
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise SystemExit(
            f"runtime-app-cashu-wallet-smoke: runtime host closed stdout\n{stderr}",
        )
    response = json.loads(line)
    status = response.get("status")
    if status == "error":
        raise SystemExit(
            f"runtime-app-cashu-wallet-smoke: runtime host error: {response['message']}",
        )
    return response


def render(process) -> str:
    response = send(process, {"op": "render"})
    return response["payload"]["html"]


def render_if_dirty(process):
    return send(process, {"op": "render_if_dirty"})


def focus_input(process, target_id: str) -> None:
    send(process, {"op": "dispatch", "event": {"targetId": target_id, "type": "focus"}})


def input_text(process, target_id: str, value: str) -> None:
    focus_input(process, target_id)
    send(
        process,
        {
            "op": "dispatch",
            "event": {
                "targetId": target_id,
                "type": "input",
                "value": value,
                "selection": {
                    "start": len(value),
                    "end": len(value),
                    "direction": "none",
                },
            },
        },
    )


def click(process, target_id: str) -> str:
    response = send(
        process,
        {"op": "dispatch", "event": {"targetId": target_id, "type": "click"}},
    )
    return response["payload"]["html"]


def wait_for_html(process, predicate, *, timeout: float = 30.0, description: str) -> str:
    deadline = time.time() + timeout
    last_html = render(process)
    if predicate(last_html):
        return last_html

    while time.time() < deadline:
        response = render_if_dirty(process)
        if response.get("status") == "no_update":
            time.sleep(0.2)
            continue
        last_html = response["payload"]["html"]
        if predicate(last_html):
            return last_html
    raise SystemExit(
        f"runtime-app-cashu-wallet-smoke: timed out waiting for {description}\n"
        f"last html:\n{last_html}",
    )


def attr(html_text: str, name: str) -> str:
    pattern = re.compile(rf'{re.escape(name)}="([^"]*)"')
    match = pattern.search(html_text)
    if not match:
        return ""
    return html.unescape(match.group(1))


with tempfile.TemporaryDirectory(prefix="shadow-cashu-wallet-") as temp_dir:
    temp_path = Path(temp_dir)
    mint_port = reserve_port()
    mint_url = f"http://127.0.0.1:{mint_port}"
    mint_work_dir = temp_path / "mint"
    mint_work_dir.mkdir(parents=True, exist_ok=True)
    config_path = mint_work_dir / "config.toml"
    config_path.write_text(
        f"""
[info]
url = "{mint_url}"
listen_host = "127.0.0.1"
listen_port = {mint_port}
mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

[database]
engine = "sqlite"

[ln]
ln_backend = "fakewallet"

[fake_wallet]
supported_units = ["sat"]
fee_percent = 0.0
reserve_fee_min = 1
min_delay_time = 1
max_delay_time = 1

[limits]
max_inputs = 1000
""".strip()
        + "\n",
        encoding="utf-8",
    )

    mint_process = subprocess.Popen(
        [
            TEST_MINT_BIN,
            "--work-dir",
            str(mint_work_dir),
            "--config",
            str(config_path),
        ],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        wait_for_http(
            f"{mint_url}/v1/info",
            process=mint_process,
            label="cdk-mintd",
        )

        prepare_env = os.environ.copy()
        prepare_env.update(
            {
                "SHADOW_RUNTIME_APP_INPUT_PATH": "runtime/app-cashu-wallet/app.tsx",
                "SHADOW_RUNTIME_APP_CACHE_DIR": "build/runtime/app-cashu-wallet-host",
                "SHADOW_RUNTIME_APP_CONFIG_JSON": json.dumps(
                    {
                        "defaultFundAmountSats": FUND_AMOUNT_SATS,
                        "defaultMintUrl": mint_url,
                    }
                ),
            }
        )
        session_json = run(
            [str(SCRIPT_DIR / "runtime_prepare_host_session.sh")],
            env=prepare_env,
            timeout=600,
        ).stdout
        session = json.loads(session_json)

        wallet_data_dir = temp_path / "wallet"
        wallet_data_dir.mkdir(parents=True, exist_ok=True)

        runtime_env = os.environ.copy()
        runtime_env["SHADOW_RUNTIME_CASHU_DATA_DIR"] = str(wallet_data_dir)
        process = subprocess.Popen(
            [session["runtimeHostBinaryPath"], "--session", session["bundlePath"]],
            cwd=REPO_ROOT,
            env=runtime_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            initial_html = render(process)
            if "Shadow Cashu" not in initial_html or "Wallet" not in initial_html:
                raise SystemExit(
                    "runtime-app-cashu-wallet-smoke: initial render missing wallet headline",
                )

            input_text(process, "cashu-mint-url", mint_url)
            click(process, "cashu-add-mint")
            wait_for_html(
                process,
                lambda current: attr(current, "data-shadow-active-mint") == mint_url
                and attr(current, "data-shadow-wallet-count") == "1"
                and attr(current, "data-shadow-status-kind") == "success",
                description="trusted mint activation",
            )

            click(process, "cashu-create-quote")
            quote_html = wait_for_html(
                process,
                lambda current: bool(attr(current, "data-shadow-latest-invoice"))
                and attr(current, "data-shadow-fund-quote-state") == "unpaid"
                and attr(current, "data-shadow-fund-quote-amount") == str(FUND_AMOUNT_SATS),
                description="funding invoice",
            )
            invoice_1 = attr(quote_html, "data-shadow-latest-invoice")
            if not invoice_1.startswith("ln"):
                raise SystemExit(
                    "runtime-app-cashu-wallet-smoke: funding invoice did not look like BOLT11",
                )

            for _ in range(15):
                click(process, "cashu-mint-quote")
                minted_html = wait_for_html(
                    process,
                    lambda current: attr(current, "data-shadow-status-kind") != "working",
                    description="funding quote mint attempt",
                )
                if attr(minted_html, "data-shadow-total-balance") == str(FUND_AMOUNT_SATS):
                    break
                time.sleep(0.5)
            else:
                raise SystemExit(
                    "runtime-app-cashu-wallet-smoke: funding quote never minted into wallet balance",
                )

            input_text(process, "cashu-send-amount", str(SEND_AMOUNT_SATS))
            click(process, "cashu-send-token")
            sent_html = wait_for_html(
                process,
                lambda current: bool(attr(current, "data-shadow-latest-token")),
                description="Cashu send token",
            )
            sent_token = attr(sent_html, "data-shadow-latest-token")
            if not sent_token.startswith("cashu"):
                raise SystemExit(
                    "runtime-app-cashu-wallet-smoke: send token did not produce a Cashu token",
                )

            click(process, "cashu-receive-submit")
            received_html = wait_for_html(
                process,
                lambda current: attr(current, "data-shadow-total-balance") == str(FUND_AMOUNT_SATS)
                and attr(current, "data-shadow-latest-receive-amount") == str(SEND_AMOUNT_SATS),
                description="Cashu token receive",
            )

            input_text(process, "cashu-fund-amount", str(PAY_AMOUNT_SATS))
            click(process, "cashu-create-quote")
            invoice_html = wait_for_html(
                process,
                lambda current: attr(current, "data-shadow-fund-quote-state") == "unpaid"
                and attr(current, "data-shadow-fund-quote-amount") == str(PAY_AMOUNT_SATS),
                description="second invoice generation",
            )
            invoice_2 = attr(invoice_html, "data-shadow-latest-invoice")
            if not invoice_2.startswith("ln"):
                raise SystemExit(
                    "runtime-app-cashu-wallet-smoke: second invoice did not look like BOLT11",
                )

            input_text(process, "cashu-pay-invoice", invoice_2)
            click(process, "cashu-pay-submit")
            paid_invoice_html = wait_for_html(
                process,
                lambda current: attr(current, "data-shadow-latest-payment-amount") == str(PAY_AMOUNT_SATS)
                and attr(current, "data-shadow-latest-payment-state") == "paid",
                description="Lightning invoice payment",
            )
            post_pay_balance = int(attr(paid_invoice_html, "data-shadow-total-balance") or "0")

            for _ in range(15):
                click(process, "cashu-mint-quote")
                reminted_html = wait_for_html(
                    process,
                    lambda current: attr(current, "data-shadow-status-kind") != "working",
                    description="second quote mint attempt",
                )
                if int(attr(reminted_html, "data-shadow-total-balance") or "0") > post_pay_balance:
                    break
                time.sleep(0.5)
            else:
                raise SystemExit(
                    "runtime-app-cashu-wallet-smoke: paid Lightning invoice never became mintable",
                )

            result = {
                "bundlePath": session["bundlePath"],
                "invoice": invoice_1,
                "invoicePaid": invoice_2,
                "mintUrl": mint_url,
                "result": "cashu-wallet-ok",
                "token": sent_token,
            }
        finally:
            assert process.stdin is not None
            process.stdin.close()
            stderr = process.stderr.read() if process.stderr is not None else ""
            return_code = process.wait(timeout=10)
            if return_code not in (0, None):
                raise SystemExit(
                    f"runtime-app-cashu-wallet-smoke: runtime host exited {return_code}\n{stderr}",
                )
    finally:
        mint_process.terminate()
        try:
            mint_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            mint_process.kill()
            mint_process.wait(timeout=10)

    print(json.dumps(result, indent=2))
PY
