import Foundation
import GrablyCore

/// Shared, locale-aware formatters for sizes, durations, speed and ETA used
/// across the download UI.
enum Formatting {
    private static func makeByteFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        return formatter
    }

    /// e.g. `48 MB`. Returns `nil` when the size is unknown.
    static func fileSize(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return makeByteFormatter().string(fromByteCount: bytes)
    }

    /// e.g. `≈ 48 MB`. Returns `nil` when unknown.
    static func approxFileSize(_ bytes: Int64?) -> String? {
        guard let text = fileSize(bytes) else { return nil }
        return "≈ \(text)"
    }

    /// e.g. `8.4 MB/s`. Returns `nil` when unknown.
    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let text = makeByteFormatter().string(fromByteCount: Int64(bytesPerSecond))
        return "\(text)/s"
    }

    /// e.g. `3:33` (m:ss) or `1:02:03` (h:mm:ss). Returns `nil` when unknown.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// ETA phrased for a caption, e.g. `осталось 0:06`. Returns `nil` when unknown.
    static func eta(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        guard let text = duration(Double(seconds)) else { return nil }
        return "осталось \(text)"
    }

    /// Percent for a fraction 0...1, e.g. `62 %`.
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded())) %"
    }
}

/// Small display helpers derived from a ``DownloadTask``'s request/state.
extension DownloadTask {
    /// The user-visible title, falling back to the URL.
    var displayTitle: String {
        mediaInfo?.title.isEmpty == false ? mediaInfo!.title : request.url.absoluteString
    }

    /// `1080p · mp4` or `MP3` etc.
    var displaySubtitle: String {
        switch request.kind {
        case let .video(height, container):
            return "\(height)p · \(container)"
        case let .audio(codec):
            return codec == .mp3 ? "MP3" : "M4A"
        }
    }

    /// SF Symbol for the media type.
    var typeSymbol: String {
        switch request.kind {
        case .video: return "video.fill"
        case .audio: return "music.note"
        }
    }

    var isAudio: Bool {
        if case .audio = request.kind { return true }
        return false
    }
}
