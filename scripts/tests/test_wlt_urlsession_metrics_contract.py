"""Source contract for additive iPhone workload timing diagnostics."""

from pathlib import Path
import unittest


SOURCE = Path(__file__).parents[2] / "SFI" / "WLTDeviceControl.swift"


class WLTURLSessionMetricsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()
        cls.metrics = cls.source.split(
            "private struct WorkloadTransactionMetrics", 1
        )[1].split("private struct WorkloadProbeResult", 1)[0]
        cls.workload = cls.source.split("private func runWorkload(", 1)[1].split(
            "private static let zeroToleranceCounterNames", 1
        )[0]

    def test_request_and_success_contract_remain_unchanged(self):
        for required in (
            "URLSessionConfiguration.ephemeral",
            ".reloadIgnoringLocalAndRemoteCacheData",
            "configuration.timeoutIntervalForRequest = TimeInterval(probe.timeoutSeconds)",
            "configuration.timeoutIntervalForResource = TimeInterval(probe.timeoutSeconds)",
            "configuration.urlCache = nil",
            'request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")',
            "bytesRead = data.count",
            'success: probeError == nil && classification == "ok"',
        ):
            self.assertIn(required, self.workload)
        self.assertNotIn('forHTTPHeaderField: "Connection"', self.workload)

    def test_per_task_delegate_preserves_structured_cancellation_without_wait(self):
        self.assertIn("session.data(\n                    for: request,\n                    delegate: metricsCollector", self.workload)
        self.assertNotIn("withCheckedContinuation", self.workload)
        self.assertNotIn("withCheckedThrowingContinuation", self.workload)
        self.assertNotIn("dataTask(", self.workload)
        self.assertNotIn("Task.sleep", self.workload)
        self.assertLess(
            self.workload.index("let finishedAt = unixMilliseconds()"),
            self.workload.index("let taskMetrics = metricsCollector.snapshot()"),
        )

    def test_startup_probe_recreates_session_after_a_bounded_timeout(self):
        probe = self.source.split("private func probeTraffic(", 1)[1].split(
            "private func loadMergedGroupSelections", 1
        )[0]
        self.assertIn("while elapsed() < timeout", probe)
        self.assertLess(
            probe.index("let session = URLSession(configuration: configuration)"),
            probe.index("session.invalidateAndCancel()"),
        )
        self.assertIn(
            "Create a fresh\n            // session for every bounded attempt",
            probe,
        )

    def test_metrics_are_nullable_redirect_complete_and_client_scoped(self):
        self.assertIn("private var capturedMetrics: WorkloadTaskMetrics?", self.metrics)
        self.assertIn("metrics.transactionMetrics.map", self.metrics)
        self.assertIn('scope = "urlsession_client"', self.metrics)
        self.assertIn("internalTunnelPhasesVisible = false", self.metrics)
        self.assertIn("connectDurationIncludesSecureConnection = true", self.metrics)
        self.assertIn("from: metrics.requestEndDate,\n                to: metrics.responseStartDate", self.metrics)
        self.assertIn("from: metrics.responseStartDate,\n                to: metrics.responseEndDate", self.metrics)
        self.assertIn("guard let start, let end", self.metrics)
        self.assertNotIn("?? 0", self.metrics)

    def test_metrics_do_not_export_endpoint_or_header_values(self):
        for forbidden in (
            "metrics.request.url",
            "metrics.response.url",
            "localAddress",
            "remoteAddress",
            "allHeaderFields",
        ):
            self.assertNotIn(forbidden, self.metrics)


if __name__ == "__main__":
    unittest.main()
