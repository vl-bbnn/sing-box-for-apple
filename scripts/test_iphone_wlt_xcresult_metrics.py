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

    def test_merges_web_asset_probe_and_preserves_site_reject(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            report = root / "scenario-report.json"
            report.write_text(json.dumps({"failure_count": 0}), encoding="utf-8")
            (root / "assets.txt").write_text(
                "page_status=200 page_bytes=46524 page_duration_ms=917 "
                "site_reject=false discovered_assets=27 requested_assets=10 "
                "successful_assets=8 minimum_successful_assets=3 "
                "asset_bytes=919482 duration_ms=4340 asset_p50_ms=1547 "
                "asset_p95_ms=3415 asset_max_ms=3415 "
                "started_at_unix_ms=1000 finished_at_unix_ms=5340 "
                "error_counts=INVALID_CONTENT:2\n",
                encoding="utf-8",
            )
            (root / "challenge.txt").write_text(
                "page_status=403 page_bytes=10290 page_duration_ms=1090 "
                "site_reject=true discovered_assets=0 requested_assets=0 "
                "successful_assets=0 asset_bytes=0 duration_ms=1090 "
                "started_at_unix_ms=6000 finished_at_unix_ms=7090 "
                "error_counts=SITE_CHALLENGE:1\n",
                encoding="utf-8",
            )
            (root / "manifest.json").write_text(json.dumps([{
                "testIdentifier": "DeviceScenarioTests/testScenario",
                "attachments": [
                    {
                        "exportedFileName": "assets.txt",
                        "suggestedHumanReadableName": "wlt-metric-web-assets-rozetked-images",
                    },
                    {
                        "exportedFileName": "challenge.txt",
                        "suggestedHumanReadableName": "wlt-metric-web-assets-4pda-images",
                    },
                ],
            }]), encoding="utf-8")

            self.assertEqual(merge_report(report, root), 2)
            payload = json.loads(report.read_text(encoding="utf-8"))
            rozetked, challenge = payload["metrics"]
            self.assertEqual(rozetked["kind"], "web_assets_probe")
            self.assertEqual(rozetked["duration_ms"], 4340)
            self.assertEqual(rozetked["successful_assets"], 8)
            self.assertEqual(rozetked["asset_p95_ms"], 3415)
            self.assertEqual(rozetked["error_counts"], {"INVALID_CONTENT": 2})
            self.assertTrue(challenge["success"])
            self.assertTrue(challenge["site_reject"])
            self.assertEqual(challenge["error_counts"], {"SITE_CHALLENGE": 1})


if __name__ == "__main__":
    unittest.main()
