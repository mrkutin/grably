import Darwin
import Foundation
import os

/// Why a download performed by ``YTDLPClient`` failed.
public enum DownloadError: Error, Sendable, Equatable {
    /// yt-dlp exited non-zero. Carries the (sanitized) stderr tail.
    case failed(code: Int32, message: String)
    /// yt-dlp exited 0 but never printed a `FINALPATH`, so the output location is
    /// unknown.
    case missingFinalPath
    /// yt-dlp reported a final path that resolves **outside** the requested
    /// destination directory. Treated as hostile and refused.
    case pathEscape(URL)
    /// The download made no progress for longer than the stall timeout and was
    /// terminated. Distinct from ``failed`` so callers can message it clearly.
    case timedOut
    /// The process ended without a terminal exit event (should not happen).
    case terminatedUnexpectedly
}

/// Abstraction over "something that can perform a download", so the
/// ``DownloadManager`` queue can be unit-tested against a mock without spawning a
/// real process. ``YTDLPClient`` is the production conformer.
public protocol MediaDownloading: Sendable {
    func download(
        _ request: DownloadRequest,
        progress: @Sendable (DownloadProgress) -> Void,
        phase: @Sendable (String) -> Void
    ) async throws -> URL
}

/// High-level async interface over the yt-dlp executable.
///
/// Actor-isolated to serialize construction of the launch descriptions; the
/// underlying ``ProcessRunner`` is itself an actor and enforces its own isolation.
public actor YTDLPClient: MediaDownloading {
    private let binaries: ResolvedBinaries
    private let runner: ProcessRunner
    private let arguments: YTDLPArguments
    private let progressParser: ProgressParser

    /// The authentication config applied to every probe/download until changed.
    ///
    /// Held here (rather than threaded through ``MediaDownloading/download`` and the
    /// ``DownloadManager`` queue) so the queue protocol stays auth-agnostic. The UI
    /// pushes the current setting via ``setAuth(_:)`` before each probe/enqueue.
    /// Never logged; cookie values are not stored in this type.
    private var auth: AuthConfig = .none

    /// Cap on retained stderr lines (bounds memory for a chatty/hostile process;
    /// only the tail is surfaced in error messages).
    private static let maxStderrLines = 50

    /// Overall wall-clock deadline for a metadata probe. `--socket-timeout` only
    /// bounds network stalls; this also catches a non-network hang (nobody would
    /// otherwise cancel the probe task).
    private let probeTimeout: Duration
    /// Maximum time a running download may go **without any output** (no progress
    /// line, no diagnostic line) before it is treated as stalled and terminated.
    /// A download can legitimately run for a long time, so we bound inactivity
    /// rather than total duration.
    private let downloadStallTimeout: Duration
    /// Grace given to yt-dlp to finalise (delete partials) after `SIGINT` on
    /// cancellation before escalating to `SIGTERM`.
    private let cancelGracePeriod: Duration

    public init(
        binaries: ResolvedBinaries,
        runner: ProcessRunner,
        arguments: YTDLPArguments = YTDLPArguments(),
        progressParser: ProgressParser = ProgressParser(),
        probeTimeout: Duration = .seconds(60),
        downloadStallTimeout: Duration = .seconds(120),
        cancelGracePeriod: Duration = .milliseconds(1500)
    ) {
        self.binaries = binaries
        self.runner = runner
        self.arguments = arguments
        self.progressParser = progressParser
        self.probeTimeout = probeTimeout
        self.downloadStallTimeout = downloadStallTimeout
        self.cancelGracePeriod = cancelGracePeriod
    }

    /// Set the authentication config applied to subsequent probes and downloads.
    /// A no-op-safe setter the UI calls before probing/enqueuing so the current
    /// session source (browser cookies / cookies file / none) is honored.
    public func setAuth(_ auth: AuthConfig) {
        self.auth = auth
    }

    // MARK: - Probe

    /// Fetch metadata (available formats, title, etc.) for a URL.
    ///
    /// - Throws: ``MediaInfo/ProbeError`` — `.playlist`/`.noFormats` for
    ///   non-single-video URLs, or `.failed` carrying the stderr tail on a
    ///   non-zero exit or unparseable output. `CancellationError` if the task is
    ///   cancelled (the process group is torn down).
    ///
    /// `auth` defaults to the actor's current setting (from ``setAuth(_:)``); pass
    /// an explicit value to override for a single probe.
    public func probe(
        url: URL,
        auth: AuthConfig? = nil
    ) async throws -> MediaInfo {
        // Enforce the http(s) allowlist before we ever spawn yt-dlp.
        try DownloadRequest.validate(url: url)

        // Don't spawn a process for an already-cancelled task.
        try Task.checkCancellation()

        let launch = ProcessLaunch(
            executableURL: binaries.ytDlp,
            arguments: arguments.probeArguments(
                url: url, auth: auth ?? self.auth
            ),
            environment: ProcessEnvironment.defaultEnvironment,
            // Never the destination dir (B5): keep the child's CWD controlled so a
            // planted plugin/library can't be loaded relative to it.
            currentDirectory: nil
        )
        let (events, handle) = try await runner.run(launch)

        // Wall-clock deadline: fires `terminate()` if the probe hangs. `timedOut`
        // is flipped first so, once the forced exit arrives, we report a timeout
        // rather than a generic non-zero failure.
        let timedOut = Flag()
        let deadline = Task { [probeTimeout] in
            try? await Task.sleep(for: probeTimeout)
            guard !Task.isCancelled else { return }
            timedOut.set()
            handle.terminate()
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            // `-J` prints the whole document as one line; accumulate all stdout
            // lines and join, tolerating any stray split.
            var stdoutLines: [String] = []
            var stderrTail = StderrTail(limit: Self.maxStderrLines)

            for await event in events {
                switch event {
                case let .stdoutLine(line):
                    stdoutLines.append(line)
                case let .stderrLine(line):
                    stderrTail.append(OutputSanitizer.sanitize(line))
                case let .exit(code, _):
                    if code == 0, !timedOut.isSet {
                        let data = Data(stdoutLines.joined(separator: "\n").utf8)
                        do {
                            return try MediaInfo.decode(from: data)
                        } catch let error as MediaInfo.ProbeError {
                            throw error // .playlist / .noFormats propagate verbatim.
                        } catch {
                            throw MediaInfo.ProbeError.failed(
                                "Не удалось разобрать метаданные: \(error)"
                            )
                        }
                    } else {
                        try Task.checkCancellation()
                        if timedOut.isSet {
                            throw MediaInfo.ProbeError.failed(
                                "Превышено время ожидания ответа yt-dlp."
                            )
                        }
                        throw Self.mapProbeFailure(stderrTail.joined())
                    }
                }
            }
            // Stream ended without an exit event: only happens on teardown.
            try Task.checkCancellation()
            if timedOut.isSet {
                throw MediaInfo.ProbeError.failed(
                    "Превышено время ожидания ответа yt-dlp."
                )
            }
            throw MediaInfo.ProbeError.failed("yt-dlp не вернул данных.")
        } onCancel: {
            handle.terminate()
        }
    }

    // MARK: - Download

    /// Start a download, streaming progress and post-processing phases via the
    /// callbacks, and return the final on-disk URL.
    ///
    /// - Parameters:
    ///   - progress: invoked for every parsed `PROGRESS` line.
    ///   - phase: invoked with a user-facing label when a post-processing step
    ///     (mux / audio extract / remux) begins.
    /// - Throws: ``DownloadError`` on non-zero exit, a missing/escaping final
    ///   path; `CancellationError` on cooperative cancellation.
    public func download(
        _ request: DownloadRequest,
        progress: @Sendable (DownloadProgress) -> Void,
        phase: @Sendable (String) -> Void
    ) async throws -> URL {
        // Re-validate the scheme even if the caller already did.
        try DownloadRequest.validate(url: request.url)

        // Don't spawn a process for an already-cancelled task.
        try Task.checkCancellation()

        let launch = ProcessLaunch(
            executableURL: binaries.ytDlp,
            arguments: arguments.downloadArguments(
                request: request, ffmpegDir: binaries.ffmpegDirectory,
                auth: auth
            ),
            environment: ProcessEnvironment.defaultEnvironment,
            currentDirectory: nil // security B5, see probe().
        )
        let (events, handle) = try await runner.run(launch)

        // Wall-clock start, so the partial-file sweep can be scoped to leftovers
        // created during *this* download session.
        let startedAt = Date()
        // Every announced destination file, so its leftover `.part`/temp siblings
        // can be name-scoped when swept. A Sendable box because it is written from
        // the (nonisolated) event loop and read from the catch. On cancellation the
        // AsyncStream may drop buffered lines, so this can legitimately be empty —
        // the sweep then falls back to session-mtime scoping.
        let destinations = URLCollector()
        // Inactivity watchdog: any output line refreshes `lastActivity`; if none
        // arrives within `downloadStallTimeout`, the process is terminated.
        let lastActivity = Clock(now: .now)
        let stalled = Flag()
        let watchdog = Task { [downloadStallTimeout] in
            while !Task.isCancelled {
                let remaining = downloadStallTimeout - lastActivity.value.duration(to: .now)
                if remaining <= .zero {
                    stalled.set()
                    handle.terminate()
                    return
                }
                do { try await Task.sleep(for: remaining) } catch { return }
            }
        }
        defer { watchdog.cancel() }

        do {
            return try await withTaskCancellationHandler {
                var finalURL: URL?
                var stderrTail = StderrTail(limit: Self.maxStderrLines)

                // Real yt-dlp emits the `--progress-template` lines and the
                // `--print after_move:FINALPATH` line across stdout/stderr, so both
                // streams are fed through the parser. The machine-readable prefixes
                // (`PROGRESS`/`FINALPATH`) are unambiguous, so this never
                // misclassifies ordinary diagnostics; a line the parser doesn't
                // recognise on stderr is kept as a diagnostic tail. Recognised
                // protocol lines are parsed raw (never sanitized) per
                // OutputSanitizer's contract.
                func consume(_ line: String) -> Bool {
                    switch progressParser.parse(line: line) {
                    case let .progress(snapshot):
                        progress(snapshot)
                        return true
                    case let .postProcessing(raw):
                        phase(Self.phaseLabel(for: raw))
                        return true
                    case let .finalPath(url):
                        finalURL = url
                        return true
                    case let .destination(url):
                        destinations.append(url)
                        return true // recorded for partial-file sweeping
                    case .none:
                        return false
                    }
                }

                for await event in events {
                    switch event {
                    case let .stdoutLine(line):
                        lastActivity.value = .now
                        _ = consume(line)
                    case let .stderrLine(line):
                        lastActivity.value = .now
                        if !consume(line) {
                            stderrTail.append(OutputSanitizer.sanitize(line))
                        }
                    case let .exit(code, _):
                        if code == 0, !stalled.isSet {
                            guard let finalURL else {
                                throw DownloadError.missingFinalPath
                            }
                            // H3 post-check: the file yt-dlp reports must physically
                            // be inside the requested destination directory. Never
                            // trust it didn't write outside via a crafted template.
                            try Self.verifyInside(
                                finalURL, directory: request.destinationDirectory
                            )
                            return finalURL
                        } else {
                            try Task.checkCancellation()
                            if stalled.isSet { throw DownloadError.timedOut }
                            throw DownloadError.failed(
                                code: code, message: stderrTail.joined()
                            )
                        }
                    }
                }
                try Task.checkCancellation()
                if stalled.isSet { throw DownloadError.timedOut }
                throw DownloadError.terminatedUnexpectedly
            } onCancel: {
                // SIGINT lets yt-dlp finalise and delete its `.part` file; escalate
                // to SIGTERM only if it hasn't exited within the grace period.
                // Both signals are gated no-ops once the process has exited.
                handle.interrupt()
                Task { [cancelGracePeriod] in
                    try? await Task.sleep(for: cancelGracePeriod)
                    handle.terminate()
                }
            }
        } catch {
            // On any non-success outcome (cancellation, stall, failure) sweep the
            // known partial/temp leftovers for this download's destinations so the
            // target folder isn't littered with `.part` files.
            Self.sweepPartials(
                destinations: destinations.values(),
                startedAt: startedAt,
                in: request.destinationDirectory
            )
            throw error
        }
    }

    // MARK: - Helpers

    /// Map a yt-dlp post-processing line to a short, user-facing phase label.
    private static func phaseLabel(for raw: String) -> String {
        if raw.hasPrefix("[Merger]") { return "Объединение…" }
        if raw.hasPrefix("[ExtractAudio]") { return "Извлечение аудио…" }
        if raw.hasPrefix("[VideoConvertor]") { return "Конвертация…" }
        if raw.hasPrefix("[Metadata]") { return "Запись метаданных…" }
        return raw
    }

    /// Verify `url`'s canonical path is inside `directory`'s canonical path.
    ///
    /// Uses `realpath` on the directory (resolving any symlinks) and on the file's
    /// parent, so neither a `../` in the reported path nor a symlinked component
    /// can smuggle the output outside the chosen directory. In addition, the final
    /// leaf itself is `lstat`-checked and rejected if it is a symlink: with
    /// `--restrict-filenames` the output name is predictable, so a symlink planted
    /// at that exact path (whose *parent* is legitimately inside the directory)
    /// could otherwise redirect the "final" file outside it.
    private static func verifyInside(_ url: URL, directory: URL) throws {
        func canonical(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // Reject a symlinked leaf (do not follow it).
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw DownloadError.pathEscape(url)
        }
        guard let realDirectory = canonical(directory.path),
              let realParent = canonical(url.deletingLastPathComponent().path) else {
            throw DownloadError.pathEscape(url)
        }
        let prefix = realDirectory.hasSuffix("/") ? realDirectory : realDirectory + "/"
        guard realParent == realDirectory || realParent.hasPrefix(prefix) else {
            throw DownloadError.pathEscape(url)
        }
    }

    /// Best-effort removal of yt-dlp's partial/temporary leftovers in `directory`.
    ///
    /// A file is only removed when it carries a known partial suffix (`.part`,
    /// `.part-Frag*`, `.ytdl`, `.temp*`) **and**:
    /// - it was modified at/after `startedAt` (created during this session), and
    /// - if the download announced any destination names, its name starts with one
    ///   of them (precise scoping for a shared folder).
    ///
    /// On cancellation the event stream can drop buffered lines, so `destinations`
    /// may be empty; the session-mtime bound then keeps the sweep scoped to this
    /// download. (With the app's serial queue there is no concurrent writer; at a
    /// higher concurrency this only ever affects freshly-written partial files.)
    private static func sweepPartials(
        destinations: [URL], startedAt: Date, in directory: URL
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let stems = Set(destinations.map { $0.lastPathComponent })
        // Small margin so filesystem/clock granularity can't exclude a just-created
        // partial whose mtime rounds a hair below `startedAt`.
        let cutoff = startedAt.addingTimeInterval(-2)
        for entry in entries {
            let name = entry.lastPathComponent
            guard isPartialName(name) else { continue }
            if !stems.isEmpty, !stems.contains(where: { name.hasPrefix($0) }) { continue }
            let mtime = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            guard mtime >= cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Whether `name` looks like a yt-dlp/ffmpeg partial or temporary artifact.
    private static func isPartialName(_ name: String) -> Bool {
        name.hasSuffix(".part")
            || name.contains(".part-Frag")
            || name.hasSuffix(".ytdl")
            || name.contains(".temp.")
            || name.hasSuffix(".temp")
    }

    /// Best-effort mapping of a yt-dlp stderr tail to a friendlier probe error.
    /// Always preserves the raw tail so nothing diagnostic is lost.
    private static func mapProbeFailure(_ stderr: String) -> MediaInfo.ProbeError {
        let lowered = stderr.lowercased()
        let hint: String?
        if lowered.contains("private video") || lowered.contains("this video is private") {
            hint = "Видео приватное."
        } else if lowered.contains("age") && lowered.contains("confirm") {
            hint = "Видео с возрастным ограничением."
        } else if lowered.contains("not available in your country")
            || lowered.contains("geo") {
            hint = "Видео недоступно в вашем регионе."
        } else if lowered.contains("unsupported url") {
            hint = "Ссылка не поддерживается."
        } else if lowered.contains("unable to download")
            || lowered.contains("timed out")
            || lowered.contains("network") {
            hint = "Ошибка сети."
        } else {
            hint = nil
        }
        let tail = stderr.isEmpty ? "yt-dlp завершился с ошибкой." : stderr
        return .failed(hint.map { "\($0)\n\(tail)" } ?? tail)
    }
}

/// A minimal `Sendable`, thread-safe one-shot boolean flag.
private final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}

/// A minimal `Sendable`, thread-safe box for a `ContinuousClock.Instant`, used by
/// the download stall watchdog to share the last-activity timestamp.
private final class Clock: Sendable {
    private let state: OSAllocatedUnfairLock<ContinuousClock.Instant>
    init(now: ContinuousClock.Instant) { state = OSAllocatedUnfairLock(initialState: now) }
    var value: ContinuousClock.Instant {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A minimal `Sendable`, thread-safe accumulator of announced destination URLs.
private final class URLCollector: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [URL]())
    func append(_ url: URL) { state.withLock { $0.append(url) } }
    func values() -> [URL] { state.withLock { $0 } }
}

/// A bounded FIFO of the most recent stderr lines.
private struct StderrTail {
    private var lines: [String] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    mutating func append(_ line: String) {
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func joined() -> String { lines.joined(separator: "\n") }
}
