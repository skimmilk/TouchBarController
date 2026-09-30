#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <time.h>

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
static NSString *const kTrayIdentifier = @"local.touchbar.controller.tray";
// Only accessed on the serial backlight queue.
static uint64_t loggedWakeCycle;

static double monotonicTimeMs(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec * 1000.0 + time.tv_nsec / 1000000.0;
}

static dispatch_queue_t backlightQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("local.touchbar.backlight", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void performBacklight(BOOL on, uint64_t wakeCycle, double wakeStartMs) {
    BOOL succeeded = TouchBarSetBacklight(on);
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

static void requestBacklight(BOOL on, uint64_t wakeCycle, double wakeStartMs) {
    dispatch_async(backlightQueue(), ^{
        performBacklight(on, wakeCycle, wakeStartMs);
    });
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

@interface TouchBarController : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@property (strong) NSTouchBar *blankBar;
@property (strong) NSTouchBar *functionBar;
@property (strong) NSTouchBar *currentBar;
@property BarMode mode;
@property BarMode priorVisibleMode;
@property BOOL fnHeld;
@property BOOL wakeRecoveryPending;
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
- (void)beginWake:(NSString *)source;
@end

static void powerCallback(void *context, io_service_t service, natural_t messageType, void *messageArgument) {
    (void)service;
    TouchBarController *controller = (__bridge TouchBarController *)context;
    switch (messageType) {
        case kIOMessageCanSystemSleep:
        case kIOMessageSystemWillSleep:
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
    _functionBar = [NSTouchBar new];
    _functionBar.delegate = self;
    NSMutableArray<NSTouchBarItemIdentifier> *items = [NSMutableArray array];
    for (NSInteger n = 1; n <= 12; n++) {
        [items addObject:[NSString stringWithFormat:@"local.touchbar.controller.f%ld", (long)n]];
    }
    _functionBar.defaultItemIdentifiers = items;
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
        selector:@selector(sessionBecameActive:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
    if (!AXIsProcessTrusted()) {
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        NSLog(@"Accessibility access is needed for F1–F12 button presses");
    }
    [self installEventMonitors];
    [self applyMode:YES];
    NSLog(@"TouchBarController running; mode=%ld", (long)self.mode);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
    if (self.powerConnection) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(self.powerNotificationPort),
                              kCFRunLoopCommonModes);
        IODeregisterForSystemPower(&_powerNotifier);
        IOServiceClose(self.powerConnection);
        IONotificationPortDestroy(self.powerNotificationPort);
    }
    [self removeEventMonitors];
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
}

- (void)saveMode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.mode forKey:kModeKey];
    [defaults setInteger:self.priorVisibleMode forKey:kPriorModeKey];
}

- (void)presentBar:(NSTouchBar *)bar force:(BOOL)force {
    if (!force && self.currentBar == bar) return;
    if (self.currentBar) [NSTouchBar minimizeSystemModalTouchBar:self.currentBar];
    [NSTouchBar presentSystemModalTouchBar:bar placement:1 systemTrayItemIdentifier:kTrayIdentifier];
    self.currentBar = bar;
}

- (void)applyMode:(BOOL)force {
    BarMode displayedMode = self.mode == BarModeOff && self.fnHeld
        ? self.priorVisibleMode : self.mode;
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
            [self presentBar:self.functionBar force:force];
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

- (void)beginWake:(NSString *)source {
    BOOL firstSignal = !self.wakeRecoveryPending;
    if (firstSignal) {
        self.wakeCycle++;
        self.wakeStartMs = monotonicTimeMs();
    }
    NSLog(@"Wake signal: %@; wake_cycle=%llu", source, (unsigned long long)self.wakeCycle);
    self.wakeRecoveryPending = YES;
    requestBacklight(NO, self.wakeCycle, self.wakeStartMs);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reapplyAfterWake) object:nil];
    if (firstSignal) {
        self.fnHeld = NO;
        GestureDetectorReset(&_gestures);
        // The first power message can precede the Touch Bar HID service becoming ready.
        uint64_t wakeCycle = self.wakeCycle;
        double wakeStartMs = self.wakeStartMs;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, backlightQueue());
        self.wakeRetryTimer = timer;
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                                  10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            if (monotonicTimeMs() - wakeStartMs <= 500.0) {
                performBacklight(NO, wakeCycle, wakeStartMs);
            }
        });
        dispatch_resume(timer);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (self.wakeRetryTimer == timer) {
                dispatch_source_cancel(timer);
                self.wakeRetryTimer = nil;
            }
        });
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
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)bar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    (void)bar;
    NSString *prefix = @"local.touchbar.controller.f";
    if (![identifier hasPrefix:prefix]) return nil;
    NSInteger number = [[identifier substringFromIndex:prefix.length] integerValue];
    if (number < 1 || number > 12) return nil;
    return [NSButtonTouchBarItem buttonTouchBarItemWithIdentifier:identifier
                                                           title:[NSString stringWithFormat:@"F%ld", (long)number]
                                                          target:self action:@selector(functionKeyTapped:)];
}

- (void)functionKeyTapped:(NSButtonTouchBarItem *)item {
    static const CGKeyCode codes[] = {
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    };
    NSInteger number = [[item.identifier substringFromIndex:@"local.touchbar.controller.f".length] integerValue];
    if (number < 1 || number > 12) return;
    if (!CGPreflightPostEventAccess()) {
        NSLog(@"F%ld tapped, but keyboard event posting is not permitted", (long)number);
        CGRequestPostEventAccess();
        return;
    }
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) {
        NSLog(@"Could not create event source for F%ld", (long)number);
        return;
    }
    CGEventRef down = CGEventCreateKeyboardEvent(source, codes[number - 1], true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, codes[number - 1], false);
    if (down && up) {
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
        NSLog(@"Posted F%ld key press", (long)number);
    } else {
        NSLog(@"Could not create keyboard events for F%ld", (long)number);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    CFRelease(source);
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
    BOOL fnHeld = (event.modifierFlags & NSEventModifierFlagFunction) != 0;
    if (self.fnHeld != fnHeld) {
        self.fnHeld = fnHeld;
        if (self.mode == BarModeOff) [self applyMode:NO];
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
        [NSApplication sharedApplication];
        [[NSProcessInfo processInfo] disableAutomaticTermination:@"Touch Bar shortcut and wake monitor"];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        TouchBarController *controller = [TouchBarController new];
        NSApp.delegate = controller;
        [NSApp run];
    }
    return 0;
}
