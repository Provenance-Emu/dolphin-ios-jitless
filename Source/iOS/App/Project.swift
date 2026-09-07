import ProjectDescription

// The Live Activity appex is described as a faithful target (GameActivity.swift EXCLUDED,
// mirroring the original pbxproj membershipException) and gets its own scheme, BUT it is
// NOT embedded into / depended on by the app — the original pbxproj had no iCube->appex
// PBXTargetDependency or embed phase either (plan risk #9). Keeping the embed OFF means the
// `iCube (AppStore)` app scheme builds without touching the appex, so the app gate stays green.
//
// Known latent issue (pre-existing, surfaced not fixed): the appex's Live_ActivityLiveActivity.swift
// references GameActivityAttributes, defined ONLY in GameActivity.swift — which the original
// EXCLUDES from the appex. So the appex is not standalone-buildable as configured upstream.
// Set APP_EMBEDS_APPEX = true only after deciding how the appex should resolve GameActivityAttributes.
let APP_EMBEDS_APPEX = false

// MARK: - Project-level base settings
//
// These flags live in the COMMON XCBuildConfiguration block of the original
// hand-maintained pbxproj — NOT in any xcconfig. They MUST be carried explicitly
// or the C++/ObjC++ bridge files (which #include Dolphin core headers) won't
// compile. Verified against `xcodebuild -showBuildSettings` of the original
// "Release (AppStore)" config: c++20 + libc++.
let projectBase: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
    "CLANG_CXX_LIBRARY": "libc++",
    "ENABLE_BITCODE": "NO",
    "EXCLUDED_ARCHS": "i386 armv7 x86_64",
    "GCC_C_LANGUAGE_STANDARD": "gnu11",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "MTL_FAST_MATH": "NO",
]

// MARK: - Configurations
//
// Per the plan: PRODUCT_BUNDLE_IDENTIFIER and CODE_SIGN_ENTITLEMENTS must be set
// per-Configuration here (target-config level), not via Target.bundleId/entitlements,
// because Tuist's single-valued target params emit a target-level setting that
// outranks the [config=...] conditionals in BundleIdentifier.xcconfig.
let dfEnt = "DolphiniOS/DolphiniOS.entitlements"
let appStoreEnt = "DolphiniOS/iCube AppStore.entitlements"

func appCfg(_ name: String, debug: Bool, bundleId: String, entitlements: String) -> Configuration {
    let xc: Path = "Project/Config/Presets/\(name).xcconfig"
    let settings: SettingsDictionary = [
        "PRODUCT_BUNDLE_IDENTIFIER": .string(bundleId),
        "CODE_SIGN_ENTITLEMENTS": .string(entitlements),
    ]
    return debug
        ? .debug(name: .configuration(name), settings: settings, xcconfig: xc)
        : .release(name: .configuration(name), settings: settings, xcconfig: xc)
}

let appConfigs: [Configuration] = [
    appCfg("Debug (Non-Jailbroken)",         debug: true,  bundleId: "com.joemattiello.iCube-debug",             entitlements: dfEnt),
    appCfg("Debug (Jailbroken)",             debug: true,  bundleId: "com.joemattiello.iCube-debug-jb",          entitlements: dfEnt),
    appCfg("Debug (AppStore)",               debug: true,  bundleId: "com.joemattiello.iCube",                   entitlements: appStoreEnt),
    appCfg("Release (Non-Jailbroken)",       debug: false, bundleId: "com.joemattiello.iCube",                   entitlements: dfEnt),
    appCfg("Release (Beta, Non-Jailbroken)", debug: false, bundleId: "com.joemattiello.iCube-njb-patreon-beta",  entitlements: dfEnt),
    appCfg("Release (Jailbroken)",           debug: false, bundleId: "com.joemattiello.iCube-jb",                entitlements: dfEnt),
    appCfg("Release (TrollStore)",           debug: false, bundleId: "com.joemattiello.iCube-ts",                entitlements: dfEnt),
    appCfg("Release (AppStore)",             debug: false, bundleId: "com.joemattiello.iCube",                   entitlements: appStoreEnt),
    appCfg("Release (Beta, Jailbroken)",     debug: false, bundleId: "com.joemattiello.iCube-patreon-beta-jb",   entitlements: dfEnt),
    appCfg("Release (Beta, TrollStore)",     debug: false, bundleId: "com.joemattiello.iCube-ts-patreon-beta",   entitlements: dfEnt),
]

