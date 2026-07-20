import Foundation

/// Why a ``DownloadRequest`` could not be constructed from untrusted input.
public enum RequestValidationError: Error, Sendable, Equatable {
    /// The URL's scheme is not on the allowlist (only `http`/`https` are accepted).
    ///
    /// Rejecting everything else blocks yt-dlp's generic extractor from being
    /// pointed at `file://` (local file disclosure), `data:` (in-memory payloads),
    /// and internal-network schemes, and shrinks the SSRF surface (e.g.
    /// `http://169.254.169.254/…` still requires http but is at least on-protocol).
    case unsupportedScheme(String?)
}

/// A user request to download a media item at a chosen type/quality into a
/// destination directory. The concrete yt-dlp arguments (format selector,
/// remux/extract flags) are derived from `kind` by ``YTDLPArguments``.
public struct DownloadRequest: Identifiable, Hashable, Sendable {
    /// URL schemes accepted from untrusted input (lower-cased).
    public static let allowedSchemes: Set<String> = ["http", "https"]
    /// Container/codec choice for an audio-only download.
    public enum AudioCodec: String, Hashable, Sendable, CaseIterable {
        /// Re-encode to MP3 (`-x --audio-format mp3`).
        case mp3
        /// Keep the native AAC stream in an `.m4a` container (no re-encode).
        case m4a
    }

    /// What the user asked to download.
    public enum Kind: Hashable, Sendable {
        /// Video capped at `height` pixels, muxed into `container` (e.g. `"mp4"`).
        case video(height: Int, container: String)
        /// Audio-only extraction to the given codec/container.
        case audio(codec: AudioCodec)

        /// A `.mp4` video convenience constructor.
        public static func video(height: Int) -> Kind {
            .video(height: height, container: "mp4")
        }
    }

    public let id: UUID
    public let url: URL
    public let kind: Kind
    public let destinationDirectory: URL

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: Kind = .video(height: 1080, container: "mp4"),
        destinationDirectory: URL
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.destinationDirectory = destinationDirectory
    }

    /// Construct a request from untrusted input, rejecting any URL whose scheme is
    /// not `http`/`https`.
    ///
    /// - Throws: ``RequestValidationError/unsupportedScheme(_:)`` for `file://`,
    ///   `data:`, or any other non-web scheme.
    public static func validated(
        id: UUID = UUID(),
        url: URL,
        kind: Kind = .video(height: 1080, container: "mp4"),
        destinationDirectory: URL
    ) throws -> DownloadRequest {
        try validate(url: url)
        return DownloadRequest(
            id: id,
            url: url,
            kind: kind,
            destinationDirectory: destinationDirectory
        )
    }

    /// Throw unless `url` uses an allowed (`http`/`https`) scheme.
    public static func validate(url: URL) throws {
        let scheme = url.scheme?.lowercased()
        guard let scheme, allowedSchemes.contains(scheme) else {
            throw RequestValidationError.unsupportedScheme(url.scheme)
        }
    }
}
