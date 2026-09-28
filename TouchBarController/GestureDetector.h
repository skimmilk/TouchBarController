#ifndef GESTURE_DETECTOR_H
#define GESTURE_DETECTOR_H

#include <stdbool.h>

typedef enum {
    GestureNone = 0,
    GestureCommand = 1,
    GestureOption = 2,
} Gesture;

typedef struct {
    double firstDown[2];
    bool pending[2];
    bool released[2];
    bool down[2];
} GestureDetector;

void GestureDetectorReset(GestureDetector *detector);
void GestureDetectorOtherKey(GestureDetector *detector);
Gesture GestureDetectorModifier(GestureDetector *detector, Gesture modifier,
                                bool isDown, bool otherModifiersHeld, double timeSeconds);

#endif
