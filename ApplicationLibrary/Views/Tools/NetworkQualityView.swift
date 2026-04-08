import Library
import Libbox
import SwiftUI

@MainActor
public struct NetworkQualityView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = NetworkQualityViewModel()

    public init() {}

    private var vpnConnected: Bool {
        environments.extensionProfile?.status.isConnectedStrict == true
    }

    public var body: some View {
        FormView {
            Section("Configuration") {
                #if os(tvOS)
                    FormTextItem("Config URL", "link") {
                        Text(viewModel.configURL)
                    }
                #else
                    TextField("Config URL", text: $viewModel.configURL)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                #endif
            }

            if vpnConnected {
                Section("Outbound") {
                    Picker("Outbound", selection: $viewModel.selectedOutbound) {
                        Text("Default").tag("")
                        ForEach(viewModel.outbounds) { outbound in
                            Text("\(outbound.tag) (\(LibboxProxyDisplayType(outbound.type)))").tag(outbound.tag)
                        }
                    }
                }
            }

            Section {
                if viewModel.isRunning {
                    FormButton(role: .destructive) {
                        viewModel.cancel()
                    } label: {
                        Label("Cancel Test", systemImage: "stop.fill")
                    }
                } else {
                    FormButton {
                        viewModel.startTest(vpnConnected: vpnConnected)
                    } label: {
                        Label("Start Test", systemImage: "play.fill")
                    }
                }
            }

            if viewModel.phase >= 0 {
                Section("Results") {
                    FormTextItem("Phase", "gauge.with.dots.needle.33percent") {
                        Text(viewModel.phaseName)
                    }
                    FormTextItem("Idle Latency", "timer") {
                        Text(viewModel.idleLatencyMs > 0 ? "\(viewModel.idleLatencyMs) ms" : "-")
                    }
                    FormTextItem("Download", "arrow.down.circle") {
                        Text(viewModel.downloadCapacity > 0 ? LibboxFormatBitrate(viewModel.downloadCapacity) : "-")
                    }
                    FormTextItem("Upload", "arrow.up.circle") {
                        Text(viewModel.uploadCapacity > 0 ? LibboxFormatBitrate(viewModel.uploadCapacity) : "-")
                    }
                    FormTextItem("Download RPM", "arrow.down.to.line") {
                        Text(viewModel.downloadRPM > 0 ? "\(viewModel.downloadRPM)" : "-")
                    }
                    FormTextItem("Upload RPM", "arrow.up.to.line") {
                        Text(viewModel.uploadRPM > 0 ? "\(viewModel.uploadRPM)" : "-")
                    }
                }
            }
        }
        .navigationTitle("Network Quality")
        .alert($viewModel.alert)
        .onAppear {
            if vpnConnected {
                viewModel.loadOutbounds()
            }
        }
        .onDisappear {
            if viewModel.isRunning {
                viewModel.cancel()
            }
        }
    }
}
