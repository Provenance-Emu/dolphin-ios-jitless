// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift
//
// Lifecycle owner for the debug/benchmark HTTP server. Self-gating:
//   - DEBUG builds: `start()` always starts the server (developer convenience).
//   - Release builds: `start()` starts ONLY when the user has flipped the
//     "Perf Test Bench (HTTP)" toggle, persisted in UserDefaults under
//     `ICubeBenchServerEnabled` (default OFF). With the toggle off — the default
//     for every shipping install — nothing binds, so there is no always-on local
//     HTTP server to flag in App Store review.
//
// App Store safety: the server is loopback-only (NativeWebServer binds 127.0.0.1;
// do not change that — it's the review-safety property), default-off, and gated
// behind a user-visible toggle. Reaching it requires an explicit USB
// `iproxy 8723 8723` forward from a Mac. Opt-in developer feature, not a service.
//
// ObjC visibility: this is `@objc`/NSObject so EmulationCoordinator.mm (ObjC++)
// can call `[DebugServerManager.shared start]` through the generated
// iCube-Swift.h.

import Foundation

@objc(DebugServerManager)
@MainActor
final class DebugServerManager: NSObject {
  @objc(sharedManager) static let shared = DebugServerManager()

  private(set) var isRunning = false
  private(set) var serverURL: String = ""

  /// Port for the loopback debug API. Reach it over USB with:
  ///   iproxy 8723 8723
  static let port: UInt16 = 8723

  private let server = NativeWebServer(port: DebugServerManager.port)
  private let routes = DebugAPIRoutes()

  override private init() { super.init() }

  /// UserDefaults key for the Release-build opt-in. Default OFF.
  static let enabledDefaultsKey = "ICubeBenchServerEnabled"

  /// Whether the server is permitted to run. Always true in DEBUG; in Release
  /// only when the user has opted in via the "Perf Test Bench (HTTP)" toggle.
  private var isEnabled: Bool {
    #if DEBUG
    return true
    #else
    return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    #endif
  }

  /// Start the server. No-op unless permitted (see `isEnabled`).
  @objc func start() {
    guard isEnabled else { return }
    guard !isRunning else { return }
    server.webSocketHandler = { path, socket in
      guard path == "/ws/events" else { return false }
      DebugEventBus.shared.attach(socket)
      return true
    }
    DebugEventBus.shared.startProducers()
    routes.registerRoutes(on: server)
    Task {
      do {
        try await server.start()
        self.isRunning = true
        self.serverURL = self.server.serverURL?.absoluteString ?? "http://127.0.0.1:\(Self.port)/"
        NSLog("[DebugServer] listening on \(self.serverURL) (loopback only; iproxy to reach over USB)")
      } catch {
        self.isRunning = false
        NSLog("[DebugServer] failed to start: \(error.localizedDescription)")
      }
    }
  }

  @objc func stop() {
    guard isRunning else { return }
    server.stop()
    isRunning = false
    serverURL = ""
  }
}
