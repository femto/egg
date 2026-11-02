// The usual Node server: http, one thread, files read asynchronously.
const http = require("http");
const fs = require("fs");

const [root, port] = process.argv.slice(2);
http.createServer((req, res) => {
  let full = root + req.url.split("?")[0];
  if (full.endsWith("/")) full += "index.html";
  fs.readFile(full, (err, body) => {
    if (err) {
      res.writeHead(404);
      res.end("not found\n");
      return;
    }
    res.writeHead(200, { "Content-Type": "application/octet-stream", "Content-Length": body.length });
    res.end(body);
  });
}).listen(Number(port), "127.0.0.1");
