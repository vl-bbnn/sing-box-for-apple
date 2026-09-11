import hashlib, json, shutil
from pathlib import Path
import subprocess, unittest, uuid
from .test_provider_integration import method, enabled, SRC, OUTPUT
P=Path(__file__).resolve().parent
class R12Regressions(unittest.TestCase):
 def test_actual_reload_persistence_journal_start_and_stop_receipts(self):
  profile=(SRC/'ExtensionProfile.swift').read_text().split('@MainActor\npublic class ExtensionProfile:')[0]
  profile='\n'.join(line for line in profile.splitlines() if not line.startswith('import ') and 'import FileProvider' not in line and 'private let logger' not in line)
  provider=(SRC/'ExtensionProvider.swift').read_text()
  lifecycle=provider[provider.index('    private let serviceLifecycleInitLock'):provider.index('\n  #endif',provider.index('    private let serviceLifecycleInitLock'))]
  signatures=['  override open func startTunnel(', '  private func currentStopTunnelGeneration(', '  private func throwIfStopTunnelRequested(', '    private func beginReloadTransition(', '  func reloadService(', '  private func reloadServiceWithOptions(', '    func requestOwnedStopService(', '    func waitOwnedStopService(', '    func lookupOwnedStopService(', '  override open func stopTunnel(', '  override open func handleAppMessage(', '    private func handleDiagnosticMessage(', '    private func startWhitelistTransportIfNeeded(', '    private func stopWhitelistTransport(', '    private func sanitizeWhitelistTransportSOCKS(', '  private func applyStartOptions(', '  private func persistStartOptions(', '  private func startService(', '  public struct OverridePreferences']
  methods='\n'.join(method(provider,x) for x in signatures)
  diagnostics=(SRC/'PacketTunnelDiagnostics.swift').read_text();begin=diagnostics.index('    private static let stopStages');end=diagnostics.index('\n  #endif',begin)
  source='import Foundation\n'+(SRC/'WLTStopOrchestrator.swift').read_text()+'\n'+profile+'\n'+(SRC/'WLTCoreLifetimeJournal.swift').read_text()+'\n'+(SRC/'ExtensionStartOptions.swift').read_text()+'\n'
  source+='''
public enum NEProviderStopReason { case userInitiated }
open class NEPacketTunnelProvider {
 open func startTunnel(options:[String:NSObject]?) async throws {}
 open func stopTunnel(with reason:NEProviderStopReason) async {}
 open func handleAppMessage(_ data:Data) async -> Data? {nil}
}
struct ExtensionStartupError:Error {let text:String;init(_ text:String){self.text=text}}
enum FilePath {static var cacheDirectory=URL(fileURLWithPath:CommandLine.arguments[1])}
enum PacketTunnelDiagnostics {
 private static let queue=DispatchQueue(label:"receipts")
 static func appendStartupMilestone(_ value:String){}
 static func residentMemoryDescription()->String {"stub"}
'''+diagnostics[begin:end]+'\n}\n'+(P/'r12_regression_stubs.swift').read_text()
  source+='\nopen class ExtensionProvider:NEPacketTunnelProvider {\n'+lifecycle+'\n'+(P/'r12_regression_fields.swift').read_text()+'\n'+methods+'\n}\n'+(P/'r12_regression_cases.swift').read_text()
  O=OUTPUT/('regressions-'+uuid.uuid4().hex);O.mkdir(parents=True)
  (O/'source-bindings.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in SRC.glob('*.swift')},indent=2)+'\n')
  for fixture in P.glob('*.py'):shutil.copy2(fixture,O/fixture.name)
  for fixture in P.glob('*_*.swift'):shutil.copy2(fixture,O/fixture.name)
  (OUTPUT/'latest-regressions-run.txt').write_text(str(O.resolve())+'\n')
  generated=O/'r12-regressions.swift';generated.write_text(enabled(source))
  compiled=subprocess.run(['swiftc','-D','SFI_DEV','-swift-version','5','-parse-as-library',str(generated),'-o',str(O/'r12-regressions')],text=True,capture_output=True,timeout=60)
  (O/'r12-regressions-compile.log').write_text(compiled.stdout+compiled.stderr);self.assertEqual(compiled.returncode,0,compiled.stderr)
  run=subprocess.run([str(O/'r12-regressions'),str(O/('r12-regression-evidence-'+uuid.uuid4().hex))],text=True,capture_output=True,timeout=60)
  (O/'r12-regressions-run.log').write_text(run.stdout+run.stderr);self.assertEqual(run.returncode,0,run.stdout+run.stderr)
if __name__=='__main__':unittest.main()
