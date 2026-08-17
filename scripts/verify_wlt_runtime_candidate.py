#!/usr/bin/env python3
"""Verify that the newest WLT service-log session uses one candidate."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any


RUNTIME_KEYS = {
    "max_active",
    "max_open",
    "dns_open_reserve",
    "max_pending",
    "queue_timeout",
    "idle_timeout",
    "peer_write_buffer",
    "kcp_window",
    "kcp_buffer",
}
KEY_VALUE = re.compile(r"\b([a-z][a-z0-9_]*)=([^\s]+)")
DURATION = re.compile(r"^([0-9]+(?:\.[0-9]+)?)(ms|s|m)$")


def duration_seconds(value: object) -> float:
    match = DURATION.fullmatch(str(value))
    if not match:
        raise ValueError(f"invalid duration: {value}")
    return float(match.group(1)) * {"ms": 0.001, "s": 1.0, "m": 60.0}[
        match.group(2)
    ]


def equal_parameter(expected: object, observed: object, key: str) -> bool:
    if key in {"queue_timeout", "idle_timeout"}:
        try:
            return abs(duration_seconds(expected) - duration_seconds(observed)) < 0.001
        except ValueError:
            return False
    return str(expected).lower() == str(observed).lower()


def load_candidate(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, dict) and "parameters" in payload:
        payload = payload["parameters"]
    if not isinstance(payload, dict) or set(payload) != RUNTIME_KEYS:
        raise ValueError("candidate must contain the complete WLT runtime schema")
    return payload


def runtime_sessions(path: Path) -> list[dict[str, str]]:
    sessions: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        lowered = line.lower()
        values = dict(KEY_VALUE.findall(line))
        if (
            "wlt carrier start phase=runtime_options" in lowered
            or "wlt carrier started" in lowered
        ):
            current.update({key: values[key] for key in RUNTIME_KEYS if key in values})
        if "wlt service stopped" in lowered and current:
            sessions.append(dict(current))
            current.clear()
    if current:
        sessions.append(current)
    return sessions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("service_log", type=Path)
    args = parser.parse_args()

    expected = load_candidate(args.candidate)
    sessions = runtime_sessions(args.service_log)
    if not sessions:
        print(json.dumps({"status": "runtime_parameters_missing"}, sort_keys=True))
        return 1
    observed = sessions[-1]
    mismatches = sorted(
        key
        for key, value in expected.items()
        if not equal_parameter(value, observed.get(key), key)
    )
    result = {
        "mismatches": mismatches,
        "parameters": {key: observed.get(key) for key in sorted(RUNTIME_KEYS)},
        "status": "matched" if not mismatches else "runtime_mismatch",
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not mismatches else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"verify-wlt-runtime-candidate: {error}", file=sys.stderr)
        raise SystemExit(2)
