import XCTest
@testable import iCube

final class DebugEventBusTests: XCTestCase {
  func testSettingsDiffFindsChangedAndAddedKeys() {
    let old: [String: Any] = ["A": ["value": 1], "B": ["value": "x"]]
    let new: [String: Any] = ["A": ["value": 2], "B": ["value": "x"], "C": ["value": true]]
    let d = DebugEventBus.settingsDiff(old: old, new: new).sorted { $0.key < $1.key }
    XCTAssertEqual(d.map(\.key), ["A", "C"])
    XCTAssertEqual(d[0].new as? Int, 2)
    XCTAssertNil(d[1].old)
  }
  func testEventEncodingHasTimestampAndKind() throws {
    let json = DebugEventBus.encode(kind: "core.state", fields: ["state": "paused"])
    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["kind"] as? String, "core.state")
    XCTAssertEqual(obj["state"] as? String, "paused")
    XCTAssertNotNil(obj["t"] as? Double)
  }
}
