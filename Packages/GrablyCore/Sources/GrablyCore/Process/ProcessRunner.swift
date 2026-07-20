import Darwin
import Foundation
import os

/// The terminal result of a finished process.
///
/// Retained for the higher-level (phase 4+) buffered-collection API; the
/// streaming ``ProcessRunner/run(_:)`` used by the download pipeline emits
/// ``ProcessEvent`` values instead.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Errors thrown while launching or managing a subprocess.
public enum ProcessRunnerError: Error, Sendable, Equatable {
    /// No file exists at the requested executable path (or it is a directory).
    case executableNotFound(URL)
    /// The file exists but does not have the executable bit set.
    case notExecutable(URL)
    /// `posix_spawn` (or pipe setup) failed; carries the underlying description.
    case launchFailed(String)
    case terminated(Int32)
    case notImplemented
}

// MARK: - Launch description

/// A fully specified, `Sendable` description of a process to launch.
///
/// Kept free of any Foundation reference types (`Process`, `Pipe`, `FileHandle`)
/// so it can cross actor/task boundaries; those non-`Sendable` objects are only
/// ever materialised inside ``ProcessRunner``.
public struct ProcessLaunch: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    /// Environment variables. Passed through ``ProcessEnvironment/resolve(_:)``,
    /// which applies a strict allowlist and forces the UTF-8 locale; host
    /// variables are never inherited.
    public var environment: [String: String]
    /// Working directory of the child.
    ///
    /// - Important (security): this must **never** be the user's download
    ///   destination or any other attacker-writable directory. yt-dlp/Python
    ///   resolve some paths relative to the CWD, so a planted `yt_dlp_plugins/`
    ///   or shared-library there could be loaded into our non-sandboxed process.
    ///   Leave it `nil` (inherit the app's controlled CWD) or point it at a
    ///   directory we own (the bundled-binaries dir or a private temp dir).
    public var currentDirectory: URL?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = ProcessEnvironment.defaultEnvironment,
        currentDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

// MARK: - Events

/// `Sendable` mirror of `Process.TerminationReason` (which is not `Sendable`).
public enum ProcessTerminationReason: Sendable, Equatable {
    case exited
    case uncaughtSignal
}

/// A single event emitted while a process runs.
///
/// `.exit` is always the final event; the stream finishes immediately after it.
public enum ProcessEvent: Sendable {
    case stdoutLine(String)
    case stderrLine(String)
    case exit(code: Int32, reason: ProcessTerminationReason)
}

// MARK: - Cancellation handle

/// A `Sendable`, thread-safe handle for signalling a running process **and every
/// process it spawns**.
///
/// The child is launched as the leader of a fresh process group (via
/// `posix_spawn` with `POSIX_SPAWN_SETPGROUP`), so its PID equals its PGID. All
/// signals are delivered to that group with `killpg(2)` — this is what lets us
/// reach yt-dlp's grandchild `ffmpeg`, which would otherwise survive and keep the
/// output pipe's write end open (see ``ProcessRunner``).
///
/// `interrupt()`/`terminate()` are idempotent and safe after exit: once the run
/// finalises they are gated off, and a `killpg` on a dead group yields `ESRCH`,
/// which is ignored. Using the group id (kept alive as long as any member lives)
/// also sidesteps the classic single-PID reuse race — we never signal a bare PID.
public final class ProcessHandle: Sendable {
    private struct State {
        var pgid: pid_t?
        var terminated = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Send `SIGINT` to the process group — yt-dlp catches this and finalises the
    /// `.part` file before exiting.
    public func interrupt() { signalGroup(SIGINT, gated: true) }

    /// Send `SIGTERM` to the process group.
    public func terminate() { signalGroup(SIGTERM, gated: true) }

    /// Force-kill the whole group with `SIGKILL`, bypassing the "already
    /// terminated" gate. Used by the runner's watchdog to reap grandchildren that
    /// outlived the parent and are still pinning the output pipe open.
    func forceKillGroup() { signalGroup(SIGKILL, gated: false) }

    // Called by the runner once the process is live (pgid == child pid).
    func setProcessGroup(_ pgid: pid_t) {
        state.withLock { $0.pgid = pgid }
    }

