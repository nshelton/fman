#pragma once
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

#define FM_NONE UINT32_MAX
enum { FM_DIRECTORY = 1, FM_SYMLINK = 2, FM_MOUNT = 4, FM_SHARED = 8, FM_SCANNED = 16 };

typedef struct {
    uint64_t logical, allocated;
    uint32_t parent, child, next, name, items;
    int error;
    uint8_t flags;
} FMNode;

typedef struct { uint64_t inode; uint32_t device; } FMHardlink;

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t wake;
    pthread_t thread;
    atomic_bool cancel;
    bool done;
    int workers, active;
    char *root, *names;
    FMNode *nodes;
    uint32_t count, capacity, names_used, names_capacity;
    uint32_t *jobs, jobs_count, jobs_capacity;
    FMHardlink *links;
    uint32_t links_count, links_capacity;
    uint64_t files, directories, errors, mounts, batches, revision;
    double started, elapsed;
} FMScan;

double fm_time(void);
FMScan *fm_scan(const char *path, int workers);
void fm_free(FMScan *scan);
char *fm_path(FMScan *scan, uint32_t node);