// Project-level configs: reuse the same preset xcconfigs (no per-target settings).
// The project needs the full custom config list or Tuist defaults to Debug/Release
// and the target configs won't have a matching project config to inherit from.
func projCfg(_ name: String, debug: Bool) -> Configuration {
    let xc: Path = "Project/Config/Presets/\(name).xcconfig"
    return debug
        ? .debug(name: .configuration(name), settings: [:], xcconfig: xc)
        : .release(name: .configuration(name), settings: [:], xcconfig: xc)
}

let projectConfigs: [Configuration] = [
    projCfg("Debug (Non-Jailbroken)",         debug: true),
    projCfg("Debug (Jailbroken)",             debug: true),
    projCfg("Debug (AppStore)",               debug: true),
    projCfg("Release (Non-Jailbroken)",       debug: false),
    projCfg("Release (Beta, Non-Jailbroken)", debug: false),
    projCfg("Release (Jailbroken)",           debug: false),
    projCfg("Release (TrollStore)",           debug: false),
    projCfg("Release (AppStore)",             debug: false),
    projCfg("Release (Beta, Jailbroken)",     debug: false),
    projCfg("Release (Beta, TrollStore)",     debug: false),
]

// Appex / tests: don't reuse the app's preset xcconfigs (they carry the app's
// bundle-id logic). Plain named configs so scheme config names line up.
func plainCfg(_ name: String, debug: Bool, settings: SettingsDictionary = [:]) -> Configuration {
    debug ? .debug(name: .configuration(name), settings: settings)
          : .release(name: .configuration(name), settings: settings)
}

// Same 10 config names/debug-ness as the project, no preset xcconfig.
let secondaryConfigs: [Configuration] = [
    plainCfg("Debug (Non-Jailbroken)",         debug: true),
    plainCfg("Debug (Jailbroken)",             debug: true),
    plainCfg("Debug (AppStore)",               debug: true),
    plainCfg("Release (Non-Jailbroken)",       debug: false),
    plainCfg("Release (Beta, Non-Jailbroken)", debug: false),
    plainCfg("Release (Jailbroken)",           debug: false),
    plainCfg("Release (TrollStore)",           debug: false),
    plainCfg("Release (AppStore)",             debug: false),
    plainCfg("Release (Beta, Jailbroken)",     debug: false),
    plainCfg("Release (Beta, TrollStore)",     debug: false),
]

// MARK: - Scripts (pre-compile; core build MUST precede Sources)

let preScripts: [TargetScript] = [
    .pre(
        path: "Project/Scripts/SetUpPython.sh",
        name: "Setup Python",
        basedOnDependencyAnalysis: false
    ),
    .pre(
        script: """
        set -euo pipefail
        SCRIPT="$PROJECT_DIR/../../../BuildiOSXCFramework.py"
        case "${PLATFORM_NAME}" in
          iphoneos)          platform="OS64" ;;
          iphonesimulator)   platform="SIMULATORARM64" ;;
          appletvos)         platform="TVOS" ;;
          appletvsimulator)  platform="SIMULATOR_TVOS" ;;
          macosx)
            if [[ "${SUPPORTS_MACCATALYST:-}" == "YES" || "${EFFECTIVE_PLATFORM_NAME:-}" == "-maccatalyst" ]]; then
              platform="MAC_CATALYST"
            else
              echo "Error: macOS (non-Catalyst) is not supported by this script."; exit 1
            fi ;;
          *) echo "Error: Unsupported PLATFORM_NAME: ${PLATFORM_NAME}"; exit 1 ;;
        esac
        echo "Building PVlibDolphin for platform: ${platform} (CONFIGURATION=${CONFIGURATION})"
        exec /usr/bin/python3 "${SCRIPT}" -p "${platform}" -v
        """,
        name: "Build Dolphin Core",
        outputPaths: [
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-ios-sim.framework",
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-ios.framework",
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-tvos.framework",
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-tvos-sim.framework",
        ],
        basedOnDependencyAnalysis: false
    ),
    .pre(
        path: "Project/Scripts/UpdateStoryboardStrings.sh",
        name: "Update Storyboard Strings",
        basedOnDependencyAnalysis: false
    ),
    .pre(
        script: #""$PROJECT_DIR/venv/bin/python3" "$PROJECT_DIR/Project/Scripts/UpdateCoreStrings.py" "$PROJECT_DIR/../../../Languages/po/" "$PROJECT_DIR/Common/UI/Localization""#,
        name: "Update Core Strings",
        inputPaths: ["$(PROJECT_DIR)/../../../Languages/po/en.po"],
        outputPaths: ["$(DERIVED_FILE_DIR)/UpdateCoreStrings_dummy.txt"]
    ),
    .pre(
        script: #""$PROJECT_DIR/venv/bin/python3" "$PROJECT_DIR/Project/Scripts/TransferCoreStringsToStoryboard.py" "$PROJECT_DIR/DolphiniOS" "$PROJECT_DIR/Common/UI/Localization/""#,
        name: "Transfer Core Strings to Storyboard Strings",
        basedOnDependencyAnalysis: false
    ),
]

