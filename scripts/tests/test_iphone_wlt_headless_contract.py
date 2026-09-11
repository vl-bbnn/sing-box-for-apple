from pathlib import Path
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
HEADLESS = (SCRIPTS / "iphone_wlt_headless.sh").read_text(encoding="utf-8")
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


if __name__ == "__main__":
    unittest.main()
