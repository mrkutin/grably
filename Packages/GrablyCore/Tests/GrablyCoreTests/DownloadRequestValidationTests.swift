import Foundation
import Testing
@testable import GrablyCore

@Suite("DownloadRequest URL validation")
struct DownloadRequestValidationTests {
    private let dest = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)

    @Test("https URLs are accepted")
    func httpsAccepted() throws {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let request = try DownloadRequest.validated(url: url, destinationDirectory: dest)
        #expect(request.url == url)
    }

    @Test("http URLs are accepted (scheme allowlist is case-insensitive)")
    func httpAccepted() throws {
        let url = URL(string: "HTTP://example.com/video")!
        let request = try DownloadRequest.validated(url: url, destinationDirectory: dest)
        #expect(request.url == url)
    }

    @Test("file:// URLs are rejected")
    func fileRejected() {
        let url = URL(string: "file:///etc/passwd")!
        #expect(throws: RequestValidationError.unsupportedScheme("file")) {
            _ = try DownloadRequest.validated(url: url, destinationDirectory: dest)
        }
    }

    @Test("data: URLs are rejected")
    func dataRejected() {
        let url = URL(string: "data:text/plain;base64,SGVsbG8=")!
        #expect(throws: RequestValidationError.unsupportedScheme("data")) {
            _ = try DownloadRequest.validated(url: url, destinationDirectory: dest)
        }
    }

    @Test("Other schemes (ftp, ssh) are rejected")
    func otherSchemesRejected() {
        for string in ["ftp://host/f", "ssh://host/f", "javascript:alert(1)"] {
            let url = URL(string: string)!
            #expect(throws: (any Error).self) {
                _ = try DownloadRequest.validated(url: url, destinationDirectory: dest)
            }
        }
    }

    @Test("validate(url:) throws for a scheme-less URL")
    func schemelessRejected() {
        let url = URL(fileURLWithPath: "/tmp/x") // has file scheme
        #expect(throws: (any Error).self) {
            try DownloadRequest.validate(url: url)
        }
    }
}
