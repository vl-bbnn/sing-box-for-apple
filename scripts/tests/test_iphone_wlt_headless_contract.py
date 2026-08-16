from pathlib import Path
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
HEADLESS = (SCRIPTS / "iphone_wlt_headless.sh").read_text(encoding="utf-8")
DUAL_SIM = (SCRIPTS / "iphone_wlt_dual_sim.sh").read_text(encoding="utf-8")
SWIFT = (SCRIPTS.parent / "SFI" / "WLTHeadlessScenario.swift").read_text(
    encoding="utf-8"
)


class IPhoneWltHeadlessContractTests(unittest.TestCase):
    def test_initial_transport_is_prepared_before_scenario_launch(self) -> None:
        self.assertIn('prepare_transport="${WLT_HEADLESS_PREPARE_TRANSPORT:-1}"', HEADLESS)
        preparation = HEADLESS.index('log "preparing initial $required_transport path')
        launch = HEADLESS.index('log "launching installed app without XCTest')
        self.assertLess(preparation, launch)
        self.assertIn('"$transition_script" "$transition_mode"', HEADLESS[preparation:launch])

    def test_shortcut_resume_preserves_the_running_scenario(self) -> None:
        start = HEADLESS.index("resume_headless_app()")
        end = HEADLESS.index("launch_transition_shortcut()", start)
        resume = HEADLESS[start:end]
        self.assertNotIn("        --terminate-existing", resume)
        self.assertIn('"$bundle_id"', resume)

    def test_transition_change_is_not_dependent_on_unique_legacy_id(self) -> None:
        self.assertIn('"$transition_id" != "$handled_transition_id"', HEADLESS)
        self.assertIn('"$transition_transport" != "$handled_transition_transport"', HEADLESS)
        self.assertIn(
            'id: "repetition-\\(index)-phase-\\(phaseIndex)-\\(phase.name)"',
            SWIFT,
        )

    def test_resource_sampling_is_bounded_and_concurrent(self) -> None:
        self.assertIn("result.resourceSucceeded = await probeResources(", SWIFT)
        self.assertIn("timeout: min(probe.timeoutSeconds, 15)", SWIFT)
        self.assertIn("maxConcurrent: 4", SWIFT)
        self.assertIn("withTaskGroup(of: Bool.self", SWIFT)

    def test_http_requests_have_a_hard_wall_clock_timeout(self) -> None:
        self.assertIn("private final class URLSessionDataGate", SWIFT)
        self.assertIn("task?.cancel()", SWIFT)
        self.assertIn("HTTP request exceeded the hard \\(timeout)s wall-clock limit", SWIFT)
        self.assertIn(
            "DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout)",
            SWIFT,
        )
        self.assertEqual(SWIFT.count("try await sessionData("), 2)
        self.assertNotIn("try await session.data(for: request)", SWIFT)

    def test_dual_sim_radio_detection_prefers_the_data_service(self) -> None:
        self.assertIn("info.dataServiceIdentifier", SWIFT)
        self.assertIn("technologies[dataServiceIdentifier]", SWIFT)
        self.assertIn("radioTechnologyRank($0) < radioTechnologyRank($1)", SWIFT)
        self.assertNotIn("values.sorted().first", SWIFT)

    def test_webkit_javascript_cannot_stall_the_entire_run(self) -> None:
        self.assertIn("private final class JavaScriptEvaluationGate", SWIFT)
        self.assertIn("DispatchQueue.main.asyncAfter(deadline: .now() + timeout)", SWIFT)
        self.assertIn("JavaScript evaluation timed out after \\(timeout)s", SWIFT)
        self.assertIn("in: webView, timeout: 5", SWIFT)

    def test_dual_sim_wrapper_restores_data_line_without_mac_shortcuts(self) -> None:
        self.assertIn("trap restore_original_data_sim EXIT", DUAL_SIM)
        self.assertIn("com.apple.shortcuts", DUAL_SIM)
        self.assertIn("WLT Switch SIM", DUAL_SIM)
        self.assertIn("prefs:root=MOBILE_DATA_SETTINGS_ID", DUAL_SIM)
        self.assertNotIn("shortcuts run", DUAL_SIM)
        self.assertNotIn("WLT-Recover-Voice", DUAL_SIM)


if __name__ == "__main__":
    unittest.main()
