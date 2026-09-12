#if SFI_DEV
import Darwin
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
        let profileName: String?
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
            if action == .selectProfile {
                guard
                    let name = components.queryItems?
                        .first(where: { $0.name == "name" })?.value,
                    !name.isEmpty,
                    name.count <= 128
                else {
                    return nil
                }
                profileName = name
            } else {
                profileName = nil
            }
            if action == .soak {
                guard
                    let durationValue = components.queryItems?
                        .first(where: { $0.name == "duration" })?.value,
                    let intervalValue = components.queryItems?
                        .first(where: { $0.name == "interval" })?.value,
                    let duration = Int(durationValue),
                    let interval = Int(intervalValue),
                    (5...3_600).contains(duration),
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
        case upsertProfile = "upsert-profile"
        case exportProfile = "export-profile"
        case exportState = "export-state"
        case ping
        case probe
        case refreshProfile = "refresh-profile"
        case selectProfile = "select-profile"
        case assertMergedProfile = "assert-merged-profile"
        case importIdentityRing = "import-identity-ring"
        case identityRingStatus = "identity-ring-status"
        case armIdentityRingFault = "arm-identity-ring-fault"
        case start
        case startProbe = "start-probe"
        case status
        case groupStatus = "group-status"
        case routeDiagnostics = "route-diagnostics"
        case stop
        case soak
        case workload
        case networkWorkload = "network-workload"
        case explicitSavedWLTOutboundReachability = "explicit_saved_WLT_outbound_reachability"
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

    private struct ExplicitWLTPlan: Decodable {
        let schema: Int
        let scope: String
        let requests: [ExplicitWLTProbeRequest]
    }

    private struct ExplicitWLTProfileBinding {
        let selectedID: Int64
        let path: String
        let mainSHA256: String
        let lastKnownGoodPath: String
        let lastKnownGoodSHA256: String?
    }

    private struct ExplicitWLTProbeRequest: Codable {
        let schema: Int
        let probeID: String
        let kind: String
        let groupTag: String
        let outboundTag: String
        let wltTag: String
        let timeoutMS: Int
        let server: String?
        let queryName: String?
        let url: String?
        let expectedStatus: Int?
        let expectedBytes: Int?
        let maxReadBytes: Int?

        enum CodingKeys: String, CodingKey {
            case schema, kind, server, url
            case probeID = "probe_id"
            case groupTag = "group_tag"
            case outboundTag = "outbound_tag"
            case wltTag = "wlt_tag"
            case timeoutMS = "timeout_ms"
            case queryName = "query_name"
            case expectedStatus = "expected_status"
            case expectedBytes = "expected_bytes"
            case maxReadBytes = "max_read_bytes"
        }
    }

    private struct ExplicitWLTProbeResult: Codable {
        let schema: Int
        let scope: String
        let probeID: String
        let kind: String
        let status: String
        let errorCode: String
        let groupTag: String
        let outboundTag: String
        let wltTag: String
        let network: String
        let attempt: String
        let fallbackAttempted: Bool
        let selectionTouched: Bool
        let profileTouched: Bool
        let instanceCurrent: Bool
        let durationMS: Int
        let requestSHA256: String
        let httpStatus: Int?
        let bytesRead: Int?
        let destinationSHA256: String?
        let dnsRcode: Int?
        let dnsAnswerCount: Int?
        let dnsQuestionSHA256: String?
        let dnsServerSHA256: String?

        enum CodingKeys: String, CodingKey {
            case schema, scope, kind, status, network, attempt
            case probeID = "probe_id"
            case errorCode = "error_code"
            case groupTag = "group_tag"
            case outboundTag = "outbound_tag"
            case wltTag = "wlt_tag"
            case fallbackAttempted = "fallback_attempted"
            case selectionTouched = "selection_touched"
            case profileTouched = "profile_touched"
            case instanceCurrent = "instance_current"
            case durationMS = "duration_ms"
            case requestSHA256 = "request_sha256"
            case httpStatus = "http_status"
            case bytesRead = "bytes_read"
            case destinationSHA256 = "destination_sha256"
            case dnsRcode = "dns_rcode"
            case dnsAnswerCount = "dns_answer_count"
            case dnsQuestionSHA256 = "dns_question_sha256"
            case dnsServerSHA256 = "dns_server_sha256"
        }
    }

    private struct WorkloadTransactionMetrics: Codable, Sendable {
        let resourceFetchType: String
        let networkProtocolName: String?
        let responseStatusCode: Int?
        let proxyConnection: Bool
        let reusedConnection: Bool
        let cellular: Bool
        let expensive: Bool
        let constrained: Bool
        let multipath: Bool
        let domainLookupMS: Int64?
        let connectMS: Int64?
        let secureConnectionMS: Int64?
        let requestMS: Int64?
        let ttfbAfterRequestMS: Int64?
        let bodyMS: Int64?
        let fetchToFirstByteMS: Int64?
        let fetchToEndMS: Int64?
        let requestHeaderBytesSent: Int64
        let requestBodyBytesSent: Int64
        let requestBodyBytesBeforeEncoding: Int64
        let responseHeaderBytesReceived: Int64
        let responseBodyBytesReceived: Int64
        let responseBodyBytesAfterDecoding: Int64

        enum CodingKeys: String, CodingKey {
            case resourceFetchType = "resource_fetch_type"
            case networkProtocolName = "network_protocol_name"
            case responseStatusCode = "response_status_code"
            case proxyConnection = "proxy_connection"
            case reusedConnection = "reused_connection"
            case cellular, expensive, constrained, multipath
            case domainLookupMS = "domain_lookup_ms"
            case connectMS = "connect_ms"
            case secureConnectionMS = "secure_connection_ms"
            case requestMS = "request_ms"
            case ttfbAfterRequestMS = "ttfb_after_request_ms"
            case bodyMS = "body_ms"
            case fetchToFirstByteMS = "fetch_to_first_byte_ms"
            case fetchToEndMS = "fetch_to_end_ms"
            case requestHeaderBytesSent = "request_header_bytes_sent"
            case requestBodyBytesSent = "request_body_bytes_sent"
            case requestBodyBytesBeforeEncoding = "request_body_bytes_before_encoding"
            case responseHeaderBytesReceived = "response_header_bytes_received"
            case responseBodyBytesReceived = "response_body_bytes_received"
            case responseBodyBytesAfterDecoding = "response_body_bytes_after_decoding"
        }

        init(_ metrics: URLSessionTaskTransactionMetrics) {
            resourceFetchType = switch metrics.resourceFetchType {
            case .networkLoad: "network_load"
            case .serverPush: "server_push"
            case .localCache: "local_cache"
            case .unknown: "unknown"
            @unknown default: "unknown"
            }
            networkProtocolName = metrics.networkProtocolName
            responseStatusCode = (metrics.response as? HTTPURLResponse)?.statusCode
            proxyConnection = metrics.isProxyConnection
            reusedConnection = metrics.isReusedConnection
            cellular = metrics.isCellular
            expensive = metrics.isExpensive
            constrained = metrics.isConstrained
            multipath = metrics.isMultipath
            domainLookupMS = Self.durationMS(
                from: metrics.domainLookupStartDate,
                to: metrics.domainLookupEndDate
            )
            // URLSession's connect interval contains the secure-connection
            // interval when TLS is negotiated. These values overlap and must
            // not be added together.
            connectMS = Self.durationMS(
                from: metrics.connectStartDate,
                to: metrics.connectEndDate
            )
            secureConnectionMS = Self.durationMS(
                from: metrics.secureConnectionStartDate,
                to: metrics.secureConnectionEndDate
            )
            requestMS = Self.durationMS(
                from: metrics.requestStartDate,
                to: metrics.requestEndDate
            )
            // TTFB starts after the request upload has ended. It still
            // includes server processing and path latency.
            ttfbAfterRequestMS = Self.durationMS(
                from: metrics.requestEndDate,
                to: metrics.responseStartDate
            )
            // data(for:) buffers the full body, so this is the client-observed
            // span from the first response byte through the last response byte.
            bodyMS = Self.durationMS(
                from: metrics.responseStartDate,
                to: metrics.responseEndDate
            )
            fetchToFirstByteMS = Self.durationMS(
                from: metrics.fetchStartDate,
                to: metrics.responseStartDate
            )
            fetchToEndMS = Self.durationMS(
                from: metrics.fetchStartDate,
                to: metrics.responseEndDate
            )
            requestHeaderBytesSent = Int64(metrics.countOfRequestHeaderBytesSent)
            requestBodyBytesSent = Int64(metrics.countOfRequestBodyBytesSent)
            requestBodyBytesBeforeEncoding = Int64(metrics.countOfRequestBodyBytesBeforeEncoding)
            responseHeaderBytesReceived = Int64(metrics.countOfResponseHeaderBytesReceived)
            responseBodyBytesReceived = Int64(metrics.countOfResponseBodyBytesReceived)
            responseBodyBytesAfterDecoding = Int64(metrics.countOfResponseBodyBytesAfterDecoding)
        }

        private static func durationMS(from start: Date?, to end: Date?) -> Int64? {
            guard let start, let end else {
                return nil
            }
            let duration = end.timeIntervalSince(start)
            guard duration >= 0 else {
                return nil
            }
            return Int64((duration * 1_000).rounded())
        }
    }

    private struct WorkloadTaskMetrics: Codable, Sendable {
        let schema: Int
        let scope: String
        let taskIntervalMS: Int64
        let redirectCount: Int
        let connectDurationIncludesSecureConnection: Bool
        let internalTunnelPhasesVisible: Bool
        let transactions: [WorkloadTransactionMetrics]

        enum CodingKeys: String, CodingKey {
            case schema, scope, transactions
            case taskIntervalMS = "task_interval_ms"
            case redirectCount = "redirect_count"
            case connectDurationIncludesSecureConnection = "connect_duration_includes_secure_connection"
            case internalTunnelPhasesVisible = "internal_tunnel_phases_visible"
        }

        init(_ metrics: URLSessionTaskMetrics) {
            schema = 1
            scope = "urlsession_client"
            taskIntervalMS = Int64((metrics.taskInterval.duration * 1_000).rounded())
            redirectCount = metrics.redirectCount
            connectDurationIncludesSecureConnection = true
            internalTunnelPhasesVisible = false
            // Keep every transaction so redirects and their independent
            // connection/cache behavior are not collapsed into one total.
            transactions = metrics.transactionMetrics.map(WorkloadTransactionMetrics.init)
        }
    }

    private final class WorkloadMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var capturedMetrics: WorkloadTaskMetrics?

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            let captured = WorkloadTaskMetrics(metrics)
            lock.lock()
            defer { lock.unlock() }
            capturedMetrics = captured
        }

        func snapshot() -> WorkloadTaskMetrics? {
            lock.lock()
            defer { lock.unlock() }
            return capturedMetrics
        }
    }

    private struct WorkloadProbeResult: Codable {
        let name: String
        let success: Bool
        let classification: String
        let statusCode: Int
        let elapsedMS: Int64
        let bytesRead: Int
        let taskMetricsStatus: String
        let taskMetrics: WorkloadTaskMetrics?
        let errorDomain: String?
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case name, success, classification
            case statusCode = "status_code"
            case elapsedMS = "elapsed_ms"
            case bytesRead = "bytes_read"
            case taskMetricsStatus = "task_metrics_status"
            case taskMetrics = "task_metrics"
            case errorDomain = "error_domain"
            case errorCode = "error_code"
        }
    }

    private struct WorkloadOutcome {
        let route: String
        let probes: [WorkloadProbeResult]
    }

    private struct GroupSelection: Codable, Sendable {
        let tag: String
        let selected: String
        let available: [String]
    }

    private struct RouteDiagnostics: Codable, Sendable {
        let instagramFamily: [String: Int]
        let metaFamily: [String: Int]
        let tiktokFamily: [String: Int]
        let youtubeFamily: [String: Int]
        let githubFamily: [String: Int]
        let neutralExample: [String: Int]

        enum CodingKeys: String, CodingKey {
            case instagramFamily = "instagram-family"
            case metaFamily = "meta-family"
            case tiktokFamily = "tiktok-family"
            case youtubeFamily = "youtube-family"
            case githubFamily = "github-family"
            case neutralExample = "neutral-example"
        }
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
        let explicitSavedWLTOutboundReachability: [ExplicitWLTProbeResult]?
        let groupSelections: [GroupSelection]?
        let routeDiagnostics: RouteDiagnostics?
        let routeDiagnosticsScope: String?
        let transportCounters: [String: Int64]?
        let identityRing: IdentityRingStatus?
        let identityRingImport: IdentityRingImportStatus?
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
            case explicitSavedWLTOutboundReachability = "explicit_saved_WLT_outbound_reachability"
            case groupSelections = "group_selections"
            case routeDiagnostics = "route_diagnostics"
            case routeDiagnosticsScope = "route_diagnostics_scope"
            case transportCounters = "transport_counters"
            case identityRing = "identity_ring"
            case identityRingImport = "identity_ring_import"
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
        let bootstrapConsumed: Bool

        enum CodingKeys: String, CodingKey {
            case version
            case activePresent = "active_present"
            case previousPresent = "previous_present"
            case reservePresent = "reserve_present"
            case quarantinePresent = "quarantine_present"
            case faultArmed = "fault_armed"
            case bootstrapConsumed = "bootstrap_consumed"
        }
    }

    private struct IdentityRingImportStatus: Codable {
        let identities: Int
        let independent: Bool
        let validated: Bool
        let staleStateCleared: Bool
        let transferInputsDeleted: Bool

        enum CodingKeys: String, CodingKey {
            case identities, independent, validated
            case staleStateCleared = "stale_state_cleared"
            case transferInputsDeleted = "transfer_inputs_deleted"
        }
    }

    private struct NetworkSnapshot: Codable {
        let status: String
        let cellular: Bool
        let wifi: Bool
        let radioTechnology: String
        let radioTechnologies: [String]
        let radioTechnologySource: String
        let cellularServiceCount: Int
        let dataServiceIDHash: String?

        enum CodingKeys: String, CodingKey {
            case status
            case cellular
            case wifi
            case radioTechnology = "radio_technology"
            case radioTechnologies = "radio_technologies"
            case radioTechnologySource = "radio_technology_source"
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
        let explicitSavedWLTOutboundReachability: [ExplicitWLTProbeResult]?
        let groupSelections: [GroupSelection]?
        let routeDiagnostics: RouteDiagnostics?
        let routeDiagnosticsScope: String?
        let transportCounters: [String: Int64]?
        let identityRing: IdentityRingStatus?
        let identityRingImport: IdentityRingImportStatus?

        init(
            status: NEVPNStatus?,
            vpnStartupMS: Int64?,
            probeElapsedMS: Int64?,
            soak: SoakOutcome?,
            runtimeParameters: WhitelistTransportConfig.RuntimeParameters?,
            workload: WorkloadOutcome? = nil,
            explicitSavedWLTOutboundReachability: [ExplicitWLTProbeResult]? = nil,
            groupSelections: [GroupSelection]? = nil,
            routeDiagnostics: RouteDiagnostics? = nil,
            routeDiagnosticsScope: String? = nil,
            transportCounters: [String: Int64]? = nil,
            identityRing: IdentityRingStatus? = nil,
            identityRingImport: IdentityRingImportStatus? = nil
        ) {
            self.status = status
            self.vpnStartupMS = vpnStartupMS
            self.probeElapsedMS = probeElapsedMS
            self.soak = soak
            self.runtimeParameters = runtimeParameters
            self.workload = workload
            self.explicitSavedWLTOutboundReachability = explicitSavedWLTOutboundReachability
            self.groupSelections = groupSelections
            self.routeDiagnostics = routeDiagnostics
            self.routeDiagnosticsScope = routeDiagnosticsScope
            self.transportCounters = transportCounters
            self.identityRing = identityRing
            self.identityRingImport = identityRingImport
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
        case identityRingImportRequiresStoppedVPN = 18
        case identityRingImportInvalid = 19
        case identityRingImportValidationFailed = 20
        case identityRingImportInstallFailed = 21
        case transportCountersUnavailable = 22
        case mergedProfileContractFailed = 23
        case stateExportRequiresStoppedVPN = 24
        case stateExportInvalidProfilePath = 25
        case stateExportChangedDuringCapture = 26
        case invalidExplicitWLTPlan = 27
        case explicitWLTProfileGraphMismatch = 28
        case explicitWLTResultInvalid = 29
    }

    private var isRunning = false

    func execute(_ request: Request) async {
        let receivedAt = unixMilliseconds()
        let candidateURL = runtimeCandidateURL(request.id)
        let workloadURL = workloadPlanURL(request.id)
        let profileURL = profilePlanURL(request.id)
        let exportURL = profileExportURL(request.id)
        let stateExportURL = stateExportURL(request.id)
        let identityRingImportURLs = identityRingImportURLs(request.id)
        guard !isRunning else {
            try? FileManager.default.removeItem(at: candidateURL)
            try? FileManager.default.removeItem(at: workloadURL)
            try? FileManager.default.removeItem(at: profileURL)
            identityRingImportURLs.forEach { try? FileManager.default.removeItem(at: $0) }
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
        case .bootstrapProfile, .upsertProfile, .start, .startProbe, .stop, .soak, .workload,
             .networkWorkload, .explicitSavedWLTOutboundReachability:
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
        pruneStateExports(excluding: stateExportURL)
        pruneIdentityRingImports(excluding: identityRingImportURLs)
        defer { try? FileManager.default.removeItem(at: candidateURL) }
        defer { try? FileManager.default.removeItem(at: workloadURL) }
        defer { try? FileManager.default.removeItem(at: profileURL) }
        defer { identityRingImportURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        var loadedRuntimeParameters: WhitelistTransportConfig.RuntimeParameters?
        do {
            let runtimeParameters = try loadRuntimeCandidate(
                for: request.action,
                at: candidateURL
            )
            loadedRuntimeParameters = runtimeParameters
            let workloadPlan = try loadWorkloadPlan(
                for: request.action,
                at: workloadURL
            )
            let explicitWLTPlan = try loadExplicitWLTPlan(
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
                profilePlan: profilePlan,
                explicitWLTPlan: explicitWLTPlan
            )
            let networkFinal = await captureNetworkSnapshot()
            let workloadSucceeded = outcome.workload?.probes.allSatisfy(\.success) ?? true
            let explicitWLTSucceeded = outcome.explicitSavedWLTOutboundReachability?
                .allSatisfy { $0.status == "success" } ?? true
            writeResult(
                request: request,
                receivedAt: receivedAt,
                state: workloadSucceeded && explicitWLTSucceeded ? "succeeded" : "failed",
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
                outcome: loadedRuntimeParameters.map {
                    Outcome(
                        status: currentStatus,
                        vpnStartupMS: nil,
                        probeElapsedMS: nil,
                        soak: nil,
                        runtimeParameters: $0
                    )
                },
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
        profilePlan: ProfilePlan?,
        explicitWLTPlan: ExplicitWLTPlan?
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
        if action == .selectProfile {
            guard let requestedName = request.profileName else {
                throw ControlError.invalidProfilePlan
            }
            guard let extensionProfile = try await ExtensionProfile.load() else {
                throw ControlError.networkExtensionNotInstalled
            }
            await extensionProfile.register()
            let status = await extensionProfile.status
            guard status == .disconnected || status == .invalid else {
                throw ControlError.unexpectedStatus
            }
            let normalized = requestedName.lowercased().filter { $0.isLetter || $0.isNumber }
            let matches = try await ProfileManager.list().filter {
                $0.name.lowercased().filter { $0.isLetter || $0.isNumber } == normalized
            }
            guard matches.count == 1 else {
                throw ControlError.selectedProfileUnavailable
            }
            await SharedPreferences.selectedProfileID.set(matches[0].mustID)
            return Outcome(
                status: status,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil
            )
        }
        if action == .assertMergedProfile {
            try await assertSelectedMergedProfile()
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
        if action == .exportState {
            let currentStatus = await loadCurrentStatus()
            guard currentStatus == .disconnected else {
                throw ControlError.stateExportRequiresStoppedVPN
            }
            try await exportState(to: stateExportURL(request.id))
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
        if action == .upsertProfile {
            guard let profilePlan else {
                throw ControlError.invalidProfilePlan
            }
            let installedProfile = try await upsertProfile(profilePlan)
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
        case .bootstrapProfile, .upsertProfile, .exportProfile, .exportState, .selectProfile, .assertMergedProfile:
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
        case .importIdentityRing:
            let currentStatus = await profile.status
            guard currentStatus == .disconnected || currentStatus == .invalid else {
                throw ControlError.identityRingImportRequiresStoppedVPN
            }
            let imported = try await importIdentityRing(request.id)
            return Outcome(
                status: currentStatus,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                identityRing: try loadIdentityRingStatus(),
                identityRingImport: imported
            )
        case .probe:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            let probeStartedAt = unixMilliseconds()
            try await probeTraffic()
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            return Outcome(
                status: .connected,
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
        case .groupStatus:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            let cleanProfile = try await selectedProfileUsesCleanWLT()
            let groupSelections = cleanProfile
                ? try await loadCleanGroupSelections()
                : try await loadMergedGroupSelections()
            return Outcome(
                status: .connected,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                groupSelections: groupSelections,
                routeDiagnostics: cleanProfile ? nil : await loadRouteDiagnostics(),
                // The daemon intentionally omits singleton groups.  For a
                // clean profile, selectedProfileUsesCleanWLT() has already
                // validated the fixed ru/eu -> VLESS leaf composition from
                // the saved profile; runtime group evidence is the exposed
                // root selector and its selected EU member.
                routeDiagnosticsScope: cleanProfile ? "clean_root_selection" : "leaf_selection"
            )
        case .routeDiagnostics:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            return Outcome(
                status: .connected,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                routeDiagnostics: await loadRouteDiagnostics()
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
            var armError: NSError?
            LibboxArmWLTAuthRingTestRejectActiveOnce(wltAuthSnapshotURL().path, &armError)
            if let armError {
                throw armError
            }
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
            // A clean WLT profile has a fixed whitelist-exit selector.  Its
            // first child can be the RU path, while the content gate asks for
            // the EU path immediately afterwards.  Selecting EU only after
            // the first probe creates an avoidable live-path handoff and can
            // surface mux-open errors on the first media workload.  Resolve
            // the clean selector before the initial traffic probe; merged
            // profiles keep their independent urltest groups unchanged.
            if try await selectedProfileUsesCleanWLT() {
                try await selectWorkloadRoute("eu")
            }
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
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            return Outcome(
                status: .connected,
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
            let (workload, transportCounters) = try await runWorkloadWithCounters(workloadPlan)
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            return Outcome(
                status: .connected,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                workload: workload,
                transportCounters: transportCounters
            )
        case .networkWorkload:
            guard let workloadPlan else {
                throw ControlError.invalidWorkload
            }
            let workload = try await runWorkload(workloadPlan)
            return Outcome(
                status: await profile.status,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                workload: workload,
                routeDiagnostics: await loadRouteDiagnostics()
            )
        case .explicitSavedWLTOutboundReachability:
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            guard let explicitWLTPlan else {
                throw ControlError.invalidExplicitWLTPlan
            }
            let results = try await runExplicitSavedWLTOutboundReachability(
                explicitWLTPlan, through: profile
            )
            guard await profile.status == .connected else {
                throw ControlError.probeRequiresConnectedVPN
            }
            return Outcome(
                status: .connected,
                vpnStartupMS: nil,
                probeElapsedMS: nil,
                soak: nil,
                runtimeParameters: nil,
                explicitSavedWLTOutboundReachability: results
            )
        }
    }

    private func wltAuthSnapshotURL() -> URL {
        FilePath.cacheDirectory
            .appendingPathComponent("WLT", isDirectory: true)
            .appendingPathComponent("auth-snapshot.json", isDirectory: false)
    }

    private func identityRingImportURLs(_ requestID: UUID) -> [URL] {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        let prefix = "wlt-test-identity-ring-\(requestID.uuidString.lowercased())"
        return [
            caches.appendingPathComponent("\(prefix)-active.aesgcm"),
            caches.appendingPathComponent("\(prefix)-reserve.aesgcm"),
            caches.appendingPathComponent("\(prefix)-key.base64"),
        ]
    }

    private func importIdentityRing(_ requestID: UUID) async throws -> IdentityRingImportStatus {
        let inputs = identityRingImportURLs(requestID)
        defer { inputs.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard inputs.count == 3 else {
            throw ControlError.identityRingImportInvalid
        }
        let fileManager = FileManager.default
        for (index, input) in inputs.enumerated() {
            let values = try? input.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            let minimumSize = index == 2 ? 40 : 28
            let maximumSize = index == 2 ? 128 : 512 * 1_024
            guard
                values?.isRegularFile == true,
                values?.isSymbolicLink != true,
                let size = values?.fileSize,
                (minimumSize ... maximumSize).contains(size)
            else {
                throw ControlError.identityRingImportInvalid
            }
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: input.path
            )
        }

        let encodedKey = try Data(contentsOf: inputs[2])
        guard
            let encodedKeyString = String(data: encodedKey, encoding: .utf8),
            let keyData = Data(base64Encoded: encodedKeyString.trimmingCharacters(in: .whitespacesAndNewlines)),
            keyData.count == 32
        else {
            throw ControlError.identityRingImportInvalid
        }
        let key = SymmetricKey(data: keyData)
        let active = try decryptIdentityRingSnapshot(at: inputs[0], using: key)
        let reserve = try decryptIdentityRingSnapshot(at: inputs[1], using: key)
        guard identityRingSnapshotsIndependent(active, reserve) else {
            throw ControlError.identityRingImportValidationFailed
        }
        let (carrierConfig, carrierConfigFile) = try await selectedWLTCarrierConfig()
        for snapshot in [active, reserve] {
            guard let snapshotString = String(data: snapshot, encoding: .utf8) else {
                throw ControlError.identityRingImportValidationFailed
            }
            var validationError: NSError?
            LibboxValidateWLTAuthSnapshot(
                carrierConfig,
                carrierConfigFile,
                snapshotString,
                &validationError
            )
            if validationError != nil {
                throw ControlError.identityRingImportValidationFailed
            }
        }

        for input in inputs {
            try fileManager.removeItem(at: input)
        }
        guard inputs.allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) else {
            throw ControlError.identityRingImportInvalid
        }

        let snapshot = wltAuthSnapshotURL()
        let reserveSnapshot = URL(fileURLWithPath: snapshot.path + ".reserve")
        let managed = [
            snapshot,
            URL(fileURLWithPath: snapshot.path + ".previous"),
            reserveSnapshot,
            URL(fileURLWithPath: snapshot.path + ".reserve.previous"),
            URL(fileURLWithPath: snapshot.path + ".quarantine"),
            URL(fileURLWithPath: snapshot.path + ".provider-cooldown"),
            URL(fileURLWithPath: snapshot.path + ".bootstrap-consumed"),
            URL(fileURLWithPath: snapshot.path + ".test-reject-active-once"),
        ]
        let original = try managed.map { url -> (URL, Data?) in
            if fileManager.fileExists(atPath: url.path) {
                return (url, try Data(contentsOf: url))
            }
            return (url, nil)
        }

        do {
            try writeProtectedAtomically(reserve, to: reserveSnapshot)
            try writeProtectedAtomically(active, to: snapshot)
            for stale in managed where stale != snapshot && stale != reserveSnapshot {
                if fileManager.fileExists(atPath: stale.path) {
                    try fileManager.removeItem(at: stale)
                }
            }
            let status = try loadIdentityRingStatus()
            guard status.activePresent, status.reservePresent else {
                throw ControlError.identityRingImportInstallFailed
            }
        } catch {
            for (url, content) in original {
                if let content {
                    try? writeProtectedAtomically(content, to: url)
                } else if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw ControlError.identityRingImportInstallFailed
        }
        return IdentityRingImportStatus(
            identities: 2,
            independent: true,
            validated: true,
            staleStateCleared: true,
            transferInputsDeleted: true
        )
    }

    private func decryptIdentityRingSnapshot(at url: URL, using key: SymmetricKey) throws -> Data {
        let encrypted = try Data(contentsOf: url)
        guard (28 ... 512 * 1_024).contains(encrypted.count) else {
            throw ControlError.identityRingImportInvalid
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)
        } catch {
            throw ControlError.identityRingImportValidationFailed
        }
    }

    private func identityRingSnapshotsIndependent(_ active: Data, _ reserve: Data) -> Bool {
        guard
            let leftRoot = try? JSONSerialization.jsonObject(with: active) as? [String: Any],
            let rightRoot = try? JSONSerialization.jsonObject(with: reserve) as? [String: Any],
            let left = leftRoot["vk"] as? [String: Any],
            let right = rightRoot["vk"] as? [String: Any]
        else {
            return false
        }
        let bearerMode = "bearer_call_token"
        let leftMode = left["calls_auth_mode"] as? String ?? "anonymous_token"
        let rightMode = right["calls_auth_mode"] as? String ?? "anonymous_token"
        let fieldIsDistinct = { (field: String) -> Bool in
            guard
                let leftValue = left[field] as? String,
                let rightValue = right[field] as? String,
                !leftValue.isEmpty,
                !rightValue.isEmpty,
                leftValue != rightValue
            else {
                return false
            }
            return true
        }
        if leftMode == bearerMode && rightMode == bearerMode {
            // Authenticated messages.getCallToken and TURN credentials are
            // stable for an account/app pair. Independence is established by
            // the separate version-3 calls sessions instead.
            return fieldIsDistinct("device_id") && fieldIsDistinct("session_key")
        }
        for field in ["anonym_token", "device_id", "messages_access_token"] {
            guard fieldIsDistinct(field) else {
                return false
            }
        }
        let leftFingerprint = (left["browser_context"] as? [String: Any])?["fingerprint"] as? String
        let rightFingerprint = (right["browser_context"] as? [String: Any])?["fingerprint"] as? String
        return leftFingerprint == nil
            || rightFingerprint == nil
            || leftFingerprint != rightFingerprint
    }

    private func selectedWLTCarrierConfig() async throws -> (String, String) {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw ControlError.selectedProfileUnavailable
        }
        let sharedDirectory = FilePath.sharedDirectory.standardizedFileURL
        let profileURL: URL
        if profile.path.hasPrefix("/") {
            profileURL = URL(fileURLWithPath: profile.path).standardizedFileURL
        } else {
            profileURL = sharedDirectory.appendingPathComponent(profile.path).standardizedFileURL
        }
        guard profileURL.path.hasPrefix(sharedDirectory.path + "/") else {
            throw ControlError.identityRingImportValidationFailed
        }
        let rootData = try Data(contentsOf: profileURL)
        guard
            let root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any],
            let services = root["services"] as? [[String: Any]],
            let service = services.first(where: { $0["type"] as? String == "wlt" }),
            let carrierConfig = service["carrier_config"] as? String,
            !carrierConfig.isEmpty
        else {
            throw ControlError.identityRingImportValidationFailed
        }
        let carrierConfigFile = service["carrier_config_file"] as? String ?? ""
        return (carrierConfig, carrierConfigFile)
    }

    private func assertSelectedMergedProfile() async throws {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw ControlError.selectedProfileUnavailable
        }
        let sharedDirectory = FilePath.sharedDirectory.standardizedFileURL
        let profileURL: URL
        if profile.path.hasPrefix("/") {
            profileURL = URL(fileURLWithPath: profile.path).standardizedFileURL
        } else {
            profileURL = sharedDirectory.appendingPathComponent(profile.path).standardizedFileURL
        }
        guard profileURL.path.hasPrefix(sharedDirectory.path + "/") else {
            throw ControlError.mergedProfileContractFailed
        }
        let data = try Data(contentsOf: profileURL)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let route = root["route"] as? [String: Any],
            route["final"] as? String == "direct_or_wlt-ru",
            let outbounds = root["outbounds"] as? [[String: Any]]
        else {
            throw ControlError.mergedProfileContractFailed
        }
        var byTag: [String: [String: Any]] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, !tag.isEmpty else { continue }
            guard byTag[tag] == nil else { throw ControlError.mergedProfileContractFailed }
            byTag[tag] = outbound
        }
        guard
            byTag["direct_or_wlt-ru"]?["type"] as? String == "urltest",
            byTag["direct_or_wlt-ru"]?["outbounds"] as? [String] == ["direct", "vless-wlt-ru"],
            byTag["direct_or_wlt-ru"]?["prefer_first_available"] as? Bool == true,
            byTag["ru_or_wlt-ru"]?["type"] as? String == "urltest",
            byTag["ru_or_wlt-ru"]?["prefer_first_available"] as? Bool == true,
            byTag["eu_or_wlt-eu"]?["type"] as? String == "urltest",
            byTag["eu_or_wlt-eu"]?["prefer_first_available"] as? Bool == true,
            byTag["direct-always"]?["outbounds"] as? [String] == ["direct"]
        else {
            throw ControlError.mergedProfileContractFailed
        }
    }

    private func selectedProfileUsesCleanWLT() async throws -> Bool {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw ControlError.selectedProfileUnavailable
        }
        let sharedDirectory = FilePath.sharedDirectory.standardizedFileURL
        let profileURL: URL
        if profile.path.hasPrefix("/") {
            profileURL = URL(fileURLWithPath: profile.path).standardizedFileURL
        } else {
            profileURL = sharedDirectory.appendingPathComponent(profile.path).standardizedFileURL
        }
        guard profileURL.path.hasPrefix(sharedDirectory.path + "/") else {
            throw ControlError.mergedProfileContractFailed
        }
        let data = try Data(contentsOf: profileURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = root["route"] as? [String: Any],
              let final = route["final"] as? String else {
            throw ControlError.mergedProfileContractFailed
        }
        guard final == "whitelist-exit" else { return false }
        guard let outbounds = root["outbounds"] as? [[String: Any]] else {
            throw ControlError.mergedProfileContractFailed
        }
        var byTag: [String: [String: Any]] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, !tag.isEmpty, byTag[tag] == nil else {
                throw ControlError.mergedProfileContractFailed
            }
            byTag[tag] = outbound
        }
        guard
            byTag["whitelist-exit"]?["type"] as? String == "selector",
            byTag["whitelist-exit"]?["outbounds"] as? [String] == ["ru", "eu"],
            byTag["ru"]?["type"] as? String == "selector",
            byTag["ru"]?["outbounds"] as? [String] == ["vless-wlt-ru"],
            byTag["eu"]?["type"] as? String == "selector",
            byTag["eu"]?["outbounds"] as? [String] == ["vless-wlt-eu"],
            byTag["vless-wlt-ru"]?["type"] as? String == "vless",
            byTag["vless-wlt-eu"]?["type"] as? String == "vless"
        else {
            throw ControlError.mergedProfileContractFailed
        }
        return true
    }

    private func runExplicitSavedWLTOutboundReachability(
        _ plan: ExplicitWLTPlan,
        through profile: ExtensionProfile
    ) async throws -> [ExplicitWLTProbeResult] {
        let profileBinding = try await validateSelectedMainForExplicitWLT(plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var results: [ExplicitWLTProbeResult] = []
        for request in plan.requests {
            try await validateExplicitWLTProfileBinding(profileBinding)
            let requestData = try encoder.encode(request)
            guard requestData.count <= 16 * 1024,
                  let requestJSON = String(data: requestData, encoding: .utf8) else {
                throw ControlError.invalidExplicitWLTPlan
            }
            let resultJSON = try await profile.probeWltOutbound(
                requestJSON,
                timeoutMillis: request.timeoutMS + 5_000
            )
            guard let resultData = resultJSON.data(using: .utf8),
                  resultData.count <= 16 * 1024 else {
                throw ControlError.explicitWLTResultInvalid
            }
            let result = try JSONDecoder().decode(ExplicitWLTProbeResult.self, from: resultData)
            try validateExplicitWLTResult(result, raw: resultData, request: request,
                                          requestData: requestData)
            try await validateExplicitWLTProfileBinding(profileBinding)
            results.append(result)
            if result.status == "failed" {
                break
            }
        }
        return results
    }

    private func validateSelectedMainForExplicitWLT(
        _ plan: ExplicitWLTPlan
    ) async throws -> ExplicitWLTProfileBinding {
        try await assertSelectedMergedProfile()
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let selected = try await ProfileManager.get(profileID) else {
            throw ControlError.selectedProfileUnavailable
        }
        let sharedDirectory = FilePath.sharedDirectory.standardizedFileURL
        let profileURL = selected.path.hasPrefix("/")
            ? URL(fileURLWithPath: selected.path).standardizedFileURL
            : sharedDirectory.appendingPathComponent(selected.path).standardizedFileURL
        let lastKnownGoodURL = URL(
            fileURLWithPath: profileURL.path + ".last-known-good"
        ).standardizedFileURL
        guard let profileData = try readExplicitWLTProfileFile(at: profileURL),
              let root = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              let dns = root["dns"] as? [String: Any],
              dns["strategy"] as? String == "prefer_ipv4",
              let finalTag = dns["final"] as? String,
              let servers = dns["servers"] as? [[String: Any]],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        let matchingServers = servers.filter { $0["tag"] as? String == finalTag }
        guard matchingServers.count == 1,
              let finalServer = matchingServers.first,
              finalServer["type"] as? String == "tcp",
              finalServer["detour"] as? String == "ru_or_wlt-ru",
              let server = finalServer["server"] as? String,
              let port = finalServer["server_port"] as? Int
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        var byTag: [String: [String: Any]] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, !tag.isEmpty, byTag[tag] == nil else {
                throw ControlError.explicitWLTProfileGraphMismatch
            }
            byTag[tag] = outbound
        }
        guard
            byTag["ru_or_wlt-ru"]?["type"] as? String == "urltest",
            byTag["ru_or_wlt-ru"]?["outbounds"] as? [String] == ["ru", "vless-wlt-ru"],
            byTag["eu_or_wlt-eu"]?["type"] as? String == "urltest",
            byTag["eu_or_wlt-eu"]?["outbounds"] as? [String] == ["eu", "vless-wlt-eu"],
            byTag["vless-wlt-ru"]?["type"] as? String == "vless",
            byTag["vless-wlt-ru"]?["detour"] as? String == "wlt-ru",
            byTag["wlt-ru"]?["type"] as? String == "wlt",
            byTag["wlt-ru"]?["route"] as? String == "ru",
            byTag["vless-wlt-eu"]?["type"] as? String == "vless",
            byTag["vless-wlt-eu"]?["detour"] as? String == "wlt-eu",
            byTag["wlt-eu"]?["type"] as? String == "wlt",
            byTag["wlt-eu"]?["route"] as? String == "eu"
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        let serverLiteral = server.contains(":") ? "[\(server)]:\(port)" : "\(server):\(port)"
        guard validLiteralIPPort(serverLiteral),
              plan.requests.first?.server == serverLiteral else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        let lastKnownGoodData = try readExplicitWLTProfileFile(
            at: lastKnownGoodURL,
            required: false
        )
        return ExplicitWLTProfileBinding(
            selectedID: profileID,
            path: profileURL.path,
            mainSHA256: sha256Hex(profileData),
            lastKnownGoodPath: lastKnownGoodURL.path,
            lastKnownGoodSHA256: lastKnownGoodData.map(sha256Hex)
        )
    }

    private func validateExplicitWLTProfileBinding(
        _ binding: ExplicitWLTProfileBinding
    ) async throws {
        let currentID = await SharedPreferences.selectedProfileID.get()
        guard
            currentID == binding.selectedID,
            let selected = try await ProfileManager.get(currentID)
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        let sharedDirectory = FilePath.sharedDirectory.standardizedFileURL
        let profileURL = selected.path.hasPrefix("/")
            ? URL(fileURLWithPath: selected.path).standardizedFileURL
            : sharedDirectory.appendingPathComponent(selected.path).standardizedFileURL
        let lastKnownGoodURL = URL(
            fileURLWithPath: profileURL.path + ".last-known-good"
        ).standardizedFileURL
        guard
            profileURL.path == binding.path,
            lastKnownGoodURL.path == binding.lastKnownGoodPath,
            let profileData = try readExplicitWLTProfileFile(at: profileURL),
            sha256Hex(profileData) == binding.mainSHA256,
            try readExplicitWLTProfileFile(at: lastKnownGoodURL, required: false)
                .map(sha256Hex) == binding.lastKnownGoodSHA256
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
    }

    private func readExplicitWLTProfileFile(
        at url: URL,
        required: Bool = true
    ) throws -> Data? {
        let fileManager = FileManager.default
        let sharedDirectory = FilePath.sharedDirectory.standardizedFileURL
        guard
            url.path.hasPrefix(sharedDirectory.path + "/"),
            url.resolvingSymlinksInPath() == url
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true
        {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        guard fileManager.fileExists(atPath: url.path) else {
            if required {
                throw ControlError.explicitWLTProfileGraphMismatch
            }
            return nil
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize <= 16 * 1_024 * 1_024
        else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1_024 * 1_024 else {
            throw ControlError.explicitWLTProfileGraphMismatch
        }
        return data
    }

    private func validateExplicitWLTResult(
        _ result: ExplicitWLTProbeResult,
        raw: Data,
        request: ExplicitWLTProbeRequest,
        requestData: Data
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw ControlError.explicitWLTResultInvalid
        }
        let commonKeys = Set([
            "schema", "scope", "probe_id", "kind", "status", "error_code", "group_tag",
            "outbound_tag", "wlt_tag", "network", "attempt", "fallback_attempted",
            "selection_touched", "profile_touched", "instance_current", "duration_ms",
            "request_sha256",
        ])
        let kindKeys = request.kind == "dns"
            ? Set(["dns_rcode", "dns_answer_count", "dns_question_sha256", "dns_server_sha256"])
            : Set(["http_status", "bytes_read", "destination_sha256"])
        guard
            Set(object.keys) == commonKeys.union(kindKeys),
            result.schema == 1,
            result.scope == "explicit_saved_WLT_outbound_reachability",
            result.probeID == request.probeID,
            result.kind == request.kind,
            ["success", "failed"].contains(result.status),
            result.errorCode.range(
                of: "^[a-z0-9_]{0,64}$", options: .regularExpression
            ) != nil,
            result.groupTag == request.groupTag,
            result.outboundTag == request.outboundTag,
            result.wltTag == request.wltTag,
            result.network == "tcp",
            result.attempt == "primary",
            !result.fallbackAttempted,
            !result.selectionTouched,
            !result.profileTouched,
            result.durationMS >= 0,
            result.status != "success" || result.durationMS <= request.timeoutMS,
            result.requestSHA256 == sha256Hex(requestData),
            (result.status == "success" && result.errorCode.isEmpty && result.instanceCurrent)
                || (result.status == "failed" && !result.errorCode.isEmpty)
        else {
            throw ControlError.explicitWLTResultInvalid
        }
        if request.kind == "dns" {
            guard let queryName = request.queryName, let server = request.server,
                  let rcode = result.dnsRcode, (-1 ... 15).contains(rcode),
                  let answerCount = result.dnsAnswerCount, answerCount >= 0,
                  result.dnsQuestionSHA256 == sha256Hex(
                    Data(queryName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).utf8)
                  ),
                  result.dnsServerSHA256 == sha256Hex(Data(server.utf8)),
                  result.httpStatus == nil, result.bytesRead == nil,
                  result.destinationSHA256 == nil,
                  result.status != "success" || (rcode == 0 && answerCount > 0)
            else {
                throw ControlError.explicitWLTResultInvalid
            }
        } else {
            guard let expectedStatus = request.expectedStatus,
                  let expectedBytes = request.expectedBytes,
                  let maximum = request.maxReadBytes,
                  let status = result.httpStatus, status >= 0,
                  let bytes = result.bytesRead, (0 ... maximum).contains(bytes),
                  let url = request.url,
                  result.destinationSHA256 == sha256Hex(Data(url.utf8)),
                  result.dnsRcode == nil, result.dnsAnswerCount == nil,
                  result.dnsQuestionSHA256 == nil, result.dnsServerSHA256 == nil,
                  result.status != "success" || (status == expectedStatus && bytes == expectedBytes)
            else {
                throw ControlError.explicitWLTResultInvalid
            }
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeProtectedAtomically(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: temporary.path
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func loadIdentityRingStatus() throws -> IdentityRingStatus {
        var statusError: NSError?
        let raw = LibboxWLTAuthRingStatus(wltAuthSnapshotURL().path, &statusError)
        if let statusError {
            throw statusError
        }
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
            let metricsCollector = WorkloadMetricsCollector()
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
                // The per-task delegate preserves data(for:)'s structured
                // cancellation. Foundation delivers metrics before task
                // completion, so reading the collector after this call returns
                // or throws requires no wait and also retains failed-task metrics.
                let (data, response) = try await session.data(
                    for: request,
                    delegate: metricsCollector
                )
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
            // Preserve the original elapsed endpoint. Optional metrics are read
            // only after this timestamp and are never awaited.
            let finishedAt = unixMilliseconds()
            let taskMetrics = metricsCollector.snapshot()
            let nsError = probeError as NSError?
            results.append(WorkloadProbeResult(
                name: probe.name,
                success: probeError == nil && classification == "ok",
                classification: classification,
                statusCode: statusCode,
                elapsedMS: max(0, finishedAt - startedAt),
                bytesRead: bytesRead,
                taskMetricsStatus: taskMetrics == nil ? "missing" : "collected",
                taskMetrics: taskMetrics,
                errorDomain: nsError?.domain,
                errorCode: nsError?.code
            ))
        }
        return WorkloadOutcome(route: plan.route, probes: results)
    }

    private static let zeroToleranceCounterNames = Set([
        "failed",
        "rejected",
        "reconnect_retries",
        "reconnects",
        "mux_open_errors",
        "mux_ping_timeouts",
        "mux_disconnects",
        "mux_control_errors",
        "mux_flow_drops",
        "peer_reconnect_failures",
    ])

    private func runWorkloadWithCounters(
        _ plan: WorkloadPlan
    ) async throws -> (WorkloadOutcome, [String: Int64]) {
        let logClient = CommandClient(.log, logMaxLines: 3_000)
        logClient.connect()
        defer { logClient.disconnect() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        // The log buffer evicts old entries at its limit, so its count is not a cursor.
        let initialLogIDs = await MainActor.run { Set(logClient.logList.map(\.id)) }
        let workload = try await runWorkload(plan)
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            let messages = await MainActor.run {
                logClient.logList.filter { !initialLogIDs.contains($0.id) }.map(\.message)
            }
            for message in messages.reversed() where message.contains("wlt service stats ") {
                var counters: [String: Int64] = [:]
                for field in message.split(separator: " ") {
                    let pair = field.split(separator: "=", maxSplits: 1)
                    guard
                        pair.count == 2,
                        Self.zeroToleranceCounterNames.contains(String(pair[0])),
                        let value = Int64(pair[1])
                    else {
                        continue
                    }
                    counters[String(pair[0])] = value
                }
                if Set(counters.keys) == Self.zeroToleranceCounterNames {
                    return (workload, counters)
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ControlError.transportCountersUnavailable
    }

    private func selectWorkloadRoute(_ route: String) async throws {
        guard route == "eu" || route == "ru" else {
            throw ControlError.invalidWorkload
        }
        let selections: [(String, String)] = route == "ru"
            ? [
                ("whitelist-exit", "ru"),
                ("ru_or_wlt-ru", "vless-wlt-ru"),
            ]
            : [
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
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, requestTimeout.isFinite, requestTimeout > 0 else {
            throw ControlError.probeFailed
        }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else {
            throw ControlError.probeFailed
        }
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let startedAt = mach_continuous_time()
        let elapsed: @Sendable () -> TimeInterval = {
            Double(mach_continuous_time() &- startedAt) * secondsPerTick
        }
        let sleepUntil: @Sendable (TimeInterval) async throws -> Void = { target in
            while true {
                try Task.checkCancellation()
                let remaining = min(target, timeout) - elapsed()
                guard remaining > 0 else { return }
                // Legacy Task.sleep may pause during system sleep. Short slices
                // recheck the same continuous deadline promptly after wake.
                try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.05) * 1e9))
            }
        }
        let endpoint = URL(string: "https://rozetked.me/")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = min(requestTimeout, timeout)
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var lastError: Error?
        while elapsed() < timeout {
            try Task.checkCancellation()
            let remainingSeconds = timeout - elapsed()
            guard remainingSeconds > 0 else { break }
            var request = URLRequest(url: endpoint)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = min(requestTimeout, remainingSeconds)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let boundedRequest = request
            do {
                let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        let (_, response) = try await session.data(for: boundedRequest)
                        return (response as? HTTPURLResponse).map {
                            (200 ..< 400).contains($0.statusCode)
                        } ?? false
                    }
                    group.addTask {
                        try await sleepUntil(timeout)
                        // Cancel the underlying URLSession operation as well as
                        // its task. The total deadline includes response-body reads.
                        session.invalidateAndCancel()
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    guard let accepted = try await group.next() else {
                        throw CancellationError()
                    }
                    return accepted
                }
                if accepted && elapsed() < timeout { return }
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
            try await sleepUntil(min(elapsed() + 0.2, timeout))
        }
        try Task.checkCancellation()
        if let lastError {
            throw lastError
        }
        throw ControlError.probeFailed
    }

    private func loadMergedGroupSelections() async throws -> [GroupSelection] {
        let expected = Set([
            "direct_or_wlt-ru",
            "ru_or_wlt-ru",
            "eu_or_wlt-eu",
        ])
        let commandClient = await MainActor.run { () -> CommandClient in
            let client = CommandClient(.groups)
            client.connect()
            return client
        }
        defer {
            Task { @MainActor in
                commandClient.disconnect()
            }
        }

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let selections = await MainActor.run { () -> [GroupSelection] in
                guard let groups = commandClient.groups else { return [] }
                return groups.compactMap { group in
                    guard expected.contains(group.tag) else { return nil }
                    let iterator = group.getItems()
                    var available: [String] = []
                    while iterator?.hasNext() == true {
                        guard let item = iterator?.next() else { continue }
                        if item.urlTestDelay > 0 {
                            available.append(item.tag)
                        }
                    }
                    return GroupSelection(
                        tag: group.tag,
                        selected: group.selected,
                        available: available
                    )
                }.sorted { $0.tag < $1.tag }
            }
            if selections.count == expected.count {
                return selections
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ControlError.timeout
    }

    private func loadCleanGroupSelections() async throws -> [GroupSelection] {
        let expectedTag = "whitelist-exit"
        let expectedItems = ["ru", "eu"]
        let commandClient = await MainActor.run { () -> CommandClient in
            let client = CommandClient(.groups)
            client.connect()
            return client
        }
        defer {
            Task { @MainActor in
                commandClient.disconnect()
            }
        }

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let selections = await MainActor.run { () -> [GroupSelection] in
                guard let groups = commandClient.groups else { return [] }
                return groups.compactMap { group in
                    guard group.tag == expectedTag else { return nil }
                    let iterator = group.getItems()
                    var available: [String] = []
                    while iterator?.hasNext() == true {
                        guard let item = iterator?.next() else { continue }
                        available.append(item.tag)
                    }
                    guard available == expectedItems, group.selected == "eu" else { return nil }
                    return GroupSelection(tag: group.tag, selected: group.selected, available: available)
                }.sorted { $0.tag < $1.tag }
            }
            // Exactly one exposed root record is required.  The daemon does
            // not publish the statically validated one-member ru/eu groups.
            if selections.count == 1 {
                return selections
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ControlError.timeout
    }

    private func loadRouteDiagnostics() async -> RouteDiagnostics {
        let allowedCategories = [
            "instagram-family", "meta-family", "tiktok-family",
            "youtube-family", "github-family", "neutral-example",
        ]
        let allowedOutbounds = ["wlt-eu", "wlt-ru", "direct", "other"]
        let allowedNetworks = ["tcp", "udp"]
        let allowedAttempts = ["primary", "fallback"]
        let commandClient = await MainActor.run { () -> CommandClient in
            let client = CommandClient(.log, logMaxLines: 3_000)
            client.connect()
            return client
        }
        defer {
            Task { @MainActor in
                commandClient.disconnect()
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let connected = await MainActor.run { commandClient.isConnected }
            if connected {
                try? await Task.sleep(nanoseconds: 300_000_000)
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let messages = await MainActor.run { commandClient.logList.map(\.message) }
        var counts: [String: [String: Int]] = [
            "instagram-family": [:],
            "meta-family": [:],
            "tiktok-family": [:],
            "youtube-family": [:],
            "github-family": [:],
            "neutral-example": [:],
        ]
        for message in messages {
            guard message.components(separatedBy: "wlt-route-leaf-category=").count == 2,
                  !message.contains("wlt-route-policy-category="),
                  !message.contains("wlt-route-category=")
            else { continue }
            for category in allowedCategories {
                let marker = "wlt-route-leaf-category=\(category) "
                guard let markerRange = message.range(of: marker) else { continue }
                let remainder = message[markerRange.upperBound...]
                let allowedFieldNames = ["outbound-class", "network", "attempt"]
                var fields: [String: String] = [:]
                var malformed = false
                for token in remainder.split(whereSeparator: \.isWhitespace) {
                    let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else {
                        malformed = true
                        break
                    }
                    let name = String(parts[0])
                    let value = String(parts[1])
                    guard allowedFieldNames.contains(name), !value.isEmpty, fields[name] == nil else {
                        malformed = true
                        break
                    }
                    fields[name] = value
                }
                guard !malformed, fields.count == allowedFieldNames.count,
                      let outbound = fields["outbound-class"], allowedOutbounds.contains(outbound),
                      let network = fields["network"], allowedNetworks.contains(network),
                      let attempt = fields["attempt"], allowedAttempts.contains(attempt)
                else { continue }
                counts[category, default: [:]][outbound, default: 0] += 1
            }
        }
        return RouteDiagnostics(
            instagramFamily: counts["instagram-family"] ?? [:],
            metaFamily: counts["meta-family"] ?? [:],
            tiktokFamily: counts["tiktok-family"] ?? [:],
            youtubeFamily: counts["youtube-family"] ?? [:],
            githubFamily: counts["github-family"] ?? [:],
            neutralExample: counts["neutral-example"] ?? [:]
        )
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
            schema: 7,
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
            explicitSavedWLTOutboundReachability:
                outcome?.explicitSavedWLTOutboundReachability,
            groupSelections: outcome?.groupSelections,
            routeDiagnostics: outcome?.routeDiagnostics,
            routeDiagnosticsScope: outcome?.routeDiagnosticsScope
                ?? (outcome?.routeDiagnostics == nil ? nil : "leaf_selection"),
            transportCounters: outcome?.transportCounters,
            identityRing: outcome?.identityRing,
            identityRingImport: outcome?.identityRingImport,
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

    private func stateExportURL(_ requestID: UUID) -> URL {
        FilePath.cacheDirectory.appendingPathComponent(
            "wlt-test-state-export-\(requestID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func exportState(to destination: URL) async throws {
        let fileManager = FileManager.default
        let shared = FilePath.sharedDirectory.standardizedFileURL
        let profiles = (try await ProfileManager.list()).sorted { $0.mustID < $1.mustID }
        guard !profiles.isEmpty, profiles.count <= 64 else {
            throw ControlError.stateExportChangedDuringCapture
        }

        struct Captured {
            let databasePath: String
            let relativePath: String
            let main: Data
            let lastKnownGood: Data?
        }
        func resolve(_ rawPath: String) throws -> (URL, String) {
            let url = rawPath.hasPrefix("/")
                ? URL(fileURLWithPath: rawPath).standardizedFileURL
                : shared.appendingPathComponent(rawPath).standardizedFileURL
            guard url.path.hasPrefix(shared.path + "/") else {
                throw ControlError.stateExportInvalidProfilePath
            }
            guard url.resolvingSymlinksInPath() == url else {
                throw ControlError.stateExportInvalidProfilePath
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ControlError.stateExportInvalidProfilePath
            }
            return (url, String(url.path.dropFirst(shared.path.count + 1)))
        }
        func readCapture() throws -> [Captured] {
            var seen = Set<String>()
            var totalBytes = 0
            return try profiles.map { profile in
                let (url, relativePath) = try resolve(profile.path)
                guard seen.insert(relativePath).inserted else {
                    throw ControlError.stateExportInvalidProfilePath
                }
                let mainSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let mainSize, mainSize <= 16 * 1_024 * 1_024 else {
                    throw ControlError.stateExportChangedDuringCapture
                }
                let main = try Data(contentsOf: url)
                let lastKnownGoodURL = URL(fileURLWithPath: url.path + ".last-known-good")
                let lastKnownGood: Data?
                if let values = try? lastKnownGoodURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                   values.isSymbolicLink == true
                {
                    throw ControlError.stateExportInvalidProfilePath
                }
                if fileManager.fileExists(atPath: lastKnownGoodURL.path) {
                    let values = try lastKnownGoodURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                    )
                    guard lastKnownGoodURL.resolvingSymlinksInPath() == lastKnownGoodURL,
                          values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          let fileSize = values.fileSize,
                          fileSize <= 16 * 1_024 * 1_024
                    else {
                        throw ControlError.stateExportInvalidProfilePath
                    }
                    lastKnownGood = try Data(contentsOf: lastKnownGoodURL)
                } else {
                    lastKnownGood = nil
                }
                guard main.count <= 16 * 1_024 * 1_024,
                      (lastKnownGood?.count ?? 0) <= 16 * 1_024 * 1_024
                else {
                    throw ControlError.stateExportChangedDuringCapture
                }
                totalBytes += main.count + (lastKnownGood?.count ?? 0)
                guard totalBytes <= 32 * 1_024 * 1_024 else {
                    throw ControlError.stateExportChangedDuringCapture
                }
                return Captured(databasePath: profile.path, relativePath: relativePath,
                                main: main, lastKnownGood: lastKnownGood)
            }
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        let before = try readCapture()
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700,
                         .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let databaseURL = destination.appendingPathComponent("settings.db")
        let databasePaths = try await ProfileManager.backupProfileDatabase(to: databaseURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600,
             .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: databaseURL.path
        )
        let after = try readCapture()
        guard before.map(\.databasePath) == databasePaths,
              before.count == after.count,
              before.indices.allSatisfy({ index in
                  before[index].databasePath == after[index].databasePath
                      && before[index].relativePath == after[index].relativePath
                      && before[index].main == after[index].main
                      && before[index].lastKnownGood == after[index].lastKnownGood
              })
        else {
            throw ControlError.stateExportChangedDuringCapture
        }

        let filesURL = destination.appendingPathComponent("configs", isDirectory: true)
        try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var entries: [[String: Any]] = []
        for (index, capture) in before.enumerated() {
            let base = String(format: "%03d", index)
            let mainName = "\(base).json"
            let mainURL = filesURL.appendingPathComponent(mainName)
            try writeProtectedAtomically(capture.main, to: mainURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mainURL.path)
            var entry: [String: Any] = [
                "source_relative_path": capture.relativePath,
                "database_path": capture.databasePath,
                "main": ["path": "configs/\(mainName)", "bytes": capture.main.count,
                         "sha256": digest(capture.main)],
                "last_known_good_present": capture.lastKnownGood != nil,
            ]
            if let lkg = capture.lastKnownGood {
                let lkgName = "\(base).last-known-good.json"
                let lkgURL = filesURL.appendingPathComponent(lkgName)
                try writeProtectedAtomically(lkg, to: lkgURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lkgURL.path)
                entry["last_known_good"] = ["path": "configs/\(lkgName)", "bytes": lkg.count,
                                             "sha256": digest(lkg)]
            }
            entries.append(entry)
        }
        let databaseData = try Data(contentsOf: databaseURL)
        let manifest: [String: Any] = [
            "schema": 1,
            "database": ["path": "settings.db", "bytes": databaseData.count,
                         "sha256": digest(databaseData)],
            "profiles": entries,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let manifestURL = destination.appendingPathComponent("manifest.json")
        try writeProtectedAtomically(manifestData, to: manifestURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    private func loadProfilePlan(for action: Action, at url: URL) throws -> ProfilePlan? {
        guard action == .bootstrapProfile || action == .upsertProfile else {
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

    private func upsertProfile(_ plan: ProfilePlan) async throws -> ExtensionProfile {
        let network = await captureNetworkSnapshot()
        guard network.status == "satisfied", network.wifi, !network.cellular else {
            throw ControlError.profileBootstrapRequiresWiFi
        }
        guard let extensionProfile = try await ExtensionProfile.load() else {
            throw ControlError.networkExtensionNotInstalled
        }
        await extensionProfile.register()
        guard await extensionProfile.status == .disconnected else {
            throw ControlError.unexpectedStatus
        }

        let normalized = plan.name.lowercased().filter { $0.isLetter || $0.isNumber }
        let namedMatches = try await ProfileManager.list().filter {
            $0.name.lowercased().filter { $0.isLetter || $0.isNumber } == normalized
        }
        guard namedMatches.count <= 1 else {
            throw ControlError.selectedProfileUnavailable
        }

        let selectedProfile: Profile
        if let existing = namedMatches.first {
            guard existing.type == .remote, existing.remoteURL == plan.url else {
                throw ControlError.selectedProfileUnavailable
            }
            try await existing.updateRemoteProfile()
            selectedProfile = existing
        } else if let existing = try await ProfileManager.get(remoteURL: plan.url) {
            existing.name = plan.name
            try await ProfileManager.update(existing)
            try await existing.updateRemoteProfile()
            selectedProfile = existing
        } else {
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
            let profile = Profile(
                name: plan.name,
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
        return extensionProfile
    }

    private func loadWorkloadPlan(for action: Action, at url: URL) throws -> WorkloadPlan? {
        guard action == .workload || action == .networkWorkload else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError.invalidWorkload
        }
        let plan = try JSONDecoder().decode(WorkloadPlan.self, from: Data(contentsOf: url))
        guard plan.schema == 1, ["eu", "ru"].contains(plan.route), (1 ... 32).contains(plan.probes.count) else {
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

    private func loadExplicitWLTPlan(for action: Action, at url: URL) throws -> ExplicitWLTPlan? {
        guard action == .explicitSavedWLTOutboundReachability else {
            return nil
        }
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            data.count <= 32 * 1024,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys) == Set(["schema", "scope", "requests"]),
            let rawRequests = root["requests"] as? [[String: Any]],
            rawRequests.count == 3
        else {
            throw ControlError.invalidExplicitWLTPlan
        }
        let plan = try JSONDecoder().decode(ExplicitWLTPlan.self, from: data)
        guard
            plan.schema == 1,
            plan.scope == "explicit_saved_WLT_outbound_reachability",
            plan.requests.count == 3,
            plan.requests.map(\.kind) == ["dns", "https", "https"]
        else {
            throw ControlError.invalidExplicitWLTPlan
        }
        var probeIDs = Set<String>()
        let common = Set([
            "schema", "probe_id", "kind", "group_tag", "outbound_tag", "wlt_tag",
            "timeout_ms",
        ])
        for (index, request) in plan.requests.enumerated() {
            let rawKeys = Set(rawRequests[index].keys)
            guard
                request.schema == 1,
                request.probeID.range(
                    of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression
                ) != nil,
                probeIDs.insert(request.probeID).inserted,
                (1 ... 90_000).contains(request.timeoutMS)
            else {
                throw ControlError.invalidExplicitWLTPlan
            }
            if request.kind == "dns" {
                guard
                    index == 0,
                    rawKeys == common.union(["server", "query_name"]),
                    request.groupTag == "ru_or_wlt-ru",
                    request.outboundTag == "vless-wlt-ru",
                    request.wltTag == "wlt-ru",
                    let server = request.server,
                    validLiteralIPPort(server),
                    let queryName = request.queryName?.lowercased(),
                    queryName.range(
                        of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$",
                        options: .regularExpression
                    ) != nil,
                    queryName.count <= 253,
                    queryName.hasSuffix(".vercel.app"),
                    request.url == nil,
                    request.expectedStatus == nil,
                    request.expectedBytes == nil,
                    request.maxReadBytes == nil
                else {
                    throw ControlError.invalidExplicitWLTPlan
                }
            } else {
                guard
                    rawKeys == common.union([
                        "url", "expected_status", "expected_bytes", "max_read_bytes",
                    ]),
                    request.groupTag == "eu_or_wlt-eu",
                    request.outboundTag == "vless-wlt-eu",
                    request.wltTag == "wlt-eu",
                    request.server == nil,
                    request.queryName == nil,
                    let url = request.url
                else {
                    throw ControlError.invalidExplicitWLTPlan
                }
                if index == 1 {
                    guard
                        url == "https://cp.cloudflare.com/generate_204",
                        request.expectedStatus == 204,
                        request.expectedBytes == 0,
                        request.maxReadBytes == 1
                    else {
                        throw ControlError.invalidExplicitWLTPlan
                    }
                } else {
                    guard
                        url.range(
                            of: "^https://speed\\.cloudflare\\.com/__down\\?bytes=1048576&seed=[A-Za-z0-9._-]{1,64}$",
                            options: .regularExpression
                        ) != nil,
                        request.expectedStatus == 200,
                        request.expectedBytes == 1_048_576,
                        request.maxReadBytes == 1_048_577
                    else {
                        throw ControlError.invalidExplicitWLTPlan
                    }
                }
            }
        }
        return plan
    }

    private func validLiteralIPPort(_ value: String) -> Bool {
        if value.hasPrefix("["), let closing = value.firstIndex(of: "]") {
            let address = String(value[value.index(after: value.startIndex) ..< closing])
            let suffix = value[value.index(after: closing)...]
            guard suffix.first == ":", let port = Int(suffix.dropFirst()) else { return false }
            return IPv6Address(address) != nil && (1 ... 65_535).contains(port)
        }
        guard let separator = value.lastIndex(of: ":") else { return false }
        let address = String(value[..<separator])
        guard let port = Int(value[value.index(after: separator)...]) else { return false }
        return IPv4Address(address) != nil && (1 ... 65_535).contains(port)
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

    private func pruneStateExports(excluding current: URL) {
        let directory = current.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for file in files where
            file.lastPathComponent != current.lastPathComponent
            && file.lastPathComponent.hasPrefix("wlt-test-state-export-")
        {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func pruneIdentityRingImports(excluding current: [URL]) {
        guard let first = current.first else {
            return
        }
        let excluded = Set(current.map(\.lastPathComponent))
        let directory = first.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for file in files where
            !excluded.contains(file.lastPathComponent)
            && file.lastPathComponent.hasPrefix("wlt-test-identity-ring-")
        {
            try? FileManager.default.removeItem(at: file)
        }
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
        let radioTechnologies = Array(Set(radioByService.values.compactMap {
            Self.sanitizedRadioTechnology($0)
        })).sorted()
        let cellularServiceCount = max(
            radioByService.count,
            telephony.serviceSubscriberCellularProviders?.count ?? 0
        )
        let dataServiceIdentifier = telephony.dataServiceIdentifier
        let activeDataRadioTechnology = dataServiceIdentifier.flatMap { identifier in
            Self.sanitizedRadioTechnology(radioByService[identifier])
        }
        let dataServiceIDHash = dataServiceIdentifier.flatMap { identifier in
            identifier.data(using: .utf8).map { data in
                SHA256.hash(data: data)
                    .prefix(6)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
        }
        let singleServiceRadioTechnology = radioByService.count == 1
            ? Self.sanitizedRadioTechnology(radioByService.values.first)
            : nil
        let radioTechnology: String
        let radioTechnologySource: String
        if let activeDataRadioTechnology {
            radioTechnology = activeDataRadioTechnology
            radioTechnologySource = "active_data_service"
        } else if let singleServiceRadioTechnology {
            radioTechnology = singleServiceRadioTechnology
            radioTechnologySource = "single_service"
        } else {
            radioTechnology = "unknown"
            radioTechnologySource = "unavailable"
        }
        return NetworkSnapshot(
            status: path.status == .satisfied ? "satisfied" : "unsatisfied",
            cellular: path.usesInterfaceType(.cellular),
            wifi: path.usesInterfaceType(.wifi),
            radioTechnology: radioTechnology,
            radioTechnologies: radioTechnologies,
            radioTechnologySource: radioTechnologySource,
            cellularServiceCount: cellularServiceCount,
            dataServiceIDHash: dataServiceIDHash
        )
    }

    private static func sanitizedRadioTechnology(_ technology: String?) -> String? {
        guard let technology else {
            return nil
        }
        let allowed = [
            CTRadioAccessTechnologyGPRS,
            CTRadioAccessTechnologyEdge,
            CTRadioAccessTechnologyWCDMA,
            CTRadioAccessTechnologyHSDPA,
            CTRadioAccessTechnologyHSUPA,
            CTRadioAccessTechnologyCDMA1x,
            CTRadioAccessTechnologyCDMAEVDORev0,
            CTRadioAccessTechnologyCDMAEVDORevA,
            CTRadioAccessTechnologyCDMAEVDORevB,
            CTRadioAccessTechnologyeHRPD,
            CTRadioAccessTechnologyLTE,
            CTRadioAccessTechnologyNRNSA,
            CTRadioAccessTechnologyNR,
        ]
        return allowed.contains(technology) ? technology : nil
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
