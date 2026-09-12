import json
import hashlib
import os
from pathlib import Path
import subprocess
import sqlite3
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

    def test_device_install_selects_only_connected_paired_physical_iphone(self):
        helper = DEVICE_HELPER.read_text()
        selector = helper.split("device_id()", 1)[1].split("device_status()", 1)[0]
        self.assertIn('connection.get("pairingState") == "paired"', selector)
        self.assertIn('connection.get("tunnelState") == "connected"', selector)
        self.assertIn('connection.get("transportType") != "sameMachine"', selector)
        self.assertIn("connected paired physical iOS device", selector)

    def test_device_control_copy_timeout_is_configurable_for_lte(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        self.assertIn('WLT_CONTROL_COPY_TIMEOUT_SECONDS:-30', control)
        self.assertGreaterEqual(control.count('--timeout "$copy_timeout_seconds"'), 4)

    def test_libbox_build_is_anchored_to_apple_repository(self):
        helper = DEVICE_HELPER.read_text()
        build_libbox = helper.split("build_libbox()", 1)[1].split("verify_libbox()", 1)[0]
        self.assertIn('cd "$repo_root"', build_libbox)
        self.assertLess(
            build_libbox.index('cd "$repo_root"'),
            build_libbox.index('bash "$repo_root/scripts/build_libbox.sh"'),
        )
        self.assertIn('>"$build_dir/build-libbox-iphone.log" 2>&1', build_libbox)

    def test_coredevice_launch_retries_only_remote_xpc_invalidation_once(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        classifier = control.split(
            "retryable_coredevice_launch_failure()", 1
        )[1].split("run()", 1)[0]
        self.assertIn('"com.apple.dt.CoreDeviceError"', classifier)
        self.assertIn('error.get("code") == 3', classifier)
        self.assertIn('error.get("code") == 10004', classifier)
        self.assertIn('"com.apple.Mercury.error"', classifier)
        self.assertIn('underlying.get("code") == 1001', classifier)
        self.assertIn("for launch_attempt in 1 2", control)
        self.assertIn("launch-attempt-1.json", control)

    def test_clean_profile_bootstrap_is_dev_controlled_and_wifi_only(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        self.assertIn("bootstrap-profile", control)
        self.assertIn("export-profile", control)
        self.assertIn("WLT_CONTROL_PROFILE_FILE", control)
        self.assertIn("WLT_CONTROL_PROFILE_EXPORT_FILE", control)
        self.assertIn('case bootstrapProfile = "bootstrap-profile"', device_control)
        self.assertIn('case exportProfile = "export-profile"', device_control)
        bootstrap = device_control.split(
            "private func bootstrapProfile", 1
        )[1].split("private func pruneWorkloadPlans", 1)[0]
        self.assertIn("network.wifi", bootstrap)
        self.assertIn("!network.cellular", bootstrap)
        self.assertIn("ExtensionProfile.install()", bootstrap)
        self.assertIn("LibboxCheckConfig", bootstrap)
        self.assertIn("autoUpdate: false", bootstrap)
        self.assertNotIn("profile.url", control)

    def test_stop_delivery_preserves_running_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / "calls.jsonl"
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text("#!/usr/bin/env python3\n" + textwrap.dedent('''
                import json, os, sys
                from pathlib import Path
                args = sys.argv[1:]
                with open(os.environ["FAKE_XCRUN_CALLS"], "a") as stream:
                    stream.write(json.dumps(args) + "\\n")
                if "launch" in args:
                    Path(args[args.index("--json-output") + 1]).write_text(
                        json.dumps({"info": {"outcome": "success"}}))
                elif "copy" in args and "from" in args:
                    request = Path(args[args.index("--source") + 1]).stem
                    Path(args[args.index("--destination") + 1]).write_text(json.dumps({
                        "schema": 7, "request_id": request, "action": "stop",
                        "state": "succeeded", "vpn_status": "disconnected"}))
                else:
                    raise SystemExit(2)
            '''))
            fake_xcrun.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               DEVICE_ID="fixture-device", WLT_APP_BUNDLE_ID="example.dev",
                               WLT_CONTROL_ARTIFACT_DIR=str(root / "artifacts"),
                               FAKE_XCRUN_CALLS=str(calls))
            result = subprocess.run([str(SCRIPTS / "iphone_wlt_control.sh"), "stop"],
                                    env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            launches = [json.loads(line) for line in calls.read_text().splitlines()
                        if "launch" in json.loads(line)]
            self.assertEqual(len(launches), 1)
            self.assertNotIn("--terminate-existing", launches[0])
            self.assertIn("--payload-url", launches[0])

    def test_startup_retry_has_budget_and_requires_cleanup(self):
        runner = (SCRIPTS / "iphone_wlt_stability.sh").read_text()
        self.assertIn("WLT_CONTROL_TIMEOUT_SECONDS=300", runner)
        self.assertIn('|| die "startup retry stop did not prove cleanup"', runner)

    def test_stop_budget_preserves_unattended_control(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        device_control = (SCRIPTS.parent / "SFI/WLTDeviceControl.swift").read_text()
        self.assertIn('timeout_seconds="${WLT_CONTROL_TIMEOUT_SECONDS:-240}"', control)
        awake_cases = device_control.split('let keepsDeviceAwake = switch request.action {', 1)[1].split('default:', 1)[0]
        self.assertIn('.stop', awake_cases)

    def test_state_export_is_bounded_consistent_and_private(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        profile_manager = (SCRIPTS.parent / "Library" / "Database" / "ProfileManager.swift").read_text()
        self.assertIn('case exportState = "export-state"', device_control)
        self.assertIn("currentStatus == .disconnected", device_control)
        self.assertIn("backupProfileDatabase", device_control)
        self.assertIn("before.indices.allSatisfy", device_control)
        self.assertIn("last_known_good_present", device_control)
        self.assertIn("32 * 1_024 * 1_024", device_control)
        self.assertIn("Database.sharedWriter.backup(to: backup)", profile_manager)
        self.assertIn('PRAGMA integrity_check', profile_manager)
        self.assertNotIn("wal_checkpoint", profile_manager)
        self.assertIn("WLT_CONTROL_STATE_EXPORT_DIR", control)
        self.assertIn("WLT_APP_GROUP_ID", control)
        self.assertIn("appGroupDataContainer", control)
        self.assertIn("state export inventory mismatch", control)
        self.assertIn('mode=ro&immutable=1', control)

    def test_state_export_rejects_missing_or_existing_destination_before_device_access(self):
        control = SCRIPTS / "iphone_wlt_control.sh"
        environment = dict(os.environ, WLT_APP_BUNDLE_ID="example.dev")
        missing = subprocess.run(
            [str(control), "export-state"], env=environment, capture_output=True, text=True
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("WLT_CONTROL_STATE_EXPORT_DIR is required", missing.stderr)
        with tempfile.TemporaryDirectory() as directory:
            environment.update(
                WLT_APP_GROUP_ID="group.example.dev",
                WLT_CONTROL_STATE_EXPORT_DIR=directory,
            )
            existing = subprocess.run(
                [str(control), "export-state"], env=environment, capture_output=True, text=True
            )
        self.assertNotEqual(existing.returncode, 0)
        self.assertIn("must not exist", existing.stderr)

    def test_state_export_verifier_accepts_only_empty_wal_and_valid_shm(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        marker = '/usr/bin/python3 - "$state_export_dir" "$artifact_dir/state-export-sidecars.json" <<\'PY\'\n'
        verifier = control.split(marker, 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "state"
            root.mkdir()
            config = root / "config.json"
            config.write_text("{}")
            database = root / "settings.db"
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE profiles (id INTEGER PRIMARY KEY, path TEXT)")
            connection.execute("INSERT INTO profiles(path) VALUES (?)", ("/private/group/config.json",))
            connection.commit()
            connection.close()
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            manifest = {
                "schema": 1,
                "database": {"path": "settings.db", "bytes": database.stat().st_size,
                             "sha256": digest(database)},
                "profiles": [{
                    "database_path": "/private/group/config.json",
                    "source_relative_path": "config.json",
                    "main": {"path": "config.json", "bytes": config.stat().st_size,
                             "sha256": digest(config)},
                    "last_known_good_present": False,
                }],
            }
            (root / "manifest.json").write_text(json.dumps(manifest))
            (root / "settings.db-wal").write_bytes(b"")
            shm = bytearray(32768)
            shm[0:4] = (3_007_000).to_bytes(4, "little")
            shm[12] = 1
            shm[48:96] = shm[:48]
            (root / "settings.db-shm").write_bytes(shm)
            evidence = Path(directory) / "sidecars.json"
            accepted = subprocess.run(
                ["python3", "-c", verifier, str(root), str(evidence)], capture_output=True, text=True
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            sidecars = json.loads(evidence.read_text())
            self.assertEqual(sidecars["wal"]["bytes"], 0)
            self.assertEqual(sidecars["shm"]["maximum_frame"], 0)
            (root / "settings.db-wal").write_bytes(b"x")
            rejected_wal = subprocess.run(
                ["python3", "-c", verifier, str(root), str(evidence)], capture_output=True, text=True
            )
            self.assertNotEqual(rejected_wal.returncode, 0)
            self.assertIn("WAL must be an empty regular file", rejected_wal.stderr)
            (root / "settings.db-wal").write_bytes(b"")
            (root / "unknown").write_bytes(b"")
            rejected_unknown = subprocess.run(
                ["python3", "-c", verifier, str(root), str(evidence)], capture_output=True, text=True
            )
            self.assertNotEqual(rejected_unknown.returncode, 0)
            self.assertIn("inventory mismatch", rejected_unknown.stderr)

    def test_identity_ring_import_is_encrypted_validated_and_atomic(self):
        control = (SCRIPTS / "iphone_wlt_control.sh").read_text()
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        self.assertIn("import-identity-ring", control)
        self.assertIn("WLT_CONTROL_IDENTITY_RING_DIR", control)
        self.assertIn('metadata.st_mode & 0o077', control)
        self.assertIn('"transfer-key.base64"', control)
        self.assertIn('case importIdentityRing = "import-identity-ring"', device_control)
        importer = device_control.split(
            "private func importIdentityRing", 1
        )[1].split("private func decryptIdentityRingSnapshot", 1)[0]
        self.assertIn("AES.GCM", device_control)
        self.assertIn("LibboxValidateWLTAuthSnapshot", importer)
        self.assertIn("identityRingSnapshotsIndependent", importer)
        self.assertIn("writeProtectedAtomically(reserve", importer)
        self.assertLess(
            importer.index("writeProtectedAtomically(reserve"),
            importer.index("writeProtectedAtomically(active"),
        )
        self.assertIn('snapshot.path + ".provider-cooldown"', importer)
        self.assertIn('snapshot.path + ".test-reject-active-once"', importer)
        self.assertIn("transferInputsDeleted: true", importer)
        self.assertIn("for (url, content) in original", importer)
        self.assertIn('"identity_ring_import": result.get("identity_ring_import")', control)
        self.assertIn('if action == "import-identity-ring"', control)
        self.assertIn("umask 077", control)
        self.assertIn("cleanup_identity_transfer", control)
        self.assertIn("identity transfer cleanup could not be proven", control)

    def test_identity_ring_accepts_distinct_authenticated_vk_call_identities(self):
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        independence = device_control.split(
            "private func identityRingSnapshotsIndependent", 1
        )[1].split("private func selectedWLTCarrierConfig", 1)[0]
        self.assertIn('let bearerMode = "bearer_call_token"', independence)
        self.assertIn("leftMode == bearerMode && rightMode == bearerMode", independence)
        self.assertIn('fieldIsDistinct("device_id")', independence)
        self.assertIn('fieldIsDistinct("session_key")', independence)
        self.assertIn(
            'for field in ["anonym_token", "device_id", "messages_access_token"]',
            independence,
        )

    def test_identity_ring_resolves_absolute_and_relative_profile_paths_safely(self):
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        resolver = device_control.split(
            "private func selectedWLTCarrierConfig", 1
        )[1].split("private func writeProtectedAtomically", 1)[0]
        self.assertIn('profile.path.hasPrefix("/")', resolver)
        self.assertIn("URL(fileURLWithPath: profile.path)", resolver)
        self.assertIn("sharedDirectory.appendingPathComponent(profile.path)", resolver)
        self.assertIn('profileURL.path.hasPrefix(sharedDirectory.path + "/")', resolver)

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
        self.assertIn(
            'if action in {"start-probe", "soak"} and result.get("state") == "succeeded":',
            control,
        )
        self.assertIn(
            'if action == "workload" and result.get("state") == "succeeded":',
            control,
        )
        self.assertIn('required = {"carrier_ready", "traffic_ready"}', control)
        self.assertIn('if "direct_fallback" in milestones:', control)
        self.assertIn("refresh-profile", control)
        self.assertIn("arm-identity-ring-fault", control)
        self.assertIn("identity-ring-status", control)
        self.assertIn("LibboxArmWLTAuthRingTestRejectActiveOnce", device_control)
        self.assertIn("LibboxWLTAuthRingStatus", device_control)
        self.assertIn('"startup_milestones": result.get("startup_milestones")', control)
        self.assertIn("PacketTunnelDiagnostics.startupMilestones()", device_control)
        self.assertIn("request.action == .workload || request.action == .soak", device_control)
        self.assertIn(
            '# Keep every control URL on the existing Dev app instance.',
            control,
        )
        self.assertNotIn('launch_arguments+=(--terminate-existing)', control)
        self.assertIn("retrying delivery once after explicit stop", RUNNER.read_text())
        self.assertIn("start_probe_can_defer_to_workload", RUNNER.read_text())
        self.assertIn("traffic_ready", RUNNER.read_text())
        diagnostics = (SCRIPTS.parent / "Library" / "Network" / "PacketTunnelDiagnostics.swift").read_text()
        self.assertIn('milestone = "direct_fallback"', diagnostics)
        self.assertIn("CommandClient(.log, logMaxLines: 3_000)", device_control)
        self.assertIn("runWorkloadWithCounters", device_control)
        self.assertIn('message.contains("wlt service stats ")', device_control)
        self.assertIn("zeroToleranceCounterNames", device_control)
        self.assertIn('"transport_counters": result.get("transport_counters")', control)
        self.assertIn('"route_diagnostics": result.get("route_diagnostics")', control)
        self.assertIn('"route_diagnostics_scope": result.get("route_diagnostics_scope")', control)
        self.assertIn('case routeDiagnosticsScope = "route_diagnostics_scope"', device_control)
        self.assertIn('routeDiagnosticsScope: outcome?.routeDiagnosticsScope', device_control)
        self.assertIn('cleanProfile ? "clean_root_selection" : "leaf_selection"', device_control)
        self.assertIn('private func loadCleanGroupSelections', device_control)
        self.assertIn('let expectedTag = "whitelist-exit"', device_control)
        self.assertIn('let expectedItems = ["ru", "eu"]', device_control)
        self.assertIn("private func loadRouteDiagnostics", device_control)
        route_diagnostics = device_control.split(
            "private func loadRouteDiagnostics", 1
        )[1].split("private func writeResult", 1)[0]
        self.assertIn('"instagram-family"', route_diagnostics)
        self.assertIn('"meta-family"', route_diagnostics)
        self.assertIn('"tiktok-family"', route_diagnostics)
        self.assertIn('"youtube-family"', route_diagnostics)
        self.assertIn('"github-family"', route_diagnostics)
        self.assertIn('"neutral-example"', route_diagnostics)
        self.assertIn('"wlt-eu"', route_diagnostics)
        self.assertIn('"wlt-ru"', route_diagnostics)
        self.assertIn('"wlt-route-leaf-category=\\(category) "', route_diagnostics)
        self.assertIn('fields["network"]', route_diagnostics)
        self.assertIn('fields["attempt"]', route_diagnostics)
        self.assertIn("fields[name] == nil", route_diagnostics)
        self.assertIn("allowedFieldNames.contains(name)", route_diagnostics)
        self.assertIn("fields.count == allowedFieldNames.count", route_diagnostics)
        self.assertIn('components(separatedBy: "wlt-route-leaf-category=").count == 2', route_diagnostics)
        self.assertNotIn("uniqueKeysWithValues", route_diagnostics)
        self.assertNotIn('"wlt-route-category=\\(category)', route_diagnostics)
        self.assertNotIn('"wlt-route-policy-category=\\(category)', route_diagnostics)
        self.assertNotIn("metadata.Domain", route_diagnostics)
        self.assertIn('action == "workload"', control)
        self.assertIn("successful WLT workload has non-zero transport counters", control)
        self.assertIn("WLT_CONTROL_MAX_SUCCESSFUL_RECONNECTS", control)
        self.assertIn("WLT_CONTROL_MAX_RECONNECT_RETRIES", control)
        self.assertIn('zero_tolerance = expected_counters - {"reconnects", "reconnect_retries"}', control)
        self.assertIn("successful WLT workload exceeded reconnect allowance", control)
        self.assertIn("successful WLT workload exceeded reconnect retry allowance", control)
        self.assertIn("Preserve a sanitized result", control)
        self.assertLess(
            control.index("print(json.dumps(allowed"),
            control.index("successful WLT workload has non-zero transport counters"),
        )
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
        self.assertIn("guard await profile.status == .connected", ordinary_probe)
        self.assertNotIn("firstTrafficProbeTimeout", ordinary_probe)
        self.assertIn("timeout: Self.firstTrafficProbeTimeout", start_probe)
        self.assertIn("requestTimeout: Self.firstTrafficRequestTimeout", start_probe)
        self.assertIn("selectedProfileUsesCleanWLT", start_probe)
        self.assertIn('try await selectWorkloadRoute("eu")', start_probe)
        self.assertLess(
            start_probe.index("selectedProfileUsesCleanWLT"),
            start_probe.index("probeTraffic("),
        )
        self.assertNotIn("acceptCurrentSessionTrafficReady", device_control)
        self.assertIn("trafficLogObserver.cancel()", start_probe)
        self.assertIn("requestTimeout: TimeInterval = 10", device_control)
        self.assertIn("probeTraffic(timeout: 12)", device_control)
        self.assertIn("https://rozetked.me/", device_control)
        traffic_probe = device_control.split("private func probeTraffic(", 1)[1].split(
            "private func ", 1
        )[0]
        self.assertIn("response as? HTTPURLResponse", traffic_probe)
        self.assertIn("(200 ..< 400).contains($0.statusCode)", traffic_probe)
        self.assertIn("} ?? false", traffic_probe)
        action_case = control.split('case "$action" in', 1)[1].split("esac", 1)[0]
        accepted_actions = action_case.split(") ;;", 1)[0].strip().split("|")
        self.assertIn("workload", accepted_actions)
        self.assertIn("network-workload", accepted_actions)
        self.assertIn("explicit_saved_WLT_outbound_reachability", accepted_actions)
        self.assertIn("WLT_CONTROL_WORKLOAD_FILE", control)
        self.assertIn("case .workload:", device_control)
        network_workload = device_control.split("case .networkWorkload:", 1)[1].split(
            "private func wltAuthSnapshotURL", 1
        )[0]
        self.assertIn("routeDiagnostics: await loadRouteDiagnostics()", network_workload)
        self.assertIn("selectWorkloadRoute(plan.route)", device_control)
        self.assertIn('route == "eu" || route == "ru"', device_control)
        self.assertIn('(\"whitelist-exit\", \"ru\")', device_control)
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
        self.assertIn('for start_attempt in $(seq 1 "$max_start_attempts")', control)
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

    def test_core_wlt_memory_recovery_restarts_provider_and_enables_on_demand(self):
        provider = (
            SCRIPTS.parent / "Library" / "Network" / "ExtensionProvider.swift"
        ).read_text()
        recovery = provider.split(
            "private func performWhitelistTransportMemoryRecovery", 1
        )[1].split("private func whitelistTransportMemoryRecoveryThreshold", 1)[0]
        self.assertIn("if isCoreWhitelistTransportProfile()", recovery)
        self.assertIn("cancelTunnelWithError(restartError)", recovery)
        self.assertIn("memory recovery requesting core provider restart", recovery)

        profile = (
            SCRIPTS.parent / "Library" / "Network" / "ExtensionProfile.swift"
        ).read_text()
        start = profile.split("private func start(", 1)[1].split(
            "public func reloadService", 1
        )[0]
        self.assertIn("whitelistTransportAutoRecovery", start)
        self.assertIn(
            "alwaysOn || onDemandEnabled || whitelistTransportAutoRecovery",
            start,
        )
        self.assertIn(
            "useDefaultRules: alwaysOn || whitelistTransportAutoRecovery",
            start,
        )

    def test_default_interface_monitor_uses_active_path_not_list_order(self):
        platform = (
            SCRIPTS.parent
            / "Library"
            / "Network"
            / "ExtensionPlatformInterface.swift"
        ).read_text()
        update = platform.split(
            "private func onUpdateDefaultInterface", 1
        )[1].split("public func closeDefaultInterfaceMonitor", 1)[0]
        self.assertIn("activeDefaultInterface(path)", update)
        self.assertIn("path.usesInterfaceType(type)", update)
        self.assertNotIn("path.availableInterfaces.first\n", update.split(
            "private func activeDefaultInterface", 1
        )[0])

    def test_headless_profile_selection_updates_visible_dashboard(self):
        main_view = (SCRIPTS.parent / "SFI" / "MainView.swift").read_text()
        control = main_view.split(
            "if let request = WLTDeviceControl.Request(url: url)", 1
        )[1].split("if url.host ==", 1)[0]
        self.assertIn("request.action == .selectProfile", control)
        self.assertIn("environments.selectedProfileUpdate.send()", control)

        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        merged_contract = device_control.split(
            "private func assertSelectedMergedProfile", 1
        )[1].split("private func writeProtectedAtomically", 1)[0]
        self.assertEqual(merged_contract.count('"prefer_first_available"'), 3)

    def test_clean_group_status_uses_daemon_exposed_root_only(self):
        device_control = (SCRIPTS.parent / "SFI" / "WLTDeviceControl.swift").read_text()
        static_contract = device_control.split(
            "private func selectedProfileUsesCleanWLT", 1
        )[1].split("private func writeProtectedAtomically", 1)[0]
        self.assertIn('["ru", "eu"]', static_contract)
        self.assertIn('["vless-wlt-ru"]', static_contract)
        self.assertIn('["vless-wlt-eu"]', static_contract)

        runtime_contract = device_control.split(
            "private func loadCleanGroupSelections", 1
        )[1].split("private func loadRouteDiagnostics", 1)[0]
        self.assertIn('let expectedTag = "whitelist-exit"', runtime_contract)
        self.assertIn('let expectedItems = ["ru", "eu"]', runtime_contract)
        self.assertIn('group.selected == "eu"', runtime_contract)
        self.assertIn("if selections.count == 1", runtime_contract)
        self.assertNotIn('"vless-wlt-ru"', runtime_contract)
        self.assertNotIn('"vless-wlt-eu"', runtime_contract)
        self.assertIn('"clean_root_selection"', device_control)

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
            network_state_path = Path(os.environ["FAKE_NETWORK_STATE"])
            network_state = (
                network_state_path.read_text().strip()
                if network_state_path.exists()
                else "cellular"
            )
            network = {
                "status": "satisfied",
                "cellular": network_state == "cellular",
                "wifi": network_state == "wifi",
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
            if (
                action == "probe"
                and os.environ.get("FAKE_FAIL_FIRST_PROBE_WITH_RESULT") == "1"
            ):
                marker = calls.with_suffix(".first-probe-result-failed")
                if not marker.exists():
                    marker.write_text("1")
                    result.update({
                        "state": "failed",
                        "vpn_status": "connected",
                        "error_domain": "NSURLErrorDomain",
                        "error_code": -1200,
                    })
                    print(json.dumps(result))
                    raise SystemExit(1)
            if (
                action == "probe"
                and "soak-probe-" in os.environ.get("WLT_CONTROL_ARTIFACT_DIR", "")
                and os.environ.get("FAKE_FAIL_LTE_RETURN_PROBE_WITH_RESULT") == "1"
            ):
                handover = network_state_path.with_suffix(".lte-return")
                failed = network_state_path.with_suffix(".lte-return-failed")
                if handover.exists() and not failed.exists():
                    failed.write_text("1")
                    result.update({
                        "state": "failed",
                        "vpn_status": "connected",
                        "error_domain": "NSURLErrorDomain",
                        "error_code": -1001,
                    })
                    print(json.dumps(result))
                    raise SystemExit(1)
            if action == "soak":
                time.sleep(2)
                ineffective = os.environ.get("FAKE_INJECTION_INEFFECTIVE") == "1"
                samples = (
                    [
                        {"offset_ms": 0, "success": True},
                        {"offset_ms": 1_000, "success": True},
                        {"offset_ms": 2_000, "success": True},
                    ]
                    if ineffective
                    else [
                        {"offset_ms": 0, "success": True},
                        {"offset_ms": 1_000, "success": False},
                        {"offset_ms": 2_000, "success": True},
                    ]
                )
                failures = sum(sample["success"] is not True for sample in samples)
                result.update({
                    "vpn_status": "connected",
                    "soak_elapsed_ms": 5000,
                    "soak_samples": len(samples),
                    "soak_successes": len(samples) - failures,
                    "soak_failures": failures,
                    "soak_probe_samples": samples,
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
            network_state = Path(os.environ["FAKE_NETWORK_STATE"])
            previous = network_state.read_text().strip() if network_state.exists() else "cellular"
            if sys.argv[1] == "WLT WiFi":
                network_state.write_text("wifi")
            elif sys.argv[1] == "WLT LTE":
                network_state.write_text("cellular")
                if previous == "wifi":
                    network_state.with_suffix(".lte-return").write_text("1")
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
            "WLT_STABILITY_INITIAL_LTE_SETTLE_SECONDS": "0",
            "FAKE_CONTROL_CALLS": str(root / "control-calls.txt"),
            "FAKE_SHORTCUT_CALLS": str(root / "shortcut-calls.txt"),
            "FAKE_VPN_STATE": str(root / "vpn-state.txt"),
            "FAKE_NETWORK_STATE": str(root / "network-state.txt"),
        })
        return environment

    def test_initial_lte_settle_is_bounded_and_rechecks_cellular(self):
        runner = RUNNER.read_text()
        self.assertIn(
            'WLT_STABILITY_INITIAL_LTE_SETTLE_SECONDS:-20',
            runner,
        )
        self.assertIn(
            'initial_lte_settle_seconds <= 120',
            runner,
        )
        settle = runner.split(
            'allowing cellular routing to settle', 1
        )[1].split('fi\n\nlog "starting WLT', 1)[0]
        self.assertIn('sleep "$initial_lte_settle_seconds"', settle)
        self.assertIn('wait_for_cellular lte-settled-status', settle)

    def test_start_attempts_can_be_limited_to_one_for_diagnostic_runs(self):
        runner = RUNNER.read_text()
        self.assertIn('WLT_STABILITY_MAX_START_ATTEMPTS:-2', runner)
        self.assertIn('max_start_attempts" == "1"', runner)
        self.assertIn('seq 1 "$max_start_attempts"', runner)

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

    def test_host_observed_soak_proves_wifi_and_lte_handover(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.base_environment(root)
            environment.update({
                "WLT_STABILITY_ALLOW_SHORT": "1",
                "WLT_STABILITY_DURATION_SECONDS": "8",
                "WLT_STABILITY_PROBE_INTERVAL_SECONDS": "2",
                "WLT_STABILITY_INJECT_LOSS": "0",
                "WLT_STABILITY_WIFI_HANDOVER_AFTER_SECONDS": "2",
                "WLT_STABILITY_LTE_RETURN_AFTER_SECONDS": "4",
                "WLT_STABILITY_RESTORE_WIFI": "0",
            })

            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads((root / "artifacts" / "result.json").read_text())
            self.assertEqual(payload["classification"], "success")
            self.assertEqual(
                [value["transport"] for value in payload["network_transitions"]],
                ["wifi", "cellular"],
            )
            self.assertEqual(
                (root / "shortcut-calls.txt").read_text().splitlines(),
                ["WLT LTE", "WLT WiFi", "WLT LTE"],
            )

    def test_host_observed_probe_failure_does_not_claim_final_disconnect(self):
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
                "FAKE_FAIL_FIRST_PROBE_WITH_RESULT": "1",
            })

            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
            )

            self.assertEqual(result.returncode, 1, result.stderr)
            payload = json.loads((root / "artifacts" / "result.json").read_text())
            self.assertEqual(payload["classification"], "failed")
            self.assertEqual(payload["failures"], ["unexpected_soak_probe_failure"])
            self.assertEqual(payload["soak_failures"], 1)
            self.assertTrue(payload["cleanup_succeeded"])

    def test_planned_handover_transient_preserves_raw_failure_and_bounded_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.base_environment(root)
            environment.update({
                "WLT_STABILITY_ALLOW_SHORT": "1",
                "WLT_STABILITY_DURATION_SECONDS": "8",
                "WLT_STABILITY_PROBE_INTERVAL_SECONDS": "2",
                "WLT_STABILITY_INJECT_LOSS": "0",
                "WLT_STABILITY_WIFI_HANDOVER_AFTER_SECONDS": "2",
                "WLT_STABILITY_LTE_RETURN_AFTER_SECONDS": "4",
                "WLT_STABILITY_HANDOVER_RECOVERY_TIMEOUT_SECONDS": "6",
                "WLT_STABILITY_RESTORE_WIFI": "0",
                "FAKE_FAIL_LTE_RETURN_PROBE_WITH_RESULT": "1",
            })

            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads((root / "artifacts" / "result.json").read_text())
            self.assertEqual(payload["classification"], "success")
            self.assertEqual(payload["soak_failures"], 1)
            self.assertEqual(payload["raw_soak_failures"], 1)
            self.assertEqual(payload["planned_handover_failures"], 1)
            self.assertEqual(payload["unplanned_soak_failures"], 0)
            self.assertEqual(len(payload["planned_handover_incidents"]), 1)
            incident = payload["planned_handover_incidents"][0]
            self.assertEqual(incident["transport"], "cellular")
            self.assertLessEqual(incident["recovery_ms"], 6_000)
            self.assertTrue(payload["cleanup_succeeded"])

    def test_ineffective_loss_injection_is_infrastructure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.base_environment(root)
            environment.update({
                "WLT_STABILITY_ALLOW_SHORT": "1",
                "FAKE_INJECTION_INEFFECTIVE": "1",
            })

            result = subprocess.run(
                [str(RUNNER)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            payload = json.loads((root / "artifacts" / "result.json").read_text())
            self.assertEqual(payload["classification"], "infrastructure")
            self.assertEqual(payload["failures"], [])
            self.assertEqual(
                payload["infrastructure_failures"],
                ["connection_loss_injection_ineffective"],
            )
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
                ["stop", "status", "start-probe", "stop", "start-probe", "stop"],
            )
            self.assertEqual(
                (root / "shortcut-calls.txt").read_text().splitlines(),
                ["WLT LTE", "WLT WiFi"],
            )


if __name__ == "__main__":
    unittest.main()
