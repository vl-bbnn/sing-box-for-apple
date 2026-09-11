#if os(iOS) && SFI_DEV
import Foundation

// Used by the actual app transaction, provider owner and durable receipt writer.
enum WLTStopStage: String, CaseIterable {
  case appPrepareEnter = "app_prepare_enter", appPrepareOK = "app_prepare_ok", appPrepareError = "app_prepare_error"
  case appRPCEnter = "app_rpc_enter", appRPCOK = "app_rpc_return_ok", appRPCError = "app_rpc_return_error"
  case appOSStopEnter = "app_os_stop_enter", appOSStopReturn = "app_os_stop_return"
  case providerCloseEnter = "provider_close_enter", providerCoreEnter = "provider_core_close_enter", providerCoreOK = "provider_core_close_ok", providerCoreError = "provider_core_close_error"
  case providerJournalEnter = "provider_journal_enter", providerJournalOK = "provider_journal_ok", providerJournalError = "provider_journal_error"
  case providerSidecarEnter = "provider_sidecar_close_enter", providerSidecarOK = "provider_sidecar_close_return", providerSidecarError = "provider_sidecar_close_error"
  case providerPlatformEnter = "provider_platform_reset_enter", providerPlatformOK = "provider_platform_reset_return", providerPlatformError = "provider_platform_reset_error"
  case providerServerEnter = "provider_server_close_enter", providerServerOK = "provider_server_close_return", providerServerError = "provider_server_close_error"
  case providerDiagnosticsEnter = "provider_diagnostics_close_enter", providerDiagnosticsOK = "provider_diagnostics_close_return", providerDiagnosticsError = "provider_diagnostics_close_error"
  case providerReturnOK = "provider_close_return_ok", providerReturnError = "provider_close_return_error"
}

struct WLTStopOutcome: Codable, Equatable {
  var primaryFailure: String?
  var evidenceFailures: [String] = []
  var cleanupFailures: [String] = []
  var resourcesClosed = false
  var succeeded: Bool { primaryFailure == nil && evidenceFailures.isEmpty && cleanupFailures.isEmpty && resourcesClosed }
}

struct WLTStopReply: Codable, Equatable {
  let lifecycle: UInt64
  let operationID: String
  let outcome: WLTStopOutcome?
  var pending: Bool { outcome == nil }
}

enum WLTStopWaitError: Error { case deadline }

// This is the production lifecycle AND full shutdown orchestration. The provider
// supplies only OS/libbox/journal/receipt boundaries. No caller owns cleanup.
final class WLTStopOrchestrator: @unchecked Sendable {
  struct Dependencies {
    var retainOwner: () -> AnyObject? = { nil }
    var closeCore: () throws -> Void
    var closeJournal: (_ coreClosed: Bool, _ reason: String) throws -> Void
    var closeSidecar: () throws -> Void
    var resetPlatform: () throws -> Void
    var closeServer: () throws -> Void
    var finishDiagnostics: () throws -> Void
    var record: (WLTStopStage, String) -> Bool
  }
  enum AdmissionError: Error { case busy, priorResourcesLive, stopRequested }
  private let condition = NSCondition()
  private let dependencies: Dependencies
  private var generation: UInt64 = 0
  private var transition = false
  private var stopIntent = false
  private var operationID: String?
  private var outcome: WLTStopOutcome?
  private var workerStarted = false
  private var previousTerminal: WLTStopReply?

  init(dependencies: Dependencies) { self.dependencies = dependencies }

  func beginTunnelStart(commandServerAbsent: Bool) throws -> UInt64 {
    condition.lock(); defer { condition.unlock() }
    guard !transition, !workerStarted || outcome != nil else { throw AdmissionError.busy }
    guard commandServerAbsent else { throw AdmissionError.priorResourcesLive }
    if operationID != nil {
      guard outcome?.resourcesClosed == true, commandServerAbsent else { throw AdmissionError.priorResourcesLive }
    } else if generation != 0 {
      throw AdmissionError.priorResourcesLive
    }
    if let operationID, let outcome {
      previousTerminal = WLTStopReply(lifecycle: generation, operationID: operationID, outcome: outcome)
    }
    generation &+= 1
    transition = true; stopIntent = false; operationID = nil; outcome = nil; workerStarted = false
    return generation
  }

  func beginReload() throws -> UInt64 {
    condition.lock(); defer { condition.unlock() }
    guard !stopIntent else { throw AdmissionError.stopRequested }
    guard !transition else { throw AdmissionError.busy }
    transition = true
    return generation
  }

  func finishTransition(_ token: UInt64) {
    condition.lock(); defer { condition.unlock() }
    guard generation == token else { return }
    transition = false
    condition.broadcast()
  }

  func throwIfStopRequested(_ token: UInt64) throws {
    condition.lock(); defer { condition.unlock() }
    guard generation == token, !stopIntent else { throw AdmissionError.stopRequested }
  }

