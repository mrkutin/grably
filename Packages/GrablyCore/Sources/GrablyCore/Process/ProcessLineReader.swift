import Foundation

/// A single line of output from a subprocess, tagged with its source stream.
public struct ProcessLine: Sendable, Hashable {
    public enum Stream: Sendable, Hashable {
        case standardOutput
        case standardError
    }

    public let stream: Stream
    public let text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Splits a raw byte stream into complete UTF-8 lines.
///
/// yt-dlp emits progress with carriage returns (`\r`) for in-place updates and
/// regular output with `\n` (and may mix `\r\n`), so this tokenizer treats `\n`,
/// `\r`, and `\r\n` all as a single line break.
///
/// Bytes are buffered raw between `push(_:)` calls, so a chunk boundary that
/// falls in the middle of a multi-byte UTF-8 scalar is handled correctly: only
/// delimiter-terminated segments are decoded, and line delimiters are ASCII
/// bytes that can never appear inside a UTF-8 continuation.
public struct LineTokenizer: Sendable {
    private static let lineFeed: UInt8 = 0x0A // \n
    private static let carriageReturn: UInt8 = 0x0D // \r
    /// Appended once when an over-length line is truncated.
    private static let truncationMarker: [UInt8] = Array("…[truncated]".utf8)

    /// Default cap on a single accumulated line before truncation.
    ///
    /// Chosen large (8 MiB) rather than the ~64 KiB suggested by the review: a
    /// yt-dlp `-J` probe emits its entire metadata document as one delimiter-free
    /// line, which is routinely tens–hundreds of KiB and occasionally a few MiB.
    /// A 64 KiB cap would corrupt that legitimate output, so the cap is set well
    /// above realistic probe sizes while still bounding memory against a broken or
    /// hostile process that streams megabytes with no line delimiter at all. The
    /// per-run aggregate byte backstop in ``ProcessRunner`` is the second layer.
    public static let defaultMaxLineBytes = 8 * 1024 * 1024

    /// Cap on the accumulated `pending` buffer before the line is truncated.
    private let maxLineBytes: Int

    /// Bytes of the line currently being accumulated (not yet terminated).
    private var pending: [UInt8] = []
    /// Set once the current line hit `maxLineBytes`; further bytes are dropped
    /// until the next delimiter resets it.
    private var truncated = false
    /// After a `\r`, a following `\n` is the tail of a CRLF pair and is skipped.
    private var skipLineFeedAfterCR = false

    public init(maxLineBytes: Int = LineTokenizer.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Feed a chunk of bytes; returns every complete line produced so far.
    ///
    /// Scans the chunk in bulk via `withUnsafeBytes`, emitting each
    /// delimiter-terminated segment in one decode instead of appending byte by
    /// byte. This matters for very large payloads (e.g. a multi-megabyte JSON
    /// probe arriving as a single "line") which the previous per-byte loop made
    /// quadratic-ish through repeated buffer growth.
    public mutating func push(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var lines: [String] = []

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var segmentStart = 0
            var i = 0

            while i < count {
                let byte = bytes[i]

                if skipLineFeedAfterCR {
                    skipLineFeedAfterCR = false
                    if byte == Self.lineFeed {
                        // Second half of a CRLF pair split across chunks — the
                        // CR already broke the line; drop this LF.
                        segmentStart = i + 1
                        i += 1
                        continue
                    }
                }

                if byte == Self.lineFeed || byte == Self.carriageReturn {
                    emitSegment(bytes, from: segmentStart, to: i, into: &lines)
                    segmentStart = i + 1
                    if byte == Self.carriageReturn {
                        skipLineFeedAfterCR = true
                    }
                }
                i += 1
            }

            // Buffer the trailing, not-yet-terminated bytes for the next chunk.
            // Delimiters are ASCII, so a segment can only end on a complete UTF-8
            // scalar; an incomplete scalar can appear here and is decoded later.
            if segmentStart < count {
                appendPending(bytes, from: segmentStart, to: count)
            }
        }

        return lines
    }

    /// Emit `pending` + `bytes[start..<end]` as one decoded line, then reset the
    /// accumulation state. Avoids an intermediate copy in the common case where
    /// nothing is buffered and the line fits under the cap.
    private mutating func emitSegment(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        into lines: inout [String]
    ) {
        if pending.isEmpty && !truncated && (end - start) <= maxLineBytes {
            lines.append(String(decoding: bytes[start..<end], as: UTF8.self))
        } else {
            appendPending(bytes, from: start, to: end)
            lines.append(decodePending())
            pending.removeAll(keepingCapacity: true)
            truncated = false
        }
    }

    /// Append `bytes[start..<end]` to `pending`, capping the accumulated line at
    /// `maxLineBytes`. On overflow the buffer is filled to the cap, a truncation
    /// marker is appended once, and `truncated` is latched so the remainder of the
    /// line (across this and subsequent chunks) is discarded until a delimiter.
    private mutating func appendPending(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int
    ) {
        guard !truncated else { return }
        let incoming = end - start
        let room = maxLineBytes - pending.count
        if incoming <= room {
            pending.append(contentsOf: bytes[start..<end])
        } else {
            if room > 0 {
                pending.append(contentsOf: bytes[start..<(start + room)])
            }
            pending.append(contentsOf: Self.truncationMarker)
            truncated = true
        }
    }

    /// Flush any buffered bytes as a final, unterminated line.
    public mutating func finish() -> String? {
        guard !pending.isEmpty else {
            skipLineFeedAfterCR = false
            truncated = false
            return nil
        }
        let line = decodePending()
        pending.removeAll(keepingCapacity: false)
        truncated = false
        skipLineFeedAfterCR = false
        return line
    }

    private func decodePending() -> String {
        String(decoding: pending, as: UTF8.self)
    }
}

/// Buffers raw bytes from a pipe and splits them into UTF-8 lines.
///
/// Thin `feed`/`flush` facade over ``LineTokenizer`` retained for call sites that
/// prefer the reader vocabulary.
public struct ProcessLineReader: Sendable {
    private var tokenizer = LineTokenizer()

    public init() {}

    /// Feed a chunk of bytes; returns any complete lines produced so far.
    public mutating func feed(_ data: Data) -> [String] {
        tokenizer.push(data)
    }

    /// Flush any remaining buffered bytes as a final line.
    public mutating func flush() -> String? {
        tokenizer.finish()
    }
}
