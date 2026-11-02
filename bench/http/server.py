# The Egg HTTP example's design in Python: 8 threads on a queue of 16, a logger
# thread, keep-alive, the file read for each request.
import queue
import socket
import sys
import threading


def respond(c, status, kind, body, keep):
    conn = "keep-alive" if keep else "close"
    head = f"HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {len(body)}\r\nConnection: {conn}\r\n\r\n"
    c.sendall(head.encode())
    c.sendall(body)


def handle(c, root, logs):
    r = c.makefile("rb")
    for served in range(1, 101):
        c.settimeout(2)
        line = r.readline(8192)
        if not line:
            return
        c.settimeout(5)
        close = False
        while True:
            h = r.readline(8192)
            if not h:
                return
            h = h.strip().lower()
            if not h:
                break
            if h.startswith(b"connection:") and b"close" in h:
                close = True
        parts = line.decode("latin-1").split()
        if len(parts) != 3:
            return
        path = parts[1]
        keep = not close and parts[2] == "HTTP/1.1" and served < 100
        full = root + path
        if path.endswith("/"):
            full += "index.html"
        kind = "text/html; charset=utf-8" if full.endswith(".html") else "application/octet-stream"
        try:
            with open(full, "rb") as f:
                body = f.read()
            status = 200
            respond(c, "200 OK", kind, body, keep)
        except FileNotFoundError:
            status = 404
            respond(c, "404 Not Found", "text/plain", b"not found\n", keep)
        logs.put(f"{status} {parts[0]} {path}")
        if not keep:
            return


def work(jobs, root, logs):
    while True:
        c = jobs.get()
        try:
            handle(c, root, logs)
        except OSError:
            pass
        c.close()


def logger(logs):
    while True:
        print(logs.get(), flush=True)


def main():
    root, port = sys.argv[1], int(sys.argv[2])
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(128)
    logs = queue.Queue(64)
    threading.Thread(target=logger, args=(logs,), daemon=True).start()
    jobs = queue.Queue(16)
    for _ in range(8):
        threading.Thread(target=work, args=(jobs, root, logs), daemon=True).start()
    while True:
        jobs.put(s.accept()[0])


main()
