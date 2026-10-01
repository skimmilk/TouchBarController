#import "BacklightControl.h"

#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <math.h>
#import <IOKit/IOKitLib.h>
#import <string.h>

static id brightnessClient;
static id systemBrightnessClient;
static NSNumber *savedBrightness;
static BOOL backlightSuppressed;
static BOOL brightnessRestorePending;
static CFStringRef const brightnessPreferences = CFSTR("local.touchbar.controller");
static CFStringRef const brightnessPreferenceKey = CFSTR("SavedTouchBarBrightness");

static id backlightDriverProperty(NSString *key) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"), &iterator) != KERN_SUCCESS) return nil;
    id value = nil;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        io_object_t parent = IO_OBJECT_NULL;
        char parentName[128] = {0};
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
            IORegistryEntryGetName(parent, parentName);
            IOObjectRelease(parent);
        }
        BOOL isTouchBar = strcmp(parentName, "backlight-dfr") == 0;
        if (isTouchBar) {
            value = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key,
                                                                      kCFAllocatorDefault, 0));
        }
        IOObjectRelease(service);
        if (isTouchBar) break;
    }
    IOObjectRelease(iterator);
    return value;
}

int TouchBarBacklightPowerState(void) {
    id power = backlightDriverProperty(@"IOPowerManagement");
    id value = [power isKindOfClass:[NSDictionary class]] ? power[@"CurrentPowerState"] : nil;
    return [value isKindOfClass:[NSNumber class]] ? [value intValue] : -1;
}

double TouchBarBacklightNits(void) {
    id value = backlightDriverProperty(@"CurrentNits");
    if (![value isKindOfClass:[NSNumber class]]) return -1;
    double nits = [value doubleValue];
    return isfinite(nits) && nits >= 0 ? nits : -1;
}

static id coreBrightnessClient(void) {
    if (systemBrightnessClient) return systemBrightnessClient;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) {
            Class cls = objc_getClass("BrightnessSystemClient");
            if (cls) systemBrightnessClient = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(new));
        }
    });
    return systemBrightnessClient;
}

static BOOL validBrightness(id value) {
    return [value isKindOfClass:[NSNumber class]] && isfinite([value doubleValue]) &&
        [value doubleValue] >= 0.0 && [value doubleValue] <= 1.0;
}

static NSInteger currentDisplayState(void) {
    // displayState returns a cached default in a freshly created client, even
    // when the service is off. Read the service property for CLI invocations.
    SEL get = sel_registerName("copyPropertyForKey:");
    if (![brightnessClient respondsToSelector:get]) return -1;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(brightnessClient, get, @"DFRDisplayState");
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : -1;
}

static void rememberBrightness(void) {
    // Retries must not replace the saved level with the off state's zero.
    if (backlightSuppressed || brightnessRestorePending) return;
    if (!savedBrightness) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(brightnessPreferenceKey, brightnessPreferences));
        if (validBrightness(value)) savedBrightness = value;
    }
    if (currentDisplayState() != 2) return;
    id client = coreBrightnessClient();
    SEL get = sel_registerName("copyPropertyForKey:andDisplay:");
    if (![client respondsToSelector:get]) return;
    int displayID = ((int (*)(id, SEL))objc_msgSend)(brightnessClient, sel_registerName("getDFRDisplayID"));
    id properties = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(client, get, @"DisplayBrightness", displayID);
    id value = [properties isKindOfClass:[NSDictionary class]] ? properties[@"Brightness"] : nil;
    if (!validBrightness(value)) return;
    savedBrightness = value;
    CFPreferencesSetAppValue(brightnessPreferenceKey, (__bridge CFPropertyListRef)value, brightnessPreferences);
    CFPreferencesAppSynchronize(brightnessPreferences);
}

BOOL TouchBarRestoreBrightness(void) {
    if (!brightnessRestorePending) return YES;
    if (currentDisplayState() != 2) return NO;
    id client = coreBrightnessClient();
    SEL set = sel_registerName("setProperty:withKey:andDisplay:");
    if (!savedBrightness || ![client respondsToSelector:set]) return NO;
    int displayID = ((int (*)(id, SEL))objc_msgSend)(brightnessClient, sel_registerName("getDFRDisplayID"));
    // Transient commit preserves ambient-light policy instead of saving a new
    // user brightness preference. macOS resumes its own brightness adjustments.
    NSDictionary *properties = @{@"Brightness": savedBrightness, @"Commit": @NO, @"CommitType": @0};
    BOOL success = ((BOOL (*)(id, SEL, id, id, uint64_t))objc_msgSend)(client, set, properties, @"DisplayBrightness", displayID);
    if (success) brightnessRestorePending = NO;
    return success;
}

static id createBrightnessClient(void) {
    static dispatch_once_t once;
    static BOOL frameworkAvailable;
    dispatch_once(&once, ^{
        frameworkAvailable = dlopen("/System/Library/PrivateFrameworks/DFRBrightness.framework/DFRBrightness", RTLD_LAZY) != NULL;
    });
    if (!frameworkAvailable) return nil;

    Class cls = objc_getClass("DFRBrightnessClient");
    if (!cls) return nil;
    IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFArrayRef services = system ? IOHIDEventSystemClientCopyServices(system) : NULL;
    if (!services) {
        if (system) CFRelease(system);
        return nil;
    }

    id client = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(new));
    BOOL ready = NO;
    if (client && ((BOOL (*)(id, SEL))objc_msgSend)(client, sel_registerName("initializeHID"))) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            BOOL isTouchBar = product && [(__bridge NSString *)product isEqualToString:@"TouchBarUserDevice"];
            if (product) CFRelease(product);
            if (!isTouchBar) continue;
            BOOL added = ((BOOL (*)(id, SEL, IOHIDServiceClientRef))objc_msgSend)(client, sel_registerName("addDFRService:"), service);
            int displayID = ((int (*)(id, SEL))objc_msgSend)(client, sel_registerName("getDFRDisplayID"));
            ready = added && displayID >= 0;
            break;
        }
    }
    CFRelease(services);
    CFRelease(system);
    return ready ? client : nil;
}

