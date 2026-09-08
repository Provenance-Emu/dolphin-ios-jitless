// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class GameFilePtrWrapper;

NS_ASSUME_NONNULL_BEGIN

@interface TVGameItem : NSObject

@property (nonatomic, readonly) NSString *id;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *filePath;
@property (nonatomic, readonly) BOOL isNKit;
@property (nonatomic, readonly) UIImage *coverImage;
@property (nonatomic, readonly, nullable) UIImage *bannerImage; // Animated game banner/icon
@property (nonatomic, readonly) GameFilePtrWrapper *wrapper;
@property (nonatomic, readonly) NSString *gameID;
@property (nonatomic, readonly) NSInteger discNumber;
@property (nonatomic, readonly) NSInteger revision;
@property (nonatomic, readonly) NSString *countryName;
@property (nonatomic, readonly) NSString *makerLong;
@property (nonatomic, readonly, nullable) NSString *apploaderDateString;
@property (nonatomic, readonly, nullable) NSString *titleIDHex;
@property (nonatomic, readonly) NSString *gametdbID;
@property (nonatomic, readonly) NSUInteger fileSize;
@property (nonatomic, readonly) NSInteger platform; // DiscIO::Platform enum value

/// User flag for Favorites (persisted via NSUserDefaults)
@property (nonatomic, getter=isFavorite) BOOL favorite;

/// YES for a synthetic entry created by screenshot mode (see
/// `TVLibraryBridge.isScreenshotDemoMode`). Such an item has NO backing
/// `GameFile` — its `wrapper` is nil despite the nonnull annotation — so it
/// must never be booted. Always NO in Release builds.
@property (nonatomic, readonly, getter=isDemoItem) BOOL demoItem;

- (instancetype)initWithWrapper:(GameFilePtrWrapper *)wrapper NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

#ifdef DEBUG
/// DEBUG-only initializer for screenshot mode's fake library. Populates the
/// same ivars `initWithWrapper:` does, from literal values instead of a
/// `GameFile`, and renders a procedural cover so no copyrighted art ships.
/// `platform` is a `DiscIO::Platform` raw value (0 = GameCube disc,
/// 2 = Wii disc, 3 = Wii WAD).
- (instancetype)initWithDemoTitle:(NSString *)title
                           gameID:(NSString *)gameID
                         platform:(NSInteger)platform
                            maker:(NSString *)maker
                      countryName:(NSString *)countryName
                         fileSize:(NSUInteger)fileSize
                        accentHue:(CGFloat)accentHue;
#endif

@end

NS_ASSUME_NONNULL_END
