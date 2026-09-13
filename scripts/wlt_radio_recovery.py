#!/usr/bin/env python3
"""Conservative host-clock qualification of one app-side radio-loss soak.

The app does not expose runSoak's start timestamp. Its origin is bounded by
host dispatch <= origin <= host receipt - reported soak duration. Never use
received_at_unix_ms as that origin: capture/handler work precedes runSoak.
Samples use the app's wall-clock elapsed values; host wall-vs-monotonic drift
is checked, but an undetectable app-only clock step remains a limitation.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import sys
import time
from pathlib import Path


def integer(value, name, minimum=0):
    if type(value) is not int or value < minimum:
        raise ValueError("invalid_" + name)
    return value


def classify(raw, timing, duration_ms, interval_ms, recovery_ms=90000):
    result = copy.deepcopy(raw) if isinstance(raw, dict) else {}
    errors = []
    samples = result.get("soak_probe_samples")
    # Preserve every raw counter and sample, including malformed values.
    result["radio_recovery"] = verdict = {
        "schema": 1, "classification": "failed", "qualification": False,
        "timing_model": "host_dispatch_receipt_origin_bracket",
        "clock_limitation": "app_wall_clock_steps_are_not_independently_observed",
        "source_network_loss_observed": result.get("network_loss_observed"),
        "source_network_recovered": result.get("network_recovered"),
        "reported_counters": {key: result.get(key) for key in (
            "soak_samples", "soak_successes", "soak_failures", "raw_soak_failures", "unplanned_soak_failures")},
        "failures": errors,
    }
    result["network_loss_observed"] = False
    result["network_recovered"] = False
    raw_failures = sum(s.get("success") is False for s in samples if isinstance(s, dict)) if isinstance(samples, list) else 0
    result["raw_soak_failures"] = raw_failures
    result["planned_radio_failures"] = 0
    result["unplanned_soak_failures"] = raw_failures
    verdict["raw_failure_count"] = raw_failures
    try:
        integer(duration_ms, "duration", 1)
        integer(interval_ms, "interval", 1)
        integer(recovery_ms, "recovery", 1)
        if recovery_ms > 90000:
            raise ValueError("recovery_bound_exceeds_90_seconds")
        if not isinstance(raw, dict) or not isinstance(samples, list) or len(samples) < 2:
            raise ValueError("missing_probe_sequence")
        if raw.get("state") != "succeeded" or raw.get("vpn_status") != "connected":
            raise ValueError("soak_did_not_finish_connected_successfully")
        elapsed = integer(raw.get("soak_elapsed_ms"), "soak_elapsed", 1)
        if elapsed < duration_ms:
            raise ValueError("soak_too_short")
        previous_end = None
        failed_indexes = []
        for index, sample in enumerate(samples):
            if not isinstance(sample, dict) or type(sample.get("success")) is not bool:
                raise ValueError("invalid_sample_shape")
            offset = integer(sample.get("offset_ms"), "sample_offset")
            probe_elapsed = integer(sample.get("elapsed_ms"), "sample_elapsed")
            # A radio outage can make the 12s HTTPS probe consume its timeout
            # plus CoreDevice/result-copy overhead.  Keep a hard upper bound,
            # while allowing the bounded loss window to be classified as one
            # planned incident instead of an unplanned probe failure.
            if probe_elapsed > 30000:
                raise ValueError("probe_duration_exceeds_budget")
            if index == 0 and offset > 1000:
                raise ValueError("initial_probe_missing")
            if previous_end is not None:
                prev = samples[index - 1]
                if offset <= prev["offset_ms"] or offset < previous_end:
                    raise ValueError("unordered_or_overlapping_probe_sequence")
                if offset - prev["offset_ms"] > max(interval_ms, prev["elapsed_ms"]) + 1000:
                    raise ValueError("gappy_probe_sequence")
            previous_end = offset + probe_elapsed
            if previous_end > elapsed:
                raise ValueError("sample_outside_soak")
            if not sample["success"]:
                failed_indexes.append(index)
        if samples[-1]["offset_ms"] < duration_ms or elapsed - previous_end > 1000:
            raise ValueError("final_probe_missing")
        for key, expected in (("soak_samples", len(samples)), ("soak_failures", len(failed_indexes)),
                              ("soak_successes", len(samples) - len(failed_indexes))):
            if integer(raw.get(key), key) != expected:
                raise ValueError("inconsistent_" + key)
        if raw.get("raw_soak_failures") is not None and integer(raw["raw_soak_failures"], "raw_soak_failures") != len(failed_indexes):
            raise ValueError("inconsistent_raw_soak_failures")
        events = [timing[k] for k in ("soak_dispatch", "injection_start", "injection_end", "soak_receipt")]
        mono = [integer(e.get("monotonic_ns"), "host_monotonic", 1) / 1e6 for e in events]
        wall = [integer(e.get("unix_ns"), "host_wall", 1) / 1e6 for e in events]
        if any(a >= b for a, b in zip(mono, mono[1:])) or type(timing.get("injection_exit_code")) is not int or timing["injection_exit_code"] != 0:
            raise ValueError("invalid_host_injection_timing")
        if max(abs((wall[i] - wall[0]) - (mono[i] - mono[0])) for i in range(4)) > 100:
            raise ValueError("host_clock_discontinuity")
        dispatch, injection_start, injection_end, receipt = mono
        origin_low, origin_high = dispatch, receipt - elapsed
        uncertainty = origin_high - origin_low
        verdict.update({"host_timing": timing, "origin_uncertainty_ms": uncertainty,
                        "injection_offset_min_ms": injection_start - origin_high,
                        "injection_offset_max_ms": injection_end - origin_low,
                        "recovery_timeout_ms": recovery_ms})
        if not 0 <= uncertainty <= min(interval_ms, 15000):
            raise ValueError("soak_origin_timing_not_bounded")
        if not failed_indexes:
            verdict["classification"] = "infrastructure"
            errors.append("radio_loss_without_failed_probe_is_diagnostic_only" if raw.get("network_loss_observed") is True else "connection_loss_injection_ineffective")
            return result
        first, last = failed_indexes[0], failed_indexes[-1]
        if failed_indexes != list(range(first, last + 1)):
            raise ValueError("multiple_failure_incidents")
        if first == 0 or samples[first - 1]["offset_ms"] + samples[first - 1]["elapsed_ms"] + origin_high >= injection_start:
            raise ValueError("pre_injection_success_not_proved")
        # Require overlap for every possible app origin in the measured bracket;
        # a failure merely near the requested offset is insufficient evidence.
        first_sample = samples[first]
        if (origin_high + first_sample["offset_ms"] > injection_end
                or origin_low + first_sample["offset_ms"] + first_sample["elapsed_ms"] < injection_start):
            raise ValueError("failed_probe_not_proved_to_overlap_injection")
        if last + 1 >= len(samples):
            raise ValueError("post_loss_success_missing")
        recovered = samples[last + 1]
        if origin_low + recovered["offset_ms"] < injection_end:
            raise ValueError("success_not_proved_after_injection")
        completion_upper = origin_high + recovered["offset_ms"] + recovered["elapsed_ms"]
        if completion_upper - injection_start > recovery_ms:
            raise ValueError("recovery_completion_outside_bound")
        result["planned_radio_failures"] = len(failed_indexes)
        result["unplanned_soak_failures"] = 0
        result["network_loss_observed"] = True
        result["network_recovered"] = True
        result["network_loss_source"] = "bounded_probe_incident_overlapping_measured_host_injection"
        result["network_recovery_source"] = "bounded_success_completion_after_measured_host_injection"
        verdict.update({"classification": "success", "qualification": True,
                        "first_failed_sample_index": first + 1, "last_failed_sample_index": last + 1,
                        "recovered_sample_index": last + 2,
                        "recovery_completion_upper_ms": completion_upper - injection_start})
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        errors.append(str(error))
    return result


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    stamp = commands.add_parser("stamp")
    stamp.add_argument("path", type=Path)
    stamp.add_argument("event")
    stamp.add_argument("--exit-code", type=int)
    check = commands.add_parser("classify")
    check.add_argument("raw", type=Path)
    check.add_argument("timing", type=Path)
    check.add_argument("output", type=Path)
    check.add_argument("--duration-ms", required=True, type=int)
    check.add_argument("--interval-ms", required=True, type=int)
    check.add_argument("--recovery-ms", default=90000, type=int)
    args = parser.parse_args()
    if args.command == "stamp":
        # macOS system Python 3.9 gives monotonic_ns a process-local origin.
        # clock_gettime(CLOCK_MONOTONIC) is shared by separate stamp processes.
        record = {"monotonic_ns": time.clock_gettime_ns(time.CLOCK_MONOTONIC), "unix_ns": time.time_ns()}
        value = json.loads(args.path.read_text()) if args.path.exists() else {}
        if args.event in value:
            raise SystemExit("duplicate timing event")
        value[args.event] = record
        if args.exit_code is not None:
            value["injection_exit_code"] = args.exit_code
        args.path.write_text(json.dumps(value, indent=2) + "\n")
        return
    data = args.raw.read_bytes()
    result = classify(json.loads(data), json.loads(args.timing.read_text()),
                      args.duration_ms, args.interval_ms, args.recovery_ms)
    result["radio_recovery"]["raw_sha256"] = hashlib.sha256(data).hexdigest()
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    # Classification is data. The runner must still collect final probe/stop
    # receipts and have its summary reject a failed or uncertain verdict.


if __name__ == "__main__":
    main()
