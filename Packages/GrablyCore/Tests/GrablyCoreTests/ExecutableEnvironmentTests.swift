import Foundation
import Testing
@testable import GrablyCore

@Suite("ProcessEnvironment resolution invariants")
struct ExecutableEnvironmentTests {

    @Test("Dangerous loader/interpreter variables are stripped even if supplied")
    func stripsDangerousVariables() {
        let hostile = [
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DYLD_LIBRARY_PATH": "/tmp",
            "LD_PRELOAD": "/tmp/evil.so",
            "LD_LIBRARY_PATH": "/tmp",
            "PYTHONPATH": "/tmp/pkgs",
            "PYTHONHOME": "/tmp/py",
            "PYTHONSTARTUP": "/tmp/rc.py",
            "PATH": "/custom/bin",
        ]
        let resolved = ProcessEnvironment.resolve(hostile)

        for key in ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD",
                    "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP"] {
            #expect(resolved[key] == nil, "\(key) must not survive resolve()")
        }
        // Allowed keys survive; locale is forced on.
        #expect(resolved["PATH"] == "/custom/bin")
        #expect(resolved["LC_ALL"] == "en_US.UTF-8")
        #expect(resolved["PYTHONIOENCODING"] == "utf-8")
    }

    @Test("A caller env without PATH still gets a usable default PATH")
    func defaultsPathWhenMissing() {
        let resolved = ProcessEnvironment.resolve(["HOME": "/Users/me"])
        #expect(resolved["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(resolved["HOME"] == "/Users/me")
    }

    @Test("An empty caller env yields the base environment")
    func emptyYieldsBase() {
        let resolved = ProcessEnvironment.resolve([:])
        #expect(resolved["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(resolved["LC_ALL"] == "en_US.UTF-8")
        #expect(resolved["PYTHONIOENCODING"] == "utf-8")
        // No stray keys leaked in.
        #expect(resolved["DYLD_INSERT_LIBRARIES"] == nil)
    }

    @Test("An empty PATH string is replaced by the default")
    func emptyPathReplaced() {
        let resolved = ProcessEnvironment.resolve(["PATH": ""])
        #expect(resolved["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
