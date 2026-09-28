#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <IOKit/IOKitLib.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

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

static void setBacklight(BOOL on) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("local.touchbar.backlight", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        NSString *tool = [[[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"touchbarctl"];
        const char *path = tool.fileSystemRepresentation;
        pid_t child = 0;
        char *const arguments[] = {(char *)path, on ? "on" : "off", NULL};
        int spawnResult = posix_spawn(&child, path, NULL, NULL, arguments, environ);
        if (spawnResult != 0) {
            NSLog(@"Could not run touchbarctl: %d", spawnResult);
            return;
        }
        int status = 0;
        if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            NSLog(@"touchbarctl failed for %@", on ? @"on" : @"off");
        }
    });
}

static NSInteger backlightPowerState(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"), &iterator) != KERN_SUCCESS) return -1;
    NSInteger state = -1;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        io_object_t parent = IO_OBJECT_NULL;
        char parentName[128] = {0};
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
            IORegistryEntryGetName(parent, parentName);
            IOObjectRelease(parent);
        }
        if (strcmp(parentName, "backlight-dfr") == 0) {
            CFTypeRef power = IORegistryEntryCreateCFProperty(service, CFSTR("IOPowerManagement"), kCFAllocatorDefault, 0);
            if (power && CFGetTypeID(power) == CFDictionaryGetTypeID()) {
                CFTypeRef value = CFDictionaryGetValue(power, CFSTR("CurrentPowerState"));
                if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                    CFNumberGetValue(value, kCFNumberNSIntegerType, &state);
                }
            }
            if (power) CFRelease(power);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return state;
}

@interface TouchBarController : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@property (strong) NSTouchBar *blankBar;
@property (strong) NSTouchBar *functionBar;
@property (strong) NSTouchBar *currentBar;
@property BarMode mode;
@property BarMode priorVisibleMode;
@property BOOL wakeRecoveryPending;
@property GestureDetector gestures;
@property (strong) id globalMonitor;
@property (strong) id localMonitor;
- (void)handleKeyboardEvent:(NSEvent *)event;
@end

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
    [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(periodicCheck:)
                                  userInfo:nil repeats:YES];
    NSLog(@"TouchBarController running; mode=%ld", (long)self.mode);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
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
    switch (self.mode) {
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
    NSLog(@"Touch Bar mode=%ld", (long)self.mode);
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
    NSLog(@"Wake notification received");
    GestureDetectorReset(&_gestures);
    self.wakeRecoveryPending = YES;
    setBacklight(NO);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reapplyAfterWake) object:nil];
    [self performSelector:@selector(rebuildEventMonitors) withObject:nil afterDelay:0.5];
    [self performSelector:@selector(rebuildEventMonitors) withObject:nil afterDelay:2.0];
    [self performSelector:@selector(reapplyAfterWake) withObject:nil afterDelay:2.0];
}

- (void)sessionBecameActive:(NSNotification *)notification {
    (void)notification;
    GestureDetectorReset(&_gestures);
    [self performSelector:@selector(rebuildEventMonitors) withObject:nil afterDelay:0.5];
}

- (void)reapplyAfterWake {
    self.wakeRecoveryPending = NO;
    [self applyMode:YES];
}

- (void)periodicCheck:(NSTimer *)timer {
    (void)timer;
    if (!self.globalMonitor || !self.localMonitor) [self rebuildEventMonitors];
    if (self.mode == BarModeOff && backlightPowerState() != 0) {
        NSLog(@"Touch Bar backlight was re-enabled; switching it off again");
        setBacklight(NO);
    }
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
