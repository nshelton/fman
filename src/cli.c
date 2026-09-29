#include "scanner.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void interrupt_scan(int signal) { (void)signal; interrupted = 1; }

static int by_size(void *context, const void *a, const void *b) {
    FMScan *s = context;
    uint64_t x = s->nodes[*(const uint32_t *)a].allocated;
    uint64_t y = s->nodes[*(const uint32_t *)b].allocated;
    return x < y ? 1 : x > y ? -1 : 0;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 || !strcmp(argv[1], "--help")) {
        fprintf(stderr, "Usage: fman-scan DIRECTORY [WORKERS=8]\nSizes are bytes. Nested mounts are excluded.\n");
        return argc == 2 ? 0 : 2;
    }
    signal(SIGINT, interrupt_scan);
    FMScan *s = fm_scan(argv[1], argc == 3 ? atoi(argv[2]) : 0);
    for (;;) {
        if (interrupted) atomic_store(&s->cancel, true);
        pthread_mutex_lock(&s->mutex);
        bool done = s->done;
        pthread_mutex_unlock(&s->mutex);
        if (done) break;
        usleep(10000);
    }
    printf("%.3f s | %llu files | %llu folders | %.0f entries/s | %llu errors | %llu mounts skipped%s\n",
           s->elapsed, s->files, s->directories, (s->count - 1) / s->elapsed,
           s->errors, s->mounts, interrupted ? " | CANCELLED: partial results" : "");
    printf("%llu logical bytes | %llu allocated bytes | %llu bulk batches | %.1f MiB index\n",
           s->nodes[0].logical, s->nodes[0].allocated, s->batches,
           ((double)s->capacity * sizeof(FMNode) + s->names_capacity +
            s->jobs_capacity * sizeof(uint32_t) + s->links_capacity * sizeof(FMHardlink)) / 1048576);
    uint32_t *ids = malloc((size_t)s->count * sizeof(uint32_t));
    uint32_t count = 0;
    for (uint32_t id = s->nodes[0].child; id != FM_NONE; id = s->nodes[id].next) ids[count++] = id;
    qsort_r(ids, count, sizeof(uint32_t), s, by_size);
    printf("    ALLOCATED        LOGICAL  NAME\n");
    for (uint32_t i = 0; i < count; i++) {
        FMNode *n = &s->nodes[ids[i]];
        printf("%13llu  %13llu  %s%s%s\n", n->allocated, n->logical,
               s->names + n->name, n->flags & FM_DIRECTORY ? "/" : "",
               n->error ? " [incomplete]" : n->flags & FM_MOUNT ? " [mount skipped]" : "");
    }
    int result = interrupted ? 130 : s->errors ? 1 : 0;
    free(ids);
    fm_free(s);
    return result;
}
