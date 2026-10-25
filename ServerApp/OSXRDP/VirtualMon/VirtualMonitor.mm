#include "VirtualMonitor.h"
#include "DisplayUtils.h"

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <unistd.h>
#import <ApplicationServices/ApplicationServices.h>

static const int kDisplayReconfigSettleUsec = 500 * 1000;

// A nonactivating cover keeps local content out of view without disabling
// display outputs. It deliberately does not claim to lock the macOS session.
@interface OSXRDPPrivacyPanel : NSPanel
@end
@implementation OSXRDPPrivacyPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end


// AX coordinates, like CGDisplayBounds, start at the top left. Keeping these
// separate from Cocoa's bottom-left coordinates avoids moving windows below
// the desktop when a physical display has a negative vertical origin.
static CGRect RemoteWorkArea(NSScreen* screen) {
    CGRect display = CGDisplayBounds([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
    NSRect visible = screen.visibleFrame, full = screen.frame;
    return CGRectMake(display.origin.x + visible.origin.x - full.origin.x,
        display.origin.y + NSMaxY(full) - NSMaxY(visible), visible.size.width, visible.size.height);
}
static BOOL ReadWindowFrame(AXUIElementRef window, CGRect* frame) {
    CFTypeRef position = NULL, size = NULL;
    BOOL ok = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position) == kAXErrorSuccess
        && AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &size) == kAXErrorSuccess
        && CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID()
        && AXValueGetValue((AXValueRef)position, kAXValueTypeCGPoint, &frame->origin)
        && AXValueGetValue((AXValueRef)size, kAXValueTypeCGSize, &frame->size);
    if (position) CFRelease(position);
    if (size) CFRelease(size);
    return ok && frame->size.width > 0 && frame->size.height > 0;
}
static BOOL SetWindowFrame(AXUIElementRef window, CGRect frame) {
    AXValueRef size = AXValueCreate(kAXValueTypeCGSize, &frame.size);
    AXValueRef point = AXValueCreate(kAXValueTypeCGPoint, &frame.origin);
    AXUIElementSetAttributeValue(window, kAXSizeAttribute, size);
    AXError error = AXUIElementSetAttributeValue(window, kAXPositionAttribute, point);
    CFRelease(size); CFRelease(point);
    return error == kAXErrorSuccess;
}
CGRect OSXRDPFitRemoteWindow(CGRect frame, CGRect work) {
    frame.size.width = MIN(frame.size.width, work.size.width);
    frame.size.height = MIN(frame.size.height, work.size.height);
    frame.origin.x = MAX(work.origin.x, MIN(frame.origin.x, CGRectGetMaxX(work) - frame.size.width));
    frame.origin.y = MAX(work.origin.y, MIN(frame.origin.y, CGRectGetMaxY(work) - frame.size.height));
    return frame;
}
// Retained objects let queued main-thread work finish safely after C++ teardown.
@interface OSXRDPWindowTransfer : NSObject
- (void)snapshot;
- (void)gather:(NSSet<NSNumber*>*)remoteIDs;
- (void)restore;
@end
@implementation OSXRDPWindowTransfer {
    NSMutableArray<NSMutableDictionary*>* _saved;
    NSMutableArray<NSDictionary*>* _ownSaved;
}
- (instancetype)init { if ((self = [super init])) { _saved = [NSMutableArray array]; _ownSaved = [NSMutableArray array]; } return self; }
- (NSMutableDictionary*)remember:(AXUIElementRef)window frame:(CGRect)frame {
    for (NSMutableDictionary* saved in _saved)
        if (CFEqual((__bridge CFTypeRef)saved[@"window"], window)) return saved;
    NSMutableDictionary* saved = [@{@"window": (__bridge id)window,
        @"frame": [NSValue valueWithRect:NSRectFromCGRect(frame)], @"moved": @NO} mutableCopy];
    [_saved addObject:saved];
    return saved;
}
- (void)enumerateWindows:(void(^)(AXUIElementRef, CGRect))block {
    if (!AXIsProcessTrusted()) return;
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.processIdentifier == getpid() || app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(axApp, 0.15);
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, &value) == kAXErrorSuccess
            && CFGetTypeID(value) == CFArrayGetTypeID()) {
            for (id object in (__bridge NSArray*)value) {
                AXUIElementRef window = (__bridge AXUIElementRef)object;
                AXUIElementSetMessagingTimeout(window, 0.15);
                CFTypeRef title = NULL;
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute, &title);
                BOOL isCover = title && CFGetTypeID(title) == CFStringGetTypeID()
                    && CFEqual(title, CFSTR("OSXRDP local screen privacy"));
                if (title) CFRelease(title);
                if (isCover) continue;
                CGRect frame;
                if (ReadWindowFrame(window, &frame)) block(window, frame);
            }
        }
        if (value) CFRelease(value);
        CFRelease(axApp);
    }
}
- (void)snapshot {
    [_saved removeAllObjects];
    [self enumerateWindows:^(AXUIElementRef window, CGRect frame) { [self remember:window frame:frame]; }];
}
- (void)gather:(NSSet<NSNumber*>*)remoteIDs {
    NSMutableArray<NSValue*>* destinations = [NSMutableArray array];
    for (NSScreen* screen in NSScreen.screens)
        if ([remoteIDs containsObject:screen.deviceDescription[@"NSScreenNumber"]])
            [destinations addObject:[NSValue valueWithRect:NSRectFromCGRect(RemoteWorkArea(screen))]];
    if (!destinations.count) return;
    // Our own UI must use AppKit: AX does not implement self-process windows.
    for (NSWindow* window in NSApp.windows) {
        if (!window.visible || [window isKindOfClass:OSXRDPPrivacyPanel.class]) continue;
        BOOL remote = NO;
        NSScreen* target = nil;
        for (NSScreen* screen in NSScreen.screens) {
            if (![remoteIDs containsObject:screen.deviceDescription[@"NSScreenNumber"]]) continue;
            if (!target) target = screen;
            if (NSPointInRect(NSMakePoint(NSMidX(window.frame), NSMidY(window.frame)), screen.frame)) remote = YES;
        }
        if (remote || !target) continue;
        BOOL saved = NO;
        for (NSDictionary* record in _ownSaved) if (record[@"window"] == window) saved = YES;
        if (!saved) [_ownSaved addObject:@{@"window":window, @"frame":[NSValue valueWithRect:window.frame]}];
        [window setFrame:NSRectFromCGRect(OSXRDPFitRemoteWindow(NSRectToCGRect(window.frame), NSRectToCGRect(target.visibleFrame))) display:YES];
    }
    __block int moved = 0;
    [self enumerateWindows:^(AXUIElementRef window, CGRect frame) {
        CFTypeRef minimized = NULL;
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute, &minimized);
        BOOL skip = minimized && CFEqual(minimized, kCFBooleanTrue);
        if (minimized) CFRelease(minimized);
        if (skip) return;
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        for (NSValue* destination in destinations)
            if (CGRectContainsPoint(NSRectToCGRect(destination.rectValue), center)) return;
        NSMutableDictionary* saved = [self remember:window frame:frame];
        CFTypeRef fullscreen = NULL;
        AXUIElementCopyAttributeValue(window, CFSTR("AXFullScreen"), &fullscreen);
        BOOL isFullscreen = fullscreen && CFEqual(fullscreen, kCFBooleanTrue);
        if (fullscreen) CFRelease(fullscreen);
        if (isFullscreen) {
            if (AXUIElementSetAttributeValue(window, CFSTR("AXFullScreen"), kCFBooleanFalse) == kAXErrorSuccess) {
                saved[@"fullscreen"] = @YES; saved[@"moved"] = @YES;
            }
            return; // Let the Space transition settle before moving this window.
        }
        Boolean settable = false;
        if (AXUIElementIsAttributeSettable(window, kAXPositionAttribute, &settable) != kAXErrorSuccess || !settable) return;
        CGRect work = NSRectToCGRect(destinations[0].rectValue);
        CGRect fitted = OSXRDPFitRemoteWindow(frame, work);
        if (SetWindowFrame(window, fitted)) { saved[@"moved"] = @YES; moved++; }
    }];
    if (moved) NSLog(@"[OSXRDP windows] moved %d windows onto the remote display", moved);
}
- (void)restore {
    for (NSDictionary* record in _ownSaved) {
        NSWindow* window = record[@"window"];
        NSRect original = [record[@"frame"] rectValue];
        BOOL visible = NO;
        for (NSScreen* screen in NSScreen.screens) if (NSIntersectsRect(original, screen.visibleFrame)) visible = YES;
        if (!visible && NSScreen.mainScreen) original = NSRectFromCGRect(OSXRDPFitRemoteWindow(NSRectToCGRect(original), NSRectToCGRect(NSScreen.mainScreen.visibleFrame)));
        [window setFrame:original display:YES];
    }
    [_ownSaved removeAllObjects];
    int restored = 0;
    for (NSDictionary* saved in _saved) {
        if (![saved[@"moved"] boolValue]) continue;
        AXUIElementRef window = (__bridge AXUIElementRef)saved[@"window"];
        CGRect frame = NSRectToCGRect([saved[@"frame"] rectValue]);
        BOOL visible = NO;
        for (NSScreen* screen in NSScreen.screens)
            if (CGRectIntersectsRect(frame, RemoteWorkArea(screen))) { visible = YES; break; }
        if (!visible && NSScreen.mainScreen) frame = OSXRDPFitRemoteWindow(frame, RemoteWorkArea(NSScreen.mainScreen));
        if (SetWindowFrame(window, frame)) restored++;
        if ([saved[@"fullscreen"] boolValue]) AXUIElementSetAttributeValue(window, CFSTR("AXFullScreen"), kCFBooleanTrue);
    }
    [_saved removeAllObjects];
    NSLog(@"[OSXRDP windows] restored %d local window positions", restored);
}
@end

