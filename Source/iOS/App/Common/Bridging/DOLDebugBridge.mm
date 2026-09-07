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
#include "Core/CoreTiming.h"
#include "Core/Movie.h"
#include "Core/State.h"
#include "Core/System.h"
#include "VideoCommon/VideoConfig.h"

#import "HostQueue.h"

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
// Guards g_log_ring plus all three handler globals below. Every access only holds the lock
// long enough to append to the ring or copy a block pointer in/out -- the block itself is
// always invoked with the lock released, so a handler is free to call back into this bridge
// (e.g. re-register itself) without risking self-deadlock.
std::mutex g_handler_mutex;
std::deque<std::string> g_log_ring;
void (^g_log_handler)(NSString*, NSString*) = nil;
void (^g_state_handler)(NSString*) = nil;
void (^g_config_handler)(void) = nil;

class RingListener : public Common::Log::LogListener {
 public:
  void Log(Common::Log::LogLevel level, const char* msg) override {
    void (^handler)(NSString*, NSString*) = nil;
    {
      std::lock_guard<std::mutex> lk(g_handler_mutex);
      g_log_ring.emplace_back(msg);
      if (g_log_ring.size() > 2000) g_log_ring.pop_front();
      // Forward only WARN/ERROR. LogLevel numbers LNOTICE=1, LERROR=2, LWARNING=3 (severity
      // does NOT increase monotonically with the enum value), so `level <= LWARNING` would
      // incorrectly also forward LNOTICE -- which is startup/OSReport spam, not a real
      // warning or error.
      if (level == Common::Log::LogLevel::LERROR || level == Common::Log::LogLevel::LWARNING)
        handler = g_log_handler;
    }
    if (handler) {
      NSString* levelName = level == Common::Log::LogLevel::LERROR ? @"ERROR" : @"WARN";
      handler(levelName, @(msg));
    }
  }
};
}  // namespace

@implementation DOLDebugBridge

+ (NSString*)coreState { return StateName(Core::GetState(Core::System::GetInstance())); }

+ (BOOL)pause {
  if (!Core::IsRunning(Core::System::GetInstance())) return NO;
  // Core::SetState ultimately reaches PauseAndLock, which is host-thread-only.
  DOLHostQueueRunSync(^{
    Core::SetState(Core::System::GetInstance(), Core::State::Paused);
  });
  return YES;
}
+ (BOOL)resume {
  if (!Core::IsRunning(Core::System::GetInstance())) return NO;
  DOLHostQueueRunSync(^{
    Core::SetState(Core::System::GetInstance(), Core::State::Running);
  });
  return YES;
}

+ (NSInteger)frameAdvance:(NSInteger)n timeoutSeconds:(double)timeout {
  NSInteger done = 0;
  for (NSInteger i = 0; i < n; i++) {
    if (Core::GetState(Core::System::GetInstance()) != Core::State::Paused) break;
    const uint64_t before = Core::System::GetInstance().GetMovie().GetCurrentFrame();
    // Core::DoFrameStep is `// NOTE: Host Thread` (Core.cpp) -- run it on the host queue and
    // wait for that single dispatch to finish. The "did the frame actually land" poll below
    // stays OFF the host queue (it only reads atomics), so it can never block the host thread.
    DOLHostQueueRunSync(^{
      Core::DoFrameStep(Core::System::GetInstance());
    });
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!(Core::GetState(Core::System::GetInstance()) == Core::State::Paused &&
             Core::System::GetInstance().GetMovie().GetCurrentFrame() > before)) {
      if ([deadline timeIntervalSinceNow] < 0) return done;
      [NSThread sleepForTimeInterval:0.002];
    }
    done++;
  }
  return done;
}

+ (uint64_t)frameCount { return Core::System::GetInstance().GetMovie().GetCurrentFrame(); }

