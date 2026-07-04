import AppIntents
import Foundation
import Library

struct StartServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Service"

    static let description = IntentDescription("Start or reload service with specified profile")

    static var parameterSummary: some ParameterSummary {
        Summary("Start service with profile \(\.$profile).")
    }

    @Parameter(title: "Profile", optionsProvider: ProfileProvider())
    var profile: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let extensionProfile = try await (ExtensionProfile.load()) else {
            throw NSError(domain: "IntentsExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "NetworkExtension not installed")])
        }
        let profileList = try await ProfileManager.list()
        let specifiedProfile = profileList.first { $0.name == profile }
        var profileChanged = false
        if let specifiedProfile {
            let specifiedProfileID = specifiedProfile.mustID
            if await SharedPreferences.selectedProfileID.get() != specifiedProfileID {
                await SharedPreferences.selectedProfileID.set(specifiedProfileID)
                profileChanged = true
            }
        } else if profile != "default" {
            throw NSError(domain: "IntentsExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Specified profile not found: \(profile)")])
        }
        if await extensionProfile.status == .connected {
            if !profileChanged {
                return .result(dialog: "Service is already running")
            }
            try await extensionProfile.reloadService()
        } else if await extensionProfile.status.isConnected {
            try await extensionProfile.restart()
        } else {
            try await extensionProfile.start()
        }
        return .result(dialog: "Service started")
    }
}

struct RestartServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart Service"

    static let description = IntentDescription("Restart service")

    static var parameterSummary: some ParameterSummary {
        Summary("Restart service")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let extensionProfile = try await (ExtensionProfile.load()) else {
            return .result(dialog: "Service is not installed")
        }
        if await extensionProfile.status == .connected {
            try await extensionProfile.reloadService()
        } else if await extensionProfile.status.isConnected {
            try await extensionProfile.restart()
        } else {
            try await extensionProfile.start()
        }
        return .result(dialog: "Service restarted")
    }
}

struct StopServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Service"

    static let description = IntentDescription("Stop service")

    static var parameterSummary: some ParameterSummary {
        Summary("Stop service")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let extensionProfile = try await (ExtensionProfile.load()) else {
            return .result(dialog: "Service is not installed")
        }
        try await extensionProfile.stop()
        return .result(dialog: "Service stopped")
    }
}

struct ToggleServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Service"

    static let description = IntentDescription("Toggle service")

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle service")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let extensionProfile = try await (ExtensionProfile.load()) else {
            return .result(value: false)
        }
        if await extensionProfile.status.isConnected {
            try await extensionProfile.stop()
            return .result(value: false)

        } else {
            try await extensionProfile.start()
            return .result(value: true)
        }
    }
}

struct GetServiceStatus: AppIntent {
    static let title: LocalizedStringResource = "Get Service Status"

    static let description = IntentDescription("Get service status")

    static var parameterSummary: some ParameterSummary {
        Summary("Get service status")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let extensionProfile = try await (ExtensionProfile.load()) else {
            return .result(value: false)
        }
        return await .result(value: extensionProfile.status.isConnected)
    }
}

struct GetCurrentProfile: AppIntent {
    static let title: LocalizedStringResource = "Get Current Profile"

    static let description = IntentDescription("Get current profile")

    static var parameterSummary: some ParameterSummary {
        Summary("Get current profile")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let profile = try await ProfileManager.get(SharedPreferences.selectedProfileID.get()) else {
            throw NSError(domain: "IntentsExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "No profile selected")])
        }
        return .result(value: profile.name)
    }
}

struct UpdateProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Update Profile"

    static let description = IntentDescription("Update specified profile")

    static var parameterSummary: some ParameterSummary {
        Summary("Update profile \(\.$profile).")
    }

    @Parameter(title: "Profile", optionsProvider: RemoteProfileProvider())
    var profile: String

    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let profile = try await ProfileManager.get(by: profile) else {
            throw NSError(domain: "IntentsExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Specified profile not found: \(profile)")])
        }
        if profile.type != .remote {
            throw NSError(domain: "IntentsExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Specified profile is not a remote profile")])
        }
        try await profile.updateRemoteProfile()
        return .result(dialog: "Profile updated")
    }
}

class ProfileProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        var profileNames = try await ProfileManager.list().map(\.name)
        if !profileNames.contains("default") {
            profileNames.insert("default", at: 0)
        }
        return profileNames
    }
}

class RemoteProfileProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        try await ProfileManager.listRemote().map(\.name)
    }
}

struct ServiceShortcuts: AppShortcutsProvider {
    private static let startPhrases: [AppShortcutPhrase<StartServiceIntent>] = ["Start \(.applicationName)"]
    private static let stopPhrases: [AppShortcutPhrase<StopServiceIntent>] = ["Stop \(.applicationName)"]
    private static let restartPhrases: [AppShortcutPhrase<RestartServiceIntent>] = ["Restart \(.applicationName)"]
    private static let togglePhrases: [AppShortcutPhrase<ToggleServiceIntent>] = ["Toggle \(.applicationName)"]
    private static let updatePhrases: [AppShortcutPhrase<UpdateProfileIntent>] = ["Update \(.applicationName) profile"]

    static var appShortcuts: [AppShortcut] {
        if #available(iOS 17.0, *) {
            return [
                AppShortcut(
                    intent: StartServiceIntent(),
                    phrases: startPhrases,
                    shortTitle: "Start",
                    systemImageName: "power"
                ),
                AppShortcut(
                    intent: StopServiceIntent(),
                    phrases: stopPhrases,
                    shortTitle: "Stop",
                    systemImageName: "stop.fill"
                ),
                AppShortcut(
                    intent: RestartServiceIntent(),
                    phrases: restartPhrases,
                    shortTitle: "Restart",
                    systemImageName: "arrow.clockwise"
                ),
                AppShortcut(
                    intent: ToggleServiceIntent(),
                    phrases: togglePhrases,
                    shortTitle: "Toggle",
                    systemImageName: "arrow.triangle.2.circlepath"
                ),
                AppShortcut(
                    intent: UpdateProfileIntent(),
                    phrases: updatePhrases,
                    shortTitle: "Update Profile",
                    systemImageName: "arrow.down.circle"
                ),
            ]
        } else {
            return [
                AppShortcut(
                    intent: StartServiceIntent(),
                    phrases: startPhrases
                ),
                AppShortcut(
                    intent: StopServiceIntent(),
                    phrases: stopPhrases
                ),
                AppShortcut(
                    intent: RestartServiceIntent(),
                    phrases: restartPhrases
                ),
                AppShortcut(
                    intent: ToggleServiceIntent(),
                    phrases: togglePhrases
                ),
                AppShortcut(
                    intent: UpdateProfileIntent(),
                    phrases: updatePhrases
                ),
            ]
        }
    }
}
