#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h> // Virtual-key constants only; no Carbon runtime linkage.
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <time.h>
#import <stdatomic.h>
#import <dlfcn.h>

#import "../CLI/BacklightControl.h"
#import "GestureDetector.h"

@interface NSTouchBar (SystemModalPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar
                         placement:(NSInteger)placement
          systemTrayItemIdentifier:(NSString *)identifier;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)bar;
@end

typedef NS_ENUM(NSInteger, BarMode) {
    BarModeOff = 0,
    BarModeNormal = 1,
    BarModeFunctions = 2,
};

static NSString *const kModeKey = @"TouchBarMode";
static NSString *const kPriorModeKey = @"PriorVisibleTouchBarMode";
static NSString *const kSavedSystemModeKey = @"SavedSystemPresentationModeGlobal";
static NSString *const kSavedSystemFnModesKey = @"SavedSystemPresentationModeFnModes";
static NSString *const kSuppressedSystemFnModesKey = @"SuppressedSystemPresentationModeFnModes";
static NSString *const kUnsetSystemMode = @"__unset__";
static NSString *const kFunctionKeysSystemMode = @"functionKeys";
static NSString *const kTrayIdentifier = @"local.touchbar.controller.tray";
// Only accessed on the serial backlight queue.
static uint64_t loggedWakeCycle;
// Main-thread decisions invalidate already queued requests and retry handlers.
static atomic_uint_fast64_t backlightGeneration;

static double monotonicTimeMs(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec * 1000.0 + time.tv_nsec / 1000000.0;
}

static dispatch_queue_t backlightQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("local.touchbar.backlight", DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL);
    });
    return queue;
}

static void performBacklight(BOOL on, uint64_t wakeCycle, double wakeStartMs) {
    uint64_t generation = atomic_load(&backlightGeneration);
    BOOL succeeded = TouchBarSetBacklight(on);
    if (on && succeeded) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), backlightQueue(), ^{
            if (atomic_load(&backlightGeneration) == generation && !TouchBarRestoreBrightness()) {
                NSLog(@"Could not restore Touch Bar brightness");
            }
        });
    }
    if (wakeCycle) {
        if (succeeded && loggedWakeCycle != wakeCycle) {
            loggedWakeCycle = wakeCycle;
            NSLog(@"wake_off_delay_ms=%.3f wake_cycle=%llu",
                  monotonicTimeMs() - wakeStartMs, (unsigned long long)wakeCycle);
        }
    } else if (!succeeded) {
        NSLog(@"Could not turn Touch Bar backlight %@", on ? @"on" : @"off");
    }
}

static uint64_t requestBacklight(BOOL on, uint64_t wakeCycle, double wakeStartMs) {
    uint64_t generation = atomic_fetch_add(&backlightGeneration, 1) + 1;
    dispatch_async(backlightQueue(), ^{
        if (atomic_load(&backlightGeneration) == generation) {
            performBacklight(on, wakeCycle, wakeStartMs);
        }
    });
    return generation;
}

static void finishWakeMeasurement(uint64_t wakeCycle) {
    dispatch_async(backlightQueue(), ^{
        if (loggedWakeCycle != wakeCycle) {
            NSLog(@"wake_off_delay_ms=unavailable wake_cycle=%llu", (unsigned long long)wakeCycle);
        }
    });
}

static void setBacklight(BOOL on) {
    requestBacklight(on, 0, 0);
}

// One hardware check after the final wake off request has settled. No idle
// polling or repeated off writes: macOS only re-enables this bar during wake.
static void recoverOffAfterWake(uint64_t generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), backlightQueue(), ^{
        if (atomic_load(&backlightGeneration) != generation) return;
        int state = TouchBarBacklightPowerState();
        if (state <= 0) return;
        NSLog(@"Touch Bar hardware remains on after wake off requests; attempting on/off recovery");
        // The repair keeps the blank bar and saved off mode. Do not schedule
        // brightness restoration during this temporary on transition.
        if (!TouchBarSetBacklight(YES)) {
            performBacklight(NO, 0, 0);
            NSLog(@"Could not begin Touch Bar on/off recovery");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), backlightQueue(), ^{
            if (atomic_load(&backlightGeneration) != generation) return;
            performBacklight(NO, 0, 0);
            NSLog(@"Touch Bar on/off recovery: final off request sent");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), backlightQueue(), ^{
                if (atomic_load(&backlightGeneration) != generation) return;
                int finalState = TouchBarBacklightPowerState();
                NSLog(@"Touch Bar recovery hardware backlight=%@",
                      finalState < 0 ? @"unavailable" : finalState == 0 ? @"off" : @"on");
            });
        });
    });
}

