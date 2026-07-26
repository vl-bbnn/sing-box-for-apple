import ApplicationLibrary
import Libbox
import Library
import NetworkExtension
import SwiftUI

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environments: ExtensionEnvironments

    @State private var selection = NavigationPage.dashboard
    @State private var importProfile: LibboxProfileContent?
    @State private var importRemoteProfile: LibboxImportRemoteProfile?
    @State private var alert: AlertState?
    @State private var showGroups = false
    @State private var showConnections = false
    @State private var buttonState = ButtonVisibilityState()
    @State private var deviceScenarioAutostartAttempted = false

    private let profileEditor: (Binding<String>, Bool) -> AnyView = { text, isEditable in
        AnyView(ProfileEditorWrapperView(text: text, isEditable: isEditable))
    }

    private var shouldShowBottomAccessory: Bool {
        guard !environments.extensionProfileLoading else {
            return false
        }
        guard !environments.emptyProfiles else {
            return false
        }
        guard environments.extensionProfile != nil else {
            return false
        }
        return true
    }

    @ViewBuilder
    private var tabViewContent: some View {
        if shouldShowBottomAccessory {
            if #available(iOS 26.0, *), !Variant.debugNoIOS26 {
                baseTabView
                    .tabViewBottomAccessory {
                        bottomAccessoryContent
                    }
            } else {
                legacyTabView
            }
        } else {
            baseTabView
        }
    }

    var body: some View {
        if Variant.screenshotMode {
            mainBody.preferredColorScheme(.dark)
        } else {
            mainBody
        }
    }

    private var baseTabView: some View {
        tabView(showsBottomAccessory: false)
    }

    private var legacyTabView: some View {
        tabView(showsBottomAccessory: shouldShowBottomAccessory)
    }

    private func tabView(showsBottomAccessory: Bool) -> some View {
        TabView(selection: $selection) {
            ForEach(NavigationPage.allCases, id: \.self) { page in
                NavigationStackCompat {
                    tabContent(for: page, showsBottomAccessory: showsBottomAccessory)
                }
                .tag(page)
                .tabItem { page.label }
            }
        }
    }

    @ViewBuilder
    private func tabContent(for page: NavigationPage, showsBottomAccessory: Bool) -> some View {
        if showsBottomAccessory {
            let content = page.contentView
                .navigationTitle(page.title)
                .tabViewBottomAccessoryCompat(useSystemAccessory: false) {
                    bottomAccessoryContent
                }
            if page == .logs {
                tabBarBackgroundIfAvailable(
                    content
                        .navigationBarTitleDisplayMode(.inline)
                )
            } else {
                tabBarBackgroundIfAvailable(content)
            }
        } else {
            let content = page.contentView
                .navigationTitle(page.title)
            if page == .logs {
                content
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                content
            }
        }
    }

    private func tabBarBackgroundIfAvailable(_ content: some View) -> some View {
        content
    }

    private var bottomAccessoryContent: some View {
        HStack(spacing: 12) {
            if let profile = environments.extensionProfile {
                StatusText(profile: profile)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            NavigationButtonsView(
                showGroupsButton: buttonState.showGroupsButton,
                showConnectionsButton: buttonState.showConnectionsButton,
                groupsCount: buttonState.groupsCount,
                connectionsCount: buttonState.connectionsCount,
                onGroupsTap: { showGroups = true },
                onConnectionsTap: { showConnections = true }
            )
            Divider()
            StartStopButton(showsRuntimeDuration: true)
        }
        .padding(.horizontal)
        .tint(.primary)
    }

    private var mainBody: some View {
        Group {
            tabViewContent
                .onAppear {
                    updateButtonVisibility()
                }
                .onReceive(environments.commandClient.$groups) { _ in
                    Task { @MainActor in updateButtonVisibility() }
                }
                .onReceive(environments.commandClient.$connections) { _ in
                    Task { @MainActor in updateButtonVisibility() }
                }
                .onReceive(environments.commandClient.$hasAnyConnection) { _ in
                    Task { @MainActor in updateButtonVisibility() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
                    Task { @MainActor in updateButtonVisibility() }
                }
                .onReceive(environments.$extensionProfile) { _ in
                    Task { @MainActor in
                        updateButtonVisibility()
                        scheduleDeviceScenarioAutostart()
                    }
                }
                .onReceive(environments.$emptyProfiles) { _ in
                    Task { @MainActor in updateButtonVisibility() }
                }
                .sheet(isPresented: $showGroups) {
                    GroupsSheetContent()
                }
                .sheet(isPresented: $showConnections) {
                    ConnectionsSheetContent()
                }
        }
        .onAppear {
            environments.postReload()
            scheduleDeviceScenarioAutostart()
        }
        .alert($alert)
        .globalChecks()
        .onChangeCompat(of: scenePhase) { newValue in
            if newValue == .active {
                environments.postReload()
                scheduleDeviceScenarioAutostart()
                scheduleDeviceScenarioLogExport()
            }
        }
        .onChangeCompat(of: selection) { newValue in
            if newValue == .logs {
                environments.connect()
            }
        }
        .environment(\.selection, $selection)
        .environment(\.importProfile, $importProfile)
        .environment(\.importRemoteProfile, $importRemoteProfile)
        .environment(\.profileEditor, profileEditor)
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .onOpenURL(perform: openURL)
    }

    private func updateButtonVisibility() {
        buttonState.update(
            profile: environments.extensionProfile,
            commandClient: environments.commandClient
        )
    }

    private func scheduleDeviceScenarioLogExport() {
        guard ProcessInfo.processInfo.environment["WLT_DEVICE_SCENARIO"] == "1" else { return }
        // Do not touch the command client during initial app launch: XCTest
        // must finish establishing automation before any extension IPC starts.
        guard environments.extensionProfile?.status.isConnected == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard environments.extensionProfile?.status.isConnected == true else { return }
            environments.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let text = environments.commandClient.logList
                    .map(\.message)
                    .joined(separator: "\n")
                let url = FilePath.cacheDirectory.appendingPathComponent("wlt-device-service.log")
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func scheduleDeviceScenarioAutostart() {
        #if os(iOS) && SFI_DEV
            guard ProcessInfo.processInfo.environment["WLT_DEVICE_AUTOSTART"] == "1" else {
                return
            }
            guard !deviceScenarioAutostartAttempted else { return }
            guard let profile = environments.extensionProfile else { return }
            deviceScenarioAutostartAttempted = true
            NSLog("WLT_DEVICE_AUTOSTART stage=begin")
            Task { @MainActor in
                do {
                    let selectedProfileID = await SharedPreferences.selectedProfileID.get()
                    if let selectedProfile = try await ProfileManager.get(selectedProfileID),
                       selectedProfile.type == .remote
                    {
                        NSLog("WLT_DEVICE_AUTOSTART stage=remote_profile_update_begin")
                        try await selectedProfile.updateRemoteProfile()
                        NSLog("WLT_DEVICE_AUTOSTART stage=remote_profile_update_done")
                    }
                    if profile.status.isConnected {
                        NSLog("WLT_DEVICE_AUTOSTART stage=already_connected")
                        scheduleDeviceScenarioLogExport()
                        return
                    }
                    try await profile.start()
                    NSLog("WLT_DEVICE_AUTOSTART stage=start_returned")
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    scheduleDeviceScenarioLogExport()
                } catch {
                    NSLog(
                        "WLT_DEVICE_AUTOSTART stage=failed error=%@",
                        error.localizedDescription
                    )
                }
            }
        #endif
    }

    private struct StatusText: View {
        @ObservedObject var profile: ExtensionProfile

        var body: some View {
            statusText
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("wlt.connection.status")
        }

        private var statusText: Text {
            switch profile.status {
            case .disconnected:
                return Text("Stopped")
            case .connecting:
                return Text("Starting")
            case .connected:
                return Text("Started")
            case .reasserting:
                return Text("Reasserting")
            case .disconnecting:
                return Text("Stopping")
            default:
                return Text("Unknown")
                    .foregroundColor(.red)
            }
        }
    }

    private func openURL(url: URL) {
        if url.host == "import-remote-profile" {
            var error: NSError?
            importRemoteProfile = LibboxParseRemoteProfileImportLink(url.absoluteString, &error)
            if let error {
                alert = AlertState(action: "parse remote profile import link", error: error)
            }
        } else if url.pathExtension == "bpf" {
            do {
                importProfile = try url.withSecurityScopedAccess {
                    try .from(Data(contentsOf: url))
                }
            } catch {
                alert = AlertState(action: "import profile from URL", error: error)
            }
        } else {
            alert = AlertState(errorMessage: String(localized: "Handled unknown URL \(url.absoluteString)"))
        }
    }
}
