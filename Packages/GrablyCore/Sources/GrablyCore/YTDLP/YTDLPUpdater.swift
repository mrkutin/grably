import CryptoKit
import Darwin
import Foundation
import os

/// The result of comparing the installed yt-dlp against the latest release.
public enum UpdateStatus: Sendable, Equatable {
    /// The installed version is current. Carries that version.
    case upToDate(String)
    /// A newer release exists. Carries the installed and available versions.
    case updateAvailable(current: String, latest: String)
}

/// Why a yt-dlp self-update operation failed. Every case carries a Russian,
/// user-facing description (via `LocalizedError`).
public enum UpdaterError: Error, Sendable, Equatable, LocalizedError {
    /// Could not reach the network at all (DNS/offline/connection refused).
    case networkUnavailable
    /// The server answered, but with a non-success HTTP status.
    case serverUnavailable(Int)
    /// The response body could not be parsed (missing/empty `tag_name`, bad JSON).
    case invalidResponse
    /// The downloaded binary is implausibly small/large or truncated.
    case corruptedDownload
    /// The downloaded binary's SHA-256 did not match the published checksum.
    case checksumMismatch
    /// yt-dlp could not report its version (spawn failed / non-zero exit / empty).
    case versionUnavailable
    /// The freshly installed binary does not launch; the previous one was restored.
    case verificationFailed
    /// Verification failed *and* the rollback failed; the previous binary is kept as
    /// a recovery file whose name is carried here.
    case rollbackFailed(String)
    /// A local filesystem operation (stage/replace/chmod) failed.
    case filesystem

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Нет подключения к интернету. Проверьте сеть и повторите."
        case let .serverUnavailable(code):
            return "Сервер обновлений недоступен (код \(code)). Повторите позже."
        case .invalidResponse:
            return "Некорректный ответ сервера обновлений."
        case .corruptedDownload:
            return "Загруженный файл повреждён. Повторите обновление."
        case .checksumMismatch:
            return "Контрольная сумма загруженного файла не совпала. Обновление отменено."
        case .versionUnavailable:
            return "Не удалось определить версию yt-dlp."
        case .verificationFailed:
            return "Обновлённый yt-dlp не запускается. Возвращена предыдущая версия."
        case let .rollbackFailed(name):
            return "Обновление не удалось, и не удалось вернуть предыдущую версию. "
                + "Резервная копия сохранена: \(name)."
        case .filesystem:
            return "Не удалось сохранить обновление на диск."
        }
    }
}

