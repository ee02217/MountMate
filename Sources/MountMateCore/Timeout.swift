import Foundation

// MARK: - Bounding blocking work

/// Runs a **synchronous, blocking** call on a dedicated OS thread and abandons it if it
/// exceeds `timeout`. Returns the call's value, or `nil` if the deadline won.
///
/// This is the load-bearing primitive of this package, and the reason it cannot be
/// `withTimeout`:
///
/// Cooperative cancellation can only abandon a task that reaches a suspension point.
/// `NetFSMountURLSync`, `Darwin.unmount` and `statfs` are synchronous C calls that can
/// park inside the kernel indefinitely — against a dead server there is no suspension
/// point at which they could ever observe `Task.isCancelled`. Wrapping such a call in
/// an `async` function does not make it abandonable; it only makes it *look* abandonable.
/// `withThrowingTaskGroup` in particular cannot help: when one child throws, the group
/// cancels the others **and then awaits them**, so a group whose child is stuck in a
/// syscall stays stuck for as long as the syscall does, deadline or no deadline.
///
/// So the blocking call gets its own disposable pthread and we race it against a timer
/// through a continuation that only ever resumes once. If the timer wins we return
/// `nil` immediately: the caller is released on schedule and the thread is abandoned.
///
/// The cost of a timeout is therefore one stranded pthread rather than a stalled caller
/// — and, critically, rather than a slot in Swift's small cooperative executor pool,
/// which would degrade the whole process's concurrency. Callers that probe repeatedly
/// must not strand a thread per probe: see `WedgedPathRegistry`, which short-circuits
/// paths already known to hang so the strand happens once, not once per health check.
public func runBlocking<T: Sendable>(
    timeout: Duration,
    _ work: @escaping @Sendable () -> T
) async -> T? {
    await withCheckedContinuation { continuation in
        let race = ResumeOnce<T?>(continuation)
        let worker = Thread {
            race.finish(work())
        }
        worker.name = "MountMateCore.runBlocking"
        worker.stackSize = 512 * 1024
        worker.start()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .nanoseconds(timeout.clampedNanoseconds)
        ) {
            race.finish(nil)
        }
    }
}

/// `runBlocking` that reports the deadline as a `MountFailure` instead of `nil`.
public func withBlockingTimeout<T: Sendable>(
    _ timeout: Duration,
    _ work: @escaping @Sendable () -> T
) async throws -> T {
    guard let value = await runBlocking(timeout: timeout, work) else {
        throw MountFailure(reason: .timedOut)
    }
    return value
}

// MARK: - Bounding async work

/// Runs `operation`, abandoning it if it exceeds `duration`.
///
/// This exists as insurance, not as the primary defence. With `kNAUIOptionNoUI` there
/// should be no dialog to block on — but the shell implementation this replaces lost
/// 7h40m to a blocking mount call, so every attempt gets a deadline anyway.
///
/// "Abandon" is meant literally, and is the difference from the obvious task-group
/// implementation: on timeout we resume the caller and **do not wait** for the
/// operation task. A task group would cancel the operation and then await it, which
/// bounds the wall clock only for an operation that actually honours cancellation. The
/// whole point of a deadline here is the case where it does not. Any blocking call
/// underneath is still expected to route through `runBlocking` so it terminates on its
/// own; this layer guarantees only that *the caller* is released on time.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let controller = TimeoutController<T>()
    let outcome: TimeoutOutcome<T> = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            controller.start(continuation, duration: duration, operation: operation)
        }
    } onCancel: {
        controller.cancel()
    }

    switch outcome {
    case .value(let value): return value
    case .failure(let box): throw box.error
    case .timedOut: throw MountFailure(reason: .timedOut)
    case .cancelled: throw CancellationError()
    }
}

private enum TimeoutOutcome<T: Sendable>: Sendable {
    case value(T)
    case failure(ErrorBox)
    case timedOut
    case cancelled
}

/// Owns the three-way race inside `withTimeout`: the operation, the deadline, and
/// cancellation of the calling task.
///
/// The unstructured tasks are `detached` deliberately. `withTimeout` is called from
/// inside `MountEngine`'s actor, and a task that inherited that isolation would run
/// the operation *on the engine* — so an operation that never suspends would jam the
/// actor and the deadline would buy nothing. Detaching costs the automatic inheritance
/// of cancellation, which is why cancellation is wired up by hand here.
private final class TimeoutController<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var race: ResumeOnce<TimeoutOutcome<T>>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancelRequested = false

    func start(
        _ continuation: CheckedContinuation<TimeoutOutcome<T>, Never>,
        duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) {
        let race = ResumeOnce(continuation)

        lock.lock()
        // `onCancel` can fire before the body ever runs, if the caller was already
        // cancelled on entry.
        if cancelRequested {
            lock.unlock()
            race.finish(.cancelled)
            return
        }
        self.race = race
        lock.unlock()

        let work = Task.detached {
            do {
                race.finish(.value(try await operation()))
            } catch is CancellationError {
                race.finish(.cancelled)
            } catch {
                race.finish(.failure(ErrorBox(error)))
            }
        }

        let timer = Task.detached {
            do {
                try await Task.sleep(for: duration)
            } catch {
                return  // the operation won; nothing to do
            }
            race.finish(.timedOut)
            // Still ask: an operation that *is* cooperative should stop doing work
            // even though we are no longer waiting for it.
            work.cancel()
        }

        lock.lock()
        self.work = work
        self.timer = timer
        let alreadyCancelled = cancelRequested
        lock.unlock()

        if alreadyCancelled {
            work.cancel()
            timer.cancel()
        }

        // Cancel the sleeper the moment the operation wins, rather than leaving a
        // timer pending for the full duration on every successful call.
        race.onFinish { timer.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let race = self.race
        let work = self.work
        let timer = self.timer
        lock.unlock()

        work?.cancel()
        timer?.cancel()
        race?.finish(.cancelled)
    }
}

/// Carries a thrown error across the race. `any Error` is not `Sendable`, but exactly
/// one racer ever reads this and only after the hand-off, so the box is safe.
private struct ErrorBox: @unchecked Sendable {
    let error: any Error
    init(_ error: any Error) { self.error = error }
}

// MARK: - Racing primitive

/// Resumes a `CheckedContinuation` exactly once, whichever racer — the worker
/// finishing or the deadline firing — gets there first. Resuming a
/// `CheckedContinuation` twice is a hard crash, so double-resume must be
/// structurally impossible, not merely unlikely.
///
/// One implementation, shared by every deadline in this package.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var onFinishHandler: (@Sendable () -> Void)?
    private var finished = false

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Runs `handler` when (or immediately, if already) the race is decided. Used to
    /// tear down the losing racer.
    func onFinish(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            handler()
            return
        }
        onFinishHandler = handler
        lock.unlock()
    }

    func finish(_ value: Value) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        finished = true
        let handler = onFinishHandler
        onFinishHandler = nil
        lock.unlock()

        continuation.resume(returning: value)
        handler?()
    }
}

extension Duration {
    /// Nanoseconds for `DispatchQueue.asyncAfter`, clamped into `Int` and never
    /// negative — a negative deadline would fire the timeout before the worker even
    /// starts.
    var clampedNanoseconds: Int {
        let (seconds, attoseconds) = components
        let nanoseconds = Double(seconds) * 1_000_000_000 + Double(attoseconds) * 1e-9
        if nanoseconds <= 0 { return 0 }
        if nanoseconds >= Double(Int.max) { return Int.max }
        return Int(nanoseconds)
    }
}
