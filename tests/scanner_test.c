#include "../src/scanner.h"
#include <sys/stat.h>
#include <assert.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void wait_done(FMScan *s) {
    double deadline = fm_time() + 30;
    for (;;) {
        pthread_mutex_lock(&s->mutex);
        bool done = s->done;
        pthread_mutex_unlock(&s->mutex);
        if (done) return;
        assert(fm_time() < deadline);
        usleep(1000);
    }
}

static void file_at(int dir, const char *name, size_t bytes, bool sparse) {
    int fd = openat(dir, name, O_CREAT | O_WRONLY | O_EXCL, 0600);
    assert(fd >= 0);
    if (sparse) assert(ftruncate(fd, (off_t)bytes) == 0);
    else {
        char data[4096];
        memset(data, 'x', sizeof(data));
        while (bytes) {
            size_t count = bytes < sizeof(data) ? bytes : sizeof(data);
            assert(write(fd, data, count) == (ssize_t)count);
            bytes -= count;
        }
    }
    close(fd);
}

static void verify(FMScan *s) {
    uint64_t *logical = calloc(s->count, sizeof(uint64_t));
    uint64_t *allocated = calloc(s->count, sizeof(uint64_t));
    uint32_t *items = calloc(s->count, sizeof(uint32_t));
    unsigned shared = 0;
    for (uint32_t i = s->count; i-- > 0;) {
        FMNode *n = &s->nodes[i];
        char *path = fm_path(s, i);
        struct stat st;
        assert(lstat(path, &st) == 0);
        free(path);
        if (n->flags & FM_DIRECTORY) {
            assert(S_ISDIR(st.st_mode));
            assert(n->flags & FM_SCANNED);
        } else {
            assert(n->logical == (uint64_t)st.st_size);
            logical[i] = (uint64_t)st.st_size;
            allocated[i] = n->flags & FM_SHARED ? 0 : (uint64_t)st.st_blocks * 512;
            if (n->flags & FM_SHARED) shared++;
            assert(n->allocated == allocated[i]);
            assert(!!(n->flags & FM_SYMLINK) == !!S_ISLNK(st.st_mode));
        }
        assert(n->logical == logical[i]);
        assert(n->allocated == allocated[i]);
        assert(n->items == items[i]);
        if (n->parent != FM_NONE) {
            assert(n->parent < i);
            logical[n->parent] += logical[i];
            allocated[n->parent] += allocated[i];
            items[n->parent] += items[i] + 1;
        }
    }
    assert(shared == 1);
    assert(s->nodes[0].items == s->count - 1);
    free(logical); free(allocated); free(items);
}

static int remove_entry(const char *path, const struct stat *st, int type, struct FTW *walk) {
    (void)st; (void)type; (void)walk;
    return remove(path);
}

int main(void) {
    char root[] = "/tmp/fman-test-XXXXXX";
    assert(mkdtemp(root));
    int dir = open(root, O_RDONLY | O_DIRECTORY);
    assert(dir >= 0);
    file_at(dir, "payload", 65537, false);
    file_at(dir, "sparse", 16 * 1024 * 1024, true);
    file_at(dir, ".hidden", 17, false);
    file_at(dir, "empty", 0, false);
    file_at(dir, "spaces 日本語 🪨", 123, false);
    char long_name[241];
    memset(long_name, 'a', sizeof(long_name) - 1);
    long_name[sizeof(long_name) - 1] = 0;
    file_at(dir, long_name, 31, false);
    assert(linkat(dir, "payload", dir, "hardlink", 0) == 0);
    assert(symlinkat("payload", dir, "symlink") == 0);
    assert(symlinkat(".", dir, "loop") == 0);
    assert(symlinkat("missing", dir, "broken") == 0);
    assert(mkdirat(dir, "empty-folder", 0700) == 0);
    assert(mkdirat(dir, "unreadable", 0000) == 0);
    for (int d = 0; d < 40; d++) {
        char name[32];
        snprintf(name, sizeof(name), "folder-%d", d);
        assert(mkdirat(dir, name, 0700) == 0);
        int sub = openat(dir, name, O_RDONLY | O_DIRECTORY);
        assert(sub >= 0);
        for (int f = 0; f < 12; f++) {
            snprintf(name, sizeof(name), "file-%d", f);
            file_at(sub, name, (size_t)(d * 12 + f), false);
        }
        close(sub);
    }
    assert(mkdirat(dir, "many", 0700) == 0);
    int many = openat(dir, "many", O_RDONLY | O_DIRECTORY);
    for (int f = 0; f < 12000; f++) {
        char name[32];
        snprintf(name, sizeof(name), "entry-%05d", f);
        file_at(many, name, 0, false);
    }
    close(many);
    FMScan *serial = fm_scan(root, 1);
    FMScan *parallel = fm_scan(root, 8);
    wait_done(serial);
    wait_done(parallel);
    assert(serial->errors == 1 && parallel->errors == 1);
    assert(serial->count == 12534 && parallel->count == serial->count);
    assert(serial->nodes[0].logical == parallel->nodes[0].logical);
    assert(serial->nodes[0].allocated == parallel->nodes[0].allocated);
    verify(serial);
    verify(parallel);
    printf("PASS: %u entries, bulk boundaries, aggregation, sparse files, hard links, symlinks, Unicode, permissions; 1 and 8 workers\n", serial->count - 1);
    fm_free(serial);
    fm_free(parallel);
    for (int i = 0; i < 12; i++) {
        FMScan *cancelled = fm_scan(root, 8);
        atomic_store(&cancelled->cancel, true);
        wait_done(cancelled);
        fm_free(cancelled);
    }
    FMScan *missing = fm_scan("/tmp/fman-test-does-not-exist/no-such-folder", 8);
    wait_done(missing);
    assert(missing->errors == 1 && missing->nodes[0].error != 0);
    fm_free(missing);
    puts("PASS: cancellation, repeated teardown, invalid root");
    assert(fchmodat(dir, "unreadable", 0700, 0) == 0);
    close(dir);
    assert(nftw(root, remove_entry, 16, FTW_DEPTH | FTW_PHYS) == 0);
    return 0;
}
