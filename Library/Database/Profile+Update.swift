import Foundation
import GRDB
import Libbox

public extension Profile {
    nonisolated func updateRemoteProfile() async throws {
        if type != .remote {
            return
        }
        let url = remoteURL
        let remoteContent = try await HTTPClient.getStringAsync(url)
        try await BlockingIO.run {
            var error: NSError?
            LibboxCheckConfig(remoteContent, &error)
            if let error {
                throw error
            }
        }

        let oldContent = try? await readAsync()
        if oldContent == remoteContent {
            try await commitRemoteUpdateTimestamp()
            return
        }

        if let oldContent, !oldContent.isEmpty {
            try await writeLastKnownGood(oldContent)
        }
        try await writeAsync(remoteContent)
        do {
            try await onProfileUpdated()
        } catch {
            if let oldContent, !oldContent.isEmpty {
                try? await writeAsync(oldContent)
                try? await onProfileUpdated()
            }
            throw error
        }
        try await writeLastKnownGood(remoteContent)
        try await commitRemoteUpdateTimestamp()
    }

    private nonisolated func commitRemoteUpdateTimestamp() async throws {
        await MainActor.run {
            lastUpdated = Date()
        }
        try await ProfileManager.update(self)
    }

    private nonisolated func writeLastKnownGood(_ content: String) async throws {
        let backupPath = path + ".last-known-good"
        try await BlockingIO.run {
            try content.write(toFile: backupPath, atomically: true, encoding: .utf8)
        }
    }

    nonisolated func onProfileUpdated() async throws {
        if await SharedPreferences.selectedProfileID.get() == id {
            if let profile = try? await ExtensionProfile.load() {
                if await profile.status == .connected {
                    try await profile.reloadService()
                }
            }
        }
    }
}
