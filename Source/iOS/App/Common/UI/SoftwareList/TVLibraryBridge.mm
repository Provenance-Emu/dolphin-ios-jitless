// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVLibraryBridge.h"
#import <TargetConditionals.h>

#import "GameFileCacheManager.h"
#import "GameFilePtrWrapper.h"
#import "TVGameItem.h"
#import "Core/Core.h"
#import "Core/System.h"
#import "UICommon/UICommon.h"
#import "EmulationCoordinator.h"
#include "Core/BootManager.h"
#include "Core/Boot/Boot.h"
#include "DiscIO/Enums.h"
#include "Core/IOS/IOS.h"
#include "Core/IOS/ES/ES.h"
#include "Core/CommonTitles.h"
#import "EmulationBootParameter.h"
#import "EmulationBootType.h"
#import "WiiSystemUpdateViewController.h"
#import "TVWiiSystemUpdateViewController.h"

@implementation TVLibraryBridge

#ifdef DEBUG

#pragma mark - Screenshot mode

// Fixed demo catalogue for `-SCREENSHOT_MODE 1`. Every title, publisher and ID
// here is invented for iCube's own marketing shots — no real game, box art or
// trademark is referenced. Order is fixed so captures are reproducible.
//
// platform: DiscIO::Platform raw values — 0 GameCube disc, 2 Wii disc, 3 WAD.
typedef struct {
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *gameID;
  NSInteger platform;
  __unsafe_unretained NSString *maker;
  __unsafe_unretained NSString *country;
  NSUInteger sizeMB;
  CGFloat hue;
} DOLDemoGameSpec;

static NSArray<TVGameItem*>* DOLScreenshotDemoGames(void) {
  static NSArray<TVGameItem*>* cached = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const DOLDemoGameSpec specs[] = {
      { @"Starfall Rally",       @"GSRE01", 0, @"Nimbus Interactive",  @"USA",    1350, 0.58 },
      { @"Cube Quest",           @"GCQP01", 0, @"Bitwave Studios",     @"Europe", 1180, 0.09 },
      { @"Lantern Hollow",       @"GLHE01", 0, @"Foxglove Games",      @"USA",     940, 0.33 },
      { @"Tidebreaker",          @"GTBJ01", 0, @"Kaisei Works",        @"Japan",  1420, 0.53 },
      { @"Neon Circuit GP",      @"GNCE01", 0, @"Nimbus Interactive",  @"USA",    1290, 0.78 },
      { @"Marbles & Machines",   @"GMME01", 0, @"Tiny Anvil",          @"USA",     760, 0.13 },
      { @"Emberfall Chronicles", @"RECE01", 2, @"Foxglove Games",      @"USA",    4300, 0.02 },
      { @"Skyward Drift",        @"RSDP01", 2, @"Bitwave Studios",     @"Europe", 3980, 0.55 },
      { @"Wavelink Sports",      @"RWSE01", 2, @"Harbor Light",        @"USA",    2140, 0.44 },
      { @"Glacier Point",        @"RGPE01", 2, @"Kaisei Works",        @"USA",    4510, 0.50 },
      { @"Orchard Party",        @"ROPE01", 2, @"Tiny Anvil",          @"USA",    1870, 0.26 },
      { @"Deep Signal",          @"RDSJ01", 2, @"Harbor Light",        @"Japan",  4720, 0.66 },
      { @"Pixel Pilots",         @"WPPE01", 3, @"Tiny Anvil",          @"USA",      42, 0.86 },
      { @"Tower of Cogs",        @"WTCE01", 3, @"Bitwave Studios",     @"USA",      68, 0.11 },
      { @"Lumen Lanes",          @"WLLP01", 3, @"Harbor Light",        @"Europe",   31, 0.71 },
      { @"Root & Rune",          @"WRRE01", 3, @"Foxglove Games",      @"USA",      55, 0.30 },
    };
    const size_t count = sizeof(specs) / sizeof(specs[0]);

    NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
      const DOLDemoGameSpec s = specs[i];
      TVGameItem *item = [[TVGameItem alloc] initWithDemoTitle:s.title
                                                        gameID:s.gameID
                                                      platform:s.platform
                                                         maker:s.maker
                                                   countryName:s.country
                                                      fileSize:s.sizeMB * 1024 * 1024
                                                     accentHue:s.hue];
      [items addObject:item];
    }
    cached = [items copy];

    // Seed a deterministic Favorites row (the library reads this defaults key
    // directly). Overwrites rather than merges, so repeat runs are identical.
    [[NSUserDefaults standardUserDefaults] setObject:@{
      @"GSRE01": @YES,
      @"RECE01": @YES,
      @"GNCE01": @YES,
    } forKey:@"favorites_by_gameid"];

    NSLog(@"[ScreenshotMode] seeded %zu demo library entries", count);
  });
  return cached;
}

#endif  // DEBUG

+ (BOOL)isScreenshotDemoMode {
#ifdef DEBUG
  static BOOL enabled = NO;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // NSUserDefaults surfaces `-SCREENSHOT_MODE 1` launch arguments in the
    // NSArgumentDomain, so simctl launch --args works with no extra parsing.
    enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"SCREENSHOT_MODE"];
    if (enabled) NSLog(@"[ScreenshotMode] enabled — library will show synthetic demo titles");
  });
  return enabled;
