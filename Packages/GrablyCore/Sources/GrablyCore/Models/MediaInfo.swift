import Foundation

/// Metadata for a single media item, decoded from `yt-dlp -J <URL>`
/// (`--dump-single-json`) output.
///
/// Decoding is resilient: `thumbnail` / `webpage_url` that don't parse into a
/// `URL` degrade to `nil` instead of throwing (yt-dlp occasionally emits odd
/// thumbnail strings), `duration` may be a number or absent, and any unknown
/// top-level keys are ignored.
public struct MediaInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let uploader: String?
    public let duration: Double?
    public let thumbnail: URL?
    public let webpageURL: URL?
    public let extractor: String?
    public let formats: [Format]

    public enum CodingKeys: String, CodingKey {
        case id
        case title
        case uploader
        case duration
        case thumbnail
        case webpageURL = "webpage_url"
        case extractor
        case formats
    }

    /// Errors raised by ``MediaInfo/decode(from:)`` when the probed URL does not
    /// resolve to a single downloadable video.
    public enum ProbeError: Error, Equatable, Sendable {
        /// The URL points at a playlist/channel (`_type == "playlist"`), which
        /// carries `entries` instead of `formats`.
        case playlist
        /// A single video was decoded but exposed no usable formats.
        case noFormats
        /// yt-dlp exited non-zero, or its output could not be parsed. Carries a
        /// human-readable, sanitized message (typically the stderr tail).
        case failed(String)
    }

    public init(
        id: String,
        title: String,
        uploader: String? = nil,
        duration: Double? = nil,
        thumbnail: URL? = nil,
        webpageURL: URL? = nil,
        extractor: String? = nil,
        formats: [Format] = []
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnail = thumbnail
        self.webpageURL = webpageURL
        self.extractor = extractor
        self.formats = formats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        extractor = try container.decodeIfPresent(String.self, forKey: .extractor)

        // Per-element resilient decode: a single format with a mistyped field
        // (e.g. `"width": "1920"` as a string) must not sink the entire probe.
        let wrapped = try container.decodeIfPresent(
            [FailableDecodable<Format>].self, forKey: .formats
        ) ?? []
        formats = wrapped.compactMap(\.value)

        // Lenient URL decoding: tolerate a non-string or unparsable value.
        thumbnail = Self.lenientURL(container, .thumbnail)
        webpageURL = Self.lenientURL(container, .webpageURL)
    }

    private static func lenientURL(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> URL? {
        // `try?` collapses both a thrown type-mismatch and an absent key to nil.
        guard let string = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil,
              !string.isEmpty else {
            return nil
        }
        return URL(string: string)
    }

    // MARK: - Probe decoding

    /// Decode a `yt-dlp -J` payload into a single ``MediaInfo``, rejecting probes
    /// that don't resolve to one downloadable video.
    ///
    /// - Throws:
    ///   - ``ProbeError/playlist`` when the payload is a playlist/channel
    ///     (`_type == "playlist"`), so the UI can tell the user to paste a link
    ///     to a specific video.
    ///   - ``ProbeError/noFormats`` when a video decoded but exposed no formats.
    ///   - A `DecodingError` when required fields (e.g. `id`) are missing.
    public static func decode(from data: Data) throws -> MediaInfo {
        let decoder = JSONDecoder()

        // Peek at `_type` first: a playlist has no `formats`/`id` and would
        // otherwise fail decoding with a misleading error.
        if let probe = try? decoder.decode(TypeProbe.self, from: data),
           probe.type == "playlist" {
            throw ProbeError.playlist
        }

        let info = try decoder.decode(MediaInfo.self, from: data)
        guard !info.formats.isEmpty else {
            throw ProbeError.noFormats
        }
        return info
    }

    /// Minimal shape used to detect playlists before a full decode.
    private struct TypeProbe: Decodable {
        let type: String?
        enum CodingKeys: String, CodingKey { case type = "_type" }
    }
}

/// Wraps a `Decodable` so a malformed element inside an unkeyed container is
/// dropped (`value == nil`) instead of failing the whole array decode.
struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
