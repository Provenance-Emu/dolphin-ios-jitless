// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift
//
// Registers the debug + benchmark JSON API on a NativeWebServer.
// Every response is { "ok": Bool, "data": ... } or { "ok": false, "error": ... }.
//
// Routes:
//   GET  /api/perf/live              -> live g_perf_metrics snapshot
//   GET  /api/settings               -> all known settings + metadata
//   POST /api/settings/<key>         body {"value": ...} -> set one setting
//   GET  /api/savestates             -> list save-state slots present on disk
//   POST /api/bench/start            body {"slot":N,"seconds":S} -> start a run
//   GET  /api/bench/result           -> last finished benchmark result
//   POST /api/bench/sweep            body {"key":K,"values":[...],"slot":N,"seconds":S}
//   GET  /api/health                 -> build/game/core-state/perf summary
//   POST /api/debug/pause            -> pause the running core
//   POST /api/debug/resume           -> resume the paused core
//   POST /api/debug/frame-advance    body {"n":N} -> step N frames while paused
//   GET  /api/debug/frame-count      -> emulated frame counter
//   POST /api/debug/savestate        body {"slot":N} -> save to slot N
//   POST /api/debug/loadstate        body {"slot":N} or {"path":P} -> load a state
//   GET  /api/debug/screenshot       -> current frame as image/png bytes
//   GET  /api/debug/build-info       -> SCM rev/branch/app version/configuration
//   GET  /api/debug/render-state     -> render-relevant config/state snapshot
//   GET  /api/logs                   -> query {"tail":N=200} -> last N log lines

import Foundation

/// Parses a request body as a JSON object, returning `[:]` on missing/invalid JSON.
private func jsonBody(_ body: Data?) -> [String: Any] {
  guard let body, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
  return j
}

final class DebugAPIRoutes {
  private var registered = false

  func registerRoutes(on server: NativeWebServer) {
    guard !registered else { return }

    // GET /api/perf/live — perf getters are any-thread-safe, no MainActor hop.
    server.addCustomHandler(forMethod: "GET", path: "/api/perf/live") { _, _, _, _ in
      let snap = DOLPerfBridge.snapshot()
      return ["ok": true, "data": snap]
    }

    // GET /api/settings
    server.addCustomHandler(forMethod: "GET", path: "/api/settings") { _, _, _, _ in
      // snapshotAll reads Config (internally synchronized) — safe off-main.
      let all = DOLSettingsKeyBridge.snapshotAll()
      return ["ok": true, "data": all]
    }

    // POST /api/settings/<key>  body {"value": ...}
    server.addCustomHandler(forMethod: "POST", pathRegex: "/api/settings/.*") { _, path, _, body in
      let key = (path as NSString).lastPathComponent
      guard DOLSettingsKeyBridge.isKnownKey(key) else {
        return ["ok": false, "error": "unknown key: \(key)"]
      }
      guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let value = json["value"] else {
        return ["ok": false, "error": "missing JSON body with 'value' key"]
      }
      // Config writes must happen on the main actor.
      let ok: Bool = DispatchQueue.main.sync {
        DOLSettingsKeyBridge.setKey(key, value: value)
      }
      let hot = DOLSettingsKeyBridge.isHotSwappable(key)
      return [
        "ok": ok,
        "data": [
          "key": key,
          "value": "\(value)",
          "hotSwappable": hot,
          "note": hot ? "applied live" : "boot-time: reload save state / reboot to take effect",
        ] as [String: Any],
      ]
    }

    // GET /api/savestates — enumerate the StateSaves directory.
    server.addCustomHandler(forMethod: "GET", path: "/api/savestates") { _, _, _, _ in
      guard let cPath = DolphinGetStateSavesPathC() else {
        return ["ok": true, "data": [] as [Any]]
      }
      let dir = URL(fileURLWithPath: String(cString: cPath))
      let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
      let iso = ISO8601DateFormatter()
      // Dolphin slot states are "<game>.sNN" (Core/State.cpp MakeStateFilename:
      // fmt "{}.s{:02d}"); there is also a "lastState.sav". Match both and pull
      // the slot number out of the .sNN extension when present.
      let slotRegex = try? NSRegularExpression(pattern: "\\.s([0-9]{2})$")
      let list = files.compactMap { url -> [String: Any]? in
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var slot: Int? = nil
        if let slotRegex {
          let range = NSRange(name.startIndex..., in: name)
          if let m = slotRegex.firstMatch(in: name, range: range),
             let r = Range(m.range(at: 1), in: name) {
            slot = Int(name[r])
          }
        }
        let isSlot = slot != nil
        let isLast = name == "lastState.sav"
        guard isSlot || (isLast && ext == "sav") else { return nil }
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var entry: [String: Any] = [
          "name": name,
          "size": rv?.fileSize ?? 0,
          "modified": (rv?.contentModificationDate).map { iso.string(from: $0) } ?? "",
        ]
        if let slot { entry["slot"] = slot }
        return entry
      }
      return ["ok": true, "data": list]
    }

    // POST /api/bench/start  body {"slot":N,"seconds":S}
    server.addCustomHandler(forMethod: "POST", path: "/api/bench/start") { _, _, _, body in
      var slot = 1
      var seconds: Double = 15
      if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
        slot = (json["slot"] as? NSNumber)?.intValue ?? slot
        seconds = (json["seconds"] as? NSNumber)?.doubleValue ?? seconds
      }
      Task { @MainActor in
        await DebugBenchmarkManager.shared.runBenchmark(slot: slot, seconds: seconds)
      }
      return ["ok": true, "data": ["started": true, "slot": slot, "seconds": seconds] as [String: Any]]
    }