    // Called by the runner when the run has fully finalised; gates further
    // graceful signals.
    func markTerminated() {
        state.withLock { $0.terminated = true }
    }

    private func signalGroup(_ sig: Int32, gated: Bool) {
        let pgid: pid_t? = state.withLock { current in
            if gated && current.terminated { return nil }
            return current.pgid
        }
        guard let pgid, pgid > 0 else { return }
        // Ignore the result: a dead/reaped group yields ESRCH, which is a no-op
        // for our purposes and must never crash.
        _ = killpg(pgid, sig)
    }
}

// MARK: - Internal plumbing

/// Thread-safe wrapper around a `LineTokenizer`.
///
/// A reader queue drains its pipe on an arbitrary background thread; wrapping the
/// (mutating, value-type) tokenizer in a lock keeps its buffer race-free and lets
/// the box be captured by an `@Sendable` closure.
private final class TokenizerBox: Sendable {
    private let lock: OSAllocatedUnfairLock<LineTokenizer>

    init(maxLineBytes: Int = LineTokenizer.defaultMaxLineBytes) {
        lock = OSAllocatedUnfairLock(initialState: LineTokenizer(maxLineBytes: maxLineBytes))
    }

    func push(_ data: Data) -> [String] {
        lock.withLock { $0.push(data) }
    }

    func finish() -> String? {
        lock.withLock { $0.finish() }
    }
}

/// Coordinates the three asynchronous end-conditions of a run — stdout EOF,
/// stderr EOF, and process termination (via `waitpid`) — so the `.exit` event is
/// emitted exactly once, only after every buffered line has been flushed, and the
/// stream is then finished.
///
/// Each condition is reported independently and possibly concurrently; whichever
/// arrives last performs the finalisation. A watchdog guards the pathological case
/// where the parent has been reaped but a grandchild still holds the pipe open, so
/// EOF would otherwise never arrive.
private final class RunCoordinator: Sendable {
    private struct State {
        var stdoutClosed = false
        var stderrClosed = false
        var terminated = false
        var finished = false
        var exitCode: Int32 = 0
        var reason: ProcessTerminationReason = .exited
        var totalBytes = 0
        var byteCapHit = false
    }

    /// Per-run aggregate output cap. A backstop against a broken/hostile process
    /// streaming unbounded data; combined with ``LineTokenizer``'s per-line cap it
    /// bounds total memory. 32 MiB comfortably exceeds any real probe/progress
    /// volume for a single item.
    private let maxTotalBytes = 32 * 1024 * 1024

    /// Grace period after the parent is reaped before force-killing the group to
    /// unblock readers stuck on a grandchild-held pipe.
    private let watchdogGrace: DispatchTimeInterval = .seconds(2)
    private let watchdogQueue = DispatchQueue(label: "com.grably.process.watchdog")

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let handle: ProcessHandle

    init(
        continuation: AsyncStream<ProcessEvent>.Continuation,
        handle: ProcessHandle
    ) {
        self.continuation = continuation
        self.handle = handle
    }

    func markStdoutClosed() {
        _ = finalizeIfReady { $0.stdoutClosed = true }
    }

    func markStderrClosed() {
        _ = finalizeIfReady { $0.stderrClosed = true }
    }

    func markTerminated(code: Int32, reason: ProcessTerminationReason) {
        let finished = finalizeIfReady {
            $0.terminated = true
            $0.exitCode = code
            $0.reason = reason
        }
        // Parent is gone but at least one pipe has not reached EOF: a grandchild
        // is likely still holding the write end. Arm the watchdog to force-kill
        // the group if EOF still hasn't arrived after the grace period.
        if !finished { armWatchdog() }
    }

    /// Record `count` bytes of output and report whether the per-run cap has been
    /// exceeded. Once tripped it stays tripped and always returns `true`.
    func recordBytes(_ count: Int) -> Bool {
        state.withLock {
            if $0.byteCapHit { return true }
            $0.totalBytes += count
            if $0.totalBytes > maxTotalBytes {
                $0.byteCapHit = true
                return true
            }
            return false
        }
    }

