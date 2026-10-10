import Foundation

/// The queue between the frame reader and the code reading messages. Unlike
/// an `AsyncStream`, it can be read by one iterator after another (each
/// `receiveMessages()` / `receiveResponse()` call picks up where the last
/// stopped), as the Python SDK's shared message stream can.
final class MessageChannel: @unchecked Sendable {
    private struct State {
        var buffer: [Message] = []
        var ended = false
        var failure: Error?
        var waiter: (id: UInt64, continuation: CheckedContinuation<Message?, Error>)?
        var nextWaiter: UInt64 = 0
    }

    private let state = Locked(State())

    func push(_ message: Message) {
        let waiter = state.withLock { state -> CheckedContinuation<Message?, Error>? in
            guard !state.ended else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter.continuation
            }
            state.buffer.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }

    /// Ends the channel; readers get the buffered messages, then `error` (or the end).
    func finish(throwing error: Error? = nil) {
        let waiter = state.withLock { state -> CheckedContinuation<Message?, Error>? in
            guard !state.ended else { return nil }
            state.ended = true
            state.failure = error
            defer { state.waiter = nil }
            return state.waiter?.continuation
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }

    var isFinished: Bool { state.withLock { $0.ended && $0.buffer.isEmpty } }

    /// The next message, or nil at the end. The error that ended the channel
    /// is thrown once, to the first reader that reaches it.
    func next() async throws -> Message? {
        let id = state.withLock { state -> UInt64 in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Message?, Error>) in
                enum Outcome { case message(Message), end, failure(Error), wait }
                let outcome = state.withLock { state -> Outcome in
                    if !state.buffer.isEmpty { return .message(state.buffer.removeFirst()) }
                    if state.ended {
                        if let failure = state.failure {
                            state.failure = nil
                            return .failure(failure)
                        }
                        return .end
                    }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.waiter != nil { return .failure(CLIConnectionError("Messages are already being read by another task")) }
                    state.waiter = (id, continuation)
                    return .wait
                }
                switch outcome {
                case let .message(message): continuation.resume(returning: message)
                case .end: continuation.resume(returning: nil)
                case let .failure(error): continuation.resume(throwing: error)
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Message?, Error>? in
                guard let waiter = state.waiter, waiter.id == id else { return nil }
                state.waiter = nil
                return waiter.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// Messages from a session, read in order. Iterating again continues where
/// the previous iteration stopped.
public struct MessageStream: AsyncSequence, Sendable {
    public typealias Element = Message

    let channel: MessageChannel
    /// Stops after yielding the first ``ResultMessage``.
    let stopsAtResult: Bool

    public struct AsyncIterator: AsyncIteratorProtocol {
        let channel: MessageChannel
        let stopsAtResult: Bool
        var done = false

        public mutating func next() async throws -> Message? {
            guard !done, let message = try await channel.next() else { return nil }
            if stopsAtResult, case .result = message { done = true }
            return message
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(channel: channel, stopsAtResult: stopsAtResult)
    }
}
