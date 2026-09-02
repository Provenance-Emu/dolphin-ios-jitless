// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "JitManager+Debugger.h"

#import <math.h>
#import <sys/utsname.h>
#import <unistd.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
#define CS_GET_TASK_ALLOW 0x00000004

extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

@implementation JitManager (Debugger)

- (bool)checkIfProcessIsDebugged {
  int flags = 0;
  // NOTE: sizeof(flags) != 0 was a parenthesis bug — evaluated to 1, not 4,
  // causing csops to read only 1 byte and leave the rest uninitialized.
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
    return false;
  }

  return (flags & CS_DEBUGGED) != 0;
}

// True when the process carries the get-task-allow entitlement, i.e. a debugger
// (Xcode, AltStore/SideStore, StikDebug) can attach and JIT can ever be enabled.
// This is the universal JIT precondition on iOS: it is present on every
// debuggable distribution (sideload, jailbreak, TrollStore, dev, and the App
// Store scheme when launched from Xcode) and stripped from App Store / TestFlight
// builds, which are jitless. Used to drive jitSupported at runtime so JIT UI
// shows exactly when JIT is achievable, regardless of build configuration.
- (bool)checkIfProcessIsJitCapable {
  int flags = 0;
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
    return false;
  }

  return (flags & CS_GET_TASK_ALLOW) != 0;
}

#pragma mark - TXM detection

// TXM detection runs two independent probes and ORs them (see checkIfDeviceUsesTXM).
//
// Why OR, and why a false negative is the dangerous direction: when this reports
// false on a device that really does use TXM, JitManager leaves acquiredJit true
// and EmulationCoordinator takes the "non-TXM device, dual-mapping works fine"
// branch (LuckNoTXM + AllocateExecutableMemoryRegion) — which is precisely what
// TXM blocks, so the core crashes or silently fails to JIT. The safety warning
// never fires and the StikDebug affordance stays hidden in Settings.
//
// A false positive merely drops to Cached Interpreter, which is safe. So any
// positive signal from either probe wins.

// --- Probe 1: hardware model + OS version -----------------------------------
// Adapted from StikDebug's current implementation, by way of DolphiniOS.
// https://github.com/StephenDev0/StikDebug/blob/ef5e962b/StikDebug/Support/ProcessInfo%2BTXM.swift
//
// Needs no filesystem access, so unlike the preboot probe it keeps working
// inside the app sandbox.

// Scale for packing "major,minor" into one comparable integer. 10000 leaves ample
// headroom for the minor component, which has never exceeded two digits.
static const NSInteger kDeviceVersionMajorScale = 10000;

#if !TARGET_OS_TV
// First model that uses TXM, encoded with kDeviceVersionMajorScale:
// iPhone14,2 (iPhone 13 Pro, A15) and iPad14,5 (iPad Pro M2).
// Unused on tvOS, where txmByDeviceModel returns early.
static const NSInteger kFirstTXMDeviceVersion = 14 * kDeviceVersionMajorScale + 2;
static const NSInteger kFirstIPadTXMDeviceVersion = 14 * kDeviceVersionMajorScale + 5;
#endif

- (NSString*)hardwareIdentifier {
  struct utsname systemInfo;
  uname(&systemInfo);

  return [NSString stringWithCString:systemInfo.machine
                            encoding:NSUTF8StringEncoding] ?: @"";
}

