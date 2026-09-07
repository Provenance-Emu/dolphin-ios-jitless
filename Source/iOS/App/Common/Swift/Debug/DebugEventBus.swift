// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugEventBus.swift
//
// Fan-out event bus for `/ws/events`: broadcasts `settings.changed`,
// `log.line`, `core.state`, and `perf.sample` events to every attached
// WebSocket connection. Producers (config-change/log/core-state handlers,
// a 1Hz perf-sample timer) may fire from any thread; `publish` snapshots the
// socket list under `lock` and never invokes `WebSocketConnection.send`
// while holding it.

import Foundation

final class DebugEventBus: @unchecked Sendable {
  static let shared = DebugEventBus()
  private let lock = NSLock()
  private var sockets: [ObjectIdentifier: WebSocketConnection] = [:]
  private var lastSettings: [String: Any] = [:]
  private var perfTimer: DispatchSourceTimer?
  private var producersStarted = false

  static func encode(kind: String, fields: [String: Any]) -> String {
    var obj = fields
    obj["kind"] = kind
    obj["t"] = Date().timeIntervalSince1970 * 1000
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func settingsDiff(old: [String: Any], new: [String: Any]) -> [(key: String, old: Any?, new: Any?)] {
    func value(_ d: [String: Any], _ k: String) -> Any? { (d[k] as? [String: Any])?["value"] }
    var out: [(String, Any?, Any?)] = []
    for k in Set(old.keys).union(new.keys) {
      let a = value(old, k), b = value(new, k)
      let same = (a == nil && b == nil) || (a as? NSObject) == (b as? NSObject)
      if !same { out.append((k, a, b)) }
    }
    return out.map { (key: $0.0, old: $0.1, new: $0.2) }
  }

  func publish(_ kind: String, _ fields: [String: Any]) {
    let text = Self.encode(kind: kind, fields: fields)
    lock.lock(); let targets = Array(sockets.values); lock.unlock()
    targets.forEach { $0.send(text: text) }
  }

  func attach(_ socket: WebSocketConnection) {
    lock.lock(); sockets[ObjectIdentifier(socket)] = socket; lock.unlock()
    socket.onClose = { [weak self, weak socket] in
      guard let self, let socket else { return }
      self.lock.lock(); self.sockets[ObjectIdentifier(socket)] = nil; self.lock.unlock()
    }
    publish("core.state", ["state": DOLDebugBridge.coreState()])
  }

  func startProducers() {
    guard !producersStarted else { return }
    producersStarted = true
    lastSettings = DOLSettingsKeyBridge.snapshotAll() as? [String: Any] ?? [:]
    DOLDebugBridge.setConfigChangedHandler { [weak self] in
      guard let self else { return }
      let now = DOLSettingsKeyBridge.snapshotAll() as? [String: Any] ?? [:]
      let diff = Self.settingsDiff(old: self.lastSettings, new: now)
      self.lastSettings = now
      for d in diff {
        self.publish("settings.changed", ["key": d.key, "old": d.old ?? NSNull(), "new": d.new ?? NSNull()])
      }
    }
    DOLDebugBridge.setLogHandler { [weak self] level, msg in
      self?.publish("log.line", ["level": level, "msg": msg])
    }
    DOLDebugBridge.setCoreStateHandler { [weak self] state in
      self?.publish("core.state", ["state": state])
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self, DOLDebugBridge.coreState() == "running" else { return }
      let snap = DOLPerfBridge.snapshot() as? [String: Any] ?? [:]
      self.publish("perf.sample", ["fps": snap["fps"] ?? 0, "vps": snap["vps"] ?? 0, "frame_ms": snap["frameTimeMs"] ?? 0])
    }
    timer.resume()
    perfTimer = timer
  }
}
