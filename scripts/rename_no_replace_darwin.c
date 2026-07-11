#include <errno.h>
#include <stdio.h>
#include <string.h>

#ifdef RENAME_EXCL_TESTING
#include <fcntl.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static int wait_at_test_barrier(void) {
    const char *barrier = getenv("RENAME_EXCL_TEST_BARRIER");
    if (barrier == NULL || barrier[0] == '\0') return 0;

    char ready[4096];
    char proceed[4096];
    if (snprintf(ready, sizeof(ready), "%s.ready", barrier) >= (int)sizeof(ready) ||
        snprintf(proceed, sizeof(proceed), "%s.continue", barrier) >= (int)sizeof(proceed)) {
        fprintf(stderr, "RENAME_EXCL test barrier path is too long\n");
        return -1;
    }

    int fd = open(ready, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        fprintf(stderr, "Cannot create RENAME_EXCL test barrier: %s\n", strerror(errno));
        return -1;
    }
    close(fd);

    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
    for (int attempt = 0; attempt < 3000; attempt++) {
        if (access(proceed, F_OK) == 0) {
            unlink(ready);
            unlink(proceed);
            return 0;
        }
        nanosleep(&delay, NULL);
    }
    fprintf(stderr, "Timed out waiting at RENAME_EXCL test barrier\n");
    unlink(ready);
    return -1;
}
#endif

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s STAGING DESTINATION\n", argv[0]);
        return 2;
    }
#ifdef RENAME_EXCL_TESTING
    if (wait_at_test_barrier() != 0) return 3;
#endif

    if (renamex_np(argv[1], argv[2], RENAME_EXCL) == 0) return 0;
    if (errno == EEXIST || errno == ENOTEMPTY) {
        fprintf(stderr, "RENAME_EXCL refused existing publication destination: %s\n", argv[2]);
        return 17;
    }
    fprintf(stderr, "RENAME_EXCL publication failed for %s: %s\n", argv[2], strerror(errno));
    return 18;
}
