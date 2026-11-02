// The usual Go server: net/http, a goroutine per connection.
package main

import (
	"net/http"
	"os"
	"strconv"
	"strings"
)

func main() {
	root := os.Args[1]
	http.ListenAndServe("127.0.0.1:"+os.Args[2], http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		full := root + r.URL.Path
		if strings.HasSuffix(full, "/") {
			full += "index.html"
		}
		body, err := os.ReadFile(full)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "application/octet-stream")
		h.Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(body)
	}))
}