static NSString *systemPresentationMode(void) {
    CFPreferencesAppSynchronize(CFSTR("com.apple.touchbar.agent"));
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PresentationModeGlobal"),
                                                           CFSTR("com.apple.touchbar.agent")));
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL setSystemPresentationMode(NSString *mode) {
    CFPreferencesSetAppValue(CFSTR("PresentationModeGlobal"), (__bridge CFPropertyListRef)mode,
                             CFSTR("com.apple.touchbar.agent"));
    if (!CFPreferencesAppSynchronize(CFSTR("com.apple.touchbar.agent"))) {
        NSLog(@"Could not save the macOS Touch Bar presentation mode");
        return NO;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/killall"];
    task.arguments = @[@"ControlStrip"];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"Could not refresh the macOS Touch Bar presentation mode: %@", error);
    } else {
        [task waitUntilExit];
    }
    return YES;
}

static NSDictionary *systemFnModes(void) {
    CFPreferencesAppSynchronize(CFSTR("com.apple.touchbar.agent"));
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PresentationModeFnModes"),
                                                         CFSTR("com.apple.touchbar.agent")));
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray<NSString *> *presentationModeKeys(void) {
    // DFRFoundation's presentation enum on the supported macOS versions.
    return @[@"appWithControlStrip", @"fullControlStrip", @"functionKeys", @"app",
             @"spaces", @"spacesWithControlStrip", @"workflows", @"workflowsWithControlStrip"];
}

static NSDictionary *unchangedFnModes(void) {
    NSArray *keys = presentationModeKeys();
    return [NSDictionary dictionaryWithObjects:keys forKeys:keys];
}

static BOOL setSystemFnModes(NSDictionary *modes) {
    static void (*setFnBehavior)(NSUInteger, NSUInteger);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
                                 RTLD_LAZY | RTLD_LOCAL);
        if (framework) setFnBehavior = dlsym(framework, "DFRPresentationModeSetFNBehavior");
    });
    if (!setFnBehavior) {
        NSLog(@"Could not load native Touch Bar Fn presentation control");
        return NO;
    }
    NSArray<NSString *> *keys = presentationModeKeys();
    for (NSUInteger index = 0; index < keys.count; index++) {
        NSString *target = modes[keys[index]];
        NSUInteger targetIndex = target ? [keys indexOfObject:target] : NSNotFound;
        // Native defaults: Fn shows function keys, except from function mode,
        // where it shows the expanded Control Strip.
        if (targetIndex == NSNotFound) targetIndex = index == 2 ? 1 : 2;
        setFnBehavior(index, targetIndex);
    }
    // The native setter notifies the Touch Bar server immediately. Preserve
    // the exact preference dictionary (including unset/default entries), too.
    CFPreferencesSetAppValue(CFSTR("PresentationModeFnModes"), (__bridge CFPropertyListRef)modes,
                             CFSTR("com.apple.touchbar.agent"));
    return CFPreferencesAppSynchronize(CFSTR("com.apple.touchbar.agent"));
}

@interface TouchBarController : NSObject <NSApplicationDelegate>
@property (strong) NSTouchBar *blankBar;
@property (strong) NSTouchBar *currentBar;
@property BarMode mode;
@property BarMode priorVisibleMode;
@property BOOL fnHeld;
@property BOOL suppressFnPress;
@property CFMachPortRef fnEventTap;
@property CFRunLoopSourceRef fnEventSource;
@property BOOL wakeRecoveryPending;
@property BOOL sleeping;
@property uint64_t wakeCycle;
@property double wakeStartMs;
@property (strong) dispatch_source_t wakeRetryTimer;
@property GestureDetector gestures;
@property (strong) id globalMonitor;
@property (strong) id localMonitor;
@property IONotificationPortRef powerNotificationPort;
@property io_object_t powerNotifier;
@property io_connect_t powerConnection;
- (void)handleKeyboardEvent:(NSEvent *)event;
- (CGEventRef)filterFnEvent:(CGEventRef)event type:(CGEventType)type;
- (void)installFnEventTap;
- (void)beginWake:(NSString *)source;
- (void)prepareForSleep;
- (void)restoreSystemPresentationMode;
- (void)restoreSystemFnModes;
@end

