#if SFI_DEV
import Foundation
import Libbox
import Library
import CoreTelephony
import CryptoKit
import Network
import NetworkExtension
import UIKit

actor WLTDeviceControl {
    static let shared = WLTDeviceControl()
    private static let firstStartTimeout: TimeInterval = 180
    private static let firstTrafficProbeTimeout: TimeInterval = 60
    private static let firstTrafficRequestTimeout: TimeInterval = 20

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
        case bootstrapProfile = "bootstrap-profile"
        case exportProfile = "export-profile"
        case ping
        case probe
        case refreshProfile = "refresh-profile"
        case identityRingStatus = "identity-ring-status"
        case armIdentityRingFault = "arm-identity-ring-fault"
        case start
        case startProbe = "start-probe"
        case status
        case stop
        case soak
        case workload
    }

    private struct ProfilePlan: Codable {
        let schema: Int
        let name: String
        let url: String
    }

    private struct WorkloadPlan: Decodable {
        let schema: Int
        let route: String
        let selectRoute: Bool?
        let probes: [WorkloadProbe]

        enum CodingKeys: String, CodingKey {
            case schema, route, probes
            case selectRoute = "select_route"
        }
    }

    private struct WorkloadProbe: Decodable {
        let name: String
        let url: String
        let minimumBytes: Int
        let timeoutSeconds: Int
        let acceptedStatusCodes: [Int]

        enum CodingKeys: String, CodingKey {
            case name, url
            case minimumBytes = "minimum_bytes"
            case timeoutSeconds = "timeout_seconds"
            case acceptedStatusCodes = "accepted_status_codes"
        }
    }

    private struct WorkloadProbeResult: Codable {
        let name: String
        let success: Bool
        let classification: String
        let statusCode: Int
        let elapsedMS: Int64
        let bytesRead: Int
        let errorDomain: String?
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case name, success, classification
            case statusCode = "status_code"
            case elapsedMS = "elapsed_ms"
            case bytesRead = "bytes_read"
            case errorDomain = "error_domain"
            case errorCode = "error_code"
        }
    }

    private struct WorkloadOutcome {
        let route: String
        let probes: [WorkloadProbeResult]
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
        let startupMilestones: [String]?
        let runtimeParameters: WhitelistTransportConfig.RuntimeParameters?
        let workloadRoute: String?
        let workloadProbes: [WorkloadProbeResult]?
        let identityRing: IdentityRingStatus?
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
            case startupMilestones = "startup_milestones"
            case runtimeParameters = "runtime_parameters"
            case workloadRoute = "workload_route"
            case workloadProbes = "workload_probes"
            case identityRing = "identity_ring"
            case networkInitial = "network_initial"
            case networkFinal = "network_final"
            case errorDomain = "error_domain"
            case errorCode = "error_code"
        }
    }

    private struct IdentityRingStatus: Codable {
        let version: Int
        let activePresent: Bool
        let previousPresent: Bool
        let reservePresent: Bool
        let quarantinePresent: Bool
        let faultArmed: Bool

        enum CodingKeys: String, CodingKey {
            case version
            case activePresent = "active_present"
            case previousPresent = "previous_present"
            case reservePresent = "reserve_present"
            case quarantinePresent = "quarantine_present"
            case faultArmed = "fault_armed"
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
        let workload: WorkloadOutcome?
        let identityRing: IdentityRingStatus?

        init(
            status: NEVPNStatus?,
            vpnStartupMS: Int64?,
            probeElapsedMS: Int64?,
            soak: SoakOutcome?,
            runtimeParameters: WhitelistTransportConfig.RuntimeParameters?,
            workload: WorkloadOutcome? = nil,
            identityRing: IdentityRingStatus? = nil
        ) {
            self.status = status
            self.vpnStartupMS = vpnStartupMS
            self.probeElapsedMS = probeElapsedMS
            self.soak = soak
            self.runtimeParameters = runtimeParameters
            self.workload = workload
            self.identityRing = identityRing
        }
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
        case selectedProfileUnavailable = 8
        case selectedProfileNotRemote = 9
        case startupFailed = 10
        case invalidWorkload = 11
        case workloadRouteSelectionFailed = 12
        case invalidProfilePlan = 13
        case profileBootstrapRequiresWiFi = 14
        case profileStoreNotEmpty = 15
        case profileExportUnavailable = 16
        case networkExtensionInstallFailed = 17
    }

    private var isRunning = false

    func execute(_ request: Request) async {
        let receivedAt = unixMilliseconds()
        let candidateURL = runtimeCandidateURL(request.id)
        let workloadURL = workloadPlanURL(request.id)
        let profileURL = profilePlanURL(request.id)
        let exportURL = profileExportURL(request.id)
        guard !isRunning else {
            try? FileManager.default.removeItem(at: candidateURL)
            try? FileManager.default.removeItem(at: workloadURL)
            try? FileManager.default.removeItem(at: profileURL)
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
        case .bootstrapProfile, .start, .startProbe, .soak, .workload:
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
        pruneWorkloadPlans(excluding: workloadURL)
        pruneProfilePlans(excluding: profileURL)
        pruneProfileExports(excluding: exportURL)
        defer { try? FileManager.default.removeItem(at: candidateURL) }
        defer { try? FileManager.default.removeItem(at: workloadURL) }
        defer { try? FileManager.default.removeItem(at: profileURL) }

        do {
            let runtimeParameters = try loadRuntimeCandidate(
                for: request.action,
                at: candidateURL
            )
            let workloadPlan = try loadWorkloadPlan(
                for: request.action,
                at: workloadURL
            )
            let profilePlan = try loadProfilePlan(
                for: request.action,
                at: profileURL
            )
            let networkInitial = await captureNetworkSnapshot()
            let outcome = try await perform(
                request,
                runtimeParameters: runtimeParameters,
                workloadPlan: workloadPlan,
                profilePlan: profilePlan
            )
            let networkFinal = await captureNetworkSnapshot()
            let workloadSucceeded = outcome.workload?.probes.allSatisfy(\.success) ?? true
            writeResult(
                request: request,
                receivedAt: receivedAt,
                state: workloadSucceeded ? "succeeded" : "failed",
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
        runtimeParameters: WhitelistTransportConfig.RuntimeParameters?,
        workloadPlan: WorkloadPlan?,
        profilePlan: ProfilePlan?
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
        if action == .refreshProfile {
            let profileID = await SharedPreferences.selectedProfileID.get()
            guard let selectedProfile = try await ProfileManager.get(profileID) else {
                throw ControlError.selectedProfileUnavailable
            }
            guard selectedProfile.type == .remote else {
                throw ControlError.selectedProfileNotRemote
            }
            try await selectedProfile.updateRemoteProfile()
            return Outcome(
                status: nil,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        }
        if action == .exportProfile {
            try await exportSelectedProfile(to: profileExportURL(request.id))
            let currentStatus = await loadCurrentStatus()
            return Outcome(
                status: currentStatus,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        }
        if action == .bootstrapProfile {
            guard let profilePlan else {
                throw ControlError.invalidProfilePlan
            }
            let installedProfile = try await bootstrapProfile(profilePlan)
            return Outcome(
                status: await installedProfile.status,
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
        if action == .start || action == .startProbe {
            PacketTunnelDiagnostics.resetStartupMilestones()
            PacketTunnelDiagnostics.appendStartupMilestone("profile_loaded")
        }

        switch action {
        case .bootstrapProfile, .exportProfile:
            preconditionFailure("profile actions are handled before Network Extension loading")
        case .ping:
            return Outcome(
                status: nil,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        case .refreshProfile:
            preconditionFailure("refresh-profile is handled before Network Extension loading")
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
        case .identityRingStatus:
            return Outcome(
                status: await profile.status,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                identityRing: try loadIdentityRingStatus()
            )
        case .armIdentityRingFault:
            let currentStatus = await profile.status
            guard currentStatus == .disconnected || currentStatus == .invalid else {
                throw ControlError.runtimeCandidateRequiresStoppedVPN
            }
            try LibboxArmWLTAuthRingTestRejectActiveOnce(wltAuthSnapshotURL().path)
            return Outcome(
                status: currentStatus,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                identityRing: try loadIdentityRingStatus()
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
            let trafficLogClient = CommandClient(.log, logMaxLines: 1_000)
            trafficLogClient.connect()
            let trafficLogObserver = Task {
                var observedCount = 0
                while !Task.isCancelled {
                    let messages = await MainActor.run {
                        trafficLogClient.logList.map(\.message)
                    }
                    if observedCount < messages.count {
                        for message in messages.dropFirst(observedCount) {
                            PacketTunnelDiagnostics.observeStartupLog(message)
                        }
                        observedCount = messages.count
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer {
                trafficLogObserver.cancel()
                for entry in trafficLogClient.logList {
                    PacketTunnelDiagnostics.observeStartupLog(entry.message)
                }
                trafficLogClient.disconnect()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            let probeStartedAt = unixMilliseconds()
            try await probeTraffic(
                timeout: Self.firstTrafficProbeTimeout,
                requestTimeout: Self.firstTrafficRequestTimeout
            )
            try? await Task.sleep(nanoseconds: 200_000_000)
            for entry in trafficLogClient.logList {
                PacketTunnelDiagnostics.observeStartupLog(entry.message)
            }
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
        case .workload:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            guard let workloadPlan else {
                throw ControlError.invalidWorkload
            }
            return Outcome(
                status: await profile.status,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                workload: try await runWorkload(workloadPlan)
            )
        }
    }

    private func wltAuthSnapshotURL() -> URL {
        FilePath.cacheDirectory
            .appendingPathComponent("WLT", isDirectory: true)
            .appendingPathComponent("auth-snapshot.json", isDirectory: false)
    }

    private func loadIdentityRingStatus() throws -> IdentityRingStatus {
        let raw = try LibboxWLTAuthRingStatus(wltAuthSnapshotURL().path)
        guard let data = raw.data(using: .utf8) else {
            throw ControlError.unexpectedStatus
        }
        return try JSONDecoder().decode(IdentityRingStatus.self, from: data)
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
                try await probeTraffic(timeout: 12)
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

    private func runWorkload(_ plan: WorkloadPlan) async throws -> WorkloadOutcome {
        if plan.selectRoute != false {
            try await selectWorkloadRoute(plan.route)
            // Selection is seeded on unrestricted Wi-Fi. Wait for the new WLT
            // path there before persisting it for a later LTE-only workload.
            try await probeTraffic(timeout: 60, requestTimeout: 20)
        }
        var results: [WorkloadProbeResult] = []
        for probe in plan.probes {
            let startedAt = unixMilliseconds()
            var statusCode = -1
            var bytesRead = 0
            var classification = "request_failed"
            var probeError: Error?
            do {
                guard
                    let endpoint = URL(string: probe.url),
                    endpoint.scheme?.lowercased() == "https",
                    endpoint.host != nil,
                    endpoint.user == nil,
                    endpoint.password == nil
                else {
                    throw ControlError.invalidWorkload
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.timeoutIntervalForRequest = TimeInterval(probe.timeoutSeconds)
                configuration.timeoutIntervalForResource = TimeInterval(probe.timeoutSeconds)
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: endpoint)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = TimeInterval(probe.timeoutSeconds)
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let (data, response) = try await session.data(for: request)
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                bytesRead = data.count
                let statusAccepted = probe.acceptedStatusCodes.isEmpty
                    ? (200 ..< 400).contains(statusCode)
                    : probe.acceptedStatusCodes.contains(statusCode)
                if !statusAccepted {
                    classification = "status_failed"
                } else if bytesRead < probe.minimumBytes {
                    classification = "short_body"
                } else {
                    classification = "ok"
                }
            } catch {
                probeError = error
            }
            let nsError = probeError as NSError?
            results.append(WorkloadProbeResult(
                name: probe.name,
                success: probeError == nil && classification == "ok",
                classification: classification,
                statusCode: statusCode,
                elapsedMS: max(0, unixMilliseconds() - startedAt),
                bytesRead: bytesRead,
                errorDomain: nsError?.domain,
                errorCode: nsError?.code
            ))
        }
        return WorkloadOutcome(route: plan.route, probes: results)
    }

    private func selectWorkloadRoute(_ route: String) async throws {
        guard route == "eu" else {
            throw ControlError.invalidWorkload
        }
        let selections = [
            ("whitelist-exit", "eu"),
            ("eu_or_wlt-eu", "vless-wlt-eu"),
        ]
        var selected = false
        for (group, outbound) in selections {
            do {
                let client = LibboxNewStandaloneCommandClient()!
                try await client.selectOutbound(group, outboundTag: outbound)
                selected = true
            } catch {
                continue
            }
        }
        guard selected else {
            throw ControlError.workloadRouteSelectionFailed
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
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
                timeout: Self.firstStartTimeout
            )
        case .disconnecting:
            _ = try await waitForStatus(profile, desired: .disconnected)
        case .disconnected, .invalid:
            break
        @unknown default:
            throw ControlError.unexpectedStatus
        }
        try await profile.start(wltRuntimeParameters: runtimeParameters)
        let startupLogClient = CommandClient(.log, logMaxLines: 3_000)
        startupLogClient.connect()
        let startupLogObserver = Task {
            var observedCount = 0
            while !Task.isCancelled {
                let messages = await MainActor.run {
                    startupLogClient.logList.map(\.message)
                }
                if observedCount < messages.count {
                    for message in messages.dropFirst(observedCount) {
                        PacketTunnelDiagnostics.observeStartupLog(message)
                    }
                    observedCount = messages.count
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer {
            startupLogObserver.cancel()
            for entry in startupLogClient.logList {
                PacketTunnelDiagnostics.observeStartupLog(entry.message)
            }
            startupLogClient.disconnect()
        }
        return try await waitForStatus(
            profile,
            desired: .connected,
            timeout: Self.firstStartTimeout,
            failOnWLTStartupFailure: true
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
        timeout: TimeInterval = 30,
        failOnWLTStartupFailure: Bool = false
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
            if failOnWLTStartupFailure,
                PacketTunnelDiagnostics.startupMilestones().contains(where: {
                    $0.hasPrefix("carrier_start_failed_")
                })
            {
                throw ControlError.startupFailed
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ControlError.timeout
    }

    private func probeTraffic(
        timeout: TimeInterval = 15,
        requestTimeout: TimeInterval = 10
    ) async throws {
        let endpoint = URL(string: "https://cp.cloudflare.com/generate_204")!
        let deadline = Date().addingTimeInterval(timeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var lastError: Error?
        while Date() < deadline {
            var request = URLRequest(url: endpoint)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = requestTimeout
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
            schema: 6,
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
            startupMilestones: request.action == .start || request.action == .startProbe
                || request.action == .workload || request.action == .soak
                ? PacketTunnelDiagnostics.startupMilestones() : nil,
            runtimeParameters: outcome?.runtimeParameters,
            workloadRoute: outcome?.workload?.route,
            workloadProbes: outcome?.workload?.probes,
            identityRing: outcome?.identityRing,
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

    private func workloadPlanURL(_ requestID: UUID) -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        return caches.appendingPathComponent(
            "wlt-test-workload-\(requestID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func profilePlanURL(_ requestID: UUID) -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        return caches.appendingPathComponent(
            "wlt-test-profile-\(requestID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func profileExportURL(_ requestID: UUID) -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        return caches.appendingPathComponent(
            "wlt-test-profile-export-\(requestID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func loadProfilePlan(for action: Action, at url: URL) throws -> ProfilePlan? {
        guard action == .bootstrapProfile else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError.invalidProfilePlan
        }
        let plan = try JSONDecoder().decode(ProfilePlan.self, from: Data(contentsOf: url))
        guard
            plan.schema == 1,
            !plan.name.isEmpty,
            plan.name.count <= 128,
            plan.url.count <= 2_048,
            let endpoint = URL(string: plan.url),
            endpoint.scheme?.lowercased() == "https",
            endpoint.host != nil,
            endpoint.user == nil,
            endpoint.password == nil
        else {
            throw ControlError.invalidProfilePlan
        }
        return plan
    }

    private func exportSelectedProfile(to destination: URL) async throws {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard
            let profile = try await ProfileManager.get(profileID),
            profile.type == .remote,
            let remoteURL = profile.remoteURL,
            !remoteURL.isEmpty
        else {
            throw ControlError.profileExportUnavailable
        }
        let plan = ProfilePlan(schema: 1, name: profile.name, url: remoteURL)
        try JSONEncoder().encode(plan).write(to: destination, options: .atomic)
    }

    private func bootstrapProfile(_ plan: ProfilePlan) async throws -> ExtensionProfile {
        let network = await captureNetworkSnapshot()
        guard network.status == "satisfied", network.wifi, !network.cellular else {
            throw ControlError.profileBootstrapRequiresWiFi
        }

        let selectedProfile: Profile
        if let existing = try await ProfileManager.get(remoteURL: plan.url) {
            selectedProfile = existing
        } else {
            guard try await ProfileManager.list().isEmpty else {
                throw ControlError.profileStoreNotEmpty
            }
            let remoteContent = try await HTTPClient.getStringAsync(plan.url)
            var configError: NSError?
            LibboxCheckConfig(remoteContent, &configError)
            if let configError {
                throw configError
            }
            let nextProfileID = try await ProfileManager.nextID()
            let profileDirectory = FilePath.sharedDirectory.appendingPathComponent(
                "configs",
                isDirectory: true
            )
            let profileURL = profileDirectory.appendingPathComponent(
                "config_\(nextProfileID).json",
                isDirectory: false
            )
            try FileManager.default.createDirectory(
                at: profileDirectory,
                withIntermediateDirectories: true
            )
            try remoteContent.write(to: profileURL, atomically: true, encoding: .utf8)
            let uniqueName = try await ProfileManager.uniqueName(plan.name)
            let profile = Profile(
                name: uniqueName,
                type: .remote,
                path: profileURL.relativePath,
                remoteURL: plan.url,
                autoUpdate: false,
                autoUpdateInterval: 0,
                lastUpdated: .now
            )
            try await ProfileManager.create(profile)
            selectedProfile = profile
        }
        await SharedPreferences.selectedProfileID.set(selectedProfile.mustID)

        if let existingExtension = try await ExtensionProfile.load() {
            await existingExtension.register()
            guard await existingExtension.status == .disconnected else {
                throw ControlError.unexpectedStatus
            }
            return existingExtension
        }
        try await ExtensionProfile.install()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let installed = try await ExtensionProfile.load() {
                await installed.register()
                return installed
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ControlError.networkExtensionInstallFailed
    }

    private func loadWorkloadPlan(for action: Action, at url: URL) throws -> WorkloadPlan? {
        guard action == .workload else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError.invalidWorkload
        }
        let plan = try JSONDecoder().decode(WorkloadPlan.self, from: Data(contentsOf: url))
        guard plan.schema == 1, plan.route == "eu", (1 ... 32).contains(plan.probes.count) else {
            throw ControlError.invalidWorkload
        }
        var names = Set<String>()
        for probe in plan.probes {
            guard
                probe.name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
                names.insert(probe.name).inserted,
                (0 ... 4_194_304).contains(probe.minimumBytes),
                (1 ... 180).contains(probe.timeoutSeconds),
                probe.acceptedStatusCodes.allSatisfy({ (100 ... 599).contains($0) }),
                probe.url.count <= 2_048,
                let endpoint = URL(string: probe.url),
                endpoint.scheme?.lowercased() == "https",
                endpoint.host != nil,
                endpoint.user == nil,
                endpoint.password == nil
            else {
                throw ControlError.invalidWorkload
            }
        }
        return plan
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

    private func pruneWorkloadPlans(excluding current: URL) {
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
            && file.lastPathComponent.hasPrefix("wlt-test-workload-")
            && file.pathExtension == "json"
        {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func pruneProfilePlans(excluding current: URL) {
        pruneProfileFiles(prefix: "wlt-test-profile-", excluding: current)
    }

    private func pruneProfileExports(excluding current: URL) {
        pruneProfileFiles(prefix: "wlt-test-profile-export-", excluding: current)
    }

    private func pruneProfileFiles(prefix: String, excluding current: URL) {
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
            && file.lastPathComponent.hasPrefix(prefix)
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
