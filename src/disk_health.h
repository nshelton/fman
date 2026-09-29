#ifndef FM_DISK_HEALTH_H
#define FM_DISK_HEALTH_H

#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

typedef struct {
    bool available;
    char model[41];
    char error[160];
    NVMeSMARTData data;
} FMDiskHealth;

void fm_disk_health(FMDiskHealth *health);
double fm_nvme_counter(const void *bytes);

#endif
