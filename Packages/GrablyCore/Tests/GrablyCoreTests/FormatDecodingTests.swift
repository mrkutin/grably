import Foundation
import Testing
@testable import GrablyCore

@Suite("Format & MediaInfo decoding")
struct FormatDecodingTests {

    // MARK: - Fixture loading

    private func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture \(name).json missing from test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func decodeMediaInfo() throws -> MediaInfo {
        let data = try loadFixture("youtube-info")
        return try JSONDecoder().decode(MediaInfo.self, from: data)
    }

    // MARK: - Format round-trip

    @Test("Format round-trips through JSON with yt-dlp keys")
    func formatJSONRoundTrip() throws {
        let format = Format(
            id: "137",
            ext: "mp4",
            formatNote: "1080p",
            resolution: "1920x1080",
            fps: 30,
            vcodec: "avc1.640028",
            acodec: "none",
            filesize: 12_345_678,
            width: 1920,
            height: 1080
        )

        let data = try JSONEncoder().encode(format)
        let decoded = try JSONDecoder().decode(Format.self, from: data)

        #expect(decoded == format)
        #expect(decoded.hasVideo)
        #expect(!decoded.hasAudio)
    }

    @Test("Format decodes the yt-dlp format_id key, not id")
    func formatDecodesYTDLPKeys() throws {
        let json = """
        { "format_id": "251", "ext": "webm", "acodec": "opus", "vcodec": "none" }
        """
        let format = try JSONDecoder().decode(Format.self, from: Data(json.utf8))

        #expect(format.id == "251")
        #expect(format.hasAudio)
        #expect(!format.hasVideo)
        #expect(format.isAudioOnly)
    }

    @Test("protocol key maps to networkProtocol and abr decodes")
    func formatDecodesProtocolAndABR() throws {
        let json = """
        { "format_id": "140", "ext": "m4a", "acodec": "mp4a.40.2",
          "vcodec": "none", "abr": 128.0, "protocol": "https" }
        """
        let format = try JSONDecoder().decode(Format.self, from: Data(json.utf8))
        #expect(format.networkProtocol == "https")
        #expect(format.abr == 128.0)
    }

    // MARK: - Top-level MediaInfo