// 가상 모니터 해상도 목록
//  이와 같이 구성을 채우지 않으면 macOS 가 이를 모니터가 아닌 다른 무언가로 인식하여 대화상자를 띄우는것 같음 (airplay 수신기?)
//  따라서 기본 구성을 진짜 모니터처럼 넣고 xrdp 해상도를 마지막에 넣는다.
static const int baseModes[][2] = {
    { 3840, 2160 }, { 2560, 1440 }, { 1920, 1080 }, { 1600, 900 }, { 1366, 768 }, { 1280, 720 },
    { 2560, 1600 }, { 1920, 1200 }, { 1680, 1050 }, { 1440, 900 }, { 1280, 800 }
};

VirtualMonitor::VirtualMonitor() :
    _virtualDisplayInfoCnt(0),
    _init(false),
    _disabledDisplayIds(NULL),
    _disabledDisplayIdsCnt(0),
    _watchRunning(false),
    _displaySleepAssertion(kIOPMNullAssertionID),
    _localDisplayLayoutCount(0)
{
    _privacyWindows = [NSMutableDictionary dictionary];
    _windowTransfer = [OSXRDPWindowTransfer new];
    pthread_mutex_init(&_watchLock, 0);
    pthread_cond_init(&_watchWake, 0);
}

VirtualMonitor::~VirtualMonitor() {
    Destroy();
    
    pthread_cond_destroy(&_watchWake);
    pthread_mutex_destroy(&_watchLock);
}

