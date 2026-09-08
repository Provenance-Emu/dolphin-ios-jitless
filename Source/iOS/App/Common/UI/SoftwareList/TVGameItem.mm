// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVGameItem.h"

#import "GameFilePtrWrapper.h"
#import "FoundationStringUtil.h"
#import "UICommon/GameFile.h"
#import "DiscIO/Enums.h"

@implementation TVGameItem {
    GameFilePtrWrapper *_wrapper;
    NSString *_id;
    NSString *_title;
    NSString *_filePath;
    BOOL _isNKit;
    UIImage *_coverImage;
    UIImage *_Nullable _bannerImage;
    NSString *_gameID;
    NSInteger _discNumber;
    NSInteger _revision;
    NSString *_countryName;
    NSString *_makerLong;
    NSString *_Nullable _apploaderDateString;
    NSString *_Nullable _titleIDHex;
    NSString *_gametdbID;
    NSUInteger _fileSize;
    NSInteger _platform;
    BOOL _demoItem;
}

- (instancetype)initWithWrapper:(GameFilePtrWrapper *)wrapper {
    self = [super init];
    if (self) {
        _wrapper = wrapper;

        // Critical safety check - ensure GameFile shared_ptr is not null
        if (!wrapper.gameFile) {
#ifdef DEBUG
            NSLog(@"TVGameItem: ERROR - null GameFile shared_ptr in wrapper, creating invalid item");
#endif
            _title = @"<null GameFile>";
            _filePath = @"<null>";
            _id = @"<null>";
            return self;
        }

        const UICommon::GameFile &game = *wrapper.gameFile;

        // Protect against invalid GameFile objects that can crash string conversion
        std::string gameName;
        std::string gamePath;

        try {
            gameName = game.GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom);
            gamePath = game.GetFilePath();
        } catch (...) {
            gameName = "<error>";
            gamePath = "<error>";
        }

        // Ensure non-empty strings for Foundation conversion
        if (gameName.empty()) gameName = "<unknown>";
        if (gamePath.empty()) gamePath = "<unknown>";

        _title = CppToFoundationString(gameName);
        _filePath = CppToFoundationString(gamePath);
        _id = _filePath; // Use filePath as unique identifier
        _isNKit = game.IsNKit();

        const UICommon::GameCover &cover = game.GetCoverImage();
        UIImage *result = nil;
        if (cover.buffer.empty()) {
            result = [UIImage imageNamed:@"NoCover"];
        } else {
            const size_t maxCoverBytes = 32 * 1024 * 1024; // 32MB sanity cap
            const size_t len = cover.buffer.size();
            if (len > 0 && len <= maxCoverBytes) {
                NSData *data = [NSData dataWithBytes:cover.buffer.data() length:len];
                result = [UIImage imageWithData:data];
            } else {
#ifdef DEBUG
                NSLog(@"TVGameItem: cover size invalid (%zu), using placeholder", len);
#endif
                result = [UIImage imageNamed:@"NoCover"];
            }
        }

        if (!result) {
            const CGSize size = CGSizeMake(200, 300);
            UIGraphicsBeginImageContextWithOptions(size, YES, 0);
            [[UIColor colorWithWhite:0.12 alpha:1.0] setFill];
            UIRectFill(CGRectMake(0, 0, size.width, size.height));
            result = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }

        _coverImage = result;

        // Extract banner image (animated game icon)
        const UICommon::GameBanner &banner = game.GetBannerImage();
        UIImage *bannerResult = nil;
        if (!banner.buffer.empty() && banner.width > 0 && banner.height > 0) {
            const size_t maxBannerBytes = 4 * 1024 * 1024; // 4MB sanity cap
            const size_t expectedSize = banner.width * banner.height * sizeof(u32);
            const size_t actualSize = banner.buffer.size() * sizeof(u32);

            if (actualSize <= maxBannerBytes && actualSize == expectedSize) {
                // Convert ARGB data to UIImage
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGDataProviderRef provider = CGDataProviderCreateWithData(
                    NULL,
                    banner.buffer.data(),
                    actualSize,
                    NULL
                );

                CGImageRef cgImage = CGImageCreate(
                    banner.width,
                    banner.height,
                    8,
                    32,
                    banner.width * 4,
                    colorSpace,
                    kCGImageAlphaFirst | kCGBitmapByteOrder32Big,
                    provider,
                    NULL,
                    false,
                    kCGRenderingIntentDefault
                );

                if (cgImage) {
                    bannerResult = [UIImage imageWithCGImage:cgImage];
                    CGImageRelease(cgImage);
                }

                CGDataProviderRelease(provider);
                CGColorSpaceRelease(colorSpace);

#ifdef DEBUG
                NSLog(@"TVGameItem: extracted banner %dx%d for '%@'", banner.width, banner.height, _title);
#endif
            } else {
#ifdef DEBUG
                NSLog(@"TVGameItem: banner size mismatch for '%@' - expected: %zu, actual: %zu", _title, expectedSize, actualSize);
#endif
            }
        }

        _bannerImage = bannerResult;

        // Protected string conversions for all GameFile properties
        std::string gameID = game.GetGameID();
        std::string countryName = DiscIO::GetName(game.GetCountry(), true);
        std::string makerLong = game.GetMaker(UICommon::GameFile::Variant::LongAndNotCustom);
        std::string apploaderDate = game.GetApploaderDate();

        if (gameID.empty()) gameID = "<unknown>";
        if (countryName.empty()) countryName = "<unknown>";
        if (makerLong.empty()) makerLong = "<unknown>";

        _gameID = CppToFoundationString(gameID);
        _discNumber = (NSInteger)game.GetDiscNumber();
        _revision = (NSInteger)game.GetRevision();
        _countryName = CppToFoundationString(countryName);
        _makerLong = CppToFoundationString(makerLong);

        if (!apploaderDate.empty()) {
            _apploaderDateString = CppToFoundationString(apploaderDate);
        } else {
            _apploaderDateString = nil;
        }
        if (const u64 titleId = game.GetTitleID()) {
            _titleIDHex = [NSString stringWithFormat:@"%016llx", titleId];
        } else {
            _titleIDHex = nil;
        }

        std::string gametdbID = game.GetGameTDBID();
        if (gametdbID.empty()) gametdbID = "<unknown>";
        _gametdbID = CppToFoundationString(gametdbID);

        _fileSize = (NSUInteger)game.GetFileSize();
        _platform = (NSInteger)game.GetPlatform();

        // Debug logging for file size
#ifdef DEBUG
        NSLog(@"TVGameItem: %@ - GameFile.GetFileSize() = %llu, TVGameItem.fileSize = %lu, Platform = %ld",
              _title, game.GetFileSize(), (unsigned long)_fileSize, (long)_platform);
#endif
    }
    return self;
}

