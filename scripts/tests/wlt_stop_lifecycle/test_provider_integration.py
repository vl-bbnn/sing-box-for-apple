import hashlib, json, shutil
from pathlib import Path
import re, subprocess, unittest, uuid
P=Path(__file__).resolve().parent
SRC=P.parents[2]/'Library/Network'
OUTPUT=SRC.parents[1]/'.local/stop-lifecycle-host-tests'

def enabled(source):
    return source.replace('#if os(iOS) && SFI_DEV','#if true').replace('#if os(macOS)','#if false').replace('#if os(iOS)','#if true')

def method(source, signature):
    start=source.index(signature); brace=source.index('{',start)
    masked=re.sub(r'"(?:\\.|[^"\\])*"',lambda m:' '*len(m[0]), source)
    depth=1;end=brace+1
    while depth:
        if masked[end]=='{':depth+=1
        if masked[end]=='}':depth-=1
        end+=1
    return source[start:end]

class ProviderIntegration(unittest.TestCase):
    def test_actual_provider_entrypoints_protocol_waiter_and_receipts(self):
        profile_source=(SRC/'ExtensionProfile.swift').read_text()
        app_stop=method(profile_source,'  public func stop(')
        app_timeout=re.search(r'WLTStopClient\.close\(operationID: stopOperationID, timeout: ([0-9]+)',app_stop)
        self.assertIsNotNone(app_timeout, 'bind delayed-close test to the actual app stop timeout')
        profile=profile_source.split('@MainActor\npublic class ExtensionProfile:')[0]
        profile='\n'.join(line for line in profile.splitlines() if not line.startswith('import ') and 'import FileProvider' not in line and 'private let logger' not in line)
        provider=(SRC/'ExtensionProvider.swift').read_text()
        lifecycle=provider[provider.index('    private let serviceLifecycleInitLock'):provider.index('\n  #endif',provider.index('    private let serviceLifecycleInitLock'))]
        methods='\n'.join(method(provider,x) for x in [
            '  override open func startTunnel(', '  private func currentStopTunnelGeneration(',
            '  private func throwIfStopTunnelRequested(', '    private func beginReloadTransition(',
            '  func reloadService(', '  private func reloadServiceWithOptions(', '    func requestOwnedStopService(', '    func waitOwnedStopService(', '    func lookupOwnedStopService(',
            '  override open func stopTunnel(', '    private func handleDiagnosticMessage(',
            '    private func startWhitelistTransportIfNeeded(', '    private func stopWhitelistTransport(',
            '    private func sanitizeWhitelistTransportSOCKS('])
        platform=method((SRC/'ExtensionPlatformInterface.swift').read_text(),'  public func serviceStop(')
        diagnostics=(SRC/'PacketTunnelDiagnostics.swift').read_text()
        begin=diagnostics.index('    private static let stopStages')
        end=diagnostics.index('\n  #endif',begin)
        receipts=diagnostics[begin:end]
        source='import Foundation\n'+(SRC/'WLTStopOrchestrator.swift').read_text()+'\n'+profile+'\n'
        source+='let productionAppStopTimeout: TimeInterval = '+app_timeout.group(1)+'\n'
        source+='''
public enum NEProviderStopReason { case userInitiated }
open class NEPacketTunnelProvider {
  open func startTunnel(options: [String:NSObject]?) async throws {}
  open func stopTunnel(with reason: NEProviderStopReason) async {}
}
struct ExtensionStartupError: Error { let text:String; init(_ text:String){self.text=text} }
enum FilePath { static var cacheDirectory=URL(fileURLWithPath:CommandLine.arguments[1]) }
enum PacketTunnelDiagnostics {
  private static let queue=DispatchQueue(label:"receipts")
  static func appendStartupMilestone(_ value:String) {}
  static func residentMemoryDescription()->String { "stub" }
'''+receipts+'\n}\n'+(P/'provider_stubs.swift').read_text()
        source+='\nopen class ExtensionProvider: NEPacketTunnelProvider {\n'+lifecycle+'\n'+(P/'provider_fields.swift').read_text()+'\n'+methods+'\n}\n'
        source+='\nfinal class ExtensionPlatformInterface { let tunnel:ExtensionProvider; init(_ tunnel:ExtensionProvider){self.tunnel=tunnel}\n'+platform+'\n}\n'
        source+=(P/'provider_cases.swift').read_text()
        O=OUTPUT/('provider-'+uuid.uuid4().hex);O.mkdir(parents=True)
        (O/'source-bindings.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in SRC.glob('*.swift')},indent=2)+'\n')
        for fixture in P.glob('*.py'):shutil.copy2(fixture,O/fixture.name)
        for fixture in P.glob('*_*.swift'):shutil.copy2(fixture,O/fixture.name)
        (OUTPUT/'latest-provider-run.txt').write_text(str(O.resolve())+'\n')
        generated=O/'provider-integration.swift';generated.write_text(enabled(source))
        compiled=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(generated),'-o',str(O/'provider-integration')],text=True,capture_output=True,timeout=60)
        (O/'compile.log').write_text(compiled.stdout+compiled.stderr)
        self.assertEqual(compiled.returncode,0,compiled.stderr)
        run=subprocess.run([str(O/'provider-integration'),str(O/('receipts-'+uuid.uuid4().hex))],text=True,capture_output=True,timeout=60)
        (O/'run.log').write_text(run.stdout+run.stderr)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)

if __name__=='__main__':unittest.main()