bool VirtualMonitor::Create(int width, int height, int left, int top, int index, bool isPrimary) {
    if (_virtualDisplayInfoCnt >= 16) return false;

    if (_virtualDisplayInfoCnt == 0 && !_preserveSession) {
        SaveLocalDisplayLayout();
        OSXRDPWindowTransfer* transfer = _windowTransfer;
        // AX calls may run on the IPC thread. A fresh state object avoids a
        // main-thread join/synchronous-dispatch deadlock during app shutdown.
        _windowTransfer = [OSXRDPWindowTransfer new];
        transfer = _windowTransfer;
        [transfer snapshot];
    }

    HoldDisplaySleepAssertion();
    WakeupDisplay();

    // retina 여부 판단
    int scale = CalcScale(width, height);
    int refreshRate = CalcRefreshRate(width, height);

    // 가상 디스플레이를 생성
    CGVirtualDisplayDescriptor* desc = [[CGVirtualDisplayDescriptor alloc] init];
    if (desc == nil) return false;

    // 가상 디스플레이의 기본 속성
    desc.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    desc.name = @"OSXRDP Virtual Display";
    desc.maxPixelsWide = width;
    desc.maxPixelsHigh = height;
    desc.sizeInMillimeters = CGSizeMake((double)(width / scale) * 25.4 / 96.0,
                                        (double)(height / scale) * 25.4 / 96.0);
    desc.productID = 0x5969 + index;
    desc.vendorID = 0x1207;
    desc.serialNum = 0x0007 + index;

    CGVirtualDisplaySettings* settings = [[CGVirtualDisplaySettings alloc] init];
    if (settings == nil)
        return false;

    settings.hiDPI = scale == 2 ? 1 : 0;

    NSMutableArray* modes = [NSMutableArray array];

    for (int i = 0; i < (int)(sizeof(baseModes) / sizeof(baseModes[0])); i++) {
        int baseWidth = baseModes[i][0];
        int baseHeight = baseModes[i][1];

        // 원격 클라이언트 해상도와 중복되는 모드는 skip
        if (baseWidth == width && baseHeight == height)
            continue;

        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:baseWidth height:baseHeight refreshRate:refreshRate]];
    }

    [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate]];

    if (scale == 2) {
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:width / 2 height:height / 2 refreshRate:refreshRate]];
    }

    settings.modes = modes;

    CGVirtualDisplay* virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (virtualDisplay == nil)
        return false;

    // 가상 디스플레이 속성 적용
    if ([virtualDisplay applySettings:settings] == NO) {
        NSLog(@"[VirtualMonitor::Create] applySettings failed %dx%d@%dHz scale=%d", width, height, refreshRate, scale);

        return false;
    }

    WakeupDisplay();

    if (DisplayUtils::WaitDisplayOnlineState(virtualDisplay.displayID, true, 5000) == false) {
        NSLog(@"[VirtualMonitor::Create] display is not online yet; continue waiting in monitor thread %dx%d@%dHz scale=%d", width, height, refreshRate, scale);
    }

    _virtualDisplayInfo[_virtualDisplayInfoCnt].left = left;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].top = top;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].width = width;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].height = height;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].is_retina = scale == 2 ? true : false;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].is_primary = isPrimary ? true : false;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].virtualDisplay = virtualDisplay;
    _virtualDisplayInfo[_virtualDisplayInfoCnt].refresh_rate = refreshRate;
    
    _virtualDisplayInfoCnt++;

    ApplyDisplayLayout();

    return true;
}

