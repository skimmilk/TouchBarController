#import <Foundation/Foundation.h>

// Calls must be serialized when used by a long-running process.
BOOL TouchBarSetBacklight(BOOL on);

// Call after the turnOn fade (at least 0.5 seconds), on the same serial queue.
// A subsequent off request invalidates the pending restoration.
BOOL TouchBarRestoreBrightness(void);
