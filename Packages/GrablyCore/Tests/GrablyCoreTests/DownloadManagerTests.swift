import Foundation
import Testing
@testable import GrablyCore

// MARK: - Controllable mock downloader

/// A ``MediaDownloading`` whose every call blocks until the test explicitly
/// completes/fails it, so queue ordering and cancellation are fully deterministic.
private actor MockDownloader: MediaDownloading {
    private(set) var startOrder: [UUID] = []
    private var releases: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var startWaiters: [CheckedContinuation<UUID, Never>] = []
    private var startedButUnobserved: [UUID] = []
    /// Progress/phase snapshots to replay before blocking, per request id.
    private var scripted: [UUID: (progress: DownloadProgress?, phase: String?)] = [:]
    /// An ordered burst of progress snapshots to replay synchronously (mimics
    /// yt-dlp firing 0.1 → 0.5 → 0.9 back-to-back), per request id.
    private var scriptedSequence: [UUID: [DownloadProgress]] = [:]

    func script(_ id: UUID, progress: DownloadProgress?, phase: String?) {
        scripted[id] = (progress, phase)
    }

    func scriptSequence(_ id: UUID, _ snapshots: [DownloadProgress]) {
        scriptedSequence[id] = snapshots
    }

    func download(
        _ request: DownloadRequest,
        progress: @Sendable (DownloadProgress) -> Void,
        phase: @Sendable (String) -> Void
    ) async throws -> URL {
        let id = request.id
        startOrder.append(id)

        if let snapshot = scripted[id]?.progress { progress(snapshot) }
        if let label = scripted[id]?.phase { phase(label) }
        for snapshot in scriptedSequence[id] ?? [] { progress(snapshot) }

        noteStarted(id)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                releases[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Suspend until some `download(_:)` begins, returning its id.
    func awaitNextStart() async -> UUID {
        if !startedButUnobserved.isEmpty { return startedButUnobserved.removeFirst() }
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete(_ id: UUID, url: URL) {
        releases.removeValue(forKey: id)?.resume(returning: url)
    }

    func fail(_ id: UUID, error: Error) {
        releases.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cancelWaiter(_ id: UUID) {
        releases.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func noteStarted(_ id: UUID) {
        if !startWaiters.isEmpty {
            startWaiters.removeFirst().resume(returning: id)
        } else {
            startedButUnobserved.append(id)
        }
    }
}

@Suite("DownloadManager")
struct DownloadManagerTests {

    private struct TimeoutError: Error {}

    private func request() -> DownloadRequest {
        DownloadRequest(
            url: URL(string: "https://example.com/watch?v=\(UUID().uuidString)")!,
            kind: .audio(codec: .m4a),
            destinationDirectory: FileManager.default.temporaryDirectory
        )
    }

    /// Poll a task's state until `predicate` holds or we time out.
    private func waitForState(
        _ manager: DownloadManager,
        _ id: UUID,
        timeout: Duration = .seconds(5),
        _ predicate: @Sendable @escaping (DownloadState) -> Bool
    ) async throws -> DownloadState {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let state = await manager.state(of: id), predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimeoutError()
    }

    // MARK: - Queue ordering

    @Test("Two tasks run sequentially with maxConcurrent = 1")
    func sequentialQueue() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)

        let dest = FileManager.default.temporaryDirectory
        let requestA = DownloadRequest(
            url: URL(string: "https://example.com/a")!, destinationDirectory: dest
        )
        let requestB = DownloadRequest(
            url: URL(string: "https://example.com/b")!, destinationDirectory: dest
        )

        let idA = await manager.enqueue(requestA)
        let idB = await manager.enqueue(requestB)

        // A starts; B waits its turn.
        let firstStarted = await mock.awaitNextStart()
        #expect(firstStarted == idA)
        _ = try await waitForState(manager, idA) { $0 == .running }
        #expect(await manager.state(of: idB) == .queued)

        // Finish A; B then starts.
        await mock.complete(idA, url: dest.appendingPathComponent("a.m4a"))
        let secondStarted = await mock.awaitNextStart()
        #expect(secondStarted == idB)
        _ = try await waitForState(manager, idA) {
            if case .completed = $0 { return true } else { return false }
        }
        _ = try await waitForState(manager, idB) { $0 == .running }

        await mock.complete(idB, url: dest.appendingPathComponent("b.m4a"))
        _ = try await waitForState(manager, idB) {
            if case .completed = $0 { return true } else { return false }
        }

        #expect(await mock.startOrder == [idA, idB])
    }

    // MARK: - State transitions + events

    @Test("A task emits queued → running → postProcessing → completed")
    func stateTransitions() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let dest = FileManager.default.temporaryDirectory
        let req = DownloadRequest(
            url: URL(string: "https://example.com/x")!, destinationDirectory: dest
        )

        // Subscribe before enqueuing so no event is missed.
        let stream = await manager.events()
        let collector = Task { () -> [DownloadManagerEvent] in
            var events: [DownloadManagerEvent] = []
            for await event in stream {
                events.append(event)
                if case let .stateChanged(_, state) = event,
                   case .completed = state { break }
            }
            return events
        }

        let id = await manager.enqueue(req)
        await mock.script(id, progress: DownloadProgress(
            status: "downloading", downloadedBytes: 50, totalBytes: 100
        ), phase: "Объединение…")

        let started = await mock.awaitNextStart()
        #expect(started == id)
        _ = try await waitForState(manager, id) {
            if case .postProcessing = $0 { return true } else { return false }
        }
        let finalURL = dest.appendingPathComponent("x.m4a")
        await mock.complete(id, url: finalURL)

        let events = try await withThrowingTaskGroup(of: [DownloadManagerEvent].self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                collector.cancel()
                return []
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let states: [DownloadState] = events.compactMap {
            if case let .stateChanged(_, state) = $0 { return state } else { return nil }
        }
        #expect(states.first == .queued)
        #expect(states.contains(.running))
        #expect(states.contains { if case .postProcessing = $0 { return true } else { return false } })
        #expect(states.last == .completed(finalURL))

        let sawProgress = events.contains {
            if case .progress = $0 { return true } else { return false }
        }
        #expect(sawProgress)
    }

    @Test("Every intermediate progress snapshot reaches subscribers, in order")
    func progressSnapshotsDeliveredInOrder() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let dest = FileManager.default.temporaryDirectory
        let req = DownloadRequest(
            url: URL(string: "https://example.com/seq")!, destinationDirectory: dest
        )
        let id = req.id

        // yt-dlp emits a gradient of snapshots; the UI must see all of them, not
        // just the first/last, and never out of order.
        let snapshots = [
            DownloadProgress(status: "downloading", downloadedBytes: 10, totalBytes: 100),
            DownloadProgress(status: "downloading", downloadedBytes: 50, totalBytes: 100),
            DownloadProgress(status: "downloading", downloadedBytes: 90, totalBytes: 100),
        ]
        await mock.scriptSequence(id, snapshots)

        // Subscribe before enqueuing so no event can be missed.
        let stream = await manager.events()
        let collector = Task { () -> [Double] in
            var fractions: [Double] = []
            for await event in stream {
                if case let .progress(_, progress) = event { fractions.append(progress.fraction) }
                if case let .stateChanged(_, state) = event, case .completed = state { break }
            }
            return fractions
        }

        _ = await manager.enqueue(req)
        _ = await mock.awaitNextStart()
        await mock.complete(id, url: dest.appendingPathComponent("seq.m4a"))

        let fractions = try await withThrowingTaskGroup(of: [Double].self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                collector.cancel()
                return []
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        // All three snapshots delivered, strictly in emission order.
        #expect(fractions == [0.1, 0.5, 0.9])
    }

    // MARK: - Failure

    @Test("A failing download surfaces a .failed state")
    func failedDownload() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let id = await manager.enqueue(request())

        _ = await mock.awaitNextStart()
        await mock.fail(id, error: DownloadError.failed(code: 1, message: "boom"))

        let state = try await waitForState(manager, id) {
            if case .failed = $0 { return true } else { return false }
        }
        // The Russian heading is prepended; the raw yt-dlp tail is kept as detail.
        #expect(state == .failed("Не удалось выполнить загрузку.\nboom"))
    }

    // MARK: - Cancellation

    @Test("Cancelling a running task marks it cancelled and starts the next")
    func cancelRunning() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let dest = FileManager.default.temporaryDirectory
        let idA = await manager.enqueue(request())
        let idB = await manager.enqueue(request())

        _ = try await waitForState(manager, idA) { $0 == .running }
        _ = await mock.awaitNextStart() // idA

        await manager.cancel(idA)
        _ = try await waitForState(manager, idA) { $0 == .cancelled }

        // B must now get its turn.
        let started = await mock.awaitNextStart()
        #expect(started == idB)
        _ = try await waitForState(manager, idB) { $0 == .running }
        await mock.complete(idB, url: dest.appendingPathComponent("b.m4a"))
    }

    @Test("Cancelling a queued task removes it before it ever starts")
    func cancelQueued() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let dest = FileManager.default.temporaryDirectory
        let idA = await manager.enqueue(request())
        let idB = await manager.enqueue(request())

        _ = await mock.awaitNextStart() // idA running
        _ = try await waitForState(manager, idA) { $0 == .running }
        #expect(await manager.state(of: idB) == .queued)

        await manager.cancel(idB)
        #expect(await manager.state(of: idB) == .cancelled)

        // Completing A must NOT start the cancelled B.
        await mock.complete(idA, url: dest.appendingPathComponent("a.m4a"))
        _ = try await waitForState(manager, idA) {
            if case .completed = $0 { return true } else { return false }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await mock.startOrder == [idA], "cancelled queued task must never start")
    }

    @Test("Cancelling during post-processing marks the task cancelled")
    func cancelDuringPostProcessing() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let id = await manager.enqueue(request())
        await mock.script(id, progress: nil, phase: "Объединение…")

        _ = await mock.awaitNextStart()
        _ = try await waitForState(manager, id) {
            if case .postProcessing = $0 { return true } else { return false }
        }

        await manager.cancel(id)
        let state = try await waitForState(manager, id) { $0 == .cancelled }
        #expect(state == .cancelled)
    }

    @Test("Cancelling an unknown or already-terminal id is a no-op")
    func cancelUnknownOrTerminal() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)

        // Unknown id: no crash, no state.
        await manager.cancel(UUID())

        // Terminal id: cancel must not change a completed task.
        let dest = FileManager.default.temporaryDirectory
        let id = await manager.enqueue(request())
        _ = await mock.awaitNextStart()
        await mock.complete(id, url: dest.appendingPathComponent("x.m4a"))
        _ = try await waitForState(manager, id) {
            if case .completed = $0 { return true } else { return false }
        }
        await manager.cancel(id)
        try await Task.sleep(for: .milliseconds(50))
        if case .completed = await manager.state(of: id) {} else {
            Issue.record("cancel of a completed task must be a no-op")
        }
    }

    @Test("Enqueuing an already-active id is ignored (no duplicate run)")
    func duplicateEnqueueIgnored() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let dest = FileManager.default.temporaryDirectory
        let req = DownloadRequest(
            url: URL(string: "https://example.com/dup")!, destinationDirectory: dest
        )

        let id = await manager.enqueue(req)
        _ = await mock.awaitNextStart()
        _ = try await waitForState(manager, id) { $0 == .running }

        // Second enqueue of the same id while running must be ignored.
        let again = await manager.enqueue(req)
        #expect(again == id)
        #expect(await manager.state(of: id) == .running, "must not reset to .queued")

        await mock.complete(id, url: dest.appendingPathComponent("dup.m4a"))
        _ = try await waitForState(manager, id) {
            if case .completed = $0 { return true } else { return false }
        }
        #expect(await mock.startOrder == [id], "the id must have started exactly once")
    }

    @Test("pathEscape and missingFinalPath are mapped to Russian .failed states")
    func mapsDownloadErrorsToFailed() async throws {
        let dest = FileManager.default.temporaryDirectory

        for (error, expected) in [
            (DownloadError.pathEscape(dest.appendingPathComponent("x.mp4")),
             "Файл вышел за пределы папки назначения: \(dest.appendingPathComponent("x.mp4").path)"),
            (DownloadError.missingFinalPath, "yt-dlp не сообщил путь к готовому файлу."),
        ] {
            let mock = MockDownloader()
            let manager = DownloadManager(client: mock, maxConcurrent: 1)
            let id = await manager.enqueue(request())
            _ = await mock.awaitNextStart()
            await mock.fail(id, error: error)
            let state = try await waitForState(manager, id) {
                if case .failed = $0 { return true } else { return false }
            }
            #expect(state == .failed(expected))
        }
    }

    // MARK: - Multiple subscribers & snapshot

    @Test("Multiple concurrent subscribers each receive every event")
    func multipleSubscribers() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let dest = FileManager.default.temporaryDirectory

        func collect(_ stream: AsyncStream<DownloadManagerEvent>) -> Task<[DownloadManagerEvent], Never> {
            Task {
                var events: [DownloadManagerEvent] = []
                for await event in stream {
                    events.append(event)
                    if case let .stateChanged(_, state) = event, case .completed = state { break }
                }
                return events
            }
        }

        let a = collect(await manager.events())
        let b = collect(await manager.events())

        let id = await manager.enqueue(request())
        _ = await mock.awaitNextStart()
        await mock.complete(id, url: dest.appendingPathComponent("x.m4a"))

        func hasCompleted(_ events: [DownloadManagerEvent]) -> Bool {
            events.contains { if case let .stateChanged(_, s) = $0, case .completed = s { return true }; return false }
        }
        #expect(hasCompleted(await a.value))
        #expect(hasCompleted(await b.value))
    }

    @Test("snapshot() lets a late observer reconstruct running state and progress")
    func lateSubscriberSnapshot() async throws {
        let mock = MockDownloader()
        let manager = DownloadManager(client: mock, maxConcurrent: 1)
        let id = await manager.enqueue(request())
        await mock.script(id, progress: DownloadProgress(
            status: "downloading", downloadedBytes: 40, totalBytes: 100
        ), phase: nil)

        _ = await mock.awaitNextStart()
        _ = try await waitForState(manager, id) { $0 == .running }

        // A subscriber that only attaches now can seed itself from the snapshot.
        // Progress is ingested asynchronously, so poll until it lands.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var entry: DownloadTaskSnapshot?
        while ContinuousClock.now < deadline {
            entry = await manager.snapshot().first { $0.id == id }
            if entry?.progress.downloadedBytes == 40 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let entry else {
            Issue.record("snapshot should contain the running task"); return
        }
        #expect(entry.state == .running)
        #expect(entry.progress.downloadedBytes == 40)
        #expect(entry.progress.totalBytes == 100)
    }
}