void VirtualMonitor::Destroy(bool preserveSession) {
    preserveSession = preserveSession && (_virtualDisplayInfoCnt > 0 || _preserveSession);
    _preserveSession = preserveSession;
    // 가상 모미터 watch 스레드 정지
    if (_watchRunning == true) {
        _watchRunning = false;
        pthread_cond_signal(&_watchWake);
        pthread_join(_watchThread, NULL); // 완전히 정지할때까지 대기
    }

    if (_disabledDisplayIdsCnt > 0 || _localDisplayLayoutCount > 0) {
        WakeupDisplay();
        usleep(kDisplayReconfigSettleUsec);
    }

    // 비활성화한 디스플레이 롤백 (반드시 먼저 해야함, 그렇지 않는 경우 위 설명처럼 windowserver 가 크래시할 수 있음)
    RestoreOtherMonitors();
    RestoreLocalDisplayLayout(!preserveSession);

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        // nil 로 설정하면 알아서 뽀개짐 (즉시 뽀개지는건 아님)
        _virtualDisplayInfo[i].virtualDisplay = nil;
    }

    _virtualDisplayInfoCnt = 0;
    memset(&_virtualDisplayInfo, 0x00, sizeof(_virtualDisplayInfo));
    if (preserveSession) UpdateLocalPrivacy();
    else ClearLocalPrivacy();

    _init = false;
    if (!preserveSession) ReleaseDisplaySleepAssertion();
}

void VirtualMonitor::SaveLocalDisplayLayout() {
    _localDisplayLayoutCount = 0;
    uint32_t count = 0;
    CGDirectDisplayID displays[32];
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return;
    for (uint32_t i = 0; i < count; ++i) {
        if (IsVirtualDisplay(displays[i])) continue;
        CGRect bounds = CGDisplayBounds(displays[i]);
        auto* saved = &_localDisplayLayout[_localDisplayLayoutCount++];
        saved->id = displays[i];
        saved->x = (int)bounds.origin.x;
        saved->y = (int)bounds.origin.y;
    }
}

void VirtualMonitor::RestoreLocalDisplayLayout(bool forget) {
    if (_localDisplayLayoutCount == 0) return;
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    bool ok = true;
    int right = 0;
    for (int i = 0; i < _localDisplayLayoutCount; ++i) {
        const auto* saved = &_localDisplayLayout[i];
        // This version never disables physical outputs. Skip unplugged screens;
        // do not guess IDs or resurrect displays absent from the current list.
        if (!DisplayUtils::IsDisplayOnline(saved->id)) continue;
        CGRect bounds = CGDisplayBounds(saved->id);
        right = MAX(right, saved->x + (int)bounds.size.width);
        if (CGConfigureDisplayOrigin(cfg, saved->id, saved->x, saved->y) != kCGErrorSuccess) ok = false;
    }
    // Vacate the origin before deleting virtual screens, restoring the local
    // primary display without leaving two screens claiming (0,0).
    for (int i = 0; i < _virtualDisplayInfoCnt; ++i) {
        auto* display = &_virtualDisplayInfo[i];
        if (display->virtualDisplay == nil) continue;
        if (CGConfigureDisplayOrigin(cfg, display->virtualDisplay.displayID,
                                     right + 64, 0) != kCGErrorSuccess) ok = false;
        right += display->width;
    }
    CGError error = kCGErrorFailure;
    if (ok) error = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    else CGCancelDisplayConfiguration(cfg);
    NSLog(@"[OSXRDP local displays] restore layout result=%d", error);
    if (forget) _localDisplayLayoutCount = 0;
}

void VirtualMonitor::RestoreOtherMonitors() {
    if (_disabledDisplayIdsCnt == 0 || _disabledDisplayIds == NULL) {
        return;
    }
    
    DisplayUtils::ApplyDisplayEnabled(_disabledDisplayIds, _disabledDisplayIdsCnt, true);
    
    free(_disabledDisplayIds);
    
    _disabledDisplayIds = NULL;
    _disabledDisplayIdsCnt = 0;
}

void VirtualMonitor::StartMonitor() {
    HoldDisplaySleepAssertion();
    WakeupDisplay();
    UpdateLocalPrivacy();

    if (_watchRunning == false) {
        _watchRunning = true;
        pthread_create(&_watchThread , NULL, WatchThreadProc, this);
    }
}

void VirtualMonitor::UpdateLocalPrivacy() {
    if (getuid() == 0) return;
    NSMutableSet<NSNumber*>* remoteIDs = [NSMutableSet set];
    for (int i = 0; i < _virtualDisplayInfoCnt; ++i) {
        if (_virtualDisplayInfo[i].virtualDisplay != nil)
            [remoteIDs addObject:@(_virtualDisplayInfo[i].virtualDisplay.displayID)];
    }
    // Capture retained objects, never this: queued work may outlive teardown.
    NSMutableDictionary<NSNumber*, NSWindow*>* windows = _privacyWindows;
    OSXRDPWindowTransfer* transfer = _windowTransfer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [transfer gather:remoteIDs];
        NSMutableSet<NSNumber*>* localIDs = [NSMutableSet set];
        for (NSScreen* screen in [NSScreen screens]) {
            NSNumber* displayID = screen.deviceDescription[@"NSScreenNumber"];
            if (displayID == nil || [remoteIDs containsObject:displayID]) continue;
            [localIDs addObject:displayID];
            NSWindow* cover = windows[displayID];
            if (cover == nil) {
                cover = [[OSXRDPPrivacyPanel alloc] initWithContentRect:screen.frame
                    styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered defer:NO screen:screen];
                cover.title = @"OSXRDP local screen privacy";
                cover.backgroundColor = [NSColor blackColor];
                cover.opaque = YES;
                cover.hasShadow = NO;
                cover.releasedWhenClosed = NO;
                cover.hidesOnDeactivate = NO;
                cover.level = CGShieldingWindowLevel() + 1;
                cover.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                    | NSWindowCollectionBehaviorStationary
                    | NSWindowCollectionBehaviorIgnoresCycle
                    | NSWindowCollectionBehaviorFullScreenAuxiliary;
                windows[displayID] = cover;
                NSLog(@"[OSXRDP privacy] covering local display %@", displayID);
            }
            [cover setFrame:screen.frame display:YES];
            [cover orderFrontRegardless];
        }
        for (NSNumber* displayID in [windows.allKeys copy]) {
            if (![localIDs containsObject:displayID]) {
                [windows[displayID] close];
                [windows removeObjectForKey:displayID];
            }
        }
    });
}

