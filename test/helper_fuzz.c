/* Outer: exercise the real frame/launch parser without executing fuzz data. */
#define main owned_io_entrypoint
#define read fuzz_read
#define fork fuzz_fork
#include "../apps/libtmux_erlang/c_src/owned_io.c"
#undef main
#undef read
#undef fork

static const unsigned char *fuzz_input;
static size_t fuzz_left, fuzz_fragment;

ssize_t fuzz_read(int fd, void *buffer, size_t size) {
    if (fd != STDIN_FILENO) abort();
    if (size > fuzz_left) size = fuzz_left;
    if (size > fuzz_fragment) size = fuzz_fragment;
    memcpy(buffer, fuzz_input, size);
    fuzz_input += size;
    fuzz_left -= size;
    return (ssize_t)size;
}

pid_t fuzz_fork(void) {
    errno = EAGAIN;
    return -1;
}

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
    if (size < 2 || size > 65540) return 0;
    struct state s = {0};
    s.child_in = s.exec_fd = s.streams[0] = s.streams[1] = -1;
    s.input_need = 2;
    unsigned mode = data[0] % 4;
    if (mode != 0) {
        s.configured = s.ready = 1;
        s.child_in = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (s.child_in == -1) abort();
        if (mode == 2) s.stopping = 1;
        if (mode == 3) s.terminal = 1;
    }
    fuzz_fragment = (size_t)data[1] + 1;
    fuzz_input = data + 2;
    fuzz_left = size - 2;
    while (fuzz_left) read_parent(&s);
    read_parent(&s); /* EOF with any partially accumulated header or payload. */
    close_fd(&s.child_in);
    close_fd(&s.exec_fd);
    for (int i = 0; i < 2; i++) close_fd(&s.streams[i]);
    return 0;
}
