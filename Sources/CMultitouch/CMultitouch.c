#include "CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>

// Private Apple ABI; isolated here so Swift never depends on its struct layout.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex, state, fingerID, handID;
    MTVector normalized;
    float size;
    int32_t unknown;
    float angle, majorAxis, minorAxis;
    MTVector absolute;
    int32_t field14, field15;
    float density;
} MTContact;
_Static_assert(sizeof(MTContact) == 96, "Unexpected multitouch ABI");
_Static_assert(offsetof(MTContact, normalized) == 32, "Unexpected touch position offset");

typedef int (*MTCallback)(void *, MTContact *, int, double, int);
static CFArrayRef (*createList)(void);
static void (*registerCallback)(void *, MTCallback);
static void (*unregisterCallback)(void *, MTCallback);
static void (*startDevice)(void *, int);
static void (*stopDevice)(void *);
static bool (*isRunning)(void *);
static int (*sensorDimensions)(void *, int *, int *);
static int (*surfaceDimensions)(void *, int *, int *);
static CFMutableArrayRef devices;
static QLTouchCallback consumer;
static pthread_mutex_t callbackLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t loadOnce = PTHREAD_ONCE_INIT;
static bool available;

static void loadFramework(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LOCAL | RTLD_LAZY);
    if (!handle) return;
    createList = dlsym(handle, "MTDeviceCreateList");
    registerCallback = dlsym(handle, "MTRegisterContactFrameCallback");
    unregisterCallback = dlsym(handle, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(handle, "MTDeviceStart");
    stopDevice = dlsym(handle, "MTDeviceStop");
    isRunning = dlsym(handle, "MTDeviceIsRunning");
    sensorDimensions = dlsym(handle, "MTDeviceGetSensorDimensions");
    surfaceDimensions = dlsym(handle, "MTDeviceGetSensorSurfaceDimensions");
    available = createList && registerCallback && unregisterCallback && startDevice && stopDevice && isRunning && sensorDimensions && surfaceDimensions;
    // Keep loaded for process lifetime: a device may still have a callback in flight.
}

bool QLMultitouchAvailable(void) {
    pthread_once(&loadOnce, loadFramework);
    return available;
}

static int receiveFrame(void *device, MTContact *contacts, int count, double timestamp, int frame) {
    if (count < 0 || count > 32 || (count && !contacts)) return 0;
    QLTouch touches[32];
    int activeCount = 0;
    for (int i = 0; i < count; i++) {
        // Ignore proximity, lift-off and lingering contacts.
        if (contacts[i].state != 3 && contacts[i].state != 4) continue;
        touches[activeCount++] = (QLTouch){ contacts[i].pathIndex, contacts[i].normalized.position.x, contacts[i].normalized.position.y };
    }
    pthread_mutex_lock(&callbackLock);
    if (consumer && CFArrayContainsValue(devices, CFRangeMake(0, CFArrayGetCount(devices)), device)) {
        consumer((uintptr_t)device, touches, activeCount, timestamp);
    }
    pthread_mutex_unlock(&callbackLock);
    return 0;
}

void QLMultitouchStop(void) {
    pthread_mutex_lock(&callbackLock);
    consumer = NULL;
    pthread_mutex_unlock(&callbackLock);
    if (!devices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        void *device = (void *)CFArrayGetValueAtIndex(devices, i);
        unregisterCallback(device, receiveFrame);
        stopDevice(device);
    }
    CFRelease(devices);
    devices = NULL;
}

int QLMultitouchStart(QLTouchCallback callback) {
    QLMultitouchStop();
    if (!QLMultitouchAvailable()) return -1;
    CFArrayRef candidates = createList();
    if (!candidates) return 0;
    devices = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    int count = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(candidates); i++) {
        void *device = (void *)CFArrayGetValueAtIndex(candidates, i);
        int rows = 0, columns = 0, width = 0, height = 0;
        // Exclude narrow Touch Bars and portrait Magic Mouse surfaces.
        // MTDeviceIsOpaqueSurface is NOT a trackpad discriminator on current Macs.
        if (sensorDimensions(device, &rows, &columns) != 0 || rows < 10 ||
            surfaceDimensions(device, &width, &height) != 0 || width <= height || height <= 0) continue;
        registerCallback(device, receiveFrame);
        startDevice(device, 0);
        if (!isRunning(device)) {
            unregisterCallback(device, receiveFrame);
            stopDevice(device);
            continue;
        }
        CFArrayAppendValue(devices, device);
        count++;
    }
    CFRelease(candidates);
    pthread_mutex_lock(&callbackLock);
    consumer = callback;
    pthread_mutex_unlock(&callbackLock);
    return count;
}
