import Foundation

#if SFI_DEV
  import CryptoKit
#endif

#if SFI_DEV
  import CoreFoundation
#endif

public enum WhitelistTransportConfig {
  public static let bootstrapPathComponent = "whitelist-transport"

  #if SFI_DEV
  public struct RuntimeParameters: Codable, Equatable {
    public let maxActive: Int
    public let maxOpen: Int
    public let dnsOpenReserve: Int
    public let maxPending: Int
    public let queueTimeout: String
    public let idleTimeout: String
    public let peerWriteBuffer: Int
    public let kcpWindow: Int
    public let kcpBuffer: Int
    public let vlessMuxProtocol: String?
    public let vlessMuxMaxConnections: Int?
    public let vlessMuxMinStreams: Int?

    enum CodingKeys: String, CodingKey {
      case maxActive = "max_active"
      case maxOpen = "max_open"
      case dnsOpenReserve = "dns_open_reserve"
      case maxPending = "max_pending"
      case queueTimeout = "queue_timeout"
      case idleTimeout = "idle_timeout"
      case peerWriteBuffer = "peer_write_buffer"
      case kcpWindow = "kcp_window"
      case kcpBuffer = "kcp_buffer"
      case vlessMuxProtocol = "vless_mux_protocol"
      case vlessMuxMaxConnections = "vless_mux_max_connections"
      case vlessMuxMinStreams = "vless_mux_min_streams"
    }
  }

  public enum RuntimeCandidateError: Int, Error {
    case invalidEnvelope = 1
    case invalidSchema = 2
    case invalidValue = 3
    case invalidConfig = 4
    case missingWLTService = 5
    case multipleWLTServices = 6
    case missingWLTVLESSOutbound = 7
  }

  private static let runtimeParameterKeys: Set<String> = [
    "max_active",
    "max_open",
    "dns_open_reserve",
    "max_pending",
    "queue_timeout",
    "idle_timeout",
    "peer_write_buffer",
    "kcp_window",
    "kcp_buffer",
  ]

  private static let vlessMuxParameterKeys: Set<String> = [
    "vless_mux_protocol",
    "vless_mux_max_connections",
    "vless_mux_min_streams",
  ]

  public static func decodeRuntimeCandidate(_ data: Data) throws -> RuntimeParameters {
    guard
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(envelope.keys) == ["parameters"],
      let parameters = envelope["parameters"] as? [String: Any]
    else {
      throw RuntimeCandidateError.invalidEnvelope
    }
    let parameterKeys = Set(parameters.keys)
    guard
      parameterKeys == runtimeParameterKeys
        || parameterKeys == runtimeParameterKeys.union(vlessMuxParameterKeys)
    else {
      throw RuntimeCandidateError.invalidSchema
    }
    guard
      let maxActive = strictInteger(parameters["max_active"]),
      let maxOpen = strictInteger(parameters["max_open"]),
      let dnsOpenReserve = strictInteger(parameters["dns_open_reserve"]),
      let maxPending = strictInteger(parameters["max_pending"]),
      let queueTimeout = parameters["queue_timeout"] as? String,
      let idleTimeout = parameters["idle_timeout"] as? String,
      let peerWriteBuffer = strictInteger(parameters["peer_write_buffer"]),
      let kcpWindow = strictInteger(parameters["kcp_window"]),
      let kcpBuffer = strictInteger(parameters["kcp_buffer"]),
      maxActive > 0,
      maxOpen > 0,
      maxOpen <= maxActive,
      dnsOpenReserve >= 0,
      dnsOpenReserve < maxOpen,
      maxPending > 0,
      peerWriteBuffer > 0,
      kcpWindow > 0,
      kcpBuffer > 0,
      validPositiveDuration(queueTimeout),
      validPositiveDuration(idleTimeout)
    else {
      throw RuntimeCandidateError.invalidValue
    }
    let vlessMuxProtocol: String?
    let vlessMuxMaxConnections: Int?
    let vlessMuxMinStreams: Int?
    if parameterKeys.isSuperset(of: vlessMuxParameterKeys) {
      guard
        let protocolValue = parameters["vless_mux_protocol"] as? String,
        ["smux", "yamux", "h2mux"].contains(protocolValue),
        let maxConnections = strictInteger(parameters["vless_mux_max_connections"]),
        let minStreams = strictInteger(parameters["vless_mux_min_streams"]),
        maxConnections > 0,
        minStreams > 0
      else {
        throw RuntimeCandidateError.invalidValue
      }
      vlessMuxProtocol = protocolValue
      vlessMuxMaxConnections = maxConnections
      vlessMuxMinStreams = minStreams
    } else {
      vlessMuxProtocol = nil
      vlessMuxMaxConnections = nil
      vlessMuxMinStreams = nil
    }
    return RuntimeParameters(
      maxActive: maxActive,
      maxOpen: maxOpen,
      dnsOpenReserve: dnsOpenReserve,
      maxPending: maxPending,
      queueTimeout: queueTimeout,
      idleTimeout: idleTimeout,
      peerWriteBuffer: peerWriteBuffer,
      kcpWindow: kcpWindow,
      kcpBuffer: kcpBuffer,
      vlessMuxProtocol: vlessMuxProtocol,
      vlessMuxMaxConnections: vlessMuxMaxConnections,
      vlessMuxMinStreams: vlessMuxMinStreams
    )
  }

