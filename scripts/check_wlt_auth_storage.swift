import Foundation
import Dispatch

@main
struct CheckWLTAuthStorage {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Caches/WLT")
        let durable = root.appendingPathComponent("Application Support/WLTAuth")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let names = ["auth-snapshot.json", "auth-snapshot.json.reserve", "auth-snapshot.json.provider-cooldown"]
        for name in names { try Data(name.utf8).write(to: legacy.appendingPathComponent(name)) }
        let snapshot = try WLTAuthStorage.prepare(legacy: legacy, durable: durable)
        for name in names {
            precondition(tryData(durable.appendingPathComponent(name)) == tryData(legacy.appendingPathComponent(name)))
        }
        try Data("new identity".utf8).write(to: snapshot)
        _ = try WLTAuthStorage.prepare(legacy: legacy, durable: durable)
        precondition(tryData(snapshot) == Data("new identity".utf8))
        try fm.removeItem(at: snapshot)
        _ = try WLTAuthStorage.prepare(legacy: legacy, durable: durable)
        precondition(!fm.fileExists(atPath: snapshot.path), "stale identity resurrected")
        try fm.removeItem(at: legacy)
        _ = try WLTAuthStorage.prepare(legacy: legacy, durable: durable)
        precondition(fm.fileExists(atPath: durable.appendingPathComponent(names[1]).path))
        let fresh = root.appendingPathComponent("fresh/Auth")
        _ = try WLTAuthStorage.prepare(legacy: legacy, durable: fresh)
        precondition(fm.fileExists(atPath: fresh.path))
        // Invalid source must not commit a partial migration.
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("active".utf8).write(to: legacy.appendingPathComponent(names[0]))
        try fm.createSymbolicLink(at: legacy.appendingPathComponent(names[1]), withDestinationURL: durable.appendingPathComponent(names[1]))
        let rejected = root.appendingPathComponent("rejected/Auth")
        do { _ = try WLTAuthStorage.prepare(legacy: legacy, durable: rejected); fatalError("accepted symlink") }
        catch { precondition(!fm.fileExists(atPath: rejected.path)) }
        try fm.removeItem(at: legacy.appendingPathComponent(names[1]))
        let concurrent = root.appendingPathComponent("concurrent/Auth")
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            let file = try! WLTAuthStorage.prepare(legacy: legacy, durable: concurrent)
            precondition(tryData(file) == Data("active".utf8))
        }
        let remaining = try fm.contentsOfDirectory(atPath: concurrent.deletingLastPathComponent().path).filter { $0.hasPrefix(".wlt-auth-") && $0 != ".wlt-auth-migration.lock" }
        precondition(remaining.isEmpty)
        print("WLT auth storage: migration, cache eviction, repeat, deletion, empty enrollment and atomic failure passed")
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
}
