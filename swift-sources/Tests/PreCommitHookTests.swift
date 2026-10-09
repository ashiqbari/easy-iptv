import XCTest
import Foundation

/// Real git commits in disposable repositories; Swift itself is stubbed so
/// testing the pre-commit hook does not recursively run this test suite.
final class PreCommitHookTests: XCTestCase {
    func testPassingTestsAllowCommitAndRunFullReleaseSuite() throws {
        let fixture = try HookFixture(exitCode: 0)
        defer { fixture.remove() }
        let result = try fixture.commit()
        XCTAssertEqual(result.status, 0, result.output)
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(log.contains("test -c release"))
        XCTAssertTrue(log.contains(fixture.root.appendingPathComponent("swift-sources").path))
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "HEAD"]).status, 0)
    }

    func testFailingTestsBlockCommitAndLeaveIndexUntouched() throws {
        let fixture = try HookFixture(exitCode: 27)
        defer { fixture.remove() }
        let result = try fixture.commit()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Commit blocked"))
        XCTAssertNotEqual(try fixture.git(["rev-parse", "--verify", "HEAD"]).status, 0)
        XCTAssertEqual(try fixture.git(["diff", "--cached", "--name-only"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "fixture.txt")
    }

    func testInstallerPreservesExistingHookConfiguration() throws {
        let fixture = try HookFixture(exitCode: 0)
        defer { fixture.remove() }
        _ = try fixture.git(["config", "core.hooksPath", "custom-hooks"])
        let result = try fixture.run("/bin/sh", [fixture.root.appendingPathComponent(".githooks/install.sh").path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.git(["config", "--get", "core.hooksPath"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "custom-hooks")
    }

    func testInstallerIsIdempotent() throws {
        let fixture = try HookFixture(exitCode: 0)
        defer { fixture.remove() }
        for _ in 0..<2 {
            let result = try fixture.run("/bin/sh", [fixture.root.appendingPathComponent(".githooks/install.sh").path])
            XCTAssertEqual(result.status, 0, result.output)
        }
        XCTAssertEqual(try fixture.git(["config", "--get", "core.hooksPath"]).output.trimmingCharacters(in: .whitespacesAndNewlines), ".githooks")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.root.appendingPathComponent(".githooks/pre-commit").path))
    }

    func testMissingSwiftBlocksHook() throws {
        let fixture = try HookFixture(exitCode: 0)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("bin/swift"))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("bin/git").path, withDestinationPath: "/usr/bin/git")
        let result = try fixture.run("/bin/sh", [fixture.root.appendingPathComponent(".githooks/pre-commit").path], path: fixture.root.appendingPathComponent("bin").path)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Swift is unavailable"))
    }
}

private struct HookFixture {
    let root: URL
    var log: URL { root.appendingPathComponent("swift-invocation.log") }

    init(exitCode: Int) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-tests-\(UUID())")
        let files = FileManager.default
        for name in ["swift-sources", ".githooks", "bin"] {
            try files.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["pre-commit", "install.sh"] {
            try files.copyItem(at: repo.appendingPathComponent(".githooks/\(name)"), to: root.appendingPathComponent(".githooks/\(name)"))
        }
        let stub = root.appendingPathComponent("bin/swift")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$*\" > \"$HOOK_TEST_LOG\"\nexit \(exitCode)\n".write(to: stub, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".githooks/pre-commit").path)
        _ = try git(["init", "-q"])
        _ = try git(["config", "core.hooksPath", ".githooks"])
        try "fixture".write(to: root.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "fixture.txt"])
    }

    func commit() throws -> (status: Int32, output: String) {
        try git(["-c", "user.name=Hook Test", "-c", "user.email=hook-test@example.invalid", "-c", "commit.gpgSign=false", "commit", "-qm", "fixture"])
    }

    func git(_ arguments: [String]) throws -> (status: Int32, output: String) { try run("/usr/bin/git", arguments) }

    func run(_ executable: String, _ arguments: [String], path: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        // Git exports repository-specific variables when running a real hook.
        // They must not redirect these fixture commits into the user's repository.
        for key in environment.keys.filter({ $0.hasPrefix("GIT_") }) {
            environment.removeValue(forKey: key)
        }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["PATH"] = path ?? (root.appendingPathComponent("bin").path + ":/usr/bin:/bin")
        environment["HOOK_TEST_LOG"] = log.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
