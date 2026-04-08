import Foundation
import Libbox
import SwiftUI

public enum STUNTimeoutOption: Int32, CaseIterable, Identifiable {
    case three = 3
    case five = 5
    case ten = 10

    public var id: Int32 { rawValue }

    public var label: String {
        "\(rawValue)s"
    }
}

@MainActor
public final class STUNTestViewModel: BaseViewModel {
    @Published public var phase: Int32 = -1
    @Published public var externalAddr: String = ""
    @Published public var latencyMs: Int32 = 0
    @Published public var natMapping: Int32 = 0
    @Published public var natFiltering: Int32 = 0
    @Published public var natTypeSupported: Bool = false
    @Published public var isRunning = false
    @Published public var server: String = LibboxSTUNDefaultServer
    @Published public var timeout: STUNTimeoutOption = .three
    @Published public var selectedOutbound: String = ""

    private var standaloneTest: LibboxSTUNTest?
    private var runningTask: Task<Void, Never>?

    public func startTest(vpnConnected: Bool) {
        phase = -1
        externalAddr = ""
        latencyMs = 0
        natMapping = 0
        natFiltering = 0
        natTypeSupported = false
        isRunning = true

        let server = server
        let outboundTag = selectedOutbound
        let timeoutSeconds = timeout.rawValue

        if vpnConnected {
            let handler = TestHandler(self)
            runningTask = Task { [weak self] in
                do {
                    try await Task.detached {
                        try LibboxNewStandaloneCommandClient()!.startSTUNTest(withTimeout: server, outboundTag: outboundTag, timeoutSeconds: timeoutSeconds, handler: handler)
                    }.value
                } catch {
                    guard let self else { return }
                    self.isRunning = false
                    self.alert = AlertState(action: "STUN test", error: error)
                }
                self?.runningTask = nil
            }
        } else {
            let test = LibboxNewSTUNTest()!
            standaloneTest = test
            let handler = TestHandler(self)
            test.start(withTimeout: server, timeoutSeconds: timeoutSeconds, handler: handler)
        }
    }

    public func cancel() {
        runningTask?.cancel()
        runningTask = nil
        standaloneTest?.cancel()
        standaloneTest = nil
        isRunning = false
    }

    private final class TestHandler: NSObject, LibboxSTUNTestHandlerProtocol, @unchecked Sendable {
        private weak var viewModel: STUNTestViewModel?

        init(_ viewModel: STUNTestViewModel?) {
            self.viewModel = viewModel
        }

        func onProgress(_ progress: LibboxSTUNTestProgress?) {
            guard let progress else { return }
            let phase = progress.phase
            let externalAddr = progress.externalAddr
            let latencyMs = progress.latencyMs
            let natMapping = progress.natMapping
            let natFiltering = progress.natFiltering
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.phase = phase
                if !externalAddr.isEmpty {
                    viewModel.externalAddr = externalAddr
                }
                if latencyMs > 0 {
                    viewModel.latencyMs = latencyMs
                }
                viewModel.natMapping = natMapping
                viewModel.natFiltering = natFiltering
            }
        }

        func onResult(_ result: LibboxSTUNTestResult?) {
            guard let result else { return }
            let externalAddr = result.externalAddr
            let latencyMs = result.latencyMs
            let natMapping = result.natMapping
            let natFiltering = result.natFiltering
            let natTypeSupported = result.natTypeSupported
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.phase = 3
                viewModel.externalAddr = externalAddr
                viewModel.latencyMs = latencyMs
                viewModel.natMapping = natMapping
                viewModel.natFiltering = natFiltering
                viewModel.natTypeSupported = natTypeSupported
                viewModel.isRunning = false
                viewModel.runningTask = nil
                viewModel.standaloneTest = nil
            }
        }

        func onError(_ message: String?) {
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.isRunning = false
                viewModel.runningTask = nil
                viewModel.standaloneTest = nil
                if let message {
                    viewModel.alert = AlertState(errorMessage: message)
                }
            }
        }
    }
}