  public static func applyingRuntimeParameters(
    _ parameters: RuntimeParameters,
    to configContent: String
  ) throws -> String {
    guard
      let data = configContent.data(using: .utf8),
      var dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var services = dictionary["services"] as? [Any]
    else {
      throw RuntimeCandidateError.invalidConfig
    }
    let wltIndices = services.indices.filter { index in
      guard let service = services[index] as? [String: Any] else {
        return false
      }
      return stringValue(service["type"])?.lowercased() == "wlt"
    }
    guard !wltIndices.isEmpty else {
      throw RuntimeCandidateError.missingWLTService
    }
    guard wltIndices.count == 1 else {
      throw RuntimeCandidateError.multipleWLTServices
    }
    let index = wltIndices[0]
    guard var service = services[index] as? [String: Any] else {
      throw RuntimeCandidateError.invalidConfig
    }
    service["max_active_streams"] = parameters.maxActive
    service["max_open_attempts"] = parameters.maxOpen
    service["dns_open_reserve"] = parameters.dnsOpenReserve
    service["max_pending_dials"] = parameters.maxPending
    service["dial_queue_timeout"] = parameters.queueTimeout
    service["idle_timeout"] = parameters.idleTimeout
    service["peer_write_buffer"] = parameters.peerWriteBuffer
    service["kcp_window"] = parameters.kcpWindow
    service["kcp_buffer"] = parameters.kcpBuffer
    services[index] = service
    dictionary["services"] = services
    if
      let protocolValue = parameters.vlessMuxProtocol,
      let maxConnections = parameters.vlessMuxMaxConnections,
      let minStreams = parameters.vlessMuxMinStreams
    {
      guard var outbounds = dictionary["outbounds"] as? [Any] else {
        throw RuntimeCandidateError.invalidConfig
      }
      let wltTags = Set(outbounds.compactMap { raw -> String? in
        guard
          let outbound = raw as? [String: Any],
          stringValue(outbound["type"])?.lowercased() == "wlt"
        else {
          return nil
        }
        return stringValue(outbound["tag"])
      })
      var modifiedOutbounds = 0
      for outboundIndex in outbounds.indices {
        guard
          var outbound = outbounds[outboundIndex] as? [String: Any],
          stringValue(outbound["type"])?.lowercased() == "vless",
          let detour = stringValue(outbound["detour"]),
          wltTags.contains(detour)
        else {
          continue
        }
        outbound["multiplex"] = [
          "enabled": true,
          "protocol": protocolValue,
          "max_connections": maxConnections,
          "min_streams": minStreams,
        ]
        outbounds[outboundIndex] = outbound
        modifiedOutbounds += 1
      }
      guard modifiedOutbounds > 0 else {
        throw RuntimeCandidateError.missingWLTVLESSOutbound
      }
      dictionary["outbounds"] = outbounds
    }
    guard JSONSerialization.isValidJSONObject(dictionary) else {
      throw RuntimeCandidateError.invalidConfig
    }
    let encoded = try JSONSerialization.data(
      withJSONObject: dictionary,
      options: [.sortedKeys]
    )
    guard let content = String(data: encoded, encoding: .utf8) else {
      throw RuntimeCandidateError.invalidConfig
    }
    return content
  }
  #endif

