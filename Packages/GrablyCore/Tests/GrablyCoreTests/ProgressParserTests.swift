import Foundation
import Testing
@testable import GrablyCore

@Suite("ProgressParser")
struct ProgressParserTests {
    private let parser = ProgressParser()

    // MARK: - Progress

    @Test("Mid-download progress with a known total")
    func midDownloadProgress() throws {
        // status downloaded total total_estimate speed eta
        let event = parser.parse(line: "PROGRESS downloading 1250000 2000000 NA 543210 12")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress, got \(String(describing: event))")
            return
        }
        #expect(p.status == "downloading")
        #expect(p.downloadedBytes == 1_250_000)
        #expect(p.totalBytes == 2_000_000)
        #expect(p.speed == 543_210)
        #expect(p.eta == 12)
        #expect(abs(p.fraction - 0.625) < 0.0001)
    }

    @Test("Early progress falls back to total_bytes_estimate")
    func earlyProgressUsesEstimate() throws {
        let event = parser.parse(line: "PROGRESS downloading 16384 NA 111500000 NA NA")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.downloadedBytes == 16384)
        #expect(p.totalBytes == 111_500_000) // from the estimate column
        #expect(p.speed == nil)
        #expect(p.eta == nil)
        #expect(p.fraction > 0 && p.fraction < 0.01)
    }

    @Test("NA and zero fields map to nil, not zero")
    func naAndZeroBecomeNil() throws {
        let event = parser.parse(line: "PROGRESS downloading 0 0 0 0 0")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.downloadedBytes == 0)
        #expect(p.totalBytes == nil)
        #expect(p.speed == nil)
        #expect(p.eta == nil)
        #expect(p.fraction == 0)
    }

    @Test("Finished status yields full completion")
    func finishedProgress() throws {
        let event = parser.parse(line: "PROGRESS finished 111500000 111500000 NA 0 0")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.status == "finished")
        #expect(p.fraction == 1)
    }

    @Test("Finished with unknown total still reports completion via status")
    func finishedWithUnknownTotal() throws {
        let event = parser.parse(line: "PROGRESS finished 5242880 NA NA NA NA")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.fraction == 1)
    }

    @Test("Malformed progress line (too few fields) is ignored")
    func malformedProgressIgnored() {
        #expect(parser.parse(line: "PROGRESS downloading 100") == nil)
    }

    @Test("Non-finite / out-of-range numeric fields do not trap")
    func nonFiniteFieldsAreNilNotCrash() {
        // downloaded=inf, total=nan, total_estimate=1e19, speed=inf, eta=nan.
        // Int64(Double) would trap on any of these; they must degrade to nil.
        let event = parser.parse(line: "PROGRESS downloading inf nan 1e19 inf nan")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress, got \(String(describing: event))")
            return
        }
        #expect(p.status == "downloading")
        // inf downloaded → unparseable → clamped to 0 by the fallback.
        #expect(p.downloadedBytes == 0)
        #expect(p.totalBytes == nil) // nan total and 1e19 estimate both rejected
        #expect(p.speed == nil)      // inf speed rejected
        #expect(p.eta == nil)        // nan eta rejected
        #expect(p.fraction == 0)
    }

    @Test("Huge finite integer beyond Int64 range degrades to nil for int fields")
    func hugeIntegerDegradesToNil() {
        // total/eta = 1e19 (> Int64.max ≈ 9.22e18) must not trap the Int64 cast.
        let event = parser.parse(line: "PROGRESS downloading 1000 1e19 1e19 1e19 1e19")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.downloadedBytes == 1000)
        #expect(p.totalBytes == nil) // out of Int64 range → rejected
        #expect(p.eta == nil)        // out of Int64 range → rejected
        // speed is a Double: a huge-but-finite value is kept (no overflow risk).
        #expect(p.speed == 1e19)
    }

    @Test("None tokens are treated as absent, like NA")
    func noneTokensAreAbsent() {
        let event = parser.parse(line: "PROGRESS downloading 2048 None None None None")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.downloadedBytes == 2048)
        #expect(p.totalBytes == nil)
        #expect(p.speed == nil)
        #expect(p.eta == nil)
    }

    @Test("Error status is surfaced as a progress snapshot")
    func errorStatus() {
        let event = parser.parse(line: "PROGRESS error 0 NA NA NA NA")
        guard case let .progress(p)? = event else {
            Issue.record("expected .progress")
            return
        }
        #expect(p.status == "error")
        #expect(p.fraction == 0)
    }

    @Test("Live stream with perpetually-unknown total stays at fraction 0 until finished")
    func liveStreamUnknownTotal() {
        let running = parser.parse(line: "PROGRESS downloading 5000000 NA NA 800000 NA")
        guard case let .progress(a)? = running else {
            Issue.record("expected .progress")
            return
        }
        #expect(a.totalBytes == nil)
        #expect(a.fraction == 0) // never a misleading partial bar without a total

        let done = parser.parse(line: "PROGRESS finished 9000000 NA NA NA NA")
        guard case let .progress(b)? = done else {
            Issue.record("expected .progress")
            return
        }
        #expect(b.fraction == 1) // completion inferred from status alone
    }

    // MARK: - Destination / post-processing / final path

    @Test("Destination line parses the file path")
    func destinationLine() throws {
        let line = "[download] Destination: /Users/me/Downloads/Video [dQw4w9WgXcQ].f137.mp4"
        guard case let .destination(url)? = parser.parse(line: line) else {
            Issue.record("expected .destination")
            return
        }
        #expect(url.path == "/Users/me/Downloads/Video [dQw4w9WgXcQ].f137.mp4")
    }

    @Test("Destination marker in the middle of a line is not a false destination")
    func destinationMarkerMustBePrefix() {
        // The marker only counts as an anchor at the start of the (trimmed) line.
        let line = "note: [download] Destination: /Users/me/should-not-match.mp4"
        #expect(parser.parse(line: line) == nil)
    }

    @Test("Merger post-processing line is recognized")
    func mergerLine() throws {
        let line = "[Merger] Merging formats into \"/Users/me/Downloads/Video [id].mp4\""
        guard case let .postProcessing(text)? = parser.parse(line: line) else {
            Issue.record("expected .postProcessing")
            return
        }
        #expect(text.contains("Merging formats"))
    }

    @Test("ExtractAudio post-processing line is recognized")
    func extractAudioLine() throws {
        let line = "[ExtractAudio] Destination: /Users/me/Downloads/Song [id].mp3"
        guard case .postProcessing? = parser.parse(line: line) else {
            Issue.record("expected .postProcessing")
            return
        }
    }

    @Test("FINALPATH line yields the final on-disk URL")
    func finalPathLine() throws {
        let line = "FINALPATH /Users/me/Downloads/Video [dQw4w9WgXcQ].mp4"
        guard case let .finalPath(url)? = parser.parse(line: line) else {
            Issue.record("expected .finalPath")
            return
        }
        #expect(url.path == "/Users/me/Downloads/Video [dQw4w9WgXcQ].mp4")
        #expect(url.isFileURL)
    }

    @Test("FINALPATH with spaces in the path is preserved")
    func finalPathWithSpaces() throws {
        let line = "FINALPATH /Users/me/Downloads/My Great Song [abc].mp3"
        guard case let .finalPath(url)? = parser.parse(line: line) else {
            Issue.record("expected .finalPath")
            return
        }
        #expect(url.path == "/Users/me/Downloads/My Great Song [abc].mp3")
    }

    // MARK: - Noise

    @Test("Unrelated lines return nil", arguments: [
        "",
        "   ",
        "[youtube] dQw4w9WgXcQ: Downloading webpage",
        "[info] Downloading 1 format(s): 137+140",
        "WARNING: something happened",
        "PROGRESS",
    ])
    func garbageReturnsNil(_ line: String) {
        #expect(parser.parse(line: line) == nil)
    }

    // MARK: - Sequential multi-format scenario

    @Test("A full video+audio download sequence parses in order")
    func fullDownloadSequence() {
        let lines = [
            "[info] Downloading 1 format(s): 137+140",
            "[download] Destination: /Users/me/Downloads/Video [id].f137.mp4",
            "PROGRESS downloading 0 NA 111500000 NA NA",
            "PROGRESS downloading 55750000 111500000 NA 8000000 7",
            "PROGRESS finished 111500000 111500000 NA 0 0",
            "[download] Destination: /Users/me/Downloads/Video [id].f140.m4a",
            "PROGRESS downloading 1712500 3425000 NA 900000 2",
            "PROGRESS finished 3425000 3425000 NA 0 0",
            "[Merger] Merging formats into \"/Users/me/Downloads/Video [id].mp4\"",
            "FINALPATH /Users/me/Downloads/Video [id].mp4",
        ]

        let events = lines.compactMap { parser.parse(line: $0) }

        // Two destinations, five progress snapshots, one merge, one final path.
        var destinations = 0, progresses = 0, postProc = 0, finals = 0
        for event in events {
            switch event {
            case .destination: destinations += 1
            case .progress: progresses += 1
            case .postProcessing: postProc += 1
            case .finalPath: finals += 1
            }
        }
        #expect(destinations == 2)
        #expect(progresses == 5)
        #expect(postProc == 1)
        #expect(finals == 1)

        // The last meaningful event is the final path.
        guard case .finalPath? = events.last else {
            Issue.record("expected trailing .finalPath")
            return
        }
    }
}
