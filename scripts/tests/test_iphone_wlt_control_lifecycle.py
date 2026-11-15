import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import urlsplit, parse_qs


ROOT = Path(__file__).resolve().parent
REPO_CONTROL = ROOT.parent / "iphone_wlt_control.sh"
CONTROL = REPO_CONTROL if REPO_CONTROL.is_file() else ROOT / "candidate/scripts/iphone_wlt_control.sh"

FAKE_XCRUN = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit, parse_qs

args = sys.argv[1:]
log = Path(os.environ["FAKE_XCRUN_LOG"])
with log.open("a") as output:
    output.write(json.dumps(args) + "\n")

def value(flag):
    return args[args.index(flag) + 1]

if args[:4] == ["devicectl", "device", "process", "launch"]:
    launches = sum(
        json.loads(line)[:4] == ["devicectl", "device", "process", "launch"]
        for line in log.read_text().splitlines()
    )
    if os.environ.get("FAKE_RETRY_FIRST") == "1" and launches == 1:
        Path(value("--json-output")).write_text(json.dumps({
            "info": {"outcome": "failed"},
            "error": {"domain": "com.apple.dt.CoreDeviceError", "code": 10004},
        }))
        raise SystemExit(1)
    Path(value("--json-output")).write_text(json.dumps({"info": {"outcome": "succeeded"}}))
    raise SystemExit(0)
if args[:4] == ["devicectl", "device", "copy", "from"]:
    request = Path(value("--source")).stem
    result = {
        "schema": 8,
        "request_id": request,
        "action": os.environ["FAKE_ACTION"],
        "state": "succeeded",
        "startup_milestones": ["carrier_ready", "traffic_ready"],
    }
    Path(value("--destination")).write_text(json.dumps(result))
    raise SystemExit(0)
raise SystemExit("unexpected fake xcrun call: " + repr(args))
'''


class LifecycleLaunchTest(unittest.TestCase):
    def run_action(self, action: str, retry_first: bool = False):
        with tempfile.TemporaryDirectory(dir=os.environ.get("WLT_ARTIFACT_ROOT", str(ROOT))) as scratch:
            scratch = Path(scratch)
            fake = scratch / "xcrun"
            fake.write_text(FAKE_XCRUN)
            fake.chmod(0o755)
            log = scratch / "xcrun.jsonl"
            artifact = scratch / "artifact"
            environment = dict(os.environ)
            environment.update({
                "PATH": str(scratch) + os.pathsep + os.environ["PATH"],
                "DEVICE_ID": "fake-device",
                "WLT_APP_BUNDLE_ID": "example.dev",
                "WLT_CONTROL_ARTIFACT_DIR": str(artifact),
                "WLT_CONTROL_TIMEOUT_SECONDS": "10",
                "FAKE_XCRUN_LOG": str(log),
                "FAKE_ACTION": action,
                "FAKE_RETRY_FIRST": "1" if retry_first else "0",
            })
            result = subprocess.run([str(CONTROL), action], env=environment,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            launches = [call for call in calls if call[:4] ==
                        ["devicectl", "device", "process", "launch"]]
            self.assertEqual(len(launches), 2 if retry_first else 1)
            for launch in launches:
                self.assertNotIn("--terminate-existing", launch)
                self.assertIn("--activate", launch)
                self.assertEqual(launch[-1], "example.dev")
                url = launch[launch.index("--payload-url") + 1]
                parsed = urlsplit(url)
                self.assertEqual((parsed.scheme, parsed.netloc, parsed.path),
                                 ("sing-box", "wlt-test-control", "/" + action))
                self.assertIn("request", parse_qs(parsed.query))
            if retry_first:
                self.assertTrue((artifact / "launch-attempt-1.json").exists())
                self.assertEqual(launches[0], launches[1])

    def test_start_uses_payload_without_termination(self):
        self.run_action("start")

    def test_start_probe_uses_payload_without_termination(self):
        self.run_action("start-probe")

    def test_stop_retries_payload_without_termination(self):
        self.run_action("stop", retry_first=True)


if __name__ == "__main__":
    unittest.main()
