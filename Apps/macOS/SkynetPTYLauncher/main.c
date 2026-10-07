#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

// Spawned as a fresh session leader with the PTY slave on standard input.
// Acquire the controlling terminal before exec so shell job control and
// terminal-generated signals (including Ctrl-C) reach the foreground group.
int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Terminal launcher requires an executable.\n");
        return 64;
    }
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1) {
        perror("Could not acquire controlling terminal");
        return 1;
    }
    if (tcsetpgrp(STDIN_FILENO, getpgrp()) == -1) {
        perror("Could not set terminal foreground group");
        return 1;
    }
    execv(argv[1], &argv[1]);
    perror("Could not start terminal executable");
    return 127;
}
