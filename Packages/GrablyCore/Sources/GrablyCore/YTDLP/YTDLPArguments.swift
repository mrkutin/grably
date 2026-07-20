import Foundation

/// Builds yt-dlp command-line argument arrays for probing and downloading.
///
/// Everything is returned as a plain `[String]` argv — no shell quoting — so the
/// arrays can be handed straight to `Process`/`posix_spawn`. All logic here is
/// pure and offline-testable.
public struct YTDLPArguments: Sendable {
    public init() {}

    /// Machine-readable progress line format. yt-dlp prints one line per update:
    ///
    /// `PROGRESS <status> <downloaded> <total> <total_estimate> <speed> <eta>`
    ///
    /// Fields that are frequently `None` early in a download (`total_bytes`,
    /// `total_bytes_estimate`, `speed`, `eta`) use the `s` conversion rather than
    /// `d`: yt-dlp's `d` formatting of a `None` value is inconsistent across
    /// versions, whereas `s` reliably prints `NA`, which ``ProgressParser``
    /// already treats as absent.
    public static let progressTemplate =
        "download:PROGRESS %(progress.status)s %(progress.downloaded_bytes)d "
        + "%(progress.total_bytes)s %(progress.total_bytes_estimate)s "
        + "%(progress.speed)s %(progress.eta)s"

    /// Emitted once the final file has been moved into place (after mux/extract).
    public static let finalPathTemplate = "after_move:FINALPATH %(filepath)s"

    /// Output filename template appended to the destination directory.
    public static let filenameTemplate = "%(title)s.%(ext)s"

    /// Flags applied to every invocation to keep behavior deterministic and
    /// independent of the host environment:
    /// - `--ignore-config` ignores `~/.config/yt-dlp` and other config files.
    /// - `--no-plugin-dirs` disables loading of yt-dlp plugins. `--ignore-config`
    ///   does **not** cover these: a plugin is arbitrary Python that yt-dlp would
    ///   import and execute inside our non-sandboxed process, so a planted
    ///   `yt_dlp_plugins/` directory would be code execution. This closes that.
    /// - `--no-warnings` suppresses noise on stderr.
    /// - `--no-colors` prevents ANSI escapes leaking into parsed output.
    /// - `--socket-timeout 30` bounds hangs on stalled connections.
    public static let hardeningArguments = [
        "--ignore-config", "--no-plugin-dirs", "--no-warnings", "--no-colors",
        "--socket-timeout", "30",
    ]

    // MARK: - Probe

    /// Arguments to dump metadata as a single JSON object for `url`.
    ///
    /// A literal `--` precedes the URL so a value that begins with `-` can never be
    /// re-interpreted by yt-dlp as an option (e.g. `--exec`, which would run an
    /// arbitrary command). The URL is the sole positional argument.
    ///
    /// `auth` (defaulting to `.none`) injects the cookie/credential flags **before**
    /// the `--` terminator so a signed-in session is available when probing a
    /// site the user has legal access to. See ``authArguments(_:)``.
    public func probeArguments(
        url: URL, auth: AuthConfig = .none
    ) -> [String] {
        Self.hardeningArguments
            + sessionArguments(auth: auth)
            + ["-J", "--no-playlist", "--", url.absoluteString]
    }

    // MARK: - Download

