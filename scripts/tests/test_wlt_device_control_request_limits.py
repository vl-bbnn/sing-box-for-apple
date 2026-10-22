"""Boundary contracts for Dev-only host-control request parsing."""

from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).parents[2] / "SFI" / "WLTDeviceControl.swift"


class WLTDeviceControlRequestLimitTests(unittest.TestCase):
    def test_one_hour_soak_is_accepted_and_larger_value_is_rejected(self):
        source = SOURCE.read_text()
        request_parser = source.split("init?(url: URL)", 1)[1].split(
            "enum Action", 1
        )[0]
        match = re.search(
            r"\(([0-9_]+)\.\.\.([0-9_]+)\)\.contains\(duration\)",
            request_parser,
        )
        self.assertIsNotNone(match)
        minimum, maximum = (
            int(value.replace("_", "")) for value in match.groups()
        )
        self.assertTrue(minimum <= 3_600 <= maximum)
        self.assertFalse(minimum <= 3_601 <= maximum)
        self.assertIn("interval <= duration", request_parser)


if __name__ == "__main__":
    unittest.main()
