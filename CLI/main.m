#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <stdio.h>
#import <string.h>

#import "BacklightControl.h"

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

static BOOL diagnoseDisplay(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator) != KERN_SUCCESS) return NO;
    BOOL found = NO;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef dfr = IORegistryEntryCreateCFProperty(service, CFSTR("dfr"), kCFAllocatorDefault, 0);
        BOOL isTouchBar = dfr && CFEqual(dfr, kCFBooleanTrue);
        if (dfr) CFRelease(dfr);
        if (isTouchBar) {
            found = YES;
            io_name_t name = {0};
            IORegistryEntryGetName(service, name);
            printf("framebuffer=%s\n", name);
            for (NSString *key in @[@"IOPowerManagement", @"IdleState", @"DisplayIsIdle"]) {
                id value = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
                printf("%s=%s\n", key.UTF8String, value ? [[value description] UTF8String] : "unavailable");
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "on") != 0 && strcmp(argv[1], "off") != 0 && strcmp(argv[1], "status") != 0 && strcmp(argv[1], "diagnose") != 0)) {
            fprintf(stderr, "usage: touchbarctl {on|off|status|diagnose}\n");
            return 2;
        }
        if (strcmp(argv[1], "diagnose") == 0) {
            int state = backlightPowerState();
            printf("backlight=%s\n", state < 0 ? "unavailable" : state == 0 ? "off" : "on");
            BOOL found = diagnoseDisplay();
            if (!found) fprintf(stderr, "Touch Bar framebuffer status is unavailable\n");
            puts("These are driver states; they do not establish whether the panel is working.");
            return state >= 0 && found ? 0 : 1;
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
        if (!TouchBarSetBacklight(on)) {
            fprintf(stderr, "Could not turn the Touch Bar backlight %s\n", on ? "on" : "off");
            return 1;
        }
        if (on) {
            [NSThread sleepForTimeInterval:0.7];
            if (!TouchBarRestoreBrightness()) {
                fprintf(stderr, "Could not restore the Touch Bar brightness\n");
                return 1;
            }
        }
        return 0;
    }
}
