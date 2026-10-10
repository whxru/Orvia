#ifndef MAGICWHEEL_MULTITOUCH_H
#define MAGICWHEEL_MULTITOUCH_H
#include <stdint.h>
typedef struct { int32_t id; double x, y; } MWContact;
typedef void (*MWFrameCallback)(uint64_t device, const MWContact *contacts, int count);
int MWStart(MWFrameCallback callback);
void MWStop(void);
// 1 running, 0 no longer monitored, -1 status unavailable.
int MWDeviceIsRunning(uint64_t device);
const char *MWLastError(void);
#endif
