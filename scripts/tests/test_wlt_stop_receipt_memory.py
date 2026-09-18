"""Production receipt appends must release Foundation temporaries on a live worker."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
import uuid

APPLE = Path(__file__).resolve().parents[2]


class StopReceiptMemoryTests(unittest.TestCase):
    def test_repeated_appends_bound_temporary_memory_without_discarding_history(self):
        diagnostics = (APPLE / 'Library/Network/PacketTunnelDiagnostics.swift').read_text()
        start = diagnostics.index('    private static let stopStages')
        end = diagnostics.index('\n  #endif', start)
        lifecycle = (APPLE / 'Library/Network/WLTStopOrchestrator.swift').read_text()
        lifecycle = lifecycle.replace('#if os(iOS) && SFI_DEV', '#if true')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = []
            for sequence in range(1, 2049):
                identity = str(uuid.uuid4())
                records.append(json.dumps({'schema': 2, 'sequence': sequence, 'sequence_origin': 1,
                    'operation_id': identity, 'request_id': identity, 'canonical_operation_id': identity,
                    'lifecycle': 1, 'ownership': 'provider', 'stage': 'provider_core_close_enter',
                    'outcome': 'started', 'cleanup_required': False,
                    'error': {'class': 'none', 'code': 'none', 'retryable': False},
                    'wall_unix_ms': 1000 + sequence, 'monotonic_ns': 1000000 + sequence}, sort_keys=True))
            original = ('\n'.join(records) + '\n').encode()
            receipt = root / 'wlt-stop-provider.jsonl'
            receipt.write_bytes(original)
            source = 'import Foundation\nimport Darwin\n' + lifecycle + '''
            enum FilePath { static var cacheDirectory = URL(fileURLWithPath: CommandLine.arguments[1]) }
            enum PacketTunnelDiagnostics {
              private static let queue = DispatchQueue(label: "receipt-test")
            ''' + diagnostics[start:end] + '''
            }
            @main struct Main {
              static func main() {
                var before = rusage(); getrusage(RUSAGE_SELF, &before)
                let id = UUID().uuidString
                autoreleasepool {
                  for _ in 0..<32 {
                    precondition(PacketTunnelDiagnostics.appendStopStage("provider_core_close_enter",
                      operationID: id, canonicalOperationID: id, lifecycle: 1))
                  }
                  var after = rusage(); getrusage(RUSAGE_SELF, &after)
                  print(after.ru_maxrss - before.ru_maxrss)
                }
              }
            }
            '''
            swift = root / 'main.swift'
            swift.write_text(source)
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift),
                            '-o', str(root / 'probe')], check=True, capture_output=True, timeout=60)
            result = subprocess.run([str(root / 'probe'), str(root)], check=True,
                                    capture_output=True, text=True, timeout=60)
            # The unbounded writer retains tens of MB across these appends;
            # permit allocator variation while enforcing the regression boundary.
            self.assertLess(int(result.stdout.strip()), 24 * 1024 * 1024)
            actual = receipt.read_bytes()
            self.assertTrue(actual.startswith(original))
            rows = [json.loads(line) for line in actual.splitlines()]
            self.assertEqual([row['sequence'] for row in rows], list(range(1, 2081)))
            self.assertTrue(all(row['sequence_origin'] == 1 for row in rows))


if __name__ == '__main__':
    unittest.main()