- (NSString *)id { return _id; }
- (NSString *)title { return _title; }
- (NSString *)filePath { return _filePath; }
- (BOOL)isNKit { return _isNKit; }
- (UIImage *)coverImage { return _coverImage; }
- (UIImage * _Nullable)bannerImage { return _bannerImage; }
- (GameFilePtrWrapper *)wrapper { return _wrapper; }
- (NSString *)gameID { return _gameID; }
- (NSInteger)discNumber { return _discNumber; }
- (NSInteger)revision { return _revision; }
- (NSString *)countryName { return _countryName; }
- (NSString *)makerLong { return _makerLong; }
- (NSString * _Nullable)apploaderDateString { return _apploaderDateString; }
- (NSString * _Nullable)titleIDHex { return _titleIDHex; }
- (NSString *)gametdbID { return _gametdbID; }
- (NSUInteger)fileSize { return _fileSize; }
- (NSInteger)platform { return _platform; }
- (BOOL)isDemoItem { return _demoItem; }

- (BOOL)isFavorite {
    if (!_gameID) return NO;
    NSDictionary *fav = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"favorites_by_gameid"] ?: @{};
    return [fav[_gameID] boolValue];
}

- (void)setFavorite:(BOOL)favorite {
    if (!_gameID) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *fav = [[d dictionaryForKey:@"favorites_by_gameid"] mutableCopy];
    if (!fav) fav = [NSMutableDictionary dictionary];
    fav[_gameID] = @(favorite);
    [d setObject:fav forKey:@"favorites_by_gameid"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FavoritesChanged" object:nil userInfo:@{ @"gameID": _gameID }];
}


#ifdef DEBUG

#pragma mark - Screenshot-mode demo items

/// Renders a procedural 400x600 cover: a hue-derived vertical gradient, a few
/// deterministic geometric accents, the title, and a platform strip. Entirely
/// synthetic — nothing copyrighted, nothing loaded from disk.
static UIImage *DOLDemoCoverImage(NSString *title, NSString *platformLabel, CGFloat hue) {
    const CGSize size = CGSizeMake(400, 600);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = YES;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];

    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;

        // Background gradient: deep, saturated top -> near-black bottom.
        UIColor *top = [UIColor colorWithHue:hue saturation:0.72 brightness:0.62 alpha:1.0];
        UIColor *bottom = [UIColor colorWithHue:fmod(hue + 0.08, 1.0) saturation:0.85 brightness:0.14 alpha:1.0];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(__bridge id)top.CGColor, (__bridge id)bottom.CGColor];
        CGFloat locs[2] = {0.0, 1.0};
        CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locs);
        CGContextDrawLinearGradient(c, grad, CGPointZero, CGPointMake(0, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);

        // Deterministic accents: concentric arcs + a diagonal band. The seed is
        // the hue, so a given title always renders identically.
        const NSUInteger seed = (NSUInteger)(hue * 997.0);
        CGContextSaveGState(c);
        CGContextSetBlendMode(c, kCGBlendModeScreen);
        for (int i = 0; i < 4; i++) {
            CGFloat rad = 90.0 + i * 62.0 + (seed % 17);
            CGFloat cx = 60.0 + (seed % 5) * 34.0;
            CGFloat cy = 190.0 + (seed % 7) * 12.0;
            [[UIColor colorWithHue:fmod(hue + 0.5, 1.0) saturation:0.5 brightness:0.30 alpha:0.34] setStroke];
            CGContextSetLineWidth(c, 10.0);
            CGContextAddArc(c, cx, cy, rad, 0, M_PI * 2, 0);
            CGContextStrokePath(c);
        }
        CGContextRestoreGState(c);

        CGContextSaveGState(c);
        CGContextSetBlendMode(c, kCGBlendModeOverlay);
        [[UIColor colorWithWhite:1.0 alpha:0.16] setFill];
        CGContextMoveToPoint(c, 0, size.height * 0.56);
        CGContextAddLineToPoint(c, size.width, size.height * 0.40);
        CGContextAddLineToPoint(c, size.width, size.height * 0.50);
        CGContextAddLineToPoint(c, 0, size.height * 0.66);
        CGContextClosePath(c);
        CGContextFillPath(c);
        CGContextRestoreGState(c);

        // Bottom scrim so the title always reads.
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        NSArray *scrim = @[(__bridge id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
                           (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.86].CGColor];
        CGFloat locs2[2] = {0.0, 1.0};
        CGGradientRef g2 = CGGradientCreateWithColors(cs2, (__bridge CFArrayRef)scrim, locs2);
        CGContextDrawLinearGradient(c, g2, CGPointMake(0, size.height * 0.52), CGPointMake(0, size.height), 0);
        CGGradientRelease(g2);
        CGColorSpaceRelease(cs2);

        // Title.
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentLeft;
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        NSDictionary *titleAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:44 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSParagraphStyleAttributeName: ps,
        };
        [title drawInRect:CGRectMake(28, 396, size.width - 56, 150) withAttributes:titleAttrs];

        // Platform strip.
        NSDictionary *platAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.78],
            NSKernAttributeName: @(2.2),
        };
        [[platformLabel uppercaseString] drawAtPoint:CGPointMake(28, 552) withAttributes:platAttrs];
    }];
}

