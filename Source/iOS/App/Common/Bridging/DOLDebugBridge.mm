// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLDebugBridge.h"

#import <Foundation/Foundation.h>

// C++ includes
#include <mutex>
#include <deque>
#include "Common/CommonPaths.h"
#include "Common/Config/Config.h"
#include "Common/FileUtil.h"
#include "Common/Logging/LogManager.h"
#include "Common/Version.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/Movie.h"
#include "Core/State.h"
#include "Core/System.h"
#include "VideoCommon/VideoConfig.h"

static NSString* StateName(Core::State s) {
  switch (s) {
    case Core::State::Uninitialized: return @"uninitialized";
    case Core::State::Starting: return @"starting";
    case Core::State::Running: return @"running";
    case Core::State::Paused: return @"paused";
    case Core::State::Stopping: return @"stopping";
  }
  return @"unknown";
}

// Log ring + listener. LOG_WINDOW_LISTENER is free on iOS: LogManager itself only wires up
// FILE_LISTENER + CONSOLE_LISTENER at init (Common/Logging/LogManager.cpp), and
// LOG_WINDOW_LISTENER is otherwise only registered by DolphinQt's LogWidget, which iOS
// doesn't build. (Verified via `grep -rn RegisterListener` across Source/Core + Source/iOS.)
namespace {
std::mutex g_log_mutex;
std::deque<std::string> g_log_ring;
void (^g_log_handler)(NSString*, NSString*) = nil;
class RingListener : public Common::Log::LogListener {
 public:
  void Log(Common::Log::LogLevel level, const char* msg) override {
    std::lock_guard<std::mutex> lk(g_log_mutex);
    g_log_ring.emplace_back(msg);
    if (g_log_ring.size() > 2000) g_log_ring.pop_front();
    if (g_log_handler && level <= Common::Log::LogLevel::LWARNING)
      g_log_handler(level == Common::Log::LogLevel::LERROR ? @"ERROR" : @"WARN", @(msg));
  }
};
std::once_flag g_log_once;
void (^g_state_handler)(NSString*) = nil;
int g_state_cb_handle = -1;
Config::ConfigChangedCallbackID g_config_cb;
}  // namespace

@implementation DOLDebugBridge

+ (NSString*)coreState { return StateName(Core::GetState(Core::System::GetInstance())); }

+ (BOOL)pause {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  Core::SetState(sys, Core::State::Paused);
  return YES;
}
+ (BOOL)resume {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  Core::SetState(sys, Core::State::Running);
  return YES;
}

+ (NSInteger)frameAdvance:(NSInteger)n timeoutSeconds:(double)timeout {
  auto& sys = Core::System::GetInstance();
  NSInteger done = 0;
  for (NSInteger i = 0; i < n; i++) {
    if (Core::GetState(sys) != Core::State::Paused) break;
    const uint64_t before = sys.GetMovie().GetCurrentFrame();
    Core::DoFrameStep(sys);
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!(Core::GetState(sys) == Core::State::Paused && sys.GetMovie().GetCurrentFrame() > before)) {
      if ([deadline timeIntervalSinceNow] < 0) return done;
      [NSThread sleepForTimeInterval:0.002];
    }
    done++;
  }
  return done;
}

+ (uint64_t)frameCount { return Core::System::GetInstance().GetMovie().GetCurrentFrame(); }

+ (nullable NSData*)screenshotPNGWithTimeout:(double)timeout {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return nil;
  const std::string name = "debugapi-" + std::to_string((long long)([[NSDate date] timeIntervalSince1970] * 1000));
  Core::SaveScreenShot(name);
  // SaveScreenShot writes <Screenshots>/<GameID>/<name>.png asynchronously (Core::Core.cpp
  // GenerateScreenshotFolderPath + SaveScreenShot(string_view)).
  const std::string gameId = SConfig::GetInstance().GetGameID();
  std::string path = File::GetUserPath(D_SCREENSHOTS_IDX) + gameId + DIR_SEP_CHR + name + ".png";
  NSString* ns = @(path.c_str());
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  unsigned long long lastSize = 0;
  while ([deadline timeIntervalSinceNow] > 0) {
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:ns error:nil];
    unsigned long long size = [attrs fileSize];
    if (size > 0 && size == lastSize) {
      NSData* data = [NSData dataWithContentsOfFile:ns];
      [[NSFileManager defaultManager] removeItemAtPath:ns error:nil];
      return data;
    }
    lastSize = size;
    [NSThread sleepForTimeInterval:0.05];
  }
  return nil;
}

