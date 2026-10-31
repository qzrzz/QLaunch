#ifndef QL_MULTITOUCH_H
#define QL_MULTITOUCH_H
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    int32_t identifier;
    float x;
    float y;
} QLTouch;

typedef void (*QLTouchCallback)(uintptr_t device, const QLTouch *touches, int count, double timestamp);
// Call lifecycle functions on the main thread. Callback runs on the device thread.
bool QLMultitouchAvailable(void);
int QLMultitouchStart(QLTouchCallback callback);
void QLMultitouchStop(void);
#endif
