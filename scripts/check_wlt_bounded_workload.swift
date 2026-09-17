import Foundation

actor WorkloadRecorder {
    var active = 0
    var peak = 0
    var started: [Int] = []
    func begin(_ value: Int) {
        active += 1
        peak = max(peak, active)
        started.append(value)
    }
    func end() { active -= 1 }
    func snapshot() -> (Int, Int, [Int]) { (active, peak, started) }
}

@main struct CheckBoundedWorkload {
    static func main() async throws {
        for width in [1, 4, 16] {
            let recorder = WorkloadRecorder()
            let results = try await WLTBoundedWorkload.run(Array(0 ..< 32), concurrency: width) { value in
                await recorder.begin(value)
                // Deliberately finish later inputs first.
                try await Task.sleep(nanoseconds: UInt64(4 - value % 4) * 10_000_000)
                await recorder.end()
                return value * 2
            }
            let (active, peak, started) = await recorder.snapshot()
            precondition(results == Array(0 ..< 32).map { $0 * 2 })
            precondition(active == 0 && peak == width)
            precondition(started.sorted() == Array(0 ..< 32))
        }
        for width in [0, -1, 17] {
            do {
                _ = try await WLTBoundedWorkload.run([1], concurrency: width) { $0 }
                fatalError("invalid concurrency accepted")
            } catch WLTBoundedWorkload.InvalidLimit.concurrency {}
        }
        let empty = try await WLTBoundedWorkload.run([Int](), concurrency: 4) { $0 }
        precondition(empty.isEmpty)
        let recorder = WorkloadRecorder()
        let task = Task {
            try await WLTBoundedWorkload.run(Array(0 ..< 32), concurrency: 4) { value in
                await recorder.begin(value)
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    await recorder.end()
                    return value
                } catch {
                    await recorder.end()
                    throw error
                }
            }
        }
        // Wait only for the initial window to begin; cancellation must join it
        // and must not admit the remaining 28 requests.
        for _ in 0 ..< 100 {
            if await recorder.snapshot().2.count == 4 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { _ = try await task.value; fatalError("cancellation swallowed") }
        catch is CancellationError {}
        let (active, peak, started) = await recorder.snapshot()
        precondition(active == 0 && peak == 4 && started.count == 4)
        print("PASS: bounded overlap, input order, exactly once, sequential compatibility, limits, cancellation")
    }
}
