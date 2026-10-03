// Exercise the real Fn event filter without installing a global event tap.
#define main TouchBarControllerApplicationMain
#import "../TouchBarController/main.m"
#undef main

static NSMutableArray<NSNumber *> *requests;
BOOL TouchBarSetBacklight(BOOL on) { [requests addObject:@(on)]; return YES; }
BOOL TouchBarRestoreBrightness(void) { return YES; }
int TouchBarBacklightPowerState(void) { return 0; }

@interface MemoryDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation MemoryDefaults
- (instancetype)init { self = [super init]; if (self) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (BOOL)synchronize { return YES; }
@end

@interface FnTestController : TouchBarController
@property BarMode savedMode;
@property BOOL functionPresentation;
@property BOOL permissionGranted;
@property NSUInteger filterInstallAttempts;
@property BOOL nativeFnSuppressed;
@property NSDictionary *testNativeFnModes;
@property MemoryDefaults *testDefaults;
@end
@implementation FnTestController
- (void)installFnEventTap { self.filterInstallAttempts++; }
- (BOOL)fnEventFilterPermissionGranted { return self.permissionGranted; }
- (instancetype)init {
    self = [super init];
    if (self) _testDefaults = [MemoryDefaults new];
    return self;
}
- (NSUserDefaults *)fnModeDefaults { return self.testDefaults; }
- (NSDictionary *)nativeFnModes { return self.testNativeFnModes; }
- (BOOL)setNativeFnModes:(NSDictionary *)modes {
    self.testNativeFnModes = [modes copy];
    self.nativeFnSuppressed = [modes isEqual:unchangedFnModes()];
    return YES;
}
- (void)saveMode { self.savedMode = self.mode; }
- (void)restoreSystemPresentationMode { self.functionPresentation = NO; }
- (void)showSystemFunctionKeys { self.functionPresentation = YES; }
- (void)presentBar:(NSTouchBar *)bar force:(BOOL)force { (void)bar; (void)force; }
- (void)rebuildEventMonitors {}
@end

static void settle(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    dispatch_sync(backlightQueue(), ^{});
}

static BOOL sendEvent(FnTestController *controller, CGEventType type,
                      CGKeyCode key, CGEventFlags flags, CGEventFlags *resultFlags) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, key, type != kCGEventKeyUp);
    CGEventSetType(event, type);
    CGEventSetFlags(event, flags);
    CGEventRef result = [controller filterFnEvent:event type:type];
    if (resultFlags) *resultFlags = CGEventGetFlags(event);
    BOOL passed = result != NULL;
    CFRelease(event);
    return passed;
}

static BOOL fn(FnTestController *controller, BOOL down) {
    return sendEvent(controller, kCGEventFlagsChanged, kVK_Function,
                     down ? kCGEventFlagMaskSecondaryFn : 0, NULL);
}