NSDictionary<NSString *, id> *TouchBarBrightnessDiagnostics(void) {
    NSMutableDictionary *values = [NSMutableDictionary new];
    values[@"driver.IODisplayParameters"] = backlightDriverProperty(@"IODisplayParameters") ?: [NSNull null];
    id saved = CFBridgingRelease(CFPreferencesCopyAppValue(brightnessPreferenceKey, brightnessPreferences));
    values[@"saved_restore_brightness"] = validBrightness(saved) ? saved : [NSNull null];

    id dfr = brightnessClient ?: createBrightnessClient();
    SEL getDFR = sel_registerName("copyPropertyForKey:");
    values[@"dfr.DFRDisplayState"] = [dfr respondsToSelector:getDFR]
        ? ((id (*)(id, SEL, id))objc_msgSend)(dfr, getDFR, @"DFRDisplayState") ?: [NSNull null] : [NSNull null];
    SEL getStep = sel_registerName("getDimmingStep");
    values[@"dfr.cached_dimming_step"] = [dfr respondsToSelector:getStep]
        ? @(((NSInteger (*)(id, SEL))objc_msgSend)(dfr, getStep)) : [NSNull null];
    SEL getID = sel_registerName("getDFRDisplayID");
    int displayID = [dfr respondsToSelector:getID] ? ((int (*)(id, SEL))objc_msgSend)(dfr, getID) : -1;
    values[@"display_id"] = displayID >= 0 ? @(displayID) : [NSNull null];

    id core = coreBrightnessClient();
    SEL getCore = sel_registerName("copyPropertyForKey:andDisplay:");
    BOOL available = displayID >= 0 && [core respondsToSelector:getCore];
    for (NSString *key in @[@"DisplayBrightness", @"DisplayBrightnessFactor", @"DisplayBrightnessAuto",
                            @"BrightnessGlobalScalar", @"VirtualBrightnessLimits", @"MaxBrightness",
                            @"FreezeBrightness", @"BrightnessRestrictions", @"DisplayPanelLuminanceMin",
                            @"DisplayPanelLuminanceMid", @"DisplayPanelLuminanceMax",
                            @"DisplayProductLuminanceMin", @"DisplayProductLuminanceMid", @"DisplayProductLuminanceMax"]) {
        id value = available ? ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(core, getCore, key, displayID) : nil;
        values[[@"corebrightness." stringByAppendingString:key]] = value ?: [NSNull null];
    }
    id status = available ? ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(core, getCore, @"StatusInfo", displayID) : nil;
    for (NSString *key in @[@"AutoBrightness", @"BrightnessControlCapabilities", @"Display"]) {
        id value = [status isKindOfClass:[NSDictionary class]] ? status[key] : nil;
        values[[@"corebrightness.StatusInfo." stringByAppendingString:key]] = value ?: [NSNull null];
    }
    return values;
}

BOOL TouchBarSetBacklight(BOOL on) {
    if (!brightnessClient) brightnessClient = createBrightnessClient();
    if (!brightnessClient) return NO;

    if (!on) {
        rememberBrightness();
        backlightSuppressed = YES;
        brightnessRestorePending = NO;
    } else {
        // A separately invoked CLI can load the snapshot saved by off/the app.
        if (!savedBrightness) {
            id value = CFBridgingRelease(CFPreferencesCopyAppValue(brightnessPreferenceKey, brightnessPreferences));
            if (validBrightness(value)) savedBrightness = value;
        }
        NSInteger state = currentDisplayState();
        BOOL wasOff = state >= 0 && state != 2;
        if (savedBrightness && (backlightSuppressed || wasOff)) brightnessRestorePending = YES;
    }

    // turnOff uses a 0.5-second fade on the tested macOS build. Retrying that
    // method during wake is not an immediate off request.
    // Keep the original turnOn fade; restore its brightness separately afterward.
    SEL action = sel_registerName(on ? "turnOn" : "turnOffWithPeriod:");
    if (![brightnessClient respondsToSelector:action]) return NO;
    BOOL success = on ? ((BOOL (*)(id, SEL))objc_msgSend)(brightnessClient, action)
        : ((BOOL (*)(id, SEL, float))objc_msgSend)(brightnessClient, action, 0.0f);
    if (success) {
        if (on) backlightSuppressed = NO;
        return YES;
    }

    // A client created before sleep may hold an invalid HID service after wake.
    brightnessClient = createBrightnessClient();
    if (!brightnessClient || ![brightnessClient respondsToSelector:action]) return NO;
    success = on ? ((BOOL (*)(id, SEL))objc_msgSend)(brightnessClient, action)
        : ((BOOL (*)(id, SEL, float))objc_msgSend)(brightnessClient, action, 0.0f);
    if (success && on) backlightSuppressed = NO;
    return success;
}
