#include "disk_health.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <sys/mount.h>
#include <stdio.h>
#include <string.h>

double fm_nvme_counter(const void *bytes) {
    const uint8_t *p = bytes;
    double value = 0;
    for (int i = 15; i >= 0; i--) value = value * 256 + p[i];
    return value;
}

void fm_disk_health(FMDiskHealth *health) {
    memset(health, 0, sizeof(*health));
    snprintf(health->error, sizeof(health->error), "NVMe health data is unavailable for the startup disk.");
    struct statfs fs;
    if (statfs("/", &fs) || strncmp(fs.f_mntfromname, "/dev/", 5)) return;
    io_service_t device = IOServiceGetMatchingService(kIOMainPortDefault,
        IOBSDNameMatching(kIOMainPortDefault, 0, fs.f_mntfromname + 5));
    while (device) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(device,
            CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
        bool found = capable && CFEqual(capable, kCFBooleanTrue);
        if (capable) CFRelease(capable);
        if (found) break;
        io_registry_entry_t parent = IO_OBJECT_NULL;
        IORegistryEntryGetParentEntry(device, kIOServicePlane, &parent);
        IOObjectRelease(device);
        device = parent;
    }
    if (!device) return;

    IOCFPlugInInterface **plugin = NULL;
    IONVMeSMARTInterface **smart = NULL;
    SInt32 score;
    IOReturn result = IOCreatePlugInInterfaceForService(device, kIONVMeSMARTUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugin, &score);
    if (result == kIOReturnSuccess && plugin) {
        HRESULT query = (*plugin)->QueryInterface(plugin,
            CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (void **)&smart);
        if (query == S_OK && smart) {
            result = (*smart)->SMARTReadData(smart, &health->data);
            health->available = result == kIOReturnSuccess;
            if (health->available) {
                NVMeIdentifyControllerStruct identify = {0};
                if ((*smart)->GetIdentifyData(smart, &identify, 0) == kIOReturnSuccess) {
                    memcpy(health->model, identify.MODEL_NUMBER, 40);
                    size_t length = strlen(health->model);
                    while (length && health->model[length - 1] == ' ') health->model[--length] = 0;
                }
            }
        } else result = kIOReturnUnsupported;
    }
    if (!health->available)
        snprintf(health->error, sizeof(health->error), "Could not read startup SSD health (0x%08x).", result);
    if (smart) (*smart)->Release(smart);
    if (plugin) IODestroyPlugInInterface(plugin);
    IOObjectRelease(device);
}