static CGEventRef fnEventCallback(CGEventTapProxy proxy, CGEventType type,
                                 CGEventRef event, void *context) {
    (void)proxy;
    TouchBarController *controller = (__bridge TouchBarController *)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(controller.fnEventTap, true);
        return event;
    }
    return [controller filterFnEvent:event type:type];
}

static void powerCallback(void *context, io_service_t service, natural_t messageType, void *messageArgument) {
    (void)service;
    TouchBarController *controller = (__bridge TouchBarController *)context;
    switch (messageType) {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(controller.powerConnection, (long)messageArgument);
            break;
        case kIOMessageSystemWillSleep:
            [controller prepareForSleep];
            IOAllowPowerChange(controller.powerConnection, (long)messageArgument);
            break;
        case kIOMessageSystemWillPowerOn:
            [controller beginWake:@"powering on"];
            break;
        case kIOMessageSystemHasPoweredOn:
            [controller beginWake:@"powered on"];
            break;
    }
}

@implementation TouchBarController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger savedMode = [defaults integerForKey:kModeKey];
    _mode = [defaults objectForKey:kModeKey] && savedMode >= BarModeOff && savedMode <= BarModeFunctions
        ? savedMode : BarModeNormal;
    NSInteger prior = [defaults integerForKey:kPriorModeKey];
    _priorVisibleMode = prior == BarModeFunctions ? BarModeFunctions : BarModeNormal;
    GestureDetectorReset(&_gestures);

    _blankBar = [NSTouchBar new];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.powerConnection = IORegisterForSystemPower((__bridge void *)self, &_powerNotificationPort,
                                                     powerCallback, &_powerNotifier);
    if (self.powerConnection) {
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(self.powerNotificationPort),
                           kCFRunLoopCommonModes);
    } else {
        NSLog(@"Could not register for I/O Kit power notifications; using workspace wake notification");
    }
    [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
        selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
        selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
        selector:@selector(sessionBecameActive:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    [self installEventMonitors];
    [self installFnEventTap];
    [self applyMode:YES];
    NSLog(@"TouchBarController running; mode=%ld", (long)self.mode);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (self.wakeRetryTimer) dispatch_source_cancel(self.wakeRetryTimer);
    atomic_fetch_add(&backlightGeneration, 1);
    [self restoreSystemPresentationMode];
    [self restoreSystemFnModes];
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
    if (self.powerConnection) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(self.powerNotificationPort),
                              kCFRunLoopCommonModes);
        IODeregisterForSystemPower(&_powerNotifier);
        IOServiceClose(self.powerConnection);
        IONotificationPortDestroy(self.powerNotificationPort);
    }
    [self removeEventMonitors];
    if (self.fnEventSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.fnEventSource, kCFRunLoopCommonModes);
        CFRelease(self.fnEventSource);
        self.fnEventSource = NULL;
    }
    if (self.fnEventTap) {
        CFMachPortInvalidate(self.fnEventTap);
        CFRelease(self.fnEventTap);
        self.fnEventTap = NULL;
    }
}

- (void)installFnEventTap {
    if (self.fnEventTap) return;
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) |
                       CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    // The session tap is too late: macOS has already selected the Fn Touch Bar
    // row by then. Filter where HID events enter WindowServer instead.
    self.fnEventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                     kCGEventTapOptionDefault, mask, fnEventCallback,
                                     (__bridge void *)self);
    if (!self.fnEventTap) {
        NSLog(@"Optional Fn event filter unavailable; accessibility_trusted=%d. Native Touch Bar Fn presentation is handled separately.", AXIsProcessTrusted());
        return;
    }
    self.fnEventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.fnEventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.fnEventSource, kCFRunLoopCommonModes);
    CGEventTapEnable(self.fnEventTap, true);
    NSLog(@"Fn wake HID filter installed; enabled=%d", CGEventTapIsEnabled(self.fnEventTap));
}

- (BOOL)fnEventFilterPermissionGranted {
    return AXIsProcessTrusted();
}

