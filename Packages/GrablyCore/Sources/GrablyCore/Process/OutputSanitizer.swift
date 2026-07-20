import Foundation

/// Strips terminal control characters from subprocess output before it is logged
/// or shown in the UI.
///
/// yt-dlp echoes untrusted metadata (video title, uploader, description) into its
/// stderr/stdout lines. A crafted title can embed ANSI escape sequences (`ESC[…`),
/// the bell (`BEL`), carriage returns, or other C0/C1 control bytes; if written
/// verbatim to a terminal or an `NSTextView` these can spoof output, hide text, or
/// re-position the cursor. This removes every C0 (`0x00–0x1F`) and C1
/// (`0x80–0x9F`) control code except the horizontal tab (`0x09`), which is benign
/// and worth preserving for alignment.
///
/// Only apply this to strings destined for logs/UI — never to lines being parsed
/// as the machine-readable `PROGRESS`/`FINALPATH` protocol, whose format is fixed.
public enum OutputSanitizer {
    /// Return `line` with control characters removed (tab excepted).
    public static func sanitize(_ line: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars {
            let value = scalar.value
            let isC0 = value <= 0x1F
            let isDelete = value == 0x7F
            let isC1 = value >= 0x80 && value <= 0x9F
            if (isC0 || isDelete || isC1) && scalar != "\t" {
                continue
            }
            result.append(scalar)
        }
        return String(result)
    }
}