    /// Arguments to perform a download for `request`, using the ffmpeg binaries
    /// located in `ffmpegDir`.
    ///
    /// `auth` (defaulting to `.none`) injects the cookie/credential flags **before**
    /// the `--` terminator. See ``authArguments(_:)``.
    public func downloadArguments(
        request: DownloadRequest,
        ffmpegDir: URL,
        auth: AuthConfig = .none
    ) -> [String] {
        var args: [String] = []

        // Format selector + type-specific remux / extract flags.
        args += formatSelectorArguments(for: request.kind)

        // Authentication flags (cookies), if any.
        args += sessionArguments(auth: auth)

        // Common download flags.
        args += Self.hardeningArguments
        // `--progress` forces progress reporting even when stdout/stderr is not a
        // TTY (our pipes never are); without it yt-dlp emits no `--progress-template`
        // lines at all. `--newline` makes each update its own `\n`-terminated line.
        // The progress lines and the `after_move:FINALPATH` line may land on either
        // stdout or stderr depending on yt-dlp version/mode, so ``YTDLPClient`` feeds
        // *both* streams through the parser; their machine-readable prefixes make
        // the classification unambiguous regardless of which stream they arrive on.
        args += ["--newline", "--progress", "--no-playlist"]

        // Destination directory is anchored via `-P home:<dir>` and the `-o`
        // template is a bare *filename* (no path separators). This prevents a
        // `%(title)s`/`%(id)s` value — untrusted metadata — from smuggling `../`
        // or an absolute path out of the chosen directory. `--restrict-filenames`
        // is mandatory (further strips separators/odd characters) and
        // `--trim-filenames 200` bounds the name length against ENAMETOOLONG.
        args += ["-P", "home:\(normalizedDirectory(request.destinationDirectory))"]
        args += ["-o", Self.filenameTemplate]
        args += ["--restrict-filenames"]
        args += ["--trim-filenames", "200"]

        args += ["--ffmpeg-location", ffmpegDir.path]
        args += ["--progress-template", Self.progressTemplate]
        args += ["--print", Self.finalPathTemplate]

        // `--` guards against a URL beginning with `-` being parsed as a flag;
        // the URL is the sole positional argument and stays last.
        args += ["--", request.url.absoluteString]
        return args
    }

    // MARK: - Authentication

    /// Translate an ``AuthConfig`` into the corresponding yt-dlp flags.
    ///
    /// - `.none` → no flags.
    /// - `.browserCookies(b)` → `["--cookies-from-browser", b.rawValue]`. The
    ///   browser identifier is an enum `rawValue`, so it is a fixed allowlist token
    ///   and can never be an attacker-controlled string.
    /// - `.cookiesFile(url)` → `["--cookies", url.path]`.
    ///
    /// All flags are emitted **before** the `--` option terminator by the callers,
    /// so they are always parsed as options and never confused with the positional
    /// URL. Cookie values themselves are never inspected or logged here.
    public func authArguments(_ auth: AuthConfig) -> [String] {
        switch auth.source {
        case .none:
            return []
        case let .browserCookies(browser):
            return ["--cookies-from-browser", browser.rawValue]
        case let .cookiesFile(url):
            return ["--cookies", url.path]
        }
    }

    /// The authentication flag list, emitted **before** the `--` terminator by both
    /// probe and download. Currently a thin wrapper over ``authArguments(_:)``.
    public func sessionArguments(auth: AuthConfig) -> [String] {
        authArguments(auth)
    }

    // MARK: - Helpers

    private func formatSelectorArguments(for kind: DownloadRequest.Kind) -> [String] {
        switch kind {
        case let .video(height, container):
            // Fallback chain, tried left-to-right:
            //  1. `bv*[…][ext=mp4]+ba[ext=m4a]` — the progressive/YouTube-style pair
            //     (mp4 video + m4a audio), muxed by ffmpeg.
            //  2. `bv*[…]+ba` — **HLS-safe**: any best video ≤H plus any best audio,
            //     with no `ext` constraint. Kinescope's HLS renditions are all
            //     video-only (`acodec=none`) and its audio is `ext=mp4`, not `m4a`,
            //     so `ba[ext=m4a]` never matches and there is no muxed rendition to
            //     fall back to — this rung is what makes HLS download at all.
            //  3. `b[…]` — a genuinely muxed rendition ≤H, the last resort.
            let selector =
                "bv*[height<=\(height)][ext=\(container)]+ba[ext=m4a]"
                + "/bv*[height<=\(height)]+ba"
                + "/b[height<=\(height)]"
            // `--remux-video` losslessly repackages into the requested container
            // when a fallback yields e.g. webm.
            return [
                "-f", selector,
                "--merge-output-format", container,
                "--remux-video", container,
            ]

        case let .audio(codec):
            switch codec {
            case .m4a:
                // Prefer the native AAC stream — no re-encode.
                return ["-f", "ba[ext=m4a]/ba/b"]
            case .mp3:
                return ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
            }
        }
    }

    /// The destination directory path with any trailing slash removed, for use as
    /// the `home:` root of `-P`.
    private func normalizedDirectory(_ destination: URL) -> String {
        var dir = destination.path
        while dir.count > 1 && dir.hasSuffix("/") {
            dir.removeLast()
        }
        return dir
    }
}
