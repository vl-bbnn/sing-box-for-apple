func require(_ value:Bool,_ label:String){if !value {fatalError(label)}}
func until(_ condition:()->Bool) async throws {
 let start=DispatchTime.now().uptimeNanoseconds
 while !condition(){if DispatchTime.now().uptimeNanoseconds-start>3_000_000_000{fatalError("condition timeout")};try await Task.sleep(nanoseconds:1_000_000)}
}
func inventory(_ root:URL) throws -> [String:String] {
 let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey])!
 var values:[String:String]=[:]
 for case let url as URL in enumerator {
  let relative=String(url.path.dropFirst(root.path.count))
  let kind=try url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey])
  if kind.isRegularFile==true {values[relative]=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()}
  else if kind.isDirectory==true {values[relative]="directory"}
 }
 return values
}
func rows(_ root:URL,_ name:String)throws -> [[String:Any]] {
 let url=root.appendingPathComponent(name)
 guard FileManager.default.fileExists(atPath:url.path) else{return []}
 return try String(contentsOf:url,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
}
@main struct R12Cases {
 @MainActor static func main() async throws {
  let root=FilePath.cacheDirectory
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  func id()->String{UUID().uuidString.lowercased()}
  func config(_ marker:String)->[String:NSObject] { ["configContent":NSString(string:"{\"outbounds\":[{\"type\":\"wlt\"}],\"marker\":\"\(marker)\"}"),"systemProxyEnabled":NSNumber(value:marker != "rejected")] }
  func provider(_ f:Fixture)->ExtensionProvider {ExtensionProvider(f,snapshot:root.appendingPathComponent("start-\(id()).plist"))}
  func finish(_ p:ExtensionProvider) async throws -> WLTStopReply {
   let reply=p.requestOwnedStopService(operationID:id(),journalCloseReason:"test_end")
   return try await p.waitOwnedStopService(reply,timeout:2)
  }
  // Exact handleAppMessage and binary-plist persistence are used. A close
  // already owning the lifecycle rejects before any memory/disk mutation.
  let f=Fixture(),p=provider(Fixture());let a=provider(f)
  try await a.startTunnel(options:config("original"))
  let original=try Data(contentsOf:a.startOptionsURL!)
  f.gates["coreClose"]=DispatchSemaphore(value:0)
  let pending=a.requestOwnedStopService(operationID:id(),journalCloseReason:"race")
  try await until{f.count("coreClose")==1}
  let rejected=await a.handleAppMessage(try ExtensionStartOptions.encode(config("rejected")))
  require(rejected != nil && (try! Data(contentsOf:a.startOptionsURL!))==original,"rejected reload changed persisted config")
  require(a.tunnelOptions?["configContent"]==config("original")["configContent"] && a.overridePreferences?.systemProxyEnabled==true,"rejected reload changed effective options")
  f.gates["coreClose"]!.signal();_=try await a.waitOwnedStopService(pending,timeout:2)
  print("PASS stop-versus-reload preserves actual options and persisted plist bytes")
  // A second normal reload cannot change options being used by an admitted
  // first reload, including the data persisted for the next tunnel start.
  let rf=Fixture(),rp=provider(Fixture());let reloading=provider(rf)
  try await reloading.startTunnel(options:config("initial"))
  rf.gates["startCore"]=DispatchSemaphore(value:0)
  let first=Task{await reloading.handleAppMessage(try ExtensionStartOptions.encode(config("accepted")))}
  try await until{rf.count("startCore")==2}
  let acceptedBytes=try Data(contentsOf:reloading.startOptionsURL!)
  let second=await reloading.handleAppMessage(try ExtensionStartOptions.encode(config("rejected")))
  require(second != nil && (try! Data(contentsOf:reloading.startOptionsURL!))==acceptedBytes,"concurrent rejected reload changed disk")
  require(reloading.tunnelOptions?["configContent"]==config("accepted")["configContent"],"concurrent rejected reload changed memory")
  rf.gates["startCore"]!.signal();let firstResult=try await first.value
  require(firstResult==nil && rf.count("startCore")==2,"first admitted reload did not finish exactly once")
  _=try await finish(reloading)
  print("PASS reload-versus-reload admission covers actual option transaction")
  // A persistence failure must not apply unpersisted options or invoke core.
  let pf=Fixture(),pp=provider(pf);try await pp.startTunnel(options:config("original"))
  let snapshot=pp.startOptionsURL!,saved=snapshot.appendingPathExtension("saved")
  try FileManager.default.moveItem(at:snapshot,to:saved)
  try FileManager.default.createDirectory(at:snapshot,withIntermediateDirectories:false)
  let failedPersist=await pp.handleAppMessage(try ExtensionStartOptions.encode(config("rejected")))
  require(failedPersist != nil && pp.tunnelOptions?["configContent"]==config("original")["configContent"] && pf.count("startCore")==1,"persistence failure changed effective/core config")
  _=try await finish(pp)
  print("PASS actual persistence error retains effective config and releases transition")
  // Failed reload reserves one close owner before transition release. Exercise
  // actual option persistence, journal failure, delayed and failed core close.
  for failedClose in [false, true] {
   let af=Fixture(),ap=provider(af)
   try await ap.startTunnel(options:config("before-ambiguous"))
   let oldJournal=ap.wltCoreLifetimeJournal!,oldSession=oldJournal.sessionIdentifier
   af.failures.insert("startCore")
   af.gates["coreClose"]=DispatchSemaphore(value:0)
   if failedClose { af.failures.insert("coreClose") }
   let ambiguous=await ap.handleAppMessage(try ExtensionStartOptions.encode(config("ambiguous")))
   require(ambiguous != nil,"ambiguous core failure accepted")
   try await until{af.count("coreClose")==1}
   let owner=ap.observed()!
   require(owner.pending,"blocked owner was not pending")
   let persisted=try Data(contentsOf:ap.startOptionsURL!)
   let second=await ap.handleAppMessage(try ExtensionStartOptions.encode(config("rejected")))
   require(second != nil && af.count("startCore")==2,"second core admitted before close")
   require((try! Data(contentsOf:ap.startOptionsURL!))==persisted && ap.tunnelOptions?["configContent"]==config("ambiguous")["configContent"],"rejected reload mutated config")
   do { try await ap.reloadService(); fatalError("direct reload admitted before close") } catch {}
   do { try await ap.startTunnel(options:config("rejected")); fatalError("start admitted before close") } catch {}
   require(ap.observed()?.operationID==owner.operationID && af.count("coreClose")==1,"duplicate cleanup owner")
   af.failures.remove("startCore")
   af.gates["coreClose"]!.signal()
   let closed=try await ap.waitOwnedStopService(owner,timeout:2)
   require(closed.outcome != nil,"close has no terminal outcome")
   if failedClose {
    require(!closed.outcome!.resourcesClosed && ap.commandServer != nil && ap.wltCoreLifetimeJournal === oldJournal,"failed close lost resource ownership")
    do {try await ap.startTunnel(options:config("rejected"));fatalError("start admitted after failed cleanup")}catch{}
    do {try await ap.reloadService();fatalError("reload admitted after failed cleanup")}catch{}
   } else {
    require(closed.outcome!.resourcesClosed && ap.commandServer==nil && ap.wltCoreLifetimeJournal==nil,"late cleanup did not retire resources")
    let oldEvidence=try inventory(oldJournal.sessionDirectory)
    try await ap.startTunnel(options:config("recovered"))
    require(ap.wltCoreLifetimeJournal!.sessionIdentifier != oldSession,"restart reused ambiguous journal")
    require((try! inventory(oldJournal.sessionDirectory))==oldEvidence,"restart changed ambiguous evidence")
    af.gates.removeValue(forKey:"coreClose")
    _=try await finish(ap)
   }
  }
  print("PASS ambiguous reload blocks restart until one owner proves cleanup; failed close retains resources")
  // Real journal seal and final manifest faults, then a fresh lifecycle using
  // actual startService allocation. Failed on-disk evidence must stay intact.
  for fault in ["seal","manifest"] {
   let jf=Fixture(),jp=provider(jf);try await jp.startTunnel(options:config("journal"))
   let old=jp.wltCoreLifetimeJournal!,oldID=old.sessionIdentifier
   let damaged=old.sessionDirectory.appendingPathComponent(fault=="seal" ? "generation-0001.log":"session.json")
   try FileManager.default.moveItem(at:damaged,to:damaged.appendingPathExtension("preserved"))
   try FileManager.default.createDirectory(at:damaged,withIntermediateDirectories:false)
   let failed=try await finish(jp)
   require(failed.outcome!.evidenceFailures.contains("journal_finalize_failed") && failed.outcome!.resourcesClosed,"journal error masked or suppressed safe cleanup")
   require(jp.wltCoreLifetimeJournal==nil,"retired journal remains attached")
   let failedEvidence=try inventory(old.sessionDirectory)
   try await jp.startTunnel(options:config("fresh"))
   require(jp.wltCoreLifetimeJournal!.sessionIdentifier != oldID,"next start reused failed journal")
   let done=try await finish(jp)
   require(done.outcome!.succeeded && (try! inventory(old.sessionDirectory))==failedEvidence,"new lifecycle altered failed evidence or failed to finish")
  }
  print("PASS real journal seal/manifest failure retires owner and preserves disk evidence across next lifecycle")
  // A transaction records canonical binding as soon as it sees admission.
  func transaction(_ tp:ExtensionProvider,_ requestID:String,timeout:Double=2,failBoundReceipt:Bool=false) async throws {
   try await WLTStopTransaction.perform(prepare:{},closeService:{bind in
    _=try await WLTStopClient.close(operationID:requestID,timeout:timeout,observeOwner:bind){data,_ in
      try ExtensionDiagnosticMessage.decodeResponse(tp.wire(data)!)
    }
   },stopTunnel:{try! tp.fixture.hit("appOSStop")},record:{stage,canonical in
    let savedRoot=FilePath.cacheDirectory
    if stage == .appOwnerBound && failBoundReceipt {
      let bad=root.appendingPathComponent("receipt-block-\(requestID)");try! Data("blocked".utf8).write(to:bad)
      FilePath.cacheDirectory=bad
    }
    let written=PacketTunnelDiagnostics.appendStopStage(stage.rawValue,operationID:requestID,
      requestID:requestID,canonicalOperationID:canonical?.operationID,lifecycle:canonical?.lifecycle)
    FilePath.cacheDirectory=savedRoot
    if stage == .appOwnerBound {try! tp.fixture.hit("boundReceipt")}
    return written
   })
  }
  let os=Fixture(),op=provider(os);try await op.startTunnel(options:config("os-first"))
  os.gates["coreClose"]=DispatchSemaphore(value:0)
  let osTask=Task{await op.stopTunnel(with:.userInitiated)}
  try await until{os.count("coreClose")==1}
  let canonical=op.observed()!,requests=[id(),id()]
  let app1=Task{try await transaction(op,requests[0])},app2=Task{try await transaction(op,requests[1])}
  try await until{ (try! rows(root,"wlt-stop-app.jsonl")).filter{requests.contains($0["request_id"] as? String ?? "") && $0["stage"] as? String == "app_owner_bound"}.count==2 }
  os.gates["coreClose"]!.signal();try await app1.value;try await app2.value;await osTask.value
  let appRows=try rows(root,"wlt-stop-app.jsonl"),providerRows=try rows(root,"wlt-stop-provider.jsonl")
  for requestID in requests {
   let events=appRows.filter{$0["request_id"] as? String==requestID}
   let bound=events.firstIndex{$0["stage"] as? String=="app_owner_bound"}!
   require(events.filter{$0["stage"] as? String=="app_owner_bound"}.count==1,"duplicate binding")
   for row in events.dropFirst(bound) {require(row["canonical_operation_id"] as? String==canonical.operationID && (row["lifecycle"] as? NSNumber)?.uint64Value==canonical.lifecycle,"canonical association lost")}
   require(events.contains{$0["stage"] as? String=="app_rpc_return_ok"},"successful transaction missing terminal receipt")
  }
  let terminal=providerRows.filter{$0["operation_id"] as? String==canonical.operationID && $0["stage"] as? String=="provider_close_return_ok"}
  require(terminal.count==1 && terminal[0]["canonical_operation_id"] as? String==canonical.operationID && (terminal[0]["lifecycle"] as? NSNumber)?.uint64Value==canonical.lifecycle && os.count("coreClose")==1,"provider canonical terminal mismatch")
  print("PASS OS-first concurrent actual transactions bind two requests to one canonical terminal lifecycle")
  for mode in ["cancel","timeout","binding-io"] {
   let tf=Fixture(),tp=provider(tf);try await tp.startTunnel(options:config(mode))
   tf.gates["coreClose"]=DispatchSemaphore(value:0)
   let requestID=id()
   if mode=="binding-io" {
    _=tp.requestOwnedStopService(operationID:id(),journalCloseReason:"bind-io-fixture")
    try await until{tf.count("coreClose")==1}
   }
   let task=Task{try await transaction(tp,requestID,timeout:mode=="timeout" ? 0.03:2,failBoundReceipt:mode=="binding-io")}
   try await until{tf.count("coreClose")==1}
   if mode=="cancel" {
    try await until{(try! rows(root,"wlt-stop-app.jsonl")).contains{$0["request_id"] as? String==requestID && $0["stage"] as? String=="app_owner_bound"}}
    task.cancel()
   }
   if mode=="binding-io" {try await until{tf.count("boundReceipt")==1};tf.gates["coreClose"]!.signal()}
   do{try await task.value;fatalError("expected transaction failure")}
   catch is CancellationError {require(mode=="cancel","unexpected cancellation")}
   catch WLTStopWaitError.deadline {require(mode=="timeout","unexpected deadline")}
   catch let failure as WLTStopTransaction.Failure {require(mode=="binding-io" && failure.primary==nil && failure.receiptStages==["app_owner_bound"],"binding IO not retained separately: mode=\(mode) primary=\(String(describing:failure.primary)) stages=\(failure.receiptStages)")}
   let pending=tp.observed()!
   if mode != "binding-io" {require(pending.pending,"waiter terminated owner");tf.gates["coreClose"]!.signal()}
   let done=try await tp.waitOwnedStopService(pending,timeout:2)
   require(done.outcome!.succeeded && tf.count("appOSStop")==1,"safe cleanup lost after waiter/receipt failure")
   if mode != "binding-io" {
    let events=(try rows(root,"wlt-stop-app.jsonl")).filter{$0["request_id"] as? String==requestID}
    let terminal=events.first{$0["stage"] as? String=="app_rpc_return_error"}!
    require(terminal["canonical_operation_id"] as? String==done.operationID,"failed waiter lost canonical identity")
   }
  }
  print("PASS bound identity survives actual waiter cancellation/deadline; binding writer error rejects evidence while cleanup finishes")
  // Actual writer state at each interruption: renamed old segment with absent
  // active, freshly-created empty active, and empty first-write failure state.
  for state in ["absent","empty-created","empty-write-failed"] {
   let rotate=root.appendingPathComponent("rotation-\(state)");FilePath.cacheDirectory=rotate
   require(PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id()),"seed")
   let active=rotate.appendingPathComponent("wlt-stop-app.jsonl")
   var row=try JSONSerialization.jsonObject(with:Data(contentsOf:active)) as! [String:Any]
   var bytes=Data();var count=0
   while bytes.count<=1024*1024 {count+=1;row["sequence"]=count;var line=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);line.append(10);bytes.append(line)}
   try bytes.write(to:active)
   require(PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id()),"rotation")
   try FileManager.default.moveItem(at:active,to:rotate.appendingPathComponent("first-write-state-preserved.jsonl"))
   if state != "absent" {try Data().write(to:active)}
   require(PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id()),"recover interruption")
   require(PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id()),"subsequent append")
   let written=try rows(rotate,"wlt-stop-app.jsonl")
   require(written.count==2 && written[0]["sequence"] as! Int==count+1 && written[1]["sequence"] as! Int==count+2 && written[0]["sequence_origin"] as! Int==count+1,"archive to active sequence restarted")
   // An internally contiguous active segment with a wrong origin must fail.
   var corrupt=Data()
   for (offset,var entry) in written.enumerated(){entry["sequence_origin"]=count+9;entry["sequence"]=count+9+offset;var line=try JSONSerialization.data(withJSONObject:entry);line.append(10);corrupt.append(line)}
   try corrupt.write(to:active)
   require(!PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id()) && (try! Data(contentsOf:active))==corrupt,"unexplained continuity accepted or evidence overwritten")
  }
  // Missing/empty archives and sequence overflow are rejected. A historical
  // schema-1 first segment remains readable and continues with schema 2.
  for mode in ["empty-archive","gap-archive","overflow","legacy"] {
   let dir=root.appendingPathComponent("archive-\(mode)");FilePath.cacheDirectory=dir
   require(PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id()),"archive seed")
   let active=dir.appendingPathComponent("wlt-stop-app.jsonl")
   var row=try JSONSerialization.jsonObject(with:Data(contentsOf:active)) as! [String:Any]
   try FileManager.default.moveItem(at:active,to:dir.appendingPathComponent("seed-preserved.jsonl"))
   func archive(_ last:Int,_ bytes:Data) throws {
    let name="wlt-stop-app.archive."+String(format:"%020lld",Int64(last))+"."+id()+".jsonl"
    try bytes.write(to:dir.appendingPathComponent(name))
   }
   func record(_ value:[String:Any]) throws -> Data {var data=try JSONSerialization.data(withJSONObject:value);data.append(10);return data}
   switch mode {
   case "empty-archive":try archive(1,Data())
   case "gap-archive":
    try archive(1,record(row));row["sequence"]=3;row["sequence_origin"]=3;try archive(3,record(row))
   case "overflow":row["sequence"]=Int.max;row["sequence_origin"]=Int.max;try record(row).write(to:active)
   default:
    row["schema"]=1;row.removeValue(forKey:"request_id");row.removeValue(forKey:"canonical_operation_id");row.removeValue(forKey:"lifecycle")
    try archive(1,record(row))
   }
   let before=try inventory(dir)
   let result=PacketTunnelDiagnostics.appendStopStage("app_prepare_ok",operationID:id())
   if mode=="legacy" {let written=try rows(dir,"wlt-stop-app.jsonl");require(result && written[0]["schema"] as! Int==2 && written[0]["sequence"] as! Int==2,"legacy continuation failed")}
   else {require(!result && (try! inventory(dir))==before,"malformed archive/overflow mutated evidence or was accepted")}
  }
  print("PASS malformed/empty archive and overflow rejection; schema-1 archive continuity")
  FilePath.cacheDirectory=root
  require(!PacketTunnelDiagnostics.appendStopStage("app_owner_bound",operationID:id()),"unbound association accepted")
  require(!PacketTunnelDiagnostics.appendStopStage("app_rpc_return_ok",operationID:id()),"unbound success accepted")
  require(!PacketTunnelDiagnostics.appendStopStage("provider_close_return_ok",operationID:id()),"unbound provider terminal accepted")
  print("PASS archive continuity at three empty/absent boundaries and negative canonical/sequence gates")
  _=p;_=rp
 }
}
