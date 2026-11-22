#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    int ready[2];
    if (argc != 2 || pipe(ready) < 0 ||
        signal(SIGTERM, SIG_IGN) == SIG_ERR || signal(SIGHUP, SIG_IGN) == SIG_ERR)
        return 60;
    pid_t child = fork();
    if (child < 0)
        return 61;
    if (child == 0) {
        close(ready[0]);
        if (setsid() < 0 || write(ready[1], "R", 1) != 1)
            _exit(62);
        close(ready[1]);
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        for (;;)
            pause();
    }
    close(ready[1]);
    char byte;
    if (read(ready[0], &byte, 1) != 1 || byte != 'R')
        return 63;
    close(ready[0]);
    int report = open(argv[1], O_WRONLY);
    if (report < 0 || dprintf(report, "%ld\t%ld\t%ld\t%ld\n",
            (long)getpid(), (long)child, (long)getpgrp(), (long)getpgid(child)) < 0 ||
        close(report) < 0)
        return 64;
    ssize_t count;
    do {
        count = read(STDIN_FILENO, &byte, 1);
    } while (count < 0 && errno == EINTR);
    if (count != 1 || write(STDOUT_FILENO, "final stdout\n", 13) != 13 ||
        write(STDERR_FILENO, "final stderr\n", 13) != 13)
        return 65;
    return 17;
}
