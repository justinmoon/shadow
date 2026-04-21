from __future__ import annotations

import json
import socket
import subprocess
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Sequence


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def run(
    repo_root: Path,
    command: Sequence[str],
    *,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    timeout: int = 20,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        cwd=repo_root,
        env=env,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=True,
    )


def query_relay_via_websocket(
    repo_root: Path,
    relay_url: str,
    *,
    kinds: Sequence[int] = (1,),
    limit: int = 50,
    timeout: int = 5,
) -> str:
    script = f"""
const ws = new WebSocket({json.dumps(relay_url)});
const messages = [];
ws.onopen = () => ws.send(JSON.stringify(["REQ", "sub1", {{"kinds": {json.dumps(list(kinds))}, "limit": {limit}}}]));
ws.onmessage = (event) => {{
  messages.push(String(event.data));
  if (String(event.data).includes('"EOSE"')) {{
    console.log(JSON.stringify(messages));
    ws.close();
  }}
}};
ws.onclose = () => process.exit(0);
setTimeout(() => {{
  console.log(JSON.stringify(messages));
  ws.close();
}}, 2000);
"""
    result = run(repo_root, ["node", "-e", script], timeout=timeout)
    return result.stdout.strip()


def wait_for_relay_ready(
    stderr_path: Path,
    name: str,
    *,
    timeout_seconds: float = 10.0,
) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if stderr_path.is_file() and "relay running at" in stderr_path.read_text(
            encoding="utf-8",
            errors="replace",
        ):
            return
        time.sleep(0.1)

    stderr = ""
    if stderr_path.is_file():
        stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
    raise SystemExit(f"timed out waiting for {name}\n{stderr}")


@dataclass
class LocalRelay:
    repo_root: Path
    process: subprocess.Popen[str]
    url: str
    port: int
    temp_dir: tempfile.TemporaryDirectory[str]
    stdout_path: Path
    stderr_path: Path
    events_path: Path | None

    def query_kind1(self, *, limit: int = 50, timeout: int = 5) -> str:
        return query_relay_via_websocket(
            self.repo_root,
            self.url,
            kinds=(1,),
            limit=limit,
            timeout=timeout,
        )


@contextmanager
def running_relay(
    repo_root: Path,
    *,
    event_lines: Sequence[str] = (),
    prefix: str = "shadow-nostr-relay-",
    host: str = "127.0.0.1",
) -> Iterator[LocalRelay]:
    temp_dir = tempfile.TemporaryDirectory(prefix=prefix)
    temp_path = Path(temp_dir.name)
    stdout_path = temp_path / "relay.out"
    stderr_path = temp_path / "relay.err"

    try:
        for attempt in range(1, 6):
            port = reserve_port()
            url = f"ws://{host}:{port}"
            command = [
                "nak",
                "serve",
                "--hostname",
                host,
                "--port",
                str(port),
            ]

            events_path: Path | None = None
            if event_lines:
                events_path = temp_path / "relay-events.jsonl"
                events_path.write_text(
                    "\n".join(event_lines) + "\n",
                    encoding="utf-8",
                )
                command.extend(["--events", str(events_path)])

            with stdout_path.open("w", encoding="utf-8") as stdout_handle, stderr_path.open(
                "w",
                encoding="utf-8",
            ) as stderr_handle:
                process = subprocess.Popen(
                    command,
                    cwd=repo_root,
                    stdout=stdout_handle,
                    stderr=stderr_handle,
                    text=True,
                )

            try:
                wait_for_relay_ready(stderr_path, "local nak relay")
            except BaseException:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
                if attempt == 5:
                    raise
                continue

            try:
                yield LocalRelay(
                    repo_root=repo_root,
                    process=process,
                    url=url,
                    port=port,
                    temp_dir=temp_dir,
                    stdout_path=stdout_path,
                    stderr_path=stderr_path,
                    events_path=events_path,
                )
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            break
        else:
            raise SystemExit("failed to start local nak relay")
    finally:
        temp_dir.cleanup()


def build_text_note_events(repo_root: Path, contents: Sequence[str]) -> list[str]:
    with running_relay(repo_root, prefix="shadow-nostr-seed-") as relay:
        event_lines: list[str] = []
        for content in contents:
            key = run(repo_root, ["nak", "key", "generate"], timeout=10).stdout.strip()
            event_lines.append(
                run(
                    repo_root,
                    ["nak", "publish", "--sec", key, relay.url],
                    input_text=content.rstrip("\n") + "\n",
                    timeout=20,
                ).stdout.strip(),
            )
        return event_lines
