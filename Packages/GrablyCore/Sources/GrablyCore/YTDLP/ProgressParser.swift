import Foundation

/// Parses a single line of yt-dlp output into a semantic ``ProgressParser/Event``.
///
/// yt-dlp is expected to run with the machine-readable templates from
/// ``YTDLPArguments`` (`--progress-template` and `--print after_move:…`), so
/// progress and final-path lines can be tokenized deterministically. Lines that
/// carry no interesting information return `nil`.
public struct ProgressParser: Sendable {
    /// A meaningful event decoded from one output line.
    public enum Event: Sendable, Equatable {
        /// A download progress snapshot.
        case progress(DownloadProgress)
        /// The download destination path was announced (`[download] Destination: …`).
        case destination(URL)
        /// A post-processing step is running (mux/extract), carrying its raw line.
        case postProcessing(String)
        /// The final on-disk path after everything completed (`FINALPATH …`).
        case finalPath(URL)
    }

    public init() {}

    private static let progressPrefix = "PROGRESS "
    private static let finalPathPrefix = "FINALPATH "
    private static let destinationMarker = "[download] Destination: "

    /// Parse a single line of yt-dlp output. Returns `nil` for lines that carry
    /// no recognized event.
    public func parse(line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix(Self.progressPrefix) {
            return parseProgress(String(trimmed.dropFirst(Self.progressPrefix.count)))
        }

        if trimmed.hasPrefix(Self.finalPathPrefix) {
            let path = String(trimmed.dropFirst(Self.finalPathPrefix.count))
            guard !path.isEmpty else { return nil }
            return .finalPath(URL(fileURLWithPath: path))
        }

        if trimmed.hasPrefix(Self.destinationMarker) {
            let path = String(trimmed.dropFirst(Self.destinationMarker.count))
            guard !path.isEmpty else { return nil }
            return .destination(URL(fileURLWithPath: path))
        }

        if trimmed.hasPrefix("[Merger]")
            || trimmed.hasPrefix("[ExtractAudio]")
            || trimmed.hasPrefix("[VideoConvertor]")
            || trimmed.hasPrefix("[Metadata]") {
            return .postProcessing(trimmed)
        }

        return nil
    }

    // MARK: - Progress

    private func parseProgress(_ payload: String) -> Event? {
        // Fields: status downloaded total total_estimate speed eta
        let fields = payload.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 6 else { return nil }

        let status = fields[0]
        let downloaded = Self.parseInt64(fields[1]) ?? 0
        let total = Self.parsePositiveInt64(fields[2])
        let totalEstimate = Self.parsePositiveInt64(fields[3])
        let speed = Self.parsePositiveDouble(fields[4])
        let eta = Self.parsePositiveInt(fields[5])

        let progress = DownloadProgress(
            status: status,
            downloadedBytes: downloaded,
            totalBytes: total ?? totalEstimate,
            speed: speed,
            eta: eta
        )
        return .progress(progress)
    }

    // MARK: - Numeric helpers

    /// Treat yt-dlp's `"NA"`/empty as absent; parse plain or float-ish integers.
    ///
    /// yt-dlp can print non-finite (`inf`, `nan`) or wildly out-of-range values in
    /// live/fragmented modes; converting those straight to `Int64` traps, so the
    /// float path is guarded to stay strictly inside the representable range.
    private static func parseInt64(_ token: String) -> Int64? {
        guard !isMissing(token) else { return nil }
        if let value = Int64(token) { return value }
        if let value = Double(token) {
            guard value.isFinite,
                  value >= Double(Int64.min),
                  value < Double(Int64.max) else { return nil }
            return Int64(value)
        }
        return nil
    }

    /// Positive-only Int64: `"NA"`, `0`, or negative → `nil` (unknown).
    private static func parsePositiveInt64(_ token: String) -> Int64? {
        guard let value = parseInt64(token), value > 0 else { return nil }
        return value
    }

    private static func parsePositiveDouble(_ token: String) -> Double? {
        guard !isMissing(token), let value = Double(token),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func parsePositiveInt(_ token: String) -> Int? {
        guard let value = parseInt64(token), value > 0 else { return nil }
        return Int(value)
    }

    private static func isMissing(_ token: String) -> Bool {
        token.isEmpty || token == "NA" || token == "None"
    }
}
