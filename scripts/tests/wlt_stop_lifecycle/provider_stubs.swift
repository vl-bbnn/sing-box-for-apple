final class Fixture: @unchecked Sendable {
  let lock=NSLock(); private var values:[String]=[]
  var failures:Set<String>=[]; var gates:[String:DispatchSemaphore]=[:]
  var suspendStart=false, suspendReload=false; var releaseStart=false, releaseReload=false
  func hit(_ stage:String) throws {
    lock.lock();values.append(stage);let gate=gates[stage];let fail=failures.contains(stage);lock.unlock()
    gate?.wait()
    if fail {throw NSError(domain:stage,code:1)}
  }
  func count(_ stage:String)->Int {lock.lock();defer{lock.unlock()};return values.filter{$0==stage}.count}
}
final class FakeServer {
  let f:Fixture;init(_ f:Fixture){self.f=f}
  func closeService() throws {try f.hit("core")}
  func close() {try! f.hit("server")}
  func probeWltOutbound(_ value:String,error:inout NSError?)->String {"{}"}
}
final class FakeJournal {
  let f:Fixture;init(_ f:Fixture){self.f=f}
  func didCloseService(reason:String,finalizeSession:Bool,terminalObserversConfirmed:Bool) throws {precondition(terminalObserversConfirmed);try f.hit("journal")}
  func didFailToCloseService(reason:String,errorDescription:String,finalizeSession:Bool) throws {try f.hit("failedJournal")}
}
final class FakePlatform {
  let f:Fixture;init(_ f:Fixture){self.f=f}
  func reset(){try! f.hit("platform")}
}

enum WhitelistTransportConfig { static func usesCoreWhitelistTransport(_ text:String)->Bool {false} }
final class LibboxWhitelistTransportOptions {
 var transport="",turnableConfig="",turnableListeners="",socks="",telemostLink="",telemostDisplayName=""
 var startTimeoutMS:Int=0
 var telemostVP8FPS:Int32=0,telemostVP8Batch:Int32=0,telemostPayloadSize:Int32=0
}
final class LibboxWhitelistTransportClient {
 let f:Fixture;init(_ f:Fixture){self.f=f}
 func close() throws {try f.hit("sidecar")}
}
enum SidecarBoundary { static var starts=0;static let fixture=Fixture() }
func LibboxStartWhitelistTransport(_ options:LibboxWhitelistTransportOptions,_ error:inout NSError?)->LibboxWhitelistTransportClient? {
 SidecarBoundary.starts+=1;return LibboxWhitelistTransportClient(SidecarBoundary.fixture)
}