void VirtualMonitor::ClearLocalPrivacy() {
    NSMutableDictionary<NSNumber*, NSWindow*>* windows = _privacyWindows;
    OSXRDPWindowTransfer* transfer = _windowTransfer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [transfer restore];
        for (NSWindow* cover in windows.allValues) [cover close];
        [windows removeAllObjects];
        NSLog(@"[OSXRDP privacy] local display covers removed");
    });
}

void VirtualMonitor::WakeupDisplay() {
    IOPMAssertionID assertionID = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("OSXRDP: wake display"), kIOPMUserActiveLocal, &assertionID);
    if (assertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(assertionID);
        assertionID = kIOPMNullAssertionID;
    }
}

void VirtualMonitor::HoldDisplaySleepAssertion() {
    if (_displaySleepAssertion != kIOPMNullAssertionID) {
        return;
    }

    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                kIOPMAssertionLevelOn,
                                CFSTR("OSXRDP virtual monitor session"),
                                &_displaySleepAssertion);
}

void VirtualMonitor::ReleaseDisplaySleepAssertion() {
    if (_displaySleepAssertion == kIOPMNullAssertionID) {
        return;
    }

    IOPMAssertionRelease(_displaySleepAssertion);
    _displaySleepAssertion = kIOPMNullAssertionID;
}

// todo: DisplayUtils::ApplyDisplayEnabled 에 중복 로직이 있음
bool VirtualMonitor::DisableOtherMonitors() {
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors begin virtualDisplayCnt=%d disabledCnt=%d]", _virtualDisplayInfoCnt, _disabledDisplayIdsCnt);
    
    // 가상 디스플레이가 없으면 무시
    if (_virtualDisplayInfoCnt <= 0) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=noVirtualDisplay]");
        return false;
    }
    
    // 디스플레이 갯수를 조회
    uint32_t displayCnt = 0;
    CGError displayListErr = CGGetOnlineDisplayList(0, NULL, &displayCnt);
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors onlineCnt=%u err=%d]", displayCnt, displayListErr);
    
    if (displayListErr != kCGErrorSuccess || displayCnt == 0) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=noDisplay err=%d cnt=%u]", displayListErr, displayCnt);
        return false;
    }
    
    // 디스플레이 id 들을 조회
    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=mallocDisplayIds cnt=%u]", displayCnt);
        return false;
    }
    
    displayListErr = CGGetOnlineDisplayList(displayCnt, displayIds, NULL);
    if (displayListErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=getDisplayList err=%d cnt=%u]", displayListErr, displayCnt);
        free(displayIds);
        
        return false;
    }

    bool hasPhysicalOnlineDisplay = false;
    for (uint32_t i = 0; i < displayCnt; i++) {
        if (IsVirtualDisplay(displayIds[i]) == false) {
            hasPhysicalOnlineDisplay = true;
            break;
        }
    }

    if (hasPhysicalOnlineDisplay == false) {
        free(displayIds);
        return true;
    }
    
    uint32_t* newDisabledDisplayIds = (uint32_t*)realloc(_disabledDisplayIds, sizeof(uint32_t) * (_disabledDisplayIdsCnt + displayCnt));
    if (newDisabledDisplayIds == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=realloc oldCnt=%d addCnt=%u]", _disabledDisplayIdsCnt, displayCnt);
        free(displayIds);
        return false;
    }
    
    _disabledDisplayIds = newDisabledDisplayIds;
    
    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=beginConfiguration err=%d cfg=%p]", beginErr, cfg);
        free(displayIds);
        
        return false;
    }
    
    int newDisabledDisplayIdsCnt = _disabledDisplayIdsCnt;
    
    for (uint32_t i = 0; i < displayCnt; i++) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors check id=%u index=%u]", displayIds[i], i);
        
        if (IsVirtualDisplay(displayIds[i])) {
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors skip virtual id=%u]", displayIds[i]);
            continue;
        }
        
        // 물리 디스플레이를 끄도록 구성
        CGError configureErr = CGSConfigureDisplayEnabled(cfg, displayIds[i], false);
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors configure id=%u enabled=0 err=%d]", displayIds[i], configureErr);
        
        bool exists = false;
        for (int j = 0; j < _disabledDisplayIdsCnt; j++) {
            if (_disabledDisplayIds[j] == displayIds[i]) {
                exists = true;
                break;
            }
        }
        
        if (exists == false) {
            // 나중에 복원할 수 있도록 id 를 저장
            _disabledDisplayIds[newDisabledDisplayIdsCnt] = displayIds[i];
            newDisabledDisplayIdsCnt++;
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors add disabled id=%u newCnt=%d]", displayIds[i], newDisabledDisplayIdsCnt);
        }
        else {
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors skip duplicate id=%u]", displayIds[i]);
        }
    }
    
    // 설정 저장
    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=complete err=%d oldCnt=%d newCnt=%d]", completeErr, _disabledDisplayIdsCnt, newDisabledDisplayIdsCnt);
        free(displayIds);
        return false;
    }
    
    _disabledDisplayIdsCnt = newDisabledDisplayIdsCnt;
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors success disabledCnt=%d]", _disabledDisplayIdsCnt);
    
    free(displayIds);

    return true;
}

