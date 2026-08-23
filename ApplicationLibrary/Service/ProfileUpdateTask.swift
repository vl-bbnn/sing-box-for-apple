import Foundation
import Library

public enum ProfileUpdateTask {
    static let minUpdateInterval: TimeInterval = 15 * 60
    static let defaultUpdateInterval: TimeInterval = 60 * 60

    private static var timer: Timer?

    public static func configure() async throws {
        timer?.invalidate()
        timer = nil
        let profiles = try await ProfileManager.listAutoUpdateEnabled()
        if profiles.isEmpty {
            return
        }
        var updateInterval = profiles.map { it in
            it.autoUpdateIntervalOrDefault
        }.min()!
        if updateInterval < minUpdateInterval {
            updateInterval = minUpdateInterval
        }
        let newTimer = Timer(fire: calculateEarliestBeginDate(profiles), interval: updateInterval, repeats: true) { _ in
            Task {
                await getAndupdateProfiles()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    static func calculateEarliestBeginDate(_ profiles: [Profile]) -> Date {
        let nowTime = Date.now
        var earliestBeginDate = profiles.map { profile in
            guard let lastUpdated = profile.lastUpdated else {
                return nowTime
            }
            return lastUpdated.addingTimeInterval(profile.autoUpdateIntervalOrDefault)
        }.min() ?? nowTime
        if earliestBeginDate <= nowTime {
            earliestBeginDate = nowTime
        }
        return earliestBeginDate
    }

    private nonisolated static func getAndupdateProfiles() async {
        do {
            _ = try await updateProfiles(ProfileManager.listAutoUpdateEnabled())
            NSLog("profile update task succeed")
        } catch {
            NSLog("profile update task failed: \(error.localizedDescription)")
        }
    }

    static func updateProfiles(_ profiles: [Profile]) async -> Bool {
        var success = true
        for profile in profiles {
            let profileName = profile.name
            if let lastUpdated = profile.lastUpdated,
               lastUpdated > Date(timeIntervalSinceNow: -profile.autoUpdateIntervalOrDefault)
            {
                continue
            }
            if await shouldDeferAutomaticUpdate(profile) {
                NSLog("Deferred automatic selected/WLT profile update until VPN is connected")
                continue
            }
            do {
                try await profile.updateRemoteProfile()
                NSLog("Updated profile %@", profileName)
            } catch {
                NSLog("Update profile %@ failed: %@", profileName, error.localizedDescription)
                success = false
            }
        }
        return success
    }

    private nonisolated static func shouldDeferAutomaticUpdate(_ profile: Profile) async -> Bool {
        let selectedProfileID = await SharedPreferences.selectedProfileID.get()
        let isSelected = profile.id == selectedProfileID
        let content = try? await profile.readAsync()
        let usesWLT = content.map(WhitelistTransportConfig.usesCoreWhitelistTransport) ?? false
        if !isSelected && !usesWLT { return false }
        guard let extensionProfile = try? await ExtensionProfile.load() else {
            return true
        }
        return await extensionProfile.status != .connected
    }
}

extension Profile {
    var autoUpdateIntervalOrDefault: TimeInterval {
        if autoUpdateInterval > 0 {
            return TimeInterval(autoUpdateInterval * 60)
        } else {
            return ProfileUpdateTask.defaultUpdateInterval
        }
    }
}
