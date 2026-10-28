import XCTest
@testable import Quip

/// `ProjectName` against the vector file VibeCut's resolver is checked with too
/// (`Fixtures/project_name_vectors.json`, same cases in both repos). Folder
/// names here are invented.
final class ProjectNameTests: XCTestCase {

    private struct Vector: Decodable {
        let name: String
        let cwd: String
        let gitDirs: [String]
        let expect: String?
    }

    private func vectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/project_name_vectors.json")
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    func testEverySharedVector() throws {
        let all = try vectors()
        XCTAssertGreaterThanOrEqual(all.count, 10, "the vector file went missing or was emptied")
        for v in all {
            let gitPaths = Set(v.gitDirs.map { $0 + "/.git" })
            let got = ProjectName.resolve(cwd: v.cwd) { gitPaths.contains($0) }
            XCTAssertEqual(got, v.expect, v.name)
        }
    }

    func testNilCwdHasNoProject() {
        XCTAssertNil(ProjectName.resolve(cwd: nil) { _ in true })
    }

    func testRealFilesystemFindsAGitFileOrDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-projname-\(UUID().uuidString)/demo-proj", isDirectory: true)
        let sub = root.appendingPathComponent("src/mail", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // A worktree has a `.git` FILE, not a directory.
        try Data("gitdir: elsewhere".utf8).write(to: root.appendingPathComponent(".git"))
        XCTAssertEqual(ProjectName.resolve(cwd: sub.path), "demo-proj")
    }

    func testWindowStateProjectIsOptionalAndAdditive() throws {
        let frame = WindowFrame(x: 0, y: 0, width: 1, height: 1)
        let with = WindowState(id: "w", name: "n", app: "iTerm2", folder: "src", enabled: true,
                               frame: frame, state: "neutral", color: "#fff", project: "demo-proj")
        let round = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(with))
        XCTAssertEqual(round.project, "demo-proj")
        XCTAssertEqual(round.folder, "src")

        // An older Mac's JSON has no `project`.
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as! [String: Any]
        var stripped = old
        stripped.removeValue(forKey: "project")
        let decoded = try JSONDecoder().decode(WindowState.self,
                                               from: JSONSerialization.data(withJSONObject: stripped))
        XCTAssertNil(decoded.project)
        XCTAssertEqual(decoded.folder, "src")
    }
}
