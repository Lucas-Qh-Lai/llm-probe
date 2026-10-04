#if canImport(XCTest)
import XCTest
@testable import LLMProbeCore

/// Runs the engine's offline self check through XCTest.
///
/// `SelfTest` lives in the library so the same checks can be executed on a Mac
/// that only has the Command Line Tools installed (`swift run llmprobe
/// selftest`). With a full toolchain — CI, or a machine with Xcode — this wrapper
/// reports each failure as a normal XCTest failure.
final class CoreSelfTests: XCTestCase {
    func testOfflineSelfCheckPasses() {
        let report = SelfTest.run()
        let summary = report.failures
            .map { "\($0.check): \($0.detail)" }
            .joined(separator: "\n")
        XCTAssertTrue(report.failures.isEmpty, "self check failures:\n\(summary)")
        XCTAssertGreaterThan(report.checksRun, 15)
    }

    /// `LLMProbeVersion.short` is the single source of truth for the release
    /// version; every package is built from it.
    func testVersionIsWellFormed() {
        let parts = LLMProbeVersion.short.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "not a semantic version: \(LLMProbeVersion.short)")
        for part in parts {
            XCTAssertNotNil(Int(part), "non-numeric version component: \(part)")
        }
        XCTAssertNotEqual(LLMProbeVersion.short, "0.0.0")
    }

    /// `scripts/build_app.sh` generates the app's Info.plist, so it must derive
    /// both version keys from that constant. A literal there is how a 0.2.0
    /// bundle ends up reporting 0.1.0 — which no unit test could previously
    /// catch, because the old check pinned the version to a literal instead.
    func testAppBundleVersionIsDerivedFromTheSourceConstant() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LLMProbeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/build_app.sh"))
        let script = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(
            script.contains("<key>CFBundleShortVersionString</key><string>$VERSION</string>"),
            "build_app.sh must write $VERSION into CFBundleShortVersionString"
        )
        XCTAssertTrue(
            script.contains("<key>CFBundleVersion</key><string>$VERSION</string>"),
            "build_app.sh must write $VERSION into CFBundleVersion"
        )
        XCTAssertTrue(
            script.contains("public static let short"),
            "build_app.sh must read the version from LLMProbeVersion.short"
        )
    }
}
#endif
