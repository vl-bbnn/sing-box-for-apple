import Foundation
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
  enum ServiceCloseResult: Equatable {
    case succeeded
    case failed(String)
    case inProgress
  }

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
  private let lifecycleStateLock = NSLock()
  private var stopTunnelGeneration: UInt64 = 0
  #if os(iOS) && SFI_DEV
    private let serviceLifecycleInitLock = NSLock()
    private var serviceLifecycleStorage: WLTStopOrchestrator?
    private var serviceLifecycle: WLTStopOrchestrator {
      serviceLifecycleInitLock.lock()
      defer { serviceLifecycleInitLock.unlock() }
      if let serviceLifecycleStorage { return serviceLifecycleStorage }
      let lifecycle = WLTStopOrchestrator(dependencies: .init(
      retainOwner: { [weak self] in self },
      closeCore: { [weak self] in
        guard let self else { throw NSError(domain: "WLTStop", code: 1) }
        guard let server = self.commandServer else {
          // Failed startup can stop before creating a core. An existing
          // lifetime journal, however, requires an actual close proof.
          guard self.wltCoreLifetimeJournal == nil else { throw NSError(domain: "WLTStop", code: 1) }
          return
        }
        try server.closeService()
      },
      closeJournal: { [weak self] coreClosed, reason in
        guard let self else { throw NSError(domain: "WLTStop", code: 1) }
        if let journal = self.wltCoreLifetimeJournal {
          // A closed core retires this journal even when evidence persistence
          // fails. Keep its disk evidence and old outcome; never attach it to
          // the next lifecycle. A failed core still owns its journal/resources.
          defer { if coreClosed { self.wltCoreLifetimeJournal = nil } }
          if coreClosed {
            try journal.didCloseService(reason: reason, finalizeSession: true, terminalObserversConfirmed: true)
          } else {
            try journal.didFailToCloseService(reason: reason, errorDescription: "core_close_failed", finalizeSession: true)
          }
        }
      },
      closeSidecar: { [weak self] in
        guard let self, self.stopWhitelistTransport() else { throw NSError(domain: "WLTStop", code: 2) }
      },
      resetPlatform: { [weak self] in
        guard let self else { throw NSError(domain: "WLTStop", code: 1) }
        self.platformInterface.reset()
      },
      closeServer: { [weak self] in
        guard let self else { throw NSError(domain: "WLTStop", code: 1) }
        self.commandServer?.close()
        self.commandServer = nil
      },
      finishDiagnostics: { [weak self] in
        guard let self else { throw NSError(domain: "WLTStop", code: 1) }
        self.stopDiagnosticsHeartbeat()
        self.endDiagnosticsSession("owned stop completed")
      },
      record: { stage, operationID, lifecycle in
        PacketTunnelDiagnostics.appendStopStage(stage.rawValue, operationID: operationID,
          requestID: operationID, canonicalOperationID: operationID, lifecycle: lifecycle)
      }
    ))
      serviceLifecycleStorage = lifecycle
      return lifecycle
    }
  #endif

  public private(set) var commandServer: LibboxCommandServer?
  private lazy var platformInterface = ExtensionPlatformInterface(self)
  public var tunnelOptions: [String: NSObject]?
  private var startOptionsURL: URL?
  private var whitelistTransportProfileIsCore = false
  #if os(iOS) && SFI_DEV
    private var wltCoreLifetimeJournal: WLTCoreLifetimeJournal?
  #endif
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
    #if os(iOS) && SFI_DEV
      // Admission precedes diagnostics; a rejected concurrent start cannot
      // replace or end the running lifecycle's diagnostic session.
      let lifecycleToken = try serviceLifecycle.beginTunnelStart(commandServerAbsent: commandServer == nil)
      defer { serviceLifecycle.finishTransition(lifecycleToken) }
    #endif
    beginDiagnosticsSession()
    PacketTunnelDiagnostics.appendStartupMilestone("extension_started")
    recordLifecycleEvent("(packet-tunnel): startTunnel entered")
    do {
      #if os(iOS) && SFI_DEV
        try await startTunnelImpl(options: startOptions, lifecycleToken: lifecycleToken)
      #else
        try await startTunnelImpl(options: startOptions)
      #endif
    } catch {
      recordLifecycleEvent("(packet-tunnel): startTunnel failed: \(error.localizedDescription)")
      #if os(iOS) && SFI_DEV
        // The deferred transition release allows the same owner to clean up
        // partial startup, including a stop racing the startup failure.
        _ = requestOwnedStopService(operationID: UUID().uuidString.lowercased(), journalCloseReason: "start_failed")
      #else
        endDiagnosticsSession("startTunnel failed")
      #endif
      throw error
    }
  }

  private func startTunnelImpl(options startOptions: [String: NSObject]?, lifecycleToken: UInt64? = nil) async throws {
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
      #if os(iOS) && SFI_DEV
        try throwIfStopTunnelRequested(since: startStopGeneration, lifecycleToken: lifecycleToken)
      #else
        try throwIfStopTunnelRequested(since: startStopGeneration)
      #endif
      recordNetworkPathSnapshot(stage: "before-start-service")
      writeLifecycleMessage("(packet-tunnel): starting sing-box service")
      PacketTunnelDiagnostics.appendStartupMilestone("core_starting")
      try await startService(expectedStopGeneration: startStopGeneration)
      #if os(iOS) && SFI_DEV
        try throwIfStopTunnelRequested(since: startStopGeneration, lifecycleToken: lifecycleToken)
      #else
        try throwIfStopTunnelRequested(since: startStopGeneration)
      #endif
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
    if let commandServer {
      commandServer.writeMessage(2, message: message)
    }
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

  private func throwIfStopTunnelRequested(since generation: UInt64, lifecycleToken: UInt64? = nil) throws {
    #if os(iOS) && SFI_DEV
      if currentStopTunnelGeneration() != generation {
        throw ExtensionStartupError("(packet-tunnel) error: start service canceled by stopTunnel")
      }
      do {
        guard let lifecycleToken else { throw WLTStopOrchestrator.AdmissionError.stopRequested }
        try serviceLifecycle.throwIfStopRequested(lifecycleToken)
      } catch {
        throw ExtensionStartupError("(packet-tunnel) error: start service canceled by stop intent")
      }
    #else
      if currentStopTunnelGeneration() != generation {
        throw ExtensionStartupError("(packet-tunnel) error: start service canceled by stopTunnel")
      }
    #endif
  }

  #if os(iOS) && SFI_DEV
    private func beginReloadTransition() throws -> UInt64 {
      do {
        return try serviceLifecycle.beginReload()
      } catch {
        throw ExtensionStartupError("(packet-tunnel) error: reload rejected during terminal stop")
      }
    }
  #endif

  private func startService(expectedStopGeneration: UInt64) async throws {
    guard var configContent = tunnelOptions?["configContent"] as? String else {
      throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
    }
    #if os(iOS) && SFI_DEV
      var preparedJournalGeneration: WLTCoreLifetimeJournal.PreparedGeneration?
    #endif
    #if SFI_DEV
      if whitelistTransportProfileIsCore {
        let snapshotFile = FilePath.cacheDirectory
          .appendingPathComponent("WLT", isDirectory: true)
          .appendingPathComponent("auth-snapshot.json", isDirectory: false)
        PacketTunnelDiagnostics.appendStartupMilestone(
          FileManager.default.fileExists(atPath: snapshotFile.path)
            ? "wlt_snapshot_file_present" : "wlt_snapshot_file_missing")
        let injectedConfig = WhitelistTransportConfig.injectingCoreAuthSnapshotFile(
          into: configContent,
          snapshotFile: snapshotFile)
        if injectedConfig != configContent {
          writeLifecycleMessage("(packet-tunnel): core whitelist transport auth snapshot cache configured")
          configContent = injectedConfig
        }
        #if os(iOS)
          if wltCoreLifetimeJournal == nil {
            let journalRoot = FilePath.cacheDirectory
              .appendingPathComponent("WLT", isDirectory: true)
              .appendingPathComponent("LifetimeJournals", isDirectory: true)
            try? WLTCoreLifetimeJournal.enforceRetention(
              in: journalRoot,
              keepingLatestSealedSessions: 4
            )
            wltCoreLifetimeJournal = try WLTCoreLifetimeJournal(rootDirectory: journalRoot)
          }
          guard let journal = wltCoreLifetimeJournal else {
            throw ExtensionStartupError("(packet-tunnel) error: create WLT lifetime journal")
          }
          let prepared = try journal.prepareGeneration(configContent: configContent)
          preparedJournalGeneration = prepared
          configContent = prepared.configContent
        #endif
      }
    #endif

    let options = LibboxOverrideOptions()
    do {
      try commandServer!.startOrReloadService(configContent, options: options)
    } catch {
      #if os(iOS) && SFI_DEV
        // A throwing libbox reload may leave the preceding core alive. Close
        // admission before releasing the caller's lifecycle transition; the
        // existing owner waits for that release before touching the resources.
        // Do not let a later reload overwrite an ambiguous generation.
        _ = requestOwnedStopService(
          operationID: UUID().uuidString.lowercased(),
          journalCloseReason: "start_or_reload_failed"
        )
        if let preparedJournalGeneration {
          try? wltCoreLifetimeJournal?.didFailToStartGeneration(
            preparedJournalGeneration,
            errorDescription: error.localizedDescription
          )
        }
      #endif
      throw ExtensionStartupError(
        "(packet-tunnel) error: start service: \(error.localizedDescription)")
    }
    #if os(iOS) && SFI_DEV
      if let preparedJournalGeneration {
        // r2 propagates the prior Instance.Close result before it starts this generation.
        try? wltCoreLifetimeJournal?.didStartGeneration(
          preparedJournalGeneration,
          previousGenerationCloseConfirmed: true
        )
      }
    #endif
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

  // Non-diagnostic platforms retain their existing synchronous service close.
  #if !(os(iOS) && SFI_DEV)
  @discardableResult
  func stopService() -> ServiceCloseResult {
    do {
      try commandServer?.closeService()
      platformInterface.reset()
      return .succeeded
    } catch { return .failed(error.localizedDescription) }
  }
  #endif

  func reloadService() async throws {
    try await reloadServiceWithOptions(nil)
  }

  // One admission covers option persistence/mutation and the complete reload.
  // A rejected app request cannot alter the running or next-start config.
  private func reloadServiceWithOptions(_ options: [String: NSObject]?) async throws {
    let reloadStartedAt = Date()
    let reloadStopGeneration = currentStopTunnelGeneration()
    #if os(iOS) && SFI_DEV
      let lifecycleToken = try beginReloadTransition()
      defer { serviceLifecycle.finishTransition(lifecycleToken) }
      try throwIfStopTunnelRequested(since: reloadStopGeneration, lifecycleToken: lifecycleToken)
    #else
      try throwIfStopTunnelRequested(since: reloadStopGeneration)
    #endif
    if let options {
      try persistStartOptions(options)
      applyStartOptions(options)
    }
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
    #if os(iOS) && SFI_DEV
      try throwIfStopTunnelRequested(since: reloadStopGeneration, lifecycleToken: lifecycleToken)
    #else
      try throwIfStopTunnelRequested(since: reloadStopGeneration)
    #endif
    writeLifecycleMessage("(packet-tunnel): starting sing-box service")
    try await startService(expectedStopGeneration: reloadStopGeneration)
    #if os(iOS) && SFI_DEV
      try throwIfStopTunnelRequested(since: reloadStopGeneration, lifecycleToken: lifecycleToken)
    #else
      try throwIfStopTunnelRequested(since: reloadStopGeneration)
    #endif
    writeLifecycleMessage(
      "(packet-tunnel): sing-box service started elapsed=\(formatDuration(Date().timeIntervalSince(singBoxStartedAt))) reloadTotal=\(formatDuration(Date().timeIntervalSince(reloadStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
  }

  #if os(iOS) && SFI_DEV
    func requestOwnedStopService(operationID: String, journalCloseReason: String) -> WLTStopReply {
      serviceLifecycle.request(operationID: operationID, reason: journalCloseReason)
    }

    func lookupOwnedStopService(lifecycle: UInt64, operationID: String) -> WLTStopReply? {
      serviceLifecycle.lookup(lifecycle: lifecycle, operationID: operationID)
    }

    func waitOwnedStopService(_ reply: WLTStopReply, timeout: TimeInterval = 20) async throws -> WLTStopReply {
      try await serviceLifecycle.wait(for: reply, timeout: timeout)
    }
  #endif

  override open func stopTunnel(with reason: NEProviderStopReason) async {
    #if os(iOS) && SFI_DEV
      let reply = requestOwnedStopService(operationID: UUID().uuidString.lowercased(), journalCloseReason: "tunnel_stop_\(stopReasonDescription(reason))")
      // Deadline/cancellation ends only this waiter. The owner completes server
      // and diagnostic teardown even when this callback has already returned.
      do { _ = try await waitOwnedStopService(reply) }
      catch { return }
    #else
      let reasonDescription = stopReasonDescription(reason)
      markStopTunnelRequested()
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
    #endif
  }

  override open func handleAppMessage(_ messageData: Data) async -> Data? {
    #if os(iOS) && SFI_DEV
      if ExtensionDiagnosticMessage.isDiagnostic(messageData) {
        return handleDiagnosticMessage(messageData)
      }
    #endif
    do {
      let options = try ExtensionStartOptions.decode(messageData)
      try await reloadServiceWithOptions(options)
      return nil
    } catch {
      return error.localizedDescription.data(using: .utf8)
    }
  }

  #if os(iOS) && SFI_DEV
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
      if request.operation == "poll_wlt_service_close" {
        guard let key = try? ExtensionDiagnosticMessage.decodeStopKey(request.requestJSON),
          let reply = lookupOwnedStopService(lifecycle: key.lifecycle, operationID: key.operationID) else {
          return try? ExtensionDiagnosticMessage.encodeResponse(
            ExtensionDiagnosticMessage.Response(version: 1, status: "failed", resultJSON: nil, errorCode: "service_close_unknown_operation"))
        }
        return try? ExtensionDiagnosticMessage.encodeStopReply(reply)
      }
      if request.operation == "close_wlt_service" {
        let reply = requestOwnedStopService(operationID: request.requestJSON, journalCloseReason: "app_provider_message_stop")
        return try? ExtensionDiagnosticMessage.encodeStopReply(reply)

      }
      guard let commandServer else {
        return try? ExtensionDiagnosticMessage.encodeResponse(
          ExtensionDiagnosticMessage.Response(
            version: 1, status: "failed", resultJSON: nil,
            errorCode: "command_server_unavailable"))
      }
      let response: ExtensionDiagnosticMessage.Response
      do {
        var probeError: NSError?
        let resultJSON = commandServer.probeWltOutbound(
          request.requestJSON, error: &probeError)
        if let probeError {
          throw probeError
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
      try WLTSidecarReplacement.perform(close: { stopWhitelistTransport() }, start: {
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
      })
    }

    @discardableResult
    private func stopWhitelistTransport() -> Bool {
      guard let client = whitelistTransportClient else {
        return true
      }
      let transportStoppedAt = Date()
      do {
        try client.close()
      } catch {
        writeLifecycleMessage("(packet-tunnel) stop whitelist transport: \(error.localizedDescription)")
        return false
      }
      whitelistTransportClient = nil
      writeLifecycleMessage(
        "(packet-tunnel): whitelist transport stopped elapsed=\(formatDuration(Date().timeIntervalSince(transportStoppedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      return true
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
