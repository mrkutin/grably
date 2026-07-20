import Foundation
import Testing
@testable import GrablyCore

@Suite("yt-dlp argument building")
struct YTDLPArgumentsTests {
    private let builder = YTDLPArguments()
    private let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
    private let dest = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)
    private let ffmpeg = URL(fileURLWithPath: "/opt/grably/ffmpeg", isDirectory: true)

    private func downloadArgs(_ kind: DownloadRequest.Kind) -> [String] {
        let request = DownloadRequest(url: url, kind: kind, destinationDirectory: dest)
        return builder.downloadArguments(request: request, ffmpegDir: ffmpeg)
    }

    /// Value following the given flag in an argv array.
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - Probe

    @Test("Probe arguments request single-JSON dump with hardening flags")
    func probeArguments() {
        let args = builder.probeArguments(url: url)
        #expect(args == YTDLPArguments.hardeningArguments + ["-J", "--no-playlist", "--", url.absoluteString])
        // URL stays last, immediately after the `--` option terminator.
        #expect(args.last == url.absoluteString)
        #expect(args[args.count - 2] == "--")
    }

    @Test("Hardening flags are present in probe arguments")
    func probeHardeningFlags() {
        let args = builder.probeArguments(url: url)
        #expect(args.contains("--ignore-config"))
        #expect(args.contains("--no-plugin-dirs"))
        #expect(args.contains("--no-warnings"))
        #expect(args.contains("--no-colors"))
        #expect(value(after: "--socket-timeout", in: args) == "30")
    }

    // MARK: - Video

    @Test("Video 1080p mp4 selector and merge format")
    func video1080p() {
        let args = downloadArgs(.video(height: 1080, container: "mp4"))
        #expect(value(after: "-f", in: args) ==
            "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]")
        // The HLS-safe intermediate fallback (any video ≤H + any audio) is present.
        #expect(value(after: "-f", in: args)?.contains("/bv*[height<=1080]+ba/") == true)
        #expect(value(after: "--merge-output-format", in: args) == "mp4")
        // Remux the container to mp4 if the last fallback yielded e.g. webm.
        #expect(value(after: "--remux-video", in: args) == "mp4")
    }

    @Test("Video 720p selector uses the requested height")
    func video720p() {
        let args = downloadArgs(.video(height: 720, container: "mp4"))
        #expect(value(after: "-f", in: args) ==
            "bv*[height<=720][ext=mp4]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]")
        #expect(value(after: "-f", in: args)?.contains("/bv*[height<=720]+ba/") == true)
        #expect(value(after: "--merge-output-format", in: args) == "mp4")
        #expect(value(after: "--remux-video", in: args) == "mp4")
        // Video downloads must not carry audio-extraction flags.
        #expect(!args.contains("-x"))
        #expect(!args.contains("--audio-format"))
    }

    // MARK: - Audio

    @Test("Audio mp3 extracts and re-encodes at best quality")
    func audioMP3() {
        let args = downloadArgs(.audio(codec: .mp3))
        #expect(value(after: "-f", in: args) == "ba/b")
        #expect(args.contains("-x"))
        #expect(value(after: "--audio-format", in: args) == "mp3")
        #expect(value(after: "--audio-quality", in: args) == "0")
        #expect(!args.contains("--merge-output-format"))
    }

    @Test("Audio m4a keeps the native stream without re-encoding")
    func audioM4A() {
        let args = downloadArgs(.audio(codec: .m4a))
        #expect(value(after: "-f", in: args) == "ba[ext=m4a]/ba/b")
        #expect(!args.contains("-x"))
        #expect(!args.contains("--audio-format"))
        // Audio-only requests never remux video.
        #expect(!args.contains("--remux-video"))
    }

    // MARK: - Common flags

    @Test("Common flags are always present", arguments: [
        DownloadRequest.Kind.video(height: 1080, container: "mp4"),
        DownloadRequest.Kind.audio(codec: .mp3),
        DownloadRequest.Kind.audio(codec: .m4a),
    ])
    func commonFlags(_ kind: DownloadRequest.Kind) {
        let args = downloadArgs(kind)

        #expect(args.contains("--newline"))
        #expect(args.contains("--no-playlist"))

        // Hardening flags are applied to every download too.
        #expect(args.contains("--ignore-config"))
        #expect(args.contains("--no-plugin-dirs"))
        #expect(args.contains("--no-warnings"))
        #expect(args.contains("--no-colors"))
        #expect(value(after: "--socket-timeout", in: args) == "30")

        // Destination is anchored via `-P home:<dir>`…
        #expect(value(after: "-P", in: args) == "home:/Users/me/Downloads")
        // …and `-o` is a bare filename (no path separators) so untrusted metadata
        // in %(title)s can't escape the directory.
        let output = value(after: "-o", in: args)
        #expect(output == "%(title)s.%(ext)s")
        #expect(!(output?.contains("/") ?? true))

        // Filename hardening is mandatory.
        #expect(args.contains("--restrict-filenames"))
        #expect(value(after: "--trim-filenames", in: args) == "200")

        // ffmpeg location points at the provided directory.
        #expect(value(after: "--ffmpeg-location", in: args) == "/opt/grably/ffmpeg")

        // Machine-readable progress + final-path templates.
        #expect(value(after: "--progress-template", in: args) == YTDLPArguments.progressTemplate)
        #expect(value(after: "--print", in: args) == YTDLPArguments.finalPathTemplate)

        // URL is the final argument, immediately after the `--` terminator.
        #expect(args.last == url.absoluteString)
        #expect(args[args.count - 2] == "--")
    }

    // MARK: - Argument-injection hardening (B1/B3/B4)

    @Test("A URL beginning with a dash is guarded by `--` and never becomes a flag")
    func dashLeadingURLIsPositional() {
        // A crafted URL whose string begins with `-` (e.g. `--exec=...`) must land
        // after the `--` terminator, as a positional, not be parsed as an option.
        let hostile = URL(string: "https://example.com/-hack")!
        let request = DownloadRequest(url: hostile, kind: .video(height: 720), destinationDirectory: dest)
        let args = builder.downloadArguments(request: request, ffmpegDir: ffmpeg)

        let dashDashIndex = args.firstIndex(of: "--")
        #expect(dashDashIndex != nil)
        #expect(args.last == hostile.absoluteString)
        // Every element after `--` is a positional; the URL is the only one here.
        if let i = dashDashIndex {
            #expect(args[(i + 1)...].count == 1)
        }
    }

    @Test("Plugin loading is disabled on both probe and download")
    func pluginDirsDisabled() {
        #expect(builder.probeArguments(url: url).contains("--no-plugin-dirs"))
        #expect(downloadArgs(.video(height: 1080)).contains("--no-plugin-dirs"))
    }

    @Test("Destination directory with a trailing slash is normalized for -P")
    func destinationTrailingSlashNormalized() {
        let slashed = URL(fileURLWithPath: "/Users/me/Downloads/", isDirectory: true)
        let request = DownloadRequest(url: url, kind: .video(height: 720), destinationDirectory: slashed)
        let args = builder.downloadArguments(request: request, ffmpegDir: ffmpeg)
        #expect(value(after: "-P", in: args) == "home:/Users/me/Downloads")
    }

    // MARK: - Authentication

    /// Index of a flag in an argv array, or nil.
    private func index(of flag: String, in args: [String]) -> Int? {
        args.firstIndex(of: flag)
    }

    @Test("No auth flags are emitted for .none (probe and download)")
    func authNoneEmitsNothing() {
        let probe = builder.probeArguments(url: url, auth: .none)
        let dl = builder.downloadArguments(
            request: DownloadRequest(url: url, kind: .video(height: 720), destinationDirectory: dest),
            ffmpegDir: ffmpeg, auth: .none
        )
        for args in [probe, dl] {
            #expect(!args.contains("--cookies-from-browser"))
            #expect(!args.contains("--cookies"))
        }
        // Default parameter equals passing .none explicitly.
        #expect(builder.probeArguments(url: url) == probe)
    }

    @Test("browserCookies(.safari) adds --cookies-from-browser safari in probe")
    func authBrowserProbe() {
        let args = builder.probeArguments(
            url: url, auth: AuthConfig(source: .browserCookies(.safari))
        )
        #expect(value(after: "--cookies-from-browser", in: args) == "safari")
        #expect(!args.contains("--cookies"))
        // Flag lands before the `--` terminator.
        let flag = index(of: "--cookies-from-browser", in: args)
        let terminator = index(of: "--", in: args)
        #expect(flag != nil && terminator != nil && flag! < terminator!)
    }

    @Test("browserCookies(.chrome) adds --cookies-from-browser chrome in download")
    func authBrowserDownload() {
        let request = DownloadRequest(url: url, kind: .video(height: 720), destinationDirectory: dest)
        let args = builder.downloadArguments(
            request: request, ffmpegDir: ffmpeg, auth: AuthConfig(source: .browserCookies(.chrome))
        )
        #expect(value(after: "--cookies-from-browser", in: args) == "chrome")
        let flag = index(of: "--cookies-from-browser", in: args)
        let terminator = index(of: "--", in: args)
        #expect(flag != nil && terminator != nil && flag! < terminator!)
    }

    @Test("cookiesFile adds --cookies <path> in probe and download, before --")
    func authCookiesFile() {
        let cookies = URL(fileURLWithPath: "/Users/me/cookies.txt")
        let auth = AuthConfig(source: .cookiesFile(cookies))

        let probe = builder.probeArguments(url: url, auth: auth)
        #expect(value(after: "--cookies", in: probe) == "/Users/me/cookies.txt")
        #expect(!probe.contains("--cookies-from-browser"))

        let request = DownloadRequest(url: url, kind: .audio(codec: .mp3), destinationDirectory: dest)
        let dl = builder.downloadArguments(request: request, ffmpegDir: ffmpeg, auth: auth)
        #expect(value(after: "--cookies", in: dl) == "/Users/me/cookies.txt")

        for args in [probe, dl] {
            let flag = index(of: "--cookies", in: args)
            let terminator = index(of: "--", in: args)
            #expect(flag != nil && terminator != nil && flag! < terminator!)
        }
    }

    @Test("Browser enum is a strict allowlist mapped by rawValue")
    func browserAllowlist() {
        // Every case maps to exactly its own lowercase rawValue — no free-form input.
        let expected: [AuthConfig.Browser: String] = [
            .safari: "safari", .chrome: "chrome", .firefox: "firefox",
            .edge: "edge", .brave: "brave", .opera: "opera",
            .vivaldi: "vivaldi", .chromium: "chromium",
        ]
        for browser in AuthConfig.Browser.allCases {
            let args = builder.authArguments(AuthConfig(source: .browserCookies(browser)))
            #expect(args == ["--cookies-from-browser", browser.rawValue])
            #expect(args[1] == expected[browser])
            // Only known tokens exist; construction from a bogus string fails.
        }
        #expect(AuthConfig.Browser(rawValue: "; rm -rf /") == nil)
        #expect(AuthConfig.Browser(rawValue: "chrome:Default") == nil)
    }

    @Test("Auth flags do not disturb the existing hardening / URL layout")
    func authKeepsHardeningLayout() {
        let request = DownloadRequest(url: url, kind: .video(height: 1080), destinationDirectory: dest)
        let args = builder.downloadArguments(
            request: request, ffmpegDir: ffmpeg, auth: AuthConfig(source: .browserCookies(.firefox))
        )
        // Hardening + positional-URL invariants still hold with auth present.
        #expect(args.contains("--no-plugin-dirs"))
        #expect(args.contains("--restrict-filenames"))
        #expect(args.last == url.absoluteString)
        #expect(args[args.count - 2] == "--")
    }

    @Test("Progress template carries the fields the parser expects")
    func progressTemplateShape() {
        let t = YTDLPArguments.progressTemplate
        #expect(t.hasPrefix("download:PROGRESS "))
        // Fields often `None` early use `s` (prints `NA`); downloaded_bytes uses `d`.
        for token in ["%(progress.status)s", "%(progress.downloaded_bytes)d",
                      "%(progress.total_bytes)s", "%(progress.total_bytes_estimate)s",
                      "%(progress.speed)s", "%(progress.eta)s"] {
            #expect(t.contains(token))
        }
        // The frequently-None numeric fields must not use `d`.
        #expect(!t.contains("%(progress.total_bytes)d"))
        #expect(!t.contains("%(progress.speed)d"))
        #expect(!t.contains("%(progress.eta)d"))
    }
}
