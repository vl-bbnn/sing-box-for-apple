import Foundation
import Libbox
import NetworkExtension
import os

#if os(iOS)
  import FileProvider
#endif

private let logger = Logger(category: "ExtensionProfile")

#if os(iOS) && SFI_DEV
  enum ExtensionDiagnosticMessage {
    private static let magic = Data("SFI_DEV_DIAGNOSTIC\0".utf8)
    private static let maximumMessageBytes = 32 * 1024

    struct Request: Codable {
      let version: Int
      let operation: String
      let requestJSON: String

      enum CodingKeys: String, CodingKey {
        case version, operation
        case requestJSON = "request_json"
      }
    }

    struct Response: Codable {
      let version: Int
      let status: String
      let resultJSON: String?
      let errorCode: String

      enum CodingKeys: String, CodingKey {
        case version, status
        case resultJSON = "result_json"
        case errorCode = "error_code"
      }
    }

    static func isDiagnostic(_ data: Data) -> Bool {
      data.starts(with: magic)
    }

    static func encodeProbeRequest(_ requestJSON: String) throws -> Data {
      try encode(
        Request(
          version: 1,
          operation: "probe_wlt_outbound",
          requestJSON: requestJSON
        ))
    }

    static func decodeRequest(_ data: Data) throws -> Request {
      let payload = try payload(data)
      guard
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
        Set(object.keys) == Set(["version", "operation", "request_json"])
      else {
        throw CocoaError(.coderInvalidValue)
      }
      let request: Request = try decode(data)
      guard
        request.version == 1,
        request.operation == "probe_wlt_outbound",
        !request.requestJSON.isEmpty,
        request.requestJSON.utf8.count <= 16 * 1024
      else {
        throw CocoaError(.coderInvalidValue)
      }
      return request
    }

    static func encodeResponse(_ response: Response) throws -> Data {
      try encode(response)
    }

    static func decodeResponse(_ data: Data) throws -> Response {
      let responsePayload = try payload(data)
      guard
        let object = try JSONSerialization.jsonObject(with: responsePayload) as? [String: Any],
        Set(object.keys).isSubset(of: Set(["version", "status", "result_json", "error_code"])),
        Set(["version", "status", "error_code"]).isSubset(of: Set(object.keys))
      else {
        throw CocoaError(.coderInvalidValue)
      }
      let response: Response = try decode(data)
      guard
        response.version == 1,
        ["success", "failed"].contains(response.status),
        response.errorCode.count <= 64,
        response.resultJSON?.utf8.count ?? 0 <= 16 * 1024,
        (response.status == "success" && response.errorCode.isEmpty
          && response.resultJSON != nil)
          || (response.status == "failed" && !response.errorCode.isEmpty
            && response.resultJSON == nil)
      else {
        throw CocoaError(.coderInvalidValue)
      }
      return response
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let payload = try encoder.encode(value)
      guard payload.count + magic.count <= maximumMessageBytes else {
        throw CocoaError(.coderInvalidValue)
      }
      return magic + payload
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
      try JSONDecoder().decode(T.self, from: payload(data))
    }

    private static func payload(_ data: Data) throws -> Data {
      guard isDiagnostic(data), data.count <= maximumMessageBytes else {
        throw CocoaError(.coderInvalidValue)
      }
      return Data(data.dropFirst(magic.count))
    }
  }

  private final class ExtensionDiagnosticResponseWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?

    func install(_ continuation: CheckedContinuation<Data?, Error>) {
      lock.lock()
      self.continuation = continuation
      lock.unlock()
    }

    func resume(_ result: Result<Data?, Error>) {
      lock.lock()
      let pending = continuation
      continuation = nil
      lock.unlock()
      guard let pending else { return }
      pending.resume(with: result)
    }
  }
#endif

@MainActor
public class ExtensionProfile: ObservableObject {
  public static let controlKind = AppConfiguration.widgetControlKind

