// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

private final class FakeWriter: ControllerConfigWriting {
  var calls: [String] = []

  func setGCPortActive(_ a: Bool, port: Int) { calls.append("activeGC=\(a)@\(port)") }
  func setWiimoteSource(emulated: Bool, port: Int) { calls.append("wiiSrc=\(emulated)@\(port)") }
  func setDefaultDevice(_ q: String, system: EmulatedSystem, port: Int) { calls.append("bind=\(q)@\(port)") }
  func clearDefaultDevice(system: EmulatedSystem, port: Int) { calls.append("clear@\(port)") }
  func defaultProfileName(forQualifier q: String) -> String? {
    if q.hasPrefix("MFi") { return "Physical Controller" }
    if q.hasPrefix("iOS/") { return "Touchscreen" }
    return nil
  }
  func loadProfile(_ n: String, system: EmulatedSystem, port: Int, restoreDevice: Bool) { calls.append("profile=\(n)@\(port)") }
  func assignTouchscreen(system: EmulatedSystem, port: Int) { calls.append("touch@\(port)") }
  func saveConfig(system: EmulatedSystem) { calls.append("save") }
}

final class ControllerAssignmentServiceTests: XCTestCase {

  func test_assignPhysical_GCPort2_activatesBindsProfilesSaves() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    // 0-based port 1 == Player 2
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 1, system: .gamecube)
    XCTAssertEqual(
      fake.calls,
      ["activeGC=true@1", "bind=MFi/0/Gamepad@1", "profile=Physical Controller@1", "save"])
  }

  func test_assignPhysical_WiiPort3_activatesViaWiimoteSource() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    // 0-based port 2 == Player 3
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 2, system: .wii)
    XCTAssertEqual(
      fake.calls,
      ["wiiSrc=true@2", "bind=MFi/0/Gamepad@2", "profile=Physical Controller@2", "save"])
  }

  func test_assign_unknownDevice_skipsProfile() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "Mystery/0/Thing", toPlayer: 0, system: .gamecube)
    XCTAssertEqual(fake.calls, ["activeGC=true@0", "bind=Mystery/0/Thing@0", "save"])
  }

  func test_clear_clearsThenSaves() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.clear(player: 1, system: .gamecube)
    XCTAssertEqual(fake.calls, ["clear@1", "save"])
  }

  func test_assignTouchscreen_activatesThenBindsTouchscreen() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.assignTouchscreen(toPlayer: 0, system: .gamecube)
    // assignTouchscreen on the writer is responsible for its own save.
    XCTAssertEqual(fake.calls, ["activeGC=true@0", "touch@0"])
  }
}
