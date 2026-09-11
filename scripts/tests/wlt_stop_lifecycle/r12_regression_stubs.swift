final class Fixture: @unchecked Sendable {
 let lock=NSLock();private var calls:[String]=[]
 var failures:Set<String>=[];var gates:[String:DispatchSemaphore]=[:]
 func hit(_ stage:String) throws {
  lock.lock();calls.append(stage);let gate=gates[stage];let fail=failures.contains(stage);lock.unlock()
  gate?.wait();if fail {throw NSError(domain:stage,code:1)}
 }
 func count(_ stage:String)->Int {lock.lock();defer{lock.unlock()};return calls.filter{$0==stage}.count}
}
final class FakeServer {
 let f:Fixture;init(_ f:Fixture){self.f=f}
 func closeService() throws {try f.hit("coreClose")}
 func close(){try! f.hit("serverClose")}
 func startOrReloadService(_ config:String,options:LibboxOverrideOptions) throws {try f.hit("startCore")}
 func probeWltOutbound(_ value:String,error:inout NSError?)->String {"{}"}
}
final class FakePlatform {let f:Fixture;init(_ f:Fixture){self.f=f};func reset(){try! f.hit("platformReset")}}
final class LibboxOverrideOptions {}
enum WhitelistTransportConfig {
 static func usesCoreWhitelistTransport(_ config:String)->Bool {config.contains("wlt")}
 static func injectingCoreAuthSnapshotFile(into config:String,snapshotFile:URL)->String {config}
}
final class LibboxWhitelistTransportOptions {
 var transport="",turnableConfig="",turnableListeners="",socks="",telemostLink="",telemostDisplayName=""
 var startTimeoutMS:Int=0;var telemostVP8FPS:Int32=0,telemostVP8Batch:Int32=0,telemostPayloadSize:Int32=0
}
final class LibboxWhitelistTransportClient {func close() throws {}}
func LibboxStartWhitelistTransport(_ options:LibboxWhitelistTransportOptions,_ error:inout NSError?)->LibboxWhitelistTransportClient? {LibboxWhitelistTransportClient()}
