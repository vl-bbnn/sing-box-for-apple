import Foundation
import GRDB

public enum ProfileBackupError: Error {
    case concurrentProfileChange
    case integrityCheckFailed
}

public enum ProfileManager {
    /// Creates a self-contained SQLite snapshot without checkpointing or
    /// otherwise modifying the live database. The returned paths are read from
    /// the snapshot and are safe to use as its profile/config binding.
    public nonisolated static func backupProfileDatabase(to destination: URL) async throws -> [String] {
        let before = try await Database.sharedWriter.read { db in
            return try String.fetchAll(db, sql: "SELECT path FROM profiles ORDER BY id")
        }
        let backup = try DatabaseQueue(path: destination.path)
        try Database.sharedWriter.backup(to: backup)
        let captured = try await backup.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
                throw ProfileBackupError.integrityCheckFailed
            }
            return try String.fetchAll(db, sql: "SELECT path FROM profiles ORDER BY id")
        }
        let after = try await Database.sharedWriter.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM profiles ORDER BY id")
        }
        guard before == captured, captured == after else {
            throw ProfileBackupError.concurrentProfileChange
        }
        return captured
    }

    public nonisolated static func create(_ profile: Profile) async throws {
        profile.order = try await nextOrder()
        try await Database.sharedWriter.write { db in
            try profile.insert(db, onConflict: .fail)
        }
    }

    public nonisolated static func get(_ profileID: Int64) async throws -> Profile? {
        try await Database.sharedWriter.read { db in
            try Profile.fetchOne(db, id: profileID)
        }
    }

    public nonisolated static func get(by profileName: String) async throws -> Profile? {
        try await Database.sharedWriter.read { db in
            try Profile.filter(Column("name") == profileName).fetchOne(db)
        }
    }

    public nonisolated static func get(remoteURL: String) async throws -> Profile? {
        try await Database.sharedWriter.read { db in
            try Profile
                .filter(Column("type") == ProfileType.remote.rawValue)
                .filter(Column("remoteURL") == remoteURL)
                .order(Column("order").asc)
                .fetchOne(db)
        }
    }

    public nonisolated static func delete(_ profile: Profile) async throws {
        _ = try await Database.sharedWriter.write { db in
            try profile.delete(db)
        }
    }

    public nonisolated static func delete(by id: Int64) async throws {
        _ = try await Database.sharedWriter.write { db in
            try Profile.deleteOne(db, id: id)
        }
    }

    public nonisolated static func delete(_ profileList: [Profile]) async throws -> Int {
        try await Database.sharedWriter.write { db in
            try Profile.deleteAll(db, keys: profileList.map {
                ["id": $0.id!]
            })
        }
    }

    public nonisolated static func delete(by id: [Int64]) async throws -> Int {
        try await Database.sharedWriter.write { db in
            try Profile.deleteAll(db, ids: id)
        }
    }

    public nonisolated static func update(_ profile: Profile) async throws {
        _ = try await Database.sharedWriter.write { db in
            try profile.updateChanges(db)
        }
    }

    public nonisolated static func update(_ profileList: [Profile]) async throws {
        // TODO: batch update
        try await Database.sharedWriter.write { db in
            for profile in profileList {
                try profile.updateChanges(db)
            }
        }
    }

    public nonisolated static func list() async throws -> [Profile] {
        try await Database.sharedWriter.read { db in
            try Profile.all().order(Column("order").asc).fetchAll(db)
        }
    }

    public nonisolated static func listRemote() async throws -> [Profile] {
        try await Database.sharedWriter.read { db in
            try Profile.filter(Column("type") == ProfileType.remote.rawValue).order(Column("order").asc).fetchAll(db)
        }
    }

    public nonisolated static func listAutoUpdateEnabled() async throws -> [Profile] {
        try await Database.sharedWriter.read { db in
            try Profile.filter(Column("autoUpdate") == true).order(Column("order").asc).fetchAll(db)
        }
    }

    public nonisolated static func nextID() async throws -> Int64 {
        try await Database.sharedWriter.read { db in
            if let lastProfile = try Profile.select(Column("id")).order(Column("id").desc).fetchOne(db) {
                return lastProfile.id! + 1
            } else {
                return 1
            }
        }
    }

    private nonisolated static func nextOrder() async throws -> UInt32 {
        try await Database.sharedWriter.read { db in
            try UInt32(Profile.fetchCount(db))
        }
    }

    public nonisolated static func uniqueName(_ baseName: String) async throws -> String {
        let profiles = try await list()
        let existingNames = Set(profiles.map(\.name))
        if !existingNames.contains(baseName) {
            return baseName
        }
        var counter = 1
        while true {
            let candidate = "\(baseName) (\(counter))"
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }
}