// "iPhone14,2" -> 140002, i.e. major * kDeviceVersionMajorScale + minor, so the
// pair compares like a tuple: major first, then minor.
//
// Deliberately NOT the decimal form (major + minor / 10^digits) used upstream in
// StikDebug and DolphiniOS. That scales the minor by its own digit count, so
// "14,10" becomes 14.10 == 14.1 and sorts BELOW "14,2" == 14.2. Real devices hit
// this: iPad14,10 and iPad14,11 (iPad Air M2, 2024) would read as 14.1 < the 14.5
// iPad cutoff and be reported as non-TXM — a false negative, which is the
// dangerous direction (see the note above checkIfDeviceUsesTXM).
- (nullable NSNumber*)deviceVersionFromIdentifier:(NSString*)identifier
                                          pattern:(NSString*)pattern {
  NSError* error = nil;
  NSRegularExpression* regex =
      [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
  if (!regex) {
    return nil;
  }

  NSTextCheckingResult* match =
      [regex firstMatchInString:identifier options:0 range:NSMakeRange(0, identifier.length)];
  if (!match || match.numberOfRanges < 3) {
    return nil;
  }

  NSRange majorRange = [match rangeAtIndex:1];
  NSRange minorRange = [match rangeAtIndex:2];
  if (majorRange.location == NSNotFound || minorRange.location == NSNotFound) {
    return nil;
  }

  NSString* majorString = [identifier substringWithRange:majorRange];
  NSString* minorString = [identifier substringWithRange:minorRange];

  return @(majorString.integerValue * kDeviceVersionMajorScale + minorString.integerValue);
}

- (nullable NSNumber*)deviceVersionFromIdentifier:(NSString*)identifier {
  NSNumber* iPhoneVersion =
      [self deviceVersionFromIdentifier:identifier pattern:@"iPhone(\\d+),(\\d+)"];
  if (iPhoneVersion) {
    return iPhoneVersion;
  }

  return [self deviceVersionFromIdentifier:identifier pattern:@"iPad(\\d+),(\\d+)"];
}

- (bool)txmByDeviceModel {
#if TARGET_OS_TV
  // The model table only covers iPhone and iPad identifiers, and on a tvOS build
  // @available(iOS N, *) is unconditionally true — which would mark every Apple TV
  // as TXM and disable JIT across tvOS. Leave tvOS to the preboot probe until the
  // Apple TV cutoff is confirmed on hardware.
  return false;
#else
  NSString* identifier = [self hardwareIdentifier];

  if (@available(iOS 27.0, *)) {
    // Every device that reaches iOS 27 uses TXM except these two iPad Pro models.
    return ![identifier isEqualToString:@"iPad8,11"] && ![identifier isEqualToString:@"iPad8,12"];
  }

  if (@available(iOS 26.0, *)) {
    NSNumber* deviceVersion = [self deviceVersionFromIdentifier:identifier];
    if (!deviceVersion) {
      return false;
    }

    if ([identifier hasPrefix:@"iPad"]) {
      return deviceVersion.integerValue >= kFirstIPadTXMDeviceVersion;
    }

    return deviceVersion.integerValue >= kFirstTXMDeviceVersion;
  }

  return false;
#endif
}

// --- Probe 2: preboot firmware image ----------------------------------------
// Looks for the TXM firmware image the device booted with. Kept as a
// corroborating signal: it is authoritative when it can read those directories,
// but it returns false whenever the directory listing fails — including, most
// likely, under the app sandbox — which is why it can no longer stand alone.

- (nullable NSString*)filePathAtPath:(NSString*)path withLength:(NSUInteger)length {
    NSError *error = nil;
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error];
    if (!items) { return nil; }

    for (NSString *entry in items) {
        if (entry.length == length) {
            return [path stringByAppendingPathComponent:entry];
        }
    }
    return nil;
}

- (bool)txmByPrebootProbe {
    // Primary: /System/Volumes/Preboot/<36>/boot/<96>/usr/.../Ap,TrustedExecutionMonitor.img4
    NSString* bootUUID = [self filePathAtPath:@"/System/Volumes/Preboot" withLength:36];
    if (bootUUID) {
        NSString* bootDir = [bootUUID stringByAppendingPathComponent:@"boot"];
        NSString* ninetySixCharPath = [self filePathAtPath:bootDir withLength:96];
        if (ninetySixCharPath) {
            NSString* img = [ninetySixCharPath stringByAppendingPathComponent:
                             @"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
            return access(img.fileSystemRepresentation, F_OK) == 0;
        }
    }

    // Fallback: /private/preboot/<96>/usr/.../Ap,TrustedExecutionMonitor.img4
    NSString* fallback = [self filePathAtPath:@"/private/preboot" withLength:96];
    if (fallback) {
        NSString* img = [fallback stringByAppendingPathComponent:
                         @"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        return access(img.fileSystemRepresentation, F_OK) == 0;
    }

    return false;
}

- (bool)checkIfDeviceUsesTXM {
    const bool byModel = [self txmByDeviceModel];
    const bool byProbe = [self txmByPrebootProbe];

    NSLog(@"[JitManager] TXM detection: model=%d preboot=%d device=%@",
          (int)byModel, (int)byProbe, [self hardwareIdentifier]);

    return byModel || byProbe;
}

@end
