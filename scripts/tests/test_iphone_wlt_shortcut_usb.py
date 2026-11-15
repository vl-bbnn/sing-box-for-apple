import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "iphone_wlt_shortcut.sh"


class IPhoneShortcutUSBTests(unittest.TestCase):
    def test_radio_on_refuses_wifi_only_coredevice_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_idevice = root / "idevice_id"
            fake_idevice.write_text("#!/bin/sh\nexit 0\n")
            fake_idevice.chmod(0o755)
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text("#!/bin/sh\ntouch \"$FAKE_XCRUN_CALLED\"\n")
            fake_xcrun.chmod(0o755)
            called = root / "xcrun-called"
            env = os.environ.copy()
            env.update({
                "DEVICE_ID": "fixture-device",
                "WLT_SHORTCUT_ARTIFACT_DIR": str(root / "artifacts"),
                "WLT_IDEVICE_ID_BIN": str(fake_idevice),
                "XCRUN": str(fake_xcrun),
                "FAKE_XCRUN_CALLED": str(called),
            })
            result = subprocess.run(
                [str(SCRIPT), "WLT RadioOn"], env=env,
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 3)
            self.assertIn("requires this iPhone", result.stderr)
            self.assertFalse(called.exists())


if __name__ == "__main__":
    unittest.main()