bool VirtualMonitor::IsVirtualDisplay(CGDirectDisplayID displayId) {
    if (displayId == 0) {
        return false;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (_virtualDisplayInfo[i].virtualDisplay == nil) {
            continue;
        }

        if (_virtualDisplayInfo[i].virtualDisplay.displayID == displayId) {
            return true;
        }
    }

    return false;
}

bool VirtualMonitor::IsAllVirtualDisplayOnline() {
    if (_virtualDisplayInfoCnt <= 0) {
        return false;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (_virtualDisplayInfo[i].virtualDisplay == nil) {
            return false;
        }

        if (DisplayUtils::IsDisplayOnline(_virtualDisplayInfo[i].virtualDisplay.displayID) == false) {
            return false;
        }
    }

    return true;
}

int VirtualMonitor::GetPrimaryDisplayIndex() {
    if (_virtualDisplayInfoCnt <= 0) {
        return -1;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (_virtualDisplayInfo[i].is_primary != 0) {
            return i;
        }
    }

    return 0;
}

bool VirtualMonitor::IsRightPrimaryDisplay() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return false;
    }

    if (_virtualDisplayInfo[primaryIndex].virtualDisplay == nil) {
        return false;
    }

    return CGMainDisplayID() == _virtualDisplayInfo[primaryIndex].virtualDisplay.displayID;
}

bool VirtualMonitor::IsRightDisplayLayout() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return false;
    }

    struct VIRTUALMONITOR_INFO* primaryInfo = &_virtualDisplayInfo[primaryIndex];
    if (primaryInfo->virtualDisplay == nil) {
        return false;
    }

    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[i];
        if (displayInfo->virtualDisplay == nil) {
            return false;
        }

        CGRect bounds = CGDisplayBounds(displayInfo->virtualDisplay.displayID);
        int expectedX = displayInfo->left - primaryInfo->left;
        int expectedY = displayInfo->top - primaryInfo->top;

        if ((int)bounds.origin.x != expectedX || (int)bounds.origin.y != expectedY) {
            return false;
        }
    }

    return IsRightPrimaryDisplay();
}

int VirtualMonitor::SetResolution(int index) {
    if (index < 0 || index >= _virtualDisplayInfoCnt) {
        return 1;
    }

    struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[index];
    if (displayInfo->virtualDisplay == nil) {
        return 1;
    }

    CGDisplayModeRef bestMode = NULL;
    
    // Retina 해상도 까지 조회하기 위한 옵션
    CFStringRef keys[1] = { kCGDisplayShowDuplicateLowResolutionModes };
    CFTypeRef values[1] = { kCFBooleanTrue };
        
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)keys,
        (const void **)values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
        
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayInfo->virtualDisplay.displayID, options);
    if (modes == NULL) {
        NSLog(@"[VirtualMonitor::SetResolution] CGDisplayCopyAllDisplayModes null\n");
        CFRelease(options);
        
        return 1;
    }
    
    if (displayInfo->is_retina) {
        CFIndex cnt = CFArrayGetCount(modes);
        // Retina (HiDPI) 가 먹힌 해상도를 먼저 찾기
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            
            if (modeWidth == (displayInfo->width / 2) && modeHeight == (displayInfo->height / 2)
                && CGDisplayModeGetPixelWidth(mode) == displayInfo->width
                && CGDisplayModeGetPixelHeight(mode) == displayInfo->height) {
                NSLog(@"found retina bestmode\n");
                bestMode = mode;
                break;
            }
        }
        
        // Retina 해상도를 찾지 못한 경우 일반 해상도를 찾기
        if (bestMode == NULL) {
            CFIndex cnt = CFArrayGetCount(modes);
            for (CFIndex i = 0; i < cnt; i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                
                size_t modeWidth = CGDisplayModeGetWidth(mode);
                size_t modeHeight = CGDisplayModeGetHeight(mode);
                
                if (modeWidth == displayInfo->width && modeHeight == displayInfo->height
                    && CGDisplayModeGetPixelWidth(mode) == displayInfo->width
                    && CGDisplayModeGetPixelHeight(mode) == displayInfo->height) {
                    NSLog(@"found bestmode\n");
                    bestMode = mode;
                    break;
                }
            }
        }
    }
    else {
        CFIndex cnt = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            
            if (modeWidth == displayInfo->width && modeHeight == displayInfo->height
                && CGDisplayModeGetPixelWidth(mode) == displayInfo->width
                && CGDisplayModeGetPixelHeight(mode) == displayInfo->height) {
                NSLog(@"found bestmode\n");
                bestMode = mode;
                break;
            }
        }
    }
    
    if (bestMode == NULL) {
        NSLog(@"bestmode is null\n");
        
        CFRelease(modes);
        CFRelease(options);
        
        return 1;
    }
    
    CGError err = CGDisplaySetDisplayMode(displayInfo->virtualDisplay.displayID, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        printf("Configure Resolution Failed. %d \n", err);
    }
    
    CFRelease(modes);
    CFRelease(options);
    
    return err == kCGErrorSuccess ? 0 : 1;
}

