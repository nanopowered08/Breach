#!/usr/bin/env python3
"""Run the BreachEngine map-load smoke test through Roblox Open Cloud.

This script is intentionally invoked only by the manual workflow_dispatch workflow.
It downloads the mission source on the GitHub runner, uploads it as a binary input,
creates one Luau execution task, and reports its result and logs.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from pathlib import Path

API = "https://apis.roblox.com/cloud/v2"
ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> "None":
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def request(url: str, *, method: str = "GET", headers: dict[str, str] | None = None,
            body: bytes | None = None, timeout: int = 30) -> bytes:
    req = Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urlopen(req, timeout=timeout) as response:
            return response.read()
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        fail(f"HTTP {exc.code} from {url}: {detail[:2000]}")
    except (URLError, TimeoutError) as exc:
        fail(f"Request failed for {url}: {exc}")


def json_request(url: str, *, method: str, api_key: str,
                 payload: dict | None = None) -> dict:
    headers = {"x-api-key": api_key, "accept": "application/json"}
    body = None
    if payload is not None:
        headers["content-type"] = "application/json"
        body = json.dumps(payload, separators=(",", ":")).encode()
    raw = request(url, method=method, headers=headers, body=body)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"Roblox returned invalid JSON: {exc}")


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        fail(f"Missing required GitHub secret/variable: {name}")
    return value


def main() -> None:
    api_key = required_env("ROBLOX_API_KEY")
    universe_id = required_env("ROBLOX_UNIVERSE_ID")
    place_id = required_env("ROBLOX_PLACE_ID")
    mission_url = required_env("MISSION_GIST_URL")
    commit_sha = required_env("GITHUB_SHA")

    if not universe_id.isdecimal() or not place_id.isdecimal():
        fail("ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID must be numeric IDs.")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", commit_sha):
        fail("GITHUB_SHA must be a full 40-character commit SHA.")
    parsed = urlparse(mission_url)
    if parsed.scheme != "https" or parsed.hostname != "gist.githubusercontent.com":
        fail("MISSION_GIST_URL must be an HTTPS raw gist.githubusercontent.com URL.")

    print("Downloading mission source on the GitHub runner...")
    mission = request(mission_url, timeout=60)
    if not mission:
        fail("The mission download was empty.")
    if len(mission) > 100 * 1024 * 1024:
        fail("Mission input exceeds the 100 MiB binary-input limit.")
    print(f"Downloaded {len(mission):,} bytes (source content is not logged).")

    print("Creating Roblox binary input...")
    binary = json_request(
        f"{API}/universes/{universe_id}/luau-execution-session-task-binary-inputs",
        method="POST",
        api_key=api_key,
        payload={"size": len(mission)},
    )
    binary_path = binary.get("path")
    upload_uri = binary.get("uploadUri")
    if not binary_path or not upload_uri:
        fail(f"Binary-input response omitted path or uploadUri: {binary}")

    print("Uploading mission input...")
    request(
        upload_uri,
        method="PUT",
        headers={"content-type": "application/octet-stream"},
        body=mission,
        timeout=120,
    )

    template_path = ROOT / "tools" / "open_cloud_smoke.luau"
    template = template_path.read_text(encoding="utf-8")
    script = template.replace("__BREACH_COMMIT_SHA__", json.dumps(commit_sha))
    if "__BREACH_COMMIT_SHA__" in script:
        fail("Could not substitute the commit SHA in the Luau task script.")

    print("Creating Open Cloud Luau execution task...")
    task = json_request(
        f"{API}/universes/{universe_id}/places/{place_id}/luau-execution-session-tasks",
        method="POST",
        api_key=api_key,
        payload={"script": script, "binaryInput": binary_path, "timeout": "300s"},
    )
    task_path = task.get("path")
    if not task_path:
        fail(f"Task-creation response omitted path: {task}")

    print(f"Task created: {task_path}")
    print("Waiting for the task to finish...")
    deadline = time.monotonic() + 310
    while time.monotonic() < deadline:
        current = json_request(
            f"{API}/{task_path}", method="GET", api_key=api_key
        )
        state = current.get("state", "UNKNOWN")
        print(f"Task state: {state}")
        if state != "PROCESSING":
            break
        time.sleep(3)
    else:
        fail("Timed out waiting for the Open Cloud task (the task may still be running).")

    # Fetch logs after completion so failures include useful diagnostics.
    try:
        logs = json_request(
            f"{API}/{task_path}/logs", method="GET", api_key=api_key
        )
        for entry in logs.get("luauExecutionSessionTaskLogs", []):
            for message in entry.get("messages", []):
                print(f"[Roblox] {message}")
    except SystemExit:
        # The task result remains authoritative; a log-fetch failure should not hide it.
        print("::warning::Could not retrieve task logs.")

    state = current.get("state")
    if state != "COMPLETE":
        error = current.get("error") or {}
        fail(f"Open Cloud task ended in state {state}: "
             f"{error.get('code', '')} {error.get('message', '')}")

    results = (current.get("output") or {}).get("results", [])
    print("Open Cloud smoke test passed.")
    print("Returned values: " + json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
