import Darwin
import Foundation
import Testing
@testable import GrablyCore

@Suite("BinaryProvisioner")
struct BinaryProvisionerTests {

    // MARK: - Fixtures

    /// A throwaway source+support directory pair, cleaned up by the caller.
    private struct Sandbox {
        let root: URL
        let source: URL
        let support: URL
    }

    private func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bp-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("bin", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return Sandbox(root: root, source: source, support: support)
    }

    private func writeFakeBinaries(
        in dir: URL,
        content: [String: String] = [
            "yt-dlp": "YTDLP-v1", "ffmpeg": "FFMPEG-v1", "ffprobe": "FFPROBE!",
        ]
    ) throws {
        for (name, text) in content {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        url.path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }
    }

    private func setQuarantine(_ url: URL) {
        let value = Array("0081;00000000;Test;".utf8)
        _ = url.path.withCString { path in
            value.withUnsafeBytes { buffer in
                setxattr(path, "com.apple.quarantine", buffer.baseAddress, buffer.count, 0, 0)
            }
        }
    }

    // MARK: - Tests

    @Test("Copies missing binaries into the support directory and marks them executable")
    func copiesWhenAbsent() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        let resolved = try await provisioner.resolve()

        #expect(resolved.ytDlp == sandbox.support.appendingPathComponent("yt-dlp"))
        #expect(resolved.ffmpeg == sandbox.support.appendingPathComponent("ffmpeg"))
        #expect(resolved.ffprobe == sandbox.support.appendingPathComponent("ffprobe"))
        #expect(resolved.ffmpegDirectory == sandbox.support)

