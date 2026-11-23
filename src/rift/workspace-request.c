#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

int main(int argc, const char *argv[]) {
    uint64_t sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const char *home = getenv("HOME");
    const char *state = getenv("MAC_RICING_STATE");
    const char *socket_path = getenv("MAC_RICING_SOCKET");
    if (argc != 2 || ((!socket_path || !*socket_path) && (!state || !*state) && !home)) {
        return 2;
    }

    struct sockaddr_un address = {.sun_family = AF_UNIX};
    int path_length;
    if (socket_path && *socket_path) {
        path_length = snprintf(address.sun_path, sizeof(address.sun_path), "%s", socket_path);
    } else if (state && *state) {
        path_length = snprintf(address.sun_path, sizeof(address.sun_path), "%s/switch.sock", state);
    } else {
        path_length = snprintf(address.sun_path, sizeof(address.sun_path), "%s/.local/state/mac-ricing/switch.sock", home);
    }
    if (path_length < 0 || (size_t)path_length >= sizeof(address.sun_path)) {
        fputs("Workspace socket path is too long\n", stderr);
        return 2;
    }
    address.sun_len = offsetof(struct sockaddr_un, sun_path) + path_length + 1;

    char message[64];
    int length = snprintf(message, sizeof(message), "%" PRIu64 " %s", sent, argv[1]);
    if (length < 0 || (size_t)length >= sizeof(message)) {
        return 2;
    }

    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("workspace request socket");
        return 1;
    }
    ssize_t written;
    do {
        written = sendto(fd, message, length, 0, (const struct sockaddr *)&address, address.sun_len);
    } while (written < 0 && errno == EINTR);
    if (written != length) {
        perror("workspace request");
    }
    close(fd);
    return written == length ? 0 : 1;
}
