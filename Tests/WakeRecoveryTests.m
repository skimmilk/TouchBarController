// Exercise the real wake handlers with hardware/UI effects replaced.
#define main TouchBarControllerApplicationMain
#import "../TouchBarController/main.m"
#undef main

static NSMutableArray<NSNumber *> *requests;
static NSUInteger brightnessRestores;
static BOOL hardwareOn;
static BOOL offStuck;
static BOOL powerUnavailable;
static NSUInteger powerReads;
BOOL TouchBarSetBacklight(BOOL on) {
    [requests addObject:@(on)];
    if (on) offStuck = NO;
    if (!offStuck) hardwareOn = on;
    return YES;
}
BOOL TouchBarRestoreBrightness(void) { brightnessRestores++; return YES; }
int TouchBarBacklightPowerState(void) { powerReads++; return powerUnavailable ? -1 : hardwareOn; }

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
static void waitForRecoveryOn(void) {
    for (NSUInteger attempt = 0; attempt < 40; attempt++) {
        runLoopFor(0.05);
        if (snapshot().lastObject.boolValue) return;
    }
    NSCAssert(NO, @"Recovery did not begin");
}

static NSUInteger readCount(void) {
    __block NSUInteger result;
    dispatch_sync(backlightQueue(), ^{ result = powerReads; });
    return result;
}
static void finishWakeForTest(TestController *controller) {
    [controller beginWake:@"one-shot recovery test"];
    [NSObject cancelPreviousPerformRequestsWithTarget:controller];
    [controller reapplyAfterWake];
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

        // A healthy off wake receives one settled hardware check, then no
        // polling or repeated hardware writes while idle.
        drain();
        NSUInteger offCount = snapshot().count;
        NSUInteger reads = readCount();
        runLoopFor(1.0);
        assertOffOnly();
        NSCAssert(snapshot().count == offCount && readCount() == reads + 1,
                  @"A healthy wake did not stop after its one hardware check");
        reads = readCount();
        dispatch_sync(backlightQueue(), ^{ hardwareOn = YES; });
        runLoopFor(0.4);
        NSCAssert(snapshot().count == offCount && readCount() == reads,
                  @"Idle state changes triggered polling or backlight writes");

        // Fn and ordinary off changes only send their requested state.
        controller.fnHeld = YES;
        [controller applyMode:NO];
        drain();
        count = snapshot().count;
        NSCAssert(snapshot().lastObject.boolValue, @"Fn did not show the preview");
        runLoopFor(0.3);
        NSCAssert(snapshot().count == count, @"Idle work blanked the Fn preview");
        controller.fnHeld = NO;
        [controller applyMode:NO];
        drain();
        NSCAssert(!snapshot().lastObject.boolValue, @"Fn release did not turn off");
        count = snapshot().count;
        runLoopFor(0.9);
        NSCAssert(snapshot().count == count && readCount() == reads,
                  @"Ordinary off mode started polling or repeated off writes");
        [controller prepareForSleep];
        drain();
        count = snapshot().count;
        runLoopFor(0.3);
        NSCAssert(snapshot().count == count, @"Hardware work kept running during sleep");

        // Off work queued behind a blocked hardware call must not override a
        // newer on decision.
        clear();
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        dispatch_async(backlightQueue(), ^{
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        });
        dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);
        controller.sleeping = NO;
        controller.mode = BarModeOff;
        [controller applyMode:NO];
        controller.mode = BarModeNormal;
        [controller applyMode:NO];
        dispatch_semaphore_signal(release);
        drain();
        NSCAssert(snapshot().count == 1 && snapshot().lastObject.boolValue,
                  @"Stale off work overrode a newer on decision");
        runLoopFor(0.3);
        NSCAssert(snapshot().count == 1, @"Off retries continued in normal mode");

        // An on request queued before sleep must not execute after that decision.
        clear();
        dispatch_async(backlightQueue(), ^{
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        });
        dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);
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

        // Reproduce the live failure: off returns success, but the hardware
        // stays on until it receives an on -> off transition.
        clear();
        dispatch_sync(backlightQueue(), ^{ hardwareOn = YES; offStuck = YES; });
        controller.mode = BarModeOff;
        finishWakeForTest(controller);
        runLoopFor(0.4);
        assertOffOnly(); // Do not cycle during the initial settling interval.
        runLoopFor(1.7);
        NSUInteger onCount = 0;
        for (NSNumber *on in snapshot()) if (on.boolValue) onCount++;
        NSCAssert(onCount == 1 && !snapshot().lastObject.boolValue,
                  @"Successful-but-ineffective off was not recovered with one on/off transition");
        dispatch_sync(backlightQueue(), ^{
            NSCAssert(!hardwareOn, @"Recovery left the hardware powered");
        });
        NSCAssert(controller.mode == BarModeOff && brightnessRestores == 1,
                  @"Recovery changed the saved mode or restored brightness while off");

        // After recovery and its one verification, leave idle hardware alone.
        clear();
        reads = readCount();
        dispatch_sync(backlightQueue(), ^{ hardwareOn = YES; offStuck = YES; });
        runLoopFor(0.9);
        NSCAssert(snapshot().count == 0 && readCount() == reads, @"Recovery left idle polling active");

        // A user turning on during recovery must cancel its delayed off.
        finishWakeForTest(controller);
        waitForRecoveryOn();
        controller.mode = BarModeNormal;
        [controller applyMode:NO];
        clear();
        runLoopFor(0.9);
        NSCAssert(snapshot().count == 0,
                  @"Recovery turned off a newer visible mode");

        // Sleep must cancel a pending recovery too.
        dispatch_sync(backlightQueue(), ^{ hardwareOn = YES; offStuck = YES; });
        controller.mode = BarModeOff;
        finishWakeForTest(controller);
        waitForRecoveryOn();
        [controller prepareForSleep];
        clear();
        runLoopFor(0.9);
        NSCAssert(snapshot().count == 0,
                  @"Recovery kept running after sleep");

        // Turning on before the wake check must cancel that check entirely.
        dispatch_sync(backlightQueue(), ^{ hardwareOn = YES; offStuck = YES; });
        finishWakeForTest(controller);
        reads = readCount();
        controller.mode = BarModeNormal;
        [controller applyMode:NO];
        clear();
        runLoopFor(0.9);
        NSCAssert(snapshot().count == 0 && readCount() == reads,
                  @"A cancelled wake check still accessed hardware");
        controller.mode = BarModeOff;

        // Unknown hardware state must not trigger a speculative on request.
        controller.sleeping = NO;
        dispatch_sync(backlightQueue(), ^{
            hardwareOn = YES; offStuck = YES; powerUnavailable = YES;
        });
        reads = readCount();
        finishWakeForTest(controller);
        runLoopFor(0.9);
        assertOffOnly();
        NSCAssert(readCount() == reads + 1, @"Unknown driver state caused repeated checks");
        count = snapshot().count;
        runLoopFor(0.6);
        NSCAssert(snapshot().count == count && readCount() == reads + 1,
                  @"Unknown driver state kept polling");
        [controller prepareForSleep];
        puts("Wake recovery tests passed");
    }
    return 0;
}