    @Test("Top-level metadata decodes correctly")
    func decodesTopLevelMetadata() throws {
        let info = try decodeMediaInfo()

        #expect(info.id == "dQw4w9WgXcQ")
        #expect(info.title == "Rick Astley - Never Gonna Give You Up (Official Video)")
        #expect(info.uploader == "Rick Astley")
        #expect(info.duration == 213.0)
        #expect(info.extractor == "youtube")
        #expect(info.webpageURL == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    @Test("An empty thumbnail string degrades to nil instead of throwing")
    func brokenThumbnailBecomesNil() throws {
        let info = try decodeMediaInfo()
        // The fixture thumbnail is an empty string — no URL.
        #expect(info.thumbnail == nil)
    }

    @Test("A thumbnail with control characters is unparseable and becomes nil")
    func controlCharacterThumbnailBecomesNil() throws {
        // Control chars are rejected by URL(string:) across OS versions, so this
        // exercises the parse-failure path independent of Foundation leniency.
        // The \u0001 JSON escape decodes to a literal U+0001 in the string.
        let json = "{ \"id\": \"x\", \"title\": \"T\", "
            + "\"thumbnail\": \"https://ex\\u0001ample.com/x.jpg\", \"formats\": [] }"
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        #expect(info.thumbnail == nil)
    }

    @Test("Decoding tolerates unknown keys and a non-string thumbnail")
    func lenientDecodingOfNoisyPayload() throws {
        let json = """
        {
          "id": "x1",
          "title": "Noisy",
          "thumbnail": ["not", "a", "string"],
          "some_future_field": { "nested": true },
          "duration": 42,
          "formats": []
        }
        """
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        #expect(info.id == "x1")
        #expect(info.thumbnail == nil)
        #expect(info.duration == 42)
        #expect(info.formats.isEmpty)
    }

    @Test("Missing optional fields decode to nil / empty")
    func missingOptionalsAreNil() throws {
        let json = #"{ "id": "bare", "title": "Bare" }"#
        let info = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        #expect(info.uploader == nil)
        #expect(info.duration == nil)
        #expect(info.thumbnail == nil)
        #expect(info.webpageURL == nil)
        #expect(info.formats.isEmpty)
    }

    // MARK: - Format collection

    @Test("Fixture exposes the full set of formats")
    func decodesAllFormats() throws {
        let info = try decodeMediaInfo()
        #expect(info.formats.count == 16)
    }

    @Test("Audio-only filtering")
    func audioOnlyFiltering() throws {
        let info = try decodeMediaInfo()
        let audio = info.formats.filter(\.isAudioOnly)
        #expect(audio.count == 4)
        #expect(Set(audio.map(\.id)) == ["139", "140", "250", "251"])
        // Audio formats never carry picture dimensions.
        #expect(audio.allSatisfy { $0.height == nil })
    }

    @Test("Video-only (DASH) filtering")
    func videoOnlyFiltering() throws {
        let info = try decodeMediaInfo()
        let video = info.formats.filter(\.isVideoOnly)
        #expect(video.count == 9)
        #expect(video.allSatisfy { $0.hasVideo && !$0.hasAudio })
    }

    @Test("Complete (muxed) filtering")
    func completeFiltering() throws {
        let info = try decodeMediaInfo()
        let complete = info.formats.filter(\.isComplete)
        #expect(Set(complete.map(\.id)) == ["18", "22"])
    }

    @Test("Storyboard is neither audio-only, video-only nor complete")
    func storyboardExcluded() throws {
        let info = try decodeMediaInfo()
        let sb = try #require(info.formats.first { $0.id == "sb0" })
        #expect(!sb.isAudioOnly)
        #expect(!sb.isVideoOnly)
        #expect(!sb.isComplete)
    }

    @Test("qualityLabel derives from height or format_note")
    func qualityLabels() throws {
        let info = try decodeMediaInfo()
        let f137 = try #require(info.formats.first { $0.id == "137" })
        #expect(f137.qualityLabel == "1080p")

        let f251 = try #require(info.formats.first { $0.id == "251" })
        #expect(f251.height == nil)
        #expect(f251.qualityLabel == "medium")
    }

    @Test("bestFilesize prefers exact over approximate")
    func bestFilesizePreference() throws {
        let info = try decodeMediaInfo()
        // 137 has filesize null but filesize_approx set.
        let f137 = try #require(info.formats.first { $0.id == "137" })
        #expect(f137.filesize == nil)
        #expect(f137.bestFilesize == 111_500_000)

        // 140 has an exact filesize.
        let f140 = try #require(info.formats.first { $0.id == "140" })
        #expect(f140.bestFilesize == 3_425_000)
    }

    // MARK: - Classification edge cases

    @Test("Video-only with a null acodec is still classified as video-only")
    func videoOnlyWithNullAcodec() throws {
        // Some extractors emit `acodec: null` rather than the literal "none".
        let json = """
        { "format_id": "999", "ext": "mp4", "vcodec": "avc1.640028",
          "acodec": null, "height": 1080, "width": 1920 }
        """
        let f = try JSONDecoder().decode(Format.self, from: Data(json.utf8))
        #expect(f.acodec == nil)
        #expect(f.hasVideo)
        #expect(!f.hasAudio)
        #expect(f.isVideoOnly)
        #expect(!f.isComplete)
        #expect(!f.isAudioOnly)
    }

    @Test("A row with no codecs and no height is not audio-only")
    func degenerateRowIsNotAudioOnly() throws {
        // e.g. a storyboard-like row: vcodec/acodec both "none", no height.
        let json = """
        { "format_id": "junk", "vcodec": "none", "acodec": "none" }
        """
        let f = try JSONDecoder().decode(Format.self, from: Data(json.utf8))
        #expect(f.height == nil)
        #expect(!f.hasAudio)
        #expect(!f.isAudioOnly)
        #expect(!f.isVideoOnly)
        #expect(!f.isComplete)
    }

    // MARK: - Resilient probe decoding

    @Test("One format with a mistyped field is dropped; the rest survive")
    func mistypedFormatIsSkipped() throws {
        // Middle format has "width" as a string — it must not sink the probe.
        let json = """
        {
          "id": "vid", "title": "Resilient", "_type": "video",
          "formats": [
            { "format_id": "a", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "height": 720 },
            { "format_id": "bad", "ext": "mp4", "width": "1920", "height": 1080 },
            { "format_id": "c", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2" }
          ]
        }
        """
        let info = try MediaInfo.decode(from: Data(json.utf8))
        #expect(info.formats.count == 2)
        #expect(Set(info.formats.map(\.id)) == ["a", "c"])
        #expect(!info.formats.contains { $0.id == "bad" })
    }

    @Test("A playlist payload throws ProbeError.playlist")
    func playlistThrows() {
        let json = """
        {
          "_type": "playlist",
          "id": "PL123",
          "title": "My Playlist",
          "entries": [
            { "id": "a", "title": "One" },
            { "id": "b", "title": "Two" }
          ]
        }
        """
        #expect(throws: MediaInfo.ProbeError.playlist) {
            _ = try MediaInfo.decode(from: Data(json.utf8))
        }
    }

    @Test("A video with no usable formats throws ProbeError.noFormats")
    func noFormatsThrows() {
        let json = #"{ "_type": "video", "id": "v", "title": "Empty", "formats": [] }"#
        #expect(throws: MediaInfo.ProbeError.noFormats) {
            _ = try MediaInfo.decode(from: Data(json.utf8))
        }
    }

    @Test("A payload missing `id` throws while decoding")
    func missingIDThrows() {
        // Documented behavior: `id` is required; its absence is a hard error
        // (not silently defaulted), surfaced as a DecodingError.
        let json = #"{ "title": "No ID", "formats": [{ "format_id": "a" }] }"#
        #expect(throws: (any Error).self) {
            _ = try MediaInfo.decode(from: Data(json.utf8))
        }
    }

    @Test("A well-formed single video decodes via MediaInfo.decode")
    func decodeHappyPath() throws {
        let data = try loadFixture("youtube-info")
        let info = try MediaInfo.decode(from: data)
        #expect(info.id == "dQw4w9WgXcQ")
        #expect(info.formats.count == 16)
    }
}
