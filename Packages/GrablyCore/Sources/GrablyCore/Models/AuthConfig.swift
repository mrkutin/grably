import Foundation

/// How grably should authenticate to a site that requires a signed-in session
/// (the user has legal access; yt-dlp reuses their credentials/cookies).
///
/// The type is deliberately closed: the only browser identifiers ever handed to
/// yt-dlp come from ``Browser`` (an enum with a fixed `rawValue` allowlist), so an
/// arbitrary attacker-controlled string can never reach the `--cookies-from-browser`
/// flag. A cookies file is passed by its resolved filesystem path only.
///
/// Sendable/Equatable so it can cross the actor boundary into ``YTDLPClient`` and
/// be diffed by the UI. Cookie *values* and any credentials are never stored here
/// and never logged.
public struct AuthConfig: Sendable, Equatable {
    /// Where yt-dlp should source the authenticated session from.
    public enum Source: Sendable, Equatable {
        /// No authentication — public content only.
        case none
        /// Reuse the login session from a locally installed browser
        /// (`--cookies-from-browser`). The user must be logged in to the target
        /// site in that browser.
        case browserCookies(Browser)
        /// Read cookies from a Netscape-format `cookies.txt` file (`--cookies`).
        case cookiesFile(URL)
    }

    /// The browsers yt-dlp can extract cookies from. This is a strict allowlist:
    /// only these `rawValue`s are ever passed to `--cookies-from-browser`, so no
    /// free-form string can be smuggled into the argv (which could otherwise pass
    /// yt-dlp a `keyring`/`profile` suffix or an unexpected token).
    public enum Browser: String, Sendable, Equatable, CaseIterable {
        case safari
        case chrome
        case firefox
        case edge
        case brave
        case opera
        case vivaldi
        case chromium
    }

    public var source: Source

    public init(source: Source) {
        self.source = source
    }

    /// The default: no authentication.
    public static let none = AuthConfig(source: .none)
}
