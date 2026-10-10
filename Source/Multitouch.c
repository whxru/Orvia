#include "Multitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>
// Reverse-engineered ABI of MultitouchSupport, loaded optionally at runtime.
// No third-party source is linked. Apple has not published this API.
typedef struct { float x, y; } MWPoint;
typedef struct { MWPoint position, velocity; } Vector;
typedef struct {
    int32_t frame; double timestamp;
    int32_t pathIndex, state, fingerID, handID;
    Vector normalized; float size; int32_t field9;
    float angle, majorAxis, minorAxis;
    Vector absolute; int32_t field14, field15; float density;
} Touch;
_Static_assert(sizeof(Touch) == 96, "Multitouch ABI must be 96 bytes");
_Static_assert(offsetof(Touch, normalized) == 32, "Multitouch position offset");
typedef void (*FrameFn)(void *, Touch *, int, double, int);
static void *library;
static CFArrayRef devices;
static _Atomic(MWFrameCallback) client;
static void (*unregisterFrame)(void *, FrameFn);
static int (*stopDevice)(void *);
static bool (*deviceIsRunning)(void *);
static const char *error = "";
static void frame(void *device, Touch *touches, int count, double timestamp, int frameNumber) {
    MWFrameCallback callback = atomic_load(&client);
    if (!callback || count < 0 || count > 64) return;
    MWContact contacts[64]; int n = 0;
    for (int i = 0; i < count; ++i) {
        Touch t = touches[i];
        if ((t.state == 3 || t.state == 4) && isfinite(t.normalized.position.x) && isfinite(t.normalized.position.y)) {
            contacts[n++] = (MWContact){t.pathIndex, t.normalized.position.x, t.normalized.position.y};
        }
    }
    callback((uint64_t)(uintptr_t)device, contacts, n);
}
void MWStop(void) {
    atomic_store(&client, NULL);
    if (devices) {
        for (CFIndex i = 0; i < CFArrayGetCount(devices); ++i) {
            void *d = (void *)CFArrayGetValueAtIndex(devices, i);
            if (unregisterFrame) unregisterFrame(d, frame);
            if (stopDevice) stopDevice(d);
        }
        CFRelease(devices); devices = NULL;
    }
}
int MWStart(MWFrameCallback callback) {
    MWStop(); error = "";
    if (!library) library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
    if (!library) { error = "此系统无法加载触控板接口"; return -1; }
    CFArrayRef (*createList)(void) = dlsym(library, "MTDeviceCreateList");
    void (*registerFrame)(void *, FrameFn) = dlsym(library, "MTRegisterContactFrameCallback");
    int (*startDevice)(void *, int) = dlsym(library, "MTDeviceStart");
    unregisterFrame = dlsym(library, "MTUnregisterContactFrameCallback");
    stopDevice = dlsym(library, "MTDeviceStop");
    deviceIsRunning = dlsym(library, "MTDeviceIsRunning");
    if (!createList || !registerFrame || !startDevice || !unregisterFrame || !stopDevice) {
        error = "触控板接口不兼容此系统版本"; return -1;
    }
    devices = createList();
    if (!devices || CFArrayGetCount(devices) == 0) { error = "未找到触控板，请连接后重新检测"; return 0; }
    atomic_store(&client, callback);
    for (CFIndex i = 0; i < CFArrayGetCount(devices); ++i) {
        void *d = (void *)CFArrayGetValueAtIndex(devices, i);
        registerFrame(d, frame); startDevice(d, 0);
    }
    return (int)CFArrayGetCount(devices);
}
int MWDeviceIsRunning(uint64_t device) {
    // Called on the same main thread as start/stop. Never dereference a stale
    // callback's device pointer after the registered device list is released.
    if (!devices) return 0;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); ++i) {
        void *d = (void *)CFArrayGetValueAtIndex(devices, i);
        if ((uint64_t)(uintptr_t)d == device) return deviceIsRunning ? deviceIsRunning(d) : -1;
    }
    return 0;
}
const char *MWLastError(void) { return error; }
