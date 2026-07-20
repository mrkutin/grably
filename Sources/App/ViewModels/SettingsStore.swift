import Foundation
import Observation
import GrablyCore

/// Persisted user preferences backed by `UserDefaults`.
///
/// The download directory is persisted as a bookmark so the chosen folder keeps
/// resolving across launches even if it moves or is renamed. The app is not
/// sandboxed (it must spawn helper processes), so the security-scoped options are
/// best-effort: on a non-sandboxed process `startAccessingSecurityScopedResource`
/// is effectively a no-op, and we degrade to a plain path when a scoped bookmark
/// cannot be produced.
@MainActor
@Observable
final class SettingsStore {
    /// The default download destination.
    var downloadDirectory: URL {
        didSet { persistDownloadDirectory() }
    }

    /// Default media type used when a fresh probe finishes.
    var defaultKind: MediaKind {
        didSet { defaults.set(defaultKind.rawValue, forKey: Keys.defaultKind) }
    }

    /// Default audio codec used when the audio type is selected.
    var defaultAudioCodec: DownloadRequest.AudioCodec {
        didSet { defaults.set(defaultAudioCodec.rawValue, forKey: Keys.defaultAudioCodec) }
    }

    /// Preferred video ceiling (px height) applied as the default quality.
    var defaultVideoHeight: Int {
        didSet { defaults.set(defaultVideoHeight, forKey: Keys.defaultVideoHeight) }
    }

    /// How grably authenticates to sites requiring a signed-in session.
    ///
    /// Persisted as a small discriminator plus (for the cookies file) a
    /// security-scoped bookmark, mirroring the download-directory scheme. Cookie
    /// values are never stored here — only the source *selection*.
    var authConfig: AuthConfig {
        didSet { persistAuth() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let downloadBookmark = "downloadDirectoryBookmark"
        static let downloadPath = "downloadDirectoryPath"
        static let defaultKind = "defaultKind"
        static let defaultAudioCodec = "defaultAudioCodec"
        static let defaultVideoHeight = "defaultVideoHeight"
        static let authSource = "authSource"          // "none" | "browser" | "file"
        static let authBrowser = "authBrowser"         // Browser.rawValue
        static let authCookiesBookmark = "authCookiesBookmark"
        static let authCookiesPath = "authCookiesPath"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Resolve the persisted download directory (bookmark → path → Downloads).
        let fallback = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.downloadDirectory = Self.resolveDownloadDirectory(defaults, fallback: fallback)

        // Restore the format defaults.
        self.defaultKind = MediaKind(rawValue: defaults.string(forKey: Keys.defaultKind) ?? "")
            ?? .video
        self.defaultAudioCodec = DownloadRequest.AudioCodec(
            rawValue: defaults.string(forKey: Keys.defaultAudioCodec) ?? ""
        ) ?? .mp3
        let storedHeight = defaults.integer(forKey: Keys.defaultVideoHeight)
        self.defaultVideoHeight = storedHeight == 0 ? 1080 : storedHeight

        // Restore the authentication selection.
        self.authConfig = Self.resolveAuthConfig(defaults)
    }

    // MARK: - Download directory persistence

    /// Update the download directory from a user selection (e.g. NSOpenPanel).
    func setDownloadDirectory(_ url: URL) {
        downloadDirectory = url
    }

    private func persistDownloadDirectory() {
        defaults.set(downloadDirectory.path, forKey: Keys.downloadPath)
        // Try a security-scoped bookmark first; fall back to a plain one, then to
        // just the path (already stored above).
        if let data = try? downloadDirectory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(data, forKey: Keys.downloadBookmark)
        } else if let data = try? downloadDirectory.bookmarkData() {
            defaults.set(data, forKey: Keys.downloadBookmark)
        } else {
            defaults.removeObject(forKey: Keys.downloadBookmark)
        }
    }

    // MARK: - Authentication persistence

    /// Convenience for the UI's source Picker (three mutually exclusive modes).
    enum AuthSourceKind: String, CaseIterable, Hashable {
        case none
        case browser
        case file
    }

    /// The current source as a UI-friendly discriminator.
    var authSourceKind: AuthSourceKind {
        switch authConfig.source {
        case .none: return .none
        case .browserCookies: return .browser
        case .cookiesFile: return .file
        }
    }

    /// Currently selected browser (defaults to Safari when not in browser mode), so
    /// the UI Picker always has a concrete value to bind.
    var authBrowser: AuthConfig.Browser {
        if case let .browserCookies(browser) = authConfig.source { return browser }
        return .safari
    }

