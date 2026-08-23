import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


SCRIPTS = Path(__file__).parents[1]
RUNNER = SCRIPTS / "iphone_wlt_stability.sh"
SHORTCUT_HELPER = SCRIPTS / "iphone_wlt_shortcut.sh"
DEVICE_HELPER = SCRIPTS / "iphone_whitelist_device.sh"


class IPhoneWLTStabilityContractTests(unittest.TestCase):
    def test_device_install_and_launch_require_wifi_no_vpn_confirmation(self):
        helper = DEVICE_HELPER.read_text()
        self.assertIn("require_wifi_no_vpn_confirmation", helper)
        install = helper.split("install_app()", 1)[1].split("launch_app()", 1)[0]
        launch = helper.split("launch_app()", 1)[1].split("usage()", 1)[0]
        self.assertIn("require_wifi_no_vpn_confirmation", install)
        self.assertIn("require_wifi_no_vpn_confirmation", launch)
        self.assertIn("WLT_DEVICE_WIFI_NO_VPN_CONFIRMED", helper)
        self.assertIn("WLT_IOS_WIFI_TRUST_PROOF", helper)
        self.assertIn("age <= 900", helper)

    def test_device_install_selects_only_connected_paired_iphone(self):
        helper = DEVICE_HELPER.read_text()
        selector = helper.split("device_id()", 1)[1].split("device_status()", 1)[0]
        self.assertIn('connection.get("pairingState") == "paired"', selector)
        self.assertIn('connection.get("tunnelState") == "connected"', selector)
        self.assertIn("connected paired iOS device", selector)

    def test_device_control_copy_timeout_is_configurable_for_lte(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        self.assertIn('WLT_CONTROL_COPY_TIMEOUT_SECONDS:-30', control)
        self.assertEqual(control.count('--timeout "$copy_timeout_seconds"'), 2)

    def test_shortcut_helper_warms_before_delivering_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = root / "xcrun-calls.jsonl"
            fake_xcrun = root / "xcrun.py"
            fake_xcrun.write_text(textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                from pathlib import Path
                import sys

                with Path(os.environ["FAKE_XCRUN_CALLS"]).open("a") as handle:
                    handle.write(json.dumps(sys.argv[1:]) + "\\n")
                if (
                    os.environ.get("FAKE_FAIL_FIRST_WARM") == "1"
                    and "--payload-url" not in sys.argv
                ):
                    marker = Path(os.environ["FAKE_XCRUN_CALLS"]).with_suffix(".failed")
                    if not marker.exists():
                        marker.write_text("1")
                        raise SystemExit(1)
                """
            ))
            fake_xcrun.chmod(0o755)
            environment = os.environ.copy()
            environment.update({
                "DEVICE_ID": "fixture-device",
                "WLT_SHORTCUT_ARTIFACT_DIR": str(root / "artifacts"),
                "WLT_IOS_SHORTCUT_WARMUP_SECONDS": "0",
                "XCRUN": str(fake_xcrun),
                "FAKE_XCRUN_CALLS": str(calls),
                "FAKE_FAIL_FIRST_WARM": "1",
            })

            result = subprocess.run(
                [str(SHORTCUT_HELPER), "WLT WiFi"],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            invocations = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len(invocations), 3)
            self.assertIn("--terminate-existing", invocations[0])
            self.assertNotIn("--payload-url", invocations[0])
            self.assertIn("--terminate-existing", invocations[1])
            self.assertNotIn("--payload-url", invocations[1])
            self.assertIn("--payload-url", invocations[2])
            self.assertNotIn("--terminate-existing", invocations[2])

    def test_failed_start_preserves_sanitized_transport_failure(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        self.assertIn(
            'if candidate_path and result.get("state") == "succeeded":',
            control,
        )
        self.assertIn("refresh-profile", control)
        self.assertIn('"startup_milestones": result.get("startup_milestones")', control)
        self.assertIn("PacketTunnelDiagnostics.startupMilestones()", device_control)
        self.assertIn("CommandClient(.log, logMaxLines: 3_000)", device_control)
        self.assertIn("PacketTunnelDiagnostics.observeStartupLog(entry.message)", device_control)
        self.assertIn("firstTrafficProbeTimeout: TimeInterval = 60", device_control)
        self.assertIn("firstTrafficRequestTimeout: TimeInterval = 20", device_control)
        ordinary_probe = device_control.split("case .probe:", 1)[1].split(
            "case .status:", 1
        )[0]
        start_probe = device_control.split("case .startProbe:", 1)[1].split(
            "case .stop:", 1
        )[0]
        self.assertIn("try await probeTraffic()", ordinary_probe)
        self.assertNotIn("firstTrafficProbeTimeout", ordinary_probe)
        self.assertIn("timeout: Self.firstTrafficProbeTimeout", start_probe)
        self.assertIn("requestTimeout: Self.firstTrafficRequestTimeout", start_probe)
        self.assertNotIn("acceptCurrentSessionTrafficReady", device_control)
        self.assertIn("trafficLogObserver.cancel()", start_probe)
        self.assertIn("requestTimeout: TimeInterval = 10", device_control)
        self.assertIn("probeTraffic(timeout: 12)", device_control)
        self.assertIn("https://cp.cloudflare.com/generate_204", device_control)
        self.assertNotIn("https://www.google.com/generate_204", device_control)
        self.assertIn("|workload)", control)
        self.assertIn("WLT_CONTROL_WORKLOAD_FILE", control)
        self.assertIn("case .workload:", device_control)
        self.assertIn("selectWorkloadRoute(plan.route)", device_control)
        workload = device_control.split("private func runWorkload", 1)[1].split(
            "private func selectWorkloadRoute", 1
        )[0]
        self.assertIn("probeTraffic(timeout: 60, requestTimeout: 20)", workload)
        selector = device_control.split("private func selectWorkloadRoute", 1)[1].split(
            "private func loadCurrentStatus", 1
        )[0]
        self.assertIn('guard route == "eu"', selector)
        self.assertIn('(\"whitelist-exit\", \"eu\")', selector)
        self.assertIn('(\"eu_or_wlt-eu\", \"vless-wlt-eu\")', selector)
        self.assertNotIn('(\"eu\", \"vless-wlt-eu\")', selector)
        self.assertNotIn("closeConnections()", selector)
        self.assertIn("workloadProbes", device_control)
        self.assertIn("retryable_start_failure", control := RUNNER.read_text())
        self.assertIn('"carrier_start_failed_connect" in milestones', control)
        self.assertIn("for start_attempt in 1 2", control)
        self.assertIn("classify_injected_recovery", control)
        self.assertIn("probe_transition_after_host_injection", control)
        self.assertIn("final_probe_status=0", control)
        shortcut = SHORTCUT_HELPER.read_text()
        self.assertIn("for resume_attempt in 1 2", shortcut)
        self.assertEqual(shortcut.count('shortcuts://run-shortcut?name='), 1)

        ui_test = (SCRIPTS.parent / "SFIUITests" / "DeviceScenarioTests.swift").read_text()
        content = json.loads(
            (SCRIPTS.parent / "SFIUITests" / "wlt-eu-content.json").read_text()
        )
        self.assertIn('case "assert_visual_change":', ui_test)
        self.assertIn('case "assert_texts_absent":', ui_test)
        actions = {step.get("name") for step in content["steps"]}
        self.assertTrue({
            "youtube-playback",
            "tiktok-playback",
            "instagram-reels-playback",
        }.issubset(actions))
        started_index = next(
            index
            for index, step in enumerate(content["steps"])
            if step.get("action") == "assert_text" and step.get("text") == "Started"
        )
        ecosystem_indices = [
            index
            for index, step in enumerate(content["steps"])
            if "google.com" in step.get("text", "")
            or step.get("app") == "youtube"
        ]
        self.assertTrue(ecosystem_indices)
        self.assertTrue(all(index > started_index for index in ecosystem_indices))

    def test_automatic_wlt_refresh_waits_for_connected_vpn(self):
        update_task = (
            SCRIPTS.parent
            / "ApplicationLibrary"
            / "Service"
            / "ProfileUpdateTask.swift"
        ).read_text()
        self.assertIn("shouldDeferAutomaticUpdate(profile)", update_task)
        self.assertIn("extensionProfile.status != .connected", update_task)

    def test_deprecated_note_probe_does_not_surface_command_socket_shutdown(self):
        global_checks = (
            SCRIPTS.parent
            / "ApplicationLibrary"
            / "Views"
            / "Abstract"
            / "GlobalChecksModifier.swift"
        ).read_text()
        deprecated_check = global_checks.split(
            "private nonisolated func checkDeprecatedNotes() async", 1
        )[1].split("private func showNextDeprecatedNote", 1)[0]
        self.assertIn(
            "try? LibboxNewStandaloneCommandClient()!.getDeprecatedNotes()",
            deprecated_check,
        )
        self.assertNotIn('AlertState(action: "check deprecated notes"', deprecated_check)

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
            if action == "probe" and os.environ.get("FAKE_FAIL_FIRST_PROBE") == "1":
                marker = calls.with_suffix(".first-probe-failed")
                if not marker.exists():
                    marker.write_text("1")
                    raise SystemExit(1)
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
                    "soak_probe_samples": [
                        {"offset_ms": 0, "success": True},
                        {"offset_ms": 1_000, "success": False},
                        {"offset_ms": 2_000, "success": True},
                    ],
                    "network_loss_observed": False,
                    "network_recovered": False,
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
            soak = json.loads((root / "artifacts" / "soak.json").read_text())
            self.assertEqual(
                soak["network_loss_source"],
                "probe_transition_after_host_injection",
            )

    def test_no_loss_soak_uses_bounded_host_probes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.base_environment(root)
            environment.update({
                "WLT_STABILITY_ALLOW_SHORT": "1",
                "WLT_STABILITY_DURATION_SECONDS": "5",
                "WLT_STABILITY_PROBE_INTERVAL_SECONDS": "2",
                "WLT_STABILITY_INJECT_LOSS": "0",
                "WLT_STABILITY_PREPARE_LTE": "0",
                "WLT_STABILITY_RESTORE_WIFI": "0",
                "FAKE_FAIL_FIRST_PROBE": "1",
            })

            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads((root / "artifacts" / "result.json").read_text())
            self.assertEqual(payload["classification"], "success")
            self.assertGreaterEqual(payload["soak_elapsed_ms"], 5_000)
            self.assertGreaterEqual(payload["soak_samples"], 3)
            self.assertEqual(payload["soak_failures"], 0)
            calls = (root / "control-calls.txt").read_text().splitlines()
            self.assertGreaterEqual(calls.count("probe"), 5)
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