  public static func bootstrapURL(for remoteURL: String?) -> String? {
    guard let remoteURL, var components = URLComponents(string: remoteURL) else {
      return nil
    }
    var path = components.path
    if path.hasSuffix("/") {
      path.removeLast()
    }
    path += "/" + bootstrapPathComponent
    components.path = path
    return components.string
  }

  public static func parseBootstrapOptions(_ content: String) throws -> [String: NSObject] {
    guard let data = content.data(using: .utf8) else {
      return [:]
    }
    let object = try JSONSerialization.jsonObject(with: data)
    return options(from: object as? [String: Any])
  }

  public static func requiresWhitelistTransport(_ configContent: String) -> Bool {
    guard let object = parseConfig(configContent) else {
      return false
    }
    return containsCoreWLTType(object) || containsLegacyWhitelistTransport(object)
  }

  public static func usesCoreWhitelistTransport(_ configContent: String) -> Bool {
    guard let object = parseConfig(configContent) else {
      return false
    }
    return containsCoreWLTType(object)
  }

  public static func usesLegacyWhitelistTransport(_ configContent: String) -> Bool {
    guard let object = parseConfig(configContent) else {
      return false
    }
    return !containsCoreWLTType(object) && containsLegacyWhitelistTransport(object)
  }

  public static func injectingCoreAuthSnapshotFile(
    into configContent: String,
    snapshotFile: URL
  ) -> String {
    guard var dictionary = parseConfig(configContent) as? [String: Any],
      var services = dictionary["services"] as? [Any]
    else {
      return configContent
    }

    var changed = false
    let snapshotPath = snapshotFile.relativePath
    for index in services.indices {
      guard var service = services[index] as? [String: Any],
        stringValue(service["type"])?.lowercased() == "wlt"
      else {
        continue
      }
      if stringValue(service["auth_snapshot_file"])?.isEmpty ?? true {
        service["auth_snapshot_file"] = snapshotPath
        changed = true
      }
      if stringValue(service["auth_snapshot_output_file"])?.isEmpty ?? true {
        service["auth_snapshot_output_file"] = snapshotPath
        changed = true
      }
      if service.removeValue(forKey: "config_trusted_at") != nil {
        // Local profile presence is the bootstrap trust boundary. Keep the
        // compatibility field out of the effective runtime configuration.
        changed = true
      }
      services[index] = service
    }

    guard changed else {
      return configContent
    }
    dictionary["services"] = services
    guard JSONSerialization.isValidJSONObject(dictionary),
      let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
      let injected = String(data: data, encoding: .utf8)
    else {
      return configContent
    }
    return injected
  }

  private static func options(from metadata: [String: Any]?) -> [String: NSObject] {
    guard let metadata else {
      return [:]
    }

    var options: [String: NSObject] = [:]
    if boolValue(metadata["enabled"]) ?? false {
      options["whitelistTransportEnabled"] = NSNumber(value: true)
    }
    if let transport = stringValue(metadata["transport"] ?? metadata["type"]), !transport.isEmpty {
      options["whitelistTransportType"] = NSString(string: transport.lowercased())
    }
    if let link = stringValue(metadata["telemost_link"] ?? metadata["join_link"]), !link.isEmpty {
      options["whitelistTransportTelemostLink"] = NSString(string: link)
    }
    if let socks = stringValue(metadata["socks"] ?? metadata["socks_listeners"]), !socks.isEmpty {
      options["whitelistTransportSOCKSListeners"] = NSString(string: socks)
    }
    if let turnableConfig = jsonStringValue(metadata["turnable_config"] ?? metadata["turnable_url"]),
      !turnableConfig.isEmpty
    {
      options["whitelistTransportTurnableConfig"] = NSString(string: turnableConfig)
    }
    if let turnableListeners = stringValue(metadata["turnable_listeners"]), !turnableListeners.isEmpty {
      options["whitelistTransportTurnableListeners"] = NSString(string: turnableListeners)
    }
    if let displayName = stringValue(metadata["display_name"]), !displayName.isEmpty {
      options["whitelistTransportDisplayName"] = NSString(string: displayName)
    }
    if let fps = intValue(metadata["vp8_fps"]) {
      options["whitelistTransportVP8FPS"] = NSNumber(value: fps)
    }
    if let batch = intValue(metadata["vp8_batch"]) {
      options["whitelistTransportVP8Batch"] = NSNumber(value: batch)
    }
    if let payloadSize = intValue(metadata["payload_size"] ?? metadata["vp8_payload_size"]) {
      options["whitelistTransportPayloadSize"] = NSNumber(value: payloadSize)
    }
    if let ignoreMemoryLimit = boolValue(metadata["ignore_memory_limit"]) {
      options["ignoreMemoryLimit"] = NSNumber(value: ignoreMemoryLimit)
    }
    return options
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  private static func jsonStringValue(_ value: Any?) -> String? {
    if let string = stringValue(value) {
      return string
    }
    guard let value else {
      return nil
    }
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: []),
      let string = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return string
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
    }
    if let value = stringValue(value) {
      return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
    return nil
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = stringValue(value) {
      return Int(value)
    }
    return nil
  }

