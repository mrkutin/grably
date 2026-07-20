import Foundation

/// A single downloadable media format as reported by yt-dlp (`formats[]`).
///
/// Decoding is deliberately lenient: every field except `format_id` is optional
/// so a "noisy" real-world yt-dlp payload never fails to decode. Unknown keys are
/// ignored by `Codable` automatically.
public struct Format: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let ext: String?
    public let formatNote: String?
    public let resolution: String?
    public let fps: Double?
    public let vcodec: String?
    public let acodec: String?
    public let filesize: Int64?
    public let filesizeApprox: Int64?
    public let tbr: Double?
    public let abr: Double?
    public let vbr: Double?
    public let width: Int?
    public let height: Int?
    public let networkProtocol: String?

    public enum CodingKeys: String, CodingKey {
        case id = "format_id"
        case ext
        case formatNote = "format_note"
        case resolution
        case fps
        case vcodec
        case acodec
        case filesize
        case filesizeApprox = "filesize_approx"
        case tbr
        case abr
        case vbr
        case width
        case height
        case networkProtocol = "protocol"
    }

    public init(
        id: String,
        ext: String? = nil,
        formatNote: String? = nil,
        resolution: String? = nil,
        fps: Double? = nil,
        vcodec: String? = nil,
        acodec: String? = nil,
        filesize: Int64? = nil,
        filesizeApprox: Int64? = nil,
        tbr: Double? = nil,
        abr: Double? = nil,
        vbr: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        networkProtocol: String? = nil
    ) {
        self.id = id
        self.ext = ext
        self.formatNote = formatNote
        self.resolution = resolution
        self.fps = fps
        self.vcodec = vcodec
        self.acodec = acodec
        self.filesize = filesize
        self.filesizeApprox = filesizeApprox
        self.tbr = tbr
        self.abr = abr
        self.vbr = vbr
        self.width = width
        self.height = height
        self.networkProtocol = networkProtocol
    }

    /// True when this format carries a video stream.
    public var hasVideo: Bool {
        guard let vcodec else { return false }
        return vcodec != "none"
    }

    /// True when this format carries an audio stream.
    public var hasAudio: Bool {
        guard let acodec else { return false }
        return acodec != "none"
    }

    /// Audio-only: carries audio, no video stream, and no picture dimensions.
    ///
    /// Requiring ``hasAudio`` keeps degenerate rows (e.g. storyboards with
    /// `vcodec`/`acodec` both `"none"` and no `height`) out of the audio list.
    public var isAudioOnly: Bool {
        hasAudio && !hasVideo && height == nil
    }

    /// Video-only (DASH): has a video stream but no audio.
    ///
    /// Uses ``hasAudio`` (rather than `acodec == "none"`) so formats where some
    /// extractors emit a null `acodec` instead of the literal `"none"` are still
    /// classified correctly, consistent with ``isComplete``.
    public var isVideoOnly: Bool {
        hasVideo && !hasAudio
    }

    /// A complete muxed stream carrying both audio and video.
    public var isComplete: Bool {
        hasVideo && hasAudio
    }

    /// Best available file size estimate (exact preferred over approximate).
    public var bestFilesize: Int64? {
        filesize ?? filesizeApprox
    }

    /// Human-readable quality label, e.g. `"1080p"` for video or the
    /// `format_note` (`"medium"`, `"tiny"`, …) for audio-only formats.
    public var qualityLabel: String {
        if let height {
            return "\(height)p"
        }
        if let formatNote, !formatNote.isEmpty {
            return formatNote
        }
        return ext ?? id
    }
}
