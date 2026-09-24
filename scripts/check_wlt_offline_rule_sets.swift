import CryptoKit
import Foundation

// This host-only FilePath stub lets the real Library implementation run without
// an iOS simulator or a device. No HTTP endpoint is contacted by the test.
enum FilePath {
  static var sharedDirectory: URL!
}

@main
struct OfflineRuleSetCheck {
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func main() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("wlt-rule-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    FilePath.sharedDirectory = root

    let payloadProfile = """
      {"services":[{"type":"wlt","tag":"wlt"}],"outbounds":[
        {"type":"vless","tag":"vless-wlt-eu","detour":"wlt"},
        {"type":"urltest","tag":"eu_or_wlt-eu","outbounds":["vless-wlt-eu"],
         "url":"https://www.gstatic.com/generate_204","payload_probe":{"bytes":65536,"default":"vless-wlt-eu"}}
      ],"route":{"rule_set":[]}}
      """
    let compatible = try WhitelistTransportConfig.compatibleProfile(payloadProfile)
    let compatibleObject = try JSONSerialization.jsonObject(with: Data(compatible.utf8)) as! [String: Any]
    let compatibleOutbounds = compatibleObject["outbounds"] as! [[String: Any]]
    precondition(compatibleOutbounds[1]["payload_probe"] == nil)
    precondition(compatibleOutbounds[1]["url"] as? String == "https://www.gstatic.com/generate_204")

    let first = Data("SRS\u{00}first".utf8)
    let second = Data("SRS\u{00}second".utf8)
    let firstDigest = digest(first)
    let secondDigest = digest(second)
    let config = """
      {"services":[{"type":"wlt","tag":"wlt"}],"route":{"rule_set":[
        {"type":"remote","format":"binary","tag":"first",
         "url":"https://example.com/rules/first.srs?v=\(firstDigest.prefix(16))"},
        {"type":"remote","format":"binary","tag":"second",
         "url":"https://example.com/rules/second.srs"}]}}
      """
    let snapshot = root.appendingPathComponent("wlt-rule-snapshots", isDirectory: true)
      .appendingPathComponent(digest(Data(config.utf8)), isDirectory: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try first.write(to: snapshot.appendingPathComponent("first.srs"))
    try second.write(to: snapshot.appendingPathComponent("second.srs"))
    let hashes = ["first": firstDigest, "second": secondDigest]
    try JSONSerialization.data(withJSONObject: hashes)
      .write(to: snapshot.appendingPathComponent("manifest.json"))

    func verifyLocal(_ output: String, directory: URL) throws {
      let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
      let route = parsed["route"] as! [String: Any]
      let entries = route["rule_set"] as! [[String: Any]]
      precondition(entries.count == 2)
      for entry in entries {
        precondition(entry["type"] as? String == "local")
        precondition(entry["format"] as? String == "binary")
        precondition(entry["url"] == nil)
        let tag = entry["tag"] as! String
        precondition(entry["path"] as? String == directory.appendingPathComponent("\(tag).srs").path)
      }
    }
    try verifyLocal(WhitelistTransportConfig.localRuleSetConfig(config), directory: snapshot)

    let backup = snapshot.deletingLastPathComponent()
      .appendingPathComponent(snapshot.lastPathComponent + ".backup")
    try FileManager.default.moveItem(at: snapshot, to: backup)
    try verifyLocal(WhitelistTransportConfig.localRuleSetConfig(config), directory: backup)

    try Data("SRS\u{00}corrupt".utf8).write(to: backup.appendingPathComponent("second.srs"))
    do {
      _ = try WhitelistTransportConfig.localRuleSetConfig(config)
      fatalError("corrupted snapshot was accepted")
    } catch WhitelistTransportConfig.OfflineRuleSetError.missingSnapshot {
      // Expected: neither the primary nor its backup can be trusted.
    }

    let malformed = """
      {"services":[{"type":"wlt"}],"route":{"rule_set":[{"type":"remote","tag":"first"},1]}}
      """
    do {
      _ = try WhitelistTransportConfig.localRuleSetConfig(malformed)
      fatalError("malformed WLT rule-set list was accepted")
    } catch WhitelistTransportConfig.OfflineRuleSetError.invalidRuleSet {
      print("offline rule-set snapshot check passed")
    }
  }
}
