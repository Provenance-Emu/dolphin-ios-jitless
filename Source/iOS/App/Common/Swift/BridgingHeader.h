// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioSessionManager.h"
#import "BootNoticeManager.h"
#import "PGOFlush.h"
#import "DolphinCoreService.h"
#import "EmulationCoordinator.h"
#import "FirstRunInitializationService.h"
#import "GameFileCacheManager.h"
#import "JitManager.h"
#import "JitManager+AltServer.h"
#import "JitManager+JitStreamer.h"
#import "JitManager+PTrace.h"
#import "LegacyInputConfigMigrationService.h"
#import "MainSceneCoordinator.h"
#import "UpdateNoticeViewController.h"
#import "UpdateRequiredNoticeViewController.h"
#import "FastmemManager.h"
#import "MappingRootViewController.h"

#import "EmuEventVC.h"
#import "InputOverriderBridge.h"
#import "TCManagerInterface.h"
#import "TVGameItem.h"
#import "DOLWiimoteBridge.h"
#import "VirtualMFiControllerManager.h"
#import "AudioFXBridge.h"

#if TARGET_OS_IOS
#import "DOLUIKitSwitch.h"
#endif

// SwiftUI tvOS bridges
#import "TVLibraryBridge.h"
#import "TVEmulationBridge.h"
#import "DOLConfigBridge.h"
#import "DOLDebugBridge.h"
#import "DOLPerfBridge.h"
#import "DOLSettingsKeyBridge.h"
#import "DSUServerBridge.h"
#import "DSUPingBridge.h"
#import "DOLPathsBridge.h"
#import "TVCheatsBridge.h"
#import "TVControllerMappingBridge.h"
#import "NANDImportManager.h"
#import "ImportFileManager.h"