    /// Apply `mutate`, then finalise the stream iff all three end-conditions have
    /// been met. Returns whether the run is (now or already) finished.
    private func finalizeIfReady(_ mutate: @Sendable (inout State) -> Void) -> Bool {
        let outcome: (finished: Bool, payload: (code: Int32, reason: ProcessTerminationReason)?) =
            state.withLock { state in
                mutate(&state)
                if state.stdoutClosed, state.stderrClosed, state.terminated, !state.finished {
                    state.finished = true
                    return (true, (state.exitCode, state.reason))
                }
                return (state.finished, nil)
            }

        if let payload = outcome.payload {
            continuation.yield(.exit(code: payload.code, reason: payload.reason))
            // Death confirmed and everything drained: block further graceful
            // signals, then close the stream. Order matters — blocking before
            // finish() means the stream's onTermination handler's terminate() is
            // a no-op rather than racing a reused PGID.
            handle.markTerminated()
            continuation.finish()
        }
        return outcome.finished
    }

    private func armWatchdog() {
        watchdogQueue.asyncAfter(deadline: .now() + watchdogGrace) { [state, handle] in
            let stillRunning = state.withLock { !$0.finished }
            if stillRunning { handle.forceKillGroup() }
        }
    }
}

// MARK: - Runner

/// Spawns and supervises helper subprocesses (yt-dlp, ffmpeg).
///
/// Actor-isolated so the low-level `posix_spawn` plumbing (pipes, file actions,
/// argv/envp C arrays) is set up in one isolation domain. Callers only ever
/// receive the `Sendable` ``ProcessEvent`` stream and ``ProcessHandle``.
///
/// ## Process-group teardown (why not `Foundation.Process`)
///
/// yt-dlp routinely spawns a child `ffmpeg` for muxing. If we launched with
/// `Foundation.Process` the child would share *our* process group, so we could not
/// signal it as a unit without also signalling ourselves. Worse, a grandchild
/// `ffmpeg` that outlives (or is backgrounded by) yt-dlp inherits the stdout/stderr
/// pipe write end; a blocking read would then **never** see EOF and the stream
/// would hang forever.
///
/// We therefore launch via `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (new group,
/// PGID == PID) and `POSIX_SPAWN_CLOEXEC_DEFAULT` (no stray fd inheritance).
/// Cancellation signals go to the whole group via `killpg`, and a 2 s watchdog
/// after the parent is reaped `SIGKILL`s the group if a lingering grandchild is
/// still pinning a pipe open — guaranteeing EOF and a delivered `.exit`.
public actor ProcessRunner {
    public init() {}

    /// Launch `launch` and stream its output.
    ///
    /// stdout and stderr are read line-by-line via independent ``LineTokenizer``s
    /// (so yt-dlp's `\r`-separated progress lines surface individually). The
    /// returned stream yields `.stdoutLine`/`.stderrLine` events as they arrive
    /// and a final `.exit` once the process ends and both pipes reach EOF, after
    /// which it finishes.
    ///
    /// Dropping or cancelling the stream tears the whole process group down
    /// (`SIGTERM` via the continuation's `onTermination`), so nothing is left
    /// running and no reader thread is left blocked.
    ///
    /// - Throws: ``ProcessRunnerError/executableNotFound(_:)`` /
    ///   ``ProcessRunnerError/notExecutable(_:)`` for a bad executable path, or a
    ///   `launchFailed` wrapping any error from pipe setup / `posix_spawn`.
    public func run(
        _ launch: ProcessLaunch
    ) throws -> (events: AsyncStream<ProcessEvent>, handle: ProcessHandle) {
        try validate(launch.executableURL)

        // Create the two output pipes.
        var stdoutFDs = (read: Int32(-1), write: Int32(-1))
        var stderrFDs = (read: Int32(-1), write: Int32(-1))
        try withUnsafeTemporaryAllocation(of: Int32.self, capacity: 2) { buf in
            guard pipe(buf.baseAddress!) == 0 else {
                throw ProcessRunnerError.launchFailed("pipe() failed: \(errno)")
            }
            stdoutFDs = (buf[0], buf[1])
        }
        do {
            try withUnsafeTemporaryAllocation(of: Int32.self, capacity: 2) { buf in
                guard pipe(buf.baseAddress!) == 0 else {
                    throw ProcessRunnerError.launchFailed("pipe() failed: \(errno)")
                }
                stderrFDs = (buf[0], buf[1])
            }
        } catch {
            close(stdoutFDs.read)
            close(stdoutFDs.write)
            throw error
        }

        // Keep the fds we hold in the parent from leaking into any *other*
        // concurrent spawn. (The child side is covered by CLOEXEC_DEFAULT; the
        // dup2 targets are re-opened by the file actions regardless.)
        for fd in [stdoutFDs.read, stdoutFDs.write, stderrFDs.read, stderrFDs.write] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        let handle = ProcessHandle()

        // Unbounded buffering: never drop a progress line under back-pressure. The
        // real OOM vectors (unbounded single line, unbounded total) are capped in
        // LineTokenizer and RunCoordinator respectively.
        var capturedContinuation: AsyncStream<ProcessEvent>.Continuation!
        let stream = AsyncStream<ProcessEvent>(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        let continuation = capturedContinuation!

        // Dropping/cancelling the consumer tears down the whole group.
        continuation.onTermination = { [handle] _ in handle.terminate() }

        let coordinator = RunCoordinator(continuation: continuation, handle: handle)

        // Spawn.
        let pid: pid_t
        do {
            pid = try spawn(
                launch: launch,
                stdoutWrite: stdoutFDs.write,
                stderrWrite: stderrFDs.write,
                stdoutRead: stdoutFDs.read,
                stderrRead: stderrFDs.read
            )
        } catch {
            // Nothing started; close everything and finish the (empty) stream.
            close(stdoutFDs.read)
            close(stdoutFDs.write)
            close(stderrFDs.read)
            close(stderrFDs.write)
            handle.markTerminated()
            coordinator.markStdoutClosed()
            coordinator.markStderrClosed()
            coordinator.markTerminated(code: -1, reason: .exited)
            throw error
        }

        // Child now owns the write ends; the parent must drop them so EOF can be
        // observed once the child (and its group) exits.
        close(stdoutFDs.write)
        close(stderrFDs.write)

        // PGID == PID because of POSIX_SPAWN_SETPGROUP with group 0.
        handle.setProcessGroup(pid)

        startReader(
            readFD: stdoutFDs.read,
            label: "com.grably.process.stdout",
            makeEvent: { ProcessEvent.stdoutLine($0) },
            onEOF: { coordinator.markStdoutClosed() },
            coordinator: coordinator,
            handle: handle,
            continuation: continuation
        )
        startReader(
            readFD: stderrFDs.read,
            label: "com.grably.process.stderr",
            makeEvent: { ProcessEvent.stderrLine($0) },
            onEOF: { coordinator.markStderrClosed() },
            coordinator: coordinator,
            handle: handle,
            continuation: continuation
        )

        startReaper(pid: pid, coordinator: coordinator)

        return (stream, handle)
    }

    // MARK: Helpers

    private func validate(_ url: URL) throws {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ProcessRunnerError.executableNotFound(url)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ProcessRunnerError.notExecutable(url)
        }
        // NOTE (phase 4 / BinaryProvisioner): this checks only existence + the
        // executable bit. Verifying the binary is the bundled one (inside our
        // bundle, not a symlink, with a valid code signature) is out of scope here.
    }

    /// `posix_spawn` the child in a fresh process group with clean fds.
    private func spawn(
        launch: ProcessLaunch,
        stdoutWrite: Int32,
        stderrWrite: Int32,
        stdoutRead: Int32,
        stderrRead: Int32
    ) throws -> pid_t {
        let executablePath = launch.executableURL.path

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Deterministic, non-interactive stdin.
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // Wire the pipe write ends onto the child's stdout/stderr.
        posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO)
        // Belt-and-suspenders: explicitly close the read ends and the original
        // write fds in the child (CLOEXEC_DEFAULT already closes them on exec).
        posix_spawn_file_actions_addclose(&fileActions, stdoutRead)
        posix_spawn_file_actions_addclose(&fileActions, stderrRead)
        posix_spawn_file_actions_addclose(&fileActions, stdoutWrite)
        posix_spawn_file_actions_addclose(&fileActions, stderrWrite)
        if let cwd = launch.currentDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd.path)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Reset every signal to its default disposition in the child. A parent
        // that has *ignored* a signal (SIG_IGN) passes that ignore through exec —
        // e.g. a host/test harness that ignores SIGINT would make the child immune
        // to our interrupt/terminate, so it must be reset or cancellation silently
        // fails.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        // Also unblock every signal in the child: a blocked signal (inherited
        // sigmask, e.g. from the Swift runtime/test harness threads) stays pending
        // rather than being delivered, which would likewise defeat cancellation.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        // New process group (leader == child) + reset signals + no fd leaks.
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
            | Int16(POSIX_SPAWN_SETSIGDEF)
            | Int16(POSIX_SPAWN_SETSIGMASK)
            | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0) // 0 => new group, PGID == child PID

        let environment = ProcessEnvironment.resolve(launch.environment)

        // Build argv / envp as NUL-terminated C string arrays.
        let argvStrings = [executablePath] + launch.arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executablePath, &fileActions, &attr, argv, envp)
        guard rc == 0 else {
            throw ProcessRunnerError.launchFailed(
                "posix_spawn failed: \(String(cString: strerror(rc)))"
            )
        }
        return pid
    }

    /// Reap the child on a dedicated queue and report its exit to the coordinator.
    ///
    /// Reaping the parent PID is what confirms its death to the OS (the analogue of
    /// `Process.terminationHandler`); the coordinator turns that plus both pipe
    /// EOFs into the final `.exit`.
    private func startReaper(pid: pid_t, coordinator: RunCoordinator) {
        let queue = DispatchQueue(label: "com.grably.process.wait")
        queue.async {
            var status: Int32 = 0
            while true {
                let r = waitpid(pid, &status, 0)
                if r == -1 && errno == EINTR { continue }
                break
            }
            let code: Int32
            let reason: ProcessTerminationReason
            if (status & 0x7F) == 0 {
                // WIFEXITED: low 7 bits zero.
                code = (status >> 8) & 0xFF // WEXITSTATUS
                reason = .exited
            } else {
                // WIFSIGNALED: low 7 bits are the terminating signal.
                code = status & 0x7F // WTERMSIG
                reason = .uncaughtSignal
            }
            coordinator.markTerminated(code: code, reason: reason)
        }
    }

    /// Drain a pipe's read end on a dedicated serial queue, yielding one event per
    /// completed line.
    ///
    /// Uses a blocking `read(upToCount:)` loop rather than `readabilityHandler`: it
    /// gives deterministic EOF delivery and never races the reaper over the same
    /// file handle. Critically, `read(upToCount:)` throws a *Swift* error on
    /// `EBADF`/broken-pipe rather than raising the uncatchable
    /// `NSFileHandleOperationException` that `availableData` throws — so a torn-down
    /// fd can never crash the whole app; it is simply treated as EOF.
    private func startReader(
        readFD: Int32,
        label: String,
        makeEvent: @escaping @Sendable (String) -> ProcessEvent,
        onEOF: @escaping @Sendable () -> Void,
        coordinator: RunCoordinator,
        handle: ProcessHandle,
        continuation: AsyncStream<ProcessEvent>.Continuation
    ) {
        let readEnd = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        let tokenizer = TokenizerBox()
        let queue = DispatchQueue(label: label)
        queue.async {
            while true {
                let chunk: Data?
                do {
                    chunk = try readEnd.read(upToCount: 64 * 1024)
                } catch {
                    break // EBADF / broken pipe → treat as EOF.
                }
                guard let chunk, !chunk.isEmpty else { break } // nil/empty => EOF.
                for line in tokenizer.push(chunk) {
                    continuation.yield(makeEvent(line))
                }
                if coordinator.recordBytes(chunk.count) {
                    // Per-run output cap tripped: stop the process and this reader.
                    // The other pipe then EOFs and `.exit` is still delivered.
                    handle.terminate()
                    break
                }
            }
            if let tail = tokenizer.finish() {
                continuation.yield(makeEvent(tail))
            }
            onEOF()
        }
    }
}