int main(void) {
    @autoreleasepool {
        requests = [NSMutableArray new];
        FnTestController *controller = [FnTestController new];
        NSDictionary *originalFnModes = @{@"appWithControlStrip": @"functionKeys",
                                          @"extraSetting": @"preserved"};
        controller.testNativeFnModes = originalFnModes;
        for (BarMode visible = BarModeNormal; visible <= BarModeFunctions; visible++) {
            controller.mode = BarModeOff;
            controller.priorVisibleMode = visible;
            [controller applyMode:NO];
            settle();
            NSCAssert(controller.nativeFnSuppressed, @"Off mode left native Fn switching active");
            NSCAssert(!fn(controller, YES), @"Wake Fn press reached macOS");
            settle();
            NSCAssert(controller.mode == BarModeOff && controller.savedMode == BarModeOff,
                      @"Fn preview changed the saved off mode");
            NSCAssert(controller.functionPresentation == (visible == BarModeFunctions),
                      @"Fn wake showed the wrong controls");
            NSCAssert(requests.lastObject.boolValue, @"Fn did not turn on the backlight");
            NSCAssert(controller.nativeFnSuppressed, @"Native Fn suppression ended before release");
            NSCAssert([[controller.testDefaults objectForKey:kSavedSystemFnModesKey] isEqual:originalFnModes],
                      @"Native Fn settings were not saved exactly");
            NSUInteger count = requests.count;
            NSCAssert(!fn(controller, YES), @"Repeated wake Fn press was not consumed");

            CGEventFlags resultFlags = 0;
            NSCAssert(sendEvent(controller, kCGEventFlagsChanged, kVK_Shift,
                                kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskShift, &resultFlags),
                      @"Wake Fn swallowed another modifier");
            NSCAssert(resultFlags == kCGEventFlagMaskShift, @"Fn leaked into another modifier event");
            NSCAssert(sendEvent(controller, kCGEventKeyDown, kVK_ANSI_A,
                                kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskShift, &resultFlags),
                      @"Wake Fn swallowed a key");
            NSCAssert(resultFlags == kCGEventFlagMaskShift, @"Fn leaked into a key down");
            NSCAssert(sendEvent(controller, kCGEventKeyUp, kVK_ANSI_A,
                                kCGEventFlagMaskSecondaryFn, &resultFlags) && resultFlags == 0,
                      @"Fn leaked into a key up");
            NSCAssert(!fn(controller, NO), @"Wake Fn release reached macOS");
            settle();
            NSCAssert(controller.mode == BarModeOff && requests.count == count + 1 &&
                      !requests.lastObject.boolValue, @"Fn release did not turn off the preview");
            NSCAssert(controller.nativeFnSuppressed, @"Off mode lost native Fn suppression");

            [controller toggleCommand];
            settle();
            NSCAssert(controller.mode == visible && !controller.nativeFnSuppressed,
                      @"Turning on did not restore normal Fn behavior");
            NSCAssert([controller.testNativeFnModes isEqual:originalFnModes],
                      @"Native Fn settings were not restored exactly");

            count = requests.count;
            NSCAssert(fn(controller, YES), @"Fn while on did not pass through");
            NSCAssert(sendEvent(controller, kCGEventKeyDown, kVK_ANSI_A,
                                kCGEventFlagMaskSecondaryFn, &resultFlags) &&
                      resultFlags == kCGEventFlagMaskSecondaryFn,
                      @"Normal Fn modifier was changed");
            NSCAssert(fn(controller, NO), @"Later Fn release did not pass through");
            settle();
            NSCAssert(requests.count == count, @"Normal Fn changed the backlight");

            [controller toggleCommand];
            settle();
            NSCAssert(controller.mode == BarModeOff && !requests.lastObject.boolValue,
                      @"Command could not turn off after Fn wake");
        }

        // Function flags on other keys (such as arrows) cannot wake the bar.
        NSCAssert(sendEvent(controller, kCGEventKeyDown, kVK_LeftArrow,
                            kCGEventFlagMaskSecondaryFn, NULL), @"Arrow was swallowed");
        settle();
        NSCAssert(controller.mode == BarModeOff, @"Arrow woke the bar");

        // The NSEvent fallback also turns the preview off on release when macOS
        // denies the event filter, although it cannot consume the native Fn.
        controller.permissionGranted = YES; // Granted after startup failed.
        for (NSUInteger down = 1; ; down = 0) {
            NSEvent *event = [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                location:NSZeroPoint modifierFlags:down ? NSEventModifierFlagFunction : 0
                timestamp:1 windowNumber:0 context:nil characters:@""
                charactersIgnoringModifiers:@"" isARepeat:NO keyCode:kVK_Function];
            [controller handleKeyboardEvent:event];
            settle();
            NSCAssert(controller.filterInstallAttempts == (down ? 0 : 1),
                      @"Permission retry did not wait for the complete Fn press");
            if (!down) break;
        }
        NSCAssert(controller.mode == BarModeOff && !requests.lastObject.boolValue,
                  @"Fallback Fn release left the preview on");

        // A Fn press released during recovery leaves the saved mode off and
        // never interrupts the dark interval.
        [controller prepareForSleep];
        controller.mode = BarModeOff;
        controller.priorVisibleMode = BarModeFunctions;
        [controller beginWake:@"Fn recovery test"];
        [NSObject cancelPreviousPerformRequestsWithTarget:controller];
        dispatch_sync(backlightQueue(), ^{ [requests removeAllObjects]; });
        NSCAssert(!fn(controller, YES), @"Recovery wake Fn was not consumed");
        NSCAssert(!fn(controller, NO), @"Recovery wake Fn release was not consumed");
        settle();
        __block NSArray<NSNumber *> *recoveryRequests;
        dispatch_sync(backlightQueue(), ^{ recoveryRequests = [requests copy]; });
        for (NSNumber *on in recoveryRequests) NSCAssert(!on.boolValue, @"Fn interrupted wake recovery");
        NSCAssert(controller.savedMode == BarModeOff, @"Recovery changed the saved off mode");
        [controller reapplyAfterWake];
        settle();
        NSCAssert(!requests.lastObject.boolValue, @"A released Fn preview reappeared after recovery");

        // A preview still held when recovery completes must stay visible until
        // release, without the off recovery check blanking it.
        [controller beginWake:@"held Fn recovery test"];
        [NSObject cancelPreviousPerformRequestsWithTarget:controller];
        NSCAssert(!fn(controller, YES), @"Held recovery Fn was not consumed");
        [controller reapplyAfterWake];
        settle();
        NSCAssert(controller.functionPresentation && requests.lastObject.boolValue,
                  @"Held Fn preview was not restored after recovery");
        NSCAssert(!fn(controller, NO), @"Held recovery Fn release was not consumed");
        settle();
        NSCAssert(!requests.lastObject.boolValue, @"Held recovery preview stayed on after release");

        [controller prepareForSleep];
        NSCAssert(!controller.fnHeld && !controller.suppressFnPress, @"Sleep retained Fn state");

        controller.sleeping = NO;
        controller.mode = BarModeOff;
        [controller applyMode:NO];
        NSDictionary *externalChange = @{@"appWithControlStrip": @"spaces"};
        controller.testNativeFnModes = externalChange;
        controller.mode = BarModeNormal;
        [controller applyMode:NO];
        NSCAssert([controller.testNativeFnModes isEqual:externalChange],
                  @"Restoration overwrote an independent System Settings change");

        controller.mode = BarModeOff;
        [controller applyMode:NO];
        NSDictionary *changeBeforeFn = @{@"appWithControlStrip": @"workflows"};
        controller.testNativeFnModes = changeBeforeFn;
        [controller handleFnDown:YES];
        settle();
        [controller handleFnDown:NO];
        settle();
        [controller toggleCommand];
        settle();
        NSCAssert([controller.testNativeFnModes isEqual:changeBeforeFn],
                  @"Fn wake overwrote a setting edited while off");

        controller.testNativeFnModes = nil;
        controller.mode = BarModeOff;
        [controller applyMode:NO];
        controller.mode = BarModeNormal;
        [controller applyMode:NO];
        NSCAssert(!controller.testNativeFnModes, @"Originally unset Fn settings were not removed");

        controller.testNativeFnModes = originalFnModes;
        controller.mode = BarModeOff;
        [controller applyMode:NO];
        FnTestController *restarted = [FnTestController new];
        restarted.testDefaults = controller.testDefaults;
        restarted.testNativeFnModes = controller.testNativeFnModes;
        restarted.mode = BarModeNormal;
        [restarted applyMode:NO];
        NSCAssert([restarted.testNativeFnModes isEqual:originalFnModes] &&
                  ![restarted.testDefaults objectForKey:kSavedSystemFnModesKey],
                  @"A restart lost the original native Fn settings");
        [controller prepareForSleep];
        [restarted prepareForSleep];
        puts("Fn wake tests passed");
    }
    return 0;
}