  private let manager: NEVPNManager?
  private var connection: NEVPNConnection?
  private var observer: Any?
  private let isMock: Bool

  @Published public var status: NEVPNStatus
  @Published public var connectedDate: Date?

  public init(_ manager: NEVPNManager) {
    self.manager = manager
    connection = manager.connection
    status = manager.connection.status
    connectedDate = manager.connection.connectedDate
    isMock = false
  }

  private init(mockStatus: NEVPNStatus, mockConnectedDate: Date?) {
    manager = nil
    connection = nil
    status = mockStatus
    connectedDate = mockConnectedDate
    isMock = true
  }

  private static var _mock: ExtensionProfile?

  public static var mock: ExtensionProfile {
    if _mock == nil {
      _mock = ExtensionProfile(
        mockStatus: .connected, mockConnectedDate: Date().addingTimeInterval(-3600))
    }
    return _mock!
  }

  public func register() {
    guard !isMock, let manager else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NEVPNStatusDidChange,
      object: manager.connection,
      queue: nil
    ) { [weak self] notification in
      guard let connection = notification.object as? NEVPNConnection else {
        return
      }
      Task { @MainActor in
        guard let self else {
          return
        }
        self.connection = connection
        self.status = connection.status
        self.connectedDate = connection.connectedDate
        #if os(macOS)
          if connection.status == .disconnected || connection.status == .invalid {
            await WhitelistTransportManager.shared.stop()
          }
        #endif
        #if os(iOS)
          if #available(iOS 16.0, *) {
            if connection.status == .connected || connection.status == .disconnected {
              Self.signalFileProviderChanges()
            }
          }
        #endif
      }
    }
  }

  #if os(iOS)
    @available(iOS 16.0, *)
    private static func signalFileProviderChanges() {
      Task.detached {
        guard
          let domain = try? await NSFileProviderManager.domains()
            .first(where: { $0.identifier.rawValue == AppConfiguration.fileProviderDomainID }),
          let manager = NSFileProviderManager(for: domain)
        else {
          return
        }
        try? await manager.signalEnumerator(for: .workingSet)
      }
    }
  #endif

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private static func makeDefaultOnDemandRules() -> [NEOnDemandRule] {
    let rule = NEOnDemandRuleConnect()
    rule.interfaceTypeMatch = .any
    rule.probeURL = URL(string: "http://captive.apple.com")
    return [rule]
  }

  private func setOnDemandRules(useDefaultRules: Bool) async {
    guard let manager else { return }
    if useDefaultRules {
      manager.onDemandRules = Self.makeDefaultOnDemandRules()
    } else {
      let rules = await SharedPreferences.onDemandRules.get()
      manager.onDemandRules =
        rules.isEmpty ? Self.makeDefaultOnDemandRules() : rules.map { $0.toNERule() }
    }
  }

  public func updateOnDemand(enabled: Bool, useDefaultRules: Bool) async throws {
    guard let manager else { return }
    manager.isOnDemandEnabled = enabled
    if !enabled {
      if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
        var config = proto.providerConfiguration ?? [:]
        if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
          proto.providerConfiguration = config
        }
      }
    }
    await setOnDemandRules(useDefaultRules: useDefaultRules)
    try await manager.saveToPreferences()
  }

  @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
  public func fetchLastDisconnectError() async throws {
    guard let connection else { return }
    try await connection.fetchLastDisconnectError()
  }

  public func start() async throws {
    try await start(configContentTransform: nil)
  }

  #if SFI_DEV
    public func start(
      wltRuntimeParameters: WhitelistTransportConfig.RuntimeParameters?
    ) async throws {
      let transform = wltRuntimeParameters.map { parameters in
        { configContent in
          try WhitelistTransportConfig.applyingRuntimeParameters(
            parameters,
            to: configContent
          )
        }
      }
      try await start(configContentTransform: transform)
    }
  #endif

  private func start(
    configContentTransform: ((String) throws -> String)?
  ) async throws {
    if isMock {
      status = .connecting
      try await Task.sleep(nanoseconds: 500_000_000)
      status = .connected
      connectedDate = Date()
      return
    }
    guard let manager else { return }
    try await fetchProfile()
    #if SFI_DEV
      PacketTunnelDiagnostics.appendStartupMilestone("profile_loaded")
    #endif
    let options = try await prepareStartOptions(
      configContentTransform: configContentTransform
    )
    manager.isEnabled = true
    let alwaysOn = await SharedPreferences.alwaysOn.get()
    let onDemandEnabled = await SharedPreferences.onDemandEnabled.get()
    #if os(iOS) && SFI_DEV
      let whitelistTransportAutoRecovery =
        (options["whitelistTransportEnabled"] as? NSNumber)?.boolValue ?? false
    #else
      let whitelistTransportAutoRecovery = false
    #endif
    if alwaysOn || onDemandEnabled || whitelistTransportAutoRecovery {
      manager.isOnDemandEnabled = true
      await setOnDemandRules(
        useDefaultRules: alwaysOn || whitelistTransportAutoRecovery
      )
    }
    if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
      var config = proto.providerConfiguration ?? [:]
      if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
        proto.providerConfiguration = config
      }
    }
    #if !os(tvOS)
      if let protocolConfiguration = manager.protocolConfiguration {
        let includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
        protocolConfiguration.includeAllNetworks = includeAllNetworks
        protocolConfiguration.excludeLocalNetworks = await SharedPreferences.excludeLocalNetworks
          .get()
        protocolConfiguration.enforceRoutes = await SharedPreferences.enforceRoutes.get()
        if #available(iOS 16.4, macOS 13.3, *) {
          protocolConfiguration.excludeAPNs = await SharedPreferences.excludeAPNs.get()
          protocolConfiguration.excludeCellularServices =
            await SharedPreferences.excludeCellularServices.get()
        }
        if #available(iOS 17.4, macOS 14.4, *) {
          protocolConfiguration.excludeDeviceCommunication =
            await SharedPreferences.excludeDeviceCommunication.get()
        }
      }
    #endif
    try await manager.saveToPreferences()
    #if SFI_DEV
      PacketTunnelDiagnostics.appendStartupMilestone("start_options_ready")
    #endif
    #if os(macOS)
      let whitelistTransportStarted = try await WhitelistTransportManager.shared.startIfNeeded()
    #endif
    do {
      try manager.connection.startVPNTunnel(options: options)
      #if SFI_DEV
        PacketTunnelDiagnostics.appendStartupMilestone("extension_start_requested")
      #endif
    } catch {
      #if os(macOS)
        if whitelistTransportStarted {
          await WhitelistTransportManager.shared.stop()
        }
      #endif
      throw error
    }
  }

  public func reloadService() async throws {
    if isMock { return }
    #if os(macOS)
      try await WhitelistTransportManager.shared.startIfNeeded()
    #endif
    let options = try await prepareStartOptions()
    let data = try ExtensionStartOptions.encode(options)
    guard let session = connection as? NETunnelProviderSession else {
      throw NSError(
        domain: "ExtensionStartOptions", code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Tunnel session unavailable"
        ])
    }
    let response = try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(data) { response in
          continuation.resume(returning: response)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    if let response, !response.isEmpty {
      let message = String(data: response, encoding: .utf8) ?? "Unknown error"
      throw NSError(
        domain: "ExtensionStartOptions", code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: message
        ])
    }
  }

  #if os(iOS) && SFI_DEV
    public func probeWltOutbound(
      _ requestJSON: String,
      timeoutMillis: Int
    ) async throws -> String {
      guard !isMock, let session = connection as? NETunnelProviderSession else {
        throw NSError(
          domain: "ExtensionDiagnosticMessage", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Tunnel session unavailable"])
      }
      guard status == .connected else {
        throw NSError(
          domain: "ExtensionDiagnosticMessage", code: -2,
          userInfo: [NSLocalizedDescriptionKey: "Tunnel is not connected"])
      }
      guard (1...95_000).contains(timeoutMillis) else {
        throw NSError(
          domain: "ExtensionDiagnosticMessage", code: -5,
          userInfo: [NSLocalizedDescriptionKey: "Diagnostic timeout invalid"])
      }
      let message = try ExtensionDiagnosticMessage.encodeProbeRequest(requestJSON)
      let waiter = ExtensionDiagnosticResponseWaiter()
      let responseData = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data?, Error>) in
        waiter.install(continuation)
        DispatchQueue.global(qos: .utility).asyncAfter(
          deadline: .now() + .milliseconds(timeoutMillis)
        ) {
          waiter.resume(
            .failure(
              NSError(
                domain: "ExtensionDiagnosticMessage", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Diagnostic response timeout"])))
        }
        do {
          try session.sendProviderMessage(message) { response in
            waiter.resume(.success(response))
          }
        } catch {
          waiter.resume(.failure(error))
        }
      }
      guard let responseData else {
        throw NSError(
          domain: "ExtensionDiagnosticMessage", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Diagnostic response unavailable"])
      }
      let response = try ExtensionDiagnosticMessage.decodeResponse(responseData)
      guard response.status == "success", response.errorCode.isEmpty,
        let resultJSON = response.resultJSON
      else {
        throw NSError(
          domain: "ExtensionDiagnosticMessage", code: -4,
          userInfo: [NSLocalizedDescriptionKey: response.errorCode])
      }
      return resultJSON
    }
  #endif

  private func prepareStartOptions(
    configContentTransform: ((String) throws -> String)? = nil
  ) async throws -> [String: NSObject] {
    var options: [String: NSObject] = [
      "manualStart": NSNumber(value: true)
    ]

    let profileID = await SharedPreferences.selectedProfileID.get()
    guard let profile = try await ProfileManager.get(profileID) else {
      throw NSError(
        domain: "ExtensionProfile", code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Missing selected profile"
        ])
    }

    var configContent = try await profile.readAsync()
    if let configContentTransform {
      configContent = try configContentTransform(configContent)
    }
    options["configContent"] = NSString(string: configContent)

    #if !os(macOS)
      options["ignoreMemoryLimit"] = await NSNumber(
        value: SharedPreferences.ignoreMemoryLimit.get())
    #endif
    options["systemProxyEnabled"] = await NSNumber(
      value: SharedPreferences.systemProxyEnabled.get())
    options["excludeDefaultRoute"] = await NSNumber(
      value: SharedPreferences.excludeDefaultRoute.get())
    options["autoRouteUseSubRangesByDefault"] = await NSNumber(
      value: SharedPreferences.autoRouteUseSubRangesByDefault.get())
    options["excludeAPNsRoute"] = await NSNumber(value: SharedPreferences.excludeAPNsRoute.get())

    #if os(iOS) && SFI_DEV
      let usesCoreWhitelistTransport = WhitelistTransportConfig.usesCoreWhitelistTransport(configContent)
      let usesLegacyWhitelistTransport = WhitelistTransportConfig.usesLegacyWhitelistTransport(configContent)
      if usesCoreWhitelistTransport {
        options["whitelistTransportEnabled"] = NSNumber(value: true)
        options["whitelistTransportMemoryRecoveryThreshold"] = NSNumber(value: 45 * 1024 * 1024)
        options["whitelistTransportMemoryRecoveryUrgentThreshold"] = NSNumber(value: 47 * 1024 * 1024)
        options["whitelistTransportMemoryRecoveryCooldown"] = NSNumber(value: 45)
        options["whitelistTransportMemoryRecoveryUrgentCooldown"] = NSNumber(value: 20)
      }
      if usesLegacyWhitelistTransport, let bootstrapURL = WhitelistTransportConfig.bootstrapURL(for: profile.remoteURL) {
        do {
          let bootstrapContent = try await HTTPClient.getStringAsync(bootstrapURL)
          for (key, value) in try WhitelistTransportConfig.parseBootstrapOptions(bootstrapContent) {
            options[key] = value
          }
        } catch {
          throw NSError(
            domain: "WhitelistTransport", code: -1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Failed to load whitelist transport bootstrap: \(error.localizedDescription)"
            ])
        }
      } else if usesLegacyWhitelistTransport {
        throw NSError(
          domain: "WhitelistTransport", code: -1,
          userInfo: [
            NSLocalizedDescriptionKey: "Missing remote URL for whitelist transport bootstrap"
          ])
      }
    #endif

    #if !os(tvOS)
      options["includeAllNetworks"] = await NSNumber(
        value: SharedPreferences.includeAllNetworks.get())
    #endif

    #if os(tvOS)
      options["commandServerPort"] = await NSNumber(
        value: SharedPreferences.commandServerPort.get())
      options["commandServerSecret"] = await NSString(
        string: SharedPreferences.commandServerSecret.get())
    #endif

    return options
  }

  public func fetchProfile() async throws {
    let profileID = await SharedPreferences.selectedProfileID.get()
    if let profile = try await ProfileManager.get(profileID), profile.type == .icloud {
      _ = try await profile.readAsync()
    }
  }

  public func stop() async throws {
    if isMock {
      status = .disconnecting
      try await Task.sleep(nanoseconds: 300_000_000)
      status = .disconnected
      connectedDate = nil
      return
    }
    guard let manager else { return }
    if manager.isOnDemandEnabled {
      if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
        var config = proto.providerConfiguration ?? [:]
        config["wasOnDemandEnabled"] = true
        proto.providerConfiguration = config
      }
      manager.isOnDemandEnabled = false
      try await manager.saveToPreferences()
    }
    #if os(iOS) && SFI_DEV
      // Finish the journal-owning service close while the packet tunnel still
      // has ordinary runtime, before NetworkExtension begins its stop grace.
      do {
        try await Task.detached(priority: .utility) {
          // The Go RPC context bounds the caller's wait; canceling this Swift
          // task cannot interrupt the synchronous server handler.
          try LibboxNewStandaloneCommandClient()!.serviceCloseWithTimeout(20_000)
        }.value
      } catch {
        logger.debug("serviceClose error: \(error.localizedDescription)")
      }
      manager.connection.stopVPNTunnel()
    #else
      manager.connection.stopVPNTunnel()
      Task.detached(priority: .utility) {
        do {
          try LibboxNewStandaloneCommandClient()!.serviceClose()
        } catch {
          logger.debug("serviceClose error: \(error.localizedDescription)")
        }
      }
    #endif
    #if os(macOS)
      await WhitelistTransportManager.shared.stop()
    #endif
  }

  public func restart() async throws {
    try await stop()
    var waitSeconds = 0
    while status != .disconnected {
      try await Task.sleep(nanoseconds: NSEC_PER_SEC)
      waitSeconds += 1
      if waitSeconds >= 5 {
        throw NSError(
          domain: "ExtensionProfile", code: 0,
          userInfo: [NSLocalizedDescriptionKey: String(localized: "Restart service timeout")])
      }
    }
    try await start()
  }

  public static func load() async throws -> ExtensionProfile? {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    if managers.isEmpty {
      return nil
    }
    return ExtensionProfile(managers[0])
  }

  public static func install() async throws {
    let manager = NETunnelProviderManager()
    manager.localizedDescription = Variant.applicationName
    let tunnelProtocol = NETunnelProviderProtocol()
    if Variant.useSystemExtension {
      tunnelProtocol.providerBundleIdentifier = AppConfiguration.systemExtensionBundleID
    } else {
      tunnelProtocol.providerBundleIdentifier = AppConfiguration.extensionBundleID
    }
    tunnelProtocol.serverAddress = "sing-box"
    manager.protocolConfiguration = tunnelProtocol
    manager.isEnabled = true
    try await manager.saveToPreferences()
  }
}
