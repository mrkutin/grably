import Foundation
import Testing
@testable import GrablyCore

// MARK: - Offline: mock yt-dlp shell scripts driven through the real ProcessRunner

@Suite("YTDLPClient (offline, scripted)")
struct YTDLPClientOfflineTests {

    /// A temp bin dir whose `yt-dlp` is `script`; ffmpeg/ffprobe are inert stubs.
    private func makeBinaries(script: String) throws -> (ResolvedBinaries, cleanup: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try Data(script.utf8).write(to: ytDlp)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: ytDlp.path
        )
        let ffmpeg = dir.appendingPathComponent("ffmpeg")
        let ffprobe = dir.appendingPathComponent("ffprobe")
        try Data("stub".utf8).write(to: ffmpeg)
        try Data("stub".utf8).write(to: ffprobe)

        let binaries = ResolvedBinaries(
            ytDlp: ytDlp, ffmpeg: ffmpeg, ffprobe: ffprobe, ffmpegDirectory: dir
        )
        return (binaries, dir)
    }

    private func makeDestination() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let probeURL = URL(string: "https://example.com/watch?v=abc")!

    // MARK: probe

    @Test("probe decodes a single-video JSON payload")
    func probeSuccess() async throws {
        let script = """
        #!/bin/sh
        cat <<'EOF'
        {"id":"abc123","title":"Test Video","formats":[{"format_id":"18","ext":"mp4"}]}
        EOF
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        let info = try await client.probe(url: probeURL)

        #expect(info.id == "abc123")
        #expect(info.title == "Test Video")
        #expect(info.formats.count == 1)
    }

    @Test("probe maps a playlist payload to ProbeError.playlist")
    func probePlaylist() async throws {
        let script = """
        #!/bin/sh
        echo '{"_type":"playlist","entries":[]}'
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: MediaInfo.ProbeError.playlist) {
            _ = try await client.probe(url: probeURL)
        }
    }

    @Test("probe surfaces stderr on a non-zero exit")
    func probeFailure() async throws {
        let script = """
        #!/bin/sh
        echo 'ERROR: Private video. Sign in if you have been granted access.' 1>&2
        exit 1
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        do {
            _ = try await client.probe(url: probeURL)
            Issue.record("expected a ProbeError")
        } catch let MediaInfo.ProbeError.failed(message) {
            #expect(message.contains("Private video"))
        }
    }

    @Test("probe rejects a non-http(s) URL before launching")
    func probeRejectsBadScheme() async throws {
        let script = "#!/bin/sh\necho '{}'\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: RequestValidationError.self) {
            _ = try await client.probe(url: URL(string: "file:///etc/passwd")!)
        }
    }

    // MARK: download

    @Test("download parses progress, phase and returns the final path")
    func downloadSuccess() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        let script = """
        #!/bin/sh
        echo 'PROGRESS downloading 10 100 NA NA NA'
        echo 'PROGRESS downloading 55 100 NA 2000 3'
        echo '[Merger] Merging formats'
        echo 'PROGRESS finished 100 100 NA NA NA'
        : > "\(dest.path)/video.mp4"
        echo 'FINALPATH \(dest.path)/video.mp4'
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())

        let progress = Collector<DownloadProgress>()
        let phases = Collector<String>()
        let finalURL = try await client.download(
            request,
            progress: { progress.append($0) },
            phase: { phases.append($0) }
        )

        #expect(finalURL.path == "\(dest.path)/video.mp4")
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(progress.values().count == 3)
        #expect(progress.values().last?.status == "finished")
        #expect(phases.values() == ["Объединение…"])
    }

    @Test("download refuses a final path outside the destination (pathEscape)")
    func downloadPathEscape() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        let script = """
        #!/bin/sh
        echo 'FINALPATH /tmp/grably-escape.mp4'
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())

        do {
            _ = try await client.download(request, progress: { _ in }, phase: { _ in })
            Issue.record("expected pathEscape")
        } catch let DownloadError.pathEscape(url) {
            #expect(url.lastPathComponent == "grably-escape.mp4")
        }
    }

    @Test("download without a FINALPATH throws missingFinalPath")
    func downloadMissingFinalPath() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        let script = "#!/bin/sh\necho 'PROGRESS finished 100 100 NA NA NA'\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: DownloadError.missingFinalPath) {
            _ = try await client.download(request, progress: { _ in }, phase: { _ in })
        }
    }

    @Test("Cancelling the download task terminates the process cooperatively")
    func downloadCancellation() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        let script = "#!/bin/sh\nsleep 30\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())

        let task = Task { () -> URL in
            try await client.download(request, progress: { _ in }, phase: { _ in })
        }
        // Let the process actually start, then cancel.
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()

        let start = ContinuousClock.now
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(start.duration(to: .now) < .seconds(5), "cancellation should be prompt")
    }

    // MARK: probe — edge cases

    @Test("Cancelling the probe task terminates the process promptly")
    func probeCancellation() async throws {
        let script = "#!/bin/sh\nsleep 30\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        let task = Task { () -> MediaInfo in try await client.probe(url: probeURL) }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()

        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test("probe with exit 0 but empty stdout throws ProbeError.failed")
    func probeEmptyStdout() async throws {
        let script = "#!/bin/sh\nexit 0\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: MediaInfo.ProbeError.self) {
            _ = try await client.probe(url: probeURL)
        }
    }

    @Test("probe with exit 0 but garbage stdout throws ProbeError.failed")
    func probeGarbageStdout() async throws {
        let script = "#!/bin/sh\necho 'this is not json at all'\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: MediaInfo.ProbeError.self) {
            _ = try await client.probe(url: probeURL)
        }
    }

    @Test("probe honors a wall-clock timeout on a hung process")
    func probeTimeout() async throws {
        let script = "#!/bin/sh\nsleep 10\n" // no output, never exits in time
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = YTDLPClient(
            binaries: binaries, runner: ProcessRunner(),
            probeTimeout: .milliseconds(400)
        )
        let start = ContinuousClock.now
        do {
            _ = try await client.probe(url: probeURL)
            Issue.record("expected a timeout ProbeError")
        } catch let MediaInfo.ProbeError.failed(message) {
            #expect(message.contains("ожидания"), "should be a Russian timeout message")
        }
        #expect(start.duration(to: .now) < .seconds(5), "timeout should fire promptly")
    }

    // MARK: download — edge cases

    @Test("download honors a no-progress stall timeout")
    func downloadStallTimeout() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        // One line, then long silence: the inactivity watchdog must fire.
        let script = """
        #!/bin/sh
        echo 'PROGRESS downloading 1 100 NA NA NA'
        sleep 10
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(
            binaries: binaries, runner: ProcessRunner(),
            downloadStallTimeout: .milliseconds(400)
        )
        let start = ContinuousClock.now
        await #expect(throws: DownloadError.timedOut) {
            _ = try await client.download(request, progress: { _ in }, phase: { _ in })
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test("download killed by a foreign signal (not our cancellation) fails, not cancelled")
    func downloadForeignSignal() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        let script = "#!/bin/sh\nkill -9 $$\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        do {
            _ = try await client.download(request, progress: { _ in }, phase: { _ in })
            Issue.record("expected a failure")
        } catch let DownloadError.failed(code, _) {
            #expect(code == 9)
        }
    }

    @Test("Cancellation sweeps leftover .part files from the destination")
    func cancellationSweepsPartials() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        // The mock creates the `.part` at process start, then blocks. (We poll the
        // file rather than a progress line: `/bin/sh` block-buffers its stdout to a
        // pipe, so an `echo`d line would not surface until the process exits.)
        let script = """
        #!/bin/sh
        : > "\(dest.path)/video.mp4.part"
        sleep 30
        """
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())

        let task = Task { () -> URL in
            try await client.download(request, progress: { _ in }, phase: { _ in })
        }
        // Generous window: the file is created at process start, but the machine is
        // under heavy parallel-test load.
        let partial = dest.appendingPathComponent("video.mp4.part")
        var appeared = false
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: partial.path) { appeared = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(appeared, "the mock should have created a .part file")

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(
            !FileManager.default.fileExists(atPath: partial.path),
            "cancellation should have swept the .part file"
        )
    }

    // MARK: verifyInside — leaf & directory-component symlinks

    @Test("A symlinked final leaf inside the destination is rejected (pathEscape)")
    func rejectsSymlinkLeaf() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        // Plant a symlink at the exact predictable output path pointing outside.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let leaf = dest.appendingPathComponent("video.mp4")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: outside)

        let script = "#!/bin/sh\necho 'FINALPATH \(dest.path)/video.mp4'\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: DownloadError.pathEscape(leaf)) {
            _ = try await client.download(request, progress: { _ in }, phase: { _ in })
        }
    }

    @Test("A symlinked directory component inside the destination is rejected (pathEscape)")
    func rejectsSymlinkDirectoryComponent() async throws {
        let dest = try makeDestination()
        defer { try? FileManager.default.removeItem(at: dest) }

        // `dest/sub` is a symlink to an outside directory; the final path lives
        // under it, so its canonical parent escapes the destination.
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("odir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let sub = dest.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outsideDir)
        try Data("x".utf8).write(to: outsideDir.appendingPathComponent("video.mp4"))

        let script = "#!/bin/sh\necho 'FINALPATH \(dest.path)/sub/video.mp4'\n"
        let (binaries, dir) = try makeBinaries(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }

        let request = DownloadRequest(
            url: URL(string: "https://example.com/v")!, destinationDirectory: dest
        )
        let client = YTDLPClient(binaries: binaries, runner: ProcessRunner())
        await #expect(throws: DownloadError.self) {
            _ = try await client.download(request, progress: { _ in }, phase: { _ in })
        }
    }
}

