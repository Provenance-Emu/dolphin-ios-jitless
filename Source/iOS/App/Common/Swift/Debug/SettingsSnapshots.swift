// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/SettingsSnapshots.swift
//
// Named settings snapshots for the debug API: save the full `snapshotAllLayers()`
// dump under a sanitised name, list what's saved, load one back, and diff two of
// them. Backed by flat JSON files under `directory` — no Realm/CoreData.

import Foundation

final class SettingsSnapshots {
  private let directory: URL

  init(directory: URL) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  static var defaultDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DebugSnapshots")
  }

  /// Keep only letters/numbers/`-`/`_` so a name can never escape `directory` (e.g.
  /// `../evil` or an absolute path) — falls back to "snapshot" if that strips everything.
  static func sanitise(_ name: String) -> String {
    let allowed = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return allowed.isEmpty ? "snapshot" : allowed
  }

  func save(name: String, snapshot: [String: Any], gameId: String) throws {
    let doc: [String: Any] = [
      "name": Self.sanitise(name), "taken_at": ISO8601DateFormatter().string(from: Date()),
      "game_id": gameId, "settings": snapshot,
    ]
    let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: directory.appendingPathComponent(Self.sanitise(name) + ".json"), options: .atomic)
  }

  func list() -> [[String: Any]] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { url in
      guard let d = try? Data(contentsOf: url), let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
      return ["name": doc["name"] ?? "", "taken_at": doc["taken_at"] ?? "", "game_id": doc["game_id"] ?? ""]
    }.sorted { ($0["taken_at"] as? String ?? "") < ($1["taken_at"] as? String ?? "") }
  }

  func load(name: String) -> [String: Any]? {
    let url = directory.appendingPathComponent(Self.sanitise(name) + ".json")
    guard let d = try? Data(contentsOf: url), let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return doc["settings"] as? [String: Any]
  }

  /// Rows of `{key, a, b}` for every key whose `["value"]` differs between the two
  /// snapshots (added/removed keys included — `a`/`b` is `NSNull()` on the missing side).
  static func diff(_ a: [String: Any], _ b: [String: Any]) -> [[String: Any]] {
    DebugEventBus.settingsDiff(old: a, new: b).map { ["key": $0.key, "a": $0.old ?? NSNull(), "b": $0.new ?? NSNull()] }
      .sorted { ($0["key"] as! String) < ($1["key"] as! String) }
  }
}