// Return whether this Fn press belongs to the wake shortcut. Keep the whole
// press (including release) out of macOS's normal Fn handling. This previews
// the visible controls without changing the saved off mode.
- (BOOL)handleFnDown:(BOOL)down {
    BOOL consume = self.suppressFnPress;
    if (down && !self.fnHeld && self.mode == BarModeOff) {
        NSLog(@"Fn wake shortcut; filter_active=%d", self.fnEventTap != NULL);
        self.suppressFnPress = YES;
        consume = YES;
        GestureDetectorOtherKey(&_gestures);
        // Presentation changes may restart ControlStrip; keep that work out of
        // the synchronous event tap callback so it cannot time out.
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyMode:NO]; });
    }
    self.fnHeld = down;
    if (!down) {
        self.suppressFnPress = NO;
        if (consume) dispatch_async(dispatch_get_main_queue(), ^{ [self applyMode:NO]; });
    }
    return consume;
}

- (CGEventRef)filterFnEvent:(CGEventRef)event type:(CGEventType)type {
    CGEventFlags flags = CGEventGetFlags(event);
    if (type == kCGEventFlagsChanged &&
        CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == kVK_Function) {
        if ([self handleFnDown:(flags & kCGEventFlagMaskSecondaryFn) != 0]) return NULL;
    }
    if (self.suppressFnPress) {
        // Other modifiers and keys still work while the wake press is held,
        // without reintroducing Fn into the downstream event stream.
        CGEventSetFlags(event, flags & ~kCGEventFlagMaskSecondaryFn);
    }
    return event;
}

- (void)removeEventMonitors {
    if (self.globalMonitor) {
        [NSEvent removeMonitor:self.globalMonitor];
        self.globalMonitor = nil;
    }
    if (self.localMonitor) {
        [NSEvent removeMonitor:self.localMonitor];
        self.localMonitor = nil;
    }
}

- (void)installEventMonitors {
    NSEventMask mask = NSEventMaskFlagsChanged | NSEventMaskKeyDown;
    self.globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        [self handleKeyboardEvent:event];
    }];
    self.localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        [self handleKeyboardEvent:event];
        return event;
    }];
    NSLog(@"Keyboard monitors installed: global=%d local=%d", self.globalMonitor != nil, self.localMonitor != nil);
}

- (void)rebuildEventMonitors {
    [self removeEventMonitors];
    [self installEventMonitors];
    [self installFnEventTap];
}

- (void)saveMode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.mode forKey:kModeKey];
    [defaults setInteger:self.priorVisibleMode forKey:kPriorModeKey];
}

- (void)showSystemFunctionKeys {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kSavedSystemModeKey]) {
        [defaults setObject:systemPresentationMode() ?: kUnsetSystemMode forKey:kSavedSystemModeKey];
        [defaults synchronize];
    }
    if (![systemPresentationMode() isEqualToString:kFunctionKeysSystemMode]) {
        setSystemPresentationMode(kFunctionKeysSystemMode);
    }
}

- (void)restoreSystemPresentationMode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedMode = [defaults stringForKey:kSavedSystemModeKey];
    if (!savedMode) return;
    if ([systemPresentationMode() isEqualToString:kFunctionKeysSystemMode]) {
        NSString *mode = [savedMode isEqualToString:kUnsetSystemMode] ? nil : savedMode;
        if (![mode isEqualToString:kFunctionKeysSystemMode] && !setSystemPresentationMode(mode)) return;
    }
    [defaults removeObjectForKey:kSavedSystemModeKey];
    [defaults synchronize];
}

- (void)suppressSystemFnModes {
    NSUserDefaults *defaults = [self fnModeDefaults];
    NSDictionary *modes = unchangedFnModes();
    NSDictionary *current = [self nativeFnModes];
    if (![defaults objectForKey:kSavedSystemFnModesKey] || ![current isEqual:modes]) {
        // A setting edited while off becomes the new value to restore, even
        // when the wake press needs to reapply our temporary override.
        [defaults setObject:current ?: kUnsetSystemMode forKey:kSavedSystemFnModesKey];
        [defaults setObject:modes forKey:kSuppressedSystemFnModesKey];
        [defaults synchronize];
    }
    if (![current isEqual:modes] && ![self setNativeFnModes:modes]) {
        NSLog(@"Could not suppress the native Fn Touch Bar row");
    }
}

- (void)restoreSystemFnModes {
    NSUserDefaults *defaults = [self fnModeDefaults];
    id saved = [defaults objectForKey:kSavedSystemFnModesKey];
    if (!saved) return;
    // Preserve any independent changes made in System Settings while off.
    if ([[self nativeFnModes] isEqual:unchangedFnModes()]) {
        NSDictionary *modes = [saved isKindOfClass:[NSDictionary class]] ? saved : nil;
        if (![self setNativeFnModes:modes]) return;
    }
    [defaults removeObjectForKey:kSavedSystemFnModesKey];
    [defaults removeObjectForKey:kSuppressedSystemFnModesKey];
    [defaults synchronize];
}