    /// Resolved cookies file URL when in file mode, else nil.
    var authCookiesFile: URL? {
        if case let .cookiesFile(url) = authConfig.source { return url }
        return nil
    }

    /// Switch the auth source mode from the UI. Preserves the last browser choice
    /// and re-resolves the persisted cookies file when returning to those modes.
    func setAuthSource(_ kind: AuthSourceKind) {
        switch kind {
        case .none:
            authConfig = .none
        case .browser:
            authConfig = AuthConfig(source: .browserCookies(authBrowser))
        case .file:
            if let url = authCookiesFile ?? Self.resolveCookiesFile(defaults) {
                authConfig = AuthConfig(source: .cookiesFile(url))
            } else {
                // No file chosen yet; stay in file mode with an empty selection by
                // leaving source as-is until the user picks one.
                authConfig = AuthConfig(source: .none)
            }
        }
    }

    /// Set the browser used for `--cookies-from-browser`.
    func setAuthBrowser(_ browser: AuthConfig.Browser) {
        authConfig = AuthConfig(source: .browserCookies(browser))
    }

    /// Set the cookies.txt file (e.g. from an NSOpenPanel selection).
    func setAuthCookiesFile(_ url: URL) {
        authConfig = AuthConfig(source: .cookiesFile(url))
    }

    private func persistAuth() {
        switch authConfig.source {
        case .none:
            defaults.set(AuthSourceKind.none.rawValue, forKey: Keys.authSource)
        case let .browserCookies(browser):
            defaults.set(AuthSourceKind.browser.rawValue, forKey: Keys.authSource)
            defaults.set(browser.rawValue, forKey: Keys.authBrowser)
        case let .cookiesFile(url):
            defaults.set(AuthSourceKind.file.rawValue, forKey: Keys.authSource)
            defaults.set(url.path, forKey: Keys.authCookiesPath)
            // Security-scoped bookmark (best-effort; app is not sandboxed).
            if let data = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                defaults.set(data, forKey: Keys.authCookiesBookmark)
            } else if let data = try? url.bookmarkData() {
                defaults.set(data, forKey: Keys.authCookiesBookmark)
            } else {
                defaults.removeObject(forKey: Keys.authCookiesBookmark)
            }
        }
    }

    private static func resolveAuthConfig(_ defaults: UserDefaults) -> AuthConfig {
        let kind = AuthSourceKind(rawValue: defaults.string(forKey: Keys.authSource) ?? "")
        switch kind {
        case .some(.browser):
            let browser = AuthConfig.Browser(
                rawValue: defaults.string(forKey: Keys.authBrowser) ?? ""
            ) ?? .safari
            return AuthConfig(source: .browserCookies(browser))
        case .some(.file):
            if let url = resolveCookiesFile(defaults) {
                return AuthConfig(source: .cookiesFile(url))
            }
            return .none
        case .some(.none), Optional.none:
            return .none
        }
    }

    private static func resolveCookiesFile(_ defaults: UserDefaults) -> URL? {
        if let data = defaults.data(forKey: Keys.authCookiesBookmark) {
            var isStale = false
            if let url = (try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &isStale
            )) ?? (try? URL(
                resolvingBookmarkData: data, options: [],
                relativeTo: nil, bookmarkDataIsStale: &isStale
            )) {
                return url
            }
        }
        if let path = defaults.string(forKey: Keys.authCookiesPath) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func resolveDownloadDirectory(
        _ defaults: UserDefaults, fallback: URL
    ) -> URL {
        if let data = defaults.data(forKey: Keys.downloadBookmark) {
            var isStale = false
            // Attempt scoped resolution first; on a non-sandboxed process this
            // succeeds for non-scoped bookmarks too. If it throws, try plain.
            if let url = (try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) ?? (try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) {
                // A stale bookmark still resolves; the didSet on the next explicit
                // change refreshes it. Refresh eagerly here too.
                if isStale {
                    let refreshed = (try? url.bookmarkData(options: [.withSecurityScope]))
                        ?? (try? url.bookmarkData())
                    if let refreshed { defaults.set(refreshed, forKey: Keys.downloadBookmark) }
                }
                return url
            }
        }
        if let path = defaults.string(forKey: Keys.downloadPath) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fallback
    }
}

/// User-facing media type selection.
public enum MediaKind: String, CaseIterable, Hashable, Sendable {
    case video
    case audio
}
