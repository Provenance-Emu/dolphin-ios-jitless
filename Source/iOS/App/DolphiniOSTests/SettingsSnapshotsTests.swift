import XCTest
@testable import iCube

final class SettingsSnapshotsTests: XCTestCase {
  func makeStore() -> SettingsSnapshots {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return SettingsSnapshots(directory: dir)
  }
  func testSaveListLoadRoundTrip() throws {
    let s = makeStore()
    try s.save(name: "before", snapshot: ["A": ["value": 1]], gameId: "SMNE01")
    XCTAssertEqual(s.list().count, 1)
    XCTAssertEqual(s.list()[0]["name"] as? String, "before")
    XCTAssertEqual((s.load(name: "before")?["A"] as? [String: Any])?["value"] as? Int, 1)
  }
  func testDiffReportsOnlyChangedKeys() {
    let d = SettingsSnapshots.diff(["A": ["value": 1], "B": ["value": 2]], ["A": ["value": 1], "B": ["value": 3]])
    XCTAssertEqual(d.count, 1)
    XCTAssertEqual(d[0]["key"] as? String, "B")
    XCTAssertEqual(d[0]["b"] as? Int, 3)
  }
  func testNameIsSanitised() throws {
    let s = makeStore()
    try s.save(name: "../evil", snapshot: [:], gameId: "")
    XCTAssertEqual(s.list()[0]["name"] as? String, "evil")
  }
}
