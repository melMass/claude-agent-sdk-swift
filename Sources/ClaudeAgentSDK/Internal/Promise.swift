import Foundation

/// A value delivered once, awaited by any number of tasks.
final class Promise<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var result: Result<Value, Error>?
        var waiters: [CheckedContinuation<Value, Error>] = []
    }

    private let state = Locked(State())

    var isResolved: Bool { state.withLock { $0.result != nil } }

    func resolve(_ result: Result<Value, Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Error>] in
            guard state.result == nil else { return [] }
            state.result = result
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    func succeed(_ value: Value) { resolve(.success(value)) }
    func fail(_ error: Error) { resolve(.failure(error)) }

    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, Error>? in
                    if let result = state.result { return result }
                    state.waiters.append(continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }
    }
}
