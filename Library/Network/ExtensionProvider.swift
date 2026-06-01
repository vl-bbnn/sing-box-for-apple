import Foundation
import Libbox
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
  private static let defaultLogMaxLines = 3000
  private static let whitelistTransportLogMaxLines = 300
  private static let whitelistTransportOOMMemoryLimit: Int64 = 44 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryThreshold: UInt64 = 42 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryUrgentThreshold: UInt64 = 44 * 1024 * 1024
  private static let whitelistTransportMemoryRecoveryCooldown: TimeInterval = 20
  private static let whitelistTransportMemoryRecoverySkipLogInterval: TimeInterval = 30

  public private(set) var commandServer: LibboxCommandServer?
  private lazy var platformInterface = ExtensionPlatformInterface(self)
  public var tunnelOptions: [String: NSObject]?
  private var startOptionsURL: URL?
  #if os(iOS)
    private var whitelistTransportClient: LibboxWhitelistTransportClient?
    private var diagnosticsMemoryPressure: DispatchSourceMemoryPressure?
    private var diagnosticsLastMemoryRecoveryAt: Date?
    private var diagnosticsLastMemoryRecoverySkipAt: Date?
    private var memoryRecoveryInProgress = false
  #endif
  private var diagnosticsSessionID: String?
  private var diagnosticsStartedAt: Date?
  private var diagnosticsHeartbeat: DispatchSourceTimer?
  private var diagnosticsLastMemoryPressureAt: Date?

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

    let options = LibboxSetupOptions()
    options.basePath = basePath
    options.workingPath = workingPath
    options.tempPath = tempPath

    let whitelistTransportEnabled =
      (effectiveOptions["whitelistTransportEnabled"] as? NSNumber)?.boolValue ?? false
    if whitelistTransportEnabled {
      options.logMaxLines = Self.whitelistTransportLogMaxLines
      #if os(iOS)
        options.oomMemoryLimit = Self.whitelistTransportOOMMemoryLimit
      #endif
    } else {
      options.logMaxLines = Self.defaultLogMaxLines
    }
    recordLifecycleEvent(
      "(packet-tunnel): libbox resource policy whitelistTransport=\(whitelistTransportEnabled) logMaxLines=\(options.logMaxLines) oomMemoryLimit=\(options.oomMemoryLimit)")

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
    #if os(iOS)
      stageStartedAt = Date()
      try startWhitelistTransportIfNeeded(effectiveOptions)
      recordStartupStage(
        "whitelist-transport", startedAt: stageStartedAt, totalStartedAt: startupStartedAt)
    #endif
    do {
      stageStartedAt = Date()
      writeLifecycleMessage("(packet-tunnel): starting sing-box service")
      try await startService()
      writeLifecycleMessage(
        "(packet-tunnel): sing-box service started elapsed=\(formatDuration(Date().timeIntervalSince(stageStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
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
    #if os(iOS)
      diagnosticsLastMemoryRecoveryAt = nil
      diagnosticsLastMemoryRecoverySkipAt = nil
      memoryRecoveryInProgress = false
    #endif
    startDiagnosticsHeartbeat()
    #if os(iOS)
      startMemoryPressureDiagnostics()
    #endif
    recordLifecycleEvent(
      "(packet-tunnel): diagnostics session started memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
  }

  private func endDiagnosticsSession(_ reason: String) {
    recordLifecycleEvent(
      "(packet-tunnel): diagnostics session ended reason=\(reason) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
    stopDiagnosticsHeartbeat()
    #if os(iOS)
      stopMemoryPressureDiagnostics()
    #endif
    diagnosticsSessionID = nil
    diagnosticsStartedAt = nil
    diagnosticsLastMemoryPressureAt = nil
    #if os(iOS)
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
      self?.recordLifecycleEvent("(packet-tunnel): heartbeat memory=\(memoryDescription)")
      #if os(iOS)
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
        self.recordLifecycleEvent(
          "(packet-tunnel): memory pressure event=\(eventDescription) memory=\(memoryDescription)")
        if let memoryBytes {
          self.scheduleWhitelistTransportMemoryRecoveryIfNeeded(
            memoryBytes: memoryBytes,
            reason: "memory-pressure-\(eventDescription)"
          )
        }
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

    private var isWhitelistTransportActive: Bool {
      ((tunnelOptions?["whitelistTransportEnabled"] as? NSNumber)?.boolValue ?? false)
        && whitelistTransportClient != nil
    }

    private func scheduleWhitelistTransportMemoryRecoveryIfNeeded(
      memoryBytes: UInt64,
      reason: String
    ) {
      guard isWhitelistTransportActive, commandServer != nil else {
        return
      }
      guard memoryBytes >= Self.whitelistTransportMemoryRecoveryThreshold else {
        return
      }
      let now = Date()
      let isUrgent = memoryBytes >= Self.whitelistTransportMemoryRecoveryUrgentThreshold
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
        if !isUrgent && elapsed < Self.whitelistTransportMemoryRecoveryCooldown {
          let remaining = Self.whitelistTransportMemoryRecoveryCooldown - elapsed
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
      recordLifecycleEvent(
        "(packet-tunnel): memory recovery scheduled mode=\(recoveryMode) reason=\(reason) memory=\(PacketTunnelDiagnostics.formatBytes(memoryBytes)) threshold=\(PacketTunnelDiagnostics.formatBytes(Self.whitelistTransportMemoryRecoveryThreshold)) urgentThreshold=\(PacketTunnelDiagnostics.formatBytes(Self.whitelistTransportMemoryRecoveryUrgentThreshold))")
      Task { [weak self] in
        await self?.performWhitelistTransportMemoryRecovery(reason: reason)
      }
    }

    private func recordMemoryRecoverySkipIfNeeded(
      now: Date,
      reason: String,
      cause: String,
      memoryBytes: UInt64
    ) {
      if let lastSkip = diagnosticsLastMemoryRecoverySkipAt,
        now.timeIntervalSince(lastSkip) < Self.whitelistTransportMemoryRecoverySkipLogInterval
      {
        return
      }
      diagnosticsLastMemoryRecoverySkipAt = now
      recordLifecycleEvent(
        "(packet-tunnel): memory recovery skipped reason=\(reason) cause=\(cause) memory=\(PacketTunnelDiagnostics.formatBytes(memoryBytes)) threshold=\(PacketTunnelDiagnostics.formatBytes(Self.whitelistTransportMemoryRecoveryThreshold))")
    }

    private func performWhitelistTransportMemoryRecovery(reason: String) async {
      let recoveryStartedAt = Date()
      recordLifecycleEvent(
        "(packet-tunnel): memory recovery started reason=\(reason) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      defer {
        memoryRecoveryInProgress = false
      }
      do {
        try await reloadService()
        recordLifecycleEvent(
          "(packet-tunnel): memory recovery completed reason=\(reason) elapsed=\(formatDuration(Date().timeIntervalSince(recoveryStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      } catch {
        recordLifecycleEvent(
          "(packet-tunnel): memory recovery failed reason=\(reason) error=\(error.localizedDescription) elapsed=\(formatDuration(Date().timeIntervalSince(recoveryStartedAt))) memory=\(PacketTunnelDiagnostics.residentMemoryDescription())")
      }
    }
  #endif

  private func recordLifecycleEvent(_ message: String) {
    let enrichedMessage = enrichDiagnosticsMessage(message)
    PacketTunnelDiagnostics.append(enrichedMessage)
    Self.logger.info("\(enrichedMessage, privacy: .public)")
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

  private func formatDuration(_ interval: TimeInterval) -> String {
    String(format: "%.3fs", max(0, interval))
  }

  private func startService() async throws {
    guard let configContent = tunnelOptions?["configContent"] as? String else {
      throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
    }

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
    #if os(iOS)
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
    #if os(iOS)
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
        ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
      }
    #endif
    endDiagnosticsSession("stopTunnel completed reason=\(reasonDescription)")
  }

  override open func handleAppMessage(_ messageData: Data) async -> Data? {
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
    @unknown default:
      return "unknown(\(reason.rawValue))"
    }
  }

  #if os(iOS)
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
