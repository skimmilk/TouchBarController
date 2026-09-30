#import <Foundation/Foundation.h>

// Replace preference storage and both private clients; no hardware or user
// preferences are changed by this test.
static NSNumber *storedLevel;
static CFPropertyListRef testCopy(CFStringRef key, CFStringRef app) {
    (void)key; (void)app;
    return CFBridgingRetain(storedLevel);
}
static void testSet(CFStringRef key, CFPropertyListRef value, CFStringRef app) {
    (void)key; (void)app;
    storedLevel = (__bridge NSNumber *)value;
}
static Boolean testSync(CFStringRef app) { (void)app; return true; }
#define CFPreferencesCopyAppValue testCopy
#define CFPreferencesSetAppValue testSet
#define CFPreferencesAppSynchronize testSync
#import "../CLI/BacklightControl.m"

@interface FakeSystemBrightness : NSObject
@property NSNumber *level;
@property NSDictionary *lastWrite;
@end
@implementation FakeSystemBrightness
- (id)copyPropertyForKey:(NSString *)key andDisplay:(uint64_t)display {
    NSCAssert([key isEqualToString:@"DisplayBrightness"] && display == 3, @"Wrong display/property");
    return @{@"Brightness": self.level};
}
- (BOOL)setProperty:(NSDictionary *)value withKey:(NSString *)key andDisplay:(uint64_t)display {
    NSCAssert([key isEqualToString:@"DisplayBrightness"] && display == 3, @"Wrong display/property");
    self.lastWrite = value;
    self.level = value[@"Brightness"];
    return YES;
}
@end

@interface FakeDFRBrightness : NSObject
@property NSInteger state;
@property FakeSystemBrightness *system;
@end
@implementation FakeDFRBrightness
- (NSInteger)displayState { return 2; } // Reproduce the fresh client's stale cache.
- (id)copyPropertyForKey:(NSString *)key {
    NSCAssert([key isEqualToString:@"DFRDisplayState"], @"Wrong state property");
    return @(self.state);
}
- (int)getDFRDisplayID { return 3; }
- (BOOL)turnOffWithPeriod:(float)period {
    NSCAssert(period == 0.0f, @"Off must be immediate");
    self.state = 1;
    self.system.level = @0; // Reproduce the observed loss of brightness.
    return YES;
}
- (BOOL)turnOn { self.state = 2; return YES; }
@end

int main(void) {
    @autoreleasepool {
        FakeSystemBrightness *system = [FakeSystemBrightness new];
        FakeDFRBrightness *dfr = [FakeDFRBrightness new];
        system.level = @0.274;
        dfr.state = 2;
        dfr.system = system;
        systemBrightnessClient = system;
        brightnessClient = dfr;
        NSCAssert(TouchBarSetBacklight(NO) && TouchBarSetBacklight(NO), @"Off failed");
        NSCAssert([storedLevel isEqual:@0.274], @"Retries overwrote the snapshot with zero");
        NSCAssert(TouchBarSetBacklight(YES) && TouchBarRestoreBrightness(), @"Restore failed");
        NSCAssert([system.level isEqual:@0.274], @"Brightness was not preserved");
        NSCAssert([system.lastWrite[@"Commit"] isEqual:@NO] && [system.lastWrite[@"CommitType"] isEqual:@0],
                  @"Restore must use a transient commit");

        NSCAssert(TouchBarSetBacklight(NO), @"Off failed");
        savedBrightness = nil; // A new CLI invocation loads the stored snapshot.
        backlightSuppressed = NO;
        NSCAssert(TouchBarSetBacklight(YES) && TouchBarRestoreBrightness(), @"Stored restore failed");
        NSCAssert([system.level isEqual:@0.274], @"Stored snapshot was lost");
        NSCAssert(TouchBarSetBacklight(NO) && TouchBarSetBacklight(YES) && TouchBarSetBacklight(NO), @"Rapid toggle failed");
        NSCAssert(TouchBarRestoreBrightness() && [system.level isEqual:@0], @"Stale restore illuminated off state");
        NSCAssert(TouchBarSetBacklight(YES) && TouchBarRestoreBrightness() && [system.level isEqual:@0.274],
                  @"Rapid off during the on fade overwrote the snapshot");

        dfr.state = 2;
        backlightSuppressed = NO;
        system.level = @0;
        NSCAssert(TouchBarSetBacklight(NO) && TouchBarSetBacklight(YES) && TouchBarRestoreBrightness(), @"Minimum restore failed");
        NSCAssert([savedBrightness isEqual:@0] && [system.level isEqual:@0], @"Valid minimum brightness was rejected");
        puts("Brightness restoration tests passed");
    }
    return 0;
}