// MARK: - Sentry dSYM upload (post-compile)
//
// Replicates the "Upload Debug Symbols to Sentry" run-script phase the Sentry installer added to
// the gitignored iCube.xcodeproj. sentry-cli auto-discovers the gitignored Source/iOS/App/.sentryclirc
// (which holds the auth token) from the working dir at build time — the token never lives here.
// SENTRY_ORG/SENTRY_PROJECT are inline as the installer wrote them. The `if which sentry-cli` guard
// makes it a no-op (warning only) when sentry-cli isn't installed or upload fails, so it never
// breaks a build (e.g. CI without sentry-cli or network).
let uploadDsymScript: TargetScript = .post(
    script: """
    # This script is responsible for uploading debug symbols and source context for Sentry.
    if [[ "$(uname -m)" == arm64 ]]; then
      export PATH="/opt/homebrew/bin:$PATH"
    fi

    if which sentry-cli >/dev/null; then
      export SENTRY_ORG=provenance-emu
      export SENTRY_PROJECT=icube
      ERROR=$(sentry-cli debug-files upload --include-sources "$DWARF_DSYM_FOLDER_PATH" 2>&1 >/dev/null)
      if [ ! $? -eq 0 ]; then
        echo "warning: sentry-cli - $ERROR"
      fi
    else
      echo "warning: sentry-cli not installed, download from https://github.com/getsentry/sentry-cli/releases"
    fi
    """,
    name: "Upload Debug Symbols to Sentry",
    inputPaths: [
        "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}",
    ],
    basedOnDependencyAnalysis: false
)

// MARK: - iCube app target

