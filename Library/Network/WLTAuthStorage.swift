#if SFI_DEV
import Foundation
import Darwin

/// Enrolled identities are durable state, not disposable network caches.
public enum WLTAuthStorage {
    public static func prepare(legacy: URL, durable: URL) throws -> URL {
        let manager = FileManager.default
        let parent = durable.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let descriptor = open(parent.appendingPathComponent(".wlt-auth-migration.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let snapshot = durable.appendingPathComponent("auth-snapshot.json")
        // The directory itself is the migration commit. Never resurrect an
        // intentionally removed identity from the stale legacy cache.
        if manager.fileExists(atPath: durable.path) {
            guard try durable.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try durable.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return snapshot
        }
        let staging = parent.appendingPathComponent(".wlt-auth-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let suffixes = ["", ".previous", ".reserve", ".reserve.previous", ".quarantine",
                        ".provider-cooldown", ".bootstrap-consumed", ".test-reject-active-once"]
        for suffix in suffixes {
            let name = "auth-snapshot.json" + suffix
            let source = legacy.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            let metadata = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let destination = staging.appendingPathComponent(name)
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        for file in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
        #endif
        try manager.moveItem(at: staging, to: durable)
        return snapshot
    }
}
#endif
