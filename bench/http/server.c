// The Egg HTTP example's design in C: 8 workers on a queue of 16, a logger
// thread, keep-alive, the file read for each request.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

typedef struct {
    void **items;
    int cap, head, count;
    pthread_mutex_t lock;
    pthread_cond_t readable, writable;
} queue;

static void q_init(queue *q, int cap) {
    q->items = malloc(sizeof(void *) * cap);
    q->cap = cap;
    q->head = q->count = 0;
    pthread_mutex_init(&q->lock, NULL);
    pthread_cond_init(&q->readable, NULL);
    pthread_cond_init(&q->writable, NULL);
}

static void q_send(queue *q, void *v) {
    pthread_mutex_lock(&q->lock);
    while (q->count == q->cap) pthread_cond_wait(&q->writable, &q->lock);
    q->items[(q->head + q->count) % q->cap] = v;
    q->count++;
    pthread_cond_signal(&q->readable);
    pthread_mutex_unlock(&q->lock);
}

static void *q_recv(queue *q) {
    pthread_mutex_lock(&q->lock);
    while (q->count == 0) pthread_cond_wait(&q->readable, &q->lock);
    void *v = q->items[q->head];
    q->head = (q->head + 1) % q->cap;
    q->count--;
    pthread_cond_signal(&q->writable);
    pthread_mutex_unlock(&q->lock);
    return v;
}

static queue jobs, logs;
static const char *root;

typedef struct {
    int fd, pos, end;
    char buf[8192];
} conn;

static int read_line(conn *c, char *out, int max) {
    int n = 0;
    for (;;) {
        if (c->pos == c->end) {
            ssize_t r = recv(c->fd, c->buf, sizeof c->buf, 0);
            if (r <= 0) return -1;
            c->pos = 0;
            c->end = (int)r;
        }
        char ch = c->buf[c->pos++];
        if (ch == '\n') break;
        if (n == max - 1) return -1;
        out[n++] = ch;
    }
    if (n > 0 && out[n - 1] == '\r') n--;
    out[n] = 0;
    return n;
}

static int write_all(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t w = send(fd, p, n, 0);
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static void set_timeout(int fd, int ms) {
    struct timeval t = { ms / 1000, (ms % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof t);
}

static const char *content_type(const char *path) {
    size_t n = strlen(path);
    if (n >= 5 && strcmp(path + n - 5, ".html") == 0) return "text/html; charset=utf-8";
    return "application/octet-stream";
}

static int respond(conn *c, const char *status, const char *kind, const char *body, size_t n, int keep) {
    char head[256];
    int h = snprintf(head, sizeof head, "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: %s\r\n\r\n",
                     status, kind, n, keep ? "keep-alive" : "close");
    if (write_all(c->fd, head, (size_t)h) != 0) return -1;
    return write_all(c->fd, body, n);
}

static int serve(conn *c, const char *path, int keep) {
    char full[9000];
    snprintf(full, sizeof full, "%s%s%s", root, path, path[strlen(path) - 1] == '/' ? "index.html" : "");
    FILE *f = fopen(full, "rb");
    if (f == NULL) {
        if (respond(c, "404 Not Found", "text/plain", "not found\n", 10, keep) != 0) return -1;
        return 404;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *body = malloc((size_t)n + 1);
    size_t got = fread(body, 1, (size_t)n, f);
    fclose(f);
    int r = respond(c, "200 OK", content_type(full), body, got, keep);
    free(body);
    return r != 0 ? -1 : 200;
}

static void handle(conn *c) {
    char line[8192], header[8192];
    for (int served = 1; served <= 100; served++) {
        set_timeout(c->fd, 2000);
        if (read_line(c, line, sizeof line) < 0) return;
        set_timeout(c->fd, 5000);
        int close_it = 0;
        for (;;) {
            int n = read_line(c, header, sizeof header);
            if (n < 0) return;
            if (n == 0) break;
            if (strncasecmp(header, "connection:", 11) == 0 && strcasestr(header, "close")) close_it = 1;
        }
        char *space = strchr(line, ' ');
        char *end = space == NULL ? NULL : strchr(space + 1, ' ');
        if (end == NULL || end == space + 1) return;
        *space = 0;
        *end = 0;
        int keep = !close_it && strcmp(end + 1, "HTTP/1.1") == 0 && served < 100;
        int status = serve(c, space + 1, keep);
        if (status < 0) return;
        char *log = malloc(9000);
        snprintf(log, 9000, "%d %s %s", status, line, space + 1);
        q_send(&logs, log);
        if (!keep) return;
    }
}

static void *worker(void *arg) {
    (void)arg;
    conn *c = malloc(sizeof(conn));
    for (;;) {
        c->fd = (int)(intptr_t)q_recv(&jobs);
        c->pos = c->end = 0;
        handle(c);
        close(c->fd);
    }
}

static void *logger(void *arg) {
    (void)arg;
    for (;;) {
        char *s = q_recv(&logs);
        puts(s);
        free(s);
    }
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    root = argv[1];
    signal(SIGPIPE, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(argv[2])) };
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 128) != 0) return 1;
    q_init(&jobs, 16);
    q_init(&logs, 64);
    pthread_t t;
    pthread_create(&t, NULL, logger, NULL);
    for (int i = 0; i < 8; i++) pthread_create(&t, NULL, worker, NULL);
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c >= 0) q_send(&jobs, (void *)(intptr_t)c);
    }
}
