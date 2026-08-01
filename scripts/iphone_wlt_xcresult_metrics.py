#!/usr/bin/env python3
"""Merge WLT measurement attachments exported from an xcresult into a report."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


KEY_VALUE = re.compile(r"([a-z_]+)=([^\s]+)")
METRIC_PREFIXES = {
    "wlt-metric-dns-": "dns_probe",
    "wlt-metric-download-": "https_probe",
}


def parse_bool(value: str, default: bool = False) -> bool:
    if not value:
        return default
    return value.lower() == "true"


def parse_int(value: str, default: int = 0) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def attachment_metric(
    attachment: dict[str, Any], attachments_dir: Path
) -> dict[str, Any] | None:
    name = str(attachment.get("suggestedHumanReadableName", ""))
    metric_kind = ""
    metric_name = name
    for prefix, kind in METRIC_PREFIXES.items():
        if name.startswith(prefix):
            metric_kind = kind
            metric_name = name.removeprefix(prefix)
            break
    if not metric_kind:
        return None

    exported_name = Path(str(attachment.get("exportedFileName", ""))).name
    if not exported_name:
        return None
    exported_path = attachments_dir / exported_name
    if not exported_path.is_file():
        return None
    values = dict(KEY_VALUE.findall(
        exported_path.read_text(encoding="utf-8", errors="replace")
    ))
    duration_ms = parse_int(values.get("elapsed_ms", ""))
    finished_at_ms = parse_int(values.get("finished_at_unix_ms", ""))
    if finished_at_ms <= 0:
        finished_at_ms = int(float(attachment.get("timestamp", 0)) * 1000)
    started_at_ms = parse_int(values.get("started_at_unix_ms", ""))
    if started_at_ms <= 0 and finished_at_ms > 0:
        started_at_ms = max(0, finished_at_ms - duration_ms)

    status = parse_int(values.get("status", ""), -1)
    success = parse_bool(values.get("success", ""), 200 <= status < 300)
    metric: dict[str, Any] = {
        "name": metric_name,
        "kind": metric_kind,
        "duration_ms": duration_ms,
        "success": success,
        "expected_success": True,
        "started_at_unix_ms": started_at_ms,
        "finished_at_unix_ms": finished_at_ms,
    }
    if metric_kind == "dns_probe":
        metric.update({
            "host": values.get("host", ""),
            "queries": 1,
            "successes": 1 if success else 0,
            "status": status,
        })
    else:
        metric.update({
            "host": values.get("host", ""),
            "status": status,
            "bytes": parse_int(values.get("bytes", "")),
            "bytes_per_second": parse_int(values.get("bytes_per_second", "")),
        })
    return metric


def load_metrics(attachments_dir: Path) -> list[dict[str, Any]]:
    manifest_path = attachments_dir / "manifest.json"
    if not manifest_path.is_file():
        return []
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    metrics = []
    for test in manifest:
        for attachment in test.get("attachments", []):
            metric = attachment_metric(attachment, attachments_dir)
            if metric is not None:
                metrics.append(metric)
    return sorted(metrics, key=lambda item: (
        int(item.get("finished_at_unix_ms", 0)), str(item.get("name", ""))
    ))


def merge_report(report_path: Path, attachments_dir: Path) -> int:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    metrics = load_metrics(attachments_dir)
    report["metrics"] = metrics
    report["metric_count"] = len(metrics)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return len(metrics)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--attachments", type=Path, required=True)
    args = parser.parse_args()
    count = merge_report(args.report, args.attachments)
    print(json.dumps({"metrics": count}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
