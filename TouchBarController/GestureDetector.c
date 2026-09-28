#include "GestureDetector.h"
#include <string.h>

void GestureDetectorReset(GestureDetector *detector) {
    memset(detector, 0, sizeof(*detector));
}

void GestureDetectorOtherKey(GestureDetector *detector) {
    for (int i = 0; i < 2; i++) {
        detector->pending[i] = false;
        detector->released[i] = false;
    }
}

Gesture GestureDetectorModifier(GestureDetector *detector, Gesture modifier,
                                bool isDown, bool otherModifiersHeld, double timeSeconds) {
    if (modifier != GestureCommand && modifier != GestureOption) return GestureNone;
    int index = modifier - 1;
    int other = 1 - index;

    if (!isDown) {
        if (detector->down[index]) {
            detector->down[index] = false;
            if (detector->pending[index]) detector->released[index] = true;
        }
        return GestureNone;
    }
    if (detector->down[index]) return GestureNone;
    detector->down[index] = true;
    detector->pending[other] = false;
    detector->released[other] = false;
    if (otherModifiersHeld) {
        detector->pending[index] = false;
        detector->released[index] = false;
        return GestureNone;
    }
    if (detector->pending[index] && detector->released[index] &&
        timeSeconds >= detector->firstDown[index] &&
        timeSeconds - detector->firstDown[index] <= 0.3) {
        detector->pending[index] = false;
        detector->released[index] = false;
        return modifier;
    }
    detector->firstDown[index] = timeSeconds;
    detector->pending[index] = true;
    detector->released[index] = false;
    return GestureNone;
}
