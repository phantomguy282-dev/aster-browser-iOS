import XCTest
@testable import AsterMobile

final class SecurityPolicyTests: XCTestCase {
    func testRejectsUnsafeAddresses() {
        for address in ["javascript:alert(1)", "file:///secret", "https://user:pass@example.com/", "https://example.com:99999/", "https://bad host/", "https://example.com\\evil"] {
            XCTAssertThrowsError(try WebPolicy.webURL(address), address)
        }
    }
    func testSearchAndModernDomains() throws {
        XCTAssertEqual(try WebPolicy.resolve("example.dev", engine: "google").host, "example.dev")
        let query = try WebPolicy.resolve("two words", engine: "google")
        XCTAssertEqual(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "two words")
        XCTAssertEqual(try WebPolicy.resolve("localhost:8080/test", engine: "google").scheme, "http")
    }
    func testFilenameAndDomainBoundaries() throws {
        XCTAssertEqual(WebPolicy.filename("../../note.txt"), "note.txt")
        XCTAssertFalse(WebPolicy.filename("image\u{202e}exe.png").contains("\u{202e}"))
        XCTAssertTrue(MobileShield.matches("sub.bad.example", "bad.example"))
        XCTAssertFalse(MobileShield.matches("notbad.example", "bad.example"))
        XCTAssertThrowsError(try MobileShield.domain("https://bad.example"))
    }
    func testLocalHashNeverMeansSafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        let report = try DownloadInspector.inspect(file: file, name: "note.txt", mime: "text/plain", expectedHash: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(report.verdict, "UNVERIFIED")
        XCTAssertFalse(report.malwareScanned)
        XCTAssertEqual(report.bytes, 5)
        XCTAssertEqual(try DownloadInspector.inspect(file: file, name: "payload.apk", mime: "image/png").verdict, "SUSPICIOUS")
    }
    func testModesAndExplicitExceptions() throws {
        var p = BrowserPreferences()
        p.threatDomains = ["bad.example"]
        p.adultDomains = ["adult.example"]
        let threat = try WebPolicy.webURL("https://bad.example/")
        XCTAssertNotNil(MobileShield.blocked(threat, preferences: p))
        XCTAssertNil(MobileShield.blocked(try WebPolicy.webURL("https://adult.example/"), preferences: p))
        p.shieldMode = "strict"
        XCTAssertNotNil(MobileShield.blocked(try WebPolicy.webURL("https://adult.example/"), preferences: p))
        p.exceptions = ["bad.example"]
        XCTAssertNil(MobileShield.blocked(threat, preferences: p))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(MobileShield.contentRules(p).utf8)) as? [[String: Any]])
    }
}
