#if SFI_DEV
import Foundation

// A finite sliding window for reproducible Dev workloads. Each input runs once;
// completion order cannot change the order of the recorded probe results.
enum WLTBoundedWorkload {
    enum InvalidLimit: Error { case concurrency }

    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], concurrency: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard (1 ... 16).contains(concurrency) else { throw InvalidLimit.concurrency }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: inputs.count)
            var next = 0
            for _ in 0 ..< min(concurrency, inputs.count) {
                let index = next
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await operation(inputs[index]))
                }
            }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                results[index] = result
                if next < inputs.count {
                    let index = next
                    next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, try await operation(inputs[index]))
                    }
                }
            }
            return results.map { $0! }
        }
    }
}
#endif
