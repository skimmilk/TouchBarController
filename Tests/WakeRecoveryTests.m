// Exercise the real wake handlers with hardware/UI effects replaced.
#define main TouchBarControllerApplicationMain
#import "../TouchBarController/main.m"
#undef main

static NSMutableArray<NSNumber *> *requests;
static NSUInteger brightnessRestores;
BOOL TouchBarSetBacklight(BOOL on) {
    [requests addObject:@(on)];
    return YES;
}
BOOL TouchBarRestoreBrightness(void) { brightnessRestores++; return YES; }

@interface TestController : TouchBarController
@end
@implementation TestController
- (void)saveMode {}
- (void)restoreSystemPresentationMode {}
- (void)showSystemFunctionKeys {}
- (void)presentBar:(NSTouchBar *)bar force:(BOOL)force { (void)bar; (void)force; }
- (void)rebuildEventMonitors {}
@end

static void drain(void) { dispatch_sync(backlightQueue(), ^{}); }
static void clear(void) { dispatch_sync(backlightQueue(), ^{ [requests removeAllObjects]; }); }
static NSArray<NSNumber *> *snapshot(void) {
    __block NSArray<NSNumber *> *result;
    dispatch_sync(backlightQueue(), ^{ result = [requests copy]; });
    return result;
}
static void assertOffOnly(void) {
    for (NSNumber *on in snapshot()) NSCAssert(!on.boolValue, @"Unexpected on request");
}
static void runLoopFor(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    drain();
}

int main(void) {
    @autoreleasepool {
        requests = [NSMutableArray new];
        TestController *controller = [TestController new];
        controller.mode = BarModeNormal;
        [controller beginWake:@"test"];
        uint64_t cycle = controller.wakeCycle;
        controller.fnHeld = YES;
        [controller applyMode:NO];
        [controller toggleOption];
        runLoopFor(0.03);
        assertOffOnly();
        NSCAssert(snapshot().count >= 2, @"Off retries did not run");
        runLoopFor(0.55);
        NSUInteger earlyCount = snapshot().count;
        runLoopFor(0.15);
        NSCAssert(snapshot().count > earlyCount, @"Off retries stopped before restoration");
        [controller beginWake:@"second signal"];
        NSCAssert(controller.wakeCycle == cycle, @"Duplicate wake created another cycle");
        [NSObject cancelPreviousPerformRequestsWithTarget:controller];
        [controller reapplyAfterWake];
        drain();
        NSUInteger count = snapshot().count;
        NSCAssert(snapshot().lastObject.boolValue, @"Visible mode was not restored");
        runLoopFor(0.08);
        NSCAssert(snapshot().count == count, @"A stale retry ran after restoration");

        clear();
        [controller beginWake:@"rapid sleep"];
        [controller prepareForSleep];
        [controller toggleCommand];
        runLoopFor(2.1);
        assertOffOnly();
        NSCAssert(brightnessRestores == 0, @"Sleep did not cancel delayed brightness restoration");
        NSCAssert(controller.sleeping && !controller.wakeRecoveryPending && !controller.wakeRetryTimer,
                  @"Sleep did not cancel recovery");
        clear();
        [controller beginWake:@"next wake"];
        NSCAssert(controller.wakeCycle == cycle + 2, @"Next sleep/wake reused the old cycle");
        [NSObject cancelPreviousPerformRequestsWithTarget:controller];
        [controller reapplyAfterWake];
        assertOffOnly(); // Command changed the saved mode to off during sleep.

        // An on request queued before sleep must not execute after that decision.
        clear();
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        dispatch_async(backlightQueue(), ^{
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        });
        dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);
        controller.mode = BarModeNormal;
        [controller applyMode:NO];
        [controller prepareForSleep];
        dispatch_semaphore_signal(release);
        assertOffOnly();
        NSCAssert(snapshot().count == 1, @"Stale on request was not discarded");
        [controller beginWake:@"brightness restoration"];
        [NSObject cancelPreviousPerformRequestsWithTarget:controller];
        [controller reapplyAfterWake];
        runLoopFor(0.8);
        NSCAssert(brightnessRestores == 1, @"Brightness was not restored after the on fade");
        puts("Wake recovery tests passed");
    }
    return 0;
}
