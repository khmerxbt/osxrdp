
#include "PermissionCheckUtils.h"
#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

bool PermissionCheckUtils::HasAccPermission() {
    return AXIsProcessTrustedWithOptions(nullptr) != 0 ? true : false;
}

bool PermissionCheckUtils::HasScreenRecordPermission() {
    return CGPreflightScreenCaptureAccess();
}

void PermissionCheckUtils::ShowAccPermissionRequestDialog() {
    CFDictionaryRef options = ::CFDictionaryCreate(
      kCFAllocatorDefault,
      (const void**)&kAXTrustedCheckOptionPrompt,
      (const void**)&kCFBooleanTrue,
      1,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks
    );
    
    if (options == NULL)
    {
      return;
    }
    
    AXIsProcessTrustedWithOptions(options);
    
    CFRelease(options);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

void PermissionCheckUtils::ShowScreenRecordPermissionRequestDialog() {
    void (^openSettings)(void) = ^{
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    };
    if (CGPreflightScreenCaptureAccess()) { openSettings(); return; }
    // A real ScreenCaptureKit request registers this running app with TCC.
    // Opening the pane alone cannot add an app or grant it permission.
    if (@available(macOS 12.3, *)) {
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* content, NSError* error) {
            dispatch_async(dispatch_get_main_queue(), openSettings);
        }];
    } else {
        CGRequestScreenCaptureAccess();
        openSettings();
    }
}

void PermissionCheckUtils::ResetAccPermission() {
    NSTask* task = [[NSTask alloc] init];

    [task setLaunchPath:@"/usr/bin/tccutil"];
    [task setArguments:@[@"reset", @"Accessibility", @"com.byungho.osxrdp.mainapp"]];

    @try
    {
      [task launch];
      [task waitUntilExit];
    }
    @catch (NSException* exception)
    {
      return;
    }
}

void PermissionCheckUtils::ResetScreenRecordPermission() {
    NSTask* task = [[NSTask alloc] init];

    [task setLaunchPath:@"/usr/bin/tccutil"];
    [task setArguments:@[@"reset", @"ScreenCapture", @"com.byungho.osxrdp.mainapp"]];

    @try
    {
      [task launch];
      [task waitUntilExit];
    }
    @catch (NSException* exception)
    {
      return;
    }
}

bool PermissionCheckUtils::HasAllPermissionToStartRemoteConnection() {
    return HasAccPermission() && HasScreenRecordPermission();
}
