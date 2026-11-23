#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <unistd.h>

static int gated_daemon(unsigned *pty)
{
    const char *path = getenv("LIBTMUX_TEST_REAP_GATE");
    if (path != NULL) {
        FILE *gate = fopen(path, "r");
        if (gate != NULL) {
            long daemon = 0;
            int matched = fscanf(gate, "%ld %u", &daemon, pty) == 2;
            fclose(gate);
            if (matched && daemon == (long)getpid())
                return 1;
        }
    }
    return 0;
}

/* Close only the bound pane's native master, preserving the holder's slave. */
static int gated_master(int fd)
{
    unsigned expected, actual;
    return gated_daemon(&expected) && ioctl(fd, TIOCGPTN, &actual) == 0 && actual == expected;
}

ssize_t read(int fd, void *data, size_t size)
{
    ssize_t (*native_read)(int, void *, size_t) = dlsym(RTLD_NEXT, "read");
    if (gated_master(fd)) {
        (void)native_read(fd, data, size);
        errno = EIO;
        return -1;
    }
    return native_read(fd, data, size);
}

ssize_t readv(int fd, const struct iovec *vectors, int count)
{
    ssize_t (*native_readv)(int, const struct iovec *, int) = dlsym(RTLD_NEXT, "readv");
    if (gated_master(fd)) {
        (void)native_readv(fd, vectors, count);
        errno = EIO;
        return -1;
    }
    return native_readv(fd, vectors, count);
}

/* Withhold native reaping only for the exact owned daemon named by the test. */
pid_t waitpid(pid_t pid, int *status, int options)
{
    unsigned pty;
    if ((options & WNOHANG) != 0 && gated_daemon(&pty))
        return 0;
    pid_t (*native_waitpid)(pid_t, int *, int) = dlsym(RTLD_NEXT, "waitpid");
    if (native_waitpid == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return native_waitpid(pid, status, options);
}

/* pidfd readiness proves exit without consuming the daemon's wait status. */
int main(int argc, char **argv)
{
    if (argc != 2)
        return 64;
    char *end;
    long pid = strtol(argv[1], &end, 10);
    if (*end != '\0' || pid <= 0)
        return 64;
    int fd = (int)syscall(SYS_pidfd_open, (pid_t)pid, 0);
    if (fd < 0)
        return 65;
    struct pollfd watched = {.fd = fd, .events = POLLIN};
    int ready;
    do {
        ready = poll(&watched, 1, 850);
    } while (ready < 0 && errno == EINTR);
    close(fd);
    if (ready != 1 || (watched.revents & POLLIN) == 0)
        return 66;
    return puts("exited") < 0 ? 67 : 0;
}
