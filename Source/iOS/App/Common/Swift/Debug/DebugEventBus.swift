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
// while holding it. `lastSettings` is likewise only ever read/written while
// holding `lock`, since the config-changed handler can fire concurrently
// from any thread. A newly `attach`-ed socket gets its own initial
// `core.state` snapshot, not a broadcast. `stopProducers()` tears down the
// timer and sockets for `DebugServerManager.stop()`.

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
    let t = Date().timeIntervalSince1970 * 1000
    obj["t"] = t
    // `isValidJSONObject` must be checked BEFORE calling `data(withJSONObject:)`:
    // a non-serializable value (e.g. Double.nan) makes that call raise an
    // uncaught NSInvalidArgumentException rather than throw a catchable Swift
    // error, so `try?` alone does not protect against it.
    if JSONSerialization.isValidJSONObject(obj),
       let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
      return String(decoding: data, as: UTF8.self)
    }
    // `fields` failed to serialize (e.g. a Double.nan value) — fall back to
    // just the two fields every consumer relies on rather than an empty "{}".
    let fallback: [String: Any] = ["kind": kind, "t": t]
    let fallbackData = (try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: fallbackData, as: UTF8.self)
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
    // Only the newly attached socket gets the initial snapshot — not a
    // broadcast to every socket already attached.
    socket.send(text: Self.encode(kind: "core.state", fields: ["state": DOLDebugBridge.coreState()]))
  }

  /// Cancels the perf timer, closes and detaches every attached socket, and
  /// clears `producersStarted` so a later `start()` can re-arm the timer. The
  /// `DOLDebugBridge` handlers are left registered — they're install-once by
  /// design and harmlessly no-op via `publish` finding no sockets.
  func stopProducers() {
    lock.lock()
    perfTimer?.cancel()
    perfTimer = nil
    let targets = Array(sockets.values)
    sockets.removeAll()
    producersStarted = false
    lock.unlock()
    targets.forEach { $0.close() }
  }

  func startProducers() {
    guard !producersStarted else { return }
    producersStarted = true
    lock.lock()
    lastSettings = DOLSettingsKeyBridge.snapshotAll() as? [String: Any] ?? [:]
    lock.unlock()
    DOLDebugBridge.setConfigChangedHandler { [weak self] in
      guard let self else { return }
      let now = DOLSettingsKeyBridge.snapshotAll() as? [String: Any] ?? [:]
      // Guard the read-then-write of `lastSettings` with `lock` since this
      // handler may fire from any thread and concurrently; compute the diff
      // and publish only after releasing the lock.
      self.lock.lock()
      let old = self.lastSettings
      self.lastSettings = now
      self.lock.unlock()
      let diff = Self.settingsDiff(old: old, new: now)
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
