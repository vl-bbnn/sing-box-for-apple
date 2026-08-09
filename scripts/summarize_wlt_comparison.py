#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path
from typing import Any


def median(values: list[float | int | None]) -> float | None:
    clean = [float(value) for value in values if value is not None]
    return statistics.median(clean) if clean else None


def ratio(numerator: float | None, denominator: float | None) -> float | None:
    if numerator is None or denominator is None or denominator <= 0:
        return None
    return numerator / denominator


def rounded(value: float | None, digits: int = 3) -> float | None:
    return round(value, digits) if value is not None and math.isfinite(value) else None


def load(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def flatten_http(result: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    flattened: dict[str, list[dict[str, Any]]] = {}
    for repetition in result.get("repetitions", []):
        for route_index, route in enumerate(repetition.get("routes", [])):
            for probe in route.get("http_probes", []):
                key = f"{route_index}:{route.get('route', 'unknown')}:{probe.get('name', 'unknown')}"
                flattened.setdefault(key, []).append(probe)
    return flattened


def flatten_playback(result: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    flattened: dict[str, list[dict[str, Any]]] = {}
    for repetition in result.get("repetitions", []):
        for route_index, route in enumerate(repetition.get("routes", [])):
            for probe in route.get("playback_probes", []):
                key = f"{route_index}:{route.get('route', 'unknown')}:{probe.get('name', 'unknown')}"
                flattened.setdefault(key, []).append(probe)
    return flattened


def expected_http_keys(configuration: dict[str, Any]) -> set[str]:
    expected: set[str] = set()
    for route_index, route in enumerate(configuration.get("route_workloads", [])):
        route_name = route.get("route", "unknown")
        for probe in route.get("http_probes", []):
            expected.add(f"{route_index}:{route_name}:{probe.get('name', 'unknown')}")
    if configuration.get("warm_probe"):
        route_index = len(configuration.get("route_workloads", []))
        probe = configuration["warm_probe"]
        expected.add(f"{route_index}:warm-sentinel:{probe.get('name', 'unknown')}")
    return expected


def jaccard(left: list[str], right: list[str]) -> float | None:
    left_set = set(left)
    right_set = set(right)
    if not left_set and not right_set:
        return None
    union = left_set | right_set
    return len(left_set & right_set) / len(union) if union else None


def paired_similarity(
    left: list[dict[str, Any]], right: list[dict[str, Any]]
) -> float | None:
    values: list[float] = []
    for left_probe, right_probe in zip(left, right):
        token_similarity = jaccard(
            left_probe.get("content_token_hashes", []),
            right_probe.get("content_token_hashes", []),
        )
        if token_similarity is not None:
            values.append(token_similarity)
        elif left_probe.get("body_sha256") and right_probe.get("body_sha256"):
            values.append(float(left_probe["body_sha256"] == right_probe["body_sha256"]))
    return statistics.median(values) if values else None


def probe_success(probes: list[dict[str, Any]]) -> bool | None:
    if not probes:
        return None
    return all(probe.get("success") for probe in probes)


def missing_measurements(
    wifi: list[dict[str, Any]],
    wlt: list[dict[str, Any]],
) -> list[str]:
    phases = {
        "wifi_no_vpn": wifi,
        "lte_wlt": wlt,
    }
    return [phase for phase, probes in phases.items() if not probes]


def summarize_http(
    key: str,
    wifi: list[dict[str, Any]],
    wlt: list[dict[str, Any]],
) -> dict[str, Any]:
    _, route, name = key.split(":", 2)
    wifi_ms = median([probe.get("elapsed_ms") for probe in wifi])
    wlt_ms = median([probe.get("elapsed_ms") for probe in wlt])
    wlt_wifi_factor = ratio(wlt_ms, wifi_ms)
    wifi_wlt_similarity = paired_similarity(wifi, wlt)
    content_floor = 0.65 if route == "eu" else 0.75
    wifi_resources = median([probe.get("resource_success_percent") for probe in wifi])
    wlt_resources = median([probe.get("resource_success_percent") for probe in wlt])

    reasons: list[str] = []
    severity = "pass"
    missing = missing_measurements(wifi, wlt)
    wifi_success = probe_success(wifi)
    wlt_success = probe_success(wlt)
    baseline_success = wifi_success is True
    if missing:
        severity = "fail"
        reasons.append(f"missing measurement: {', '.join(missing)}")
    if wifi_success is False:
        severity = "fail"
        reasons.append("unrestricted Wi-Fi functional baseline failed")
    if baseline_success and wlt_success is False:
        severity = "fail"
        reasons.append("WLT failed a probe that passed on unrestricted Wi-Fi")
    if wifi_wlt_similarity is not None and wifi_wlt_similarity < content_floor:
        severity = "fail"
        reasons.append(
            f"content similarity {wifi_wlt_similarity:.3f} is below adaptive floor {content_floor:.3f}"
        )
    resource_baseline = wifi_resources
    if (
        resource_baseline is not None
        and wlt_resources is not None
        and wlt_resources < resource_baseline - 10
    ):
        severity = "fail"
        reasons.append("WLT resource completeness is over 10 percentage points below baseline")

    return {
        "key": key,
        "route": route,
        "name": name,
        "verdict": severity,
        "reasons": reasons,
        "missing_measurements": missing,
        "success": {
            "wifi_no_vpn": wifi_success,
            "lte_wlt": wlt_success,
        },
        "median_ms": {
            "wifi_no_vpn": rounded(wifi_ms),
            "lte_wlt": rounded(wlt_ms),
        },
        "slowdown": {
            "wlt_vs_wifi": rounded(wlt_wifi_factor),
        },
        "content_similarity": {
            "wifi_vs_lte_wlt": rounded(wifi_wlt_similarity),
            "adaptive_floor": rounded(content_floor),
        },
        "resource_success_percent": {
            "wifi_no_vpn": rounded(wifi_resources),
            "lte_wlt": rounded(wlt_resources),
        },
        "median_bytes": {
            "wifi_no_vpn": rounded(median([probe.get("bytes") for probe in wifi])),
            "lte_wlt": rounded(median([probe.get("bytes") for probe in wlt])),
        },
    }


def summarize_playback(
    key: str,
    wifi: list[dict[str, Any]],
    wlt: list[dict[str, Any]],
) -> dict[str, Any]:
    _, route, name = key.split(":", 2)
    wifi_ms = median([probe.get("elapsed_ms") for probe in wifi])
    wlt_ms = median([probe.get("elapsed_ms") for probe in wlt])
    reasons: list[str] = []
    verdict = "pass"
    missing = missing_measurements(wifi, wlt)
    wifi_success = probe_success(wifi)
    wlt_success = probe_success(wlt)
    if missing:
        verdict = "fail"
        reasons.append(f"missing measurement: {', '.join(missing)}")
    if wifi_success is False:
        verdict = "fail"
        reasons.append("unrestricted Wi-Fi playback baseline failed")
    if wifi_success is True and wlt_success is False:
        verdict = "fail"
        reasons.append("WLT playback failed while unrestricted Wi-Fi passed")
    return {
        "key": key,
        "route": route,
        "name": name,
        "verdict": verdict,
        "reasons": reasons,
        "missing_measurements": missing,
        "success": {
            "wifi_no_vpn": wifi_success,
            "lte_wlt": wlt_success,
        },
        "median_elapsed_ms": {
            "wifi_no_vpn": rounded(wifi_ms),
            "lte_wlt": rounded(wlt_ms),
        },
        "median_advance_seconds": {
            "wifi_no_vpn": rounded(median([probe.get("advance_seconds") for probe in wifi])),
            "lte_wlt": rounded(median([probe.get("advance_seconds") for probe in wlt])),
        },
    }


def markdown(report: dict[str, Any]) -> str:
    lines = [
        "# WLT normalized Wi-Fi/LTE comparison",
        "",
        f"Overall verdict: **{report['verdict']}**.",
        "",
        "Restricted native LTE without VPN is not executed because policy timeouts are not "
        "radio-speed measurements. HTTP content/resources are compared between unrestricted "
        "Wi-Fi and LTE+WLT; WLT/Wi-Fi timing is descriptive.",
        "",
        "| Probe | Route | Wi-Fi ms | LTE+WLT ms | WLT/Wi-Fi | Wi-Fi↔WLT | Resources Wi-Fi/WLT | Verdict |",
        "|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for item in report["http_probes"]:
        timing = item["median_ms"]
        slowdown = item["slowdown"]
        similarity = item["content_similarity"]
        resources = item["resource_success_percent"]
        lines.append(
            f"| {item['name']} | {item['route']} | {timing['wifi_no_vpn'] or '—'} | "
            f"{timing['lte_wlt'] or '—'} | "
            f"{slowdown['wlt_vs_wifi'] or '—'} | "
            f"{similarity['wifi_vs_lte_wlt'] if similarity['wifi_vs_lte_wlt'] is not None else '—'} | "
            f"{resources['wifi_no_vpn'] if resources['wifi_no_vpn'] is not None else '—'}/"
            f"{resources['lte_wlt'] if resources['lte_wlt'] is not None else '—'} | "
            f"{item['verdict']} |"
        )
    issues = [item for item in report["http_probes"] if item["reasons"]]
    if issues:
        lines.extend(["", "## HTTP findings", ""])
        for item in issues:
            lines.append(f"- `{item['name']}` ({item['route']}): {'; '.join(item['reasons'])}.")
    lines.extend([
        "",
        "## Native media gate",
        "",
        "YouTube and Twitch playback are intentionally evaluated in their native iOS apps, "
        "outside the headless verdict. The required gate covers unrestricted Wi-Fi and LTE+WLT.",
    ])
    lines.extend(["", "## Decision rules", ""])
    lines.extend(f"- {rule}" for rule in report["decision_rules"])
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wifi", type=Path, required=True)
    parser.add_argument("--wlt", type=Path, required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path, required=True)
    args = parser.parse_args()

    wifi_result = load(args.wifi)
    wlt_result = load(args.wlt)
    http = {
        "wifi": flatten_http(wifi_result),
        "wlt": flatten_http(wlt_result),
    }
    playback = {
        "wifi": flatten_playback(wifi_result),
        "wlt": flatten_playback(wlt_result),
    }
    all_http = sorted(set(http["wifi"]) | set(http["wlt"]))
    all_playback = sorted(set(playback["wifi"]) | set(playback["wlt"]))
    http_summary = [
        summarize_http(
            key,
            http["wifi"].get(key, []),
            http["wlt"].get(key, []),
        )
        for key in all_http
    ]
    playback_summary = [
        summarize_playback(
            key,
            playback["wifi"].get(key, []),
            playback["wlt"].get(key, []),
        )
        for key in all_playback
    ]
    verdicts = [item["verdict"] for item in http_summary + playback_summary]
    overall = "fail" if "fail" in verdicts else "warn" if "warn" in verdicts else "pass"
    report = {
        "schema": 1,
        "verdict": overall,
        "inputs": {
            "wifi_no_vpn": str(args.wifi),
            "lte_wlt": str(args.wlt),
        },
        "decision_rules": [
            "Restricted native LTE without VPN is not a usable baseline and is not executed.",
            "WLT/Wi-Fi timing is descriptive because it includes the ordinary Wi-Fi/LTE radio difference.",
            "WLT content similarity to Wi-Fi must stay above 0.75; EU routes use 0.65.",
            "WLT resource completeness may not fall more than 10 percentage points below the no-VPN baseline.",
            "A WLT probe fails if the same restricted functional probe passes on Wi-Fi but fails with WLT.",
            "Only unrestricted Wi-Fi without VPN and restricted LTE with WLT are functional acceptance phases.",
        ],
        "source_status": {
            "wifi_no_vpn": wifi_result.get("status"),
            "lte_wlt": wlt_result.get("status"),
        },
        "native_media_gate": {
            "required": True,
            "scope": "YouTube and Twitch native iOS apps on unrestricted Wi-Fi and LTE+WLT",
            "included_in_headless_verdict": False,
        },
        "http_probes": http_summary,
        "playback_probes": playback_summary,
        "wlt_startup_ms": {
            "cold_median": rounded(
                median([rep.get("cold_startup_ms") for rep in wlt_result.get("repetitions", [])])
            ),
            "warm_median": rounded(
                median([rep.get("warm_startup_ms") for rep in wlt_result.get("repetitions", [])])
            ),
        },
    }
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    args.markdown_output.write_text(markdown(report), encoding="utf-8")


if __name__ == "__main__":
    main()
