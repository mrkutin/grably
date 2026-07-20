import Foundation

/// Describes the location of the bundled helper executables and the
/// environment they should run under.
public struct ExecutableEnvironment: Sendable {
    /// Path to the yt-dlp executable.
    public let ytdlpURL: URL
    /// Path to the ffmpeg executable.
    public let ffmpegURL: URL
    /// Path to the ffprobe executable.
    public let ffprobeURL: URL
    /// Additional environment variables to inject into spawned processes.
    public let extraEnvironment: [String: String]

    public init(
        ytdlpURL: URL,
        ffmpegURL: URL,
        ffprobeURL: URL,
        extraEnvironment: [String: String] = [:]
    ) {
        self.ytdlpURL = ytdlpURL
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
        self.extraEnvironment = extraEnvironment
    }
}

/// Builds the environment-variable dictionaries that spawned helper processes
/// run under.
///
/// yt-dlp and ffmpeg emit non-ASCII text (titles, paths) and must be pinned to a
/// UTF-8 locale, otherwise Python raises `UnicodeEncodeError` mid-download and
/// yt-dlp mangles filenames. `LC_ALL=en_US.UTF-8` and `PYTHONIOENCODING=utf-8`
/// are therefore forced on every launch.
///
/// A namespace (uninhabited `enum`) rather than a value type — it holds no state,
/// only pure builders.
public enum ProcessEnvironment {
    /// The default `PATH` search directories, in priority order.
    public static let defaultSearchPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// UTF-8 locale/encoding variables forced onto every spawned process.
    public static let localeOverrides: [String: String] = [
        "LC_ALL": "en_US.UTF-8",
        "PYTHONIOENCODING": "utf-8",
    ]

    /// The only environment keys a caller may contribute to the final process
    /// environment. Everything else is dropped.
    ///
    /// This is a strict allowlist (deny-by-default) so that dynamic-loader and
    /// interpreter-hijacking variables inherited from the host — most critically
    /// `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `LD_PRELOAD`/`LD_LIBRARY_PATH`
    /// and `PYTHONPATH`/`PYTHONHOME`/`PYTHONSTARTUP` — can never reach yt-dlp or
    /// ffmpeg. The app is not sandboxed, so an attacker-influenced env var here
    /// would be arbitrary code execution inside our process tree. `PATH` and the
    /// forced UTF-8 locale are added unconditionally below regardless of this set.
    public static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "TMPDIR",
    ]

    /// A minimal, deterministic base environment: a fixed `PATH` plus the UTF-8
    /// locale overrides. Independent of the host's inherited environment so
    /// launches behave identically regardless of how the app was started.
    ///
    /// - Parameter extraPATH: directories prepended to the default search paths
    ///   (e.g. the bundled-binaries directory).
    public static func base(extraPATH: [String] = []) -> [String: String] {
        var environment = localeOverrides
        environment["PATH"] = (extraPATH + defaultSearchPaths).joined(separator: ":")
        return environment
    }

    /// The environment used by `ProcessLaunch` when a caller supplies none.
    public static var defaultEnvironment: [String: String] { base() }

    /// Resolve the final environment for a launch.
    ///
    /// The result is built from scratch, never inherited from the host: only keys
    /// in ``allowedEnvironmentKeys`` are copied from `environment`, then the UTF-8
    /// locale overrides are forced on, and a `PATH` is guaranteed (the default
    /// search paths are substituted if the caller supplied none). This means a
    /// hostile `DYLD_*` / `LD_*` / `PYTHONPATH` entry in `environment` is silently
    /// discarded rather than passed to the child.
    public static func resolve(_ environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        // Deny-by-default: keep only explicitly allowed keys from the caller.
        for (key, value) in environment where allowedEnvironmentKeys.contains(key) {
            result[key] = value
        }

        // Force the UTF-8 locale so it can never be dropped or overridden.
        for (key, value) in localeOverrides {
            result[key] = value
        }

        // Guarantee a usable PATH even if the caller supplied none (or an empty one).
        if result["PATH"]?.isEmpty ?? true {
            result["PATH"] = base()["PATH"]
        }

        return result
    }
}
