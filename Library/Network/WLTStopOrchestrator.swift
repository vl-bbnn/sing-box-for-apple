#if os(iOS) && SFI_DEV
  import Foundation

  /// Owns exactly one potentially blocking stop operation. Callers only observe
  /// snapshots; a deadline never changes the owner or publishes completion.
  final class WLTStopOrchestrator {
    enum Result: Equatable { case pending, succeeded, failed }
    struct Snapshot: Equatable {
      let operationID: String
      let result: Result
      let ownerStarted: Bool
    }

    private let lock = NSLock()
    private var operationID: String?
    private var result: Result = .pending
    private var ownerStarted = false

    func admit(operationID proposed: String, work: @escaping () -> Bool) -> Snapshot {
      lock.lock()
      if let operationID {
        let snapshot = Snapshot(operationID: operationID, result: result, ownerStarted: ownerStarted)
        lock.unlock()
        return snapshot
      }
      operationID = proposed
      ownerStarted = true
      let snapshot = Snapshot(operationID: proposed, result: .pending, ownerStarted: true)
      lock.unlock()
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let succeeded = work()
        self?.complete(succeeded: succeeded)
      }
      return snapshot
    }

    func snapshot() -> Snapshot? {
      lock.lock(); defer { lock.unlock() }
      guard let operationID else { return nil }
      return Snapshot(operationID: operationID, result: result, ownerStarted: ownerStarted)
    }

    private func complete(succeeded: Bool) {
      lock.lock(); defer { lock.unlock() }
      guard ownerStarted, result == .pending else { return }
      result = succeeded ? .succeeded : .failed
    }
  }
#endif
