import Foundation

/// A parsed progress snapshot emitted while a download is running, derived from
/// a machine-readable yt-dlp `--progress-template` line.
///
/// yt-dlp reports unknown numeric fields as `"NA"` (or `0`); those are mapped to
/// `nil` here rather than a misleading zero. Only `downloadedBytes` is always
/// meaningful.
public struct DownloadProgress: Hashable, Sendable {
    /// yt-dlp status token, e.g. `"downloading"` or `"finished"`.
    public let status: String
    /// Downloaded bytes so far (never negative).
    public let downloadedBytes: Int64
    /// Best known total size (`total_bytes` preferred over `total_bytes_estimate`).
    public let totalBytes: Int64?
    /// Current speed in bytes per second, if known.
    public let speed: Double?
    /// Estimated seconds remaining, if known.
    public let eta: Int?

    public init(
        status: String,
        downloadedBytes: Int64,
        totalBytes: Int64? = nil,
        speed: Double? = nil,
        eta: Int? = nil
    ) {
        self.status = status
        self.downloadedBytes = max(0, downloadedBytes)
        self.totalBytes = totalBytes
        self.speed = speed
        self.eta = eta
    }

    /// Fractional completion in the range `0...1`, computed from the best known
    /// total. Returns `0` when the total is unknown and the download is not yet
    /// finished, and `1` once the status reports completion.
    public var fraction: Double {
        if let totalBytes, totalBytes > 0 {
            return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
        }
        return status == "finished" ? 1 : 0
    }

    public static let zero = DownloadProgress(status: "", downloadedBytes: 0)
}
