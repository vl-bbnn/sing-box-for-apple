import Foundation

public enum AppConfiguration {
    private static func overlayValue(_ key: String, fallback: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    public static var applicationName: String {
        overlayValue("OverlayApplicationName", fallback: "sing-box")
    }

    public static var clientImportScheme: String {
        overlayValue("VPNClientImportScheme", fallback: packageName)
    }

    public static var applicationLink: String {
        overlayValue("OverlayApplicationLink", fallback: "https://example.com/2b2n-vpn/")
    }

    public static var changelogLink: String {
        overlayValue("OverlayChangelogLink", fallback: "https://example.com/2b2n-vpn/changelog/")
    }

    public static var configurationLink: String {
        overlayValue("OverlayConfigurationLink", fallback: "https://example.com/2b2n-vpn/configuration/")
    }

    public static var sourceLink: String {
        overlayValue("OverlaySourceLink", fallback: "https://example.com/2b2n-stack/source/")
    }

    public static var releasesLink: String {
        overlayValue("OverlayReleasesLink", fallback: "https://example.com/2b2n-vpn/releases/")
    }

    public static var singBoxCoreLink: String {
        overlayValue("OverlaySingBoxCoreLink", fallback: "https://github.com/SagerNet/sing-box")
    }

    public static var singBoxAppleClientLink: String {
        overlayValue("OverlaySingBoxAppleClientLink", fallback: "https://github.com/SagerNet/sing-box-for-apple")
    }

    public static var singBoxLXLink: String {
        overlayValue("OverlaySingBoxLXLink", fallback: "https://github.com/Leadaxe/sing-box-lx")
    }

    public static var stackSourceLink: String {
        overlayValue("OverlayStackSourceLink", fallback: "https://github.com/vl-bbnn/2b2n-stack")
    }

    public static var showsAppStoreReview: Bool {
        !["bbnn-vpn", "2b2n-vpn", "dev-vpn"].contains(applicationName)
    }

    public static let iCloudDirectoryName = "sing-box"

    public static let packageName: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()

    public static let appGroupID: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()

    public static var teamID: String {
        guard let dotIndex = appGroupID.firstIndex(of: ".") else {
            fatalError("Invalid appGroupID format: \(appGroupID)")
        }
        return String(appGroupID[..<dotIndex])
    }

    public static var extensionBundleID: String {
        "\(packageName).extension"
    }

    public static var systemExtensionBundleID: String {
        "\(packageName).system"
    }

    #if os(macOS)
        /// After a system-extension replace, launchd keeps the previous version's per-version provider job
        /// registered and still owning the NEMachServiceName endpoint; it refuses to let the new version
        /// reclaim a fixed endpoint name, so the app reaches the dead old listener. The version suffix gives
        /// each build its own endpoint. Must equal NEMachServiceName in SystemExtension/Info.plist, which is
        /// baked from $(APP_GROUP_IDENTIFIER).system.$(MARKETING_VERSION); Bundle.version is that same value.
        public static var systemExtensionMachServiceName: String {
            "\(appGroupID).system.\(Bundle.main.version)"
        }
    #endif

    public static var packetTunnelBundleIDs: [String] {
        if extensionBundleID == systemExtensionBundleID {
            return [extensionBundleID]
        }
        return [extensionBundleID, systemExtensionBundleID]
    }

    public static var fileProviderDomainID: String {
        "\(packageName).workingdir"
    }

    public static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    public static var profileUTType: String {
        "\(packageName).profile"
    }

    public static var backgroundTaskID: String {
        "\(packageName).update_profiles"
    }

    public static var iCloudContainerID: String {
        "iCloud.\(packageName)"
    }

    #if os(macOS) || JAILBREAK
        public static var rootHelperBundleID: String {
            "\(packageName).helper"
        }

        public static var rootHelperMachService: String {
            "\(appGroupID).helper"
        }
    #endif
}
