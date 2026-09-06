// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVEmulationBridge.h"

#import <UIKit/UIKit.h>

#import "EmulationCoordinator.h"
#import "EmulationBootParameter.h"
#import "EmulationBootType.h"

// C++ Core host messaging
#include "Core/Host.h"
#include "Core/Core.h"
#include "Core/System.h"
#include "Core/State.h"
#include "Core/ConfigManager.h"
#include "Common/FileUtil.h"
#include "Common/Version.h"
#include "Core/Config/MainSettings.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/FramebufferManager.h"
#include "VideoCommon/FrameDumper.h"
#include "VideoCommon/PostProcessing.h"
#include "WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#import "Core/Config/WiimoteSettings.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/SI/SI_Device.h"
#import "Core/HW/Wiimote.h"

extern std::unique_ptr<VideoCommon::Presenter> g_presenter;
extern std::unique_ptr<FramebufferManager> g_framebuffer_manager;

@implementation TVEmulationBridge

+ (void)runWithBootParameter:(EmulationBootParameter*)param {
  [[EmulationCoordinator shared] runEmulationWithBootParameter:param];
}

+ (void)stop {
  // Resume-where-left-off: persist the dedicated auto-state (blocking) BEFORE the
  // CPU thread is torn down, so the next launch can continue from here. Gated on
  // the user toggle; default off means this is a no-op. The auto-state lives in its
  // own "{GameID}.auto" file and never touches numbered save slots.
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"resume_where_left_off"]) {
    NSString* autoPath = [self autoStateFilePath];
    if (autoPath.length > 0) {
      State::SaveAs(Core::System::GetInstance(), std::string(autoPath.UTF8String), /*wait=*/true);
    }
  }
  Host_Message(HostMessageID::WMUserStop);
}

+ (void)pause {
  Core::SetState(Core::System::GetInstance(), Core::State::Paused);
}

+ (void)resume {
  Core::SetState(Core::System::GetInstance(), Core::State::Running);
}

+ (BOOL)isPaused {
  return Core::GetState(Core::System::GetInstance()) == Core::State::Paused;
}

+ (void)registerMainDisplayView:(UIView*)view {
  [[EmulationCoordinator shared] registerMainDisplayView:view];
}

+ (void)launchGameAtPath:(NSString*)path {
  if (path.length == 0) return;
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeFile;
  p.path = path;
  NSString* lower = path.lowercaseString;
  p.isNKit = [lower hasSuffix:@".nkit.iso"] || [lower hasSuffix:@".nkit.gcz"] || [lower hasSuffix:@".nkit"]; // best-effort
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (BOOL)isRunning {
  Core::State s = Core::GetState(Core::System::GetInstance());
  return s == Core::State::Running || s == Core::State::Paused || s == Core::State::Starting;
}

+ (void)saveStateToSlot:(NSInteger)slot wait:(BOOL)wait {
  State::Save(Core::System::GetInstance(), (int)slot, wait);
}

+ (void)loadStateFromSlot:(NSInteger)slot {
  int s = (int)slot;
  Core::QueueHostJob([s](Core::System& system) {
    State::Load(system, s);
  });
}

+ (NSString*)currentGameID {
  const std::string game_id = SConfig::GetInstance().GetGameID();
  return [NSString stringWithUTF8String:game_id.c_str()];
}

+ (nullable NSString*)stateFilePathForSlot:(NSInteger)slot {
  const std::string game_id = SConfig::GetInstance().GetGameID();
  if (game_id.empty())
    return nil;
  // Mirror Core/State.cpp MakeStateFilename: "{StateSavesDir}{GameID}.s{NN}".
  NSString* dir = [NSString stringWithUTF8String:File::GetUserPath(D_STATESAVES_IDX).c_str()];
  NSString* gid = [NSString stringWithUTF8String:game_id.c_str()];
  return [NSString stringWithFormat:@"%@%@.s%02ld", dir, gid, (long)slot];
}

+ (nullable NSString*)autoStateFilePath {
  const std::string game_id = SConfig::GetInstance().GetGameID();
  if (game_id.empty())
    return nil;
  NSString* dir = [NSString stringWithUTF8String:File::GetUserPath(D_STATESAVES_IDX).c_str()];
  NSString* gid = [NSString stringWithUTF8String:game_id.c_str()];
  return [NSString stringWithFormat:@"%@%@.auto", dir, gid];
}

+ (void)saveStateToPath:(NSString*)path wait:(BOOL)wait {
  if (path.length == 0)
    return;
  State::SaveAs(Core::System::GetInstance(), std::string(path.UTF8String), wait);
}

+ (void)loadStateFromPath:(NSString*)path {
  if (path.length == 0)
    return;
  std::string p(path.UTF8String);
  Core::QueueHostJob([p](Core::System& system) {
    State::LoadAs(system, p);
  });
}

+ (BOOL)stateFileIsCompatibleAtPath:(NSString*)path {
  if (path.length == 0)
    return NO;
  State::StateHeader header;
  if (!State::ReadHeader(std::string(path.UTF8String), header))
    return NO;
  // Match the loader's ACTUAL acceptance test (State.cpp ValidateHeaders): a state loads iff its
  // version cookie decodes to the current STATE_VERSION. The old SCM-revision-string compare was far
  // stricter than the loader — the rev string churns on every rebaseline build, so every prior save
  // read as "Incompatible" even though it loads fine. COOKIE_BASE (0xBAADBABE) is the loader's fixed
  // magic base (State.cpp, file-local), mirrored here since the bridge can't see the constant.
  static constexpr uint32_t kCookieBase = 0xBAADBABEu;
  const uint32_t loadedVersion = header.version_header.version_cookie - kCookieBase;
  return loadedVersion == State::GetVersion() ? YES : NO;
}

+ (void)captureScreenshotToPath:(NSString*)path {
  if (path.length == 0)
    return;
  // Non-blocking request; FrameDumper writes the PNG on the next presented frame.
  if (g_frame_dumper)
    g_frame_dumper->SaveScreenshot(std::string(path.UTF8String));
}

+ (BOOL)isOverscanCompensationApplicable {
  return [[EmulationCoordinator shared] isOverscanCompensationApplicable];
}

+ (BOOL)overscanFullscreenEnabled {
  return [[EmulationCoordinator shared] overscanFullscreenEnabled];
}

+ (void)setOverscanFullscreenEnabled:(BOOL)enabled {
  [[EmulationCoordinator shared] setOverscanFullscreenEnabled:enabled];
}

// Display / Orientation helpers
+ (void)resizeSurfaceNow {
  if (g_presenter) {
    g_presenter->ResizeSurface();
  }
}

+ (void)reloadShadersNow {
  if (g_framebuffer_manager) {
    g_framebuffer_manager->RecompileShaders();
  }
}

// Fast-forward (configurable speed multiplier)
+ (BOOL)toggleFastForward {
  static float originalSpeed = 1.0f;
  static bool isFastForwarding = false;

  if (!isFastForwarding) {
    // Store original speed and enable fast forward
    originalSpeed = Config::Get(Config::MAIN_EMULATION_SPEED);

    // Get configured fast forward speed from UserDefaults
    NSInteger ffSpeedPercent = [[NSUserDefaults standardUserDefaults] integerForKey:@"fast_forward_speed_percent"];
    if (ffSpeedPercent <= 0) {
      ffSpeedPercent = 300; // Default to 3x speed
    }

    if (ffSpeedPercent == 0) {
      // Unlimited speed - use throttler disable
      Core::SetIsThrottlerTempDisabled(true);
    } else {
      // Use configured speed multiplier
      float speedMultiplier = (float)ffSpeedPercent / 100.0f;
      Config::SetCurrent(Config::MAIN_EMULATION_SPEED, speedMultiplier);
    }

    // Mute audio if configured
    if (!Config::Get(Config::MAIN_AUDIO_MUTED) &&
        Config::Get(Config::MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT)) {
      Config::SetCurrent(Config::MAIN_AUDIO_MUTED, true);
    }

    isFastForwarding = true;
  } else {
    // Restore original speed and disable fast forward
    Core::SetIsThrottlerTempDisabled(false);
    Config::SetCurrent(Config::MAIN_EMULATION_SPEED, originalSpeed);

    // Unmute audio if we muted it
    if (Config::Get(Config::MAIN_AUDIO_MUTED) &&
        Config::GetActiveLayerForConfig(Config::MAIN_AUDIO_MUTED) == Config::LayerType::CurrentRun) {
      Config::DeleteKey(Config::LayerType::CurrentRun, Config::MAIN_AUDIO_MUTED);
    }

    isFastForwarding = false;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLFastForwardToggled" object:nil userInfo:@{ @"enabled": @(isFastForwarding) }];
  });
  return isFastForwarding;
}