let iCube = Target.target(
    name: "iCube",
    destinations: [.iPhone, .iPad, .appleTv, .macWithiPadDesign, .macCatalyst, .appleVisionWithiPadDesign],
    product: .app,
    bundleId: "com.joemattiello.iCube", // placeholder; real per-config ids set in appConfigs
    deploymentTargets: .multiplatform(iOS: "17.0", tvOS: "17.0"),
    infoPlist: .file(path: "DolphiniOS/Info.plist"),
    sources: [
        // The legacy ObjC/UIKit settings view controllers under Common/UI/Settings/ and
        // DolphiniOS/UI/Settings/ are the iOS-only settings UI. They use UIKit APIs that are
        // unavailable on tvOS (UISlider, UISwitch, UIStepper, UITableViewStyleInsetGrouped, touch
        // APIs). The live tvOS settings UI is SwiftUI (SettingsRootView.swift / TVRootView). These
        // ObjC sources are not used on tvOS, so exclude the ObjC sources (*.m/*.mm) from the tvOS
        // build and re-add them iOS/Catalyst-only. We keep the *.swift and *.h files unconditional:
        // the SwiftUI settings views live under these dirs, and the headers (e.g.
        // MappingRootViewController.h, which declares DOLMappingType used by the programmatic Swift
        // MappingRootViewController in ButtonMappingView.swift) must stay on the bridging header path.
        .glob("DolphiniOS/**/*.{swift,h}"),
        .glob(
            "DolphiniOS/**/*.{m,mm}",
            excluding: ["DolphiniOS/UI/Settings/**/*.{m,mm}"]
        ),
        .glob(
            "DolphiniOS/UI/Settings/**/*.{m,mm}",
            compilationCondition: .when([.ios, .catalyst])
        ),
        // NOTE: GameActivity.swift (Common/Swift/Activity) defines GameActivityManager, used by
        // the app (ControllerExtensions, EmulationScreen, PauseMenuView, PauseGestureTracker).
        // In the original pbxproj it is a membershipEXCEPTION on the appex's "Activity" synchronized
        // folder — i.e. EXCLUDED from the appex, kept in the app. So it stays in the app glob.
        .glob("Common/**/*.{swift,h}"),
        // PGOFlush.c (the iCube PGO profile-flush shim) is the only plain C source in the app.
        // The {m,mm} globs below don't match *.c, so include it explicitly. Unconditional: the
        // shim must build on both iOS and tvOS (its weak __llvm_profile_* refs no-op on a
        // non-instrumented shipping core, so this never changes normal-build behavior).
        .glob("Common/**/*.c"),
        .glob(
            "Common/**/*.{m,mm}",
            excluding: ["Common/UI/Settings/**/*.{m,mm}"]
        ),
        .glob(
            "Common/UI/Settings/**/*.{m,mm}",
            compilationCondition: .when([.ios, .catalyst])
        ),
    ],
    resources: [
        "DolphiniOS/Assets.xcassets",
        "Common/Assets.xcassets",
        "Common/DolphinAssets.xcassets",
        // These are iOS UIKit xibs/storyboards (touch controller, boot notices, JIT-wait) with an
        // iPhone/iPad-only targeted device family — ibtool rejects them for tvOS ("iOS xibs do not
        // support target device type tv"). tvOS uses the SwiftUI UI, not these, so include them on
        // iOS/Catalyst only and keep them out of the tvOS build.
        .glob(pattern: "DolphiniOS/**/*.storyboard", inclusionCondition: .when([.ios, .catalyst])),
        .glob(pattern: "DolphiniOS/**/*.xib", inclusionCondition: .when([.ios, .catalyst])),
        "DolphiniOS/**/*.strings",
        "DolphiniOS/Base.lproj/**",
        "DolphiniOS/en.lproj/**",
        "DolphiniOS/ja.lproj/**",
        "Project/Assets/DefaultPreferences.plist",
        "Project/Assets/Logger.ini",
        "Project/Assets/cacert.pem",
        // StikDebug JIT broker script handed off at runtime via the stikdebug:// URL scheme
        // (StikDebugLauncher.swift). Bundled flat so Bundle.main.url(forResource:"icube") resolves.
        "Project/Assets/icube.js",
        .folderReference(path: "../../../Data/Sys"),
        .folderReference(path: "Project/Assets/compiled_shaders"),
    ],
    entitlements: nil, // per-config via CODE_SIGN_ENTITLEMENTS in appConfigs
    scripts: preScripts + [uploadDsymScript],
    dependencies: [
        .xcframework(path: "../../../build/xcframework/PVlibDolphin.xcframework"),
        // MoltenVK (Vulkan-on-Metal ICD) is iOS-only: the prebuilt xcframework has only
        // ios device/simulator slices (no tvOS slice), and the core never builds/links it
        // (CMake gates MoltenVK to APPLE AND NOT IOS, and tvOS is IOS=TRUE in the toolchain).
        // The Vulkan backend dlopen's MoltenVK.framework at runtime — no direct link — so
        // excluding it from tvOS just makes the (unused) Vulkan backend unavailable there;
        // tvOS renders via native Metal. Linking it on tvOS makes Xcode look for a nonexistent
        // tvOS slice and fail. Condition keeps iOS linking byte-for-byte unchanged.
        .xcframework(path: "../../../Externals/MoltenVK-iOS/MoltenVK.xcframework", condition: .when([.ios])),
        .package(product: "PVWebServer"),
        .package(product: "Zip"),
        .package(product: "PLzmaSDK"),
        .package(product: "SWCompression"),
        .package(product: "UICollectionViewLeftAlignedLayout"),
        .package(product: "AltKit"),
        .package(product: "Sentry"),
        .sdk(name: "ReplayKit", type: .framework),
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "UniformTypeIdentifiers", type: .framework),
        .sdk(name: "MetalKit", type: .framework),
        .sdk(name: "GameController", type: .framework),
        // CoreMotion is iOS-only: the framework does not exist in the tvOS SDK (ld fails with
        // "framework 'CoreMotion' not found"). All source uses are already #if canImport(CoreMotion)
        // gated, so nothing references it on tvOS — only this link line pulls it in. Gate to
        // iOS/Catalyst to match the MoltenVK pattern above and keep iOS linking unchanged.
        .sdk(name: "CoreMotion", type: .framework, condition: .when([.ios, .catalyst])),
        // appex embed intentionally OFF (faithful to original; see APP_EMBEDS_APPEX note above).
    ] + (APP_EMBEDS_APPEX ? [.target(name: "LiveActivityExtension")] : []),
    settings: .settings(
        base: projectBase.merging([
            "ARCHS": "arm64",
            "EXCLUDED_ARCHS": "x86_64",
            "ONLY_ACTIVE_ARCH": "NO",
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "NO",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_FILE": "DolphiniOS/Info.plist",
            "INFOPLIST_FILE[sdk=appletv*]": "DolphiniOS/Info-TV.plist",
            "INFOPLIST_KEY_GCSupportsControllerUserInteraction": "YES",
            "INFOPLIST_KEY_GCSupportsGameMode": "YES",
            "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.entertainment",
            "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace": "YES",
            "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "iCube uses your local network to discover and connect to DSU controllers and devices.",
            "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": "Used to save gameplay clips you record with Instant Replay.",
            "INFOPLIST_KEY_NSSupportsLiveActivities": "YES",
            "INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates": "YES",
            "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
            "INFOPLIST_KEY_UILaunchStoryboardName": "LaunchScreen",
            // Main.storyboard deleted (dead — AppDelegate sets config.storyboard = nil and roots
            // SwiftUI via UIHostingController). Empty on all platforms; tvOS already shipped empty.
            "INFOPLIST_KEY_UIMainStoryboardFile": "",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            // The bridging header imports basename-only headers (AudioSessionManager.h etc.)
            // scattered across Common/ and DolphiniOS/ subdirs. The original pbxproj resolved
            // these via the target header map built from synchronized-folder .h membership;
            // Tuist's source globs don't populate that map identically, so add the subtrees to
            // the quote-include search path. $(inherited) is load-bearing: it keeps
            // Common.xcconfig's Core/** + Library paths (target base outranks the xcconfig).
            "USER_HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/Common/**", "$(SRCROOT)/DolphiniOS/**"],
            "MARKETING_VERSION": "1.0.0",
            "CURRENT_PROJECT_VERSION": "13",
            // Literal name (not $(TARGET_NAME)): Tuist resolves PRODUCT_NAME at generate time;
            // scheme-specific home-screen labels stay on DOL_APP_DISPLAY_NAME in preset xcconfigs.
            "PRODUCT_NAME": "iCube",
            "SUPPORTS_MACCATALYST": "YES",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "YES",
            "SWIFT_VERSION": "5.0",
            "SWIFT_OBJC_INTEROP_MODE": "objc",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2,3,6",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "$(DOL_APP_ICON_ASSET_NAME)",
            "ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletv*]": "$(DOL_APP_ICON_ASSET_NAME_TV)",
            // Tuist's .recommended defaults inject the MORE-SPECIFIC appletvos*/appletvsimulator* keys
            // pointing at the stock "App Icon & Top Shelf Image" name, which outranks the appletv*
            // override above and makes actool look for an asset that doesn't exist (ours is
            // "tvOS Icons") — App Store then rejects with missing CFBundlePrimaryIcon + Top Shelf Image
            // Wide. Pin the specific keys to our real brandassets so every tvOS SDK variant agrees.
            "ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletvos*]": "$(DOL_APP_ICON_ASSET_NAME_TV)",
            "ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletvsimulator*]": "$(DOL_APP_ICON_ASSET_NAME_TV)",
            "LLVM_LTO[config=Release (AppStore)]": "YES_THIN",
            "LLVM_LTO[config=Release (Beta, Jailbroken)]": "YES_THIN",
            "LLVM_LTO[config=Release (Beta, Non-Jailbroken)]": "YES_THIN",
            "LLVM_LTO[config=Release (Beta, TrollStore)]": "YES_THIN",
            "LLVM_LTO[config=Release (Jailbroken)]": "YES_THIN",
            "LLVM_LTO[config=Release (Non-Jailbroken)]": "YES_THIN",
            "LLVM_LTO[config=Release (TrollStore)]": "YES_THIN",

        ]),
        configurations: appConfigs,
        defaultSettings: .recommended(excluding: ["ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME"])
    )
)

