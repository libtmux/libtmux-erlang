#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static void hold_pipe(int fd)
{
    char byte;
    ssize_t count;
    do {
        count = read(fd, &byte, sizeof byte);
    } while (count < 0 && errno == EINTR);
    _exit(count < 0 ? 71 : 70);
}

static void hold_setup(const char *socket)
{
    const char *ready = getenv("LIBTMUX_TEST_PROGRAM_READY");
    int gate[2];
    if (ready == NULL || socket == NULL || pipe(gate) < 0 ||
        signal(SIGTERM, SIG_IGN) == SIG_ERR || signal(SIGHUP, SIG_IGN) == SIG_ERR)
        _exit(68);
    pid_t child = fork();
    if (child < 0)
        _exit(68);
    if (child == 0)
        hold_pipe(gate[0]);
    int fd = open(ready, O_WRONLY);
    if (fd < 0 || dprintf(fd, "%ld\t%ld\t%ld\t%s\n",
            (long)getpid(), (long)child, (long)getpgrp(), socket) < 0 || close(fd) < 0)
        _exit(69);
    hold_pipe(gate[0]);
}

int main(int argc, char **argv)
{
    const char *version = getenv("LIBTMUX_TEST_PROGRAM_VERSION");
    if (argc == 2 && strcmp(argv[1], "-V") == 0 && version != NULL)
        return puts(version) < 0 ? 65 : 0;
    const char *socket = NULL;
    const char *blocked = getenv("LIBTMUX_TEST_PROGRAM_BLOCK");
    if (blocked == NULL)
        blocked = "new-session";
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "-S") == 0 && index + 1 < argc)
            socket = argv[++index];
        else if (strcmp(argv[index], blocked) == 0) {
            const char *marker = getenv("LIBTMUX_TEST_PROGRAM_MARKER");
            if (marker != NULL) {
                FILE *file = fopen(marker, "wx");
                return file != NULL && fclose(file) == 0 ? 66 : 65;
            }
            hold_setup(socket == NULL ? "-" : socket);
        }
    }
    const char *tmux = getenv("LIBTMUX_TEST_PROGRAM_REAL");
    if (tmux == NULL)
        return 68;
    execv(tmux, argv);
    return 68;
}
