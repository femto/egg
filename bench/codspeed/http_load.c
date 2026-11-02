// Load client for the CodSpeed HTTP benchmarks (codspeed.yaml).
//
//   http_load PATH CONNS REQS -- SERVER [ARGS...]
//
// Starts SERVER with ARGS, the www root and a free port, waits until it
// accepts connections, then makes CONNS keep-alive connections one after
// the other and sends REQS GET requests for PATH on each. Every response
// must be a 200 with a body of Content-Length bytes. It then stops the
// server with SIGTERM. The client is plain C and does the same work for
// every server, so the difference between benchmarks is the server.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static pid_t server = -1;

static void fail(const char *what) {
    fprintf(stderr, "http_load: %s\n", what);
    if (server > 0) {
        kill(server, SIGKILL);
        waitpid(server, NULL, 0);
    }
    exit(1);
}

static int free_port(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET };
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t n = sizeof a;
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) != 0 || getsockname(s, (struct sockaddr *)&a, &n) != 0)
        fail("no free port");
    close(s);
    return ntohs(a.sin_port);
}

static int dial(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
    if (s >= 0) close(s);
    return -1;
}

typedef struct {
    int fd, pos, end;
    char buf[65536];
} conn;

static int fill(conn *c) {
    ssize_t r;
    do r = recv(c->fd, c->buf, sizeof c->buf, 0);
    while (r < 0 && errno == EINTR);
    if (r <= 0) return -1;
    c->pos = 0;
    c->end = (int)r;
    return 0;
}

static int read_line(conn *c, char *out, int max) {
    int n = 0;
    for (;;) {
        if (c->pos == c->end && fill(c) != 0) return -1;
        char ch = c->buf[c->pos++];
        if (ch == '\n') break;
        if (n == max - 1) return -1;
        out[n++] = ch;
    }
    if (n > 0 && out[n - 1] == '\r') n--;
    out[n] = 0;
    return n;
}

// Reads one response; returns 0 for a 200 with its whole body.
static int response(conn *c) {
    char line[1024];
    if (read_line(c, line, sizeof line) < 0) return -1;
    if (strncmp(line, "HTTP/1.1 200", 12) != 0) {
        fprintf(stderr, "http_load: got \"%s\"\n", line);
        return -1;
    }
    long length = -1;
    for (;;) {
        int n = read_line(c, line, sizeof line);
        if (n < 0) return -1;
        if (n == 0) break;
        if (strncasecmp(line, "content-length:", 15) == 0) length = strtol(line + 15, NULL, 10);
    }
    if (length < 0) return -1;
    while (length > 0) {
        if (c->pos == c->end && fill(c) != 0) return -1;
        int take = c->end - c->pos;
        if (take > length) take = (int)length;
        c->pos += take;
        length -= take;
    }
    return 0;
}

static void send_all(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) fail("send failed");
        p += w;
        n -= (size_t)w;
    }
}

int main(int argc, char **argv) {
    if (argc < 6 || strcmp(argv[4], "--") != 0) {
        fprintf(stderr, "usage: http_load PATH CONNS REQS -- SERVER [ARGS...]\n");
        return 2;
    }
    const char *path = argv[1];
    int conns = atoi(argv[2]), reqs = atoi(argv[3]);
    // The servers close a connection after 100 requests.
    if (conns < 1 || reqs < 1 || reqs > 99) fail("CONNS must be at least 1, REQS from 1 to 99");

    char www[4096];
    const char *self = strrchr(argv[0], '/');
    snprintf(www, sizeof www, "%.*swww", self == NULL ? 0 : (int)(self - argv[0] + 1), argv[0]);
    int port = free_port();
    char port_s[16];
    snprintf(port_s, sizeof port_s, "%d", port);

    int nargs = argc - 5;
    char **cmd = calloc((size_t)nargs + 3, sizeof *cmd);
    for (int i = 0; i < nargs; i++) cmd[i] = argv[5 + i];
    cmd[nargs] = www;
    cmd[nargs + 1] = port_s;

    server = fork();
    if (server < 0) fail("fork failed");
    if (server == 0) {
        // The servers log every request: keep that out of the output.
        freopen("/dev/null", "w", stdout);
        execvp(cmd[0], cmd);
        perror(cmd[0]);
        _exit(127);
    }

    // Under simulation the servers start slowly: wait up to 5 minutes.
    int probe = -1;
    for (int i = 0; i < 3000 && probe < 0; i++) {
        if (waitpid(server, NULL, WNOHANG) == server) {
            server = -1;
            fail("the server exited before accepting connections");
        }
        probe = dial(port);
        if (probe < 0) nanosleep(&(struct timespec){ 0, 100 * 1000 * 1000 }, NULL);
    }
    if (probe < 0) fail("the server did not start");
    close(probe);

    char request[1024];
    int n = snprintf(request, sizeof request, "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: http_load\r\nAccept: */*\r\n\r\n", path);
    conn *c = malloc(sizeof *c);
    for (int i = 0; i < conns; i++) {
        c->fd = dial(port);
        c->pos = c->end = 0;
        if (c->fd < 0) fail("connect failed");
        for (int j = 0; j < reqs; j++) {
            send_all(c->fd, request, (size_t)n);
            if (response(c) != 0) {
                fprintf(stderr, "http_load: connection %d, request %d\n", i + 1, j + 1);
                fail("bad response");
            }
        }
        close(c->fd);
    }

    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    return 0;
}