        for url in [resolved.ytDlp, resolved.ffmpeg, resolved.ffprobe] {
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try permissions(url) == 0o755)
        }
        // Content matches the source.
        let copied = try String(contentsOf: resolved.ytDlp, encoding: .utf8)
        #expect(copied == "YTDLP-v1")
    }

    @Test("Skips copying when the installed copy is byte-identical (no extra copy)")
    func skipsWhenUpToDate() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // Stamp a distinctive past mtime on the installed copy. A second resolve()
        // whose source is byte-identical must NOT recopy, so the mtime is preserved
        // (a recopy via replaceItemAt would bump it to "now").
        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinel], ofItemAtPath: installed.path
        )

        _ = try await provisioner.resolve()

        let mtime = try FileManager.default
            .attributesOfItem(atPath: installed.path)[.modificationDate] as? Date
        #expect(mtime == sentinel, "identical copy must not be re-copied")
        #expect(try String(contentsOf: installed, encoding: .utf8) == "YTDLP-v1")
    }

    @Test("Recopies when the installed copy has the same size but different content")
    func recopiesWhenContentTamperedSameSize() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // Tamper: same 8-byte length as "YTDLP-v1" but different bytes, plus a newer
        // mtime — the old size+mtime heuristic would have kept this. Content hashing
        // must detect it and restore the trusted bundle copy.
        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        try Data("PATCHED!".utf8).write(to: installed)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: installed.path
        )

        _ = try await provisioner.resolve()

        #expect(
            try String(contentsOf: installed, encoding: .utf8) == "YTDLP-v1",
            "tampered same-size copy must be restored from the trusted source"
        )
    }

    @Test("A symlink planted at the destination path is rejected as untrusted")
    func rejectsSymlinkDestination() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // Replace the installed yt-dlp with a symlink to an attacker file whose
        // content happens to match the source (so a naive hash check would pass).
        // lstat on the destination must still reject the symlink outright.
        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        let payload = sandbox.root.appendingPathComponent("payload")
        try Data("YTDLP-v1".utf8).write(to: payload)
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: payload)

        await #expect(throws: BinaryError.untrustedBinary("yt-dlp")) {
            _ = try await provisioner.resolve()
        }
    }

    @Test("Recopies when the source differs in size")
    func recopiesWhenSourceChanged() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // A new, larger source binary must be re-copied over the old install.
        try Data("YTDLP-v2-much-longer".utf8)
            .write(to: sandbox.source.appendingPathComponent("yt-dlp"))
        _ = try await provisioner.resolve()

        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        #expect(try String(contentsOf: installed, encoding: .utf8) == "YTDLP-v2-much-longer")
    }

    @Test("A symlinked source binary is rejected as untrusted")
    func rejectsSymlinkSource() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        // ffmpeg/ffprobe are real, but yt-dlp is a symlink to an outside file.
        try writeFakeBinaries(in: sandbox.source, content: ["ffmpeg": "F", "ffprobe": "P"])
        let outside = sandbox.root.appendingPathComponent("elsewhere")
        try Data("evil".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: sandbox.source.appendingPathComponent("yt-dlp"), withDestinationURL: outside
        )

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        await #expect(throws: BinaryError.untrustedBinary("yt-dlp")) {
            _ = try await provisioner.resolve()
        }
    }

    @Test("A missing source binary throws sourceMissing")
    func missingSourceThrows() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        // Only ffmpeg/ffprobe present; yt-dlp is absent.
        try writeFakeBinaries(in: sandbox.source, content: ["ffmpeg": "F", "ffprobe": "P"])

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        await #expect(throws: BinaryError.sourceMissing("yt-dlp")) {
            _ = try await provisioner.resolve()
        }
    }

    // MARK: - Version-stamped yt-dlp (self-update survival)

    /// Ship a bundle version stamp alongside the fake binaries, switching yt-dlp
    /// onto version-governed provisioning.
    private func writeBundleStamp(_ version: String, in dir: URL) throws {
        try Data(version.utf8).write(to: dir.appendingPathComponent(".yt-dlp.version"))
    }

    @Test("A user self-update to yt-dlp survives the next provisioning run")
    func selfUpdateSurvivesRelaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)
        try writeBundleStamp("2026.06.09", in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // The bundled copy + its version stamp were installed.
        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        let supportStamp = sandbox.support.appendingPathComponent(".yt-dlp.version")
        #expect(try String(contentsOf: installed, encoding: .utf8) == "YTDLP-v1")
        #expect(try String(contentsOf: supportStamp, encoding: .utf8) == "2026.06.09")

        // Simulate YTDLPUpdater.update(): overwrite the support copy with a newer,
        // byte-different build and bump the support stamp forward.
        try Data("YTDLP-SELF-UPDATED".utf8).write(to: installed)
        try Data("2026.07.01".utf8).write(to: supportStamp)

        // Next launch: the provisioner must NOT revert the newer support copy to the
        // older bundled one (this is the regression the hash-based check caused).
        _ = try await provisioner.resolve()

        #expect(
            try String(contentsOf: installed, encoding: .utf8) == "YTDLP-SELF-UPDATED",
            "a newer self-updated yt-dlp must survive provisioning"
        )
        #expect(try String(contentsOf: supportStamp, encoding: .utf8) == "2026.07.01")
    }

    @Test("A newer bundled yt-dlp (after an app update) refreshes the support copy")
    func newerBundleRefreshesSupport() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)
        try writeBundleStamp("2026.06.09", in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // A user self-update advances the support copy to 2026.07.01.
        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        let supportStamp = sandbox.support.appendingPathComponent(".yt-dlp.version")
        try Data("YTDLP-SELF-UPDATED".utf8).write(to: installed)
        try Data("2026.07.01".utf8).write(to: supportStamp)

        // The app is then updated, shipping an even newer bundled build.
        try Data("YTDLP-BUNDLED-v3".utf8).write(to: sandbox.source.appendingPathComponent("yt-dlp"))
        try writeBundleStamp("2026.08.01", in: sandbox.source)

        _ = try await provisioner.resolve()

        #expect(
            try String(contentsOf: installed, encoding: .utf8) == "YTDLP-BUNDLED-v3",
            "a strictly newer bundled build must refresh the support copy"
        )
        #expect(try String(contentsOf: supportStamp, encoding: .utf8) == "2026.08.01")
    }

    @Test("Provisioning sweeps orphaned staging/backup crumbs but keeps recovery + stamp")
    func sweepsOrphans() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)
        try writeBundleStamp("2026.06.09", in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // Plant crumbs a crashed run would leak, plus a recovery file that must be
        // kept and the live version stamp.
        let plant: (String) throws -> Void = { name in
            try Data("x".utf8).write(to: sandbox.support.appendingPathComponent(name))
        }
        try plant(".yt-dlp.update.999.\(UUID().uuidString)")
        try plant(".yt-dlp.backup.999.\(UUID().uuidString)")
        try plant(".yt-dlp.888.\(UUID().uuidString).tmp")
        let recoveryName = ".yt-dlp.recovery.777.\(UUID().uuidString)"
        try plant(recoveryName)

        _ = try await provisioner.resolve()

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: sandbox.support.path))
        #expect(!remaining.contains(where: { $0.hasPrefix(".yt-dlp.update.") }))
        #expect(!remaining.contains(where: { $0.hasPrefix(".yt-dlp.backup.") }))
        #expect(!remaining.contains(where: { $0.hasSuffix(".tmp") }))
        #expect(remaining.contains(recoveryName), "recovery file must be preserved")
        #expect(remaining.contains(".yt-dlp.version"), "version stamp must be preserved")
    }

    @Test("resolve() strips the com.apple.quarantine xattr from installed binaries")
    func stripsQuarantine() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeFakeBinaries(in: sandbox.source)

        let provisioner = BinaryProvisioner(
            sourceDirectory: sandbox.source, supportDirectory: sandbox.support
        )
        _ = try await provisioner.resolve()

        // Plant a quarantine attribute on the installed copy, then re-resolve.
        let installed = sandbox.support.appendingPathComponent("yt-dlp")
        setQuarantine(installed)
        guard hasQuarantine(installed) else {
            // Some filesystems (rare in CI) reject user xattrs; document + skip.
            Issue.record("could not set com.apple.quarantine on \(installed.path); skipping")
            return
        }

        _ = try await provisioner.resolve()
        #expect(!hasQuarantine(installed), "quarantine xattr should have been removed")
    }
}
