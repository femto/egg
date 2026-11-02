// The Egg HTTP example's design in Go: 8 goroutines on a queue of 16, a
// logger, keep-alive, the file read for each request.
package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

func respond(c net.Conn, status, kind string, body []byte, keep bool) error {
	conn := "close"
	if keep {
		conn = "keep-alive"
	}
	head := fmt.Sprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n", status, kind, len(body), conn)
	if _, err := c.Write([]byte(head)); err != nil {
		return err
	}
	_, err := c.Write(body)
	return err
}

func handle(c net.Conn, root string, log chan<- string) {
	r := bufio.NewReader(c)
	for served := 1; served <= 100; served++ {
		c.SetDeadline(time.Now().Add(2 * time.Second))
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		c.SetDeadline(time.Now().Add(5 * time.Second))
		closeIt := false
		for {
			h, err := r.ReadString('\n')
			if err != nil {
				return
			}
			h = strings.TrimRight(h, "\r\n")
			if h == "" {
				break
			}
			l := strings.ToLower(h)
			if strings.HasPrefix(l, "connection:") && strings.Contains(l, "close") {
				closeIt = true
			}
		}
		parts := strings.Fields(line)
		if len(parts) != 3 {
			return
		}
		path := parts[1]
		keep := !closeIt && parts[2] == "HTTP/1.1" && served < 100
		full := root + path
		if strings.HasSuffix(path, "/") {
			full += "index.html"
		}
		kind := "application/octet-stream"
		if strings.HasSuffix(full, ".html") {
			kind = "text/html; charset=utf-8"
		}
		status := 200
		body, err := os.ReadFile(full)
		if err != nil {
			status = 404
			err = respond(c, "404 Not Found", "text/plain", []byte("not found\n"), keep)
		} else {
			err = respond(c, "200 OK", kind, body, keep)
		}
		if err != nil {
			return
		}
		log <- fmt.Sprintf("%d %s %s", status, parts[0], path)
		if !keep {
			return
		}
	}
}

func main() {
	root := os.Args[1]
	s, err := net.Listen("tcp", "127.0.0.1:"+os.Args[2])
	if err != nil {
		panic(err)
	}
	logs := make(chan string, 64)
	go func() {
		w := bufio.NewWriter(os.Stdout)
		for l := range logs {
			fmt.Fprintln(w, l)
			w.Flush()
		}
	}()
	jobs := make(chan net.Conn, 16)
	for i := 0; i < 8; i++ {
		go func() {
			for c := range jobs {
				handle(c, root, logs)
				c.Close()
			}
		}()
	}
	for {
		c, err := s.Accept()
		if err == nil {
			jobs <- c
		}
	}
}