+ (BOOL)loadStateSlot:(NSInteger)slot {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  State::Load(sys, (int)slot);
  return YES;
}
+ (BOOL)loadStatePath:(NSString*)path {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys) || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  State::LoadAs(sys, path.UTF8String);
  return YES;
}
+ (BOOL)saveStateSlot:(NSInteger)slot {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  State::Save(sys, (int)slot, /*wait=*/true);
  return YES;
}

+ (NSDictionary<NSString*, id>*)renderState {
  const auto& c = g_ActiveConfig;
  return @{
    @"backend" : @(Config::Get(Config::MAIN_GFX_BACKEND).c_str()),
    @"internal_resolution" : @(c.iEFBScale),
    @"cpu_core" : @((int)Config::Get(Config::MAIN_CPU_CORE)),
    @"dual_core" : @(Config::Get(Config::MAIN_CPU_THREAD)),
    @"vertex_loader_type" : @((int)c.vertex_loader_type),
    @"fast_math" : @(Config::Get(Config::GFX_HACK_FAST_MATH)),
    @"neon_texture_decode" : @(c.bNEONTextureDecode),
    @"immediate_xfb" : @(c.bImmediateXFB),
    @"skip_efb_copy_to_ram" : @(c.bSkipEFBCopyToRam),
    @"vi_skip_mode" : @((int)Config::Get(Config::GFX_HACK_VI_SKIP_MODE)),
    @"overclock_enable" : @(Config::Get(Config::MAIN_OVERCLOCK_ENABLE)),
    @"overclock" : @(Config::Get(Config::MAIN_OVERCLOCK)),
    @"vi_overclock" : @(Config::Get(Config::MAIN_VI_OVERCLOCK)),
    @"core_state" : [self coreState],
  };
}

+ (NSDictionary<NSString*, id>*)buildInfo {
  NSBundle* b = [NSBundle mainBundle];
  return @{
    @"scm_rev" : @(Common::GetScmRevStr().c_str()),
    @"scm_branch" : @(Common::GetScmBranchStr().c_str()),
    @"app_version" : b.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
    @"app_build" : b.infoDictionary[@"CFBundleVersion"] ?: @"",
#if DEBUG
    @"configuration" : @"debug",
#else
    @"configuration" : @"release",
#endif
  };
}

+ (NSArray<NSString*>*)logTail:(NSInteger)count {
  std::lock_guard<std::mutex> lk(g_log_mutex);
  NSMutableArray* out = [NSMutableArray array];
  size_t start = g_log_ring.size() > (size_t)count ? g_log_ring.size() - count : 0;
  for (size_t i = start; i < g_log_ring.size(); i++) [out addObject:@(g_log_ring[i].c_str())];
  return out;
}

+ (void)setConfigChangedHandler:(void (^)(void))handler {
  static bool registered = false;
  static void (^stored)(void) = nil;
  stored = handler;
  if (!registered) {
    g_config_cb = Config::AddConfigChangedCallback([] { if (stored) stored(); });
    registered = true;
  }
}
+ (void)setLogHandler:(void (^)(NSString*, NSString*))handler {
  std::call_once(g_log_once, [] {
    auto* mgr = Common::Log::LogManager::GetInstance();
    mgr->RegisterListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, std::make_unique<RingListener>());
    mgr->EnableListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, true);
  });
  std::lock_guard<std::mutex> lk(g_log_mutex);
  g_log_handler = handler;
}
+ (void)setCoreStateHandler:(void (^)(NSString*))handler {
  g_state_handler = handler;
  if (g_state_cb_handle < 0)
    g_state_cb_handle = Core::AddOnStateChangedCallback([](Core::State s) { if (g_state_handler) g_state_handler(StateName(s)); });
}

@end