/// Keeps the installed yt-dlp executable up to date.
///
/// Two responsibilities:
/// - **version discovery** — the installed version (via `yt-dlp --version`) and the
///   latest published version (via the GitHub releases API), and their comparison;
/// - **updating** — a *direct download* of the official self-contained
///   `yt-dlp_macos` binary from GitHub, atomically swapped into place after a
///   size + SHA-256 check and a post-install launch verification (with rollback).
///
/// A direct download is used rather than `yt-dlp -U` because the latter rewrites the
/// executable in place with looser guarantees; here every step is validated and the
/// swap is atomic, matching ``BinaryProvisioner``'s trust model.
///
/// **Release pinning.** A single release *tag* is resolved once per `update()` and
/// used to fetch both the binary and its `SHA2-256SUMS` from
/// `.../releases/download/<tag>/…`. This keeps the version the user is told about,
/// the bytes downloaded, and the checksum verified all from the same release
/// (fetching from the moving `/latest/` target could otherwise desynchronise them).
///
/// Actor-isolated so the stage → checksum → chmod → strip-quarantine → replace →
/// verify sequence for the single shared executable never interleaves with itself.
public actor YTDLPUpdater {
    private let ytDlpURL: URL
    private let runner: ProcessRunner
    private let session: URLSession

    private static let log = Logger(subsystem: "com.grably.core", category: "updater")

    /// GitHub API endpoint for the newest release metadata.
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    )!
    /// File name of the universal macOS build inside a release.
    private static let macosBinaryName = "yt-dlp_macos"
    /// File name of the per-release SHA-256 manifest.
    private static let checksumManifestName = "SHA2-256SUMS"
    /// GitHub requires a User-Agent on every request; identify ourselves.
    private static let userAgent = "grably-updater"

    /// Default plausible size bounds for the downloaded `yt-dlp_macos` (~35 MiB).
    public static let defaultMinBinaryBytes = 5 * 1024 * 1024
    public static let defaultMaxBinaryBytes = 200 * 1024 * 1024

    /// Actual size bounds in force (injectable for tests).
    private let minBinaryBytes: Int
    private let maxBinaryBytes: Int

    /// Wall-clock cap on a `yt-dlp --version` probe.
    private let versionTimeout: Duration
    /// Cap on an individual network request (metadata / manifest / download start).
    private let networkTimeout: TimeInterval
    /// Overall wall-clock cap on the binary download (defence against a slow drip).
    private let resourceTimeout: TimeInterval

    /// Test-only seam: invoked after the atomic swap and before the launch
    /// verification, so a test can perturb the filesystem (e.g. make the directory
    /// read-only) to exercise the rollback-failure path. `nil` in production.
    private var afterSwapHook: (@Sendable () async -> Void)?

    public init(
        ytDlpURL: URL,
        runner: ProcessRunner,
        session: URLSession = .shared,
        versionTimeout: Duration = .seconds(15),
        networkTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 300,
        minBinaryBytes: Int = YTDLPUpdater.defaultMinBinaryBytes,
        maxBinaryBytes: Int = YTDLPUpdater.defaultMaxBinaryBytes
    ) {
        self.ytDlpURL = ytDlpURL
        self.runner = runner
        self.session = session
        self.versionTimeout = versionTimeout
        self.networkTimeout = networkTimeout
        self.resourceTimeout = resourceTimeout
        self.minBinaryBytes = minBinaryBytes
        self.maxBinaryBytes = maxBinaryBytes
    }

    /// Install a post-swap hook (test-only). See ``afterSwapHook``.
    func setAfterSwapHook(_ hook: @escaping @Sendable () async -> Void) {
        afterSwapHook = hook
    }

    // MARK: - Version discovery

    /// The currently installed yt-dlp version string (e.g. `2026.06.09`).
    ///
    /// - Throws: ``UpdaterError/versionUnavailable`` if yt-dlp cannot be launched,
    ///   exits non-zero, or prints nothing parseable.
    public func currentVersion() async throws -> String {
        let output: (code: Int32, stdout: String)
        do {
            output = try await runVersionProbe()
        } catch {
            throw UpdaterError.versionUnavailable
        }
        guard output.code == 0 else { throw UpdaterError.versionUnavailable }
        let version = Self.parseVersion(output.stdout)
        guard !version.isEmpty else { throw UpdaterError.versionUnavailable }
        return version
    }

    /// The latest published yt-dlp version, from the GitHub releases API.
    ///
    /// - Throws: ``UpdaterError/networkUnavailable`` when the host is unreachable,
    ///   ``UpdaterError/serverUnavailable(_:)`` on a non-200 status, or
    ///   ``UpdaterError/invalidResponse`` if `tag_name` is missing/empty.
    public func latestVersion() async throws -> String {
        try await latestRelease().version
    }

    /// Resolve the newest release into its raw `tag` (used to build download URLs)
    /// and its normalised `version` (shown to the user).
    private func latestRelease() async throws -> (tag: String, version: String) {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.timeoutInterval = networkTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw UpdaterError.serverUnavailable(http.statusCode)
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawTag = object["tag_name"] as? String
        else {
            throw UpdaterError.invalidResponse
        }
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = Self.parseVersion(rawTag)
        guard !tag.isEmpty, !version.isEmpty else {
            throw UpdaterError.invalidResponse
        }
        return (tag, version)
    }

    /// Compare the installed against the latest version.
    public func checkForUpdate() async throws -> UpdateStatus {
        let current = try await currentVersion()
        let latest = try await latestRelease().version
        if Self.isNewer(latest, than: current) {
            return .updateAvailable(current: current, latest: latest)
        }
        return .upToDate(current)
    }

    // MARK: - Update

    /// Download the newest `yt-dlp_macos` build and swap it into place, returning
    /// the resulting installed version.
    ///
    /// Pipeline: resolve the release tag → download the binary and its
    /// `SHA2-256SUMS` from that exact tag → HTTP-200 + size sanity check → verify the
    /// binary's SHA-256 against the manifest → chmod 0755 + strip
    /// `com.apple.quarantine` → atomic `replaceItemAt` → verify the new binary
    /// launches (`--version`) → record the installed version stamp. If verification
    /// fails the previous binary is restored and ``UpdaterError/verificationFailed``
    /// is thrown; if that restore *also* fails the backup is preserved and
    /// ``UpdaterError/rollbackFailed(_:)`` is thrown.
    ///
    /// - Throws: ``UpdaterError`` describing the failing stage; `CancellationError`
    ///   if the operation was cancelled.
    public func update() async throws -> String {
        let release = try await latestRelease()

        // The heavy download (binary + manifest) is bounded by an overall deadline
        // so a slow drip cannot hang the update indefinitely.
        let tag = release.tag
        let staged = try await withResourceDeadline { [self] in
            try await downloadVerifiedBinary(tag: tag)
        }

        let fileManager = FileManager.default
        let directory = ytDlpURL.deletingLastPathComponent()

        var stagedConsumed = false
        defer { if !stagedConsumed { try? fileManager.removeItem(at: staged) } }

        // Back up the current binary so a failed verification can be rolled back.
        var backup: URL?
        var backupPreserved = false
        if fileManager.fileExists(atPath: ytDlpURL.path) {
            let candidate = directory.appendingPathComponent(
                ".yt-dlp.backup.\(getpid()).\(UUID().uuidString)"
            )
            do {
                try fileManager.copyItem(at: ytDlpURL, to: candidate)
                backup = candidate
            } catch {
                throw UpdaterError.filesystem
            }
        }
        defer { if let backup, !backupPreserved { try? fileManager.removeItem(at: backup) } }

        // Atomic swap: replaceItemAt when a binary already exists, else a move.
        do {
            if fileManager.fileExists(atPath: ytDlpURL.path) {
                _ = try fileManager.replaceItemAt(ytDlpURL, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: ytDlpURL)
            }
            stagedConsumed = true
        } catch {
            throw UpdaterError.filesystem
        }

        // Ensure the swapped-in file is executable and un-quarantined.
        FileSecurity.makeExecutable(ytDlpURL)
        FileSecurity.removeQuarantine(ytDlpURL)

        if let afterSwapHook { await afterSwapHook() }

        // Verify the new binary actually launches; roll back otherwise.
        let installedVersion: String
        do {
            installedVersion = try await currentVersion()
        } catch {
            guard let backup else { throw UpdaterError.verificationFailed }
            do {
                // Restore consumes `backup` (moved back into place).
                _ = try fileManager.replaceItemAt(ytDlpURL, withItemAt: backup)
                backupPreserved = true
                throw UpdaterError.verificationFailed
            } catch let error as UpdaterError {
                throw error
            } catch {
                // Rollback itself failed: never delete the backup — it is now the
                // only working copy. Preserve it under a recovery name if we can,
                // and surface the fact (and the file name) in the error.
                backupPreserved = true
                let recovery = directory.appendingPathComponent(
                    ".yt-dlp.recovery.\(getpid()).\(UUID().uuidString)"
                )
                let preservedName: String
                if (try? fileManager.moveItem(at: backup, to: recovery)) != nil {
                    preservedName = recovery.lastPathComponent
                } else {
                    preservedName = backup.lastPathComponent
                }
                Self.log.error(
                    "yt-dlp update rollback failed; backup preserved as \(preservedName, privacy: .public)"
                )
                throw UpdaterError.rollbackFailed(preservedName)
            }
        }

        // Record the installed version so the provisioner will not overwrite this
        // (possibly user-newer) binary with the bundled one on the next launch.
        writeVersionStamp(installedVersion)
        return installedVersion
    }

    // MARK: - Download

    /// Download the tagged macOS binary, then fetch and enforce its published
    /// SHA-256 checksum. Returns the validated staging URL (same volume as
    /// `ytDlpURL`, so the later `replaceItemAt` is a cheap rename).
    private func downloadVerifiedBinary(tag: String) async throws -> URL {
        let staged = try await downloadBinary(tag: tag)

        let fileManager = FileManager.default
        func fail(_ error: Error) -> Error {
            try? fileManager.removeItem(at: staged)
            return error
        }

        let manifest = try await downloadChecksumManifest(tag: tag)
        guard let expected = Self.expectedChecksum(
            from: manifest, fileName: Self.macosBinaryName
        ) else {
            throw fail(UpdaterError.checksumMismatch)
        }
        guard let digest = FileSecurity.sha256(of: staged) else {
            throw fail(UpdaterError.filesystem)
        }
        guard FileSecurity.hexString(digest) == expected else {
            throw fail(UpdaterError.checksumMismatch)
        }

        // TODO (post-MVP): additionally verify the GPG signature of SHA2-256SUMS
        // (SHA2-256SUMS.sig) against yt-dlp's release-signing public key, so a
        // compromised release host cannot serve a matching binary+manifest pair.
        return staged
    }

    /// Download the tagged `yt-dlp_macos` into a staging file next to `ytDlpURL`,
    /// after validating the HTTP status and size. Returns the staging URL.
    private func downloadBinary(tag: String) async throws -> URL {
        let url = Self.binaryURL(tag: tag)
        var request = URLRequest(url: url)
        request.timeoutInterval = networkTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // Defence in depth: never fetch a binary over cleartext.
        guard url.scheme == "https" else {
            throw UpdaterError.invalidResponse
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }

        let fileManager = FileManager.default
        // The system-provided temp file is deleted once we return; move it to our
        // own staging path immediately so we control its lifetime.
        let staged = ytDlpURL.deletingLastPathComponent().appendingPathComponent(
            ".yt-dlp.update.\(getpid()).\(UUID().uuidString)"
        )
        do {
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.moveItem(at: tempURL, to: staged)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw UpdaterError.filesystem
        }

        // Validate the response and size; on any failure, drop the staged file.
        func fail(_ error: UpdaterError) -> UpdaterError {
            try? fileManager.removeItem(at: staged)
            return error
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw fail(.serverUnavailable(http.statusCode))
        }
        let size = (try? fileManager.attributesOfItem(atPath: staged.path)[.size] as? Int) ?? nil
        guard let size, size >= minBinaryBytes, size <= maxBinaryBytes else {
            throw fail(.corruptedDownload)
        }

        FileSecurity.makeExecutable(staged)
        FileSecurity.removeQuarantine(staged)
        return staged
    }

    /// Fetch the tagged `SHA2-256SUMS` manifest as text.
    private func downloadChecksumManifest(tag: String) async throws -> String {
        let url = Self.checksumURL(tag: tag)
        var request = URLRequest(url: url)
        request.timeoutInterval = networkTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard url.scheme == "https" else {
            throw UpdaterError.invalidResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdaterError.serverUnavailable(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdaterError.invalidResponse
        }
        return text
    }

    // MARK: - URLs

    private static func binaryURL(tag: String) -> URL {
        URL(string:
            "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/\(macosBinaryName)"
        )!
    }

    private static func checksumURL(tag: String) -> URL {
        URL(string:
            "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/\(checksumManifestName)"
        )!
    }

    // MARK: - Version stamp

    /// Where the installed-version side-file lives (next to the executable).
    private var versionStampURL: URL {
        ytDlpURL.deletingLastPathComponent()
            .appendingPathComponent(BinaryStamp.ytDlpVersionFileName)
    }

    /// Record the installed version so ``BinaryProvisioner`` treats the support copy
    /// as authoritative and does not clobber a user-installed update on next launch.
    private func writeVersionStamp(_ version: String) {
        try? Data(version.utf8).write(to: versionStampURL, options: .atomic)
    }

    // MARK: - Checksum manifest parsing

    /// Extract the lowercase hex SHA-256 for `fileName` from a `SHA2-256SUMS`
    /// manifest (`<hex>␠␠<name>` lines; a leading `*` on the name, coreutils'
    /// binary-mode marker, is tolerated).
    static func expectedChecksum(from manifest: String, fileName: String) -> String? {
        for rawLine in manifest.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let tokens = rawLine
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard tokens.count >= 2 else { continue }
            var name = tokens[tokens.count - 1]
            if name.hasPrefix("*") { name.removeFirst() }
            if name == fileName {
                let hex = tokens[0].lowercased()
                // A SHA-256 hex digest is exactly 64 hex characters.
                guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
                return hex
            }
        }
        return nil
    }

    // MARK: - Resource deadline

    /// Run `operation`, failing with ``UpdaterError/networkUnavailable`` if it does
    /// not finish within `resourceTimeout`. Cancels the in-flight download on timeout.
    private func withResourceDeadline<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [resourceTimeout] in
                try await Task.sleep(for: .seconds(resourceTimeout))
                throw UpdaterError.networkUnavailable
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw UpdaterError.networkUnavailable
            }
            return result
        }
    }

    // MARK: - Error mapping

    /// Map a `URLSession` transport error: cancellation propagates as
    /// `CancellationError`; anything else becomes ``UpdaterError/networkUnavailable``.
    private static func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return UpdaterError.networkUnavailable
    }

    // MARK: - Process probe

    /// Run `yt-dlp --version` and collect stdout with a wall-clock timeout.
    private func runVersionProbe() async throws -> (code: Int32, stdout: String) {
        let launch = ProcessLaunch(
            executableURL: ytDlpURL,
            arguments: ["--version"],
            environment: ProcessEnvironment.defaultEnvironment,
            currentDirectory: nil
        )
        let (events, handle) = try await runner.run(launch)

        let deadline = Task { [versionTimeout] in
            try? await Task.sleep(for: versionTimeout)
            guard !Task.isCancelled else { return }
            handle.terminate()
        }
        defer { deadline.cancel() }

        var stdoutLines: [String] = []
        var code: Int32 = -1
        for await event in events {
            switch event {
            case let .stdoutLine(line):
                stdoutLines.append(line)
            case .stderrLine:
                break
            case let .exit(exitCode, _):
                code = exitCode
            }
        }
        return (code, stdoutLines.joined(separator: "\n"))
    }

    // MARK: - Version helpers

    /// Extract the version token from raw output/tag text. Delegates to
    /// ``VersionCompare/parse(_:)``.
    static func parseVersion(_ raw: String) -> String {
        VersionCompare.parse(raw)
    }

    /// Whether `candidate` is a strictly newer yt-dlp release than `current`.
    /// Delegates to ``VersionCompare/isNewer(_:than:)``.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        VersionCompare.isNewer(candidate, than: current)
    }
}

