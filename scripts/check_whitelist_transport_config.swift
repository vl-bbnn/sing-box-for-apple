import Foundation

@main
struct WhitelistTransportConfigCheck {
  static func main() {
    if CommandLine.arguments.count == 2 {
      do {
        let data: Data
        if CommandLine.arguments[1] == "-" {
          data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
          data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        _ = try WhitelistTransportConfig.decodeRuntimeCandidate(data)
        print("runtime candidate ok")
        return
      } catch {
        fatalError("runtime candidate failed: \(error)")
      }
    }

    assertDetection(
      name: "ordinary config with unrelated wlt strings",
      config: """
        {
          "log": {"level": "info"},
          "outbounds": [
            {"type": "direct", "tag": "ordinary-turnable-wlt-note"}
          ],
          "route": {"final": "ordinary-turnable-wlt-note"}
        }
      """,
      requires: false,
      core: false,
      legacy: false
    )

    assertDetection(
      name: "core WLT service",
      config: """
        {
          "services": [
            {"type": "wlt", "tag": "wlt-turnable", "transport": "turnable", "turnable_config": "{}"}
          ],
          "outbounds": [
            {"type": "direct", "tag": "direct"}
          ]
        }
        """,
      requires: true,
      core: true,
      legacy: false
    )

    assertDetection(
      name: "top-level type is ignored",
      config: """
        {
          "type": "wlt",
          "outbounds": [
            {"type": "direct", "tag": "direct"}
          ]
        }
        """,
      requires: false,
      core: false,
      legacy: false
    )

    assertDetection(
      name: "core WLT outbound",
      config: """
        {
          "outbounds": [
            {"type": "wlt", "tag": "wlt-eu", "service": "wlt-turnable", "route": "eu"}
          ]
        }
        """,
      requires: true,
      core: true,
      legacy: false
    )

    assertDetection(
      name: "legacy sidecar outbound",
      config: """
        {
          "outbounds": [
            {"type": "vless", "tag": "vless-wlt-eu", "server": "127.0.0.1", "server_port": 12101}
          ]
        }
        """,
      requires: true,
      core: false,
      legacy: true
    )

    assertDetection(
      name: "core WLT with legacy-compatible generated tag",
      config: """
        {
          "services": [
            {"type": "wlt", "tag": "wlt-turnable", "transport": "turnable", "turnable_config": "{}"}
          ],
          "outbounds": [
            {"type": "wlt", "tag": "wlt-eu", "service": "wlt-turnable", "route": "eu"},
            {"type": "vless", "tag": "vless-wlt-eu", "detour": "wlt-eu"}
          ]
        }
        """,
      requires: true,
      core: true,
      legacy: false
    )

    assertDetection(
      name: "malformed config with wlt text",
      config: #"{"outbounds": [{"type": "direct", "tag": "direct"}], "note": "type\":\"wlt"}"#,
      requires: false,
      core: false,
      legacy: false
    )

    assertRuntimeCandidateOverlay()
    assertLocalProfileTrust()
  }

  private static func assertLocalProfileTrust() {
    let config = #"{"services":[{"type":"wlt","config_trusted_at":1},{"type":"direct"}]}"#
    let snapshot = URL(fileURLWithPath: "/private/cache/wlt-auth.json")
    let trusted = WhitelistTransportConfig.injectingCoreAuthSnapshotFile(
      into: config,
      snapshotFile: snapshot
    )
    guard
      let trustedData = trusted.data(using: .utf8),
      let trustedObject = try? JSONSerialization.jsonObject(with: trustedData) as? [String: Any],
      let trustedServices = trustedObject["services"] as? [[String: Any]],
      trustedServices.first?["config_trusted_at"] == nil
    else {
      fatalError("calendar config trust remained in the effective profile")
    }

    let untrusted = WhitelistTransportConfig.injectingCoreAuthSnapshotFile(
      into: config,
      snapshotFile: snapshot
    )
    guard
      let untrustedData = untrusted.data(using: .utf8),
      let untrustedObject = try? JSONSerialization.jsonObject(with: untrustedData) as? [String: Any],
      let untrustedServices = untrustedObject["services"] as? [[String: Any]],
      untrustedServices.first?["config_trusted_at"] == nil
    else {
      fatalError("profile-provided config trust timestamp was accepted")
    }
  }

  private static func assertRuntimeCandidateOverlay() {
    let candidate = """
      {
        "parameters": {
          "max_active": 52,
          "max_open": 20,
          "dns_open_reserve": 4,
          "max_pending": 48,
          "queue_timeout": "2.5s",
          "idle_timeout": "1.5m",
          "peer_write_buffer": 192,
          "kcp_window": 1024,
          "kcp_buffer": 2097152
        }
      }
      """
    let config = """
      {
        "services": [
          {
            "type": "wlt",
            "tag": "wlt-turnable",
            "turnable_config": "opaque-value",
            "max_active_streams": 56
          }
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}]
      }
      """
    do {
      let parameters = try WhitelistTransportConfig.decodeRuntimeCandidate(
        Data(candidate.utf8)
      )
      let overlaid = try WhitelistTransportConfig.applyingRuntimeParameters(
        parameters,
        to: config
      )
      guard
        let data = overlaid.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let services = object["services"] as? [[String: Any]],
        let service = services.first,
        service["max_active_streams"] as? Int == 52,
        service["max_open_attempts"] as? Int == 20,
        service["dial_queue_timeout"] as? String == "2.5s",
        service["idle_timeout"] as? String == "1.5m",
        service["turnable_config"] as? String == "opaque-value"
      else {
        fatalError("runtime candidate overlay did not preserve/apply expected fields")
      }
    } catch {
      fatalError("valid runtime candidate failed: \(error)")
    }

    let muxCandidate = """
      {
        "parameters": {
          "max_active": 52,
          "max_open": 20,
          "dns_open_reserve": 4,
          "max_pending": 48,
          "queue_timeout": "2.5s",
          "idle_timeout": "30s",
          "peer_write_buffer": 192,
          "kcp_window": 1024,
          "kcp_buffer": 2097152,
          "vless_mux_protocol": "smux",
          "vless_mux_max_connections": 1,
          "vless_mux_min_streams": 4
        }
      }
      """
    let muxConfig = """
      {
        "services": [{"type":"wlt","tag":"wlt-carrier"}],
        "outbounds": [
          {"type":"wlt","tag":"wlt-eu"},
          {"type":"vless","tag":"vless-wlt-eu","detour":"wlt-eu"},
          {"type":"vless","tag":"ordinary-eu","detour":"direct"}
        ]
      }
      """
    do {
      let parameters = try WhitelistTransportConfig.decodeRuntimeCandidate(
        Data(muxCandidate.utf8)
      )
      let overlaid = try WhitelistTransportConfig.applyingRuntimeParameters(
        parameters,
        to: muxConfig
      )
      guard
        let data = overlaid.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let outbounds = object["outbounds"] as? [[String: Any]],
        let wltVLESS = outbounds.first(where: { $0["tag"] as? String == "vless-wlt-eu" }),
        let mux = wltVLESS["multiplex"] as? [String: Any],
        mux["enabled"] as? Bool == true,
        mux["protocol"] as? String == "smux",
        mux["max_connections"] as? Int == 1,
        mux["min_streams"] as? Int == 4,
        let ordinary = outbounds.first(where: { $0["tag"] as? String == "ordinary-eu" }),
        ordinary["multiplex"] == nil
      else {
        fatalError("runtime mux overlay did not stay scoped to WLT-detoured VLESS")
      }
    } catch {
      fatalError("valid runtime mux candidate failed: \(error)")
    }

    let partial = #"{"parameters":{"max_active":52}}"#
    do {
      _ = try WhitelistTransportConfig.decodeRuntimeCandidate(Data(partial.utf8))
      fatalError("partial runtime candidate was accepted")
    } catch WhitelistTransportConfig.RuntimeCandidateError.invalidSchema {
      // Expected.
    } catch {
      fatalError("partial runtime candidate returned unexpected error: \(error)")
    }
  }

  private static func assertDetection(
    name: String,
    config: String,
    requires: Bool,
    core: Bool,
    legacy: Bool
  ) {
    let detectedRequires = WhitelistTransportConfig.requiresWhitelistTransport(config)
    guard detectedRequires == requires else {
      fatalError("\(name): requires=\(detectedRequires), want \(requires)")
    }
    let detectedCore = WhitelistTransportConfig.usesCoreWhitelistTransport(config)
    guard detectedCore == core else {
      fatalError("\(name): core=\(detectedCore), want \(core)")
    }
    let detectedLegacy = WhitelistTransportConfig.usesLegacyWhitelistTransport(config)
    guard detectedLegacy == legacy else {
      fatalError("\(name): legacy=\(detectedLegacy), want \(legacy)")
    }
  }
}
