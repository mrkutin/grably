import CryptoKit
import Darwin
import Foundation
import Testing
@testable import GrablyCore

// MARK: - URLSession stubbing

/// Thread-safe, path-aware registry of canned responses. Rules are matched in
/// insertion order (first match wins); the suite is `.serialized` so no two tests
/// share it. Path awareness matters because a single `update()` now fetches three
/// distinct resources — the release metadata, the binary, and its `SHA2-256SUMS` —
/// two of which live on the same host.
private final class StubRegistry: @unchecked Sendable {
    struct Response {
        var statusCode: Int
        var data: Data?
        var failsWithNetworkError: Bool = false
        /// If set, emit a redirect (status should be 3xx) to this URL instead.
        var redirectTo: URL?
    }

    private struct Rule {
        let match: @Sendable (URL) -> Bool
        let response: Response
    }

    private let lock = NSLock()
    private var rules: [Rule] = []

    static let shared = StubRegistry()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        rules.removeAll()
    }

    func add(_ response: Response, when match: @escaping @Sendable (URL) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        rules.append(Rule(match: match, response: response))
    }

    func response(for url: URL?) -> Response? {
        guard let url else { return nil }
        lock.lock(); defer { lock.unlock() }
        return rules.first(where: { $0.match(url) })?.response
    }
}