    // GET /api/bench/result — last finished run, or running status.
    server.addCustomHandler(forMethod: "GET", path: "/api/bench/result") { _, _, _, _ in
      // Hop to main to read manager state (it is @MainActor), then encode.
      let payload: [String: Any] = DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          let mgr = DebugBenchmarkManager.shared
          if mgr.isRunning {
            return ["ok": true, "data": ["status": "running"] as [String: Any]]
          }
          guard let result = mgr.lastResult else {
            return ["ok": true, "data": ["status": "no-result"] as [String: Any]]
          }
          guard let dict = Self.encodeJSONObject(result) else {
            return ["ok": false, "error": "failed to encode result"]
          }
          return ["ok": true, "data": ["status": "done", "result": dict] as [String: Any]]
        }
      }
      return payload
    }

    // POST /api/bench/sweep  body {"key":K,"values":[...],"slot":N,"seconds":S}
    server.addCustomHandler(forMethod: "POST", path: "/api/bench/sweep") { _, _, _, body in
      guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let key = json["key"] as? String,
            let values = json["values"] as? [Any] else {
        return ["ok": false, "error": "missing key/values in body"]
      }
      guard DOLSettingsKeyBridge.isKnownKey(key) else {
        return ["ok": false, "error": "unknown key: \(key)"]
      }
      let slot = (json["slot"] as? NSNumber)?.intValue ?? 1
      let seconds = (json["seconds"] as? NSNumber)?.doubleValue ?? 15
      let stringValues = values.map { "\($0)" }
      Task { @MainActor in
        _ = await DebugBenchmarkManager.shared.runSweep(
          key: key, values: stringValues, slot: slot, seconds: seconds)
      }
      return ["ok": true, "data": [
        "started": true, "key": key, "values": stringValues, "slot": slot, "seconds": seconds,
      ] as [String: Any]]
    }

    // GET /api/health — build/game/core-state/perf summary.
    server.addCustomHandler(forMethod: "GET", path: "/api/health") { _, _, _, _ in
      let perf = DOLPerfBridge.snapshot() as? [String: Any] ?? [:]
      let build = DOLDebugBridge.buildInfo()
      return ["ok": true, "data": [
        "build_sha": build["scm_rev"] ?? "", "config": build["configuration"] ?? "",
        "game_id": TVEmulationBridge.currentGameID(), "core_state": DOLDebugBridge.coreState(),
        "fps": perf["fps"] ?? 0, "vps": perf["vps"] ?? 0,
      ] as [String: Any]]
    }

    // POST /api/debug/pause
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/pause") { _, _, _, _ in
      DOLDebugBridge.pause() ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                             : ["ok": false, "status": 409, "error": "core not running"]
    }

    // POST /api/debug/resume
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/resume") { _, _, _, _ in
      DOLDebugBridge.resume() ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                              : ["ok": false, "status": 409, "error": "core not running"]
    }

    // POST /api/debug/frame-advance  body {"n":N}
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/frame-advance") { _, _, _, body in
      let n = (jsonBody(body)["n"] as? NSNumber)?.intValue ?? 1
      guard DOLDebugBridge.coreState() == "paused" else {
        return ["ok": false, "status": 409, "error": "core must be paused (state=\(DOLDebugBridge.coreState()))"]
      }
      let done = DOLDebugBridge.frameAdvance(n, timeoutSeconds: 5)
      if done < n { return ["ok": false, "status": 504, "error": "timed out after \(done)/\(n) frames"] }
      return ["ok": true, "data": ["frames_advanced": done, "frame_count": DOLDebugBridge.frameCount()] as [String: Any]]
    }

    // GET /api/debug/frame-count
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/frame-count") { _, _, _, _ in
      ["ok": true, "data": ["frame_count": DOLDebugBridge.frameCount()]]
    }

    // POST /api/debug/savestate  body {"slot":N}
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/savestate") { _, _, _, body in
      let slot = (jsonBody(body)["slot"] as? NSNumber)?.intValue ?? 1
      return DOLDebugBridge.saveStateSlot(slot) ? ["ok": true, "data": ["slot": slot]]
                                                 : ["ok": false, "status": 409, "error": "core not running"]
    }

    // POST /api/debug/loadstate  body {"slot":N} or {"path":P}
    server.addCustomHandler(forMethod: "POST", path: "/api/debug/loadstate") { _, _, _, body in
      let j = jsonBody(body)
      let ok: Bool
      if let p = j["path"] as? String { ok = DOLDebugBridge.loadStatePath(p) }
      else { ok = DOLDebugBridge.loadStateSlot((j["slot"] as? NSNumber)?.intValue ?? 1) }
      return ok ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                : ["ok": false, "status": 409, "error": "core not running or state missing"]
    }

    // GET /api/debug/screenshot — raw PNG bytes (not the JSON envelope).
    server.addRawHandler(forMethod: "GET", path: "/api/debug/screenshot") { _, _ in
      guard let png = DOLDebugBridge.screenshotPNG(withTimeout: 3) else {
        return .error("screenshot not produced within 3s (core running?)", status: 504)
      }
      return NativeWebServer.RawResponse(status: 200, contentType: "image/png", body: png)
    }

    // GET /api/debug/build-info
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/build-info") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.buildInfo()]
    }

    // GET /api/debug/render-state
    server.addCustomHandler(forMethod: "GET", path: "/api/debug/render-state") { _, _, _, _ in
      ["ok": true, "data": DOLDebugBridge.renderState()]
    }

    // GET /api/logs  query {"tail":N=200}
    server.addCustomHandler(forMethod: "GET", path: "/api/logs") { _, _, query, _ in
      let n = Int(query?["tail"] ?? "") ?? 200
      return ["ok": true, "data": ["lines": DOLDebugBridge.logTail(n)]]
    }

    registered = true
  }

  // MARK: - Encoding helper

  /// Encode a Codable into a JSON object suitable for JSONSerialization.
  private static func encodeJSONObject<T: Encodable>(_ value: T) -> Any? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