- (NSUserDefaults *)fnModeDefaults { return [NSUserDefaults standardUserDefaults]; }
- (NSDictionary *)nativeFnModes { return systemFnModes(); }
- (BOOL)setNativeFnModes:(NSDictionary *)modes { return setSystemFnModes(modes); }

- (void)updateFnPresentation {
    if (self.sleeping || self.wakeRecoveryPending) return;
    if (self.mode == BarModeOff || self.suppressFnPress) [self suppressSystemFnModes];
    else [self restoreSystemFnModes];
}

- (void)presentBar:(NSTouchBar *)bar force:(BOOL)force {
    if (!force && self.currentBar == bar) return;
    if (self.currentBar) [NSTouchBar minimizeSystemModalTouchBar:self.currentBar];
    [NSTouchBar presentSystemModalTouchBar:bar placement:1 systemTrayItemIdentifier:kTrayIdentifier];
    self.currentBar = bar;
}

- (void)applyMode:(BOOL)force {
    // Shortcuts (including Fn) may change the saved mode during recovery, but
    // must not interrupt the off interval or enqueue a stale on request.
    if (self.sleeping || self.wakeRecoveryPending) {
        [self saveMode];
        return;
    }
    BarMode displayedMode = self.mode == BarModeOff && self.fnHeld && self.suppressFnPress
        ? self.priorVisibleMode : self.mode;
    [self updateFnPresentation];
    if (displayedMode == BarModeFunctions) [self showSystemFunctionKeys];
    else [self restoreSystemPresentationMode];
    switch (displayedMode) {
        case BarModeOff:
            [self presentBar:self.blankBar force:force];
            setBacklight(NO);
            break;
        case BarModeNormal:
            if (!self.wakeRecoveryPending) setBacklight(YES);
            if (self.currentBar) [NSTouchBar minimizeSystemModalTouchBar:self.currentBar];
            self.currentBar = nil;
            break;
        case BarModeFunctions:
            if (!self.wakeRecoveryPending) setBacklight(YES);
            if (self.currentBar) [NSTouchBar minimizeSystemModalTouchBar:self.currentBar];
            self.currentBar = nil;
            break;
    }
    [self saveMode];
    NSLog(@"Touch Bar mode=%ld displayedMode=%ld", (long)self.mode, (long)displayedMode);
}

- (void)toggleCommand {
    if (self.mode == BarModeOff) {
        self.mode = self.priorVisibleMode;
    } else {
        self.priorVisibleMode = self.mode;
        self.mode = BarModeOff;
    }
    [self applyMode:NO];
}

- (void)toggleOption {
    if (self.mode == BarModeFunctions) {
        self.mode = BarModeNormal;
    } else {
        self.mode = BarModeFunctions;
    }
    [self applyMode:NO];
}

- (void)didWake:(NSNotification *)notification {
    (void)notification;
    [self beginWake:@"workspace notification"];
}

- (void)willSleep:(NSNotification *)notification {
    (void)notification;
    [self prepareForSleep];
}

- (void)prepareForSleep {
    self.sleeping = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (self.wakeRetryTimer) {
        dispatch_source_cancel(self.wakeRetryTimer);
        self.wakeRetryTimer = nil;
    }
    if (self.wakeRecoveryPending) finishWakeMeasurement(self.wakeCycle);
    self.wakeRecoveryPending = NO;
    self.fnHeld = NO;
    self.suppressFnPress = NO;
    GestureDetectorReset(&_gestures);
    setBacklight(NO);
}