// MARK: - Live Activity appex

let liveActivity = Target.target(
    name: "LiveActivityExtension",
    destinations: [.iPhone, .iPad, .macCatalyst],
    product: .appExtension,
    bundleId: "com.joemattiello.iCube.Live-Activity",
    deploymentTargets: .multiplatform(iOS: "18.2"),
    infoPlist: .file(path: "Live Activity/Info.plist"),
    sources: [
        .glob("Live Activity/**/*.swift"),
        // NOTE: the original pbxproj EXCLUDES GameActivity.swift from the appex (it's a
        // membershipException), yet Live_ActivityLiveActivity.swift references
        // GameActivityAttributes which is defined there. TODO when re-enabling the appex:
        // confirm how the appex resolves GameActivityAttributes (shared file vs. duplicate) —
        // it may need GameActivity.swift here after all, with the app+appex both compiling it.
    ],
    resources: ["Live Activity/LiveActivityAssets.xcassets"],
    entitlements: .file(path: "Live ActivityExtension.entitlements"),
    dependencies: [
        .sdk(name: "SwiftUI", type: .framework),
        .sdk(name: "WidgetKit", type: .framework),
    ],
    settings: .settings(
        base: [
            "SKIP_INSTALL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "SWIFT_VERSION": "5.0",
            "DEVELOPMENT_TEAM": "S32Z3HMYVQ",
            "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME": "WidgetBackground",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "INFOPLIST_FILE": "Live Activity/Info.plist",
            // The appex must NOT inherit the app's ObjC bridging header (it pulls in
            // AudioSessionManager.h and the whole Dolphin core header tree). GameActivity.swift
            // only needs Foundation + ActivityKit.
            "SWIFT_OBJC_BRIDGING_HEADER": "",
        ],
        configurations: secondaryConfigs
    )
)