/// Thread-safe collector for values pushed from `@Sendable` callbacks.
private final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    func values() -> [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - Online: real yt-dlp/ffmpeg against the network (gated)

@Suite("YTDLPClient (online)", .enabled(if: ProcessInfo.processInfo.environment["GRABLY_ONLINE_TESTS"] == "1"))
struct YTDLPClientOnlineTests {

    /// Resolve the real bundled binaries. Uses `GRABLY_BIN_DIR` if set, otherwise
    /// derives `<repo>/Resources/bin` from this test file's location.
    private static func binDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["GRABLY_BIN_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // → repo root
        return url.appendingPathComponent("Resources/bin", isDirectory: true)
    }

    private func makeClient() async throws -> YTDLPClient {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("online-\(UUID().uuidString)", isDirectory: true)
        let provisioner = BinaryProvisioner(
            sourceDirectory: Self.binDirectory(), supportDirectory: support
        )
        let binaries = try await provisioner.resolve()
        return YTDLPClient(binaries: binaries, runner: ProcessRunner())
    }

    // A reliably-available public video (overridable via GRABLY_TEST_URL).
    private var testVideo: URL {
        if let override = ProcessInfo.processInfo.environment["GRABLY_TEST_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
    }

    @Test("Real probe returns MediaInfo with formats")
    func realProbe() async throws {
        let client = try await makeClient()
        let info = try await client.probe(url: testVideo)
        #expect(!info.id.isEmpty)
        #expect(!info.title.isEmpty)
        #expect(!info.formats.isEmpty)
    }

    @Test("Real download writes a file inside the destination with progress")
    func realDownload() async throws {
        let client = try await makeClient()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let request = DownloadRequest(
            url: testVideo, kind: .audio(codec: .m4a), destinationDirectory: dest
        )
        let progress = Collector<DownloadProgress>()
        let finalURL = try await client.download(
            request, progress: { progress.append($0) }, phase: { _ in }
        )

        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(finalURL.path.hasPrefix(dest.path))
        #expect(!progress.values().isEmpty, "progress callbacks should have fired")
        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int) ?? 0
        #expect(size > 0)
    }
}
