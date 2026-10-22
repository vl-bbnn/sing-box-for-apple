import Foundation
#if os(iOS) && SFI_DEV
  import CryptoKit
#endif
import Libbox
import Darwin
import Network
import NetworkExtension
import os.log

#if os(iOS)
  import WidgetKit
#endif
#if os(macOS)
  import CoreLocation
#endif

open class ExtensionProvider: NEPacketTunnelProvider {
  private static let logger = Logger(category: "ExtensionProvider")
  private static let defaultLogMaxLines = 100_000
  private static let whitelistTransportLogMaxLines = 3_000
  private static let whitelistTransportMemoryRecoveryThresholdDefault: UInt64 = 42 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryUrgentThresholdDefault: UInt64 =
    44 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryThresholdCore: UInt64 = 45 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryUrgentThresholdCore: UInt64 =
    47 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryCooldownDefault: TimeInterval = 20
  private static let whitelistTransportMemoryRecoveryUrgentCooldownDefault: TimeInterval = 15
  private static let whitelistTransportMemoryRecoveryCooldownCore: TimeInterval = 45
  private static let whitelistTransportMemoryRecoveryUrgentCooldownCore: TimeInterval = 20
  private static let whitelistTransportMemoryRecoverySkipLogInterval: TimeInterval = 30
  #if os(iOS) && SFI_DEV
    private static let wltHeapProfileThreshold: UInt64 = 43 * 1024 * 1024
  #endif
  private let lifecycleStateLock = NSLock()
  private var stopTunnelGeneration: UInt64 = 0

  public private(set) var commandServer: LibboxCommandServer?
  private lazy var platformInterface = ExtensionPlatformInterface(self)
  public var tunnelOptions: [String: NSObject]?
  private var startOptionsURL: URL?
  private var whitelistTransportProfileIsCore = false
  #if os(iOS)
    private var diagnosticsMemoryPressure: DispatchSourceMemoryPressure?
  #endif
  #if os(iOS) && SFI_DEV
    private var whitelistTransportClient: LibboxWhitelistTransportClient?
    private var diagnosticsLastMemoryRecoveryAt: Date?
    private var diagnosticsLastMemoryRecoverySkipAt: Date?
    private var memoryRecoveryInProgress = false
  #endif
  private var diagnosticsSessionID: String?
  private var diagnosticsStartedAt: Date?
  private var diagnosticsHeartbeat: DispatchSourceTimer?
  private var diagnosticsLastMemoryPressureAt: Date?
  private var diagnosticsLastThermalState: String?

  public struct OverridePreferences {
    public var includeAllNetworks: Bool = false
    public var systemProxyEnabled: Bool = true
    public var excludeDefaultRoute: Bool = false
    public var autoRouteUseSubRangesByDefault: Bool = false
    public var excludeAPNsRoute: Bool = false
  }

  public var overridePreferences: OverridePreferences?

  private func applyStartOptions(_ options: [String: NSObject]) {
    tunnelOptions = options
    #if SFI_DEV
      if let configContent = options["configContent"] as? String {
        whitelistTransportProfileIsCore =
          WhitelistTransportConfig.usesCoreWhitelistTransport(configContent)
      } else {
        whitelistTransportProfileIsCore = false
      }
    #else
      whitelistTransportProfileIsCore = false
    #endif
    overridePreferences = OverridePreferences(
      includeAllNetworks: (options["includeAllNetworks"] as? NSNumber)?.boolValue ?? false,
      systemProxyEnabled: (options["systemProxyEnabled"] as? NSNumber)?.boolValue ?? true,
      excludeDefaultRoute: (options["excludeDefaultRoute"] as? NSNumber)?.boolValue ?? false,
      autoRouteUseSubRangesByDefault: (options["autoRouteUseSubRangesByDefault"] as? NSNumber)?
        .boolValue ?? false,
      excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false
    )
  }

  private func persistStartOptions(_ options: [String: NSObject]) throws {
    guard let startOptionsURL else {
      return
    }
    let data = try ExtensionStartOptions.encode(options)
    try data.write(to: startOptionsURL, options: .atomic)
  }

  private func loadPersistedStartOptions() throws -> [String: NSObject]? {
    guard let startOptionsURL, FileManager.default.fileExists(atPath: startOptionsURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: startOptionsURL)
    return try ExtensionStartOptions.decode(data)
  }

  private func resolveStartOptions(_ startOptions: [String: NSObject]?) throws -> [String: NSObject]
  {
    if let startOptions, startOptions["configContent"] as? String != nil {
      return startOptions
    }
    let persistedOptions: [String: NSObject]?
    do {
      persistedOptions = try loadPersistedStartOptions()
    } catch {
      throw ExtensionStartupError(
        "(packet-tunnel) error: load start options: \(error.localizedDescription)")
    }
    if let persistedOptions {
      if let startOptions {
        return persistedOptions.merging(startOptions) { _, new in new }
      }
      return persistedOptions
    }
    throw ExtensionStartupError("(packet-tunnel) error: missing start options")
  }

  #if os(macOS)
    private var xpcListener: NSXPCListener!
    private var xpcService: CommandXPCService!
    private var locationManager: CLLocationManager?
    private var locationDelegate: stubLocationDelegate?
  #endif

  override open func startTunnel(options startOptions: [String: NSObject]?) async throws {
    beginDiagnosticsSession()
    PacketTunnelDiagnostics.appendStartupMilestone("extension_started")
    recordLifecycleEvent("(packet-tunnel): startTunnel entered")
    do {
      try await startTunnelImpl(options: startOptions)
    } catch {
      recordLifecycleEvent("(packet-tunnel): startTunnel failed: \(error.localizedDescription)")
      endDiagnosticsSession("startTunnel failed")
      throw error
    }
  }

