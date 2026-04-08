import Libbox
import Library
import SwiftUI

@MainActor
public struct STUNTestView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = STUNTestViewModel()

    public init() {}

    @ViewBuilder
    private func resultValue(_ value: String?, active: Bool) -> some View {
        if let value {
            HStack(spacing: 6) {
                if viewModel.isRunning, active {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(value)
            }
        } else if viewModel.isRunning, active {
            ProgressView()
                .controlSize(.small)
        } else {
            Text("-")
        }
    }

    public var body: some View {
        FormView {
            Section("Configuration") {
                #if os(tvOS)
                    FormTextItem("Server", "server.rack") {
                        Text(viewModel.server)
                    }
                #else
                    FormItem("Server") {
                        TextField("STUN Server", text: $viewModel.server)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                    }
                #endif
                Picker("Timeout", selection: $viewModel.timeout) {
                    ForEach(STUNTimeoutOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(viewModel.isRunning)
                if let profile = environments.extensionProfile {
                    OutboundSection(profile: profile, viewModel: viewModel)
                }
            }

            Section {
                if viewModel.isRunning {
                    FormButton {
                        viewModel.cancel()
                    } label: {
                        Label("Cancel Test", systemImage: "stop.fill")
                    }
                } else {
                    FormButton {
                        viewModel.startTest(vpnConnected: environments.extensionProfile?.status.isConnectedStrict == true)
                    } label: {
                        Label("Start Test", systemImage: "play.fill")
                    }
                }
            }

            if viewModel.phase >= 0 {
                Section("Results") {
                    FormTextItem("External Address", "network") {
                        resultValue(viewModel.externalAddr.isEmpty ? nil : viewModel.externalAddr, active: viewModel.phase == 0)
                    }
                    FormTextItem("Latency", "timer") {
                        resultValue(viewModel.latencyMs > 0 ? "\(viewModel.latencyMs) ms" : nil, active: viewModel.phase == 0)
                    }
                    if viewModel.phase == 3, !viewModel.natTypeSupported {
                        FormTextItem("NAT Type Detection", "exclamationmark.triangle") {
                            Text("Not supported by server")
                        }
                    } else {
                        FormTextItem("NAT Mapping", "arrow.left.arrow.right") {
                            resultValue(viewModel.natMapping > 0 ? LibboxFormatNATMapping(viewModel.natMapping) : nil, active: viewModel.phase == 1)
                        }
                        FormTextItem("NAT Filtering", "line.3.horizontal.decrease") {
                            resultValue(viewModel.natFiltering > 0 ? LibboxFormatNATFiltering(viewModel.natFiltering) : nil, active: viewModel.phase == 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("STUN Test")
        .alert($viewModel.alert)
        .onDisappear {
            if viewModel.isRunning {
                viewModel.cancel()
            }
        }
    }
}

private struct OutboundSection: View {
    @ObservedObject var profile: ExtensionProfile
    @ObservedObject var viewModel: STUNTestViewModel

    var body: some View {
        Group {
            if profile.status.isConnectedStrict {
                FormNavigationLink {
                    OutboundPickerView(selectedOutbound: $viewModel.selectedOutbound)
                } label: {
                    HStack {
                        Text("Outbound")
                        Spacer()
                        Text(viewModel.selectedOutbound.isEmpty ? String(localized: "Default") : viewModel.selectedOutbound)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .onChangeCompat(of: profile.status) { status in
            if !status.isConnectedStrict {
                if viewModel.isRunning {
                    viewModel.cancel()
                }
                viewModel.selectedOutbound = ""
            }
        }
    }
}