+ (nullable NSData*)screenshotPNGWithTimeout:(double)timeout {
  if (!Core::IsRunning(Core::System::GetInstance())) return nil;
  const std::string name = "debugapi-" + std::to_string((long long)([[NSDate date] timeIntervalSince1970] * 1000));
  // Core::SaveScreenShot must run on the host thread. The screenshot file it triggers is
  // written asynchronously, so the poll loop below stays off the host queue -- it only reads
  // the filesystem and never blocks the host thread.
  //
  // SConfig::GetInstance().GetGameID() is read here too, inside the same host-queue hop,
  // rather than on the caller's (server) queue: SConfig is host-thread-confined the same
  // way Core::SaveScreenShot is, and reading it from the server queue while the host thread
  // concurrently mutates config during boot/shutdown is a data race.
  __block std::string gameId;
  DOLHostQueueRunSync(^{
    Core::SaveScreenShot(name);
    gameId = SConfig::GetInstance().GetGameID();
  });
  // SaveScreenShot writes <Screenshots>/<GameID>/<name>.png asynchronously (Core::Core.cpp
  // GenerateScreenshotFolderPath + SaveScreenShot(string_view)).
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
  if (!Core::IsRunning(Core::System::GetInstance())) return NO;
  // State::Load reaches PauseAndLock -- host-thread-only, same as pause/resume above.
  DOLHostQueueRunSync(^{
    State::Load(Core::System::GetInstance(), (int)slot);
  });
  return YES;
}
+ (BOOL)loadStatePath:(NSString*)path {
  if (!Core::IsRunning(Core::System::GetInstance()) || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  DOLHostQueueRunSync(^{
    State::LoadAs(Core::System::GetInstance(), path.UTF8String);
  });
  return YES;
}
+ (BOOL)saveStateSlot:(NSInteger)slot {
  if (!Core::IsRunning(Core::System::GetInstance())) return NO;
  DOLHostQueueRunSync(^{
    State::Save(Core::System::GetInstance(), (int)slot, /*wait=*/true);
  });
  return YES;
}

+ (NSDictionary<NSString*, id>*)renderState {
  const auto& c = g_ActiveConfig;
  // Ruling (final whole-branch review, item 6): config-sourced fields below are
  // renamed with a `_configured` suffix -- they report what Config says, NOT
  // what the running core is actually doing (there's no cheap accessor for the
  // CPU core actually in use). `vi_skip_active` is the one addition here that
  // IS a runtime read: CoreTimingManager::GetVISkip() reports whether VI-skip
  // is in effect for the current frame, same category as the g_ActiveConfig
  // (`c.*`) fields below it.
  return @{
    @"backend" : @(Config::Get(Config::MAIN_GFX_BACKEND).c_str()),
    @"internal_resolution" : @(c.iEFBScale),
    @"cpu_core_configured" : @((int)Config::Get(Config::MAIN_CPU_CORE)),
    @"dual_core_configured" : @(Config::Get(Config::MAIN_CPU_THREAD)),
    @"vertex_loader_type" : @((int)c.vertex_loader_type),
    @"fast_math" : @(Config::Get(Config::GFX_HACK_FAST_MATH)),
    @"neon_texture_decode" : @(c.bNEONTextureDecode),
    @"immediate_xfb" : @(c.bImmediateXFB),
    @"skip_efb_copy_to_ram" : @(c.bSkipEFBCopyToRam),
    @"vi_skip_mode_configured" : @((int)Config::Get(Config::GFX_HACK_VI_SKIP_MODE)),
    @"vi_skip_active" : @(Core::System::GetInstance().GetCoreTiming().GetVISkip()),
    @"overclock_enable_configured" : @(Config::Get(Config::MAIN_OVERCLOCK_ENABLE)),
    @"overclock_configured" : @(Config::Get(Config::MAIN_OVERCLOCK)),
    @"vi_overclock_configured" : @(Config::Get(Config::MAIN_VI_OVERCLOCK)),
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
  std::lock_guard<std::mutex> lk(g_handler_mutex);
  NSMutableArray* out = [NSMutableArray array];
  size_t start = g_log_ring.size() > (size_t)count ? g_log_ring.size() - count : 0;
  for (size_t i = start; i < g_log_ring.size(); i++) [out addObject:@(g_log_ring[i].c_str())];
  return out;
}

+ (void)setConfigChangedHandler:(void (^)(void))handler {
  {
    std::lock_guard<std::mutex> lk(g_handler_mutex);
    g_config_handler = handler;
  }
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Callback ID is intentionally discarded: this listener is never removed for the
    // lifetime of the process, so there is nothing to do with the returned ID.
    (void)Config::AddConfigChangedCallback([] {
      void (^handler)(void) = nil;
      {
        std::lock_guard<std::mutex> lk(g_handler_mutex);
        handler = g_config_handler;
      }
      if (handler) handler();
    });
  });
}
+ (void)setLogHandler:(void (^)(NSString*, NSString*))handler {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    auto* mgr = Common::Log::LogManager::GetInstance();
    mgr->RegisterListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, std::make_unique<RingListener>());
    mgr->EnableListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, true);
  });
  std::lock_guard<std::mutex> lk(g_handler_mutex);
  g_log_handler = handler;
}
+ (void)setCoreStateHandler:(void (^)(NSString*))handler {
  {
    std::lock_guard<std::mutex> lk(g_handler_mutex);
    g_state_handler = handler;
  }
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Core::AddOnStateChangedCallback([](Core::State s) {
      void (^handler)(NSString*) = nil;
      {
        std::lock_guard<std::mutex> lk(g_handler_mutex);
        handler = g_state_handler;
      }
      if (handler) handler(StateName(s));
    });
  });
}

@end