+ (BOOL)isFastForwardEnabled {
  // Check if current emulation speed is different from base speed or throttler is disabled
  float currentSpeed = Config::Get(Config::MAIN_EMULATION_SPEED);
  float baseSpeed = Config::GetBase(Config::MAIN_EMULATION_SPEED);
  return (currentSpeed != baseSpeed) || Core::GetIsThrottlerTempDisabled();
}

+ (BOOL)isCurrentSystemWii {
  return Core::System::GetInstance().IsWii();
}

+ (float)currentDrawAspectRatio {
  if (g_presenter)
    return (float)g_presenter->CalculateDrawAspectRatio();
  return 4.0f / 3.0f;
}

+ (void)setWiiIMUPointEnabled:(BOOL)enabled {
  // Enable/disable Wiimote IMUPoint group to avoid fighting with touch IR.
  //
  // This used to be Core::RunOnCPUThread(..., wait_for_completion = true) and was
  // the only blocking CPU-thread call in the app layer. It runs on the MAIN thread
  // from SwiftUI (.onAppear/.onDisappear of the Wii touch pads, and again at
  // emulation-screen setup), so on every Wii boot the UI thread sat in
  // PauseAndLock waiting for the CPU thread to acknowledge Stepping. When that
  // acknowledgement never came the app was exactly as reported: emulation kept
  // rendering and playing audio, every native control was dead, force-quit only.
  // GameCube titles never call this, which is why only Wii games hung.
  //
  // Pausing the core was never needed: emulated-controller settings are guarded
  // by the ControllerEmu state lock, which is how DolphinQt's mapping UI flips
  // the same groups from its own UI thread. Take the lock, set, return.
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  auto* group = Wiimote::GetWiimoteGroup(0, WiimoteEmu::WiimoteGroup::IMUPoint);
  if (group)
    group->enabled.SetValue(enabled);
}

+ (CGRect)currentVideoContentRect {
  UIView* view = [[EmulationCoordinator shared] mainDisplayView];
  if (!view) return CGRectZero;
  const CGFloat w = view.bounds.size.width;
  const CGFloat h = view.bounds.size.height;
  if (w <= 0 || h <= 0) return CGRectZero;
  const CGFloat ar = (CGFloat)[self currentDrawAspectRatio];
  // Aspect-fit the video inside view.bounds
  CGFloat contentW = w;
  CGFloat contentH = w / ar;
  if (contentH > h) {
    contentH = h;
    contentW = h * ar;
  }
  const CGFloat x = (w - contentW) * 0.5;
  const CGFloat y = (h - contentH) * 0.5;
  return CGRectMake(x, y, contentW, contentH);
}

@end
