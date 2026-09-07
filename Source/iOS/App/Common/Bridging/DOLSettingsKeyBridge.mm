// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.mm

#import "DOLSettingsKeyBridge.h"
#import "DOLConfigBridge.h"

#import <Foundation/Foundation.h>

// C++ includes — needed for snapshotAllLayers/resetKeys' direct Config::Layer access
// (DOLConfigBridge's typed accessors only expose the RESOLVED value, not a per-layer one).
#include <algorithm>
#include <optional>
#include <type_traits>
#include "Common/Config/Config.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
// Full definition of `AnisotropicFilteringMode` (GraphicsSettings.h only forward-declares
// it) — needed to instantiate Layer::Get<AnisotropicFilteringMode> for the anisotropy key.
#include "VideoCommon/VideoConfig.h"
// Full definition of `PowerPC::CPUCore` (MainSettings.h only forward-declares it) — needed
// for the same reason (std::underlying_type_t requires a complete enum type).
#include "Core/PowerPC/PowerPC.h"

typedef NS_ENUM(NSInteger, DOLSettingType) {
  DOLSettingTypeBool,
  DOLSettingTypeInt,
  DOLSettingTypeFloat,
  DOLSettingTypeString,
};

typedef id _Nonnull (^DOLGetterBlock)(void);
typedef void (^DOLSetterBlock)(id value);
// Returns nil when `layer` has no explicit entry for this key.
typedef id _Nullable (^DOLLayerGetterBlock)(Config::LayerType layer);
// Deletes this key from Base / PerGame(LocalGame) / CurrentRun.
typedef void (^DOLResetBlock)(void);

// One entry per settable key.
@interface DOLSettingEntry : NSObject
@property(nonatomic) DOLSettingType type;
@property(nonatomic) BOOL hotSwappable;
@property(nonatomic, copy) DOLGetterBlock getter;
@property(nonatomic, copy) DOLSetterBlock setter;
@property(nonatomic, copy) DOLLayerGetterBlock layerGetter;
@property(nonatomic, copy) DOLResetBlock resetBlock;
@end

@implementation DOLSettingEntry
@end

@implementation DOLSettingsKeyBridge

// MARK: - Value coercion helpers

static BOOL CoerceBool(id v) {
  if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
  if ([v isKindOfClass:[NSString class]]) {
    NSString* s = [(NSString*)v lowercaseString];
    return [s isEqualToString:@"true"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
  }
  return NO;
}

static NSInteger CoerceInt(id v) {
  if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString*)v integerValue];
  return 0;
}

static float CoerceFloat(id v) {
  if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString*)v floatValue];
  return 0.0f;
}

static NSString* CoerceString(id v) {
  if ([v isKindOfClass:[NSString class]]) return v;
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v stringValue];
  return @"";
}

// MARK: - Per-layer value access (for snapshotAllLayers / resetKeys)

// Boxes a Config::Layer's raw stored value the same way the typed DOLConfigBridge
// accessors box a *resolved* one: bool -> NSNumber(BOOL), int/float -> NSNumber, any
// enum -> NSNumber of its underlying int (matching e.g. `(int)Config::Get(MAIN_CPU_CORE)`
// above), std::string -> NSString.
template <typename T>
static id BoxConfigValue(const T& v) {
  if constexpr (std::is_same_v<T, std::string>) {
    return [NSString stringWithUTF8String:v.c_str()];
  } else if constexpr (std::is_enum_v<T>) {
    return @(static_cast<int>(v));
  } else {
    return @(v);
  }
}

// Builds a per-layer getter for a specific Config::Info<T>: nil when `layer` has no
// explicit entry for this key (Layer::Get<T> falls through to std::nullopt — this is
// deliberately NOT the same as the key's default value), else the layer's raw value.
template <typename T>
static DOLLayerGetterBlock MakeLayerGetter(const Config::Info<T>& info) {
  const Config::Location location = info.GetLocation();
  return ^id _Nullable(Config::LayerType layer) {
    std::shared_ptr<Config::Layer> layerPtr = Config::GetLayer(layer);
    if (!layerPtr) return nil;
    std::optional<T> value = layerPtr->Get<T>(location);
    if (!value) return nil;
    return BoxConfigValue<T>(*value);
  };
}

