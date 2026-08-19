#if SFI_DEV
import Foundation
import Library
import CoreTelephony
import CryptoKit
import Network
import NetworkExtension
import UIKit

actor WLTDeviceControl {
    static let shared = WLTDeviceControl()

    struct Request: Equatable {
        let id: UUID
        let action: Action
        let soakDurationSeconds: Int?
        let soakIntervalSeconds: Int?

        init?(url: URL) {
            guard url.scheme == "sing-box", url.host == "wlt-test-control" else {
                return nil
            }
            let actionName = url.pathComponents.dropFirst().first
            guard let actionName, let action = Action(rawValue: actionName) else {
                return nil
            }
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let requestValue = components.queryItems?
                    .first(where: { $0.name == "request" })?.value,
                let id = UUID(uuidString: requestValue)
            else {
                return nil
            }
            self.id = id
            self.action = action
            if action == .soak {
                guard
                    let durationValue = components.queryItems?
                        .first(where: { $0.name == "duration" })?.value,
                    let intervalValue = components.queryItems?
                        .first(where: { $0.name == "interval" })?.value,
                    let duration = Int(durationValue),
                    let interval = Int(intervalValue),
                    (5...1_800).contains(duration),
                    (1...300).contains(interval),
                    interval <= duration
                else {
                    return nil
                }
                soakDurationSeconds = duration
                soakIntervalSeconds = interval
            } else {
                soakDurationSeconds = nil
                soakIntervalSeconds = nil
            }
        }
    }

    enum Action: String, Codable {
        case ping
        case probe
        case start
        case startProbe = "start-probe"
        case status
        case stop
        case soak
    }

    private struct SoakProbeSample: Codable {
        let offsetMS: Int64
        let success: Bool
        let elapsedMS: Int64
        let network: NetworkSnapshot
        let errorDomain: String?
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case offsetMS = "offset_ms"
            case success
            case elapsedMS = "elapsed_ms"
            case network
            case errorDomain = "error_domain"
            case errorCode = "error_code"
        }
    }

    private struct SoakOutcome {
        let elapsedMS: Int64
        let samples: [SoakProbeSample]
        let networkLossObserved: Bool
        let networkRecovered: Bool
    }

    private struct Result: Codable {
        let schema: Int
        let requestID: String
        let action: Action
        let state: String
        let vpnStatus: String
        let receivedAtUnixMS: Int64
        let finishedAtUnixMS: Int64
        let elapsedMS: Int64
        let vpnStartupMS: Int64?
        let probeElapsedMS: Int64?
        let soakElapsedMS: Int64?
        let soakSamples: Int?
        let soakSuccesses: Int?
        let soakFailures: Int?
        let soakProbeSamples: [SoakProbeSample]?
        let networkLossObserved: Bool?
        let networkRecovered: Bool?
        let runtimeParameters: WhitelistTransportConfig.RuntimeParameters?
        let networkInitial: NetworkSnapshot?
        let networkFinal: NetworkSnapshot?
        let errorDomain: String?
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case schema
            case requestID = "request_id"
            case action
            case state
            case vpnStatus = "vpn_status"
            case receivedAtUnixMS = "received_at_unix_ms"
            case finishedAtUnixMS = "finished_at_unix_ms"
            case elapsedMS = "elapsed_ms"
            case vpnStartupMS = "vpn_startup_ms"
            case probeElapsedMS = "probe_elapsed_ms"
            case soakElapsedMS = "soak_elapsed_ms"
            case soakSamples = "soak_samples"
            case soakSuccesses = "soak_successes"
            case soakFailures = "soak_failures"
            case soakProbeSamples = "soak_probe_samples"
            case networkLossObserved = "network_loss_observed"
            case networkRecovered = "network_recovered"
            case runtimeParameters = "runtime_parameters"
            case networkInitial = "network_initial"
            case networkFinal = "network_final"
            case errorDomain = "error_domain"
            case errorCode = "error_code"
        }
    }

    private struct NetworkSnapshot: Codable {
        let status: String
        let cellular: Bool
        let wifi: Bool
        let radioTechnology: String
        let cellularServiceCount: Int
        let dataServiceIDHash: String?

        enum CodingKeys: String, CodingKey {
            case status
            case cellular
            case wifi
            case radioTechnology = "radio_technology"
            case cellularServiceCount = "cellular_service_count"
            case dataServiceIDHash = "data_service_id_hash"
        }
    }

    private struct Outcome {
        let status: NEVPNStatus?
        let vpnStartupMS: Int64?
        let probeElapsedMS: Int64?
        let soak: SoakOutcome?
        let runtimeParameters: WhitelistTransportConfig.RuntimeParameters?
    }

    private actor ConnectivityObservation {
        private var sawUnsatisfied = false
        private var sawSatisfiedAfterLoss = false

        func observe(_ status: Network.NWPath.Status) {
            if status == .satisfied {
                if sawUnsatisfied {
                    sawSatisfiedAfterLoss = true
                }
            } else {
                sawUnsatisfied = true
            }
        }

        func result() -> (lossObserved: Bool, recovered: Bool) {
            (sawUnsatisfied, sawSatisfiedAfterLoss)
        }
    }

    private enum ControlError: Int, Error {
        case busy = 1
        case networkExtensionNotInstalled = 2
        case unexpectedStatus = 3
        case timeout = 4
        case probeFailed = 5
        case probeRequiresConnectedVPN = 6
        case runtimeCandidateRequiresStoppedVPN = 7
    }

    private var isRunning = false

    func execute(_ request: Request) async {
        let receivedAt = unixMilliseconds()
        let candidateURL = runtimeCandidateURL(request.id)
        guard !isRunning else {
            try? FileManager.default.removeItem(at: candidateURL)
            writeResult(
                request: request,
                receivedAt: receivedAt,
                state: "failed",
                vpnStatus: "unknown",
                outcome: nil,
                networkInitial: nil,
                networkFinal: nil,
                error: ControlError.busy
            )
            return
        }
        isRunning = true
        defer { isRunning = false }
        let keepsDeviceAwake = switch request.action {
        case .start, .startProbe, .soak:
            true
        default:
            false
        }
        let previousIdleTimerDisabled: Bool? = if keepsDeviceAwake {
            await MainActor.run {
                let previous = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
                return previous
            }
        } else {
            nil
        }
        defer {
            if let previousIdleTimerDisabled {
                Task { @MainActor in
                    UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
                }
            }
        }
        pruneRuntimeCandidates(excluding: candidateURL)
        defer { try? FileManager.default.removeItem(at: candidateURL) }

        do {
            let runtimeParameters = try loadRuntimeCandidate(
                for: request.action,
                at: candidateURL
            )
            let networkInitial = await captureNetworkSnapshot()
            let outcome = try await perform(
                request,
                runtimeParameters: runtimeParameters
            )
            let networkFinal = await captureNetworkSnapshot()
            writeResult(
                request: request,
                receivedAt: receivedAt,
                state: "succeeded",
                vpnStatus: outcome.status.map(statusDescription) ?? "not_checked",
                outcome: outcome,
                networkInitial: networkInitial,
                networkFinal: networkFinal,
                error: nil
            )
        } catch {
            let currentStatus = await loadCurrentStatus()
            let networkFinal = await captureNetworkSnapshot()
            writeResult(
                request: request,
                receivedAt: receivedAt,
                state: "failed",
                vpnStatus: currentStatus.map(statusDescription) ?? "unknown",
                outcome: nil,
                networkInitial: nil,
                networkFinal: networkFinal,
                error: error
            )
        }
    }

    private func perform(
        _ request: Request,
        runtimeParameters: WhitelistTransportConfig.RuntimeParameters?
    ) async throws -> Outcome {
        let action = request.action
        if action == .ping {
            return Outcome(
                status: nil,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        }
        guard let profile = try await ExtensionProfile.load() else {
            throw ControlError.networkExtensionNotInstalled
        }
        await profile.register()

        switch action {
        case .ping:
            return Outcome(
                status: nil,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        case .probe:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            let probeStartedAt = unixMilliseconds()
            try await probeTraffic()
            return Outcome(
                status: await profile.status,
                vpnStartupMS: nil,
                probeElapsedMS: max(0, unixMilliseconds() - probeStartedAt),
                soak: nil,
                runtimeParameters: nil
            )
        case .status:
            return Outcome(
                status: await profile.status,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        case .start:
            let startedAt = unixMilliseconds()
            let status = try await start(
                profile,
                runtimeParameters: runtimeParameters
            )
            return Outcome(
                status: status,
                vpnStartupMS: max(0, unixMilliseconds() - startedAt),
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: runtimeParameters
            )
        case .startProbe:
            let startedAt = unixMilliseconds()
            _ = try await start(
                profile,
                runtimeParameters: runtimeParameters
            )
            let startupMS = max(0, unixMilliseconds() - startedAt)
            let probeStartedAt = unixMilliseconds()
            try await probeTraffic()
            return Outcome(
                status: await profile.status,
                vpnStartupMS: startupMS,
                probeElapsedMS: max(0, unixMilliseconds() - probeStartedAt),
                soak: nil,
                runtimeParameters: runtimeParameters
            )
        case .stop:
            return Outcome(
                status: try await stop(profile),
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        case .soak:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            guard
                let durationSeconds = request.soakDurationSeconds,
                let intervalSeconds = request.soakIntervalSeconds
            else {
                throw ControlError.unexpectedStatus
            }
            let soak = await runSoak(
                durationSeconds: durationSeconds,
                intervalSeconds: intervalSeconds
            )
            return Outcome(
                status: await profile.status,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: soak,
                runtimeParameters: nil
            )
        }
    }

    private func runSoak(
        durationSeconds: Int,
        intervalSeconds: Int
    ) async -> SoakOutcome {
        let startedAt = unixMilliseconds()
        let deadline = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let observation = ConnectivityObservation()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let status = path.status
            Task { await observation.observe(status) }
        }
        monitor.start(queue: DispatchQueue(label: "WLTDeviceControl.SoakNetwork"))
        defer { monitor.cancel() }

        var samples: [SoakProbeSample] = []
        var nextProbeAt = Date()
        while true {
            let probeStartedAt = unixMilliseconds()
            let network = await captureNetworkSnapshot()
            var probeError: Error?
            do {
                try await probeTraffic(timeout: 8)
            } catch {
                probeError = error
            }
            let finishedAt = unixMilliseconds()
            let nsError = probeError as NSError?
            samples.append(SoakProbeSample(
                offsetMS: max(0, probeStartedAt - startedAt),
                success: probeError == nil,
                elapsedMS: max(0, finishedAt - probeStartedAt),
                network: network,
                errorDomain: nsError?.domain,
                errorCode: nsError?.code
            ))

            if deadline.timeIntervalSinceNow <= 0 {
                break
            }
            nextProbeAt = nextProbeAt.addingTimeInterval(TimeInterval(intervalSeconds))
            let delay = min(
                max(0, nextProbeAt.timeIntervalSinceNow),
                max(0, deadline.timeIntervalSinceNow)
            )
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        let connectivity = await observation.result()
        return SoakOutcome(
            elapsedMS: max(0, unixMilliseconds() - startedAt),
            samples: samples,
            networkLossObserved: connectivity.lossObserved,
            networkRecovered: connectivity.recovered
        )
    }

    private func loadCurrentStatus() async -> NEVPNStatus? {
        guard let profile = try? await ExtensionProfile.load() else {
            return nil
        }
        return await profile.status
    }

    private func start(
        _ profile: ExtensionProfile,
        runtimeParameters: WhitelistTransportConfig.RuntimeParameters?
    ) async throws -> NEVPNStatus {
        let initialStatus = await profile.status
        switch initialStatus {
        case .connected:
            if runtimeParameters != nil {
                throw ControlError.runtimeCandidateRequiresStoppedVPN
            }
            return initialStatus
        case .connecting, .reasserting:
            if runtimeParameters != nil {
                throw ControlError.runtimeCandidateRequiresStoppedVPN
            }
            return try await waitForStatus(
                profile,
                desired: .connected,
                timeout: 90
            )
        case .disconnecting:
            _ = try await waitForStatus(profile, desired: .disconnected)
        case .disconnected, .invalid:
            break
        @unknown default:
            throw ControlError.unexpectedStatus
        }
        try await profile.start(wltRuntimeParameters: runtimeParameters)
        return try await waitForStatus(
            profile,
            desired: .connected,
            timeout: 90
        )
    }

    private func stop(_ profile: ExtensionProfile) async throws -> NEVPNStatus {
        let initialStatus = await profile.status
        switch initialStatus {
        case .disconnected, .invalid:
            return initialStatus
        case .disconnecting:
            return try await waitForStatus(profile, desired: .disconnected)
        case .connecting, .connected, .reasserting:
            try await profile.stop()
            return try await waitForStatus(profile, desired: .disconnected)
        @unknown default:
            throw ControlError.unexpectedStatus
        }
    }

    private func waitForStatus(
        _ profile: ExtensionProfile,
        desired: NEVPNStatus,
        timeout: TimeInterval = 30
    ) async throws -> NEVPNStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = await profile.status
            if status == desired {
                return status
            }
            if status == .invalid {
                throw ControlError.unexpectedStatus
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ControlError.timeout
    }

    private func probeTraffic(timeout: TimeInterval = 15) async throws {
        let endpoint = URL(string: "https://cp.cloudflare.com/generate_204")!
        let deadline = Date().addingTimeInterval(timeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var lastError: Error?
        while Date() < deadline {
            var request = URLRequest(url: endpoint)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 3
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            do {
                let (_, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse, response.statusCode == 204 {
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let lastError {
            throw lastError
        }
        throw ControlError.probeFailed
    }

    private func writeResult(
        request: Request,
        receivedAt: Int64,
        state: String,
        vpnStatus: String,
        outcome: Outcome?,
        networkInitial: NetworkSnapshot?,
        networkFinal: NetworkSnapshot?,
        error: Error?
    ) {
        let finishedAt = unixMilliseconds()
        let nsError = error as NSError?
        let result = Result(
            schema: 3,
            requestID: request.id.uuidString.lowercased(),
            action: request.action,
            state: state,
            vpnStatus: vpnStatus,
            receivedAtUnixMS: receivedAt,
            finishedAtUnixMS: finishedAt,
            elapsedMS: max(0, finishedAt - receivedAt),
            vpnStartupMS: outcome?.vpnStartupMS,
            probeElapsedMS: outcome?.probeElapsedMS,
            soakElapsedMS: outcome?.soak?.elapsedMS,
            soakSamples: outcome?.soak?.samples.count,
            soakSuccesses: outcome?.soak?.samples.count(where: { $0.success }),
            soakFailures: outcome?.soak?.samples.count(where: { !$0.success }),
            soakProbeSamples: outcome?.soak?.samples,
            networkLossObserved: outcome?.soak?.networkLossObserved,
            networkRecovered: outcome?.soak?.networkRecovered,
            runtimeParameters: outcome?.runtimeParameters,
            networkInitial: networkInitial,
            networkFinal: networkFinal,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code
        )
        do {
            let directory = try resultDirectory()
            let destination = directory.appendingPathComponent(
                "\(request.id.uuidString.lowercased()).json",
                isDirectory: false
            )
            let data = try JSONEncoder().encode(result)
            try data.write(to: destination, options: .atomic)
        } catch {
            NSLog("WLT device control could not write sanitized result")
        }
    }

    private func resultDirectory() throws -> URL {
        guard
            let caches = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = caches.appendingPathComponent("wlt-test-control", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        pruneResults(in: directory)
        return directory
    }

    private func runtimeCandidateURL(_ requestID: UUID) -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        return caches.appendingPathComponent(
            "wlt-test-candidate-\(requestID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func loadRuntimeCandidate(
        for action: Action,
        at url: URL
    ) throws -> WhitelistTransportConfig.RuntimeParameters? {
        guard action == .start || action == .startProbe else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try WhitelistTransportConfig.decodeRuntimeCandidate(
            Data(contentsOf: url)
        )
    }

    private func pruneRuntimeCandidates(excluding current: URL) {
        let directory = current.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for file in files where
            file.lastPathComponent != current.lastPathComponent
            && file.lastPathComponent.hasPrefix("wlt-test-candidate-")
            && file.pathExtension == "json"
        {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func captureNetworkSnapshot() async -> NetworkSnapshot {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in }
        monitor.start(queue: DispatchQueue(label: "WLTDeviceControl.NetworkSnapshot"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let path = monitor.currentPath
        monitor.cancel()
        let telephony = CTTelephonyNetworkInfo()
        let radioByService = telephony.serviceCurrentRadioAccessTechnology ?? [:]
        let radioValues = radioByService.values.sorted()
        let cellularServiceCount = max(
            radioByService.count,
            telephony.serviceSubscriberCellularProviders?.count ?? 0
        )
        let dataServiceIDHash = telephony.dataServiceIdentifier.flatMap { identifier in
            identifier.data(using: .utf8).map { data in
                SHA256.hash(data: data)
                    .prefix(6)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
        }
        return NetworkSnapshot(
            status: path.status == .satisfied ? "satisfied" : "unsatisfied",
            cellular: path.usesInterfaceType(.cellular),
            wifi: path.usesInterfaceType(.wifi),
            radioTechnology: radioValues.isEmpty
                ? "unknown"
                : radioValues.joined(separator: ","),
            cellularServiceCount: cellularServiceCount,
            dataServiceIDHash: dataServiceIDHash
        )
    }

    private func pruneResults(in directory: URL, keeping newestCount: Int = 64) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        let results = files.filter { $0.pathExtension == "json" }.sorted { left, right in
            let leftDate = try? left.resourceValues(forKeys: keys).contentModificationDate
            let rightDate = try? right.resourceValues(forKeys: keys).contentModificationDate
            let normalizedLeftDate = leftDate ?? .distantPast
            let normalizedRightDate = rightDate ?? .distantPast
            return normalizedLeftDate > normalizedRightDate
        }
        for staleResult in results.dropFirst(newestCount) {
            try? FileManager.default.removeItem(at: staleResult)
        }
    }

    private func unixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }
}
#endif