- (instancetype)initWithDemoTitle:(NSString *)title
                           gameID:(NSString *)gameID
                         platform:(NSInteger)platform
                            maker:(NSString *)maker
                      countryName:(NSString *)countryName
                         fileSize:(NSUInteger)fileSize
                        accentHue:(CGFloat)accentHue {
    self = [super init];
    if (!self) return nil;

    _demoItem = YES;
    _wrapper = nil;  // No GameFile backs a demo item — never boot one.
    _title = [title copy];
    _gameID = [gameID copy];
    _platform = platform;
    _makerLong = [maker copy];
    _countryName = [countryName copy];
    _fileSize = fileSize;
    // A path under a directory that does not exist, so any accidental boot
    // fails cleanly with "file not found" rather than touching real content.
    _filePath = [NSString stringWithFormat:@"/dev/null/icube-screenshot-demo/%@.rvz", gameID];
    _id = _filePath;
    _isNKit = NO;
    _discNumber = 0;
    _revision = 0;
    _apploaderDateString = @"2024/01/09";
    // Real WAD title IDs are 16 hex digits: an 8-digit type prefix plus the
    // four-character title code as ASCII hex. Build the same shape so the game
    // properties screen shows a plausible ID rather than a truncated one.
    if (platform == 3) {
        NSMutableString *low = [NSMutableString stringWithCapacity:8];
        for (NSUInteger i = 0; i < 4; i++) {
            unichar ch = (i < gameID.length) ? [gameID characterAtIndex:i] : (unichar)'0';
            [low appendFormat:@"%02X", (unsigned)(ch & 0x7F)];
        }
        _titleIDHex = [[NSString stringWithFormat:@"00010001%@", low] lowercaseString];
    } else {
        _titleIDHex = nil;
    }
    _gametdbID = [gameID copy];
    _bannerImage = nil;

    NSString *platformLabel;
    switch (platform) {
        case 0:  platformLabel = @"Nintendo GameCube"; break;
        case 2:  platformLabel = @"Nintendo Wii"; break;
        case 3:  platformLabel = @"WiiWare"; break;
        default: platformLabel = @"Disc"; break;
    }
    _coverImage = DOLDemoCoverImage(_title, platformLabel, accentHue);

    return self;
}

#endif  // DEBUG

@end
