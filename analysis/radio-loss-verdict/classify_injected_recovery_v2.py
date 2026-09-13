#!/usr/bin/env python3
"""Fail-closed classifier for a host-injected radio-loss soak.

The input soak JSON is never rewritten.  The verdict is emitted separately and
is keyed to the measured host injection interval rather than the requested
loss offset.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path


def classify(value: dict, start_ms: int, end_ms: int, interval_ms: int, recovery_ms: int) -> dict:
    samples = list(value.get("soak_probe_samples") or [])
    ordered = sorted(enumerate(samples), key=lambda item: item[1].get("offset_ms", -1))
    failures = [
        (i, s) for i, s in ordered
        if s.get("success") is False
    ]
    pre = [s for _, s in ordered if s.get("success") is True and s.get("offset_ms", -1) < start_ms]
    # Give the probe scheduler half an interval of timestamp uncertainty, but
    # do not accept a failure that predates the actual host command window.
    first = next(((i, s) for i, s in failures if s.get("offset_ms", -1) >= start_ms - interval_ms // 2), None)
    verdict = {"schema": 2, "injection_start_ms": start_ms, "injection_end_ms": end_ms,
               "recovery_timeout_ms": recovery_ms, "sample_count": len(samples),
               "raw_failure_count": len(failures), "network_loss_observed": False,
               "network_recovered": False, "failure": None, "classification": "failed"}
    if not pre:
        verdict["failure"] = "no_pre_injection_success"
        return verdict
    if first is None:
        verdict["failure"] = "connection_loss_not_observed"
        verdict["classification"] = "infrastructure"
        return verdict
    first_index, first_sample = first
    first_offset = first_sample.get("offset_ms", -1)
    if first_offset > end_ms + recovery_ms:
        verdict["failure"] = "loss_observed_outside_recovery_window"
        return verdict
    verdict["network_loss_observed"] = True
    recovered = next(((i, s) for i, s in ordered if i > first_index and s.get("success") is True), None)
    if recovered is None or recovered[1].get("offset_ms", 0) > first_offset + recovery_ms:
        verdict["failure"] = "connection_recovery_not_observed_within_bound"
        return verdict
    verdict["network_recovered"] = True
    verdict["recovery_offset_ms"] = recovered[1].get("offset_ms")
    # A later failure is never a planned part of a single injected event.
    late = [s for i, s in failures if i > recovered[0]]
    if late:
        verdict["failure"] = "unexpected_post_recovery_failure"
        return verdict
    verdict["classification"] = "success"
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("soak_json", type=Path)
    ap.add_argument("--injection-start-ms", type=int, required=True)
    ap.add_argument("--injection-end-ms", type=int, required=True)
    ap.add_argument("--interval-ms", type=int, required=True)
    ap.add_argument("--recovery-timeout-ms", type=int, required=True)
    args = ap.parse_args()
    value = json.loads(args.soak_json.read_text())
    verdict = classify(value, args.injection_start_ms, args.injection_end_ms,
                       args.interval_ms, args.recovery_timeout_ms)
    print(json.dumps(verdict, sort_keys=True, separators=(",", ":")))
    return 0 if verdict["classification"] == "success" else (2 if verdict["classification"] == "infrastructure" else 1)

if __name__ == "__main__":
    raise SystemExit(main())
