#if os(iOS) && SFI_DEV

import CoreTelephony
import CryptoKit
import Foundation
import Libbox
import Library
import Network
import NetworkExtension
import UIKit
import WebKit

@MainActor
enum WLTHeadlessScenarioRunner {
    static let resultFileName = "wlt-headless-result.json"
    static let serviceLogFileName = "wlt-headless-service.log"

    struct Configuration: Codable {
        struct RouteWorkload: Codable {
            var route: String
            var httpProbes: [HTTPProbe]
            var playbackProbes: [PlaybackProbe]

            enum CodingKeys: String, CodingKey {
                case route
                case httpProbes = "http_probes"
                case playbackProbes = "playback_probes"
            }
        }

        struct HTTPProbe: Codable {
            var name: String
            var url: String
            var minimumBytes: Int
            var timeoutSeconds: Double
            var resourceSampleLimit: Int
            var policyStatusCodes: [Int]
            var rangeBytes: Int?

            enum CodingKeys: String, CodingKey {
                case name, url
                case minimumBytes = "minimum_bytes"
                case timeoutSeconds = "timeout_seconds"
                case resourceSampleLimit = "resource_sample_limit"
                case policyStatusCodes = "policy_status_codes"
                case rangeBytes = "range_bytes"
            }
        }

        struct PlaybackProbe: Codable {
            var name: String
            var url: String
            var adapter: String?
            var bootstrapJavaScript: String?
            var timeoutSeconds: Double
            var observationSeconds: Double
            var minimumAdvanceSeconds: Double

            enum CodingKeys: String, CodingKey {
                case name, url, adapter
                case bootstrapJavaScript = "bootstrap_javascript"
                case timeoutSeconds = "timeout_seconds"
                case observationSeconds = "observation_seconds"
                case minimumAdvanceSeconds = "minimum_advance_seconds"
            }
        }

        struct NetworkRecoveryPhase: Codable {
            var name: String
            var requiredTransport: String
            var transitionTimeoutSeconds: Double
            var routeWorkloads: [RouteWorkload]

            enum CodingKeys: String, CodingKey {
                case name
                case requiredTransport = "required_transport"
                case transitionTimeoutSeconds = "transition_timeout_seconds"
                case routeWorkloads = "route_workloads"
            }
        }

