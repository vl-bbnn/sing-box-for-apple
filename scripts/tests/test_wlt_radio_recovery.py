import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).parents[1] / "wlt_radio_recovery.py"
spec = importlib.util.spec_from_file_location("wlt_radio_recovery", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(failed=(12,), injection=(181000, 184000), uncertainty=2000):
    samples = [{"offset_ms": i * 15000, "elapsed_ms": 5000 if i in failed else 500,
                "success": i not in failed} for i in range(61)]
    raw = {"state": "succeeded", "vpn_status": "connected", "soak_elapsed_ms": 900500,
           "soak_probe_samples": samples, "soak_samples": 61,
           "soak_successes": 61-len(failed), "soak_failures": len(failed),
           "network_loss_observed": True, "network_recovered": True}
    timing = {"injection_exit_code": 0}
    for key, ms in zip(("soak_dispatch", "injection_start", "injection_end", "soak_receipt"),
                       (1000000, 1000000 + injection[0], 1000000 + injection[1], 1900500 + uncertainty)):
        timing[key] = {"monotonic_ns": ms * 1000000, "unix_ns": (ms + 1700000000000) * 1000000}
    return raw, timing


class RadioRecoveryTests(unittest.TestCase):
    def classify(self, raw, timing):
        original = copy.deepcopy(raw)
        value = module.classify(raw, timing, 900000, 15000)
        self.assertEqual(original, raw)
        self.assertEqual(raw["soak_probe_samples"], value["soak_probe_samples"])
        self.assertEqual(value["raw_soak_failures"], value["planned_radio_failures"] + value["unplanned_soak_failures"])
        if value["radio_recovery"]["classification"] == "success":
            self.assertEqual(value["unplanned_soak_failures"], 0)
        return value

    def failed(self, raw, timing, error):
        value = self.classify(raw, timing)
        self.assertEqual(value["radio_recovery"]["classification"], "failed", value)
        self.assertIn(error, value["radio_recovery"]["failures"])
        return value

    def test_one_bounded_incident_assigns_all_failures_and_preserves_raw(self):
        raw, timing = fixture(failed=(12, 13))
        value = self.classify(raw, timing)
        self.assertTrue(value["radio_recovery"]["qualification"])
        self.assertEqual(value["planned_radio_failures"], 2)
        self.assertEqual(value["radio_recovery"]["origin_uncertainty_ms"], 2000)
        self.assertEqual(value["radio_recovery"]["recovery_completion_upper_ms"], 31500)

    def test_probe_duration_budget_is_inclusive_and_not_host_copy_time(self):
        raw, timing = fixture()
        raw["soak_probe_samples"][12]["elapsed_ms"] = 15000
        self.assertTrue(self.classify(raw, timing)["radio_recovery"]["qualification"])
        for duration in (15001, 30000):
            raw["soak_probe_samples"][12]["elapsed_ms"] = duration
            self.failed(raw, timing, "probe_duration_exceeds_budget")

    def test_delayed_injection_uses_measured_time_not_requested_offset(self):
        raw, timing = fixture(failed=(16,), injection=(241000, 244000))
        self.assertTrue(self.classify(raw, timing)["radio_recovery"]["qualification"])
        raw, timing = fixture(failed=(12,), injection=(241000, 244000))
        self.failed(raw, timing, "failed_probe_not_proved_to_overlap_injection")

    def test_pre_injection_failure_cannot_be_hidden_by_later_planned_failure(self):
        self.failed(*fixture(failed=(8, 12)), "multiple_failure_incidents")

    def test_sole_pre_injection_failure_is_failed_not_infrastructure(self):
        self.failed(*fixture(failed=(8,)), "failed_probe_not_proved_to_overlap_injection")

    def test_unrelated_failure_after_recovery_is_rejected(self):
        value = self.failed(*fixture(failed=(12, 30)), "multiple_failure_incidents")
        self.assertEqual(value["unplanned_soak_failures"], 2)

    def test_late_first_failure_is_rejected(self):
        self.failed(*fixture(failed=(30,)), "pre_injection_success_not_proved")

    def test_recovery_bound_uses_success_completion_not_start(self):
        raw, timing = fixture(failed=tuple(range(12, 18)))
        # Probe 18 starts 89 s after injection but finishes after the 90 s bound.
        self.failed(raw, timing, "recovery_completion_outside_bound")

    def test_exact_recovery_completion_bound_is_inclusive(self):
        raw, timing = fixture(failed=tuple(range(12, 18)), injection=(182500, 184000))
        value = self.classify(raw, timing)
        self.assertTrue(value["radio_recovery"]["qualification"])
        self.assertEqual(value["radio_recovery"]["recovery_completion_upper_ms"], 90000)

    def test_malformed_or_inconsistent_counters_fail(self):
        for key, wrong in (("soak_samples", 60), ("soak_successes", 61), ("soak_failures", 0),
                           ("soak_failures", True), ("raw_soak_failures", 0)):
            with self.subTest(key=key, wrong=wrong):
                raw, timing = fixture()
                raw[key] = wrong
                value = self.classify(raw, timing)
                self.assertFalse(value["radio_recovery"]["qualification"])
                self.assertEqual(value["radio_recovery"]["classification"], "failed")

    def test_order_is_validated_instead_of_sorted(self):
        raw, timing = fixture()
        raw["soak_probe_samples"][3:5] = raw["soak_probe_samples"][3:5][::-1]
        self.failed(raw, timing, "gappy_probe_sequence")

    def test_duplicate_offset_is_rejected(self):
        raw, timing = fixture()
        raw["soak_probe_samples"][3]["offset_ms"] = 30000
        self.failed(raw, timing, "unordered_or_overlapping_probe_sequence")

    def test_missing_probe_is_rejected_despite_adjusted_counters(self):
        raw, timing = fixture()
        del raw["soak_probe_samples"][30]
        raw["soak_samples"] -= 1
        raw["soak_successes"] -= 1
        self.failed(raw, timing, "gappy_probe_sequence")

    def test_missing_duration_or_nonboolean_sample_fails(self):
        for key in ("elapsed_ms", "success"):
            raw, timing = fixture()
            del raw["soak_probe_samples"][5][key]
            value = self.classify(raw, timing)
            self.assertFalse(value["radio_recovery"]["qualification"])

    def test_injection_overlap_must_hold_across_measured_origin_uncertainty(self):
        raw, timing = fixture(uncertainty=6000)
        self.failed(raw, timing, "failed_probe_not_proved_to_overlap_injection")

    def test_large_origin_uncertainty_does_not_become_a_scheduler_allowance(self):
        self.failed(*fixture(uncertainty=16000), "soak_origin_timing_not_bounded")

    def test_host_clock_discontinuity_and_failed_shortcut_rejected(self):
        raw, timing = fixture()
        timing["soak_receipt"]["unix_ns"] += 1000000000
        self.failed(raw, timing, "host_clock_discontinuity")
        raw, timing = fixture()
        timing["injection_exit_code"] = 3
        self.failed(raw, timing, "invalid_host_injection_timing")

    def test_missing_or_reordered_measured_timing_never_qualifies(self):
        for change in ("missing", "reverse", "equal", "negative_origin", "boolean_exit"):
            with self.subTest(change=change):
                raw, timing = fixture()
                if change == "missing":
                    del timing["injection_start"]
                elif change == "reverse":
                    timing["injection_start"], timing["injection_end"] = timing["injection_end"], timing["injection_start"]
                elif change == "equal":
                    timing["injection_end"] = timing["injection_start"]
                elif change == "negative_origin":
                    raw, timing = fixture(uncertainty=-1)
                else:
                    timing["injection_exit_code"] = False
                self.assertFalse(self.classify(raw, timing)["radio_recovery"]["qualification"])

    def test_observed_loss_without_failed_probes_is_preserved_as_diagnostic(self):
        raw, timing = fixture(failed=())
        value = self.classify(raw, timing)
        self.assertEqual(value["radio_recovery"]["classification"], "infrastructure")
        self.assertTrue(value["radio_recovery"]["source_network_loss_observed"])
        self.assertTrue(value["radio_recovery"]["source_network_recovered"])
        self.assertFalse(value["network_recovered"])
        self.assertFalse(value["radio_recovery"]["qualification"])

    def test_runner_summary_never_accepts_unplanned_or_missing_radio_accounting(self):
        runner = (SCRIPT.parent / "iphone_wlt_stability.sh").read_text()
        reducer = runner.split('restore_wifi_expected = sys.argv[8] == "1"', 1)[1].split("\nPY", 1)[0]
        reducer = 'import json\nfrom pathlib import Path\nimport sys\nroot = Path(sys.argv[1])\nduration=900\ninterval=15\ninject_loss=True\nwifi_handover_expected=False\nlte_return_expected=False\nhandover_recovery_timeout_ms=90000\nrestore_wifi_expected=False\n' + reducer
        for mode in ("success", "unplanned", "missing", "counter_mismatch", "diagnostic"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                raw, timing = fixture(failed=() if mode == "diagnostic" else (12,))
                soak = self.classify(raw, timing)
                if mode == "unplanned":
                    soak["planned_radio_failures"] = 0
                    soak["unplanned_soak_failures"] = 1
                elif mode == "missing":
                    del soak["unplanned_soak_failures"]
                elif mode == "counter_mismatch":
                    soak["planned_radio_failures"] = 3
                (root / "soak.json").write_text(json.dumps(soak))
                for name in ("start-probe", "final-probe", "final-stop", "idempotent-stop", "final-status"):
                    value = {"state": "succeeded", "vpn_status": "connected" if "probe" in name else "disconnected",
                             "network_final": {"cellular": True, "wifi": False}}
                    (root / (name + ".json")).write_text(json.dumps(value))
                process = subprocess.run([sys.executable, "-c", reducer, str(root), "900", "15", "1", "", "", "90", "0", "0"],
                                         capture_output=True, text=True)
                result = json.loads((root / "result.json").read_text())
                expected = "success" if mode == "success" else "infrastructure" if mode == "diagnostic" else "failed"
                self.assertEqual(result["classification"], expected, process.stderr)
                self.assertEqual(process.returncode, {"success": 0, "infrastructure": 2, "failed": 1}[expected])

    def test_timestamps_share_clock_origin_across_system_python_processes(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "timing.json"
            for event in ("before", "after"):
                result = subprocess.run(["/usr/bin/python3", str(SCRIPT), "stamp", str(target), event], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                if event == "before":
                    time.sleep(0.1)
            value = json.loads(target.read_text())
            elapsed = value["after"]["monotonic_ns"] - value["before"]["monotonic_ns"]
            self.assertGreaterEqual(elapsed, 100000000)
            wall = value["after"]["unix_ns"] - value["before"]["unix_ns"]
            self.assertLess(abs(elapsed - wall), 10000000)

    def test_cli_preserves_pristine_reply_bytes(self):
        raw, timing = fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, timing_path, output = (root / name for name in ("raw.json", "timing.json", "classified.json"))
            source.write_text(json.dumps(raw, indent=3))
            pristine = source.read_bytes()
            timing_path.write_text(json.dumps(timing))
            result = subprocess.run([sys.executable, str(SCRIPT), "classify", str(source), str(timing_path), str(output),
                                     "--duration-ms", "900000", "--interval-ms", "15000"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(source.read_bytes(), pristine)
            self.assertTrue(json.loads(output.read_text())["radio_recovery"]["qualification"])


if __name__ == "__main__":
    unittest.main()
