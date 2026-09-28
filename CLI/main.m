#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <stdio.h>
#import <string.h>

static int backlightPowerState(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"), &iterator) != KERN_SUCCESS) return -1;
    int state = -1;
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
                    CFNumberGetValue(value, kCFNumberIntType, &state);
                }
            }
            if (power) CFRelease(power);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return state;
}

static BOOL setBacklight(BOOL on) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/DFRBrightness.framework/DFRBrightness", RTLD_LAZY);
    if (!framework) return NO;
    Class cls = objc_getClass("DFRBrightnessClient");
    if (!cls) return NO;
    IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFArrayRef services = system ? IOHIDEventSystemClientCopyServices(system) : NULL;
    if (!services) {
        if (system) CFRelease(system);
        return NO;
    }
    id client = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(new));
    BOOL result = NO;
    if (((BOOL (*)(id, SEL))objc_msgSend)(client, sel_registerName("initializeHID"))) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            BOOL isTouchBar = product && [(__bridge NSString *)product isEqualToString:@"TouchBarUserDevice"];
            if (product) CFRelease(product);
            if (!isTouchBar) continue;
            BOOL added = ((BOOL (*)(id, SEL, IOHIDServiceClientRef))objc_msgSend)(client, sel_registerName("addDFRService:"), service);
            int displayID = ((int (*)(id, SEL))objc_msgSend)(client, sel_registerName("getDFRDisplayID"));
            if (added && displayID >= 0) {
                SEL action = sel_registerName(on ? "turnOn" : "turnOff");
                result = ((BOOL (*)(id, SEL))objc_msgSend)(client, action);
            }
            break;
        }
    }
    CFRelease(services);
    CFRelease(system);
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "on") != 0 && strcmp(argv[1], "off") != 0 && strcmp(argv[1], "status") != 0)) {
            fprintf(stderr, "usage: touchbarctl {on|off|status}\n");
            return 2;
        }
        if (strcmp(argv[1], "status") == 0) {
            int state = backlightPowerState();
            if (state < 0) {
                fprintf(stderr, "Touch Bar backlight status is unavailable\n");
                return 1;
            }
            puts(state == 0 ? "off" : "on");
            return 0;
        }
        BOOL on = strcmp(argv[1], "on") == 0;
        if (!setBacklight(on)) {
            fprintf(stderr, "Could not turn the Touch Bar backlight %s\n", on ? "on" : "off");
            return 1;
        }
        return 0;
    }
}
