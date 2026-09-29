#include "scanner.h"
#include <sys/attr.h>
#include <sys/vnode.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

double fm_time(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void *grow(void *p, size_t size) {
    p = realloc(p, size);
    if (!p) abort();
    return p;
}

static uint32_t add_node(FMScan *s, uint32_t parent, const char *name, uint8_t flags) {
    if (s->count == s->capacity) {
        s->capacity = s->capacity ? s->capacity * 2 : 4096;
        s->nodes = grow(s->nodes, (size_t)s->capacity * sizeof(FMNode));
    }
    uint32_t len = (uint32_t)strlen(name) + 1;
    while (s->names_used + len > s->names_capacity) {
        s->names_capacity = s->names_capacity ? s->names_capacity * 2 : 65536;
        s->names = grow(s->names, s->names_capacity);
    }
    uint32_t id = s->count++;
    s->nodes[id] = (FMNode){.parent = parent, .child = FM_NONE, .next = FM_NONE,
                           .name = s->names_used, .flags = flags};
    memcpy(s->names + s->names_used, name, len);
    s->names_used += len;
    if (parent != FM_NONE) {
        s->nodes[id].next = s->nodes[parent].child;
        s->nodes[parent].child = id;
    }
    return id;
}

static void push_job(FMScan *s, uint32_t id) {
    if (s->jobs_count == s->jobs_capacity) {
        s->jobs_capacity = s->jobs_capacity ? s->jobs_capacity * 2 : 1024;
        s->jobs = grow(s->jobs, (size_t)s->jobs_capacity * sizeof(uint32_t));
    }
    s->jobs[s->jobs_count++] = id;
}

char *fm_path(FMScan *s, uint32_t id) {
    size_t length = strlen(s->root);
    for (uint32_t n = id; n; n = s->nodes[n].parent)
        length += strlen(s->names + s->nodes[n].name) + 1;
    char *path = grow(NULL, length + 1);
    path[length] = 0;
    for (uint32_t n = id; n; n = s->nodes[n].parent) {
        const char *name = s->names + s->nodes[n].name;
        size_t len = strlen(name);
        length -= len;
        memcpy(path + length, name, len);
        path[--length] = '/';
    }
    memcpy(path, s->root, length);
    if (path[0] == '/' && path[1] == '/') memmove(path, path + 1, strlen(path));
    return path;
}

static uint32_t link_slot(uint64_t inode, uint32_t device, uint32_t capacity) {
    uint64_t h = inode ^ ((uint64_t)device << 32);
    h = (h ^ (h >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    h = (h ^ (h >> 27)) * UINT64_C(0x94d049bb133111eb);
    return (uint32_t)(h ^ (h >> 31)) & (capacity - 1);
}

static bool seen_link(FMScan *s, uint64_t inode, uint32_t device) {
    if (!inode) return false;
    if ((s->links_count + 1) * 2 >= s->links_capacity) {
        uint32_t old_capacity = s->links_capacity;
        FMHardlink *old = s->links;
        s->links_capacity = old_capacity ? old_capacity * 2 : 1024;
        s->links = calloc(s->links_capacity, sizeof(FMHardlink));
        if (!s->links) abort();
        for (uint32_t i = 0; i < old_capacity; i++) {
            if (!old[i].inode) continue;
            uint32_t slot = link_slot(old[i].inode, old[i].device, s->links_capacity);
            while (s->links[slot].inode) slot = (slot + 1) & (s->links_capacity - 1);
            s->links[slot] = old[i];
        }
        free(old);
    }
    uint32_t slot = link_slot(inode, device, s->links_capacity);
    while (s->links[slot].inode) {
        if (s->links[slot].inode == inode && s->links[slot].device == device) return true;
        slot = (slot + 1) & (s->links_capacity - 1);
    }
    s->links[slot] = (FMHardlink){inode, device};
    s->links_count++;
    return false;
}

static void mark_error(FMScan *s, uint32_t id, int error) {
    s->errors++;
    for (uint32_t n = id; n != FM_NONE; n = s->nodes[n].parent)
        if (!s->nodes[n].error) s->nodes[n].error = error;
}

static void aggregate(FMScan *s, uint32_t id, uint64_t logical, uint64_t allocated, uint32_t items) {
    for (uint32_t n = id; n != FM_NONE; n = s->nodes[n].parent) {
        s->nodes[n].logical += logical;
        s->nodes[n].allocated += allocated;
        s->nodes[n].items += items;
    }
}

static void read_directory(FMScan *s, uint32_t parent, char *buffer) {
    pthread_mutex_lock(&s->mutex);
    char *path = fm_path(s, parent);
    pthread_mutex_unlock(&s->mutex);
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    free(path);
    if (fd < 0) {
        int error = errno;
        pthread_mutex_lock(&s->mutex);
        mark_error(s, parent, error);
        pthread_mutex_unlock(&s->mutex);
        return;
    }
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
                       ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
    attrs.dirattr = ATTR_DIR_MOUNTSTATUS;
    attrs.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    while (!atomic_load(&s->cancel)) {
        int count = getattrlistbulk(fd, &attrs, buffer, 256 * 1024, 0);
        int error = errno;
        if (!count) break;
        pthread_mutex_lock(&s->mutex);
        s->batches++;
        if (count < 0) {
            mark_error(s, parent, error);
            pthread_mutex_unlock(&s->mutex);
            break;
        }
        char *entry = buffer;
        uint64_t logical_sum = 0, allocated_sum = 0;
        uint32_t items = 0;
        for (int i = 0; i < count; i++) {
            char *p = entry;
            uint32_t length;
            attribute_set_t returned;
            memcpy(&length, p, 4); p += 4;
            memcpy(&returned, p, sizeof(returned)); p += sizeof(returned);
            entry += length;
            uint32_t entry_error = 0, device = 0, type = 0, mount = 0, links = 0;
            uint64_t inode = 0;
            off_t logical = 0, allocated = 0;
            const char *name = NULL;
#define READ_ATTR(group, bit, value) \
            if (returned.group & (bit)) { memcpy(&(value), p, sizeof(value)); p += sizeof(value); }
            READ_ATTR(commonattr, ATTR_CMN_ERROR, entry_error);
            if (returned.commonattr & ATTR_CMN_NAME) {
                attrreference_t ref;
                memcpy(&ref, p, sizeof(ref));
                name = p + ref.attr_dataoffset;
                p += sizeof(ref);
            }
            READ_ATTR(commonattr, ATTR_CMN_DEVID, device);
            READ_ATTR(commonattr, ATTR_CMN_OBJTYPE, type);
            READ_ATTR(commonattr, ATTR_CMN_FILEID, inode);
            READ_ATTR(dirattr, ATTR_DIR_MOUNTSTATUS, mount);
            READ_ATTR(fileattr, ATTR_FILE_LINKCOUNT, links);
            READ_ATTR(fileattr, ATTR_FILE_TOTALSIZE, logical);
            READ_ATTR(fileattr, ATTR_FILE_ALLOCSIZE, allocated);
#undef READ_ATTR
            if (!name) { mark_error(s, parent, entry_error ? (int)entry_error : EIO); continue; }
            uint8_t flags = type == VDIR ? FM_DIRECTORY : type == VLNK ? FM_SYMLINK : 0;
            if (mount & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)) flags |= FM_MOUNT;
            uint32_t id = add_node(s, parent, name, flags);
            items++;
            if (entry_error || !type) {
                mark_error(s, id, entry_error ? (int)entry_error : EIO);
                continue;
            }
            if (type == VDIR) {
                s->directories++;
                if (flags & FM_MOUNT) s->mounts++;
                else push_job(s, id);
            } else {
                s->files++;
                if (type == VREG && (returned.fileattr & attrs.fileattr) != attrs.fileattr)
                    mark_error(s, id, ENOTSUP);
                if (links > 1 && seen_link(s, inode, device)) {
                    allocated = 0;
                    s->nodes[id].flags |= FM_SHARED;
                }
                s->nodes[id].logical = logical > 0 ? (uint64_t)logical : 0;
                s->nodes[id].allocated = allocated > 0 ? (uint64_t)allocated : 0;
                logical_sum += s->nodes[id].logical;
                allocated_sum += s->nodes[id].allocated;
            }
        }
        aggregate(s, parent, logical_sum, allocated_sum, items);
        s->revision++;
        pthread_cond_broadcast(&s->wake);
        pthread_mutex_unlock(&s->mutex);
    }
    close(fd);
}

static void *worker(void *context) {
    FMScan *s = context;
    char *buffer = grow(NULL, 256 * 1024);
    for (;;) {
        pthread_mutex_lock(&s->mutex);
        while (!s->jobs_count && s->active && !atomic_load(&s->cancel))
            pthread_cond_wait(&s->wake, &s->mutex);
        if (atomic_load(&s->cancel) || (!s->jobs_count && !s->active)) {
            pthread_mutex_unlock(&s->mutex);
            break;
        }
        uint32_t id = s->jobs[--s->jobs_count];
        s->active++;
        pthread_mutex_unlock(&s->mutex);
        read_directory(s, id, buffer);
        pthread_mutex_lock(&s->mutex);
        s->nodes[id].flags |= FM_SCANNED;
        s->revision++;
        s->active--;
        pthread_cond_broadcast(&s->wake);
        pthread_mutex_unlock(&s->mutex);
    }
    free(buffer);
    return NULL;
}

static void *coordinator(void *context) {
    FMScan *s = context;
    pthread_t threads[32];
    int started = 0;
    for (int i = 1; i < s->workers; i++)
        if (!pthread_create(&threads[started], NULL, worker, s)) started++;
    worker(s);
    for (int i = 0; i < started; i++) pthread_join(threads[i], NULL);
    pthread_mutex_lock(&s->mutex);
    s->elapsed = fm_time() - s->started;
    s->done = true;
    s->revision++;
    pthread_mutex_unlock(&s->mutex);
    return NULL;
}

FMScan *fm_scan(const char *path, int workers) {
    FMScan *s = calloc(1, sizeof(FMScan));
    if (!s) abort();
    pthread_mutex_init(&s->mutex, NULL);
    pthread_cond_init(&s->wake, NULL);
    atomic_init(&s->cancel, false);
    s->root = realpath(path, NULL);
    if (!s->root) s->root = strdup(path);
    s->workers = workers > 0 ? workers : 8;
    if (s->workers > 32) s->workers = 32;
    s->started = fm_time();
    add_node(s, FM_NONE, s->root, FM_DIRECTORY);
    push_job(s, 0);
    int error = pthread_create(&s->thread, NULL, coordinator, s);
    if (error) {
        s->thread = NULL;
        mark_error(s, 0, error);
        s->done = true;
    }
    return s;
}

void fm_free(FMScan *s) {
    if (!s) return;
    atomic_store(&s->cancel, true);
    pthread_mutex_lock(&s->mutex);
    pthread_cond_broadcast(&s->wake);
    pthread_mutex_unlock(&s->mutex);
    if (s->thread) pthread_join(s->thread, NULL);
    pthread_mutex_destroy(&s->mutex);
    pthread_cond_destroy(&s->wake);
    free(s->root); free(s->nodes); free(s->names); free(s->jobs); free(s->links); free(s);
}
