import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


SCRIPTS = Path(__file__).parents[1]
RUNNER = SCRIPTS / "iphone_wlt_stability.sh"


class IPhoneWLTStabilityContractTests(unittest.TestCase):
    def make_fake_control(self, root: Path) -> Path:
        script = root / "fake-control.py"
        script.write_text(textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import sys
            import time

            action = sys.argv[1]
            calls = Path(os.environ["FAKE_CONTROL_CALLS"])
            with calls.open("a") as handle:
                handle.write(action + "\\n")
            state_path = Path(os.environ["FAKE_VPN_STATE"])
            state = state_path.read_text().strip() if state_path.exists() else "disconnected"
            if action == "start-probe":
                state = "connected"
                state_path.write_text(state)
            elif action == "stop":
                state = "disconnected"
                state_path.write_text(state)
            network = {
                "status": "satisfied",
                "cellular": True,
                "wifi": False,
                "radio_technology": "CTRadioAccessTechnologyLTE",
                "cellular_service_count": 2,
                "data_service_id_hash": "fixture",
            }
            result = {
                "action": action,
                "state": "succeeded",
                "vpn_status": state,
                "network_initial": network,
                "network_final": network,
                "probe_elapsed_ms": 100 if action in {"probe", "start-probe"} else None,
                "vpn_startup_ms": 900 if action == "start-probe" else None,
                "soak_elapsed_ms": None,
                "soak_samples": None,
                "soak_successes": None,
                "soak_failures": None,
                "network_loss_observed": None,
                "network_recovered": None,
            }
            if action == "soak":
                time.sleep(2)
                result.update({
                    "vpn_status": "connected",
                    "soak_elapsed_ms": 5000,
                    "soak_samples": 3,
                    "soak_successes": 2,
                    "soak_failures": 1,
                    "network_loss_observed": True,
                    "network_recovered": True,
                })
            print(json.dumps(result))
            """
        ))
        script.chmod(0o755)
        return script

    def make_fake_shortcut(self, root: Path) -> Path:
        script = root / "fake-shortcut.py"
        script.write_text(textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import os
            from pathlib import Path
            import sys

            with Path(os.environ["FAKE_SHORTCUT_CALLS"]).open("a") as handle:
                handle.write(sys.argv[1] + "\\n")
            """
        ))
        script.chmod(0o755)
        return script

    def base_environment(self, root: Path) -> dict[str, str]:
        control = self.make_fake_control(root)
        shortcut = self.make_fake_shortcut(root)
        environment = os.environ.copy()
        environment.update({
            "DEVICE_ID": "fixture-device",
            "WLT_APP_BUNDLE_ID": "io.example.dev",
            "WLT_STABILITY_CONTROL_SCRIPT": str(control),
            "WLT_STABILITY_SHORTCUT_SCRIPT": str(shortcut),
            "WLT_STABILITY_ARTIFACT_DIR": str(root / "artifacts"),
            "WLT_STABILITY_DURATION_SECONDS": "5",
            "WLT_STABILITY_PROBE_INTERVAL_SECONDS": "2",
            "WLT_STABILITY_LOSS_AFTER_SECONDS": "1",
            "WLT_STABILITY_TRANSPORT_TIMEOUT_SECONDS": "5",
            "FAKE_CONTROL_CALLS": str(root / "control-calls.txt"),
            "FAKE_SHORTCUT_CALLS": str(root / "shortcut-calls.txt"),
            "FAKE_VPN_STATE": str(root / "vpn-state.txt"),
        })
        return environment

    def test_runs_soak_loss_recovery_and_idempotent_stop(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.base_environment(root)
            environment["WLT_STABILITY_ALLOW_SHORT"] = "1"
            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (root / "control-calls.txt").read_text().splitlines(),
                [
                    "stop",
                    "status",
                    "start-probe",
                    "soak",
                    "probe",
                    "stop",
                    "stop",
                    "status",
                ],
            )
            self.assertEqual(
                (root / "shortcut-calls.txt").read_text().splitlines(),
                ["WLT LTE", "wltrescan", "WLT WiFi"],
            )
            payload = json.loads((root / "artifacts" / "result.json").read_text())
            self.assertEqual(payload["classification"], "success")
            self.assertTrue(payload["network_loss_observed"])
            self.assertTrue(payload["network_recovered"])
            self.assertTrue(payload["cleanup_succeeded"])

    def test_rejects_short_acceptance_run_without_explicit_smoke_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.run(
                [str(RUNNER)],
                env=self.base_environment(root),
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("at least 900 seconds", result.stderr)
            self.assertFalse((root / "control-calls.txt").exists())

    def test_failed_start_still_runs_emergency_stop_and_wifi_restore(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.base_environment(root)
            environment["WLT_STABILITY_ALLOW_SHORT"] = "1"
            environment["FAKE_FAIL_START"] = "1"
            control = Path(environment["WLT_STABILITY_CONTROL_SCRIPT"])
            source = control.read_text().replace(
                'if action == "start-probe":\n',
                'if action == "start-probe" and os.environ.get("FAKE_FAIL_START") == "1":\n'
                '    raise SystemExit(1)\n'
                'if action == "start-probe":\n',
            )
            control.write_text(source)

            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(
                (root / "control-calls.txt").read_text().splitlines(),
                ["stop", "status", "start-probe", "stop"],
            )
            self.assertEqual(
                (root / "shortcut-calls.txt").read_text().splitlines(),
                ["WLT LTE", "WLT WiFi"],
            )


if __name__ == "__main__":
    unittest.main()
