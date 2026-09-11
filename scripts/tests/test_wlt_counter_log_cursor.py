"""Exercise the actual Swift log selection against bounded-buffer rollover."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).parents[2] / "SFI" / "WLTDeviceControl.swift"


class WLTCounterLogCursorTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler is required")
    def test_new_entries_survive_bounded_log_buffer_rollover(self):
        source = SOURCE.read_text()
        workload = source.split("private func runWorkloadWithCounters(", 1)[1].split(
            "private func selectWorkloadRoute", 1
        )[0]
        # Compile the production cursor capture and selection, not a Python copy.
        capture = "let initialLogIDs =" + workload.split("let initialLogIDs =", 1)[1].split(
            "let workload =", 1
        )[0]
        selection = "let messages =" + workload.split("let messages =", 1)[1].split(
            "for message in", 1
        )[0]
        program = r'''
import Foundation

struct LogEntry {
    let id = UUID()
    let message: String
}
final class LogClient {
    var logList: [LogEntry] = []
}
@main struct Regression {
    @MainActor static func check(initialCount: Int, appendedCount: Int, limit: Int) async {
        let logClient = LogClient()
        // Repeated text must still be recognised as new by entry identity.
        let text = "wlt service stats failed=0"
        logClient.logList = (0..<initialCount).map { _ in LogEntry(message: text) }
        __CAPTURE__
        logClient.logList.append(contentsOf:
            (0..<appendedCount).map { _ in LogEntry(message: text) })
        if logClient.logList.count > limit {
            logClient.logList.removeFirst(logClient.logList.count - limit)
        }
        __SELECTION__
        precondition(messages.count == min(appendedCount, limit),
            "Fresh logs lost or historical logs admitted: \(initialCount), \(appendedCount)")
        precondition(messages.allSatisfy { $0 == text })
    }
    static func main() async {
        await check(initialCount: 3000, appendedCount: 1, limit: 3000)
        await check(initialCount: 2999, appendedCount: 5, limit: 3000)
        await check(initialCount: 3000, appendedCount: 4000, limit: 3000)
        await check(initialCount: 3000, appendedCount: 0, limit: 3000)
        await check(initialCount: 0, appendedCount: 1, limit: 3000)
        print("bounded cursor regression passed")
    }
}
'''.replace("__CAPTURE__", capture).replace("__SELECTION__", selection)
        with tempfile.TemporaryDirectory() as temporary:
            swift_file = Path(temporary) / "Regression.swift"
            executable = Path(temporary) / "regression"
            swift_file.write_text(program)
            subprocess.run(
                ["swiftc", "-parse-as-library", str(swift_file), "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=60,
            )
            result = subprocess.run(
                [str(executable)], check=True, capture_output=True, text=True, timeout=15
            )
            self.assertIn("bounded cursor regression passed", result.stdout)

    def test_missing_or_partial_counter_sets_still_fail_closed(self):
        workload = SOURCE.read_text().split("private func runWorkloadWithCounters(", 1)[1].split(
            "private func selectWorkloadRoute", 1
        )[0]
        self.assertIn("Set(counters.keys) == Self.zeroToleranceCounterNames", workload)
        self.assertIn("throw ControlError.transportCountersUnavailable", workload)
        self.assertNotIn("initialCount", workload)


if __name__ == "__main__":
    unittest.main()
