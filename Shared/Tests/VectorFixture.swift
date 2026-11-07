import XCTest
import Foundation

/// Reads, checks and (on request) rewrites the cross-language vector files in
/// `Shared/Tests/Fixtures/vectors/` (Q-91, spec section 10.2).
///
/// A vector file is a JSON object. `_doc` explains its shape for a reader who
/// does not know Swift (the Rust Windows host reads the same files). Every other
/// top-level key whose value is an array is a SECTION: a list of cases shaped
///
///     {"name": "...", "input": {...}, "expect": <any JSON>}
///
/// The Swift test for a section decodes each `input`, runs it through the real
/// Swift rule, and asserts the result equals `expect`.
///
/// Expected values are produced by the Swift code, never typed by hand: run the
/// suite once with `QUIP_WRITE_VECTORS=1` in the test process environment
/// (`TEST_RUNNER_QUIP_WRITE_VECTORS=1 xcodebuild … test`) and each test writes
/// what the Swift code returned into `expect`, keeping `name` and `input`. A
/// normal run only checks. Write mode is refused in the iOS suite and when
/// `CI` is set, so only a local QuipMac run can rewrite a file.
enum VectorFixture {

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func url(_ relative: String) -> URL {
        fixturesDirectory.appendingPathComponent(relative)
    }

    static var writeMode: Bool {
        ProcessInfo.processInfo.environment["QUIP_WRITE_VECTORS"] == "1"
    }

    /// Why write mode may not run here, or nil when it may. Only a local Mac
    /// suite writes: CI must check what is committed, and the iOS suite runs
    /// the same Shared tests, so two writers could disagree.
    static var writeRefusal: String? {
        #if os(iOS)
        return "QUIP_WRITE_VECTORS is refused in the iOS suite; regenerate from the QuipMac suite"
        #else
        if let ci = ProcessInfo.processInfo.environment["CI"], !ci.isEmpty {
            return "QUIP_WRITE_VECTORS is refused when CI is set; CI only checks the committed vectors"
        }
        return nil
        #endif
    }

    /// Run every case of `section` in `file` (relative to `Fixtures/`).
    /// `compute` gets the decoded `input` and returns a JSON-compatible value
    /// (String, Bool, Int, Double, NSNull, [Any], [String: Any]).
    static func run<Input: Decodable>(
        _ file: String, section: String, input: Input.Type,
        minimumCases: Int = 1,
        tolerance: Double = 1e-9,
        file sourceFile: StaticString = #filePath, line: UInt = #line,
        compute: (Input) throws -> Any
    ) throws {
        let fileURL = url(file)
        let data = try Data(contentsOf: fileURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("\(file) is not a JSON object", file: sourceFile, line: line)
        }
        XCTAssertNotNil(root["_doc"], "\(file) has no _doc", file: sourceFile, line: line)
        guard let cases = root[section] as? [[String: Any]] else {
            return XCTFail("\(file) has no section \(section)", file: sourceFile, line: line)
        }
        XCTAssertGreaterThanOrEqual(cases.count, minimumCases,
                                    "\(file).\(section) went missing or was emptied",
                                    file: sourceFile, line: line)
        if writeMode, let refusal = writeRefusal {
            return XCTFail(refusal, file: sourceFile, line: line)
        }
        var rewritten: [[String: Any]] = []
        for (index, vector) in cases.enumerated() {
            let name = vector["name"] as? String ?? "#\(index)"
            guard let rawInput = vector["input"] else {
                XCTFail("\(file).\(section) \(name): no input", file: sourceFile, line: line)
                continue
            }
            let inputData = try JSONSerialization.data(withJSONObject: rawInput, options: [.fragmentsAllowed])
            let decoded = try JSONDecoder().decode(Input.self, from: inputData)
            let actual = try compute(decoded)
            if writeMode {
                var updated = vector
                updated["expect"] = actual
                rewritten.append(updated)
                continue
            }
            guard let expected = vector["expect"] else {
                XCTFail("\(file).\(section) \(name): no expect (run with QUIP_WRITE_VECTORS=1)",
                        file: sourceFile, line: line)
                continue
            }
            if let difference = JSONCompare.difference(expected, actual, path: "expect",
                                                       tolerance: tolerance) {
                XCTFail("\(file).\(section) \(name): \(difference)", file: sourceFile, line: line)
            }
        }
        if writeMode {
            root[section] = rewritten
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (out + Data("\n".utf8)).write(to: fileURL)
        }
    }

    /// `NSNull()` for nil, so an optional result writes as JSON `null`.
    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
        ["x": x, "y": y, "width": width, "height": height]
    }
}

/// JSON rect as the vector files spell it.
struct VectorRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Structural comparison of two JSONSerialization trees.
enum JSONCompare {

    /// `unsupported` is anything JSONSerialization should never produce; it
    /// never compares equal, not even to itself.
    enum Kind: String { case null, bool, number, string, array, object, unsupported }

    static func kind(_ value: Any) -> Kind {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool : .number
        }
        if value is String { return .string }
        if value is [Any] { return .array }
        if value is [String: Any] { return .object }
        return .unsupported
    }

    /// nil when equal; otherwise a short description of the first difference.
    static func difference(_ expected: Any, _ actual: Any, path: String,
                           tolerance: Double) -> String? {
        let ek = kind(expected), ak = kind(actual)
        guard ek == ak else { return "\(path): expected \(ek) \(expected), got \(ak) \(actual)" }
        switch ek {
        case .unsupported:
            return "\(path): unsupported JSON value \(expected) / \(actual)"
        case .null:
            return nil
        case .bool:
            return (expected as! NSNumber).boolValue == (actual as! NSNumber).boolValue
                ? nil : "\(path): expected \(expected), got \(actual)"
        case .number:
            let e = (expected as! NSNumber).doubleValue, a = (actual as! NSNumber).doubleValue
            return abs(e - a) <= tolerance ? nil : "\(path): expected \(e), got \(a)"
        case .string:
            return (expected as! String) == (actual as! String)
                ? nil : "\(path): expected \(String(reflecting: expected)), got \(String(reflecting: actual))"
        case .array:
            let e = expected as! [Any], a = actual as! [Any]
            guard e.count == a.count else { return "\(path): expected \(e.count) items, got \(a.count)" }
            for i in e.indices {
                if let d = difference(e[i], a[i], path: "\(path)[\(i)]", tolerance: tolerance) { return d }
            }
            return nil
        case .object:
            let e = expected as! [String: Any], a = actual as! [String: Any]
            guard Set(e.keys) == Set(a.keys) else {
                return "\(path): expected keys \(e.keys.sorted()), got \(a.keys.sorted())"
            }
            for key in e.keys.sorted() {
                if let d = difference(e[key]!, a[key]!, path: "\(path).\(key)", tolerance: tolerance) { return d }
            }
            return nil
        }
    }
}
