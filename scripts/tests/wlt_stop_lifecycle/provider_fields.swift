  let fixture:Fixture
  var commandServer:FakeServer?
  var whitelistTransportClient:LibboxWhitelistTransportClient?
  var wltCoreLifetimeJournal:FakeJournal?
  let platformInterface:FakePlatform
  let lifecycleStateLock=NSLock();var stopTunnelGeneration:UInt64=0
  var tunnelOptions:[String:NSObject]?;var reasserting=false
  init(_ f:Fixture){fixture=f;platformInterface=FakePlatform(f);super.init()}
  func beginDiagnosticsSession(){try! fixture.hit("diagnosticsBegin")}
  func endDiagnosticsSession(_ reason:String){try! fixture.hit("diagnosticsEnd")}
  func stopDiagnosticsHeartbeat(){try! fixture.hit("heartbeatStop")}
  func recordLifecycleEvent(_ text:String){}
  func writeLifecycleMessage(_ text:String){}
  func recordStartupStage(_ text:String,startedAt:Date,totalStartedAt:Date){}
  func formatDuration(_ value:TimeInterval)->String {"stub"}
  func stopReasonDescription(_ reason:NEProviderStopReason)->String {"userInitiated"}
  // OS/libbox startup boundary stub: the production outer start method owns
  // admission/release and stop races. No test calls finishTransition manually.
  func startTunnelImpl(options:[String:NSObject]?,lifecycleToken:UInt64?=nil) async throws {
    commandServer=FakeServer(fixture);wltCoreLifetimeJournal=FakeJournal(fixture)
    if fixture.failures.contains("sidecar") {whitelistTransportClient=LibboxWhitelistTransportClient(fixture)}
    try fixture.hit("startWork")
    while fixture.suspendStart && !fixture.releaseStart {try await Task.sleep(nanoseconds:1_000_000)}
    try throwIfStopTunnelRequested(since:currentStopTunnelGeneration(),lifecycleToken:lifecycleToken)
  }
  func startService(expectedStopGeneration:UInt64) async throws {
    try fixture.hit("reloadWork")
    while fixture.suspendReload && !fixture.releaseReload {try await Task.sleep(nanoseconds:1_000_000)}
  }
  func wire(_ data:Data)->Data? {handleDiagnosticMessage(data)}
  func observed()->WLTStopReply? {serviceLifecycle.snapshot()}

  func replaceSidecar(_ options:[String:NSObject]) throws { try startWhitelistTransportIfNeeded(options) }

  func persistStartOptions(_ options:[String:NSObject]) throws {}
  func applyStartOptions(_ options:[String:NSObject]) {tunnelOptions=options}