// MARK: - Shared version comparison

/// Date-based version parsing/comparison for yt-dlp releases (`YYYY.MM.DD`, with an
/// optional `.N` same-day build suffix). Shared by ``YTDLPUpdater`` and
/// ``BinaryProvisioner`` so the "which build is newer" rule is defined once.
enum VersionCompare {
    /// Trim whitespace, drop a leading `v`/`V`, and keep the first whitespace-
    /// separated token (yt-dlp's `--version` prints just the version, but be
    /// defensive about trailing noise).
    static func parse(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed
            .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .first.map(String.init) ?? ""
        if firstToken.hasPrefix("v") || firstToken.hasPrefix("V") {
            return String(firstToken.dropFirst())
        }
        return firstToken
    }

    /// Whether `candidate` represents a strictly newer release than `current`.
    /// A component-wise numeric comparison is exact for date-based versions and
    /// also orders a same-day rebuild (`2026.06.09` vs `2026.06.09.1`). Non-numeric
    /// input falls back to a plain lexicographic comparison.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = numericComponents(candidate),
              let b = numericComponents(current) else {
            return candidate > current
        }
        let count = max(a.count, b.count)
        for index in 0..<count {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }
}

// MARK: - Shared binary metadata

/// Names of the side-files that record binary provisioning/update state.
enum BinaryStamp {
    /// Records the version of the installed `yt-dlp` support copy. Written by
    /// ``YTDLPUpdater`` after a successful self-update and by ``BinaryProvisioner``
    /// after copying the bundled build, so the two agree on which is authoritative.
    static let ytDlpVersionFileName = ".yt-dlp.version"
}

// MARK: - Shared file-security helpers

/// Small, `posix`/CryptoKit-based helpers shared by the binary provisioning /
/// updating paths: mark a file executable, strip the Gatekeeper quarantine
/// attribute, and hash a file. No shelling out.
enum FileSecurity {
    /// `chmod 0755`, best-effort.
    static func makeExecutable(_ url: URL) {
        _ = url.path.withCString { chmod($0, 0o755) }
    }

    /// Remove `com.apple.quarantine` (best-effort; a missing attribute is fine).
    static func removeQuarantine(_ url: URL) {
        _ = url.path.withCString { path in
            removexattr(path, "com.apple.quarantine", 0)
        }
    }

    /// Stream a file through SHA-256, bounding memory regardless of file size.
    static func sha256(of url: URL) -> SHA256.Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    /// Lowercase hex encoding of a SHA-256 digest.
    static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
