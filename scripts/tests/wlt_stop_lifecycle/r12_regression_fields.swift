 let fixture:Fixture
 var commandServer:FakeServer?
 var whitelistTransportClient:LibboxWhitelistTransportClient?
 var wltCoreLifetimeJournal:WLTCoreLifetimeJournal?
 let platformInterface:FakePlatform
 let lifecycleStateLock=NSLock();var stopTunnelGeneration:UInt64=0
 var tunnelOptions:[String:NSObject]?;var reasserting=false
 var whitelistTransportProfileIsCore=false
 var overridePreferences:OverridePreferences?
 var startOptionsURL:URL?
 init(_ fixture:Fixture,snapshot:URL){self.fixture=fixture;platformInterface=FakePlatform(fixture);startOptionsURL=snapshot;super.init()}
 func beginDiagnosticsSession(){try! fixture.hit("diagnosticsBegin")}
 func endDiagnosticsSession(_ reason:String){try! fixture.hit("diagnosticsEnd")}
 func stopDiagnosticsHeartbeat(){try! fixture.hit("heartbeatStop")}
 func recordLifecycleEvent(_ text:String){}
 func writeLifecycleMessage(_ text:String){}
 func recordStartupStage(_ text:String,startedAt:Date,totalStartedAt:Date){}
 func formatDuration(_ value:TimeInterval)->String {"stub"}
 func stopReasonDescription(_ reason:NEProviderStopReason)->String {"userInitiated"}
 // Only packet tunnel OS/libbox initialization is stubbed. The real production
 // persistence, apply options, startService journal creation and generation
 // lifecycle run unchanged on both initial and following tunnel lifecycles.
 func startTunnelImpl(options:[String:NSObject]?,lifecycleToken:UInt64?=nil) async throws {
  let effective=options ?? ["configContent":NSString(string:"{\"outbounds\":[{\"type\":\"wlt\"}]}")]
  try persistStartOptions(effective);applyStartOptions(effective)
  commandServer=FakeServer(fixture)
  try throwIfStopTunnelRequested(since:currentStopTunnelGeneration(),lifecycleToken:lifecycleToken)
  try await startService(expectedStopGeneration:currentStopTunnelGeneration())
  try throwIfStopTunnelRequested(since:currentStopTunnelGeneration(),lifecycleToken:lifecycleToken)
 }
 func wire(_ data:Data)->Data? {handleDiagnosticMessage(data)}
 func observed()->WLTStopReply? {serviceLifecycle.snapshot()}