  func request(operationID proposed: String, reason: String) -> WLTStopReply {
    condition.lock()
    if let previousTerminal, previousTerminal.operationID == proposed {
      condition.unlock(); return previousTerminal
    }
    if let operationID {
      let reply = WLTStopReply(lifecycle: generation, operationID: operationID, outcome: outcome)
      condition.unlock(); return reply
    }
    operationID = proposed; stopIntent = true; workerStarted = true
    let token = generation
    let reply = WLTStopReply(lifecycle: token, operationID: proposed, outcome: nil)
    condition.unlock()
    let retainedOwner = dependencies.retainOwner()
    DispatchQueue.global(qos: .utility).async { [self] in
      condition.lock()
      while generation == token && transition { condition.wait() }
      condition.unlock()
      let result = withExtendedLifetime(retainedOwner) { execute(operationID: proposed, reason: reason) }
      condition.lock()
      // Publication is the final operation of the owner. All terminal resource
      // work and receipts have completed before a next start can be admitted.
      if generation == token { outcome = result; condition.broadcast() }
      condition.unlock()
    }
    return reply
  }

  func snapshot() -> WLTStopReply? {
    condition.lock(); defer { condition.unlock() }
    guard let operationID else { return nil }
    return WLTStopReply(lifecycle: generation, operationID: operationID, outcome: outcome)
  }

  func lookup(lifecycle: UInt64, operationID: String) -> WLTStopReply? {
    condition.lock(); defer { condition.unlock() }
    if generation == lifecycle, self.operationID == operationID {
      return WLTStopReply(lifecycle: generation, operationID: operationID, outcome: outcome)
    }
    if let previousTerminal, previousTerminal.lifecycle == lifecycle, previousTerminal.operationID == operationID {
      return previousTerminal
    }
    return nil
  }

  // Monotonic deadline and structured cancellation affect this observer only.
  // Task.sleep is cancellable; it is never swallowed into a spinning waiter.
  func wait(for reply: WLTStopReply, timeout: TimeInterval) async throws -> WLTStopReply {
    try await WLTStopPolling.wait(timeout: timeout) { [self] in
      guard let current = lookup(lifecycle: reply.lifecycle, operationID: reply.operationID) else {
        throw AdmissionError.priorResourcesLive
      }
      return current
    }
  }

  private func execute(operationID: String, reason: String) -> WLTStopOutcome {
    var result = WLTStopOutcome()
    func receipt(_ stage: WLTStopStage) {
      if !dependencies.record(stage, operationID) { result.evidenceFailures.append("receipt:\(stage.rawValue)") }
    }
    func cleanup(_ code: String, enter: WLTStopStage, success: WLTStopStage, failure: WLTStopStage, work: () throws -> Void) -> Bool {
      receipt(enter)
      do { try work(); receipt(success); return true }
      catch { if result.primaryFailure == nil { result.primaryFailure = code }; result.cleanupFailures.append(code); receipt(failure); return false }
    }
    receipt(.providerCloseEnter)
    let coreClosed = cleanup("core_close_failed", enter: .providerCoreEnter, success: .providerCoreOK, failure: .providerCoreError, work: dependencies.closeCore)
    receipt(.providerJournalEnter)
    do { try dependencies.closeJournal(coreClosed, reason); receipt(.providerJournalOK) }
    catch { result.evidenceFailures.append("journal_finalize_failed"); receipt(.providerJournalError) }
    // Evidence errors do not prevent safe cleanup. Failed core/sidecar cleanup
    // retains its dependent resources and ownership, rejecting another start.
    if coreClosed {
      let sidecarClosed = cleanup("sidecar_close_failed", enter: .providerSidecarEnter, success: .providerSidecarOK, failure: .providerSidecarError, work: dependencies.closeSidecar)
      if sidecarClosed {
        let platformClosed = cleanup("platform_reset_failed", enter: .providerPlatformEnter, success: .providerPlatformOK, failure: .providerPlatformError, work: dependencies.resetPlatform)
        if platformClosed {
          let serverClosed = cleanup("server_close_failed", enter: .providerServerEnter, success: .providerServerOK, failure: .providerServerError, work: dependencies.closeServer)
          if serverClosed {
            result.resourcesClosed = cleanup("diagnostics_close_failed", enter: .providerDiagnosticsEnter, success: .providerDiagnosticsOK, failure: .providerDiagnosticsError, work: dependencies.finishDiagnostics)
          }
        }
      }
    }
    receipt(result.succeeded ? .providerReturnOK : .providerReturnError)
    return result
  }
}

// Both the app protocol and OS waiter execute this production polling path.
enum WLTStopPolling {
  static func wait(timeout: TimeInterval, poll: () async throws -> WLTStopReply) async throws -> WLTStopReply {
    let start = DispatchTime.now().uptimeNanoseconds
    let duration = UInt64(max(0, timeout) * 1_000_000_000)
    while true {
      try Task.checkCancellation()
      if DispatchTime.now().uptimeNanoseconds - start >= duration { throw WLTStopWaitError.deadline }
      let reply = try await poll()
      try Task.checkCancellation()
      if DispatchTime.now().uptimeNanoseconds - start >= duration { throw WLTStopWaitError.deadline }
      if !reply.pending { return reply }
      try await Task.sleep(nanoseconds: min(10_000_000, duration - min(duration, DispatchTime.now().uptimeNanoseconds - start)))
    }
  }
}

// Used at the actual sidecar replacement callsite. A failed close must never
// erase the retained handle or invoke the replacement constructor.
enum WLTSidecarReplacement {
  static func perform(close: () -> Bool, start: () throws -> Void) throws {
    guard close() else { throw WLTStopOrchestrator.AdmissionError.priorResourcesLive }
    try start()
  }
}
#endif