        var runID: String
        var repetitions: Int
        var requiredTransport: String
        var vpnMode: String?
        var startupTimeoutSeconds: Double
        var settleSeconds: Double
        var routeWorkloads: [RouteWorkload]
        var warmProbe: HTTPProbe?
        var networkRecoveryPhases: [NetworkRecoveryPhase]?

        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case repetitions
            case requiredTransport = "required_transport"
            case vpnMode = "vpn_mode"
            case startupTimeoutSeconds = "startup_timeout_seconds"
            case settleSeconds = "settle_seconds"
            case routeWorkloads = "route_workloads"
            case warmProbe = "warm_probe"
            case networkRecoveryPhases = "network_recovery_phases"
        }
    }

    struct NetworkSnapshot: Codable {
        var status: String
        var wifi: Bool
        var cellular: Bool
        var expensive: Bool
        var constrained: Bool
        var radioTechnology: String?

        enum CodingKeys: String, CodingKey {
            case status, wifi, cellular, expensive, constrained
            case radioTechnology = "radio_technology"
        }
    }

    struct TransactionMetrics: Codable {
        var dnsMilliseconds: Double?
        var connectMilliseconds: Double?
        var tlsMilliseconds: Double?
        var firstByteMilliseconds: Double?
        var totalMilliseconds: Double?
        var protocolName: String?
        var reusedConnection: Bool?

        enum CodingKeys: String, CodingKey {
            case dnsMilliseconds = "dns_ms"
            case connectMilliseconds = "connect_ms"
            case tlsMilliseconds = "tls_ms"
            case firstByteMilliseconds = "first_byte_ms"
            case totalMilliseconds = "total_ms"
            case protocolName = "protocol"
            case reusedConnection = "reused_connection"
        }
    }

    struct HTTPProbeResult: Codable {
        var name: String
        var url: String
        var success: Bool
        var classification: String
        var statusCode: Int?
        var bytes: Int
        var elapsedMilliseconds: Double
        var metrics: TransactionMetrics?
        var resourceRequested: Int
        var resourceSucceeded: Int
        var resourceSuccessPercent: Double?
        var bodySHA256: String?
        var normalizedContentSHA256: String?
        var contentTokenCount: Int
        var contentTokenHashes: [String]
        var resourceManifestSHA256: String?
        var resourceURLHashes: [String]
        var error: String?

        enum CodingKeys: String, CodingKey {
            case name, url, success, classification, bytes, metrics, error
            case statusCode = "status_code"
            case elapsedMilliseconds = "elapsed_ms"
            case resourceRequested = "resource_requested"
            case resourceSucceeded = "resource_succeeded"
            case resourceSuccessPercent = "resource_success_percent"
            case bodySHA256 = "body_sha256"
            case normalizedContentSHA256 = "normalized_content_sha256"
            case contentTokenCount = "content_token_count"
            case contentTokenHashes = "content_token_hashes"
            case resourceManifestSHA256 = "resource_manifest_sha256"
            case resourceURLHashes = "resource_url_hashes"
        }
    }

    struct PlaybackProbeResult: Codable {
        var name: String
        var url: String
        var success: Bool
        var elapsedMilliseconds: Double
        var initialTime: Double?
        var finalTime: Double?
        var advanceSeconds: Double?
        var readyState: Int?
        var videoHeight: Int?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case name, url, success, error
            case elapsedMilliseconds = "elapsed_ms"
            case initialTime = "initial_time"
            case finalTime = "final_time"
            case advanceSeconds = "advance_seconds"
            case readyState = "ready_state"
            case videoHeight = "video_height"
        }
    }

    struct RouteResult: Codable {
        var route: String
        var selectMilliseconds: Double?
        var httpProbes: [HTTPProbeResult]
        var playbackProbes: [PlaybackProbeResult]
        var infrastructureError: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case route, error
            case selectMilliseconds = "select_ms"
            case httpProbes = "http_probes"
            case playbackProbes = "playback_probes"
            case infrastructureError = "infrastructure_error"
        }
    }

    struct NetworkRecoveryPhaseResult: Codable {
        var name: String
        var requiredTransport: String
        var network: NetworkSnapshot?
        var transitionMilliseconds: Double?
        var routes: [RouteResult]
        var error: String?

        enum CodingKeys: String, CodingKey {
            case name, network, routes, error
            case requiredTransport = "required_transport"
            case transitionMilliseconds = "transition_ms"
        }
    }

    struct TransitionRequest: Codable {
        var id: String
        var transport: String
    }

    struct RepetitionResult: Codable {
        var index: Int
        var networkBefore: NetworkSnapshot?
        var coldStartupMilliseconds: Double?
        var warmStartupMilliseconds: Double?
        var routes: [RouteResult]
        var networkRecoveryPhases: [NetworkRecoveryPhaseResult]? = nil
        var cleanupSucceeded: Bool
        var error: String?

        enum CodingKeys: String, CodingKey {
            case index, routes, error
            case networkBefore = "network_before"
            case coldStartupMilliseconds = "cold_startup_ms"
            case warmStartupMilliseconds = "warm_startup_ms"
            case cleanupSucceeded = "cleanup_succeeded"
            case networkRecoveryPhases = "network_recovery_phases"
        }
    }

    struct Result: Codable {
        var schema: Int
        var runID: String
        var status: String
        var startedAt: Date
        var finishedAt: Date?
        var requiredTransport: String
        var vpnMode: String
        var cellularAccessAllowed: Bool
        var networkInitial: NetworkSnapshot?
        var networkFinal: NetworkSnapshot?
        var repetitions: [RepetitionResult]
        var infrastructureFailures: [String]
        var baselineFailures: [String]
        var transportRejects: [String]
        var policyResponses: [String]
        var transitionRequest: TransitionRequest? = nil

        enum CodingKeys: String, CodingKey {
            case schema, status, repetitions
            case runID = "run_id"
            case startedAt = "started_at"
            case finishedAt = "finished_at"
            case requiredTransport = "required_transport"
            case vpnMode = "vpn_mode"
            case cellularAccessAllowed = "cellular_access_allowed"
            case networkInitial = "network_initial"
            case networkFinal = "network_final"
            case infrastructureFailures = "infrastructure_failures"
            case baselineFailures = "baseline_failures"
            case transportRejects = "transport_rejects"
            case policyResponses = "policy_responses"
            case transitionRequest = "transition_request"
        }
    }

    private struct PlaybackState: Decodable {
        var currentTime: Double
        var readyState: Int
        var videoHeight: Int
        var paused: Bool
    }

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var collected: URLSessionTaskMetrics?

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            lock.lock()
            collected = metrics
            lock.unlock()
        }

        func snapshot(elapsedMilliseconds: Double) -> TransactionMetrics? {
            lock.lock()
            let metrics = collected
            lock.unlock()
            guard let transaction = metrics?.transactionMetrics.last else { return nil }

            func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
                guard let start, let end else { return nil }
                return end.timeIntervalSince(start) * 1_000
            }

            return TransactionMetrics(
                dnsMilliseconds: milliseconds(
                    transaction.domainLookupStartDate,
                    transaction.domainLookupEndDate
                ),
                connectMilliseconds: milliseconds(
                    transaction.connectStartDate,
                    transaction.connectEndDate
                ),
                tlsMilliseconds: milliseconds(
                    transaction.secureConnectionStartDate,
                    transaction.secureConnectionEndDate
                ),
                firstByteMilliseconds: milliseconds(
                    transaction.requestStartDate,
                    transaction.responseStartDate
                ),
                totalMilliseconds: metrics.map { $0.taskInterval.duration * 1_000 }
                    ?? elapsedMilliseconds,
                protocolName: transaction.networkProtocolName,
                reusedConnection: transaction.isReusedConnection
            )
        }
    }

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.environment["WLT_HEADLESS_SCENARIO"] == "1"
    }

    static func run(profile initialProfile: ExtensionProfile, environments: ExtensionEnvironments) async {
        guard isRequested() else { return }
        // Keep long unattended Wi-Fi/LTE comparison runs from crossing an
        // iOS auto-lock boundary. CoreDevice cannot launch the cleanup
        // Shortcut once the device has locked, so restore the previous idle
        // timer policy as soon as this app-side scenario finishes.
        let previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        let startedAt = Date()
        var result = Result(
            schema: 3,
            runID: ProcessInfo.processInfo.environment["WLT_HEADLESS_RUN_ID"] ?? "unknown",
            status: "starting",
            startedAt: startedAt,
            finishedAt: nil,
            requiredTransport: "unknown",
            vpnMode: "unknown",
            cellularAccessAllowed: true,
            networkInitial: nil,
            networkFinal: nil,
            repetitions: [],
            infrastructureFailures: [],
            baselineFailures: [],
            transportRejects: [],
            policyResponses: []
        )
        write(result)

        do {
            let configuration = try loadConfiguration()
            result.runID = configuration.runID
            result.requiredTransport = configuration.requiredTransport
            let vpnMode = configuration.vpnMode ?? "wlt"
            result.vpnMode = vpnMode
            let allowsCellularAccess = configuration.requiredTransport != "wifi"
            result.cellularAccessAllowed = allowsCellularAccess
            try validate(configuration)
            if ProcessInfo.processInfo.environment["WLT_HEADLESS_CLEANUP"] == "1" {
                let profile = try await ExtensionProfile.load() ?? initialProfile
                profile.register()
                try await stop(profile, timeout: 45)
                result.networkFinal = await networkSnapshot(timeout: 15)
                result.status = "cleanup_completed"
                result.finishedAt = Date()
                write(result)
                return
            }
            result.status = "preflight"
            write(result)

            let initialNetwork = await networkSnapshot(timeout: 15)
            result.networkInitial = initialNetwork
            try requireTransport(initialNetwork, expected: configuration.requiredTransport)

            let profile = try await ExtensionProfile.load() ?? initialProfile
            profile.register()
            if profile.status.isConnected {
                try await stop(profile, timeout: 45)
            }

            result.status = "running"
            write(result)

            for index in 1...configuration.repetitions {
                var repetition = RepetitionResult(
                    index: index,
                    networkBefore: nil,
                    coldStartupMilliseconds: nil,
                    warmStartupMilliseconds: nil,
                    routes: [],
                    cleanupSucceeded: false,
                    error: nil
                )
                do {
                    let network = await networkSnapshot(timeout: 15)
                    repetition.networkBefore = network
                    try requireTransport(network, expected: configuration.requiredTransport)

                    if vpnMode == "wlt" {
                        repetition.coldStartupMilliseconds = try await start(
                            profile,
                            timeout: configuration.startupTimeoutSeconds
                        )
                    } else if profile.status.isConnected {
                        try await stop(profile, timeout: 45)
                    }
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, configuration.settleSeconds) * 1_000_000_000)
                    )

                    if let recoveryPhases = configuration.networkRecoveryPhases,
                       !recoveryPhases.isEmpty
                    {
                        repetition.networkRecoveryPhases = []
                        for (phaseIndex, phase) in recoveryPhases.enumerated() {
                            let transitionStarted = Date()
                            let phaseNetwork: NetworkSnapshot?
                            if phaseIndex == 0 {
                                phaseNetwork = await networkSnapshot(timeout: 15)
                                try requireTransport(
                                    phaseNetwork,
                                    expected: phase.requiredTransport
                                )
                            } else {
                                result.transitionRequest = TransitionRequest(
                                    id: "repetition-\(index)-phase-\(phaseIndex)-\(phase.name)",
                                    transport: phase.requiredTransport
                                )
                                result.status = "waiting_for_transition"
                                write(result)
                                phaseNetwork = try await waitForTransport(
                                    phase.requiredTransport,
                                    timeout: phase.transitionTimeoutSeconds
                                )
                                result.transitionRequest = nil
                                result.status = "running"
                                write(result)
                            }

                            var phaseResult = NetworkRecoveryPhaseResult(
                                name: phase.name,
                                requiredTransport: phase.requiredTransport,
                                network: phaseNetwork,
                                transitionMilliseconds: phaseIndex == 0 ? nil
                                    : Date().timeIntervalSince(transitionStarted) * 1_000,
                                routes: [],
                                error: nil
                            )
                            for workload in phase.routeWorkloads {
                                let routeResult = await run(
                                    workload: workload,
                                    selectRoute: vpnMode == "wlt",
                                    allowsCellularAccess: phase.requiredTransport != "wifi"
                                )
                                phaseResult.routes.append(routeResult)
                                repetition.routes.append(routeResult)
                                collectClassifications(
                                    routeResult,
                                    vpnMode: vpnMode,
                                    into: &result
                                )
                            }
                            if let failed = phaseResult.routes.first(where: { $0.error != nil }) {
                                phaseResult.error = failed.error
                            }
                            repetition.networkRecoveryPhases?.append(phaseResult)
                        }
                    } else {
                        for workload in configuration.routeWorkloads {
                            let routeResult = await run(
                                workload: workload,
                                selectRoute: vpnMode == "wlt",
                                allowsCellularAccess: allowsCellularAccess
                            )
                            repetition.routes.append(routeResult)
                            collectClassifications(routeResult, vpnMode: vpnMode, into: &result)
                        }

                        if vpnMode == "wlt" {
                            await exportServiceLog(environments)
                            try await stop(profile, timeout: 45)
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            repetition.warmStartupMilliseconds = try await start(
                                profile,
                                timeout: configuration.startupTimeoutSeconds
                            )
                        }
                        if let warmProbe = configuration.warmProbe {
                            let warmResult = await runHTTPProbe(
                                warmProbe,
                                allowsCellularAccess: allowsCellularAccess
                            )
                            var warmRoute = RouteResult(
                                route: "warm-sentinel",
                                selectMilliseconds: nil,
                                httpProbes: [warmResult],
                                playbackProbes: [],
                                infrastructureError: nil,
                                error: warmResult.success ? nil
                                    : warmResult.error ?? warmResult.classification
                            )
                            if !warmResult.success {
                                warmRoute.error = warmResult.error ?? warmResult.classification
                            }
                            repetition.routes.append(warmRoute)
                            collectClassifications(warmRoute, vpnMode: vpnMode, into: &result)
                        }
                    }
                    if vpnMode == "wlt" {
                        await exportServiceLog(environments)
                        try await stop(profile, timeout: 45)
                    }
                    repetition.cleanupSucceeded = true
                } catch {
                    result.transitionRequest = nil
                    repetition.error = error.localizedDescription
                    result.infrastructureFailures.append("repetition_\(index): \(error.localizedDescription)")
                    do {
                        try await stop(profile, timeout: 45)
                        repetition.cleanupSucceeded = true
                    } catch {
                        result.infrastructureFailures.append(
                            "repetition_\(index)_cleanup: \(error.localizedDescription)"
                        )
                    }
                }
                result.repetitions.append(repetition)
                write(result)
            }

            if profile.status.isConnected {
                try await stop(profile, timeout: 45)
            }
            result.networkFinal = await networkSnapshot(timeout: 15)
            try requireTransport(result.networkFinal, expected: configuration.requiredTransport)
            let repetitionsPassed = result.repetitions.count == configuration.repetitions
                && result.repetitions.allSatisfy { repetition in
                    repetition.error == nil
                        && repetition.cleanupSucceeded
                        && repetition.routes.allSatisfy { route in
                            route.error == nil
                                && route.httpProbes.allSatisfy(\.success)
                                && route.playbackProbes.allSatisfy(\.success)
                        }
                }
            result.status = repetitionsPassed && result.infrastructureFailures.isEmpty
                && result.baselineFailures.isEmpty && result.transportRejects.isEmpty
                ? "passed" : "failed"
        } catch {
            result.transitionRequest = nil
            result.infrastructureFailures.append(error.localizedDescription)
            result.status = "failed"
            if let profile = try? await ExtensionProfile.load(), profile.status.isConnected {
                try? await stop(profile, timeout: 45)
            }
            result.networkFinal = await networkSnapshot(timeout: 15)
        }
        result.finishedAt = Date()
        write(result)
    }

    private static func loadConfiguration() throws -> Configuration {
        guard let encoded = ProcessInfo.processInfo.environment["WLT_HEADLESS_SCENARIO_BASE64"],
              let data = Data(base64Encoded: encoded)
        else {
            throw scenarioError("WLT_HEADLESS_SCENARIO_BASE64 is missing or invalid")
        }
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw scenarioError("headless configuration decode failed: \(error.localizedDescription)")
        }
    }

    private static func validate(_ configuration: Configuration) throws {
        guard !configuration.runID.isEmpty else { throw scenarioError("run_id is empty") }
        guard (1...20).contains(configuration.repetitions) else {
            throw scenarioError("repetitions must be between 1 and 20")
        }
        guard ["cellular", "wifi"].contains(configuration.requiredTransport) else {
            throw scenarioError("required_transport must be cellular or wifi")
        }
        guard ["off", "wlt"].contains(configuration.vpnMode ?? "wlt") else {
            throw scenarioError("vpn_mode must be off or wlt")
        }
        guard configuration.startupTimeoutSeconds > 0 else {
            throw scenarioError("startup_timeout_seconds must be positive")
        }
        guard !configuration.routeWorkloads.isEmpty else {
            throw scenarioError("route_workloads must not be empty")
        }
        guard configuration.routeWorkloads.contains(where: {
            !$0.httpProbes.isEmpty || !$0.playbackProbes.isEmpty
        }) else {
            throw scenarioError("route_workloads must contain at least one probe")
        }
        for workload in configuration.routeWorkloads {
            guard ["ru", "eu"].contains(workload.route) else {
                throw scenarioError("unsupported route: \(workload.route)")
            }
            for probe in workload.playbackProbes {
                guard ["html_video", "youtube_iframe", "twitch_embed"].contains(
                    probe.adapter ?? "html_video"
                ) else {
                    throw scenarioError("unsupported playback adapter: \(probe.adapter ?? "unknown")")
                }
            }
        }
        if let phases = configuration.networkRecoveryPhases {
            guard !phases.isEmpty else {
                throw scenarioError("network_recovery_phases must not be empty")
            }
            guard (configuration.vpnMode ?? "wlt") == "wlt" else {
                throw scenarioError("network recovery requires vpn_mode=wlt")
            }
            guard phases.first?.requiredTransport == configuration.requiredTransport,
                  phases.last?.requiredTransport == configuration.requiredTransport
            else {
                throw scenarioError(
                    "network recovery must start and finish on required_transport"
                )
            }
            for phase in phases {
                guard !phase.name.isEmpty else {
                    throw scenarioError("network recovery phase name is empty")
                }
                guard ["cellular", "wifi"].contains(phase.requiredTransport) else {
                    throw scenarioError(
                        "unsupported recovery transport: \(phase.requiredTransport)"
                    )
                }
                guard phase.transitionTimeoutSeconds > 0 else {
                    throw scenarioError(
                        "transition_timeout_seconds must be positive for \(phase.name)"
                    )
                }
                guard !phase.routeWorkloads.isEmpty else {
                    throw scenarioError("recovery phase \(phase.name) has no workloads")
                }
                for workload in phase.routeWorkloads {
                    guard ["ru", "eu"].contains(workload.route) else {
                        throw scenarioError("unsupported route: \(workload.route)")
                    }
                }
            }
        }
    }

    private static func start(_ profile: ExtensionProfile, timeout: Double) async throws -> Double {
        if profile.status.isConnected { return 0 }
        let started = Date()
        try await profile.start()
        try await waitForStatus(profile, connected: true, timeout: timeout)
        return Date().timeIntervalSince(started) * 1_000
    }

    private static func stop(_ profile: ExtensionProfile, timeout: Double) async throws {
        if !profile.status.isConnected,
           profile.status != .connecting,
           profile.status != .reasserting
        {
            return
        }
        try await profile.stop()
        try await waitForStatus(profile, connected: false, timeout: timeout)
    }

    private static func waitForStatus(
        _ profile: ExtensionProfile,
        connected: Bool,
        timeout: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connected, profile.status.isConnected { return }
            if !connected, profile.status == .disconnected || profile.status == .invalid { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw scenarioError(
            "VPN did not become \(connected ? "connected" : "disconnected") within \(timeout)s; status=\(profile.status.rawValue)"
        )
    }

    private static func waitForTransport(
        _ expected: String,
        timeout: Double
    ) async throws -> NetworkSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot: NetworkSnapshot?
        while Date() < deadline {
            let snapshot = await networkSnapshot(timeout: 3)
            lastSnapshot = snapshot
            if (try? requireTransport(snapshot, expected: expected)) != nil,
               let snapshot
            {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let details = lastSnapshot.map {
            "wifi=\($0.wifi) cellular=\($0.cellular) radio=\($0.radioTechnology ?? "unknown")"
        } ?? "no NWPath snapshot"
        throw scenarioError(
            "transition to \(expected) was not proven within \(timeout)s; \(details)"
        )
    }

    private static func run(
        workload: Configuration.RouteWorkload,
        selectRoute: Bool,
        allowsCellularAccess: Bool
    ) async -> RouteResult {
        var result = RouteResult(
            route: workload.route,
            selectMilliseconds: nil,
            httpProbes: [],
            playbackProbes: [],
            infrastructureError: nil,
            error: nil
        )
        do {
            if selectRoute {
                let started = Date()
                try await selectOutboundWhenReady(
                    groupTag: "whitelist-exit",
                    outboundTag: workload.route,
                    timeout: 12
                )
                result.selectMilliseconds = Date().timeIntervalSince(started) * 1_000
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            for probe in workload.httpProbes {
                result.httpProbes.append(
                    await runHTTPProbe(probe, allowsCellularAccess: allowsCellularAccess)
                )
            }
            for probe in workload.playbackProbes {
                result.playbackProbes.append(await runPlaybackProbe(probe))
            }
            if let failed = result.httpProbes.first(where: { !$0.success }) {
                result.error = "\(failed.name): \(failed.error ?? failed.classification)"
            } else if let failed = result.playbackProbes.first(where: { !$0.success }) {
                result.error = "\(failed.name): \(failed.error ?? "playback_stalled")"
            }
        } catch {
            if result.httpProbes.isEmpty, result.playbackProbes.isEmpty {
                result.infrastructureError = error.localizedDescription
            }
            result.error = error.localizedDescription
        }
        return result
    }

    private static func selectOutboundWhenReady(
        groupTag: String,
        outboundTag: String,
        timeout: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        repeat {
            do {
                guard let client = LibboxNewStandaloneCommandClient() else {
                    throw scenarioError("standalone command client is unavailable")
                }
                try await client.selectOutbound(groupTag, outboundTag: outboundTag)
                return
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        throw scenarioError(
            "outbound selector was not ready within \(timeout)s for \(groupTag)/\(outboundTag): "
                + (lastError?.localizedDescription ?? "unknown error")
        )
    }

    private static func runHTTPProbe(
        _ probe: Configuration.HTTPProbe,
        allowsCellularAccess: Bool
    ) async -> HTTPProbeResult {
        guard let url = URL(string: probe.url) else {
            return failedHTTPProbe(probe, classification: "invalid_url", error: "invalid URL")
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: probe.timeoutSeconds
        )
        request.setValue("2b2n-wlt-headless/1", forHTTPHeaderField: "User-Agent")
        if let rangeBytes = probe.rangeBytes, rangeBytes > 0 {
            request.setValue("bytes=0-\(rangeBytes - 1)", forHTTPHeaderField: "Range")
        }

        let delegate = MetricsDelegate()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.allowsCellularAccess = allowsCellularAccess
        sessionConfiguration.waitsForConnectivity = true
        sessionConfiguration.timeoutIntervalForRequest = probe.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = probe.timeoutSeconds
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(started) * 1_000
            session.finishTasksAndInvalidate()
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode
            let policyResponse = statusCode.map(probe.policyStatusCodes.contains) ?? false
            let normalStatus = statusCode.map { (200...399).contains($0) } ?? false
            var result = HTTPProbeResult(
                name: probe.name,
                url: probe.url,
                success: (normalStatus && data.count >= probe.minimumBytes) || policyResponse,
                classification: policyResponse ? "policy_response" : normalStatus ? "ok" : "http_error",
                statusCode: statusCode,
                bytes: data.count,
                elapsedMilliseconds: elapsed,
                metrics: delegate.snapshot(elapsedMilliseconds: elapsed),
                resourceRequested: 0,
                resourceSucceeded: 0,
                resourceSuccessPercent: nil,
                bodySHA256: sha256Hex(data),
                normalizedContentSHA256: nil,
                contentTokenCount: 0,
                contentTokenHashes: [],
                resourceManifestSHA256: nil,
                resourceURLHashes: [],
                error: nil
            )
            if let text = decodedResponseText(data, response: httpResponse) {
                let fingerprint = contentFingerprint(text)
                result.normalizedContentSHA256 = fingerprint.sha256
                result.contentTokenCount = fingerprint.tokenCount
                result.contentTokenHashes = fingerprint.tokenHashes
            }
            if normalStatus, data.count < probe.minimumBytes {
                result.success = false
                result.classification = "short_response"
                result.error = "received \(data.count) bytes, expected at least \(probe.minimumBytes)"
            } else if !normalStatus, !policyResponse {
                result.error = "HTTP \(statusCode.map(String.init) ?? "unknown")"
            }
            if normalStatus, probe.resourceSampleLimit > 0,
               let html = decodedResponseText(data, response: httpResponse)
            {
                let resources = resourceURLs(
                    in: html,
                    baseURL: url,
                    limit: probe.resourceSampleLimit
                )
                let normalizedResources = resources.map(normalizedResourceURL).sorted()
                result.resourceManifestSHA256 = sha256Hex(
                    Data(normalizedResources.joined(separator: "\n").utf8)
                )
                result.resourceURLHashes = normalizedResources.map {
                    String(sha256Hex(Data($0.utf8)).prefix(16))
                }
                result.resourceRequested = resources.count
                for resourceURL in resources {
                    if await resourceSucceeded(
                        resourceURL,
                        timeout: probe.timeoutSeconds,
                        allowsCellularAccess: allowsCellularAccess
                    ) {
                        result.resourceSucceeded += 1
                    }
                }
                if result.resourceRequested > 0 {
                    result.resourceSuccessPercent =
                        Double(result.resourceSucceeded) / Double(result.resourceRequested) * 100
                }
            }
            return result
        } catch {
            session.invalidateAndCancel()
            let elapsed = Date().timeIntervalSince(started) * 1_000
            return HTTPProbeResult(
                name: probe.name,
                url: probe.url,
                success: false,
                classification: classify(error),
                statusCode: nil,
                bytes: 0,
                elapsedMilliseconds: elapsed,
                metrics: delegate.snapshot(elapsedMilliseconds: elapsed),
                resourceRequested: 0,
                resourceSucceeded: 0,
                resourceSuccessPercent: nil,
                bodySHA256: nil,
                normalizedContentSHA256: nil,
                contentTokenCount: 0,
                contentTokenHashes: [],
                resourceManifestSHA256: nil,
                resourceURLHashes: [],
                error: error.localizedDescription
            )
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodedResponseText(
        _ data: Data,
        response: HTTPURLResponse?
    ) -> String? {
        let declaredEncoding: String.Encoding? = response?.textEncodingName.flatMap {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding($0 as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
        var encodings = [declaredEncoding, .utf8, .windowsCP1251, .isoLatin1].compactMap { $0 }
        var seen = Set<UInt>()
        encodings.removeAll { !seen.insert($0.rawValue).inserted }
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static func contentFingerprint(
        _ text: String
    ) -> (sha256: String, tokenCount: Int, tokenHashes: [String]) {
        var normalized = text
        let patterns = [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?s)<[^>]+>"#,
            #"&(?:[a-zA-Z]+|#\d+|#x[0-9a-fA-F]+);"#,
        ]
        for pattern in patterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        normalized = normalized.lowercased().replacingOccurrences(
            of: #"\d+"#,
            with: "#",
            options: .regularExpression
        )
        let tokens = normalized.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ).filter { $0.count >= 2 }
        let ordered = tokens.joined(separator: " ")
        let hashes = Set(tokens.map { token in
            String(sha256Hex(Data(token.utf8)).prefix(16))
        }).sorted().prefix(512)
        return (
            sha256: sha256Hex(Data(ordered.utf8)),
            tokenCount: tokens.count,
            tokenHashes: Array(hashes)
        )
    }

    private static func normalizedResourceURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func resourceURLs(in html: String, baseURL: URL, limit: Int) -> [URL] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:src|href)\s*=\s*[\"']([^\"'#]+)[\"']"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var urls: [URL] = []
        var seen = Set<String>()
        for match in expression.matches(in: html, range: range) {
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: html)
            else { continue }
            let value = String(html[valueRange])
            guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { continue }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
            if urls.count >= limit { break }
        }
        return urls
    }

    private static func resourceSucceeded(
        _ url: URL,
        timeout: Double,
        allowsCellularAccess: Bool
    ) async -> Bool {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
            return (200...399).contains(status) && !data.isEmpty
        } catch {
            return false
        }
    }

    private static func runPlaybackProbe(
        _ probe: Configuration.PlaybackProbe
    ) async -> PlaybackProbeResult {
        guard let url = URL(string: probe.url) else {
            return PlaybackProbeResult(
                name: probe.name,
                url: probe.url,
                success: false,
                elapsedMilliseconds: 0,
                initialTime: nil,
                finalTime: nil,
                advanceSeconds: nil,
                readyState: nil,
                videoHeight: nil,
                error: "invalid URL"
            )
        }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 260), configuration: configuration)
        // A nearly transparent WKWebView can be treated as non-visible and
        // media playback remains at readyState=0 even on unrestricted Wi-Fi.
        // Keep the muted player visible while the probe runs so the baseline
        // measures the service rather than WebKit visibility throttling.
        webView.alpha = 1
        let container = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
        container?.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        let adapter = probe.adapter ?? "html_video"
        let started = Date()
        switch adapter {
        case "youtube_iframe":
            guard let playbackURL = youtubePlaybackURL(url) else {
                return failedPlaybackProbe(probe, error: "invalid YouTube video URL")
            }
            webView.customUserAgent =
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 "
                + "Mobile/15E148 Safari/604.1"
            var request = URLRequest(
                url: playbackURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
            )
            // YouTube error 152-4 is returned when an embedded player request
            // has no HTTP Referer. loadHTMLString(baseURL:) still has an opaque
            // document origin, so load the embed directly and provide the
            // public YouTube origin explicitly.
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            webView.load(request)
        case "twitch_embed":
            guard let document = twitchPlaybackDocument(url: url) else {
                return failedPlaybackProbe(probe, error: "invalid Twitch channel URL")
            }
            webView.loadHTMLString(document, baseURL: URL(string: "https://player.twitch.tv/"))
        default:
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        }
        let loadDeadline = Date().addingTimeInterval(probe.timeoutSeconds)
        while Date() < loadDeadline {
            if !webView.isLoading,
               (try? await evaluateJavaScript("document.readyState", in: webView) as? String) == "complete"
            {
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let bootstrap = probe.bootstrapJavaScript, !bootstrap.isEmpty {
            _ = try? await evaluateJavaScript(bootstrap, in: webView)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let htmlVideoSampleScript = #"""
        (() => {
          const video = document.querySelector('video');
          if (!video) return null;
          video.muted = true;
          video.play().catch(() => {});
          return JSON.stringify({
            currentTime: Number(video.currentTime || 0),
            readyState: Number(video.readyState || 0),
            videoHeight: Number(video.videoHeight || 0),
            paused: Boolean(video.paused)
          });
        })()
        """#
        let youtubeSampleScript = #"""
        (() => {
          const player = document.getElementById('movie_player');
          const video = document.querySelector('video');
          if (!player && !video) return null;
          try { if (video) { video.muted = true; video.play().catch(() => {}); } } catch (_) {}
          try { if (player) { player.mute(); player.playVideo(); } } catch (_) {}
          const state = Number(player && player.getPlayerState ? player.getPlayerState() : (video && !video.paused ? 1 : -1));
          const quality = String(player && player.getPlaybackQuality ? player.getPlaybackQuality() : '');
          const heights = {tiny:144, small:240, medium:360, large:480, hd720:720, hd1080:1080, highres:1440};
          const loaded = Number(player && player.getVideoLoadedFraction ? player.getVideoLoadedFraction() : (video && video.readyState >= 2 ? 1 : 0));
          return JSON.stringify({
            currentTime: Number(player && player.getCurrentTime ? player.getCurrentTime() : (video ? video.currentTime : 0)) || 0,
            readyState: Number(video ? video.readyState : (state === 1 ? 4 : (loaded > 0 ? 2 : 0))),
            videoHeight: Number(video && video.videoHeight ? video.videoHeight : (heights[quality] || 0)),
            paused: state !== 1
          });
        })()
        """#
        let twitchSampleScript = #"""
        (() => {
          const player = window.wltPlayer;
          if (!player || typeof player.getCurrentTime !== 'function') return null;
          try { player.setMuted(true); player.play(); } catch (_) {}
          const current = Number(player.getCurrentTime() || 0);
          const paused = typeof player.isPaused === 'function' ? Boolean(player.isPaused()) : current <= 0;
          const quality = String(typeof player.getQuality === 'function' ? player.getQuality() : '');
          const match = quality.match(/(\d{3,4})p/);
          return JSON.stringify({
            currentTime: current,
            readyState: paused ? (current > 0 ? 2 : 0) : 4,
            videoHeight: match ? Number(match[1]) : 0,
            paused: paused
          });
        })()
        """#
        let sampleScript = switch adapter {
        case "youtube_iframe": youtubeSampleScript
        case "twitch_embed": twitchSampleScript
        default: htmlVideoSampleScript
        }

        var firstState: PlaybackState?
        var lastState: PlaybackState?
        let observationDeadline = Date().addingTimeInterval(probe.observationSeconds)
        while Date() < observationDeadline {
            if let value = try? await evaluateJavaScript(sampleScript, in: webView) as? String,
               let data = value.data(using: .utf8),
               let state = try? JSONDecoder().decode(PlaybackState.self, from: data)
            {
                if firstState == nil { firstState = state }
                lastState = state
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let elapsed = Date().timeIntervalSince(started) * 1_000
        let advance = if let firstState, let lastState {
            lastState.currentTime - firstState.currentTime
        } else {
            nil as Double?
        }
        let success = (advance ?? 0) >= probe.minimumAdvanceSeconds
            && (lastState?.readyState ?? 0) >= 2
        return PlaybackProbeResult(
            name: probe.name,
            url: probe.url,
            success: success,
            elapsedMilliseconds: elapsed,
            initialTime: firstState?.currentTime,
            finalTime: lastState?.currentTime,
            advanceSeconds: advance,
            readyState: lastState?.readyState,
            videoHeight: lastState?.videoHeight,
            error: success ? nil : firstState == nil
                ? (adapter == "html_video" ? "video element not found" : "player state unavailable")
                : "playback did not advance"
        )
    }

    private static func failedPlaybackProbe(
        _ probe: Configuration.PlaybackProbe,
        error: String
    ) -> PlaybackProbeResult {
        PlaybackProbeResult(
            name: probe.name,
            url: probe.url,
            success: false,
            elapsedMilliseconds: 0,
            initialTime: nil,
            finalTime: nil,
            advanceSeconds: nil,
            readyState: nil,
            videoHeight: nil,
            error: error
        )
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return encoded
    }

    private static func youtubePlaybackURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        func set(_ name: String, _ value: String) {
            queryItems.removeAll(where: { $0.name == name })
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        set("autoplay", "1")
        set("mute", "1")
        set("playsinline", "1")
        set("enablejsapi", "1")
        set("origin", "https://www.youtube.com")
        components.queryItems = queryItems
        return components.url
    }

    private static func twitchPlaybackDocument(url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let channel = components?.queryItems?.first(where: { $0.name == "channel" })?.value
        guard let channel, !channel.isEmpty else { return nil }
        let encodedChannel = javaScriptString(channel)
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,#player{width:100%;height:100%;margin:0;background:#000}</style>
        <script src="https://player.twitch.tv/js/embed/v1.js"></script>
        </head><body><div id="player"></div><script>
        window.wltPlayer = new Twitch.Player('player', {
          channel: \(encodedChannel), parent: ['player.twitch.tv'],
          width: 390, height: 260, autoplay: true, muted: true
        });
        window.wltPlayer.addEventListener(Twitch.Player.READY, function() {
          try { window.wltPlayer.setMuted(true); window.wltPlayer.play(); } catch (_) {}
        });
        </script></body></html>
        """
    }

    private static func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private static func networkSnapshot(timeout: Double) async -> NetworkSnapshot? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "pro.2b2n.vpn.headless.network-path")
        monitor.start(queue: queue)
        defer { monitor.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let path = monitor.currentPath
            if path.status == .satisfied {
                return NetworkSnapshot(
                    status: "satisfied",
                    wifi: path.usesInterfaceType(.wifi),
                    cellular: path.usesInterfaceType(.cellular),
                    expensive: path.isExpensive,
                    constrained: path.isConstrained,
                    radioTechnology: currentRadioTechnology()
                )
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return NetworkSnapshot(
            status: "unavailable",
            wifi: false,
            cellular: false,
            expensive: false,
            constrained: false,
            radioTechnology: currentRadioTechnology()
        )
    }

    private static func currentRadioTechnology() -> String? {
        let info = CTTelephonyNetworkInfo()
        return info.serviceCurrentRadioAccessTechnology?.values.sorted().first
    }

    private static func requireTransport(_ snapshot: NetworkSnapshot?, expected: String) throws {
        guard let snapshot, snapshot.status == "satisfied" else {
            throw scenarioError("NWPath is not satisfied")
        }
        if expected == "wifi" {
            guard snapshot.wifi else {
                throw scenarioError(
                    "expected wifi=true, got wifi=\(snapshot.wifi) cellular=\(snapshot.cellular)"
                )
            }
            return
        }
        guard !snapshot.wifi, snapshot.cellular else {
            throw scenarioError(
                "expected wifi=false cellular=true, got wifi=\(snapshot.wifi) cellular=\(snapshot.cellular)"
            )
        }
        let acceptedRadioTechnologies: Set<String> = [
            CTRadioAccessTechnologyLTE,
            CTRadioAccessTechnologyNR,
            CTRadioAccessTechnologyNRNSA,
        ]
        guard let radio = snapshot.radioTechnology,
              acceptedRadioTechnologies.contains(radio)
        else {
            throw scenarioError(
                "cellular path is not LTE/5G: \(snapshot.radioTechnology ?? "unknown")"
            )
        }
    }

    private static func exportServiceLog(_ environments: ExtensionEnvironments) async {
        environments.connect()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let text = environments.commandClient.logList.map(\.message).joined(separator: "\n")
        try? text.write(
            to: FilePath.cacheDirectory.appendingPathComponent(serviceLogFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func collectClassifications(
        _ route: RouteResult,
        vpnMode: String,
        into result: inout Result
    ) {
        if let error = route.infrastructureError {
            result.infrastructureFailures.append("route_\(route.route): \(error)")
            return
        }
        func recordFailure(_ message: String) {
            if vpnMode == "wlt" {
                result.transportRejects.append(message)
            } else {
                result.baselineFailures.append(message)
            }
        }
        for probe in route.httpProbes {
            if probe.classification == "policy_response" {
                result.policyResponses.append("\(probe.name): HTTP \(probe.statusCode ?? 0)")
            } else if !probe.success {
                recordFailure(
                    "\(probe.name): \(probe.classification) \(probe.error ?? "")"
                )
            }
        }
        for probe in route.playbackProbes where !probe.success {
            recordFailure(
                "\(probe.name): playback_stalled \(probe.error ?? "")"
            )
        }
        if let error = route.error,
           route.httpProbes.isEmpty,
           route.playbackProbes.isEmpty
        {
            recordFailure("route_\(route.route): \(error)")
        }
    }

    private static func failedHTTPProbe(
        _ probe: Configuration.HTTPProbe,
        classification: String,
        error: String
    ) -> HTTPProbeResult {
        HTTPProbeResult(
            name: probe.name,
            url: probe.url,
            success: false,
            classification: classification,
            statusCode: nil,
            bytes: 0,
            elapsedMilliseconds: 0,
            metrics: nil,
            resourceRequested: 0,
            resourceSucceeded: 0,
            resourceSuccessPercent: nil,
            bodySHA256: nil,
            normalizedContentSHA256: nil,
            contentTokenCount: 0,
            contentTokenHashes: [],
            resourceManifestSHA256: nil,
            resourceURLHashes: [],
            error: error
        )
    }

    private static func classify(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "transport_error" }
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "timeout"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "dns_error"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorClientCertificateRejected:
            return "tls_error"
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return "connect_error"
        default:
            return "url_error_\(nsError.code)"
        }
    }

    private static func write(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result) else { return }
        try? data.write(
            to: FilePath.cacheDirectory.appendingPathComponent(resultFileName),
            options: .atomic
        )
    }

    private static func scenarioError(_ message: String) -> NSError {
        NSError(
            domain: "WLTHeadlessScenario",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

#endif
