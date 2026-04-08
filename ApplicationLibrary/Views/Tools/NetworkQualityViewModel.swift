import Foundation
import Libbox
import SwiftUI

@MainActor
public final class NetworkQualityViewModel: BaseViewModel {
    @Published public var phase: Int32 = -1
    @Published public var idleLatencyMs: Int32 = 0
    @Published public var downloadCapacity: Int64 = 0
    @Published public var uploadCapacity: Int64 = 0
    @Published public var downloadRPM: Int32 = 0
    @Published public var uploadRPM: Int32 = 0
    @Published public var isRunning = false
    @Published public var configURL: String = LibboxNetworkQualityDefaultConfigURL()
    @Published public var outbounds: [OutboundEntry] = []
    @Published public var selectedOutbound: String = ""

    private var standaloneTest: LibboxNetworkQualityTest?

    public struct OutboundEntry: Identifiable, Hashable {
        public let tag: String
        public let type: String
        public var id: String { tag }
    }

    public var phaseName: String {
        switch phase {
        case 0:
            return "Measuring Idle Latency..."
        case 1:
            return "Measuring Download..."
        case 2:
            return "Measuring Upload..."
        case 3:
            return "Done"
        default:
            return ""
        }
    }

    public func loadOutbounds() {
        Task.detached {
            do {
                let iterator = try LibboxNewStandaloneCommandClient()!.listOutbounds()
                var entries: [OutboundEntry] = []
                while iterator.hasNext() {
                    let info = iterator.next()!
                    entries.append(OutboundEntry(tag: info.tag, type: info.type))
                }
                await MainActor.run { [entries] in
                    self.outbounds = entries
                }
            } catch {
                await MainActor.run {
                    self.alert = AlertState(action: "load outbounds", error: error)
                }
            }
        }
    }

    public func startTest(vpnConnected: Bool) {
        phase = -1
        idleLatencyMs = 0
        downloadCapacity = 0
        uploadCapacity = 0
        downloadRPM = 0
        uploadRPM = 0
        isRunning = true

        let configURL = configURL
        let outboundTag = selectedOutbound

        if vpnConnected {
            Task.detached { [weak self] in
                let handler = TestHandler(self)
                do {
                    try LibboxNewStandaloneCommandClient()!.startNetworkQualityTest(configURL, outboundTag: outboundTag, handler: handler)
                } catch {
                    await MainActor.run {
                        self?.isRunning = false
                        self?.alert = AlertState(action: "network quality test", error: error)
                    }
                }
            }
        } else {
            let test = LibboxNewNetworkQualityTest()!
            standaloneTest = test
            let handler = TestHandler(self)
            test.start(configURL, handler: handler)
        }
    }

    public func cancel() {
        standaloneTest?.cancel()
        standaloneTest = nil
        isRunning = false
    }

    private class TestHandler: NSObject, LibboxNetworkQualityTestHandlerProtocol {
        private weak var viewModel: NetworkQualityViewModel?

        init(_ viewModel: NetworkQualityViewModel?) {
            self.viewModel = viewModel
        }

        func onProgress(_ progress: LibboxNetworkQualityProgress?) {
            guard let progress else { return }
            let phase = progress.phase
            let idleLatencyMs = progress.idleLatencyMs
            let downloadCapacity = progress.downloadCapacity
            let uploadCapacity = progress.uploadCapacity
            let downloadRPM = progress.downloadRPM
            let uploadRPM = progress.uploadRPM
            DispatchQueue.main.async { [self] in
                guard let viewModel else { return }
                viewModel.phase = phase
                viewModel.idleLatencyMs = idleLatencyMs
                viewModel.downloadCapacity = downloadCapacity
                viewModel.uploadCapacity = uploadCapacity
                viewModel.downloadRPM = downloadRPM
                viewModel.uploadRPM = uploadRPM
            }
        }

        func onResult(_ result: LibboxNetworkQualityResult?) {
            guard let result else { return }
            let idleLatencyMs = result.idleLatencyMs
            let downloadCapacity = result.downloadCapacity
            let uploadCapacity = result.uploadCapacity
            let downloadRPM = result.downloadRPM
            let uploadRPM = result.uploadRPM
            DispatchQueue.main.async { [self] in
                guard let viewModel else { return }
                viewModel.phase = 3
                viewModel.idleLatencyMs = idleLatencyMs
                viewModel.downloadCapacity = downloadCapacity
                viewModel.uploadCapacity = uploadCapacity
                viewModel.downloadRPM = downloadRPM
                viewModel.uploadRPM = uploadRPM
                viewModel.isRunning = false
                viewModel.standaloneTest = nil
            }
        }

        func onError(_ message: String?) {
            DispatchQueue.main.async { [self] in
                guard let viewModel else { return }
                viewModel.isRunning = false
                viewModel.standaloneTest = nil
                if let message {
                    viewModel.alert = AlertState(title: "Network Quality Test", content: message)
                }
            }
        }
    }
}
