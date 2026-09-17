"""Execute the host validator before any device operation can be scheduled."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).parents[2] / "scripts/iphone_wlt_control.sh"
VALIDATOR = SOURCE.read_text().split('required_workload = ', 1)[1].split('\nPY', 1)[0]
VALIDATOR = "import json, re, sys\nfrom urllib.parse import urlsplit\nvalue=json.load(open(sys.argv[1]))\nrequired_workload = " + VALIDATOR


class WorkloadValidationTests(unittest.TestCase):
    def validate(self, **extra):
        plan = dict(schema=1, route="eu", probes=[dict(
            name="body", url="https://example.com/body", minimum_bytes=64,
            timeout_seconds=30, accepted_status_codes=[200])], **extra)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as data:
            json.dump(plan, data)
            data.flush()
            return subprocess.run([sys.executable, "-c", VALIDATOR, data.name], capture_output=True).returncode

    def test_existing_sequential_plans_and_parallel_limits(self):
        self.assertEqual(self.validate(), 0)
        for width in [1, 4, 16]:
            self.assertEqual(self.validate(concurrency=width, select_route=False, required_transport="cellular"), 0)

    def test_invalid_types_limits_and_unknown_fields_rejected(self):
        for width in [True, False, None, "4", 1.5, 0, -1, 17]:
            self.assertNotEqual(self.validate(concurrency=width), 0)
        self.assertNotEqual(self.validate(parallel=4), 0)
        self.assertNotEqual(self.validate(required_transport="unknown"), 0)


if __name__ == "__main__":
    unittest.main()
