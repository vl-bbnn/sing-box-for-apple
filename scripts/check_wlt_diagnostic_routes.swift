import Foundation
@main struct Check {
 static func main() throws {
  let base: [String: Any] = ["max_active":56,"max_open":16,"dns_open_reserve":2,"max_pending":40,"queue_timeout":"8s","idle_timeout":"30s","peer_write_buffer":192,"kcp_window":1024,"kcp_buffer":2097152]
  let config: [String:Any] = ["services":[["type":"wlt","tag":"carrier","auth_snapshot_file":"preserve"]],"dns":["final":"dns_custom"],"route":["final":"direct_or_wlt-ru"],"outbounds":[["type":"direct","tag":"direct"],["type":"selector","tag":"direct-always","outbounds":["direct"]],["type":"wlt","tag":"wlt-ru","route":"ru","service":"carrier"],["type":"wlt","tag":"wlt-eu","route":"eu","service":"carrier"],["type":"vless","tag":"vless-wlt-ru","detour":"wlt-ru"],["type":"vless","tag":"vless-wlt-eu","detour":"wlt-eu"],["type":"urltest","tag":"direct_or_wlt-ru","outbounds":["direct","vless-wlt-ru"]],["type":"urltest","tag":"ru_or_wlt-ru","outbounds":["ru","vless-wlt-ru"],"payload_probe":["bytes":65536,"default":"vless-wlt-ru"]],["type":"urltest","tag":"eu_or_wlt-eu","outbounds":["eu","vless-wlt-eu"]]]]
  func decode(_ p:[String:Any]) throws -> WhitelistTransportConfig.RuntimeParameters { try WhitelistTransportConfig.decodeRuntimeCandidate(JSONSerialization.data(withJSONObject:["parameters":p])) }
  func apply(_ p:[String:Any],_ c:[String:Any]) throws -> [String:Any] {
   let v=try decode(p);let encoded=try JSONEncoder().encode(v);guard try JSONDecoder().decode(WhitelistTransportConfig.RuntimeParameters.self,from:encoded)==v else{fatalError("receipt roundtrip")}
   let text=try WhitelistTransportConfig.applyingRuntimeParameters(v,to:String(data:JSONSerialization.data(withJSONObject:c),encoding:.utf8)!)
   return try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
  }
  let normal=try apply(base,config);var params=base;params["diagnostic_route_mode"]="wlt_only"
  let forced=try apply(params,config);var expected=normal;var outs=normal["outbounds"] as! [[String:Any]]
  for i in outs.indices {let tag=outs[i]["tag"] as! String;if ["direct_or_wlt-ru","ru_or_wlt-ru","eu_or_wlt-eu"].contains(tag){outs[i]["outbounds"]=[tag=="eu_or_wlt-eu" ? "vless-wlt-eu" : "vless-wlt-ru"]}}
  expected["outbounds"]=outs;guard NSDictionary(dictionary:forced).isEqual(to:expected) else{fatalError("unrelated config changed")}
  guard NSDictionary(dictionary:try apply(base,config)).isEqual(to:normal) else{fatalError("overlay persisted")}
  for val:Any in [true,false,0,1,"auto","",NSNull(),["wlt_only"]] {var p=base;p["diagnostic_route_mode"]=val;do{_=try decode(p);fatalError("invalid mode accepted")}catch WhitelistTransportConfig.RuntimeCandidateError.invalidValue{}}
  for change in 0..<5 {
   var c=config;var o=c["outbounds"] as! [[String:Any]]
   switch change {case 0:o.removeLast();case 1:o.append(o[0]);case 2:o[2]["service"]="wrong";case 3:o[7]["payload_probe"]=["default":"ru"];default:o[8]["type"]="selector"};c["outbounds"]=o
   do{_=try apply(params,c);fatalError("invalid graph accepted")}catch WhitelistTransportConfig.RuntimeCandidateError.invalidConfig{}
  }
  print("diagnostic WLT-only schema, exact overlay, receipt and malformed graph checks passed")
 }
}