// MARK: - Unit tests

let iCubeTests = Target.target(
    name: "iCubeTests",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "com.joemattiello.iCubeTests",
    deploymentTargets: .multiplatform(iOS: "17.0"),
    infoPlist: .default,
    sources: ["DolphiniOSTests/**/*.swift"],
    dependencies: [.target(name: "iCube")],
    settings: .settings(
        base: [
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
            "SWIFT_VERSION": "5.0",
            // The test target uses `@testable import iCube` and doesn't need its own
            // ObjC bridging header, so clear it (see the identical fix on the
            // LiveActivityExtension target above). That alone isn't sufficient though:
            // with SWIFT_ENABLE_EXPLICIT_MODULES, `@testable import iCube` makes the
            // Swift explicit-module dependency scanner re-resolve iCube's OWN bridging
            // header (Common/Swift/BridgingHeader.h) using iCubeTests' Clang search
            // paths, not iCube's — so iCubeTests also needs iCube's
            // USER_HEADER_SEARCH_PATHS (quote-includes like "AudioSessionManager.h"
            // resolve via Common/** and DolphiniOS/**) or the scan fails with
            // "'AudioSessionManager.h' file not found" even though iCubeTests itself
            // never imports that header directly.
            "SWIFT_OBJC_BRIDGING_HEADER": "",
            "USER_HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/Common/**", "$(SRCROOT)/DolphiniOS/**"],
        ],
        configurations: secondaryConfigs
    )
)

