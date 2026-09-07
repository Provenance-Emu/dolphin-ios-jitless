// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// String-keyed facade over the typed `DOLConfigBridge` setters/getters,
/// for the debug/benchmark HTTP API and automated settings sweeps.
///
/// `DOLConfigBridge` is typed-only (separate `+gfxEfbScale` / `+setGfxEfbScale:`
/// etc.), which a generic `set(key,value)` REST endpoint can't call directly.
/// This bridge maps a stable string key to a pair of get/set blocks that close
/// over the correctly-typed `DOLConfigBridge` call. (Blocks, not
/// `performSelector:`, because the underlying setters take primitives —
/// BOOL / NSInteger / float — which `performSelector:` cannot pass safely.)
///
/// Each key is tagged hot-swappable vs boot-time. A boot-time key only takes
/// effect on the next core boot, so an automated sweep MUST reload the save
/// state / reboot the title after changing one (otherwise the change is a
/// silent no-op and the measured data is garbage).
@interface DOLSettingsKeyBridge : NSObject

/// All known keys with their current values and metadata.
/// Returns a dictionary keyed by setting name; each value is a dictionary:
///   - `value`         : NSNumber or NSString — current value
///   - `type`          : NSString — one of "bool" / "int" / "float" / "string"
///   - `hotSwappable`  : NSNumber(BOOL) — YES if it applies live mid-run
+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)snapshotAll;

/// The set of keys that require a reboot / save-state reload to take effect.
+ (NSArray<NSString*>*)bootTimeKeys;

/// YES if `key` is known and applies live without a reboot.
+ (BOOL)isHotSwappable:(NSString*)key;

/// YES if `key` is a known/settable key.
+ (BOOL)isKnownKey:(NSString*)key;

/// Apply `value` to `key`. `value` may be an NSNumber (bool/int/float) or
/// NSString depending on the key's type; numeric strings are coerced.
/// Returns NO if the key is unknown. Note: a YES return for a boot-time key
/// means the config was written, NOT that it is live — the caller must reload.
+ (BOOL)setKey:(NSString*)key value:(id)value;

/// Snapshot every known key's resolved value plus its raw value at each of the
/// Base / GlobalGame / PerGame / CurrentRun config layers.
/// Returns a dictionary keyed by setting name; each value is a dictionary:
///   - `value`  : NSNumber or NSString — the resolved (winning) value, same as `snapshotAll`
///   - `layer`  : NSString — the winning layer: "Base" / "GlobalGame" / "PerGame" /
///                "CurrentRun" / "Default", chosen by the same relative precedence as
///                `Config::SEARCH_ORDER` (Common/Config/Enums.h) restricted to these four
///                tracked layers: CurrentRun > PerGame > GlobalGame > Base. ("Default" means
///                none of the four tracked layers has an explicit entry — the resolved value
///                above came from the key's compiled-in default, or from an untracked layer
///                such as Netplay/Movie/CommandLine.)
///   - `layers` : NSDictionary<NSString*, id> — per-layer raw value ("Base" / "GlobalGame" /
///                "PerGame" / "CurrentRun"); a layer's key is omitted entirely when that
///                layer has no explicit entry for this setting
/// "PerGame" is `Config::LayerType::LocalGame` (the per-game Local GameSettings INI layer,
/// user-editable). "GlobalGame" is `Config::LayerType::GlobalGame` (the bundled
/// `Sys/GameSettings/<id>.ini` layer, read-only — its priority sits between PerGame and Base).
+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)snapshotAllLayers;

/// Delete `keys` from the Base, PerGame (Local GameINI), and CurrentRun layers, then
/// persist to disk via `Config::Save()`, which saves every layer that has unsaved changes
/// (not just Base). An empty array resets ALL known keys.
/// Every key is validated against `+isKnownKey:` BEFORE any deletion happens, so an
/// unknown key anywhere in `keys` returns NO with nothing deleted.
+ (BOOL)resetKeys:(NSArray<NSString*>*)keys;

@end

NS_ASSUME_NONNULL_END
