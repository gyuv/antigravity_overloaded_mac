import XCTest
@testable import AntigravityCore

final class DiffTests: XCTestCase {
    func testDiffAndApplyRoundTrip() throws {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\n"
        let new = "a\nb\nC\nd\ne\nf\ng\nh\ni\n"
        let d = Differ.diff(path: "x.txt", old: old, new: new)
        XCTAssertEqual(d.additions, 2)
        XCTAssertEqual(d.deletions, 1)
        XCTAssertEqual(try Differ.apply(unifiedDiff: d.unifiedText, to: old), new)
    }

    func testApplyWithWrongLineNumbersFloats() throws {
        let old = "one\ntwo\nthree\nfour\n"
        let patch = "@@ -10,3 +10,3 @@\n two\n-three\n+THREE\n four\n"
        XCTAssertEqual(try Differ.apply(unifiedDiff: patch, to: old), "one\ntwo\nTHREE\nfour\n")
    }

    func testApplyRejectsMismatchedContext() {
        XCTAssertThrowsError(try Differ.apply(unifiedDiff: "@@ -1,2 +1,2 @@\n nope\n-x\n+y\n", to: "a\nb\n"))
    }

    func testReplaceRequiresUniqueMatch() throws {
        XCTAssertThrowsError(try Differ.replace(in: "x x", old: "x", new: "y"))
        XCTAssertEqual(try Differ.replace(in: "x x", old: "x", new: "y", replaceAll: true), "y y")
        XCTAssertEqual(try Differ.replace(in: "hello world", old: "world", new: "there"), "hello there")
    }

    func testNewFileDiff() {
        let d = Differ.diff(path: "n.txt", old: nil, new: "1\n2\n")
        XCTAssertTrue(d.isNewFile)
        XCTAssertEqual(d.additions, 2)
    }
}

final class PermissionTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(PermissionEngine.classify(command: "ls -la"), .readOnly)
        XCTAssertEqual(PermissionEngine.classify(command: "git status"), .readOnly)
        XCTAssertEqual(PermissionEngine.classify(command: "swift test"), .safe)
        XCTAssertEqual(PermissionEngine.classify(command: "npm install"), .write)
        XCTAssertEqual(PermissionEngine.classify(command: "rm -rf build"), .destructive)
        XCTAssertEqual(PermissionEngine.classify(command: "git reset --hard"), .destructive)
        XCTAssertEqual(PermissionEngine.classify(command: "ls && rm x"), .destructive)
        XCTAssertEqual(PermissionEngine.classify(command: "echo hi > out.txt"), .write)
    }

    func testModes() {
        let review = PermissionEngine(mode: .review)
        XCTAssertFalse(review.needsApproval(risk: .safe, toolName: "execute_bash"))
        XCTAssertTrue(review.needsApproval(risk: .write, toolName: "write_file"))
        let turbo = PermissionEngine(mode: .turbo)
        XCTAssertFalse(turbo.needsApproval(risk: .write, toolName: "patch_file"))
        XCTAssertTrue(turbo.needsApproval(risk: .write, toolName: "execute_bash"))
        XCTAssertTrue(turbo.needsApproval(risk: .destructive, toolName: "execute_bash"))
        XCTAssertFalse(PermissionEngine(mode: .yolo).needsApproval(risk: .destructive, toolName: "execute_bash"))
    }
}

final class GlobTests: XCTestCase {
    func testGlob() {
        let files = ["a.swift", "src/b.swift", "src/deep/c.ts", "README.md"]
        XCTAssertEqual(GlobMatcher.filter(files, glob: "*.swift"), ["a.swift", "src/b.swift"])
        XCTAssertEqual(GlobMatcher.filter(files, glob: "src/**/*.{ts,swift}"), ["src/b.swift", "src/deep/c.ts"])
    }
}

final class WorkspaceTests: XCTestCase {
    func testSandboxRejectsEscapes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ws = Workspace(path: dir.path)
        XCTAssertNoThrow(try ws.resolve("sub/file.txt"))
        XCTAssertThrowsError(try ws.resolve("../escape.txt"))
        XCTAssertThrowsError(try ws.resolve("/etc/passwd"))
    }
}

final class ExecutorTests: XCTestCase {
    func testPTYRunAndTimeout() async {
        let ex = PTYExecutor()
        let tmp = FileManager.default.temporaryDirectory
        let ok = await ex.run(command: "echo hello; test -t 1 && echo tty", cwd: tmp, timeout: 10)
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertTrue(ok.output.contains("hello"))
        XCTAssertTrue(ok.output.contains("tty"))
        let fail = await ex.run(command: "exit 3", cwd: tmp, timeout: 10)
        XCTAssertEqual(fail.exitCode, 3)
        let slow = await ex.run(command: "sleep 30", cwd: tmp, timeout: 1)
        XCTAssertTrue(slow.timedOut)
    }
}

final class AgentTests: XCTestCase {
    func testMergeTextParts() {
        var parts: [JSONValue] = []
        AgentSession.appendMerging(["text": "Hel"], into: &parts)
        AgentSession.appendMerging(["text": "lo"], into: &parts)
        AgentSession.appendMerging(["text": "x", "thought": true], into: &parts)
        AgentSession.appendMerging(["functionCall": ["name": "read_file"], "thoughtSignature": "abc"], into: &parts)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["text"]?.stringValue, "Hello")
    }

    func testRequestBodyShape() {
        let c = GeminiClient(config: AgentConfig(auth: .apiKey("k")))
        let body = c.requestBody(system: "sys", history: [.userText("hi")], tools: ToolRegistry.standard.declarations)
        XCTAssertEqual(body["contents"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["functionDeclarations"]?.arrayValue?.count, ToolRegistry.standard.tools.count)
    }
}