// Deletes `location` from Base, PerGame (Config::LayerType::LocalGame), and CurrentRun,
// firing Config::OnConfigChanged() once iff any layer actually had the key. Location-based
// (not templated on T) because Layer::DeleteKey only needs the location, not the type —
// this lets one block implementation serve every key regardless of its Info<T>.
static DOLResetBlock MakeResetBlock(const Config::Location& location) {
  return ^{
    static constexpr Config::LayerType kResetLayers[] = {
      Config::LayerType::Base, Config::LayerType::LocalGame, Config::LayerType::CurrentRun,
    };
    bool changed = false;
    for (Config::LayerType lt : kResetLayers) {
      std::shared_ptr<Config::Layer> layerPtr = Config::GetLayer(lt);
      if (layerPtr && layerPtr->DeleteKey(location)) changed = true;
    }
    if (changed) Config::OnConfigChanged();
  };
}

// gfxEnhanceAnisotropySamples stores an exponent (0...4, `AnisotropicFilteringMode`) but
// reads/writes translate it to/from a sample count (1/2/4/8/16) — see
// DOLConfigBridge.{gfxEnhanceAnisotropySamples,setGfxEnhanceAnisotropySamples:}. A generic
// MakeLayerGetter(Config::GFX_ENHANCE_MAX_ANISOTROPY) would report the raw exponent, which
// would silently disagree with `value` (the translated sample count from `snapshotAll`'s
// getter) — so this key gets a dedicated layer getter that applies the same translation.
static int AnisotropyExponentToSamples(int exponent) { return 1 << std::clamp(exponent, 0, 4); }
static DOLLayerGetterBlock MakeAnisotropySamplesLayerGetter() {
  const Config::Location location = Config::GFX_ENHANCE_MAX_ANISOTROPY.GetLocation();
  return ^id _Nullable(Config::LayerType layer) {
    std::shared_ptr<Config::Layer> layerPtr = Config::GetLayer(layer);
    if (!layerPtr) return nil;
    std::optional<AnisotropicFilteringMode> raw = layerPtr->Get<AnisotropicFilteringMode>(location);
    if (!raw) return nil;
    return @(AnisotropyExponentToSamples(static_cast<int>(*raw)));
  };
}

// MARK: - Key table

// The table is the single source of truth for which settings the debug API
// can read/write and how each is dispatched. To add a key, add one entry.
//
// hotSwappable classification rationale:
//  - Renderer backend, EFB internal-resolution scale, MMU, CPU core, fastmem,
//    RAM/MEM overrides, accurate CPU cache, dual-core (CPU thread), DSP thread,
//    backend multithreading, and shader-cache toggles are read at boot /
//    backend-init time. Changing them mid-run is a no-op until reboot -> tagged
//    boot-time (hotSwappable = NO). A sweep over any of these MUST reload the
//    save state / reboot the title.
//  - Per-frame render toggles and limiter/audio params (vsync, emulation speed,
//    volume, the perf-stat overlays, fog, widescreen hack, anisotropy*) are
//    consumed each frame and apply live -> hotSwappable = YES.
//    (*anisotropy is applied live by ThermalManager via resizeSurfaceNow, so
//     it's treated as hot-swappable here; if a future backend caches sampler
//     state at boot, reclassify it.)
//
// ASSUMPTION (could not verify against the running backend): the precise
// boot-time vs live behavior of each Config key is inferred from Dolphin
// semantics + how DOLConfigBridge/ThermalManager use them, not from a runtime
// probe. Joe should sanity-check the boot-time set against the actual core
// before trusting sweep deltas on borderline keys.

