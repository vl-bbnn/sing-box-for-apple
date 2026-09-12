#!/usr/bin/env python3
"""Execute the actual Swift path reducer without device/UI automation."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class DefaultInterfaceSelectionTests(unittest.TestCase):
    def test_withdrawal_and_handover(self):
        source = ROOT / "Library/Network/WLTDefaultInterfaceSelection.swift"
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            main = directory / "main.swift"
            main.write_text('''
import Network
typealias Selection = WLTDefaultInterfaceSelection
assert(Selection.offset(status: .requiresConnection, available: [.wifi], used: [.wifi]) == nil)
assert(Selection.offset(status: .unsatisfied, available: [.wifi, .cellular], used: [.wifi]) == nil)
assert(Selection.offset(status: .satisfied, available: [.wifi, .cellular], used: [.cellular]) == 1)
assert(Selection.offset(status: .satisfied, available: [.wifi], used: []) == nil)
assert(Selection.offset(status: .satisfied, available: [.other, .wifi], used: [.other]) == nil)
assert(Selection.offset(status: .satisfied, available: [.wifi], used: [.cellular]) == nil)
assert(Selection.offset(status: .satisfied, available: [.wifi], used: [.wifi]) == 0)
let before = Selection.uptimeNanos()
assert(before > 0 && Selection.uptimeNanos() >= before)
''')
            executable = directory / "path-selection"
            subprocess.run(["xcrun", "swiftc", "-D", "SFI_DEV", str(source),
                            str(main), "-o", str(executable)], check=True,
                           capture_output=True, text=True)
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main()
