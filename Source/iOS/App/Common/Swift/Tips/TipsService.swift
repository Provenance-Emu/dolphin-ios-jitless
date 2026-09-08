import Foundation
import SwiftUI

/// Abstraction for tips to allow injection and testing
@MainActor
public protocol TipsProviding {
  func configure()
  func record(event: String)
}

/// No-op fallback for platforms without TipKit
@MainActor
public final class NoopTipsService: TipsProviding {
  public static let shared = NoopTipsService()
  private init() {}
  public func configure() {}
  public func record(event: String) {}
}

#if canImport(TipKit)
import TipKit

@available(iOS 17, tvOS 17, *)
@MainActor
public final class LiveTipsService: TipsProviding {
  public static let shared = LiveTipsService()
  private init() {}
  public func configure() {
    // Screenshot mode photographs the UI itself, and a TipKit coach mark pops
    // up on its own schedule right on top of the shot. Never configuring TipKit
    // is the only reliable way to keep it off screen: unlike the one-shot
    // interstitials, tips have no UserDefaults key to pre-set.
    if TVLibraryBridge.isScreenshotDemoMode() { return }
    try? Tips.configure()
  }
  public func record(event: String) {}
}
#endif

private struct TipsServiceKey: EnvironmentKey {
  @MainActor
  static var defaultValue: TipsProviding {
    #if canImport(TipKit)
    if #available(iOS 17, tvOS 17, *) { return LiveTipsService.shared }
    #endif
    return NoopTipsService.shared
  }
}

public extension EnvironmentValues {
  var tipsService: TipsProviding {
    get { self[TipsServiceKey.self] }
    set { self[TipsServiceKey.self] = newValue }
  }
}
