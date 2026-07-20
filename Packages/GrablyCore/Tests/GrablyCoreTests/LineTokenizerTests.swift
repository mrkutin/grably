import Foundation
import Testing
@testable import GrablyCore

@Suite("LineTokenizer")
struct LineTokenizerTests {

    private func push(_ tokenizer: inout LineTokenizer, _ string: String) -> [String] {
        tokenizer.push(Data(string.utf8))
    }

    @Test("Splits on line feeds")
    func splitsOnLineFeed() {
        var t = LineTokenizer()
        #expect(push(&t, "alpha\nbeta\ngamma\n") == ["alpha", "beta", "gamma"])
        #expect(t.finish() == nil)
    }

    @Test("Splits on carriage returns (progress updates)")
    func splitsOnCarriageReturn() {
        var t = LineTokenizer()
        #expect(push(&t, "10%\r20%\r30%\r") == ["10%", "20%", "30%"])
        #expect(t.finish() == nil)
    }

    @Test("Treats CRLF as a single break")
    func collapsesCRLF() {
        var t = LineTokenizer()
        #expect(push(&t, "line1\r\nline2\r\n") == ["line1", "line2"])
        #expect(t.finish() == nil)
    }

    @Test("A CRLF split across two chunks stays a single break")
    func crlfAcrossChunks() {
        var t = LineTokenizer()
        #expect(push(&t, "line1\r") == ["line1"])
        // The leading \n must be swallowed, not emitted as an empty line.
        #expect(push(&t, "\nline2\n") == ["line2"])
        #expect(t.finish() == nil)
    }

    @Test("Buffers a partial line until a delimiter arrives")
    func buffersPartialLine() {
        var t = LineTokenizer()
        #expect(push(&t, "PROG").isEmpty)
        #expect(push(&t, "RESS down").isEmpty)
        #expect(push(&t, "loading 1 2 NA 3 4\n") == ["PROGRESS downloading 1 2 NA 3 4"])
    }

    @Test("finish flushes a trailing unterminated line")
    func finishFlushesRemainder() {
        var t = LineTokenizer()
        #expect(push(&t, "first\nsecond") == ["first"])
        #expect(t.finish() == "second")
        // Idempotent once drained.
        #expect(t.finish() == nil)
    }

    @Test("A multi-byte UTF-8 scalar split across chunks decodes correctly")
    func utf8ScalarAcrossChunks() {
        // "café — 日本語" contains 2-byte (é), 3-byte (—, 日本語) scalars.
        let full = "café — 日本語"
        let bytes = Array(full.utf8)
        let splitPoint = 4 // lands inside the é (0xC3 0xA9) sequence
        let first = Data(bytes[..<splitPoint])
        let second = Data(bytes[splitPoint...])

        var t = LineTokenizer()
        #expect(t.push(first).isEmpty) // incomplete scalar buffered, nothing emitted
        var lines = t.push(second)
        lines += t.push(Data("\n".utf8))
        #expect(lines == [full])
    }

    @Test("Mixed \\r and \\n in one stream")
    func mixedDelimiters() {
        var t = LineTokenizer()
        let result = push(&t, "a\nb\rc\r\nd")
        #expect(result == ["a", "b", "c"])
        #expect(t.finish() == "d")
    }

    @Test("A lone trailing CR does not swallow the next chunk's first byte")
    func loneCRThenNonLF() {
        var t = LineTokenizer()
        // Chunk ends on a bare \r (not part of CRLF)…
        #expect(push(&t, "abc\r") == ["abc"])
        // …and the next chunk starts with ordinary content, not \n:
        // that content must be kept, not dropped as a phantom CRLF tail.
        #expect(push(&t, "def\n") == ["def"])
        #expect(t.finish() == nil)
    }

    @Test("A very large single line is buffered and decoded intact")
    func largeSingleLine() {
        var t = LineTokenizer()
        // Simulates a multi-chunk JSON probe arriving as one delimiter-free line.
        let chunk = String(repeating: "x", count: 200_000)
        #expect(t.push(Data(chunk.utf8)).isEmpty)
        #expect(t.push(Data(chunk.utf8)).isEmpty)
        let lines = t.push(Data("\n".utf8))
        #expect(lines.count == 1)
        #expect(lines.first?.count == 400_000)
    }

    @Test("An over-length line is truncated with a marker, then recovers")
    func overLengthLineTruncated() {
        // Tiny cap so we don't have to stream megabytes to exercise the guard.
        var t = LineTokenizer(maxLineBytes: 8)
        // 20 'x' bytes with no delimiter must be capped at 8 + marker, and the
        // overflow discarded until the next line break.
        #expect(t.push(Data(String(repeating: "x", count: 20).utf8)).isEmpty)
        let lines = t.push(Data("\nnext\n".utf8))
        #expect(lines.count == 2)
        #expect(lines[0] == "xxxxxxxx…[truncated]")
        // The tokenizer recovers: the following line is intact.
        #expect(lines[1] == "next")
        #expect(t.finish() == nil)
    }

    @Test("Truncation marker is appended at most once across chunks")
    func truncationMarkerOnce() {
        var t = LineTokenizer(maxLineBytes: 4)
        #expect(t.push(Data("aaaa".utf8)).isEmpty)      // fills to cap
        #expect(t.push(Data("bbbb".utf8)).isEmpty)      // overflow, marker added
        #expect(t.push(Data("cccc".utf8)).isEmpty)      // still discarding
        #expect(t.finish() == "aaaa…[truncated]")
    }

    @Test("A line exactly at the cap is not truncated")
    func exactCapNotTruncated() {
        var t = LineTokenizer(maxLineBytes: 5)
        let lines = t.push(Data("hello\n".utf8))
        #expect(lines == ["hello"])
    }

    @Test("Empty data pushes nothing")
    func emptyPush() {
        var t = LineTokenizer()
        #expect(t.push(Data()).isEmpty)
        #expect(t.finish() == nil)
    }

    @Test("ProcessLineReader facade delegates to the tokenizer")
    func processLineReaderFacade() {
        var reader = ProcessLineReader()
        #expect(reader.feed(Data("one\ntwo".utf8)) == ["one"])
        #expect(reader.flush() == "two")
    }
}