- (void)beginWake:(NSString *)source {
    self.sleeping = NO;
    BOOL firstSignal = !self.wakeRecoveryPending;
    if (firstSignal) {
        self.wakeCycle++;
        self.wakeStartMs = monotonicTimeMs();
    }
    NSLog(@"Wake signal: %@; wake_cycle=%llu", source, (unsigned long long)self.wakeCycle);
    self.wakeRecoveryPending = YES;
    uint64_t generation = requestBacklight(NO, self.wakeCycle, self.wakeStartMs);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reapplyAfterWake) object:nil];
    if (self.wakeRetryTimer) dispatch_source_cancel(self.wakeRetryTimer);
    // Keep enforcing off until restoration, including later driver wake writes.
    // The generation check prevents cancelled handlers running after mode-on.
    uint64_t wakeCycle = self.wakeCycle;
    double wakeStartMs = self.wakeStartMs;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, backlightQueue());
    self.wakeRetryTimer = timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                              10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    __weak dispatch_source_t weakTimer = timer;
    dispatch_source_set_event_handler(timer, ^{
        dispatch_source_t activeTimer = weakTimer;
        if (activeTimer && !dispatch_source_testcancel(activeTimer) &&
            atomic_load(&backlightGeneration) == generation) {
            performBacklight(NO, wakeCycle, wakeStartMs);
            if (monotonicTimeMs() - wakeStartMs > 500.0) {
                dispatch_source_set_timer(activeTimer,
                                          dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                                          50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
            }
        }
    });
    dispatch_resume(timer);
    if (firstSignal) {
        self.fnHeld = NO;
        self.suppressFnPress = NO;
        GestureDetectorReset(&_gestures);
        [self performSelector:@selector(rebuildEventMonitors) withObject:nil afterDelay:0.5];
        [self performSelector:@selector(rebuildEventMonitors) withObject:nil afterDelay:2.0];
    }
    [self performSelector:@selector(reapplyAfterWake) withObject:nil afterDelay:2.0];
}

- (void)sessionBecameActive:(NSNotification *)notification {
    (void)notification;
    GestureDetectorReset(&_gestures);
    [self performSelector:@selector(rebuildEventMonitors) withObject:nil afterDelay:0.5];
}

- (void)reapplyAfterWake {
    if (self.wakeRetryTimer) {
        dispatch_source_cancel(self.wakeRetryTimer);
        self.wakeRetryTimer = nil;
    }
    finishWakeMeasurement(self.wakeCycle);
    self.wakeRecoveryPending = NO;
    [self applyMode:YES];
    if (self.mode == BarModeOff && !(self.fnHeld && self.suppressFnPress)) {
        recoverOffAfterWake(atomic_load(&backlightGeneration));
    }
}

- (void)handleKeyboardEvent:(NSEvent *)event {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleKeyboardEvent:event]; });
        return;
    }
    if (event.type == NSEventTypeKeyDown) {
        GestureDetectorOtherKey(&_gestures);
        return;
    }
    if (event.type != NSEventTypeFlagsChanged) return;
    CGKeyCode keyCode = event.keyCode;
    if (!self.fnEventTap && keyCode == kVK_Function) {
        [self handleFnDown:(event.modifierFlags & NSEventModifierFlagFunction) != 0];
        // Permission may have been granted while this process was running.
        // Wait for release so an already-delivered Fn down is paired with its
        // normal release before the new filter starts consuming whole presses.
        if (!self.fnHeld && [self fnEventFilterPermissionGranted]) [self installFnEventTap];
    }
    Gesture modifier = GestureNone;
    NSEventModifierFlags ownFlag = 0;
    if (keyCode == kVK_Command || keyCode == kVK_RightCommand) {
        modifier = GestureCommand;
        ownFlag = NSEventModifierFlagCommand;
    } else if (keyCode == kVK_Option || keyCode == kVK_RightOption) {
        modifier = GestureOption;
        ownFlag = NSEventModifierFlagOption;
    } else {
        GestureDetectorOtherKey(&_gestures);
        return;
    }
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL isDown = (flags & ownFlag) != 0;
    NSEventModifierFlags modifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                     NSEventModifierFlagControl | NSEventModifierFlagShift |
                                     NSEventModifierFlagFunction;
    BOOL otherHeld = (flags & (modifiers & ~ownFlag)) != 0;
    double seconds = event.timestamp;
    Gesture gesture = GestureDetectorModifier(&_gestures, modifier, isDown,
                                               otherHeld, seconds);
    if (gesture == GestureCommand) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleCommand]; });
    } else if (gesture == GestureOption) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleOption]; });
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argv;
    @autoreleasepool {
        if (argc > 1) {
            fprintf(stderr, "TouchBarController is a background app; use touchbarctl for manual control.\n");
            return 2;
        }
        // Drain initialization temporaries before entering the long-running
        // AppKit loop, while retaining its delegate for the full run.
        __attribute__((objc_precise_lifetime)) TouchBarController *controller;
        @autoreleasepool {
            [NSApplication sharedApplication];
            [[NSProcessInfo processInfo] disableAutomaticTermination:@"Touch Bar shortcut and wake monitor"];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            controller = [TouchBarController new];
            NSApp.delegate = controller;
        }
        [NSApp run];
    }
    return 0;
}