+ (NSDictionary<NSString*, DOLSettingEntry*>*)table {
  static NSDictionary<NSString*, DOLSettingEntry*>* table = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary<NSString*, DOLSettingEntry*>* t = [NSMutableDictionary dictionary];

    DOLSettingEntry* (^mk)(DOLSettingType, BOOL, DOLGetterBlock, DOLSetterBlock,
                           DOLLayerGetterBlock, DOLResetBlock) =
      ^DOLSettingEntry*(DOLSettingType type, BOOL hot, DOLGetterBlock g, DOLSetterBlock s,
                        DOLLayerGetterBlock lg, DOLResetBlock rb) {
        DOLSettingEntry* e = [DOLSettingEntry new];
        e.type = type;
        e.hotSwappable = hot;
        e.getter = g;
        e.setter = s;
        e.layerGetter = lg;
        e.resetBlock = rb;
        return e;
      };

    // ---- Boot-time (hotSwappable = NO) ----
    t[@"gfxBackend"] = mk(DOLSettingTypeString, NO,
      ^id{ return [DOLConfigBridge gfxBackend]; },
      ^(id v){ [DOLConfigBridge setGfxBackend:CoerceString(v)]; },
      MakeLayerGetter(Config::MAIN_GFX_BACKEND), MakeResetBlock(Config::MAIN_GFX_BACKEND.GetLocation()));

    t[@"gfxEfbScale"] = mk(DOLSettingTypeInt, NO,
      ^id{ return @([DOLConfigBridge gfxEfbScale]); },
      ^(id v){ [DOLConfigBridge setGfxEfbScale:CoerceInt(v)]; },
      MakeLayerGetter(Config::GFX_EFB_SCALE), MakeResetBlock(Config::GFX_EFB_SCALE.GetLocation()));

    t[@"mainCpuCore"] = mk(DOLSettingTypeInt, NO,
      ^id{ return @([DOLConfigBridge mainCpuCore]); },
      ^(id v){ [DOLConfigBridge setMainCpuCore:CoerceInt(v)]; },
      MakeLayerGetter(Config::MAIN_CPU_CORE), MakeResetBlock(Config::MAIN_CPU_CORE.GetLocation()));

    t[@"mainMMU"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainMMU]); },
      ^(id v){ [DOLConfigBridge setMainMMU:CoerceBool(v)]; },
      MakeLayerGetter(Config::MAIN_MMU), MakeResetBlock(Config::MAIN_MMU.GetLocation()));

    t[@"mainFastmem"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainFastmem]); },
      ^(id v){ [DOLConfigBridge setMainFastmem:CoerceBool(v)]; },
      MakeLayerGetter(Config::MAIN_FASTMEM), MakeResetBlock(Config::MAIN_FASTMEM.GetLocation()));

    t[@"mainCpuThread"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainCpuThread]); },
      ^(id v){ [DOLConfigBridge setMainCpuThread:CoerceBool(v)]; },
      MakeLayerGetter(Config::MAIN_CPU_THREAD), MakeResetBlock(Config::MAIN_CPU_THREAD.GetLocation()));

    t[@"mainDSPThread"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainDSPThread]); },
      ^(id v){ [DOLConfigBridge setMainDSPThread:CoerceBool(v)]; },
      MakeLayerGetter(Config::MAIN_DSP_THREAD), MakeResetBlock(Config::MAIN_DSP_THREAD.GetLocation()));

    t[@"mainAccurateCpuCache"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainAccurateCpuCache]); },
      ^(id v){ [DOLConfigBridge setMainAccurateCpuCache:CoerceBool(v)]; },
      MakeLayerGetter(Config::MAIN_ACCURATE_CPU_CACHE), MakeResetBlock(Config::MAIN_ACCURATE_CPU_CACHE.GetLocation()));

    t[@"mainRamOverrideEnable"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainRamOverrideEnable]); },
      ^(id v){ [DOLConfigBridge setMainRamOverrideEnable:CoerceBool(v)]; },
      MakeLayerGetter(Config::MAIN_RAM_OVERRIDE_ENABLE), MakeResetBlock(Config::MAIN_RAM_OVERRIDE_ENABLE.GetLocation()));

    t[@"gfxBackendMultithreading"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge gfxBackendMultithreading]); },
      ^(id v){ [DOLConfigBridge setGfxBackendMultithreading:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_BACKEND_MULTITHREADING), MakeResetBlock(Config::GFX_BACKEND_MULTITHREADING.GetLocation()));

    t[@"gfxShaderCache"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge gfxShaderCache]); },
      ^(id v){ [DOLConfigBridge setGfxShaderCache:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_SHADER_CACHE), MakeResetBlock(Config::GFX_SHADER_CACHE.GetLocation()));

    t[@"gfxWaitForShadersBeforeStarting"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge gfxWaitForShadersBeforeStarting]); },
      ^(id v){ [DOLConfigBridge setGfxWaitForShadersBeforeStarting:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING),
      MakeResetBlock(Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING.GetLocation()));

    // ---- Hot-swappable (hotSwappable = YES) ----
    t[@"gfxVSync"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxVSync]); },
      ^(id v){ [DOLConfigBridge setGfxVSync:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_VSYNC), MakeResetBlock(Config::GFX_VSYNC.GetLocation()));

    t[@"mainEmulationSpeedPercent"] = mk(DOLSettingTypeInt, YES,
      ^id{ return @([DOLConfigBridge mainEmulationSpeedPercent]); },
      ^(id v){ [DOLConfigBridge setMainEmulationSpeedPercent:CoerceInt(v)]; },
      MakeLayerGetter(Config::MAIN_EMULATION_SPEED), MakeResetBlock(Config::MAIN_EMULATION_SPEED.GetLocation()));

    t[@"audioVolume"] = mk(DOLSettingTypeInt, YES,
      ^id{ return @([DOLConfigBridge audioVolume]); },
      ^(id v){ [DOLConfigBridge setAudioVolume:CoerceInt(v)]; },
      MakeLayerGetter(Config::MAIN_AUDIO_VOLUME), MakeResetBlock(Config::MAIN_AUDIO_VOLUME.GetLocation()));

    t[@"gfxWidescreenHack"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxWidescreenHack]); },
      ^(id v){ [DOLConfigBridge setGfxWidescreenHack:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_WIDESCREEN_HACK), MakeResetBlock(Config::GFX_WIDESCREEN_HACK.GetLocation()));

    t[@"gfxDisableFog"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxDisableFog]); },
      ^(id v){ [DOLConfigBridge setGfxDisableFog:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_DISABLE_FOG), MakeResetBlock(Config::GFX_DISABLE_FOG.GetLocation()));

    // See MakeAnisotropySamplesLayerGetter's comment: the layer getter here reports the
    // translated sample count, matching this key's `value`/setter, not the raw exponent.
    t[@"gfxEnhanceAnisotropySamples"] = mk(DOLSettingTypeInt, YES,
      ^id{ return @([DOLConfigBridge gfxEnhanceAnisotropySamples]); },
      ^(id v){ [DOLConfigBridge setGfxEnhanceAnisotropySamples:CoerceInt(v)]; },
      MakeAnisotropySamplesLayerGetter(), MakeResetBlock(Config::GFX_ENHANCE_MAX_ANISOTROPY.GetLocation()));

    t[@"gfxShowFPS"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxShowFPS]); },
      ^(id v){ [DOLConfigBridge setGfxShowFPS:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_SHOW_FPS), MakeResetBlock(Config::GFX_SHOW_FPS.GetLocation()));

    t[@"gfxHackSkipEfbCopyToRam"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxHackSkipEfbCopyToRam]); },
      ^(id v){ [DOLConfigBridge setGfxHackSkipEfbCopyToRam:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM),
      MakeResetBlock(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM.GetLocation()));

    t[@"gfxHackSkipXfbCopyToRam"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxHackSkipXfbCopyToRam]); },
      ^(id v){ [DOLConfigBridge setGfxHackSkipXfbCopyToRam:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM),
      MakeResetBlock(Config::GFX_HACK_SKIP_XFB_COPY_TO_RAM.GetLocation()));

    t[@"gfxCpuCull"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxCpuCull]); },
      ^(id v){ [DOLConfigBridge setGfxCpuCull:CoerceBool(v)]; },
      MakeLayerGetter(Config::GFX_CPU_CULL), MakeResetBlock(Config::GFX_CPU_CULL.GetLocation()));

    table = [t copy];
  });
  return table;
}

