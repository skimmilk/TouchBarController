#import "BacklightControl.h"

#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <dlfcn.h>
#import <objc/message.h>

static id brightnessClient;

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

BOOL TouchBarSetBacklight(BOOL on) {
    if (!brightnessClient) brightnessClient = createBrightnessClient();
    if (!brightnessClient) return NO;

    SEL action = sel_registerName(on ? "turnOn" : "turnOff");
    if (((BOOL (*)(id, SEL))objc_msgSend)(brightnessClient, action)) return YES;

    // A client created before sleep may hold an invalid HID service after wake.
    brightnessClient = createBrightnessClient();
    return brightnessClient && ((BOOL (*)(id, SEL))objc_msgSend)(brightnessClient, action);
}