  #if SFI_DEV
  private static func strictInteger(_ value: Any?) -> Int? {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double else {
      return nil
    }
    return Int(exactly: double)
  }

  private static func validPositiveDuration(_ value: String) -> Bool {
    let suffixes = ["ns", "us", "µs", "ms", "s", "m", "h"]
    guard let suffix = suffixes.first(where: { value.hasSuffix($0) }) else {
      return false
    }
    let number = value.dropLast(suffix.count)
    guard !number.isEmpty, let parsed = Double(number) else {
      return false
    }
    return parsed.isFinite && parsed > 0
  }
  #endif

  private static func parseConfig(_ configContent: String) -> Any? {
    guard let data = configContent.data(using: .utf8) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private static func containsCoreWLTType(_ object: Any?) -> Bool {
    guard let dictionary = object as? [String: Any] else {
      return false
    }
    return containsWLTType(in: dictionary["services"])
      || containsWLTType(in: dictionary["outbounds"])
  }

  private static func containsWLTType(in value: Any?) -> Bool {
    guard let items = value as? [Any] else {
      return false
    }
    return items.contains { item in
      guard let dictionary = item as? [String: Any],
        let type = stringValue(dictionary["type"])
      else {
        return false
      }
      return type.lowercased() == "wlt"
    }
  }

  private static func containsLegacyWhitelistTransport(_ object: Any?) -> Bool {
    guard let dictionary = object as? [String: Any],
      let outbounds = dictionary["outbounds"] as? [Any]
    else {
      return false
    }
    return outbounds.contains { outbound in
      guard let outbound = outbound as? [String: Any],
        let tag = stringValue(outbound["tag"])?.lowercased()
      else {
        return false
      }
      return legacyWhitelistTransportOutboundTags.contains(tag)
    }
  }

  private static let legacyWhitelistTransportOutboundTags: Set<String> = [
    "wlt-direct-detour",
    "wlt-eu-detour",
    "wlt-dns-detour",
    "vless-wlt-direct",
    "vless-wlt-eu",
  ]
}

#if SFI_DEV
  public extension WhitelistTransportConfig {
    enum OfflineRuleSetError: Error {
      case invalidProfile
      case invalidRuleSet
      case missingSnapshot
      case invalidDownload
    }

    private static func ruleSnapshotDirectory(for content: String) -> URL {
      let digest = SHA256.hash(data: Data(content.utf8))
        .map { String(format: "%02x", $0) }.joined()
      return FilePath.sharedDirectory
        .appendingPathComponent("wlt-rule-snapshots", isDirectory: true)
        .appendingPathComponent(digest, isDirectory: true)
    }

