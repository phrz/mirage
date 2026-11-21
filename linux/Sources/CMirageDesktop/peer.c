// The local control socket's peer: who is on the other end (SO_PEERCRED needs _GNU_SOURCE, which Swift cannot define).
#define _GNU_SOURCE
#include <sys/socket.h>
#include "md.h"

int md_peer_uid(int fd, uint32_t *uid) {
    struct ucred c;
    socklen_t len = sizeof c;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &c, &len) != 0) return -1;
    *uid = c.uid;
    return 0;
}