bool VirtualMonitor::IsRightResolution(int index) {
    if (index < 0 || index >= _virtualDisplayInfoCnt) {
        return false;
    }
    
    struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[index];
    if (displayInfo->virtualDisplay == nil) {
        return false;
    }

    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayInfo->virtualDisplay.displayID);
    if (mode == NULL) {
        return false;
    }
    
    size_t modeWidth = CGDisplayModeGetWidth(mode);
    size_t modeHeight = CGDisplayModeGetHeight(mode);
    size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
    
    bool result = false;
    if (displayInfo->is_retina) {
        result = (modeWidth == (displayInfo->width / 2) && modeHeight == (displayInfo->height / 2) &&
                  pixelWidth == displayInfo->width && pixelHeight == displayInfo->height);
    }
    else {
        result = (modeWidth == displayInfo->width && modeHeight == displayInfo->height &&
                  pixelWidth == displayInfo->width && pixelHeight == displayInfo->height);
    }
    
    CFRelease(mode);
    
    return result;
}

int VirtualMonitor::SetPrimaryDisplay() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return 1;
    }

    struct VIRTUALMONITOR_INFO* primaryInfo = &_virtualDisplayInfo[primaryIndex];
    if (primaryInfo->virtualDisplay == nil) {
        return 1;
    }

    CGDirectDisplayID primaryDisplayId = primaryInfo->virtualDisplay.displayID;
    if (primaryDisplayId == 0) {
        return 1;
    }

    CGRect primaryBounds = CGDisplayBounds(primaryDisplayId);
    int offsetX = -(int)primaryBounds.origin.x;
    int offsetY = -(int)primaryBounds.origin.y;

    if (offsetX == 0 && offsetY == 0 && CGMainDisplayID() == primaryDisplayId) {
        return 0;
    }

    uint32_t displayCnt = 0;
    CGError displayListErr = CGGetOnlineDisplayList(0, NULL, &displayCnt);
    if (displayListErr != kCGErrorSuccess || displayCnt == 0) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=noDisplay err=%d cnt=%u", displayListErr, displayCnt);
        return 1;
    }

    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=mallocDisplayIds cnt=%u", displayCnt);
        return 1;
    }

    displayListErr = CGGetOnlineDisplayList(displayCnt, displayIds, NULL);
    if (displayListErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=getDisplayList err=%d cnt=%u", displayListErr, displayCnt);
        free(displayIds);
        return 1;
    }

    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=beginConfiguration err=%d cfg=%p", beginErr, cfg);
        free(displayIds);
        return 1;
    }

    bool configured = true;
    for (uint32_t i = 0; i < displayCnt; i++) {
        CGRect bounds = CGDisplayBounds(displayIds[i]);
        int x = (int)bounds.origin.x + offsetX;
        int y = (int)bounds.origin.y + offsetY;

        CGError configureErr = CGConfigureDisplayOrigin(cfg, displayIds[i], x, y);
        if (configureErr != kCGErrorSuccess) {
            NSLog(@"[VirtualMonitor::SetPrimaryDisplay] configure failed id=%u err=%d", displayIds[i], configureErr);
            configured = false;
            break;
        }
    }

    if (configured == false) {
        CGCancelDisplayConfiguration(cfg);
        free(displayIds);
        return 1;
    }

    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    free(displayIds);

    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::SetPrimaryDisplay] failed reason=complete err=%d", completeErr);
        return 1;
    }

    NSLog(@"[VirtualMonitor::SetPrimaryDisplay] success primary=%u", primaryDisplayId);
    return 0;
}

