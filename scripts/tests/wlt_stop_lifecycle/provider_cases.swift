func require(_ value:Bool,_ label:String){if !value {fatalError(label)}}
func until(_ condition:()->Bool) async throws {
  let start=DispatchTime.now().uptimeNanoseconds
  while !condition(){if DispatchTime.now().uptimeNanoseconds-start>2_000_000_000{fatalError("condition timeout")};try await Task.sleep(nanoseconds:1_000_000)}
}
@main struct Cases {
 @MainActor static func main() async throws {
  let root=FilePath.cacheDirectory
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  func id()->String{UUID().uuidString.lowercased()}
  func close(_ p:ExtensionProvider,_ operation:String) async throws -> WLTStopReply {
    try await WLTStopClient.close(operationID:operation,timeout:1){data,_ in
      try ExtensionDiagnosticMessage.decodeResponse(p.wire(data)!)
    }
  }
  // Actual app protocol -> provider handler -> complete owner; two lifecycles.
  let f=Fixture(),p=ExtensionProvider(Fixture())
  let a=ExtensionProvider(f)
  try await a.startTunnel(options:nil)
  let first=try await close(a,id())
  require(first.outcome!.succeeded && f.count("core")==1 && f.count("server")==1 && f.count("diagnosticsEnd")==1,"app-first cleanup")
  try await a.startTunnel(options:nil)
  let second=try await close(a,id())
  require(second.lifecycle==first.lifecycle+1 && second.operationID != first.operationID && f.count("core")==2,"two lifecycles")
  print("PASS app-first, two complete lifecycle owners")
  // OS-first already has a distinct canonical identity; app joins it.
  let os=Fixture(),op=ExtensionProvider(os);os.gates["core"]=DispatchSemaphore(value:0)
  try await op.startTunnel(options:nil)
  let osTask=Task{await op.stopTunnel(with:.userInitiated)}
  try await until{os.count("core")==1}
  let canonical=op.observed()!
  let appTask=Task{try await close(op,id())}
  os.gates["core"]!.signal()
  let joined=try await appTask.value;await osTask.value
  require(joined.operationID==canonical.operationID && os.count("core")==1,"OS-first canonical join")
  print("PASS OS-first canonical pending/terminal protocol")
  // Actual simultaneous callers, including the actual platform serviceStop.
  let race=Fixture(),rp=ExtensionProvider(race);race.gates["core"]=DispatchSemaphore(value:0)
  try await rp.startTunnel(options:nil)
  await withTaskGroup(of:Void.self){group in
    for _ in 0..<12 {group.addTask{_ = rp.requestOwnedStopService(operationID:UUID().uuidString,journalCloseReason:"race")}}
  }
  try ExtensionPlatformInterface(rp).serviceStop()
  try await until{race.count("core")==1};race.gates["core"]!.signal()
  _=try await close(rp,id());require(race.count("core")==1,"concurrent one owner")
  print("PASS concurrent callers and real serviceStop integration")
  // Wait deadline/cancellation does not end core/server ownership. Late work
  // cleans up without a second stop callback or test-driven cleanup.
  for stage in ["core","server"] {
    let t=Fixture(),tp=ExtensionProvider(t);t.gates[stage]=DispatchSemaphore(value:0)
    try await tp.startTunnel(options:nil)
    let pending=tp.requestOwnedStopService(operationID:id(),journalCloseReason:"bounded")
    try await until{t.count(stage)==1}
    do {_=try await tp.waitOwnedStopService(pending,timeout:0.02);fatalError("deadline lost")}catch WLTStopWaitError.deadline{}
    do{try await tp.startTunnel(options:nil);fatalError("live restart admitted")}catch{}
    require(t.count("diagnosticsBegin")==1,"rejected start altered diagnostics")
    let waiter=Task{try await tp.waitOwnedStopService(pending,timeout:1)};waiter.cancel()
    do{_=try await waiter.value;fatalError("cancellation lost")}catch is CancellationError{}
    require(tp.observed()!.pending,"waiter falsely completed owner")
    t.gates[stage]!.signal()
    let terminal=try await tp.waitOwnedStopService(pending,timeout:1)
    require(terminal.outcome!.succeeded && t.count("diagnosticsEnd")==1,"late full cleanup")
  }
  print("PASS blocked core/server, deadline, cancellation, late teardown")
  // Real outer start/reload transition release admits deferred stop.
  for transition in ["start","reload"] {
    let t=Fixture(),tp=ExtensionProvider(t)
    if transition=="reload"{try await tp.startTunnel(options:nil);t.suspendReload=true}else{t.suspendStart=true}
    let work=Task{if transition=="start"{try await tp.startTunnel(options:nil)}else{try await tp.reloadService()}}
    try await until{t.count(transition=="start" ? "startWork":"reloadWork")==1}
    let stop=tp.requestOwnedStopService(operationID:id(),journalCloseReason:"during_transition")
    require(t.count("core")==0,"close during active transition")
    t.releaseStart=true;t.releaseReload=true
    do{try await work.value;fatalError("stop intent not seen")}catch{}
    let done=try await tp.waitOwnedStopService(stop,timeout:1)
    require(done.outcome!.succeeded && t.count("core")==1 && t.count("diagnosticsEnd")==1,"deferred close not delivered")
  }
  print("PASS stop during actual start/reload transition release")
  for failure in ["core","journal","sidecar"] {
    let t=Fixture(),tp=ExtensionProvider(t);t.failures=[failure]
    try await tp.startTunnel(options:nil)
    let request=tp.requestOwnedStopService(operationID:id(),journalCloseReason:"failure")
    let done=try await tp.waitOwnedStopService(request,timeout:1)
    require(!done.outcome!.succeeded,"failure masked")
    if failure=="journal"{require(done.outcome!.resourcesClosed && t.count("server")==1,"journal error suppressed safe cleanup")}
    else{require(!done.outcome!.resourcesClosed && tp.commandServer != nil && t.count("server")==0,"live resources released")}
  }
  print("PASS core/journal/sidecar failure resource ownership")
  let replace=Fixture(),replaceProvider=ExtensionProvider(replace)
  let oldSidecar=LibboxWhitelistTransportClient(replace)
  replaceProvider.whitelistTransportClient=oldSidecar;replace.failures=["sidecar"]
  let starts=SidecarBoundary.starts
  do {try replaceProvider.replaceSidecar(["whitelistTransportEnabled":NSNumber(value:true),"whitelistTransportTelemostLink":NSString(string:"fixture")]);fatalError("replacement admitted after close failure")}catch{}
  require(replaceProvider.whitelistTransportClient === oldSidecar && SidecarBoundary.starts==starts,"old sidecar lost")
  print("PASS actual sidecar replacement callsite retains failed handle")
  // Actual receipt writer failures reject evidence, while core error remains.
  let bad=root.appendingPathComponent("not-a-directory");try Data("x".utf8).write(to:bad)
  FilePath.cacheDirectory=bad
  for failedCore in [false,true] {
    let t=Fixture(),tp=ExtensionProvider(t);if failedCore{t.failures=["core"]}
    try await tp.startTunnel(options:nil)
    let request=tp.requestOwnedStopService(operationID:id(),journalCloseReason:"receipt_failure")
    let done=try await tp.waitOwnedStopService(request,timeout:1)
    require(!done.outcome!.evidenceFailures.isEmpty,"receipt failure masked")
    require(failedCore ? done.outcome!.primaryFailure=="core_close_failed" : done.outcome!.resourcesClosed,"primary or cleanup masked")
  }
  FilePath.cacheDirectory=root
  print("PASS actual receipt IO failure combined with core failure")
  // Production app transaction always calls OS stop, propagates the original
  // close/cancellation failure and separately retains receipt failures.
  var osStops=0
  do {
    try await WLTStopTransaction.perform(prepare:{},closeService:{_ in throw CancellationError()},stopTunnel:{osStops+=1},record:{stage,_ in stage != .appRPCError})
    fatalError("transaction failure lost")
  } catch let error as WLTStopTransaction.Failure {
    require(error.primary is CancellationError && error.receiptStages==[WLTStopStage.appRPCError.rawValue] && osStops==1,"transaction masked cancellation")
  }
  let tf=Fixture(),transactionProvider=ExtensionProvider(tf)
  try await transactionProvider.startTunnel(options:nil)
  let transactionID=id()
  try await WLTStopTransaction.perform(prepare:{},closeService:{bind in _ = try await WLTStopClient.close(operationID:transactionID,timeout:1,observeOwner:bind){data,_ in try ExtensionDiagnosticMessage.decodeResponse(transactionProvider.wire(data)!)}},stopTunnel:{osStops+=1},record:{stage,canonical in PacketTunnelDiagnostics.appendStopStage(stage.rawValue,operationID:transactionID,canonicalOperationID:canonical?.operationID,lifecycle:canonical?.lifecycle)})
  require(osStops==2 && tf.count("diagnosticsEnd")==1,"successful app transaction incomplete")
  print("PASS actual app transaction success and combined cancellation/receipt failure")
  // Actual cancellation helper retains early completion and ignores late RPC.
  let early=ExtensionDiagnosticResponseWaiter();early.resume(.failure(CancellationError()))
  do{let _:Data?=try await withCheckedThrowingContinuation{_ = early.install($0)};fatalError("early cancellation lost")}catch is CancellationError{}
  let cancel=Task{try await ExtensionDiagnosticResponseWaiter.receive(timeoutMillis:1000){_ in}}
  await Task.yield();cancel.cancel()
  do{_=try await cancel.value;fatalError("RPC cancellation lost")}catch is CancellationError{}
  do{_=try await ExtensionDiagnosticResponseWaiter.receive(timeoutMillis:10){_ in};fatalError("RPC deadline lost")}catch{}
  print("PASS real RPC waiter early cancellation, cancellation and deadline")
  // Production writer/rotation across 1 MiB. Seed a valid sequence from its
  // actual row format; archive+next writes execute unchanged production code.
  let rotate=root.appendingPathComponent("rotation");FilePath.cacheDirectory=rotate
  require(PacketTunnelDiagnostics.appendStopStage(WLTStopStage.appPrepareOK.rawValue,operationID:id()),"shared stage vocabulary")
  let url=rotate.appendingPathComponent("wlt-stop-app.jsonl")
  var row=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
  var bytes=Data();var count=0
  while bytes.count<=1024*1024{count+=1;row["sequence"]=count;var line=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);line.append(10);bytes.append(line)}
  try bytes.write(to:url)
  require(PacketTunnelDiagnostics.appendStopStage(WLTStopStage.appRPCEnter.rawValue,operationID:id()),"rotation failed")
  require(PacketTunnelDiagnostics.appendStopStage(WLTStopStage.appRPCOK.rawValue,operationID:id(),canonicalOperationID:id(),lifecycle:1),"post rotation failed")
  let archives=try FileManager.default.contentsOfDirectory(at:rotate,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.contains(".archive.")}
  require(archives.count==1 && (try! Data(contentsOf:archives[0]))==bytes,"archive evidence lost")
  let lines=try String(contentsOf:url,encoding:.utf8).split(separator:"\n")
  let last=try JSONSerialization.jsonObject(with:Data(lines.last!.utf8)) as! [String:Any]
  require(last["sequence"] as! Int==count+2,"sequence origin lost")
  print("PASS record-aware receipt rotation and subsequent append")
  _=p
 }
}