  private func startTunnelImpl(options startOptions: [String: NSObject]?) async throws {
    let startupStartedAt = Date()
    let startStopGeneration = currentStopTunnelGeneration()
    let basePath: String
    let workingPath: String
    let tempPath: String

    #if os(macOS)
      if Variant.useSystemExtension {
        let containerURL = FileManager.default.homeDirectoryForCurrentUser
        basePath = containerURL.path
        workingPath = containerURL.appendingPathComponent("Working").path
        tempPath = containerURL.appendingPathComponent("Temp").path
      } else {
        basePath = FilePath.sharedDirectory.relativePath
        workingPath = FilePath.workingDirectory.relativePath
        tempPath = FilePath.cacheDirectory.relativePath
      }
    #else
      basePath = FilePath.sharedDirectory.relativePath
      workingPath = FilePath.workingDirectory.relativePath
      tempPath = FilePath.cacheDirectory.relativePath
    #endif

    startOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(
      ExtensionStartOptions.snapshotFileName)
    recordStartupStage("paths-ready", startedAt: startupStartedAt, totalStartedAt: startupStartedAt)

    #if os(macOS)
      if Variant.useSystemExtension {
        let socketPath = basePath + "/command.sock"
        let machServiceName = AppConfiguration.appGroupID + ".system"
        xpcService = CommandXPCService(socketPath: socketPath)
        xpcListener = NSXPCListener(machServiceName: machServiceName)
        xpcListener.delegate = xpcService
      }
    #endif

    var stageStartedAt = Date()
    let effectiveOptions = try resolveStartOptions(startOptions)
    PacketTunnelDiagnostics.appendStartupMilestone("start_options_received")
    recordStartupStage(
      "resolve-options", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)
    if effectiveOptions["configContent"] == nil {
      throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
    }
    stageStartedAt = Date()
    do {
      try persistStartOptions(effectiveOptions)
    } catch {
      throw ExtensionStartupError(
        "(packet-tunnel) error: persist start options: \(error.localizedDescription)")
    }
    recordStartupStage(
      "persist-options", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)

    stageStartedAt = Date()
    applyStartOptions(effectiveOptions)
    recordStartupStage(
      "apply-options", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)
    recordNetworkPathSnapshot(stage: "after-apply-options")

    let options = LibboxSetupOptions()
    options.basePath = basePath
    options.workingPath = workingPath
    options.tempPath = tempPath

    let whitelistTransportEnabled =
      (effectiveOptions["whitelistTransportEnabled"] as? NSNumber)?.boolValue ?? false
    if whitelistTransportEnabled {
      options.logMaxLines = Self.whitelistTransportLogMaxLines
    } else {
      options.logMaxLines = Self.defaultLogMaxLines
    }
    recordLifecycleEvent(
      "(packet-tunnel): libbox resource policy whitelistTransport=\(whitelistTransportEnabled) logMaxLines=\(options.logMaxLines)")
    #if os(iOS) && SFI_DEV
      if whitelistTransportEnabled {
        recordLifecycleEvent(
          "(packet-tunnel): whitelist transport recovery policy threshold=\(PacketTunnelDiagnostics.formatBytes(whitelistTransportMemoryRecoveryThreshold())) urgentThreshold=\(PacketTunnelDiagnostics.formatBytes(whitelistTransportMemoryRecoveryUrgentThreshold())) cooldown=\(formatDuration(whitelistTransportMemoryRecoveryCooldown(isUrgent: false))) urgentCooldown=\(formatDuration(whitelistTransportMemoryRecoveryCooldown(isUrgent: true)))")
      }
    #endif

    #if os(tvOS)
      if let port = effectiveOptions["commandServerPort"] as? NSNumber {
        options.commandServerListenPort = port.int32Value
      }
      if let secret = effectiveOptions["commandServerSecret"] as? String {
        options.commandServerSecret = secret
      }
    #endif

    var setupError: NSError?
    stageStartedAt = Date()
    LibboxSetup(options, &setupError)
    if let setupError {
      throw ExtensionStartupError(
        "(packet-tunnel) error: setup service: \(setupError.localizedDescription)")
    }
    PacketTunnelDiagnostics.appendStartupMilestone("libbox_ready")
    recordStartupStage("libbox-setup", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)

    let stderrPath = URL(fileURLWithPath: tempPath, isDirectory: true).appendingPathComponent(
      "stderr.log"
    ).path
    var stderrError: NSError?
    stageStartedAt = Date()
    LibboxRedirectStderr(stderrPath, &stderrError)
    if let stderrError {
      throw ExtensionStartupError(
        "(packet-tunnel) redirect stderr error: \(stderrError.localizedDescription)")
    }
    recordStartupStage(
      "redirect-stderr", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)

    #if !os(macOS)
      let ignoreMemoryLimit =
        (effectiveOptions["ignoreMemoryLimit"] as? NSNumber)?.boolValue ?? false
      stageStartedAt = Date()
      LibboxSetMemoryLimit(!ignoreMemoryLimit)
      recordStartupStage(
        "memory-limit-\(ignoreMemoryLimit ? "disabled" : "enabled")",
        startedAt: stageStartedAt,
        totalStartedAt: startupStartedAt
      )
    #endif

    var error: NSError?
    stageStartedAt = Date()
    commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
    if let error {
      throw ExtensionStartupError(
        "(packet-tunnel): create command server error: \(error.localizedDescription)")
    }
    do {
      try commandServer!.start()
    } catch {
      throw ExtensionStartupError(
        "(packet-tunnel): start command server error: \(error.localizedDescription)")
    }
    recordStartupStage(
      "command-server", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)

    #if os(macOS)
      if Variant.useSystemExtension {
        xpcListener.resume()
        Self.logger.info("set Command Server")
        xpcService.commandServer = commandServer
      }
    #endif

    writeLifecycleMessage("(packet-tunnel): Here I stand")
    #if os(iOS) && SFI_DEV
      stageStartedAt = Date()
      try startWhitelistTransportIfNeeded(effectiveOptions)
      recordStartupStage(
        "whitelist-transport", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)
    #endif
    do {
      stageStartedAt = Date()
      try throwIfStopTunnelRequested(since: startStopGeneration)
      recordNetworkPathSnapshot(stage: "before-start-service")
      writeLifecycleMessage("(packet-tunnel): starting sing-box service")
      PacketTunnelDiagnostics.appendStartupMilestone("core_starting")
      try await startService()
      try throwIfStopTunnelRequested(since: startStopGeneration)
      writeLifecycleMessage(
        "(packet-tunnel): sing-box service started elapsed=\(formatDuration(Date().timeIntervalSince(stageStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      PacketTunnelDiagnostics.appendStartupMilestone("core_started")
      recordStartupStage(
        "complete", startedAt: startupStartedAt, totalStartedAt: startupStartedAt)
    } catch {
      #if os(macOS)
        if Variant.useSystemExtension {
          xpcService.markServiceNotReady(error)
        }
      #endif
      throw error
    }
    #if os(macOS)
      if Variant.useSystemExtension {
        xpcService.markServiceReady()
      }
    #endif
    #if os(iOS)
      if #available(iOS 18.0, *) {
        await ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
      }
    #endif
  }

  func writeMessage(_ message: String) {
    PacketTunnelDiagnostics.observeStartupLog(message)
    recordCoreRecoveryDiagnostic(message)
    if let commandServer {
      commandServer.writeMessage(2, message: message)
    }
  }

  // Command-server core logs already reside in its bounded log buffer.
  // Record selected events without feeding them back into that same server.
  func recordCoreRecoveryDiagnostic(_ message: String) {
    #if os(iOS) && SFI_DEV
      recordBoundedTrafficDiagnostic(message)
      recordBoundedAuthLifecycleDiagnostic(message)
      recordBoundedServiceTerminalDiagnostic(message)
      recordBoundedDialCausalDiagnostic(message)
      recordBoundedActiveAdmissionDiagnostic(message)
      recordBoundedCloseLifecycleDiagnostic(message)
      // A malformed dial line must never fall through a broad recovery marker.
      if message.contains("wlt dial causal event=")
        || message.contains("wlt dial correlation event=")
        || message.contains("WLT active admission ")
        || message.contains("WLT close lifecycle ")
        || message.contains("WLT startup phase=first_packet")
        || message.contains("WLT startup phase=traffic_ready")
      { return }
      // Keep recovery causes after the bounded command log has been evicted.
      // These fixed lifecycle/statistics messages contain no destinations or auth.
      let recoveryMarkers = [
        "updated default interface ", "missing default interface",
        "wlt service default interface ", "wlt service ignoring duplicate ",
        "wlt service replacing carrier ", "wlt service starting carrier after ",
        "wlt service restarting carrier ", "wlt service carrier restarted",
        "wlt service old carrier abort", "wlt service stats ",
        "relay client mux diagnostics registered", "relay client mux terminal stats",
        "relay client mux open locally retired", "tinymux client open trace",
        "relay client mux lifetime", "relay client peer write diagnostics registered",
        "relay client peer write terminal stats", "relay client peer write coverage incomplete",
        "peer write failed",
        "wlt payload phase ",
        "memory pressure: ", "memory threshold reached,",
      ]
      if isWhitelistTransportProfileActive,
        recoveryMarkers.contains(where: { message.contains($0) })
      {
        recordLifecycleEvent("(packet-tunnel): core-recovery \(message)")
      }
    #endif
  }

