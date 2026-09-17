import Foundation

@main
struct MemoryBudgetCheck {
  static func main() throws {
    let base: [String: Any] = [
      "max_active": 56, "max_open": 16, "dns_open_reserve": 2,
      "max_pending": 40, "queue_timeout": "2s", "idle_timeout": "30s",
      "peer_write_buffer": 192, "kcp_window": 1024, "kcp_buffer": 2097152,
    ]
    let config = #"{"services":[{"type":"wlt","tag":"carrier"},{"type":"oom-killer","tag":"safety"}],"outbounds":[{"type":"wlt","tag":"wlt-eu"},{"type":"vless","tag":"vless-eu","detour":"wlt-eu"}],"experimental":{"cache_file":{"enabled":true},"debug":{"gc_percent":10,"trace_back":"all","memory_limit":70778880}}}"#
    let original = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! NSDictionary
    func decode(_ params: [String: Any]) throws -> WhitelistTransportConfig.RuntimeParameters {
      try WhitelistTransportConfig.decodeRuntimeCandidate(JSONSerialization.data(withJSONObject: ["parameters": params]))
    }
    func object(_ params: [String: Any], _ input: String = config) throws -> NSDictionary {
      let text = try WhitelistTransportConfig.applyingRuntimeParameters(decode(params), to: input)
      return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! NSDictionary
    }
    let baseline = try object(base)
    guard (baseline["experimental"] as! NSDictionary).isEqual(original["experimental"]) else { fatalError("omitted budget changes debug config") }
    for mux in [false, true] {
      for limit in [24, 32, 45] {
        var params = base
        params["go_memory_limit_mib"] = limit
        if mux {
          params["vless_mux_protocol"] = "smux"
          params["vless_mux_max_connections"] = 1
          params["vless_mux_min_streams"] = 4
        }
        let parsed = try decode(params)
        let roundtrip = try JSONDecoder().decode(WhitelistTransportConfig.RuntimeParameters.self, from: JSONEncoder().encode(parsed))
        guard roundtrip == parsed && roundtrip.goMemoryLimitMiB == limit else { fatalError("budget lost in control receipt") }
        var without = params; without.removeValue(forKey: "go_memory_limit_mib")
        let expected = (try object(without)).mutableCopy() as! NSMutableDictionary
        let expectedExp = (expected["experimental"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
        let expectedDebug = (expectedExp["debug"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
        expectedDebug["memory_limit"] = limit * 1_048_576 * 3 / 2
        expectedExp["debug"] = expectedDebug; expected["experimental"] = expectedExp
        guard (try object(params)).isEqual(expected) else { fatalError("budget changes unrelated runtime config") }
        let minimal = try object(params, #"{"services":[{"type":"wlt"}],"outbounds":[{"type":"wlt","tag":"wlt-eu"},{"type":"vless","detour":"wlt-eu"}]}"#)
        let exp = minimal["experimental"] as! NSDictionary, debug = exp["debug"] as! NSDictionary
        guard debug["memory_limit"] as! Int == limit * 1_048_576 * 3 / 2 else { fatalError("missing new debug budget") }
      }
    }
    for value: Any in [23, 46, -1, true, "32", 32.5, NSNull()] {
      var params = base; params["go_memory_limit_mib"] = value
      do { _ = try decode(params); fatalError("invalid budget accepted: \(value)") }
      catch WhitelistTransportConfig.RuntimeCandidateError.invalidValue { }
    }
    for extra in [["go_memory_limit_mib": 32, "unknown": 1], ["go_memory_limit_mib": 32, "vless_mux_protocol": "smux"]] as [[String: Any]] {
      var params = base; params.merge(extra) { _, value in value }
      do { _ = try decode(params); fatalError("unknown or partial schema accepted") }
      catch WhitelistTransportConfig.RuntimeCandidateError.invalidSchema { }
    }
    var budget = base; budget["go_memory_limit_mib"] = 32
    for input in [#"{"services":[{"type":"wlt"}],"experimental":false}"#, #"{"services":[{"type":"wlt"}],"experimental":{"debug":null}}"#] {
      do { _ = try object(budget, input); fatalError("malformed debug config overwritten") }
      catch WhitelistTransportConfig.RuntimeCandidateError.invalidConfig { }
    }
    let after = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! NSDictionary
    guard after.isEqual(original) else { fatalError("source configuration mutated") }
    print("WLT memory budget checks passed: limits, schema, receipt, isolated overlay and preservation")
  }
}
