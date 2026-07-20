import Darwin
import Foundation
import Testing
@testable import GrablyCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    // MARK: - Helpers

    private struct TimeoutError: Error {}

    /// Drain a process event stream to completion, failing the test rather than
    /// hanging if the process (or our finalisation) never terminates.
    private func collect(
        _ stream: AsyncStream<ProcessEvent>,
        timeout: Duration = .seconds(10)
    ) async throws -> [ProcessEvent] {
        try await withThrowingTaskGroup(of: [ProcessEvent].self) { group in
            group.addTask {
                var events: [ProcessEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            let events = try await group.next()!
            group.cancelAll()
            return events
        }
    }

    private func stdoutLines(_ events: [ProcessEvent]) -> [String] {
        events.compactMap { if case let .stdoutLine(line) = $0 { return line } else { return nil } }
    }

    private func stderrLines(_ events: [ProcessEvent]) -> [String] {
        events.compactMap { if case let .stderrLine(line) = $0 { return line } else { return nil } }
    }

    private func exitEvent(_ events: [ProcessEvent]) -> (code: Int32, reason: ProcessTerminationReason)? {
        for event in events {
            if case let .exit(code, reason) = event { return (code, reason) }
        }
        return nil
    }

    private func launch(_ path: String, _ args: [String]) -> ProcessLaunch {
        ProcessLaunch(executableURL: URL(fileURLWithPath: path), arguments: args)
    }

    // MARK: - Tests

    @Test("Single line of stdout, then exit(0), then stream ends")
    func singleLine() async throws {
        let runner = ProcessRunner()
        let (events, _) = try await runner.run(launch("/bin/echo", ["hello"]))
        let collected = try await collect(events)

        #expect(stdoutLines(collected) == ["hello"])
        let exit = exitEvent(collected)
        #expect(exit?.code == 0)
        #expect(exit?.reason == .exited)
        // .exit is the final event and the stream is closed (collect returned).
        if case .exit = collected.last {} else {
            Issue.record("last event was not .exit: \(collected)")
        }
    }

    @Test("Multi-line stdout preserves order")
    func multiLine() async throws {
        let runner = ProcessRunner()
        let (events, _) = try await runner.run(launch("/bin/sh", ["-c", "printf 'a\\nb\\nc\\n'"]))
        let collected = try await collect(events)

        #expect(stdoutLines(collected) == ["a", "b", "c"])
        #expect(exitEvent(collected)?.code == 0)
    }

    @Test("stdout and stderr are separated")
    func stdoutAndStderrSeparated() async throws {
        let runner = ProcessRunner()
        let (events, _) = try await runner.run(launch("/bin/sh", ["-c", "echo out; echo err 1>&2"]))
        let collected = try await collect(events)

        #expect(stdoutLines(collected) == ["out"])
        #expect(stderrLines(collected) == ["err"])
        #expect(exitEvent(collected)?.reason == .exited)
    }

    @Test("Non-zero exit code is reported")
    func nonZeroExit() async throws {
        let runner = ProcessRunner()
        let (events, _) = try await runner.run(launch("/bin/sh", ["-c", "exit 3"]))
        let collected = try await collect(events)

        let exit = exitEvent(collected)
        #expect(exit?.code == 3)
        #expect(exit?.reason == .exited)
    }

    @Test("Carriage-return progress lines surface individually")
    func carriageReturnProgress() async throws {
        let runner = ProcessRunner()
        // yt-dlp emits progress as `\r`-separated in-place updates on one visual
        // line; the tokenizer must split each into its own event.
        let script = #"printf 'PROGRESS downloading 10 100\rPROGRESS downloading 50 100\rPROGRESS downloading 100 100\n'"#
        let (events, _) = try await runner.run(launch("/bin/sh", ["-c", script]))
        let collected = try await collect(events)

        #expect(stdoutLines(collected) == [
            "PROGRESS downloading 10 100",
            "PROGRESS downloading 50 100",
            "PROGRESS downloading 100 100",
        ])
        #expect(exitEvent(collected)?.code == 0)
    }

    @Test("interrupt() terminates a long-running process promptly")
    func interruptCancels() async throws {
        let runner = ProcessRunner()
        let (events, handle) = try await runner.run(launch("/bin/sh", ["-c", "sleep 30"]))

        // Let the process actually start before signalling, so the test is
        // deterministic rather than racing the launch.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            handle.interrupt()
        }

        let collected = try await collect(events, timeout: .seconds(5))
        let exit = exitEvent(collected)
        #expect(exit != nil)
        #expect(exit?.reason == .uncaughtSignal)
        if case .exit = collected.last {} else {
            Issue.record("last event was not .exit: \(collected)")
        }
    }

    @Test("terminate() after the process is dead is a no-op")
    func terminateAfterDeathIsNoOp() async throws {
        let runner = ProcessRunner()
        let (events, handle) = try await runner.run(launch("/bin/echo", ["done"]))
        let collected = try await collect(events)
        #expect(exitEvent(collected)?.code == 0)

        // Process has already exited and the stream is closed. These must not
        // crash and must not resurrect any events.
        handle.terminate()
        handle.terminate()
        handle.interrupt()
    }

    @Test("Exit is the last event and totals are complete")
    func orderingAndCompleteness() async throws {
        let runner = ProcessRunner()
        let (events, _) = try await runner.run(
            launch("/bin/sh", ["-c", "printf 'l1\\nl2\\nl3\\nl4\\nl5\\n'"])
        )
        let collected = try await collect(events)

        #expect(stdoutLines(collected) == ["l1", "l2", "l3", "l4", "l5"])
        // Exactly one exit event, and it is last.
        let exitCount = collected.reduce(into: 0) { count, event in
            if case .exit = event { count += 1 }
        }
        #expect(exitCount == 1)
        if case .exit = collected.last {} else {
            Issue.record("last event was not .exit")
        }
    }

    @Test("Missing executable throws executableNotFound")
    func missingExecutableThrows() async throws {
        let runner = ProcessRunner()
        let missing = URL(fileURLWithPath: "/nonexistent/definitely/not/here")
        await #expect(throws: ProcessRunnerError.executableNotFound(missing)) {
            _ = try await runner.run(ProcessLaunch(executableURL: missing))
        }
    }

    /// Poll `kill(pid, 0)` until the process is gone (`ESRCH`) or we time out.
    private func waitUntilGone(_ pid: pid_t, attempts: Int = 60) async -> Bool {
        for _ in 0..<attempts {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test("Cancelling the consuming task kills the process and unblocks readers (A1)")
    func cancelConsumerKillsProcess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")

        let runner = ProcessRunner()
        // Write our PID to a file, then sleep far past the test window.
        let (events, _) = try await runner.run(
            launch("/bin/sh", ["-c", "echo $$ > \(pidFile.path); exec sleep 30"])
        )

        // Consume in a task; cancelling it fires the stream's onTermination, which
        // must tear the whole process group down.
        let consumer = Task {
            for await _ in events {}
        }

        // Wait until the child has recorded its PID, then cancel.
        var childPID: pid_t?
        for _ in 0..<50 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let pid = try #require(childPID)
        consumer.cancel()

        let gone = await waitUntilGone(pid)
        #expect(gone, "process \(pid) should have been killed when the consumer was cancelled")
    }

    @Test("A backgrounded grandchild holding the pipe does not hang the stream (A2)")
    func grandchildDoesNotHang() async throws {
        let runner = ProcessRunner()
        // sh backgrounds `sleep 5` (which inherits the stdout write end), prints
        // `done`, then exits. The grandchild would keep the pipe open for 5s and
        // block EOF forever were it not for the process-group watchdog, which
        // force-kills the group ~2s after the parent is reaped.
        let (events, _) = try await runner.run(
            launch("/bin/sh", ["-c", "sleep 5 & echo done"])
        )
        // Timeout below 5s but above the 2s watchdog grace proves the watchdog
        // (not the grandchild's natural exit) unblocked us.
        let collected = try await collect(events, timeout: .seconds(4))

        #expect(stdoutLines(collected).contains("done"))
        let exit = exitEvent(collected)
        #expect(exit?.code == 0)
        #expect(exit?.reason == .exited)
        if case .exit = collected.last {} else {
            Issue.record("last event was not .exit: \(collected)")
        }
    }

    @Test("Concurrent interrupt() and terminate() from different tasks do not crash")
    func concurrentSignals() async throws {
        let runner = ProcessRunner()
        let (events, handle) = try await runner.run(launch("/bin/sh", ["-c", "sleep 30"]))

        Task.detached {
            try? await Task.sleep(for: .milliseconds(120))
            handle.interrupt()
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(120))
            handle.terminate()
        }

        let collected = try await collect(events, timeout: .seconds(5))
        #expect(exitEvent(collected) != nil)
    }

    @Test("A +x file that is not a valid executable throws launchFailed")
    func launchFailedForNonBinary() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("bogus")
        try Data("not a real binary\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let runner = ProcessRunner()
        do {
            _ = try await runner.run(ProcessLaunch(executableURL: file))
            Issue.record("expected launchFailed")
        } catch let ProcessRunnerError.launchFailed(message) {
            #expect(!message.isEmpty)
        }
    }

    @Test("A file without the executable bit throws notExecutable")
    func notExecutableThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("plain")
        try Data("hi".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let runner = ProcessRunner()
        await #expect(throws: ProcessRunnerError.notExecutable(file)) {
            _ = try await runner.run(ProcessLaunch(executableURL: file))
        }
    }

    @Test("An unterminated trailing stderr line is flushed at EOF")
    func stderrTailFlushed() async throws {
        let runner = ProcessRunner()
        let (events, _) = try await runner.run(
            launch("/bin/sh", ["-c", #"printf 'no newline' 1>&2"#])
        )
        let collected = try await collect(events)
        #expect(stderrLines(collected) == ["no newline"])
        #expect(exitEvent(collected)?.code == 0)
    }

    private func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    @Test("Repeated runs do not leak file descriptors")
    func noFDLeakAcrossRuns() async throws {
        let runner = ProcessRunner()
        // Warm up so one-time allocations don't count against the baseline.
        for _ in 0..<3 {
            let (events, _) = try await runner.run(launch("/bin/echo", ["warmup"]))
            _ = try await collect(events)
        }
        let baseline = openFDCount()

        for _ in 0..<25 {
            let (events, _) = try await runner.run(launch("/bin/sh", ["-c", "echo x; echo y 1>&2"]))
            _ = try await collect(events)
        }
        // Give the reader/reaper queues a beat to release their FileHandles.
        try await Task.sleep(for: .milliseconds(200))
        let after = openFDCount()

        // A per-run leak of even one pipe pair would add ~50 fds over 25 runs; a
        // small slack absorbs unrelated runtime fd churn.
        #expect(after - baseline < 10, "fd count grew from \(baseline) to \(after)")
    }

    @Test("Base environment carries PATH and forced UTF-8 locale")
    func baseEnvironment() {
        let env = ProcessEnvironment.base()
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["LC_ALL"] == "en_US.UTF-8")
        #expect(env["PYTHONIOENCODING"] == "utf-8")

        let extra = ProcessEnvironment.base(extraPATH: ["/opt/grably/bin"])
        #expect(extra["PATH"] == "/opt/grably/bin:/usr/bin:/bin:/usr/sbin:/sbin")

        // A caller-supplied environment is respected but the locale is forced on.
        let resolved = ProcessEnvironment.resolve(["PATH": "/custom", "LC_ALL": "C"])
        #expect(resolved["PATH"] == "/custom")
        #expect(resolved["LC_ALL"] == "en_US.UTF-8")
        #expect(resolved["PYTHONIOENCODING"] == "utf-8")
    }
}
