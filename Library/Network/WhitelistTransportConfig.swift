import Foundation

public enum WhitelistTransportConfig {
  public static let bootstrapPathComponent = "whitelist-transport"

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