static NSString* TypeName(DOLSettingType type) {
  switch (type) {
    case DOLSettingTypeBool: return @"bool";
    case DOLSettingTypeInt: return @"int";
    case DOLSettingTypeFloat: return @"float";
    case DOLSettingTypeString: return @"string";
  }
  return @"string";
}

// MARK: - Public API

+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)snapshotAll {
  NSDictionary<NSString*, DOLSettingEntry*>* table = [self table];
  NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* out =
    [NSMutableDictionary dictionaryWithCapacity:table.count];
  [table enumerateKeysAndObjectsUsingBlock:^(NSString* key, DOLSettingEntry* e, BOOL* stop) {
    out[key] = @{
      @"value" : e.getter(),
      @"type" : TypeName(e.type),
      @"hotSwappable" : @(e.hotSwappable),
    };
  }];
  return out;
}

+ (NSArray<NSString*>*)bootTimeKeys {
  NSDictionary<NSString*, DOLSettingEntry*>* table = [self table];
  NSMutableArray<NSString*>* keys = [NSMutableArray array];
  [table enumerateKeysAndObjectsUsingBlock:^(NSString* key, DOLSettingEntry* e, BOOL* stop) {
    if (!e.hotSwappable) [keys addObject:key];
  }];
  return [keys sortedArrayUsingSelector:@selector(compare:)];
}

