import Darwin
import Foundation

/// The resolved, ready-to-launch helper executables living in a writable
/// support directory (copies of the bundled originals).
public struct ResolvedBinaries: Sendable, Hashable {
    /// The `yt-dlp` executable.
    public var ytDlp: URL
    /// The `ffmpeg` executable.
    public var ffmpeg: URL
    /// The `ffprobe` executable.
    public var ffprobe: URL
    /// Directory containing `ffmpeg`/`ffprobe`, for yt-dlp's `--ffmpeg-location`.
    public var ffmpegDirectory: URL

    public init(ytDlp: URL, ffmpeg: URL, ffprobe: URL, ffmpegDirectory: URL) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.ffmpegDirectory = ffmpegDirectory
    }
}

/// Why binary provisioning failed.
public enum BinaryError: Error, Sendable, Equatable {
    /// The named executable does not exist in the source directory.
    case sourceMissing(String)
    /// The named source executable is a symlink, a non-regular file, or resolves
    /// outside the trusted source directory — never copied or executed.
    case untrustedBinary(String)
    /// Copying the named executable into the support directory failed.
    case copyFailed(String)
}

/// Locates the bundled helper executables, copies them into a writable support
/// directory, marks them executable, strips the download quarantine, and returns
/// their resolved paths.
///
/// Actor-isolated so the copy/attribute/xattr sequence for the three binaries is
/// serialized (no concurrent writers to the shared support directory).
public actor BinaryProvisioner {
    /// Source directory holding the bundled originals (in production
    /// `Bundle.main/Contents/Resources/bin`; injected in tests).
    private let sourceDirectory: URL
    /// Writable directory the binaries are copied into and run from
    /// (`~/Library/Application Support/grably/bin`).
    private let supportDirectory: URL

    /// The executables provisioned, in fixed order.
    private static let binaryNames = ["yt-dlp", "ffmpeg", "ffprobe"]

    /// The self-updatable executable, provisioned by version stamp rather than by
    /// content hash (see ``needsCopy(from:to:name:)``).
    private static let updatableName = "yt-dlp"

    public init(sourceDirectory: URL, supportDirectory: URL) {
        self.sourceDirectory = sourceDirectory
        self.supportDirectory = supportDirectory
    }

    /// Provision the binaries and return their resolved locations.
    ///
    /// For each of `yt-dlp`/`ffmpeg`/`ffprobe`:
    /// 1. validate the source is a trusted regular file inside `sourceDirectory`,
    /// 2. copy it into `supportDirectory` (atomically) if missing or its content
    ///    hash differs from the trusted source (tamper-evident freshness),
    /// 3. validate the **destination** — the path we are about to execute — is a
    ///    trusted regular file (never a symlink) inside `supportDirectory`,
    /// 4. `chmod 0755`,
    /// 5. strip the `com.apple.quarantine` xattr (best-effort).
    public func resolve() async throws -> ResolvedBinaries {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true
        )

        // Sweep any staging/backup crumbs a crashed prior run left behind (its
        // `defer` cleanup never ran). Recovery files are deliberately *not* swept.
        sweepOrphans()

        // Version of the bundled yt-dlp, if the bundle ships a stamp. Its presence
        // switches yt-dlp onto version-governed provisioning (see `needsCopy`).
        let bundledYtDlpVersion = readVersionStamp(
            sourceDirectory.appendingPathComponent(BinaryStamp.ytDlpVersionFileName)
        )

        var resolved: [String: URL] = [:]
        for name in Self.binaryNames {
            let source = sourceDirectory.appendingPathComponent(name)
            try validateSource(source, name: name)

            let destination = supportDirectory.appendingPathComponent(name)
            if try needsCopy(from: source, to: destination, name: name) {
                try copyAtomically(from: source, to: destination, name: name)
                // Stamp the freshly bundled yt-dlp so a later self-update — and this
                // provisioner on the next launch — can tell whose copy is newer.
                if name == Self.updatableName, let bundledYtDlpVersion {
                    writeVersionStamp(
                        bundledYtDlpVersion,
                        to: supportDirectory
                            .appendingPathComponent(BinaryStamp.ytDlpVersionFileName)
                    )
                }
            }

            // Validate what we actually launch. The support directory is
            // user-writable, so between provisioning runs an attacker could have
            // replaced the copy with a symlink to a payload — reject that outright.
            try validateDestination(destination, name: name)

            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination.path
            )
            FileSecurity.removeQuarantine(destination)
            resolved[name] = destination
        }

        return ResolvedBinaries(
            ytDlp: resolved["yt-dlp"]!,
            ffmpeg: resolved["ffmpeg"]!,
            ffprobe: resolved["ffprobe"]!,
            ffmpegDirectory: supportDirectory
        )
    }

    // MARK: - Validation (security)

    /// Reject anything that isn't a genuine regular file physically inside the
    /// trusted source directory. A missing file is reported as `sourceMissing`.
    private func validateSource(_ url: URL, name: String) throws {
        try validateTrustedFile(
            url, within: sourceDirectory, name: name, missingIsSourceMissing: true
        )
    }

    /// Validate the copied binary in the (user-writable) support directory — the
    /// path we hand to the loader. This is the single choke point where trust in
    /// the executed file is established.
    ///
    /// TODO (phase 8, packaging): additionally verify the binary's code signature
    /// (Developer ID / team identifier) here before it is executed. This is the
    /// one place to add it: every path that is launched flows through here.
    private func validateDestination(_ url: URL, name: String) throws {
        try validateTrustedFile(
            url, within: supportDirectory, name: name, missingIsSourceMissing: false
        )
    }

    /// Reject anything that isn't a genuine regular file physically inside
    /// `directory`.
    ///
    /// - `lstat` (not `stat`) is used so a **symlink** is detected rather than
    ///   followed: a planted symlink could otherwise point our loader at an
    ///   attacker-controlled binary elsewhere.
    /// - The canonicalized (`realpath`) file path must be a child of the
    ///   canonicalized directory, closing symlinked-parent escapes.
    private func validateTrustedFile(
        _ url: URL, within directory: URL, name: String, missingIsSourceMissing: Bool
    ) throws {
        let path = url.path

        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw missingIsSourceMissing
                ? BinaryError.sourceMissing(name)
                : BinaryError.untrustedBinary(name)
        }
        let fileType = info.st_mode & S_IFMT
        // A symlink (even one that happens to resolve inside the dir) is untrusted.
        guard fileType != S_IFLNK else {
            throw BinaryError.untrustedBinary(name)
        }
        guard fileType == S_IFREG else {
            throw BinaryError.untrustedBinary(name)
        }

        // Prefix-check the canonical paths: the real file must live inside the
        // real directory.
        guard let realDirectory = Self.canonicalPath(directory.path),
              let realFile = Self.canonicalPath(path) else {
            throw BinaryError.untrustedBinary(name)
        }
        let prefix = realDirectory.hasSuffix("/") ? realDirectory : realDirectory + "/"
        guard realFile.hasPrefix(prefix) else {
            throw BinaryError.untrustedBinary(name)
        }
    }

    /// Resolve a path to its canonical, symlink-free absolute form via `realpath`.
    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Copy

    /// Decide whether the destination must be (re)copied from the trusted source.
    ///
    /// **yt-dlp (self-updatable).** When the bundle ships a `.yt-dlp.version` stamp,
    /// yt-dlp is provisioned by *version*, not by content hash: the bundled copy is
    /// installed only if the support copy is **absent** or its recorded version is
    /// **older** than the bundled one. This is what lets a user-installed self-update
    /// (which necessarily differs in bytes from the bundle) survive a relaunch —
    /// a hash comparison would wrongly flag it as tampered and revert it. A newer
    /// *bundled* build (after an app update) still correctly refreshes the copy.
    ///
    /// **ffmpeg/ffprobe (and yt-dlp without a bundle stamp, e.g. tests).** Tamper-
    /// evident freshness by **content hash** (SHA-256): if the installed copy's bytes
    /// differ from the trusted source it is overwritten. Copy also happens when the
    /// destination is absent.
    ///
    /// A destination that is not a plain regular file (e.g. a planted symlink) is
    /// deliberately *not* recopied here — leaving it for ``validateDestination`` to
    /// reject, so tampering fails closed with a clear error rather than being
    /// silently papered over.
    private func needsCopy(from source: URL, to destination: URL, name: String) throws -> Bool {
        if name == Self.updatableName,
           let bundledVersion = readVersionStamp(
               sourceDirectory.appendingPathComponent(BinaryStamp.ytDlpVersionFileName)
           ) {
            return needsCopyByVersion(destination: destination, bundledVersion: bundledVersion)
        }

        var info = stat()
        guard lstat(destination.path, &info) == 0 else { return true }
        // Only a genuine regular file is a candidate for a content comparison; a
        // symlink/other is left to validateDestination.
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }

        guard let sourceHash = FileSecurity.sha256(of: source),
              let destinationHash = FileSecurity.sha256(of: destination) else {
            return true // Unable to hash → be safe and recopy from the trusted source.
        }
        return sourceHash != destinationHash
    }

    /// Version-governed freshness for yt-dlp: copy from the bundle only if the
    /// support copy is absent or strictly older than the bundled version.
    private func needsCopyByVersion(destination: URL, bundledVersion: String) -> Bool {
        var info = stat()
        guard lstat(destination.path, &info) == 0 else { return true } // absent → copy
        // A symlink/other is left to validateDestination to reject.
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }

        guard let installedVersion = readVersionStamp(
            supportDirectory.appendingPathComponent(BinaryStamp.ytDlpVersionFileName)
        ) else {
            return true // no stamp for an existing copy → treat as older; refresh + stamp
        }
        // Keep the installed copy unless the bundle is strictly newer.
        return VersionCompare.isNewer(bundledVersion, than: installedVersion)
    }

    // MARK: - Version stamp

    /// Read and normalise a version from a stamp side-file, or `nil` if absent/empty.
    private func readVersionStamp(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let version = VersionCompare.parse(raw)
        return version.isEmpty ? nil : version
    }

    /// Write a version to a stamp side-file (atomically, best-effort).
    private func writeVersionStamp(_ version: String, to url: URL) {
        try? Data(version.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Orphan sweep

    /// Remove staging/backup crumbs from the support directory that a crashed prior
    /// run would otherwise leak: the provisioner's own `.<name>.<pid>.<uuid>.tmp`
    /// scratch files and the updater's `.yt-dlp.update.*` / `.yt-dlp.backup.*`
    /// staging/backup files. Recovery files (`.yt-dlp.recovery.*`) and the version
    /// stamp are preserved. Best-effort; failures are ignored.
    private func sweepOrphans() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: supportDirectory.path)
        else { return }
        for entry in entries {
            let isUpdaterCrumb =
                entry.hasPrefix(".yt-dlp.update.") || entry.hasPrefix(".yt-dlp.backup.")
            let isProvisionerScratch = entry.hasPrefix(".") && entry.hasSuffix(".tmp")
            guard isUpdaterCrumb || isProvisionerScratch else { continue }
            try? fileManager.removeItem(
                at: supportDirectory.appendingPathComponent(entry)
            )
        }
    }

    /// Copy `source` to `destination` atomically: write to a sibling temp then
    /// `replaceItemAt` (or move if the destination is absent), so a crash mid-copy
    /// never leaves a truncated executable in place.
    private func copyAtomically(from source: URL, to destination: URL, name: String) throws {
        let fileManager = FileManager.default
        // Unique temp name (pid + uuid) so two independent processes provisioning
        // the same support directory can never collide on the same scratch file.
        let temp = supportDirectory.appendingPathComponent(
            ".\(name).\(getpid()).\(UUID().uuidString).tmp"
        )

        do {
            if fileManager.fileExists(atPath: temp.path) {
                try fileManager.removeItem(at: temp)
            }
            try fileManager.copyItem(at: source, to: temp)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: temp.path
            )

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw BinaryError.copyFailed(name)
        }
    }
}