    private static func remoteBinaryRuleSets(
      in config: [String: Any], profileURL: URL?
    ) throws -> [(index: Int, tag: String, url: URL, version: String)] {
      guard let route = config["route"] as? [String: Any],
        let rawEntries = route["rule_set"]
      else { return [] }
      guard let entries = rawEntries as? [[String: Any]] else {
        throw OfflineRuleSetError.invalidRuleSet
      }
      var result: [(Int, String, URL, String)] = []
      var tags = Set<String>()
      for (index, entry) in entries.enumerated() {
        guard entry["type"] as? String == "remote" else { continue }
        guard entry["format"] as? String == "binary",
          let tag = entry["tag"] as? String,
          !tag.isEmpty, tag.count <= 96,
          tag.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
          }),
          tags.insert(tag).inserted,
          let rawURL = entry["url"] as? String,
          let url = URL(string: rawURL), url.scheme == "https",
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.fragment == nil,
          profileURL == nil || host == profileURL?.host
        else { throw OfflineRuleSetError.invalidRuleSet }
        let version = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "v" })?.value ?? ""
        guard version.isEmpty || (version.count >= 16 && version.count <= 64
          && version.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
          })) else { throw OfflineRuleSetError.invalidRuleSet }
        result.append((index, tag, url, version))
      }
      guard result.count <= 64 else { throw OfflineRuleSetError.invalidRuleSet }
      return result
    }

    private static func parsedConfig(_ content: String) throws -> [String: Any] {
      guard let config = try JSONSerialization.jsonObject(with: Data(content.utf8))
        as? [String: Any] else { throw OfflineRuleSetError.invalidProfile }
      return config
    }

    /// Stage can publish payload health checks for newer WLT cores. The iOS
    /// Libbox used by this client does not support that optional URLTest field.
    /// Keep the group and its ordinary health URL, but remove only the two
    /// known merged-group extensions before validation and persistence.
    static func compatibleProfile(_ content: String) throws -> String {
      guard usesCoreWhitelistTransport(content) else { return content }
      var config = try parsedConfig(content)
      guard var outbounds = config["outbounds"] as? [[String: Any]] else {
        throw OfflineRuleSetError.invalidProfile
      }
      var changed = false
      for index in outbounds.indices where outbounds[index]["payload_probe"] != nil {
        let outbound = outbounds[index]
        guard outbound["type"] as? String == "urltest",
          let tag = outbound["tag"] as? String,
          (tag == "eu_or_wlt-eu" || tag == "ru_or_wlt-ru"),
          let probe = outbound["payload_probe"] as? [String: Any],
          Set(probe.keys) == Set(["bytes", "default"]),
          probe["bytes"] as? Int == 65536,
          let fallback = probe["default"] as? String,
          fallback == "vless-wlt-\(tag == "eu_or_wlt-eu" ? "eu" : "ru")",
          let members = outbound["outbounds"] as? [String],
          members.contains(fallback)
        else { throw OfflineRuleSetError.invalidProfile }
        outbounds[index].removeValue(forKey: "payload_probe")
        changed = true
      }
      guard changed else { return content }
      config["outbounds"] = outbounds
      let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
      guard let normalized = String(data: data, encoding: .utf8) else {
        throw OfflineRuleSetError.invalidProfile
      }
      return normalized
    }

    /// Fetches all binary assets before committing a received WLT profile.
    /// No network access occurs in the Packet Tunnel or in localRuleSetConfig.
    static func prepareOfflineRuleSets(_ content: String, profileURL: String?) async throws {
      guard usesCoreWhitelistTransport(content) else { return }
      let config = try parsedConfig(content)
      let sourceURL = profileURL.flatMap(URL.init(string:))
      let sets = try remoteBinaryRuleSets(in: config, profileURL: sourceURL)
      guard !sets.isEmpty else { return }
      let destination = ruleSnapshotDirectory(for: content)
      let parent = destination.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let pending = parent.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: pending) }
      var hashes: [String: String] = [:]
      let sessionConfiguration = URLSessionConfiguration.ephemeral
      sessionConfiguration.timeoutIntervalForRequest = 12
      sessionConfiguration.timeoutIntervalForResource = 20
      let session = URLSession(configuration: sessionConfiguration)
      defer { session.invalidateAndCancel() }
      for set in sets {
        let (data, response) = try await session.data(from: set.url)
        let digest = SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          data.count >= 4, data.count <= 8 * 1024 * 1024,
          data.starts(with: Data("SRS".utf8)),
          // The query parameter is a server-side version token, not a
          // content digest. The complete digest is recorded in the local
          // manifest and verified on every cold start.
          !digest.isEmpty
        else { throw OfflineRuleSetError.invalidDownload }
        try data.write(to: pending.appendingPathComponent("\(set.tag).srs"), options: .atomic)
        hashes[set.tag] = digest
      }
      let manifest = try JSONSerialization.data(withJSONObject: hashes)
      try manifest.write(to: pending.appendingPathComponent("manifest.json"), options: .atomic)
      guard try verifiedRuleSetFiles(sets, at: pending) else {
        throw OfflineRuleSetError.invalidDownload
      }
      let backup = parent.appendingPathComponent(destination.lastPathComponent + ".backup")
      if FileManager.default.fileExists(atPath: backup.path),
        !FileManager.default.fileExists(atPath: destination.path),
        try verifiedRuleSetFiles(sets, at: backup) {
        try FileManager.default.moveItem(at: backup, to: destination)
      }
      let hadPrevious = FileManager.default.fileExists(atPath: destination.path)
      if hadPrevious, FileManager.default.fileExists(atPath: backup.path) {
        // A prior interrupted replacement may have left this backup. Keep it
        // until the new snapshot is installed; never create a window with no
        // verified copy on disk.
        guard try verifiedRuleSetFiles(sets, at: backup) else {
          throw OfflineRuleSetError.missingSnapshot
        }
        try FileManager.default.removeItem(at: destination)
      } else if hadPrevious {
        try FileManager.default.moveItem(at: destination, to: backup)
      }
      do {
        try FileManager.default.moveItem(at: pending, to: destination)
      } catch {
        if hadPrevious, !FileManager.default.fileExists(atPath: destination.path) {
          try? FileManager.default.moveItem(at: backup, to: destination)
        }
        throw error
      }
      if hadPrevious { try? FileManager.default.removeItem(at: backup) }
    }

    private static func verifiedRuleSetFiles(
      _ sets: [(index: Int, tag: String, url: URL, version: String)], at directory: URL
    ) throws -> Bool {
      guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
        let hashes = try? JSONSerialization.jsonObject(with: manifestData) as? [String: String],
        hashes.count == sets.count
      else { return false }
      for set in sets {
        let path = directory.appendingPathComponent("\(set.tag).srs")
        guard let expected = hashes[set.tag], expected.count == 64,
          expected.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
          })
        else { return false }
        guard let data = try? Data(contentsOf: path),
          data.count >= 4, data.count <= 8 * 1024 * 1024,
          data.starts(with: Data("SRS".utf8)),
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected
        else { return false }
      }
      return true
    }

    /// Replaces remote rule-set URLs with local binary paths before IPC to the
    /// extension. Missing assets fail closed; cold startup never fetches API URLs.
    static func localRuleSetConfig(_ content: String) throws -> String {
      guard usesCoreWhitelistTransport(content) else { return content }
      var config = try parsedConfig(content)
      let sets = try remoteBinaryRuleSets(in: config, profileURL: nil)
      guard !sets.isEmpty else { return content }
      let primary = ruleSnapshotDirectory(for: content)
      let backup = primary.deletingLastPathComponent()
        .appendingPathComponent(primary.lastPathComponent + ".backup")
      let directory: URL
      if try verifiedRuleSetFiles(sets, at: primary) {
        directory = primary
      } else if try verifiedRuleSetFiles(sets, at: backup) {
        directory = backup
      } else {
        throw OfflineRuleSetError.missingSnapshot
      }
      guard
        var route = config["route"] as? [String: Any],
        var entries = route["rule_set"] as? [[String: Any]]
      else { throw OfflineRuleSetError.missingSnapshot }
      for set in sets {
        entries[set.index] = [
          "type": "local", "format": "binary", "tag": set.tag,
          "path": directory.appendingPathComponent("\(set.tag).srs").path,
        ]
      }
      route["rule_set"] = entries
      config["route"] = route
      let serialized = try JSONSerialization.data(withJSONObject: config)
      guard let output = String(data: serialized, encoding: .utf8) else {
        throw OfflineRuleSetError.invalidProfile
      }
      return output
    }
  }
#endif