+ (BOOL)isHotSwappable:(NSString*)key {
  DOLSettingEntry* e = [self table][key];
  return e != nil && e.hotSwappable;
}

+ (BOOL)isKnownKey:(NSString*)key {
  return [self table][key] != nil;
}

+ (BOOL)setKey:(NSString*)key value:(id)value {
  DOLSettingEntry* e = [self table][key];
  if (e == nil || value == nil) return NO;
  e.setter(value);
  return YES;
}

+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)snapshotAllLayers {
  NSDictionary<NSString*, DOLSettingEntry*>* table = [self table];
  NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* out =
    [NSMutableDictionary dictionaryWithCapacity:table.count];
  [table enumerateKeysAndObjectsUsingBlock:^(NSString* key, DOLSettingEntry* e, BOOL* stop) {
    id baseValue = e.layerGetter(Config::LayerType::Base);
    id perGameValue = e.layerGetter(Config::LayerType::LocalGame);
    id currentRunValue = e.layerGetter(Config::LayerType::CurrentRun);

    NSMutableDictionary<NSString*, id>* layers = [NSMutableDictionary dictionaryWithCapacity:3];
    if (baseValue != nil) layers[@"Base"] = baseValue;
    if (perGameValue != nil) layers[@"PerGame"] = perGameValue;
    if (currentRunValue != nil) layers[@"CurrentRun"] = currentRunValue;

    // Winning layer, in the same CurrentRun > PerGame(LocalGame) > Base priority as
    // Config::SEARCH_ORDER (Netplay/Movie/GlobalGame/CommandLine are outside this API's
    // three tracked layers and are never reported as the winner here).
    NSString* layerName;
    if (currentRunValue != nil) layerName = @"CurrentRun";
    else if (perGameValue != nil) layerName = @"PerGame";
    else if (baseValue != nil) layerName = @"Base";
    else layerName = @"Default";

    out[key] = @{
      @"value" : e.getter(),
      @"layer" : layerName,
      @"layers" : [layers copy],
    };
  }];
  return out;
}

+ (BOOL)resetKeys:(NSArray<NSString*>*)keys {
  NSDictionary<NSString*, DOLSettingEntry*>* table = [self table];
  NSArray<NSString*>* targetKeys = keys.count > 0 ? keys : table.allKeys;

  // Validate every key BEFORE deleting any — an unknown key anywhere in the list must
  // leave the config untouched rather than partially resetting.
  for (NSString* key in targetKeys) {
    if (table[key] == nil) return NO;
  }
  for (NSString* key in targetKeys) {
    table[key].resetBlock();
  }
  Config::Save();
  return YES;
}

@end
