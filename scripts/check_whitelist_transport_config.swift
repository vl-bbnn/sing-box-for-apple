import Foundation

@main
struct WhitelistTransportConfigCheck {
  static func main() {
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
      core: false
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
      core: true
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
      core: false
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
      core: true
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
      core: false
    )

    assertDetection(
      name: "malformed config with wlt text",
      config: #"{"outbounds": [{"type": "direct", "tag": "direct"}], "note": "type\":\"wlt"}"#,
      requires: false,
      core: false
    )
  }

  private static func assertDetection(
    name: String,
    config: String,
    requires: Bool,
    core: Bool
  ) {
    let detectedRequires = WhitelistTransportConfig.requiresWhitelistTransport(config)
    guard detectedRequires == requires else {
      fatalError("\(name): requires=\(detectedRequires), want \(requires)")
    }
    let detectedCore = WhitelistTransportConfig.usesCoreWhitelistTransport(config)
    guard detectedCore == core else {
      fatalError("\(name): core=\(detectedCore), want \(core)")
    }
  }
}