#else
  return NO;
#endif
}

+ (NSArray<TVGameItem*>*)currentGames {
#ifdef DEBUG
  if ([self isScreenshotDemoMode]) {
    return DOLScreenshotDemoGames();
  }
#endif
  return [[GameFileCacheManager sharedManager] currentGames];
}

+ (void)rescanAndFetchMetadataWithCompletion:(void(^)(void))completion {
#ifdef DEBUG
  // Screenshot mode's library is fixed: a real rescan would spin the refresh UI
  // (and hit remote sources) for a list that cannot change.
  if ([self isScreenshotDemoMode]) { if (completion) completion(); return; }
#endif
  [[GameFileCacheManager sharedManager] rescanAndFetchMetadataWithCompletionHandler:^{
    if (completion) completion();
  }];
}

+ (void)rescanLocalAndFetchMetadata:(void(^)(void))completion {
#ifdef DEBUG
  if ([self isScreenshotDemoMode]) { if (completion) completion(); return; }
#endif
  [[GameFileCacheManager sharedManager] rescanLocalAndFetchMetadataWithCompletionHandler:^{
    if (completion) completion();
  }];
}

+ (void)loadGameCubeMainMenu {
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeGCIPL;
  p.iplRegion = DiscIO::Region::NTSC_U;
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (BOOL)isWiiSystemMenuInstalled {
  // Prefer existing IOS if present to avoid creating a temporary Kernel while one exists
  if (Core::System::GetInstance().GetIOS() != nullptr) {
    const auto tmd = Core::System::GetInstance().GetIOS()->GetESCore().FindInstalledTMD(Titles::SYSTEM_MENU);
    return tmd.IsValid();
  } else {
    IOS::HLE::Kernel ios;
    const auto tmd = ios.GetESCore().FindInstalledTMD(Titles::SYSTEM_MENU);
    return tmd.IsValid();
  }
}

+ (void)loadWiiSystemMenu {
  if (![self isWiiSystemMenuInstalled]) return;
  // Ensure no IOS instance is attached before boot pipeline constructs a temporary Kernel
  if (Core::System::GetInstance().GetIOS() != nullptr) {
    Core::System::GetInstance().SetIOS(std::unique_ptr<IOS::HLE::EmulationKernel>());
  }
  EmulationBootParameter* p = [EmulationBootParameter new];
  p.bootType = EmulationBootTypeSystemMenu;
  [[EmulationCoordinator shared] runEmulationWithBootParameter:p];
}

+ (void)presentUpdateControllerWithRegion:(NSString*)regionCode {
  UIViewController* root = UIApplication.sharedApplication.keyWindow.rootViewController;
  if (!root) return;

  // Prefer the unified TVWiiSystemUpdateViewController on all platforms
  if ([TVWiiSystemUpdateViewController class]) {
    TVWiiSystemUpdateViewController* vc = [TVWiiSystemUpdateViewController new];
    if (regionCode.length > 0) { vc.updateSource = regionCode; }
    vc.isOnlineUpdate = YES;
    [root presentViewController:vc animated:YES completion:nil];
    return;
  }

  // Fallback (older iOS builds): storyboard-based updater
  @try {
    UIStoryboard* sb = [UIStoryboard storyboardWithName:@"WiiSystemUpdate" bundle:nil];
    if (sb) {
      UIViewController* vc = (UIViewController*)[sb instantiateInitialViewController];
      if (vc) {
        if (regionCode.length > 0 && [vc respondsToSelector:@selector(setUpdateSource:)]) {
          [vc setValue:regionCode forKey:@"updateSource"];
        }
        if ([vc respondsToSelector:@selector(setIsOnlineUpdate:)]) {
          [vc setValue:@(YES) forKey:@"isOnlineUpdate"];
        }
        [root presentViewController:vc animated:YES completion:nil];
        return;
      }
    }
  } @catch (...) {
  }
}

+ (void)performOnlineSystemUpdate {
  [self presentUpdateControllerWithRegion:nil];
}

+ (void)performOnlineSystemUpdateWithRegion:(NSString*)regionCode {
  [self presentUpdateControllerWithRegion:regionCode];
}

+ (void)updateLibraryWithRemotePaths:(NSArray<NSString*>*)paths fetchMetadata:(BOOL)fetch {
  printf("DEBUG BRIDGE: TVLibraryBridge received %lu remote paths\n", (unsigned long)paths.count);
  for (NSUInteger i = 0; i < paths.count; i++) {
    printf("DEBUG BRIDGE:   [%lu]: %s\n", (unsigned long)i, [paths[i] UTF8String]);
  }
  printf("DEBUG BRIDGE: Calling GameFileCacheManager updateWithExtraPaths\n");
  [[GameFileCacheManager sharedManager] updateWithExtraPaths:paths fetchMetadata:fetch];
  printf("DEBUG BRIDGE: GameFileCacheManager updateWithExtraPaths completed\n");
}

@end
