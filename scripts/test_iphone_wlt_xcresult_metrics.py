import json
import tempfile
import unittest
from pathlib import Path

from iphone_wlt_xcresult_metrics import merge_report


class XCResultMetricsTest(unittest.TestCase):
    def test_merges_dns_and_download_attachments(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            report = root / "scenario-report.json"
            report.write_text(json.dumps({"failure_count": 0}), encoding="utf-8")
            (root / "dns.txt").write_text(
                "host=example.com status=0 elapsed_ms=120 success=true "
                "started_at_unix_ms=1000 finished_at_unix_ms=1120\n",
                encoding="utf-8",
            )
            (root / "download.txt").write_text(
                "host=example.com status=200 bytes=1048576 elapsed_ms=850 "
                "bytes_per_second=1233620 started_at_unix_ms=1200 "
                "finished_at_unix_ms=2050\n",
                encoding="utf-8",
            )
            (root / "manifest.json").write_text(json.dumps([{
                "testIdentifier": "DeviceScenarioTests/testScenario",
                "attachments": [
                    {
                        "exportedFileName": "dns.txt",
                        "suggestedHumanReadableName": "wlt-metric-dns-ru-google",
                        "isAssociatedWithFailure": False,
                        "configurationName": "Test",
                        "deviceName": "iPhone",
                        "deviceId": "fixture",
                    },
                    {
                        "exportedFileName": "download.txt",
                        "suggestedHumanReadableName": "wlt-metric-download-ru-download",
                        "isAssociatedWithFailure": False,
                        "configurationName": "Test",
                        "deviceName": "iPhone",
                        "deviceId": "fixture",
                    },
                ],
            }]), encoding="utf-8")

            self.assertEqual(merge_report(report, root), 2)
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(payload["metric_count"], 2)
            self.assertEqual(payload["metrics"][0]["kind"], "dns_probe")
            self.assertEqual(payload["metrics"][0]["duration_ms"], 120)
            self.assertEqual(payload["metrics"][1]["kind"], "https_probe")
            self.assertEqual(payload["metrics"][1]["bytes"], 1048576)

    def test_missing_manifest_yields_empty_metrics(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            report = root / "scenario-report.json"
            report.write_text(json.dumps({"failure_count": 0}), encoding="utf-8")
            self.assertEqual(merge_report(report, root), 0)
            payload = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(payload["metrics"], [])


if __name__ == "__main__":
    unittest.main()
