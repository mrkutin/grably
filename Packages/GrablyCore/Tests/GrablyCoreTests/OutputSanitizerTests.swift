import Foundation
import Testing
@testable import GrablyCore

@Suite("OutputSanitizer")
struct OutputSanitizerTests {

    @Test("ANSI escape sequences are stripped")
    func stripsANSI() {
        let input = "title \u{1B}[31mRED\u{1B}[0m end"
        #expect(OutputSanitizer.sanitize(input) == "title [31mRED[0m end")
    }

    @Test("BEL and other C0 controls are removed")
    func stripsC0() {
        let input = "a\u{07}b\u{00}c\u{1F}d"
        #expect(OutputSanitizer.sanitize(input) == "abcd")
    }

    @Test("Carriage return is removed")
    func stripsCarriageReturn() {
        #expect(OutputSanitizer.sanitize("line\rmore") == "linemore")
    }

    @Test("Tabs are preserved")
    func keepsTab() {
        #expect(OutputSanitizer.sanitize("col1\tcol2") == "col1\tcol2")
    }

    @Test("DEL and C1 controls are removed")
    func stripsDELandC1() {
        let input = "x\u{7F}y\u{85}z\u{9F}w"
        #expect(OutputSanitizer.sanitize(input) == "xyzw")
    }

    @Test("Ordinary unicode text is untouched")
    func keepsUnicode() {
        let input = "café — 日本語 🎬"
        #expect(OutputSanitizer.sanitize(input) == input)
    }
}