int VirtualMonitor::ApplyDisplayLayout() {
    int primaryIndex = GetPrimaryDisplayIndex();
    if (primaryIndex < 0 || primaryIndex >= _virtualDisplayInfoCnt) {
        return 1;
    }

    struct VIRTUALMONITOR_INFO* primaryInfo = &_virtualDisplayInfo[primaryIndex];
    if (primaryInfo->virtualDisplay == nil) {
        return 1;
    }

    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonitor::ApplyDisplayLayout] failed reason=beginConfiguration err=%d cfg=%p", beginErr, cfg);
        return 1;
    }

    bool configured = true;
    int virtualRight = 0;
    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        struct VIRTUALMONITOR_INFO* displayInfo = &_virtualDisplayInfo[i];
        if (displayInfo->virtualDisplay == nil) {
            configured = false;
            break;
        }

        int x = displayInfo->left - primaryInfo->left;
        int y = displayInfo->top - primaryInfo->top;
        const int scale = displayInfo->is_retina ? 2 : 1;
        virtualRight = MAX(virtualRight, x + displayInfo->width / scale);

        CGError configureErr = CGConfigureDisplayOrigin(cfg, displayInfo->virtualDisplay.displayID, x, y);
        if (configureErr != kCGErrorSuccess) {
            NSLog(@"[VirtualMonitor::ApplyDisplayLayout] configure failed index=%d id=%u x=%d y=%d err=%d",
                  i, displayInfo->virtualDisplay.displayID, x, y, configureErr);
            configured = false;
            break;
        }
    }

    // Keep local monitors powered on as an extended desktop. Place their
    // original arrangement beside the virtual desktop instead of disabling
    // outputs through private APIs, which can leave the Mac black on exit.
    int localLeft = 0;
    for (int i = 0; i < _localDisplayLayoutCount; ++i) {
        localLeft = MIN(localLeft, _localDisplayLayout[i].x);
    }
    for (int i = 0; configured && i < _localDisplayLayoutCount; ++i) {
        const auto* saved = &_localDisplayLayout[i];
        if (!DisplayUtils::IsDisplayOnline(saved->id)) continue;
        if (CGConfigureDisplayOrigin(cfg, saved->id,
                virtualRight + 64 + saved->x - localLeft, saved->y) != kCGErrorSuccess) configured = false;
    }
    if (configured == false) {
        CGCancelDisplayConfiguration(cfg);
        return 1;
    }

    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonitor::ApplyDisplayLayout] failed reason=complete err=%d", completeErr);
        return 1;
    }

    NSLog(@"[VirtualMonitor::ApplyDisplayLayout] success primaryIndex=%d primary=%u", primaryIndex, primaryInfo->virtualDisplay.displayID);
    return 0;
}

void* VirtualMonitor::WatchThreadProc(void* args) {
    
    if (args == NULL) return NULL;
    VirtualMonitor* _this = (VirtualMonitor*)args;
    
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    
    pthread_mutex_lock(&_this->_watchLock);
    
    for(;;) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 3;
        
        pthread_cond_timedwait(&_this->_watchWake, &_this->_watchLock, &ts);
        
        if (_this->_watchRunning == false) break;
        
        _this->WatchThreadPorcInternal();
    }
    
    pthread_mutex_unlock(&_this->_watchLock);
    
    return NULL;
}

void VirtualMonitor::WatchThreadPorcInternal() {
    // 아직 가상 모니터가 완전히 활성화 되어있는지 확인하지 못한 상황
    if (_init == false) {
        // 모든 가상 모니터가 완전히 사용 가능한지 확인
        if (IsAllVirtualDisplayOnline() == false) {
            NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display does not online yet");
            return;
        }
        
        NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has been online now");
        _init = true;
    }
    
    // Physical outputs remain enabled. Their arrangement is restored on exit.
    
    // 해상도 정보 확인 (가상 모니터)
    for (int i = 0; i < _virtualDisplayInfoCnt; i++) {
        if (IsRightResolution(i) == false) {
            // 해상도가 틀어진 경우 (혹은 아직 설정되지 않은 경우) --> 해상도 설정
            NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has invalid resolution. try change it index=%d", i);
            SetResolution(i);
        }
    }

    // 다른 display 추가/삭제 과정에서 display 배치나 primary 가 풀리는 경우 원복
    if (IsRightDisplayLayout() == false) {
        NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has invalid layout. try change it");
        ApplyDisplayLayout();
    }
    UpdateLocalPrivacy();
}

// EDID 의 픽셀 클럭 필드는 10kHz 단위 16비트라 macOS 는 655.35MHz 를 넘는 타이밍을 담지 못하는것으로 보인다. (추측, 여러 테스트를 기반)
// 따라서 655.35 를 넘는 경우 주사율을 낮추는 식으로 우회한다.
int VirtualMonitor::CalcScale(int width, int height) {
    const int longEdge = MAX(width, height);
    const int shortEdge = MIN(width, height);
    return (longEdge > 3440 || (longEdge > 2300 && shortEdge > 1500)) ? 2 : 1;
}

int VirtualMonitor::CalcRefreshRate(int width, int height) {
    if (width <= 0 || height <= 0) return 45;
    
    int refreshRate = (int)(655350000.0 / ((double)width * (double)height * 1.35));

    if (refreshRate > 60) refreshRate = 60;
    else if (refreshRate < 1) refreshRate = 45;
    
    // hw 가속 인코딩이 아직 지원되지 않으므로 주사율을 좀 낮추어 cpu 점유율을 감소 (temp)
    if (width >= 3000 && height >= 2000) {
        if (refreshRate > 45) {
            refreshRate = 45;
        }
    }

    return refreshRate;
}
