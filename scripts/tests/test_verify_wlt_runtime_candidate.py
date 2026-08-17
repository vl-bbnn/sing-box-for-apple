import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify_wlt_runtime_candidate.py"
SPEC = importlib.util.spec_from_file_location("verify_wlt_runtime_candidate", SCRIPT)
assert SPEC and SPEC.loader
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)

BASELINE = {
    "max_active": 56,
    "max_open": 24,
    "dns_open_reserve": 4,
    "max_pending": 56,
    "queue_timeout": "3s",
    "idle_timeout": "30s",
    "peer_write_buffer": 256,
    "kcp_window": 1536,
    "kcp_buffer": 3145728,
}


def session(parameters: dict[str, object], *, stopped: bool = False) -> str:
    line = "INFO wlt carrier started " + " ".join(
        f"{key}={value}" for key, value in parameters.items()
    )
    if stopped:
        line += "\nINFO wlt service stopped"
    return line + "\n"


class RuntimeCandidateVerifierTests(unittest.TestCase):
    def test_exact_match(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "service.log"
            path.write_text(session(BASELINE), encoding="utf-8")
            self.assertEqual(verifier.runtime_sessions(path), [
                {key: str(value) for key, value in BASELINE.items()}
            ])
            self.assertTrue(all(
                verifier.equal_parameter(value, str(value), key)
                for key, value in BASELINE.items()
            ))

    def test_duration_equivalence(self) -> None:
        self.assertTrue(verifier.equal_parameter("3s", "3000ms", "queue_timeout"))
        self.assertTrue(verifier.equal_parameter("0.5m", "30s", "idle_timeout"))

    def test_newest_session_wins(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "service.log"
            old = dict(BASELINE, max_open=16)
            path.write_text(
                session(old, stopped=True) + session(BASELINE),
                encoding="utf-8",
            )
            sessions = verifier.runtime_sessions(path)
            self.assertEqual(sessions[-1]["max_open"], "24")

    def test_mismatch_is_detected(self) -> None:
        self.assertFalse(verifier.equal_parameter(24, "16", "max_open"))
        self.assertFalse(verifier.equal_parameter("3s", "2500ms", "queue_timeout"))

    def test_incomplete_candidate_schema_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "candidate.json"
            path.write_text(json.dumps({"parameters": {"max_active": 56}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "complete WLT runtime schema"):
                verifier.load_candidate(path)


if __name__ == "__main__":
    unittest.main()