  #if os(iOS) && SFI_DEV
  // The core forwards these two complete INFO lines without entering the
  // command log. Match the full formatter envelope and retain only its fixed,
  // credential-free event text; never persist a suffix or another service tag.
  private static func validatedCoreTrafficEvent(_ message: String) -> String? {
    guard message.utf8.count <= 256,
      !message.contains("\r"), !message.contains("\n")
    else { return nil }
    let pattern = #"(?:\x1b\[36mINFO\x1b\[0m|INFO)\[[0-9]{4,}\] (?:\[[0-9]+ [0-9a-z.]+\] )?service/wlt\[wlt-carrier\]: (WLT startup phase=(?:first_packet elapsed_ms=[0-9]{1,13} direction=(?:read|write)|traffic_ready elapsed_ms=[0-9]{1,13}))"#
    let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: message, range: fullRange),
      match.range == fullRange,
      let eventRange = Range(match.range(at: 1), in: message)
    else { return nil }
    return String(message[eventRange])
  }

  private func recordBoundedTrafficDiagnostic(_ message: String) {
    guard isWhitelistTransportProfileActive,
      let event = Self.validatedCoreTrafficEvent(message)
    else { return }
    recordLifecycleEvent("(packet-tunnel): core-traffic \(event)")
    PacketTunnelDiagnostics.observeStartupLog(event)
  }
  #endif

  // Persist only complete numeric/opaque close lifecycle events from the
  // capped Go producer. Never mirror a target, transport error or payload.
  private func recordBoundedCloseLifecycleDiagnostic(_ message: String) {
    #if os(iOS) && SFI_DEV
      guard isWhitelistTransportProfileActive,
        let context = message.range(of: "service/wlt[wlt-carrier]: ")
      else { return }
      let event = String(message[context.upperBound...])
      guard event.hasPrefix("WLT close lifecycle ") else { return }
      guard event.utf8.count <= 512,
        !event.contains("\r"), !event.contains("\n"), !event.contains("\u{001b}")
      else {
        recordLifecycleEvent("(packet-tunnel): core-close-lifecycle rejected_unallowlisted")
        return
      }
      let capMarker = "^WLT close lifecycle phase=cap_exhausted event=4097 wall_ms=[0-9]{13} cap=4096$"
      if event.range(of: capMarker, options: .regularExpression) != nil {
        recordLifecycleEvent("(packet-tunnel): core-close-lifecycle \(event)")
        return
      }
      let patterns = [
        "^WLT close lifecycle phase=start event=[0-9]{1,4} wall_ms=[0-9]{13} flow_id=[0-9]{1,5} mode=(?:graceful|abort) active=[0-9]{1,6} slots=[0-9]{1,4} kcp_wait_snd=[0-9]{1,13} mux_pending=[0-9]{1,13} kcp_read_errors=[0-9]{1,13} kcp_close_reason=(?:none|local_close|local_abort|read_error:(?:eof|closed|timeout)|write_error:(?:eof|closed|timeout)|other) mux_close_reason=(?:none|local_close_notified|local_abort_notified|remote_close|remote_close_timeout|other) draining=[0-9]{1,6} drain_slots=[0-9]{1,4} hard_ceiling=[0-9]{1,4} permit_owner=(?:active|drain)$",
        "^WLT close lifecycle phase=end event=[0-9]{1,4} wall_ms=[0-9]{13} flow_id=[0-9]{1,5} mode=(?:graceful|abort) duration_ms=[0-9]{1,13} kcp_close_ms=[0-9]{1,13} kcp_wait_snd=[0-9]{1,13} mux_pending=[0-9]{1,13} kcp_drain_calls=[0-9]{1,13} kcp_drain_ms=[0-9]{1,13} kcp_drain_result=(?:none|acked|timeout|aborted|other) mux_close_ms=[0-9]{1,13} mux_close_wait_ms=[0-9]{1,13} mux_close_control_ms=[0-9]{1,13} mux_close_control_error=[01] mux_close_reason=(?:none|local_close_notified|local_abort_notified|remote_close|remote_close_timeout|other) active=[0-9]{1,6} slots=[0-9]{1,4} permit_released=1 draining=[0-9]{1,6} drain_slots=[0-9]{1,4} hard_ceiling=[0-9]{1,4} retired_owner=(?:active|drain)(?: close_outcome=(?:returned_nil|returned_error))?$",
      ]
      let fields = event.split(separator: " ")
      guard patterns.contains(where: { event.range(of: $0, options: .regularExpression) != nil }),
        fields.count >= 7,
        fields[4].hasPrefix("event="), fields[6].hasPrefix("flow_id="),
        let sequence = UInt64(fields[4].dropFirst(6)), (1...4096).contains(sequence),
        let flowID = UInt16(fields[6].dropFirst(8))
      else {
        recordLifecycleEvent("(packet-tunnel): core-close-lifecycle rejected_unallowlisted")
        return
      }
      _ = flowID
      recordLifecycleEvent("(packet-tunnel): core-close-lifecycle \(event)")
    #endif
  }

  // Carry only the carrier's capped aggregate admission samples into the
  // retained packet diagnostic. Do not persist an unknown field or payload.
  private func recordBoundedActiveAdmissionDiagnostic(_ message: String) {
    #if os(iOS) && SFI_DEV
      guard isWhitelistTransportProfileActive,
        let context = message.range(of: "service/wlt[wlt-carrier]: ")
      else { return }
      let event = String(message[context.upperBound...])
      guard event.hasPrefix("WLT active admission ") else { return }
      let parts = event.split(separator: " ", omittingEmptySubsequences: false)
      let keys = [
        "event", "wall_ms", "queue_elapsed_ms", "active_capacity", "pending_capacity",
        "active_slots_used", "pending_slots_used", "active_count", "pending_count",
        "registered", "fresh", "pressure_eligible", "closing", "oldest_activity_ms",
      ]
      guard parts.count == 4 + keys.count,
        parts[0] == "WLT", parts[1] == "active", parts[2] == "admission",
        parts[3] == "stage=saturated" || parts[3] == "stage=wait_timeout"
      else {
        recordLifecycleEvent("(packet-tunnel): core-active-admission rejected_unallowlisted")
        return
      }
      var values: [Int64] = []
      for (index, key) in keys.enumerated() {
        let field = parts[index + 4]
        let digits = field.dropFirst(min(field.count, key.count + 1))
        guard field.hasPrefix("\(key)="),
          !digits.isEmpty, digits.utf8.count <= 13,
          digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let value = Int64(String(digits))
        else {
          recordLifecycleEvent("(packet-tunnel): core-active-admission rejected_unallowlisted")
          return
        }
        values.append(value)
      }
      guard (1...64).contains(values[0]),
        (1_000_000_000_000...9_999_999_999_999).contains(values[1]),
        values[2] <= 1_000_000_000_000,
        (1...4096).contains(values[3]), (1...4096).contains(values[4]),
        values[5] <= values[3], values[6] <= values[4],
        values[7] <= 1_000_000, values[8] <= 1_000_000,
        values[9] <= 1_000_000, values[10] <= values[9],
        values[11] <= values[9], values[12] <= values[9],
        values[10] + values[11] + values[12] == values[9],
        values[13] <= 1_000_000_000_000
      else {
        recordLifecycleEvent("(packet-tunnel): core-active-admission rejected_unallowlisted")
        return
      }
      recordLifecycleEvent("(packet-tunnel): core-active-admission \(event)")
    #endif
  }

  // Persist only complete, endpoint-free dial ID/cause forms. Any appended
  // payload or malformed producer line becomes an opaque failure marker.
  private func recordBoundedDialCausalDiagnostic(_ message: String) {
    #if os(iOS) && SFI_DEV
      guard isWhitelistTransportProfileActive,
        let context = message.range(of: "service/wlt[wlt-carrier]: ")
      else { return }
      let event = String(message[context.upperBound...])
      guard event.hasPrefix("wlt dial causal event=")
        || event.hasPrefix("wlt dial correlation event=")
      else { return }
      guard !event.contains("\r"), !event.contains("\n"), !event.contains("\u{001b}") else {
        recordLifecycleEvent("(packet-tunnel): core-dial-causal rejected_unallowlisted")
        return
      }
      let patterns = [
        "^wlt dial causal event=carrier_error logical_dial_id=[0-9]{1,20} dial_attempt_id=[0-9]{1,20} carrier_generation=[0-9]{1,20} interface_generation=[0-9]{1,20} tree=[0-9]{1,2}\\.[0-9]{1,2}\\.(?:nil|leaf|net_op|syscall_op|errno|errno_other|local_retired|canceled|deadline|eof|unexpected_eof|closed_pipe|net_closed|service_stopped|join|wrap|mux_closed|session_closed|pong_timeout|remote_disconnect)\\.[0-9]{1,10}\\.[a-f0-9]{16}(?:,[0-9]{1,2}\\.[0-9]{1,2}\\.(?:nil|leaf|net_op|syscall_op|errno|errno_other|local_retired|canceled|deadline|eof|unexpected_eof|closed_pipe|net_closed|service_stopped|join|wrap|mux_closed|session_closed|pong_timeout|remote_disconnect)\\.[0-9]{1,10}\\.[a-f0-9]{16}){0,15} tree_nodes=(?:[1-9]|1[0-6]) tree_truncated=(?:true|false)$",
        "^wlt dial causal event=early_failure logical_dial_id=[0-9]+ dial_attempt_id=[0-9]+ carrier_generation=[0-9]+ interface_generation=[0-9]+ original_transport_error=true observation_budget_ms=500$",
        "^wlt dial causal event=admitted logical_dial_id=[0-9]+ dial_attempt_id=[0-9]+ carrier_generation=[0-9]+ interface_generation=[0-9]+ deadline_remaining_ms=-?[0-9]+$",
        "^wlt dial causal event=settled logical_dial_id=[0-9]+ dial_attempt_id=[0-9]+ outcome=published cause=none$",
        "^wlt dial causal event=settled logical_dial_id=[0-9]+ dial_attempt_id=[0-9]+ outcome=(?:failed|retired_retry) cause=(?:service_stop|deadline|caller_canceled|local_retirement|carrier_failure_then_local_retirement|carrier_replaced|carrier_failure|unknown) observed_carrier_error=(?:true|false)$",
        "^wlt dial correlation event=final logical_dial_id=[0-9]+ final_attempt_id=[0-9]+ final_generation=[0-9]+ attempts=[0-9]+ outcome=(?:published|failed)$",
        "^wlt dial correlation event=retired logical_dial_id=[0-9]+ dial_attempt_id=[0-9]+ carrier_generation=[0-9]+ interface_generation=[0-9]+ retry=(?:true|false)$",
      ]
      guard patterns.contains(where: { event.range(of: $0, options: .regularExpression) != nil }) else {
        recordLifecycleEvent("(packet-tunnel): core-dial-causal rejected_unallowlisted")
        return
      }
      recordLifecycleEvent("(packet-tunnel): core-dial-causal \(event)")
    #endif
  }

  // The command log is bounded. Persist only credential-free auth lifecycle
  // events needed to audit saved-current promotion; never mirror arbitrary
  // carrier-auth messages or error payloads into packet diagnostics.
  private func recordBoundedAuthLifecycleDiagnostic(_ message: String) {
    #if os(iOS) && SFI_DEV
      guard isWhitelistTransportProfileActive,
        let context = message.range(of: "service/wlt[wlt-carrier]: ")
      else { return }
      let event = String(message[context.upperBound...])
      guard event.hasPrefix("WLT carrier auth ")
        || event.hasPrefix("WLT startup phase=provider_refresh_ready")
      else { return }
      let patterns = [
        "^WLT carrier auth event=snapshot_loaded source=current remaining_ttl_seconds=-?[0-9]+ persistence=deferred$",
        "^WLT startup phase=provider_refresh_ready elapsed_ms=[0-9]+ outcome=(not_needed|cached|refreshed)$",
        "^WLT carrier auth snapshot promoted after successful connect$",
        "^WLT carrier auth snapshot saved$",
        "^WLT carrier auth event=refresh_started source=current remaining_ttl_seconds=-?[0-9]+$",
        "^WLT carrier auth event=refresh_succeeded source=current remaining_ttl_seconds=-?[0-9]+$",
        "^WLT carrier auth refresh lifecycle event=saved_call_session_accepted category=none$",
        "^WLT carrier auth refresh lifecycle event=identity_renewal_not_entered category=none$",
        "^WLT carrier auth refresh lifecycle event=saved_call_session_rejected category=rejected$",
        "^WLT carrier auth refresh lifecycle event=calls_session_replacement_started category=none$",
        "^WLT carrier auth refresh lifecycle event=calls_session_replacement_ready category=none$",
        "^WLT carrier auth refresh lifecycle event=replacement_call_session_join_succeeded category=none$",
        "^WLT carrier auth event=fallback_started source=current_refreshed$",
        "^WLT carrier auth event=fallback_succeeded source=current_refreshed$",
        "^WLT carrier auth ring event=replenish_deferred reason=serialized_bearer_identity$",
        "^WLT carrier auth ring event=replenish_deferred retry_seconds=[0-9]+ validated=false$",
      ]
      if patterns.contains(where: { event.range(of: $0, options: .regularExpression) != nil }) {
        recordLifecycleEvent("(packet-tunnel): core-auth-lifecycle \(event)")
      } else {
        // Any other auth line, including an error with an address or token,
        // leaves an opaque disqualifying marker without exposing its payload.
        recordLifecycleEvent("(packet-tunnel): core-auth-lifecycle WLT carrier auth event=redacted_unallowlisted")
      }
    #endif
  }

  // Service close snapshots are outside the periodic heartbeat markers.
  // Validate its complete producer shape, then persist numeric fields only.
  // Reconnect errors can contain arbitrary text and must never be copied.
  private func recordBoundedServiceTerminalDiagnostic(_ message: String) {
    #if os(iOS) && SFI_DEV
      guard isWhitelistTransportProfileActive,
        let context = message.range(of: "service/wlt[wlt-carrier]: ")
      else { return }
      let event = String(message[context.upperBound...])
      guard event.hasPrefix("wlt service close_snapshot ") else { return }
      let numericFields = [
        "active", "peak_active", "draining", "peak_draining", "drain_capacity", "pending", "peak_pending", "opened", "closed",
        "queued", "dns_open_requests", "dns_open_queued", "dns_open_rejected",
        "rejected", "rejected_queue", "rejected_active", "rejected_open",
        "pressure_reclaims", "failed", "max_dial_ms", "reconnect_retries",
        "reconnect_wait_ms", "reconnects",
      ]
      let numericPattern = numericFields.map { "\($0)=[0-9]+" }.joined(separator: " ")
      let allowed = "^wlt service close_snapshot schema=2 phase=(?:pre_close close_mode=(?:graceful|abort) close_result=not_called|post_close close_mode=(?:graceful|abort) close_result=(?:returned_nil|returned_error)) closure_status=unverified snapshot_consistency=independent_reads carrier_generation=[0-9]+ " + numericPattern
        + " last_reconnect=(?:|all peers disconnected)$"
      guard event.range(of: allowed, options: .regularExpression) != nil,
        let tail = event.range(of: " last_reconnect=")
      else {
        recordLifecycleEvent("(packet-tunnel): core-service-close_snapshot rejected_unallowlisted")
        return
      }
      let reconnect = event.hasSuffix("all peers disconnected")
        ? "all_peers_disconnected" : "none"
      let numeric = String(event[..<tail.lowerBound])
      recordLifecycleEvent("(packet-tunnel): core-service-close_snapshot \(numeric) last_reconnect=\(reconnect)")
    #endif
  }

  private func beginDiagnosticsSession() {
    stopDiagnosticsHeartbeat()
    #if os(iOS)
      stopMemoryPressureDiagnostics()
    #endif
    diagnosticsSessionID = String(UUID().uuidString.prefix(8)).lowercased()
    diagnosticsStartedAt = Date()
    diagnosticsLastMemoryPressureAt = nil
    diagnosticsLastThermalState = nil
    #if os(iOS) && SFI_DEV
      diagnosticsLastMemoryRecoveryAt = nil
      diagnosticsLastMemoryRecoverySkipAt = nil
      memoryRecoveryInProgress = false
    #endif
    startDiagnosticsHeartbeat()
    #if os(iOS)
      startMemoryPressureDiagnostics()
    #endif
    recordLifecycleIncident(
      "(packet-tunnel): diagnostics session started memory=\(PacketTunnelDiagnostics.residentMemoryDescription()) thermal=\(thermalStateDescription())")
  }

  private func endDiagnosticsSession(_ reason: String) {
    recordLifecycleIncident(
      "(packet-tunnel): diagnostics session ended reason=\(reason) memory=\(PacketTunnelDiagnostics.residentMemoryDescription()) thermal=\(thermalStateDescription())")
    stopDiagnosticsHeartbeat()
    #if os(iOS)
      stopMemoryPressureDiagnostics()
    #endif
    diagnosticsSessionID = nil
    diagnosticsStartedAt = nil
    diagnosticsLastMemoryPressureAt = nil
    diagnosticsLastThermalState = nil
    #if os(iOS) && SFI_DEV
      diagnosticsLastMemoryRecoveryAt = nil
      diagnosticsLastMemoryRecoverySkipAt = nil
      memoryRecoveryInProgress = false
    #endif
  }

  private func startDiagnosticsHeartbeat() {
    stopDiagnosticsHeartbeat()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
    timer.setEventHandler { [weak self] in
      let memoryBytes = PacketTunnelDiagnostics.residentMemoryBytes()
      let memoryDescription = memoryBytes.map { PacketTunnelDiagnostics.formatBytes($0) }
        ?? "unknown"
      let thermalDescription = self?.thermalStateDescription() ?? "unknown"
      self?.recordLifecycleEvent(
        "(packet-tunnel): heartbeat memory=\(memoryDescription) thermal=\(thermalDescription)")
      #if os(iOS) && SFI_DEV
        if let self, self.isWhitelistTransportProfileActive {
          self.recordLifecycleEvent(
            "(packet-tunnel): go-memory \(LibboxWLTMemoryStatsJSON())")
          if let memoryBytes,
            memoryBytes >= Self.wltHeapProfileThreshold,
            let sessionID = self.diagnosticsSessionID
          {
            let path = FilePath.cacheDirectory
              .appendingPathComponent("wlt-heap-\(sessionID).pprof").path
            if LibboxWLTRequestHeapProfile(path) {
              self.recordLifecycleIncident(
                "(packet-tunnel): go-heap-profile requested session=\(sessionID) memory=\(memoryDescription)")
            }
          }
        }
      #endif
      if let self, thermalDescription != self.diagnosticsLastThermalState {
        let previousThermalState = self.diagnosticsLastThermalState ?? "unknown"
        self.diagnosticsLastThermalState = thermalDescription
        self.recordLifecycleIncident(
          "(packet-tunnel): thermal state changed from=\(previousThermalState) to=\(thermalDescription) memory=\(memoryDescription)")
      }
      #if os(iOS) && SFI_DEV
        if let memoryBytes {
          self?.scheduleWhitelistTransportMemoryRecoveryIfNeeded(
            memoryBytes: memoryBytes,
            reason: "heartbeat"
          )
        }
      #endif
    }
    diagnosticsHeartbeat = timer
    timer.resume()
  }

  private func stopDiagnosticsHeartbeat() {
    diagnosticsHeartbeat?.cancel()
    diagnosticsHeartbeat = nil
  }

  #if os(iOS)
    private func startMemoryPressureDiagnostics() {
      stopMemoryPressureDiagnostics()
      let source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical],
        queue: DispatchQueue.global(qos: .utility)
      )
      source.setEventHandler { [weak self] in
        guard let self, let event = self.diagnosticsMemoryPressure?.data else {
          return
        }
        let now = Date()
        if let last = self.diagnosticsLastMemoryPressureAt, now.timeIntervalSince(last) < 1 {
          return
        }
        self.diagnosticsLastMemoryPressureAt = now
        let eventDescription = self.memoryPressureDescription(event)
        let memoryBytes = PacketTunnelDiagnostics.residentMemoryBytes()
        let memoryDescription = memoryBytes.map { PacketTunnelDiagnostics.formatBytes($0) }
          ?? "unknown"
        let thermalDescription = self.thermalStateDescription()
        self.recordLifecycleIncident(
          "(packet-tunnel): memory pressure event=\(eventDescription) memory=\(memoryDescription) thermal=\(thermalDescription)")
        #if SFI_DEV
          self.recordLifecycleIncident(
            "(packet-tunnel): go-memory-pressure \(LibboxWLTMemoryStatsJSON())")
          if event.contains(.critical), self.isWhitelistTransportProfileActive,
            let sessionID = self.diagnosticsSessionID
          {
            let path = FilePath.cacheDirectory
              .appendingPathComponent("wlt-heap-\(sessionID).pprof").path
            if LibboxWLTRequestHeapProfile(path) {
              self.recordLifecycleIncident(
                "(packet-tunnel): go-heap-profile requested session=\(sessionID) reason=critical-pressure")
            }
          }
          if let memoryBytes {
            self.scheduleWhitelistTransportMemoryRecoveryIfNeeded(
              memoryBytes: memoryBytes,
              reason: "memory-pressure-\(eventDescription)"
            )
          }
        #endif
      }
      diagnosticsMemoryPressure = source
      source.resume()
    }

    private func stopMemoryPressureDiagnostics() {
      diagnosticsMemoryPressure?.cancel()
      diagnosticsMemoryPressure = nil
    }

    private func memoryPressureDescription(_ event: DispatchSource.MemoryPressureEvent) -> String {
      if event.contains(.critical) {
        return "critical"
      }
      if event.contains(.warning) {
        return "warning"
      }
      if event.contains(.normal) {
        return "normal"
      }
      return "raw(\(event.rawValue))"
    }

    #if SFI_DEV
      private var isWhitelistTransportProfileActive: Bool {
      guard (tunnelOptions?["whitelistTransportEnabled"] as? NSNumber)?.boolValue ?? false else {
        return false
      }
      if whitelistTransportClient != nil {
        return true
      }
      return whitelistTransportProfileIsCore
    }

    private func scheduleWhitelistTransportMemoryRecoveryIfNeeded(
      memoryBytes: UInt64,
      reason: String
    ) {
      guard isWhitelistTransportProfileActive, commandServer != nil else {
        return
      }
      let threshold = whitelistTransportMemoryRecoveryThreshold()
      guard memoryBytes >= threshold else {
        return
      }
      let urgentThreshold = whitelistTransportMemoryRecoveryUrgentThreshold()
      let now = Date()
      let isUrgent = memoryBytes >= urgentThreshold
      if shouldDeferWhitelistTransportMemoryRecovery(isUrgent: isUrgent) {
        recordMemoryRecoverySkipIfNeeded(
          now: now,
          reason: reason,
          cause: "thermal=\(thermalStateDescription())",
          memoryBytes: memoryBytes,
          threshold: threshold
        )
        return
      }
      if memoryRecoveryInProgress {
        recordMemoryRecoverySkipIfNeeded(
          now: now,
          reason: reason,
          cause: "in-progress",
          memoryBytes: memoryBytes
        )
        return
      }
      if let lastRecovery = diagnosticsLastMemoryRecoveryAt {
        let elapsed = now.timeIntervalSince(lastRecovery)
        let cooldown = whitelistTransportMemoryRecoveryCooldown(isUrgent: isUrgent)
        if elapsed < cooldown {
          let remaining = cooldown - elapsed
          recordMemoryRecoverySkipIfNeeded(
            now: now,
            reason: reason,
            cause: "cooldown remaining=\(formatDuration(remaining))",
            memoryBytes: memoryBytes
          )
          return
        }
      }
      memoryRecoveryInProgress = true
      diagnosticsLastMemoryRecoveryAt = now
      diagnosticsLastMemoryRecoverySkipAt = nil
      let recoveryMode = isUrgent ? "urgent" : "normal"
      recordLifecycleIncident(
        "(packet-tunnel): memory recovery scheduled mode=\(recoveryMode) reason=\(reason) memory=\(PacketTunnelDiagnostics.formatBytes(memoryBytes)) threshold=\(PacketTunnelDiagnostics.formatBytes(threshold)) urgentThreshold=\(PacketTunnelDiagnostics.formatBytes(urgentThreshold)) thermal=\(thermalStateDescription())")
      Task { [weak self] in
        await self?.performWhitelistTransportMemoryRecovery(reason: reason)
      }
    }

    private func recordMemoryRecoverySkipIfNeeded(
      now: Date,
      reason: String,
      cause: String,
      memoryBytes: UInt64,
      threshold: UInt64? = nil
    ) {
      if let lastSkip = diagnosticsLastMemoryRecoverySkipAt,
        now.timeIntervalSince(lastSkip) < Self.whitelistTransportMemoryRecoverySkipLogInterval
      {
        return
      }
      diagnosticsLastMemoryRecoverySkipAt = now
      let thresholdDescription = threshold.map { PacketTunnelDiagnostics.formatBytes($0) }
        ?? PacketTunnelDiagnostics.formatBytes(
          Self.whitelistTransportMemoryRecoveryThresholdDefault)
      recordLifecycleEvent(
        "(packet-tunnel): memory recovery skipped reason=\(reason) cause=\(cause) memory=\(PacketTunnelDiagnostics.formatBytes(memoryBytes)) threshold=\(thresholdDescription) thermal=\(thermalStateDescription())")
    }

    private func performWhitelistTransportMemoryRecovery(reason: String) async {
      let recoveryStartedAt = Date()
      recordLifecycleIncident(
        "(packet-tunnel): memory recovery started reason=\(reason) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      defer {
        memoryRecoveryInProgress = false
      }
      do {
        if isCoreWhitelistTransportProfile() {
          let restartError = NSError(
            domain: "WhitelistTransportMemoryRecovery",
            code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Core WLT memory recovery requested a clean provider restart"
            ]
          )
          recordLifecycleIncident(
            "(packet-tunnel): memory recovery requesting core provider restart reason=\(reason) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
          cancelTunnelWithError(restartError)
          return
        }
        try await reloadService()
        recordLifecycleIncident(
          "(packet-tunnel): memory recovery completed reason=\(reason) elapsed=\(formatDuration(Date().timeIntervalSince(recoveryStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      } catch {
        recordLifecycleIncident(
          "(packet-tunnel): memory recovery failed reason=\(reason) error=\(error.localizedDescription) elapsed=\(formatDuration(Date().timeIntervalSince(recoveryStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      }
    }

    private func whitelistTransportMemoryRecoveryThreshold() -> UInt64 {
      uint64Option("whitelistTransportMemoryRecoveryThreshold")
        ?? (
          isCoreWhitelistTransportProfile()
            ? Self.whitelistTransportMemoryRecoveryThresholdCore
            : Self.whitelistTransportMemoryRecoveryThresholdDefault
        )
    }

    private func whitelistTransportMemoryRecoveryUrgentThreshold() -> UInt64 {
      uint64Option("whitelistTransportMemoryRecoveryUrgentThreshold")
        ?? (
          isCoreWhitelistTransportProfile()
            ? Self.whitelistTransportMemoryRecoveryUrgentThresholdCore
            : Self.whitelistTransportMemoryRecoveryUrgentThresholdDefault
        )
    }

    private func whitelistTransportMemoryRecoveryCooldown(isUrgent: Bool) -> TimeInterval {
      if isUrgent {
        return timeIntervalOption("whitelistTransportMemoryRecoveryUrgentCooldown")
          ?? (
            isCoreWhitelistTransportProfile()
              ? Self.whitelistTransportMemoryRecoveryUrgentCooldownCore
              : Self.whitelistTransportMemoryRecoveryUrgentCooldownDefault
          )
      }
      return timeIntervalOption("whitelistTransportMemoryRecoveryCooldown")
        ?? (
          isCoreWhitelistTransportProfile()
            ? Self.whitelistTransportMemoryRecoveryCooldownCore
            : Self.whitelistTransportMemoryRecoveryCooldownDefault
        )
    }

    private func uint64Option(_ key: String) -> UInt64? {
      if let number = tunnelOptions?[key] as? NSNumber {
        return number.uint64Value
      }
      if let string = tunnelOptions?[key] as? String, let value = UInt64(string) {
        return value
      }
      return nil
    }

    private func timeIntervalOption(_ key: String) -> TimeInterval? {
      if let number = tunnelOptions?[key] as? NSNumber {
        return number.doubleValue
      }
      if let string = tunnelOptions?[key] as? String, let value = Double(string) {
        return value
      }
      return nil
    }

    private func isCoreWhitelistTransportProfile() -> Bool {
      whitelistTransportProfileIsCore
    }

      private func shouldDeferWhitelistTransportMemoryRecovery(isUrgent: Bool) -> Bool {
      guard !isUrgent else {
        return false
      }
      switch ProcessInfo.processInfo.thermalState {
      case .serious, .critical:
        return true
      default:
        return false
      }
      }
    #endif

  #endif

  private func thermalStateDescription() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown(\(ProcessInfo.processInfo.thermalState.rawValue))"
    }
  }

  private func recordLifecycleEvent(_ message: String) {
    let enrichedMessage = enrichDiagnosticsMessage(message)
    PacketTunnelDiagnostics.append(enrichedMessage)
    Self.logger.info("\(enrichedMessage, privacy: .public)")
  }

  private func recordLifecycleIncident(_ message: String) {
    let enrichedMessage = enrichDiagnosticsMessage(message)
    PacketTunnelDiagnostics.append(enrichedMessage)
    PacketTunnelDiagnostics.appendIncident(enrichedMessage)
    Self.logger.warning("\(enrichedMessage, privacy: .public)")
  }

  private func writeLifecycleMessage(_ message: String) {
    recordLifecycleEvent(message)
    writeMessage(message)
  }

  private func enrichDiagnosticsMessage(_ message: String) -> String {
    var fields: [String] = []
    if let diagnosticsSessionID {
      fields.append("session=\(diagnosticsSessionID)")
    }
    if let diagnosticsStartedAt {
      fields.append("uptime=\(formatDuration(Date().timeIntervalSince(diagnosticsStartedAt)))")
    }
    guard !fields.isEmpty else {
      return message
    }
    return "\(message) [\(fields.joined(separator: " "))]"
  }

  private func recordStartupStage(
    _ stage: String,
    startedAt: Date,
    totalStartedAt: Date? = nil
  ) {
    var details = "stage=\(stage) elapsed=\(formatDuration(Date().timeIntervalSince(startedAt)))"
    if let totalStartedAt {
      details += " total=\(formatDuration(Date().timeIntervalSince(totalStartedAt)))"
    }
    details += " memory=\(PacketTunnelDiagnostics.residentMemoryDescription())"
    recordLifecycleEvent("(packet-tunnel): startup \(details)")
  }

  private func recordNetworkPathSnapshot(stage: String) {
    let interfaces = systemInterfaceNames()
    let utunCount = interfaces.filter { $0.hasPrefix("utun") }.count
    let pathDescription = currentNetworkPathDescription()
    let preferencesDescription =
      "includeAllNetworks=\(overridePreferences?.includeAllNetworks ?? false) excludeDefaultRoute=\(overridePreferences?.excludeDefaultRoute ?? false) excludeAPNsRoute=\(overridePreferences?.excludeAPNsRoute ?? false)"
    recordLifecycleEvent(
      "(packet-tunnel): network snapshot stage=\(stage) path=\(pathDescription) system_interfaces=\(interfaces.joined(separator: ",")) utun_count=\(utunCount) \(preferencesDescription)"
    )
  }

  private func currentNetworkPathDescription() -> String {
    let monitor = Network.NWPathMonitor()
    let semaphore = DispatchSemaphore(value: 0)
    let queue = DispatchQueue.global(qos: .utility)
    var description: String?
    monitor.pathUpdateHandler = { path in
      description = self.describeNetworkPath(path)
      semaphore.signal()
    }
    monitor.start(queue: queue)
    if semaphore.wait(timeout: .now() + .seconds(1)) == .timedOut {
      description = "timeout current=\(describeNetworkPath(monitor.currentPath))"
    }
    monitor.cancel()
    return description ?? "unavailable"
  }

  private func describeNetworkPath(_ path: Network.NWPath) -> String {
    let availableInterfaces = path.availableInterfaces.map {
      "\($0.name):\(networkInterfaceTypeDescription($0.type))"
    }.joined(separator: ",")
    return
      "status=\(networkPathStatusDescription(path.status)) expensive=\(path.isExpensive) constrained=\(path.isConstrained) available=\(availableInterfaces.isEmpty ? "none" : availableInterfaces)"
  }

  private func networkPathStatusDescription(_ status: Network.NWPath.Status) -> String {
    switch status {
    case .satisfied:
      return "satisfied"
    case .unsatisfied:
      return "unsatisfied"
    case .requiresConnection:
      return "requiresConnection"
    @unknown default:
      return "unknown"
    }
  }

  private func networkInterfaceTypeDescription(_ type: Network.NWInterface.InterfaceType) -> String {
    switch type {
    case .wifi:
      return "wifi"
    case .cellular:
      return "cellular"
    case .wiredEthernet:
      return "ethernet"
    case .loopback:
      return "loopback"
    case .other:
      return "other"
    @unknown default:
      return "unknown"
    }
  }

  private func systemInterfaceNames() -> [String] {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let firstAddress else {
      return ["unavailable"]
    }
    defer {
      freeifaddrs(firstAddress)
    }

    var names = Set<String>()
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = cursor {
      if let name = current.pointee.ifa_name {
        names.insert(String(cString: name))
      }
      cursor = current.pointee.ifa_next
    }
    return names.sorted()
  }

  private func formatDuration(_ interval: TimeInterval) -> String {
    String(format: "%.3fs", max(0, interval))
  }

  private func currentStopTunnelGeneration() -> UInt64 {
    lifecycleStateLock.lock()
    defer {
      lifecycleStateLock.unlock()
    }
    return stopTunnelGeneration
  }

  private func markStopTunnelRequested() {
    lifecycleStateLock.lock()
    stopTunnelGeneration &+= 1
    lifecycleStateLock.unlock()
  }

  private func throwIfStopTunnelRequested(since generation: UInt64) throws {
    if currentStopTunnelGeneration() != generation {
      throw ExtensionStartupError("(packet-tunnel) error: start service canceled by stopTunnel")
    }
  }

  private func startService() async throws {
    guard var configContent = tunnelOptions?["configContent"] as? String else {
      throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
    }
    #if SFI_DEV
      if whitelistTransportProfileIsCore {
        let snapshotFile = try WLTAuthStorage.snapshotURL(
          library: FilePath.sharedDirectory.appendingPathComponent("Library", isDirectory: true),
          legacy: FilePath.cacheDirectory.appendingPathComponent("WLT", isDirectory: true))
        PacketTunnelDiagnostics.appendStartupMilestone(
          FileManager.default.fileExists(atPath: snapshotFile.path)
            ? "wlt_snapshot_file_present" : "wlt_snapshot_file_missing")
        let injectedConfig = WhitelistTransportConfig.injectingCoreAuthSnapshotFile(
          into: configContent,
          snapshotFile: snapshotFile,
          legacySnapshotFile: FilePath.cacheDirectory.appendingPathComponent("WLT", isDirectory: true).appendingPathComponent("auth-snapshot.json"))
        if injectedConfig != configContent {
          writeLifecycleMessage("(packet-tunnel): core whitelist transport auth snapshot cache configured")
          configContent = injectedConfig
        }
      }
    #endif

    let options = LibboxOverrideOptions()
    do {
      try commandServer!.startOrReloadService(configContent, options: options)
    } catch {
      throw ExtensionStartupError(
        "(packet-tunnel) error: start service: \(error.localizedDescription)")
    }
    #if os(macOS)
      if !Variant.useSystemExtension, commandServer!.needWIFIState() {
        locationManager = CLLocationManager()
        locationDelegate = stubLocationDelegate()
        locationManager!.delegate = locationDelegate
        locationManager!.requestLocation()
      }
    #endif
  }

  #if os(macOS)

    class stubLocationDelegate: NSObject, CLLocationManagerDelegate {
      func locationManagerDidChangeAuthorization(_: CLLocationManager) {}

      func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}

      func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
    }

  #endif

  func stopService() {
    do {
      try commandServer?.closeService()
    } catch {
      let description = error.localizedDescription
      if !description.localizedCaseInsensitiveContains("invalid argument") {
        writeLifecycleMessage("(packet-tunnel) stop service: \(description)")
      }
    }
    #if os(iOS) && SFI_DEV
      stopWhitelistTransport()
    #endif
    platformInterface.reset()
  }

  func reloadService() async throws {
    let reloadStartedAt = Date()
    writeLifecycleMessage("(packet-tunnel) reloading service")
    reasserting = true
    defer {
      reasserting = false
    }
    #if os(iOS) && SFI_DEV
      if let tunnelOptions {
        let stageStartedAt = Date()
        try startWhitelistTransportIfNeeded(tunnelOptions)
        recordStartupStage(
          "reload-whitelist-transport",
          startedAt: stageStartedAt,
          totalStartedAt: reloadStartedAt
        )
      }
    #endif
    let singBoxStartedAt = Date()
    writeLifecycleMessage("(packet-tunnel): starting sing-box service")
    try await startService()
    writeLifecycleMessage(
      "(packet-tunnel): sing-box service started elapsed=\(formatDuration(Date().timeIntervalSince(singBoxStartedAt))) reloadTotal=\(formatDuration(Date().timeIntervalSince(reloadStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
  }

  override open func stopTunnel(with reason: NEProviderStopReason) async {
    let reasonDescription = stopReasonDescription(reason)
    markStopTunnelRequested()
    writeLifecycleMessage("(packet-tunnel) stopping, reason: \(reasonDescription)")
    stopDiagnosticsHeartbeat()
    stopService()
    if let server = commandServer {
      try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
      server.close()
      commandServer = nil
    }
    #if os(macOS)
      if Variant.useSystemExtension {
        xpcService.markServiceNotReady(
          NSError(
            domain: "CommandXPC", code: -1,
            userInfo: [
              NSLocalizedDescriptionKey: "Command server stopped"
            ]))
        xpcListener.invalidate()
        xpcListener = nil
        xpcService.commandServer = nil
        xpcService = nil
        UserServiceEndpointRegistry.shared.clear()
      }
      locationManager = nil
      locationDelegate = nil
    #endif
    #if os(iOS)
      if #available(iOS 18.0, *) {
        await ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
      }
    #endif
    endDiagnosticsSession("stopTunnel completed reason=\(reasonDescription)")
  }

  override open func handleAppMessage(_ messageData: Data) async -> Data? {
    #if os(iOS) && SFI_DEV
      if ExtensionDiagnosticMessage.isDiagnostic(messageData) {
        return handleDiagnosticMessage(messageData)
      }
    #endif
    do {
      let options = try ExtensionStartOptions.decode(messageData)
      applyStartOptions(options)
      try persistStartOptions(options)
      try await reloadService()
      return nil
    } catch {
      return error.localizedDescription.data(using: .utf8)
    }
  }

  #if os(iOS) && SFI_DEV
    // Same CLOCK_UPTIME_RAW domain as the retained network callbacks. Zero
    // declines timing evidence; a diagnostic clock failure cannot change I/O.
    private static func explicitProbeUptimeNanos() -> Int64 {
      var value = timespec()
      guard clock_gettime(CLOCK_UPTIME_RAW, &value) == 0 else { return 0 }
      return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }

    private func handleDiagnosticMessage(_ messageData: Data) -> Data? {
      let request: ExtensionDiagnosticMessage.Request
      do {
        request = try ExtensionDiagnosticMessage.decodeRequest(messageData)
      } catch {
        return try? ExtensionDiagnosticMessage.encodeResponse(
          ExtensionDiagnosticMessage.Response(
            version: 1, status: "failed", resultJSON: nil,
            errorCode: "invalid_diagnostic_envelope"))
      }
      guard let commandServer else {
        return try? ExtensionDiagnosticMessage.encodeResponse(
          ExtensionDiagnosticMessage.Response(
            version: 1, status: "failed", resultJSON: nil,
            errorCode: "command_server_unavailable"))
      }
      let response: ExtensionDiagnosticMessage.Response
      do {
        // Hash the exact existing core request bytes, never a destination,
        // bearer or request body. Pair markers do not assert success or ACK.
        let probeDigest = SHA256.hash(data: Data(request.requestJSON.utf8))
          .map { String(format: "%02x", $0) }.joined()
        var coreCallReturned = false
        var probeError: NSError?
        recordLifecycleEvent(
          "(packet-tunnel): wlt-explicit-probe schema=1 phase=start request_sha256=\(probeDigest) uptime_ns=\(Self.explicitProbeUptimeNanos())")
        defer {
          recordLifecycleEvent(
            "(packet-tunnel): wlt-explicit-probe schema=1 phase=end request_sha256=\(probeDigest) uptime_ns=\(Self.explicitProbeUptimeNanos()) core_call_returned=\(coreCallReturned) core_error=\(probeError != nil)")
        }
        let resultJSON = commandServer.probeWltOutbound(
          request.requestJSON, error: &probeError)
        coreCallReturned = true
        if let probeError {
          response = ExtensionDiagnosticMessage.Response(
            version: 1, status: "failed", resultJSON: nil,
            errorCode: ExtensionDiagnosticMessage.probeErrorCode(probeError))
          return try? ExtensionDiagnosticMessage.encodeResponse(response)
        }
        guard resultJSON.utf8.count <= 16 * 1024 else {
          response = ExtensionDiagnosticMessage.Response(
            version: 1, status: "failed", resultJSON: nil,
            errorCode: "result_too_large")
          return try? ExtensionDiagnosticMessage.encodeResponse(response)
        }
        response = ExtensionDiagnosticMessage.Response(
          version: 1, status: "success", resultJSON: resultJSON,
          errorCode: "")
      } catch {
        // Core probe errors are deliberately collapsed to a bounded code.
        // The core result carries its own sanitized network failure details.
        response = ExtensionDiagnosticMessage.Response(
          version: 1, status: "failed", resultJSON: nil,
          errorCode: "probe_rejected")
      }
      return try? ExtensionDiagnosticMessage.encodeResponse(response)
    }
  #endif

  override open func sleep() async {
    writeLifecycleMessage("(packet-tunnel): sleep")
    if let commandServer {
      commandServer.pause()
    }
  }

  override open func wake() {
    writeLifecycleMessage("(packet-tunnel): wake")
    if let commandServer {
      commandServer.wake()
    }
  }

  private func stopReasonDescription(_ reason: NEProviderStopReason) -> String {
    switch reason {
    case .none:
      return "none"
    case .userInitiated:
      return "userInitiated"
    case .providerFailed:
      return "providerFailed"
    case .noNetworkAvailable:
      return "noNetworkAvailable"
    case .unrecoverableNetworkChange:
      return "unrecoverableNetworkChange"
    case .providerDisabled:
      return "providerDisabled"
    case .authenticationCanceled:
      return "authenticationCanceled"
    case .configurationFailed:
      return "configurationFailed"
    case .idleTimeout:
      return "idleTimeout"
    case .configurationDisabled:
      return "configurationDisabled"
    case .configurationRemoved:
      return "configurationRemoved"
    case .superceded:
      return "superceded"
    case .userLogout:
      return "userLogout"
    case .userSwitch:
      return "userSwitch"
    case .connectionFailed:
      return "connectionFailed"
    case .sleep:
      return "sleep"
    case .appUpdate:
      return "appUpdate"
    default:
      return "unknown(\(reason.rawValue))"
    }
  }

  #if os(iOS) && SFI_DEV
    private func startWhitelistTransportIfNeeded(_ options: [String: NSObject]) throws {
      stopWhitelistTransport()
      let enabled = (options["whitelistTransportEnabled"] as? NSNumber)?.boolValue ?? false
      guard enabled else {
        return
      }
      if let configContent = options["configContent"] as? String,
        WhitelistTransportConfig.usesCoreWhitelistTransport(configContent)
      {
        writeLifecycleMessage(
          "(packet-tunnel): core whitelist transport detected; sidecar skipped")
        return
      }
      let transportStartedAt = Date()
      let transport =
        ((options["whitelistTransportType"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "telemost"
      let wltOptions = LibboxWhitelistTransportOptions()
      wltOptions.transport = transport

      switch transport {
      case "turnable":
        let turnableConfig =
          (options["whitelistTransportTurnableConfig"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !turnableConfig.isEmpty else {
          throw ExtensionStartupError(
            "(packet-tunnel) error: whitelist transport Turnable config is not configured")
        }
        wltOptions.turnableConfig = turnableConfig
        wltOptions.turnableListeners =
          (options["whitelistTransportTurnableListeners"] as? String)
          ?? "direct=127.0.0.1:12100,eu=127.0.0.1:12101,ru=127.0.0.1:12102"
        wltOptions.startTimeoutMS = 90_000
        writeLifecycleMessage(
          "(packet-tunnel): starting whitelist transport transport=turnable listeners=\(sanitizeWhitelistTransportSOCKS(wltOptions.turnableListeners))")
      case "telemost":
        let telemostLink =
          (options["whitelistTransportTelemostLink"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !telemostLink.isEmpty else {
          throw ExtensionStartupError(
            "(packet-tunnel) error: whitelist transport Telemost link is not configured")
        }
        wltOptions.socks =
          (options["whitelistTransportSOCKSListeners"] as? String)
          ?? "direct=127.0.0.1:11080,eu=127.0.0.1:11081,dns=127.0.0.1:11082"
        if !wltOptions.socks.contains("dns=") {
          wltOptions.socks += ",dns=127.0.0.1:11082"
        }
        wltOptions.telemostLink = telemostLink
        wltOptions.telemostDisplayName =
          (options["whitelistTransportDisplayName"] as? String) ?? "WLT Client"
        wltOptions.telemostVP8FPS =
          (options["whitelistTransportVP8FPS"] as? NSNumber)?.int32Value ?? 12
        wltOptions.telemostVP8Batch =
          (options["whitelistTransportVP8Batch"] as? NSNumber)?.int32Value ?? 10
        wltOptions.telemostPayloadSize =
          (options["whitelistTransportPayloadSize"] as? NSNumber)?.int32Value ?? 0
        wltOptions.startTimeoutMS = 45_000
        writeLifecycleMessage(
          "(packet-tunnel): starting whitelist transport transport=telemost socks=\(sanitizeWhitelistTransportSOCKS(wltOptions.socks)) fps=\(wltOptions.telemostVP8FPS) batch=\(wltOptions.telemostVP8Batch) payload=\(wltOptions.telemostPayloadSize)")
      default:
        throw ExtensionStartupError(
          "(packet-tunnel) error: unsupported whitelist transport: \(transport)")
      }

      var error: NSError?
      whitelistTransportClient = LibboxStartWhitelistTransport(wltOptions, &error)
      if let error {
        whitelistTransportClient = nil
        throw ExtensionStartupError(
          "(packet-tunnel) error: start whitelist transport: \(error.localizedDescription)")
      }
      writeLifecycleMessage(
        "(packet-tunnel): whitelist transport started elapsed=\(formatDuration(Date().timeIntervalSince(transportStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
    }

    private func stopWhitelistTransport() {
      guard let client = whitelistTransportClient else {
        return
      }
      let transportStoppedAt = Date()
      do {
        try client.close()
      } catch {
        writeLifecycleMessage("(packet-tunnel) stop whitelist transport: \(error.localizedDescription)")
      }
      whitelistTransportClient = nil
      writeLifecycleMessage(
        "(packet-tunnel): whitelist transport stopped elapsed=\(formatDuration(Date().timeIntervalSince(transportStoppedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
    }

    private func sanitizeWhitelistTransportSOCKS(_ socks: String) -> String {
      socks
        .split(separator: ",")
        .compactMap { item -> String? in
          let parts = item.split(separator: "=", maxSplits: 1)
          guard let key = parts.first else {
            return nil
          }
          return String(key)
        }
        .joined(separator: ",")
    }
  #endif
}
