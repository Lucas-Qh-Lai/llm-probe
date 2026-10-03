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

    func testVersionMatchesBundle() {
        XCTAssertEqual(LLMProbeVersion.short, "0.1.0")
    }
}
#endif
