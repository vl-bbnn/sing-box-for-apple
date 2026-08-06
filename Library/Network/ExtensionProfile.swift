import Foundation
import Libbox
import NetworkExtension
import os

#if os(iOS)
  import FileProvider
#endif

private let logger = Logger(category: "ExtensionProfile")

@MainActor
public class ExtensionProfile: ObservableObject {
  public static let controlKind = AppConfiguration.widgetControlKind

  private let manager: NEVPNManager?
  private var connection: NEVPNConnection?
  private var observer: Any?
  private let isMock: Bool

  @Published public var status: NEVPNStatus
  @Published public var connectedDate: Date?

  private func traceDeviceStart(_ stage: String, error: Error? = nil) {
    #if os(iOS) && SFI_DEV
    let message: String
    if let error {
      message = "WLT_DEVICE_START stage=\(stage) status=\(status.rawValue) error=\(error.localizedDescription)"
    } else {
      message = "WLT_DEVICE_START stage=\(stage) status=\(status.rawValue)"
    }
    NSLog("%@", message)
    PacketTunnelDiagnostics.append("(app): \(message)")
    #endif
  }

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
    if isMock {
      status = .connecting
      try await Task.sleep(nanoseconds: 500_000_000)
      status = .connected
      connectedDate = Date()
      return
    }
    guard let manager else { return }
    traceDeviceStart("entered")
    traceDeviceStart("fetch_profile_begin")
    try await fetchProfile()
    traceDeviceStart("fetch_profile_done")
    manager.isEnabled = true
    let alwaysOn = await SharedPreferences.alwaysOn.get()
    let onDemandEnabled = await SharedPreferences.onDemandEnabled.get()
    if alwaysOn || onDemandEnabled {
      manager.isOnDemandEnabled = true
      await setOnDemandRules(useDefaultRules: alwaysOn)
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
    traceDeviceStart("save_preferences_begin")
    try await manager.saveToPreferences()
    traceDeviceStart("save_preferences_done")
    traceDeviceStart("prepare_options_begin")
    let options = try await prepareStartOptions()
    traceDeviceStart("prepare_options_done")
    #if os(macOS)
      let whitelistTransportStarted = try await WhitelistTransportManager.shared.startIfNeeded()
    #endif
    do {
      traceDeviceStart("start_tunnel_begin")
      try manager.connection.startVPNTunnel(options: options)
      traceDeviceStart("start_tunnel_done")
    } catch {
      traceDeviceStart("start_tunnel_failed", error: error)
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

  private func prepareStartOptions() async throws -> [String: NSObject] {
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

    let configContent = try await profile.readAsync()
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
        options["whitelistTransportMemoryRecoveryThreshold"] = NSNumber(value: 48 * 1024 * 1024)
        options["whitelistTransportMemoryRecoveryUrgentThreshold"] = NSNumber(value: 56 * 1024 * 1024)
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
    traceDeviceStart("stop_entered")
    if manager.isOnDemandEnabled {
      if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
        var config = proto.providerConfiguration ?? [:]
        config["wasOnDemandEnabled"] = true
        proto.providerConfiguration = config
      }
      manager.isOnDemandEnabled = false
      try await manager.saveToPreferences()
    }
    traceDeviceStart("stop_tunnel_begin")
    manager.connection.stopVPNTunnel()
    traceDeviceStart("stop_tunnel_done")
    Task.detached(priority: .utility) {
      do {
        try LibboxNewStandaloneCommandClient()!.serviceClose()
      } catch {
        logger.debug("serviceClose error: \(error.localizedDescription)")
      }
    }
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
    let providerBundleIdentifier = Variant.useSystemExtension
      ? AppConfiguration.systemExtensionBundleID
      : AppConfiguration.extensionBundleID
    let matchingManagers = managers.filter { manager in
      guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
        return false
      }
      return tunnelProtocol.providerBundleIdentifier == providerBundleIdentifier
    }
    #if os(iOS) && SFI_DEV
      let statuses = matchingManagers
        .map { "\($0.connection.status.rawValue):\($0.localizedDescription ?? "")" }
        .joined(separator: ",")
      let message = "WLT_DEVICE_PROFILE stage=load managers=\(managers.count) matching=\(matchingManagers.count) active=\(matchingManagers.filter { $0.connection.status.isConnected }.count) statuses=\(statuses)"
      NSLog("%@", message)
      PacketTunnelDiagnostics.append("(app): \(message)")
    #endif
    guard !matchingManagers.isEmpty else {
      return nil
    }
    let manager = matchingManagers.first(where: { $0.connection.status.isConnected })
      ?? matchingManagers.first(where: { $0.localizedDescription == Variant.applicationName })
      ?? matchingManagers[0]
    return ExtensionProfile(manager)
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
