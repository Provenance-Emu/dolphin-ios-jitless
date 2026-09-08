// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class TVGameItem;

NS_ASSUME_NONNULL_BEGIN

@interface TVLibraryBridge : NSObject

/// YES when the app was launched with `-SCREENSHOT_MODE 1` (a DEBUG-only
/// marketing-capture mode). In this mode `currentGames` returns a fixed set of
/// synthetic, non-bootable demo titles with procedurally generated cover art
/// instead of scanning for disc images, so the library can be photographed
/// without shipping or possessing any copyrighted content.
/// Always NO in Release builds.
+ (BOOL)isScreenshotDemoMode;

+ (NSArray<TVGameItem*>*)currentGames;
+ (void)rescanAndFetchMetadataWithCompletion:(void(^)(void))completion;
+ (void)rescanLocalAndFetchMetadata:(void(^)(void))completion;
+ (void)loadGameCubeMainMenu;
+ (void)performOnlineSystemUpdate;
+ (void)performOnlineSystemUpdateWithRegion:(NSString*)regionCode;

/// Returns YES if a Wii System Menu is installed in NAND
+ (BOOL)isWiiSystemMenuInstalled;
/// Boots the Wii System Menu (no-op if not installed)
+ (void)loadWiiSystemMenu;

/// Merge the provided absolute paths/URLs into the library cache and optionally fetch metadata.
+ (void)updateLibraryWithRemotePaths:(NSArray<NSString*>*)paths fetchMetadata:(BOOL)fetch;

@end

NS_ASSUME_NONNULL_END
