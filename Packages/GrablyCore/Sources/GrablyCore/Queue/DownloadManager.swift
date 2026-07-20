import Foundation

/// An observable change published by ``DownloadManager``.
public enum DownloadManagerEvent: Sendable, Equatable {
    /// A task moved to a new lifecycle state.
    case stateChanged(UUID, DownloadState)
    /// A running task reported a progress snapshot.
    case progress(UUID, DownloadProgress)
}

/// An atomic, point-in-time view of one tracked task, for a late subscriber that
/// needs to reconstruct current state without having observed the event stream
/// from the start.
public struct DownloadTaskSnapshot: Sendable, Equatable {
    public let id: UUID
    public let state: DownloadState
    public let progress: DownloadProgress

    public init(id: UUID, state: DownloadState, progress: DownloadProgress) {
        self.id = id
        self.state = state
        self.progress = progress
    }
}

/// Coordinates a queue of downloads, enforcing a concurrency limit and publishing
/// task state changes and progress through an ``AsyncStream``.
///
/// Actor-isolated so the queue, the running-task table, and the subscriber list
/// are all mutated race-free. The MVP default (`maxConcurrent == 1`) runs a strict
/// serial queue.
public actor DownloadManager {
    private let client: any MediaDownloading
    private let maxConcurrent: Int

    /// Requests keyed by id, retained while a task is queued or running.
    private var requests: [UUID: DownloadRequest] = [:]
    /// Latest known state per task.
    private var states: [UUID: DownloadState] = [:]
    /// Latest known progress per task (retained alongside state for snapshots).
    private var progresses: [UUID: DownloadProgress] = [:]
    /// Ids awaiting a free slot, in FIFO order.
    private var pending: [UUID] = []
    /// Currently executing tasks, keyed by id.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Ids that have reached a terminal state, oldest first — used to cap how much
    /// finished history is retained so `states`/`progresses` cannot grow forever.
    private var terminalOrder: [UUID] = []
    /// Live event-stream continuations, keyed by an opaque subscription token.
    private var subscribers: [UUID: AsyncStream<DownloadManagerEvent>.Continuation] = [:]

    /// Upper bound on retained terminal (completed/failed/cancelled) task records.
    /// The UI keeps its own copy of finished rows, so evicting the oldest here only
    /// affects late `snapshot()`/`state(of:)` queries for long-finished tasks.
    private let terminalHistoryLimit: Int

    public init(
        client: some MediaDownloading,
        maxConcurrent: Int = 1,
        terminalHistoryLimit: Int = 200
    ) {
        self.client = client
        self.maxConcurrent = max(1, maxConcurrent)
        self.terminalHistoryLimit = max(1, terminalHistoryLimit)
    }

    // MARK: - Public API

    /// Enqueue a request. Returns its id (the request's own id). Starts it
    /// immediately if a slot is free.
    @discardableResult
    public func enqueue(_ request: DownloadRequest) -> UUID {
        let id = request.id
        // Guard against a duplicate enqueue of an id that is already active: never
        // reset a running task back to `.queued` or add a second pending entry.
        // (A UI "retry" of a finished task re-enqueues the same id, which is fine —
        // that id is neither running nor pending here.)
        guard running[id] == nil, !pending.contains(id) else { return id }

        // Re-activating a previously finished id: drop its stale terminal record so
        // history bookkeeping stays accurate.
        terminalOrder.removeAll { $0 == id }
        requests[id] = request
        progresses[id] = .zero
        setState(id, .queued)
        pending.append(id)
        startNext()
        return id
    }

    /// Cancel a task. A running task is cancelled cooperatively (its process group
    /// is torn down); a still-queued task is removed and marked cancelled at once.
    public func cancel(_ id: UUID) {
        if let task = running[id] {
            // The perform() catch will observe CancellationError, publish
            // .cancelled and pump the queue.
            task.cancel()
            return
        }
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            setState(id, .cancelled)
            requests[id] = nil
        }
    }

    /// A stream of state/progress events. Multiple concurrent subscribers are
    /// supported; each receives every event emitted after it subscribed.
    public func events() -> AsyncStream<DownloadManagerEvent> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            // Runs synchronously on the actor during construction.
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
    }

    /// The last known state of a task (nil if never enqueued). Convenience for
    /// callers/tests that prefer polling over the event stream.
    public func state(of id: UUID) -> DownloadState? {
        states[id]
    }

    /// An atomic snapshot of every currently tracked task (id, latest state, latest
    /// progress). A subscriber that calls ``events()`` after tasks already started
    /// can seed its view from this so it does not miss earlier state/progress.
    ///
    /// Because ``DownloadManager`` is an actor, the snapshot is consistent: no event
    /// can interleave between reading the state and progress tables.
    public func snapshot() -> [DownloadTaskSnapshot] {
        states.map { id, state in
            DownloadTaskSnapshot(
                id: id, state: state, progress: progresses[id] ?? .zero
            )
        }
    }

    // MARK: - Queue engine

    private func startNext() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let request = requests[id] else { continue }
            setState(id, .running)
            let task = Task { [weak self] in
                guard let self else { return }
                await self.perform(id: id, request: request)
            }
            running[id] = task
        }
    }

    /// A single progress/phase signal, funneled through one ordered stream so the
    /// UI observes callbacks in exactly the order yt-dlp emitted them.
    private enum DownloadSignal: Sendable {
        case progress(DownloadProgress)
        case phase(String)
    }

    private func perform(id: UUID, request: DownloadRequest) async {
        // yt-dlp's callbacks fire synchronously from the parser and can arrive in
        // rapid bursts (e.g. 0.1 → 0.5 → 0.9). Funneling them through one
        // FIFO-buffered AsyncStream with a single consumer guarantees they reach
        // the actor — and thus the UI — in emission order. Spawning one detached
        // `Task {}` per callback (the previous approach) gave the runtime no
        // ordering guarantee, so intermediate snapshots could be reordered and the
        // progress bar appeared to jump only between its extremes.
        let (signals, continuation) = AsyncStream<DownloadSignal>.makeStream(
            bufferingPolicy: .unbounded
        )
        let progressHandler: @Sendable (DownloadProgress) -> Void = { snapshot in
            continuation.yield(.progress(snapshot))
        }
        let phaseHandler: @Sendable (String) -> Void = { label in
            continuation.yield(.phase(label))
        }

        // Ordered consumer: pumps each buffered signal into the actor in turn.
        let pump = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                switch signal {
                case let .progress(snapshot): await self.ingestProgress(id: id, snapshot)
                case let .phase(label): await self.ingestPhase(id: id, label)
                }
            }
        }

        let finalState: DownloadState
        do {
            let url = try await client.download(
                request, progress: progressHandler, phase: phaseHandler
            )
            finalState = .completed(url)
        } catch is CancellationError {
            finalState = .cancelled
        } catch {
            finalState = .failed(Self.describe(error))
        }

        // Close the stream and drain every remaining signal before publishing the
        // terminal state, so no in-flight progress event is lost or arrives after
        // completion.
        continuation.finish()
        await pump.value
        complete(id: id, state: finalState)
    }

    private func complete(id: UUID, state: DownloadState) {
        running[id] = nil
        requests[id] = nil
        setState(id, state)
        startNext()
    }

    private func ingestProgress(id: UUID, _ snapshot: DownloadProgress) {
        guard running[id] != nil else { return }
        progresses[id] = snapshot
        emit(.progress(id, snapshot))
    }

    private func ingestPhase(id: UUID, _ label: String) {
        guard running[id] != nil else { return }
        setState(id, .postProcessing(label))
    }

    // MARK: - Emission

    private func setState(_ id: UUID, _ state: DownloadState) {
        states[id] = state
        if state.isTerminal { recordTerminal(id) }
        emit(.stateChanged(id, state))
    }

    /// Track a terminal id and evict the oldest finished records once the retained
    /// history exceeds the cap, so `states`/`progresses` stay bounded. Only records
    /// for tasks that are neither running nor pending are ever evicted.
    private func recordTerminal(_ id: UUID) {
        terminalOrder.removeAll { $0 == id }
        terminalOrder.append(id)
        while terminalOrder.count > terminalHistoryLimit {
            let oldest = terminalOrder.removeFirst()
            states[oldest] = nil
            progresses[oldest] = nil
        }
    }

    private func emit(_ event: DownloadManagerEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    // MARK: - Helpers

    /// Central point where a Core `DownloadError` becomes a user-facing string.
    /// Every heading is Russian; a non-empty yt-dlp stderr tail is kept verbatim as
    /// a diagnostic detail below the heading.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let DownloadError.failed(_, message):
            let heading = "Не удалось выполнить загрузку."
            return message.isEmpty ? heading : "\(heading)\n\(message)"
        case DownloadError.missingFinalPath:
            return "yt-dlp не сообщил путь к готовому файлу."
        case let DownloadError.pathEscape(url):
            return "Файл вышел за пределы папки назначения: \(url.path)"
        case DownloadError.timedOut:
            return "Загрузка не отвечает: превышено время ожидания."
        case DownloadError.terminatedUnexpectedly:
            return "Загрузка завершилась неожиданно."
        default:
            return String(describing: error)
        }
    }
}
