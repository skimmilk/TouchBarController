#import <Foundation/Foundation.h>

// Calls must be serialized when used by a long-running process.
BOOL TouchBarSetBacklight(BOOL on);

// Hardware driver's state: 0 is off, positive is on, -1 is unavailable.
// Independent of DFRDisplayState, which can report off while hardware is on.
int TouchBarBacklightPowerState(void);

// Hardware driver's CurrentNits value; -1 means unavailable.
double TouchBarBacklightNits(void);

// On-demand, read-only driver/service brightness properties. Missing values
// are NSNull. This does not change brightness, power, or saved preferences.
NSDictionary<NSString *, id> *TouchBarBrightnessDiagnostics(void);

// Call after the turnOn fade (at least 0.5 seconds), on the same serial queue.
// A subsequent off request invalidates the pending restoration.
BOOL TouchBarRestoreBrightness(void);