/// A `URLProtocol` that serves responses from ``StubRegistry`` so the updater's
/// real `URLSession` code path — including redirect following — is exercised
/// without touching the network.
private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = StubRegistry.shared.response(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if stub.failsWithNetworkError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let location = stub.redirectTo {
            let response = HTTPURLResponse(
                url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["Location": location.absoluteString]
            )!
            var redirected = URLRequest(url: location)
            if let agent = request.value(forHTTPHeaderField: "User-Agent") {
                redirected.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            // The URL Loading System restarts the load for the new request through
            // this same protocol, so a rule for `location` will serve the body.
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = stub.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("YTDLPUpdater", .serialized)
struct YTDLPUpdaterTests {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write an executable `/bin/sh` script that prints `version` on `--version`
    /// (it ignores its argument and just echoes) at `url`.
    private func writeVersionScript(at url: URL, version: String, exitCode: Int = 0) throws {
        let content = """
        #!/bin/sh
        echo "\(version)"
        exit \(exitCode)
        """
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    /// Build a >5 MiB self-contained script body that prints `version` — used as the
    /// fake "downloaded" binary so post-install verification succeeds.
    private func launchableBinaryData(version: String) -> Data {
        let head = "#!/bin/sh\necho \"\(version)\"\nexit 0\n"
        let padding = "#" + String(repeating: "A", count: 6 * 1024 * 1024)
        return Data((head + padding).utf8)
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeUpdater(
        ytDlp: URL,
        session: URLSession,
        minBytes: Int = YTDLPUpdater.defaultMinBinaryBytes,
        maxBytes: Int = YTDLPUpdater.defaultMaxBinaryBytes
    ) -> YTDLPUpdater {
        YTDLPUpdater(
            ytDlpURL: ytDlp, runner: ProcessRunner(), session: session,
            minBinaryBytes: minBytes, maxBinaryBytes: maxBytes
        )
    }

    // MARK: - Stub helpers

    private func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A valid `SHA2-256SUMS` manifest for `binary` (plus a decoy line to prove the
    /// parser selects the right entry).
    private func sumsManifest(for binary: Data, name: String = "yt-dlp_macos") -> String {
        """
        \(String(repeating: "0", count: 64))  yt-dlp
        \(hexSHA256(binary))  \(name)
        \(String(repeating: "f", count: 64))  yt-dlp.exe
        """
    }

    private func stubRelease(tag: String) {
        StubRegistry.shared.add(
            .init(statusCode: 200, data: Data(#"{"tag_name":"\#(tag)"}"#.utf8)),
            when: { $0.host == "api.github.com" }
        )
    }

    private func stubBinary(_ data: Data, host: String = "github.com") {
        StubRegistry.shared.add(
            .init(statusCode: 200, data: data),
            when: { $0.host == host && $0.lastPathComponent == "yt-dlp_macos" }
        )
    }

    private func stubSums(_ text: String, host: String = "github.com") {
        StubRegistry.shared.add(
            .init(statusCode: 200, data: Data(text.utf8)),
            when: { $0.host == host && $0.lastPathComponent == "SHA2-256SUMS" }
        )
    }

    /// Wire up a complete, self-consistent release (tag + binary + matching sums).
    private func stubConsistentRelease(tag: String, binary: Data) {
        StubRegistry.shared.reset()
        stubRelease(tag: tag)
        stubBinary(binary)
        stubSums(sumsManifest(for: binary))
    }

    // MARK: - Version parsing / comparison (pure)

    @Test("parseVersion trims, drops leading v, keeps first token")
    func parseVersionNormalises() {
        #expect(YTDLPUpdater.parseVersion("  2026.06.09\n") == "2026.06.09")
        #expect(YTDLPUpdater.parseVersion("v2026.06.09") == "2026.06.09")
        #expect(YTDLPUpdater.parseVersion("2026.06.09 (extra)") == "2026.06.09")
        #expect(YTDLPUpdater.parseVersion("") == "")
    }

    @Test("isNewer compares date-based versions component-wise")
    func versionComparison() {
        #expect(YTDLPUpdater.isNewer("2026.07.01", than: "2026.06.09"))
        #expect(YTDLPUpdater.isNewer("2026.06.09.1", than: "2026.06.09"))
        #expect(!YTDLPUpdater.isNewer("2026.06.09", than: "2026.06.09"))
        #expect(!YTDLPUpdater.isNewer("2026.06.09", than: "2026.07.01"))
    }

    @Test("expectedChecksum selects the yt-dlp_macos line and validates the hex")
    func checksumParsing() {
        let manifest = """
        1111111111111111111111111111111111111111111111111111111111111111  yt-dlp
        2222222222222222222222222222222222222222222222222222222222222222  yt-dlp_macos
        """
        #expect(
            YTDLPUpdater.expectedChecksum(from: manifest, fileName: "yt-dlp_macos")
                == "2222222222222222222222222222222222222222222222222222222222222222"
        )
        // Binary-mode marker (`*`) on the filename is tolerated.
        let marked = "3333333333333333333333333333333333333333333333333333333333333333 *yt-dlp_macos"
        #expect(
            YTDLPUpdater.expectedChecksum(from: marked, fileName: "yt-dlp_macos")
                == "3333333333333333333333333333333333333333333333333333333333333333"
        )
        // A too-short / non-hex digest is rejected.
        #expect(YTDLPUpdater.expectedChecksum(from: "abc  yt-dlp_macos", fileName: "yt-dlp_macos") == nil)
        #expect(YTDLPUpdater.expectedChecksum(from: "no entry here  other", fileName: "yt-dlp_macos") == nil)
    }

    // MARK: - currentVersion

    @Test("currentVersion parses yt-dlp --version output")
    func currentVersionParses() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        let version = try await updater.currentVersion()
        #expect(version == "2026.06.09")
    }

    @Test("currentVersion throws versionUnavailable on non-zero exit")
    func currentVersionNonZero() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "", exitCode: 3)

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.versionUnavailable) {
            _ = try await updater.currentVersion()
        }
    }

    // MARK: - latestVersion

    @Test("latestVersion parses tag_name from the GitHub API")
    func latestVersionParses() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        let latest = try await updater.latestVersion()
        #expect(latest == "2026.07.01")
    }

    @Test("latestVersion maps a non-200 status to serverUnavailable")
    func latestVersionServerError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        StubRegistry.shared.add(
            .init(statusCode: 503, data: Data()), when: { $0.host == "api.github.com" }
        )
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.serverUnavailable(503)) {
            _ = try await updater.latestVersion()
        }
    }

    @Test("latestVersion maps a transport error to networkUnavailable")
    func latestVersionNetworkError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        StubRegistry.shared.add(
            .init(statusCode: 0, data: nil, failsWithNetworkError: true),
            when: { $0.host == "api.github.com" }
        )
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.networkUnavailable) {
            _ = try await updater.latestVersion()
        }
    }

    @Test("latestVersion throws invalidResponse when tag_name is missing")
    func latestVersionInvalidBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        StubRegistry.shared.add(
            .init(statusCode: 200, data: Data(#"{"name":"x"}"#.utf8)),
            when: { $0.host == "api.github.com" }
        )
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.invalidResponse) {
            _ = try await updater.latestVersion()
        }
    }

    // MARK: - checkForUpdate

    @Test("checkForUpdate reports upToDate when versions match")
    func checkUpToDate() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.07.01")

        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        let status = try await updater.checkForUpdate()
        #expect(status == .upToDate("2026.07.01"))
    }

    @Test("checkForUpdate reports updateAvailable when a newer release exists")
    func checkUpdateAvailable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        let status = try await updater.checkForUpdate()
        #expect(status == .updateAvailable(current: "2026.06.09", latest: "2026.07.01"))
    }

    // MARK: - update (happy path)

    @Test("update downloads, verifies the checksum, swaps, and re-probes")
    func updateHappyPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        let binary = launchableBinaryData(version: "2026.07.01")
        stubConsistentRelease(tag: "2026.07.01", binary: binary)

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        let newVersion = try await updater.update()
        #expect(newVersion == "2026.07.01")

        // The installed binary now reports the new version.
        #expect(try await updater.currentVersion() == "2026.07.01")
        // A version stamp was written for the provisioner to honour.
        let stamp = dir.appendingPathComponent(".yt-dlp.version")
        #expect(try String(contentsOf: stamp, encoding: .utf8) == "2026.07.01")
        // No staging/backup leftovers (the stamp is expected).
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".yt-dlp.") && $0 != ".yt-dlp.version" }
        #expect(leftovers.isEmpty)
    }

    @Test("update follows a github → CDN redirect for the binary")
    func updateFollowsRedirect() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        let binary = launchableBinaryData(version: "2026.07.01")
        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        stubSums(sumsManifest(for: binary))
        // github.com serves a 302 to the CDN; the CDN serves the bytes. The whole
        // security model leans on this redirect being followed, so exercise it.
        let cdn = URL(string: "https://objects.githubusercontent.com/dl/yt-dlp_macos")!
        StubRegistry.shared.add(
            .init(statusCode: 302, data: nil, redirectTo: cdn),
            when: { $0.host == "github.com" && $0.lastPathComponent == "yt-dlp_macos" }
        )
        stubBinary(binary, host: "objects.githubusercontent.com")

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        #expect(try await updater.update() == "2026.07.01")
    }

    @Test("update installs when no binary exists yet (moveItem branch)")
    func updateNoExistingBinary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp") // deliberately absent

        let binary = launchableBinaryData(version: "2026.07.01")
        stubConsistentRelease(tag: "2026.07.01", binary: binary)

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        #expect(try await updater.update() == "2026.07.01")
        #expect(FileManager.default.fileExists(atPath: ytDlp.path))
    }

    // MARK: - update (checksum)

    @Test("update rejects a checksum mismatch and leaves the old binary in place")
    func updateChecksumMismatch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")
        let originalContent = try Data(contentsOf: ytDlp)

        let binary = launchableBinaryData(version: "2026.07.01")
        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        stubBinary(binary)
        // A manifest whose hash does NOT match the downloaded bytes.
        stubSums("\(String(repeating: "a", count: 64))  yt-dlp_macos\n")

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.checksumMismatch) {
            _ = try await updater.update()
        }
        // The binary was not swapped, and no stamp/staging was written.
        #expect(try Data(contentsOf: ytDlp) == originalContent)
        #expect(try await updater.currentVersion() == "2026.06.09")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".yt-dlp.") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - update (size bounds)

    @Test("update rejects an implausibly small download as corruptedDownload")
    func updateTooSmall() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        stubBinary(Data(repeating: 0, count: 1024)) // below the 5 MiB floor
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.corruptedDownload) {
            _ = try await updater.update()
        }
        #expect(try await updater.currentVersion() == "2026.06.09")
    }

    @Test("update rejects an oversized download as corruptedDownload")
    func updateTooLarge() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        stubBinary(launchableBinaryData(version: "2026.07.01")) // ~6 MiB
        // Tight bounds so the ~6 MiB body exceeds the ceiling.
        let updater = makeUpdater(
            ytDlp: ytDlp, session: stubSession(), minBytes: 1024, maxBytes: 2 * 1024 * 1024
        )
        await #expect(throws: UpdaterError.corruptedDownload) {
            _ = try await updater.update()
        }
        #expect(try await updater.currentVersion() == "2026.06.09")
    }

    // MARK: - update (failure modes)

    @Test("update maps a transport error to networkUnavailable")
    func updateNetworkError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        StubRegistry.shared.reset()
        stubRelease(tag: "2026.07.01")
        StubRegistry.shared.add(
            .init(statusCode: 0, data: nil, failsWithNetworkError: true),
            when: { $0.host == "github.com" }
        )
        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.networkUnavailable) {
            _ = try await updater.update()
        }
    }

    @Test("update rolls back and throws verificationFailed when the new binary won't launch")
    func updateRollback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")
        let originalContent = try Data(contentsOf: ytDlp)

        // A large, non-executable blob passes the size + checksum checks but fails
        // to launch.
        let binary = Data(repeating: 0, count: 6 * 1024 * 1024)
        stubConsistentRelease(tag: "2026.07.01", binary: binary)

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        await #expect(throws: UpdaterError.verificationFailed) {
            _ = try await updater.update()
        }
        // The previous binary was restored intact.
        #expect(try Data(contentsOf: ytDlp) == originalContent)
        #expect(try await updater.currentVersion() == "2026.06.09")
    }

    @Test("update preserves the backup when both verification and rollback fail")
    func updateRollbackFailurePreservesBackup() async throws {
        let dir = try makeTempDir()
        // LIFO: this restore runs BEFORE the removeItem cleanup below, so the
        // (temporarily read-only) directory can be deleted.
        defer { _ = dir.path.withCString { chmod($0, 0o755) } }
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        // Passes size + checksum but fails to launch → verification fails.
        let binary = Data(repeating: 0, count: 6 * 1024 * 1024)
        stubConsistentRelease(tag: "2026.07.01", binary: binary)

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        // After the swap, make the directory read-only so the rollback's
        // `replaceItemAt` (and the recovery move) both fail.
        let dirPath = dir.path
        await updater.setAfterSwapHook {
            _ = dirPath.withCString { chmod($0, 0o500) }
        }

        var thrown: UpdaterError?
        do {
            _ = try await updater.update()
        } catch let error as UpdaterError {
            thrown = error
        }
        // Restore write access before inspecting/cleaning up.
        _ = dir.path.withCString { chmod($0, 0o755) }

        guard case .rollbackFailed = thrown else {
            Issue.record("expected rollbackFailed, got \(String(describing: thrown))")
            return
        }
        // The backup survives (under its backup or recovery name) — never deleted.
        let preserved = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".yt-dlp.backup.") || $0.hasPrefix(".yt-dlp.recovery.") }
        #expect(!preserved.isEmpty, "a failed rollback must not lose the backup")
    }

    // MARK: - Concurrency

    @Test("concurrent update() calls are serialized and both succeed")
    func concurrentUpdates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        let binary = launchableBinaryData(version: "2026.07.01")
        stubConsistentRelease(tag: "2026.07.01", binary: binary)

        let updater = makeUpdater(ytDlp: ytDlp, session: stubSession())
        async let first = updater.update()
        async let second = updater.update()
        let results = try await [first, second]
        #expect(results == ["2026.07.01", "2026.07.01"])
        #expect(try await updater.currentVersion() == "2026.07.01")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".yt-dlp.") && $0 != ".yt-dlp.version" }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Online (gated)

    @Test(
        "latestVersion returns a non-empty tag from the real GitHub API",
        .enabled(if: ProcessInfo.processInfo.environment["GRABLY_ONLINE_TESTS"] == "1")
    )
    func onlineLatestVersion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ytDlp = dir.appendingPathComponent("yt-dlp")
        try writeVersionScript(at: ytDlp, version: "2026.06.09")

        let updater = YTDLPUpdater(ytDlpURL: ytDlp, runner: ProcessRunner())
        let latest = try await updater.latestVersion()
        #expect(!latest.isEmpty)
    }
}
