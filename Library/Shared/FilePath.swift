import Foundation

public enum FilePath {
    public static let packageName = AppConfiguration.packageName
    public static let groupName = AppConfiguration.appGroupID

    private static let defaultSharedDirectory: URL! = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)

    #if os(iOS)
        public static let sharedDirectory = defaultSharedDirectory!
    #elseif os(tvOS)
        public static let sharedDirectory = defaultSharedDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    #elseif os(macOS)
        public static var sharedDirectory: URL! = defaultSharedDirectory
    #endif

    #if os(iOS)
        public static let cacheDirectory = sharedDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    #elseif os(tvOS)
        public static let cacheDirectory = sharedDirectory
    #elseif os(macOS)
        public static var cacheDirectory: URL {
            sharedDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
        }
    #endif

    #if os(macOS)
        public static var workingDirectory: URL {
            cacheDirectory.appendingPathComponent("Working", isDirectory: true)
        }
    #else
        public static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)

    #endif

    public static var iCloudDirectory = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true) ?? URL(string: "stub")!
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}

#if SFI_DEV
import Foundation
import Darwin

/// Shared app/extension auth state is durable; cache eviction must not log out WLT.
public enum WLTAuthStorage {
    private static func directory(_ url: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return false }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw NSError(domain: "WLTAuthStorage", code: 1)
        }
        return true
    }

    public static func snapshotURL(library: URL, legacy: URL) throws -> URL {
        let manager = FileManager.default
        guard try directory(library) else { throw NSError(domain: "WLTAuthStorage", code: 2) }
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        if try !directory(support) {
            do { try manager.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { guard try directory(support) else { throw error } }
        }
        // Both PacketTunnel and the control app can enter during startup.
        // A process-local lock alone would not prevent an empty destination race.
        let lockURL = support.appendingPathComponent(".wlt-auth-migration.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: "WLTAuthStorage", code: 3)
        }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(fd, LOCK_UN) }
        let durable = support.appendingPathComponent("WLT", isDirectory: true)
        if try !directory(durable) {
            let staging = support.appendingPathComponent(".wlt-migrate-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
            #endif
            var transferred: [(URL, Data)] = []
            if try directory(legacy) {
                for child in try manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                    let name = child.lastPathComponent
                    // Diagnostics are disposable and can be large. Never move
                    // LifetimeJournals or unrelated cache entries into durable auth.
                    guard name.hasPrefix("auth-snapshot.json") || name == "wlt-dns-cache.json" else { continue }
                    let attributes = try manager.attributesOfItem(atPath: child.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = attributes[.size] as? NSNumber,
                          size.intValue <= 1_048_576 else {
                        throw NSError(domain: "WLTAuthStorage", code: 4)
                    }
                    let data = try Data(contentsOf: child)
                    guard data.count == size.intValue else { throw NSError(domain: "WLTAuthStorage", code: 5) }
                    let copy = staging.appendingPathComponent(name)
                    try data.write(to: copy, options: [.withoutOverwriting])
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                    #if os(iOS)
                    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copy.path)
                    #endif
                    transferred.append((child, data))
                }
            }
            // Any copy/read/validation failure leaves every source intact and
            // the destination invisible. Commit the complete ring at once.
            for (source, data) in transferred {
                guard try Data(contentsOf: source) == data else { throw NSError(domain: "WLTAuthStorage", code: 6) }
            }
            try manager.moveItem(at: staging, to: durable)
            // Never delete a source another owner changed after our snapshot.
            for (source, data) in transferred {
                if let current = try? Data(contentsOf: source), current == data { try manager.removeItem(at: source) }
            }
            if (try? manager.contentsOfDirectory(atPath: legacy.path).isEmpty) == true { try manager.removeItem(at: legacy) }
        }
        // An existing durable ring is authoritative. Never merge stale cache
        // bytes into it or resurrect a legacy quarantined identity.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: durable.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: durable.path)
        #endif
        return durable.appendingPathComponent("auth-snapshot.json")
    }
    /// Dev control only: restore cache auth before rolling back to a legacy app.
    /// Callers must first prove the tunnel is stopped; no credentials are minted.
    public static func rollbackMigration(library: URL, legacy: URL) throws {
        let manager = FileManager.default
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        guard try directory(support) else { return }
        let fd = open(support.appendingPathComponent(".wlt-auth-migration.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw NSError(domain: "WLTAuthStorage", code: 3) }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(fd, LOCK_UN) }
        let durable = support.appendingPathComponent("WLT", isDirectory: true)
        guard try directory(durable) else { return }
        guard try directory(legacy.deletingLastPathComponent()) else { throw NSError(domain: "WLTAuthStorage", code: 7) }
        var records: [(URL, Data)] = []
        for source in try manager.contentsOfDirectory(at: durable, includingPropertiesForKeys: nil) {
            let name = source.lastPathComponent
            let attributes = try manager.attributesOfItem(atPath: source.path)
            guard name.hasPrefix("auth-snapshot.json") || name == "wlt-dns-cache.json",
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else { throw NSError(domain: "WLTAuthStorage", code: 8) }
            let data = try Data(contentsOf: source)
            guard data.count == size.intValue else { throw NSError(domain: "WLTAuthStorage", code: 5) }
            records.append((source, data))
        }
        if try !directory(legacy) { try manager.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        // Validate every destination before any write. Conflicting cache bytes
        // stay intact and the complete durable ring stays authoritative.
        for (source, data) in records {
            let target = legacy.appendingPathComponent(source.lastPathComponent)
            if let attributes = try? manager.attributesOfItem(atPath: target.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      try Data(contentsOf: target) == data else { throw NSError(domain: "WLTAuthStorage", code: 9) }
            }
        }
        for (source, data) in records {
            let target = legacy.appendingPathComponent(source.lastPathComponent)
            if !manager.fileExists(atPath: target.path) { try data.write(to: target, options: [.withoutOverwriting]) }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            #endif
            guard try Data(contentsOf: target) == data && Data(contentsOf: source) == data else { throw NSError(domain: "WLTAuthStorage", code: 10) }
        }
        let remaining = try manager.contentsOfDirectory(at: durable, includingPropertiesForKeys: nil)
        guard Set(remaining.map(\.lastPathComponent)) == Set(records.map { $0.0.lastPathComponent }) else { throw NSError(domain: "WLTAuthStorage", code: 11) }
        try manager.removeItem(at: durable)
    }

}

#endif