// MARK: - Schemes

let appStoreEnvVars: [String: EnvironmentVariable] = [ : ]

let schemes: [Scheme] = [
    .scheme(
        name: "iCube (AppStore)",
        shared: true,
        buildAction: .buildAction(targets: ["iCube"]),
        testAction: .targets(["iCubeTests"], configuration: .configuration("Debug (AppStore)")),
        runAction: .runAction(
            configuration: .configuration("Release (AppStore)"),
            arguments: .arguments(environmentVariables: appStoreEnvVars)
        ),
        archiveAction: .archiveAction(configuration: .configuration("Release (AppStore)")),
        profileAction: .profileAction(configuration: .configuration("Release (AppStore)")),
        analyzeAction: .analyzeAction(configuration: .configuration("Debug (AppStore)"))
    ),
    .scheme(
        name: "iCube (NJB)",
        shared: true,
        buildAction: .buildAction(targets: ["iCube"]),
        testAction: .targets(["iCubeTests"], configuration: .configuration("Debug (Non-Jailbroken)")),
        runAction: .runAction(configuration: .configuration("Release (Non-Jailbroken)")),
        archiveAction: .archiveAction(configuration: .configuration("Release (Non-Jailbroken)")),
        profileAction: .profileAction(configuration: .configuration("Release (Non-Jailbroken)")),
        analyzeAction: .analyzeAction(configuration: .configuration("Debug (Non-Jailbroken)"))
    ),
    .scheme(
        name: "iCube (JB)",
        shared: true,
        buildAction: .buildAction(targets: ["iCube"]),
        testAction: .targets(["iCubeTests"], configuration: .configuration("Debug (Jailbroken)")),
        runAction: .runAction(configuration: .configuration("Release (Jailbroken)")),
        archiveAction: .archiveAction(configuration: .configuration("Release (Jailbroken)")),
        profileAction: .profileAction(configuration: .configuration("Release (Jailbroken)")),
        analyzeAction: .analyzeAction(configuration: .configuration("Debug (Jailbroken)"))
    ),
    .scheme(
        name: "Live ActivityExtension",
        shared: true,
        buildAction: .buildAction(targets: ["LiveActivityExtension"]),
        runAction: .runAction(configuration: .configuration("Release (Non-Jailbroken)")),
        archiveAction: .archiveAction(configuration: .configuration("Release (Non-Jailbroken)"))
    ),
]

// MARK: - Project

let project = Project(
    name: "iCube",
    options: .options(
        defaultKnownRegions: ["en", "Base", "ja"],
        developmentRegion: "en",
        // The original project does not use Tuist's synthesized resource/string accessors;
        // its .strings files produced invalid Swift (TuistStrings+ICube.swift syntax error).
        disableBundleAccessors: true,
        disableSynthesizedResourceAccessors: true
    ),
    packages: [
        .local(path: "../PVWebServer"),
        .remote(url: "https://github.com/marmelroy/Zip.git", requirement: .upToNextMajor(from: "2.1.2")),
        .remote(url: "https://github.com/OlehKulykov/PLzmaSDK.git", requirement: .upToNextMajor(from: "1.6.1")),
        .remote(url: "https://github.com/tsolomko/SWCompression.git", requirement: .upToNextMajor(from: "4.9.0")),
        .remote(url: "https://github.com/OatmealDome/UICollectionViewLeftAlignedLayout", requirement: .upToNextMajor(from: "1.0.0")),
        .remote(url: "https://github.com/rileytestut/AltKit.git", requirement: .upToNextMajor(from: "0.0.2")),
        // Sentry crash/error reporting (added via the Sentry installer; replicated here so it
        // survives `tuist generate`, which regenerates the gitignored iCube.xcodeproj). Pinned to
        // the resolved major; Package.resolved had 8.58.3 (installer floor was 8.0.0).
        .remote(url: "https://github.com/getsentry/sentry-cocoa", requirement: .upToNextMajor(from: "9.16.1")),
    ],
    settings: .settings(
        base: projectBase,
        configurations: projectConfigs,
        defaultSettings: .recommended
    ),
    targets: [iCube, liveActivity, iCubeTests],
    schemes: schemes
)
