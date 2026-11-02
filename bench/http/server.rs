// The Egg HTTP example's design in Rust, std only: 8 threads on a queue of 16,
// a logger thread, keep-alive, the file read for each request.
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn respond(c: &mut &TcpStream, status: &str, kind: &str, body: &[u8], keep: bool) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: {}\r\n\r\n",
        status, kind, body.len(), if keep { "keep-alive" } else { "close" }
    );
    c.write_all(head.as_bytes())?;
    c.write_all(body)
}

fn timeouts(c: &TcpStream, ms: u64) -> std::io::Result<()> {
    c.set_read_timeout(Some(Duration::from_millis(ms)))?;
    c.set_write_timeout(Some(Duration::from_millis(ms)))
}

fn handle(c: &TcpStream, root: &str, log: &SyncSender<String>) -> std::io::Result<()> {
    let mut r = BufReader::new(c);
    let mut line = Vec::new();
    let mut header = Vec::new();
    for served in 1..=100 {
        timeouts(c, 2000)?;
        line.clear();
        if r.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        timeouts(c, 5000)?;
        let mut close = false;
        loop {
            header.clear();
            if r.read_until(b'\n', &mut header)? == 0 {
                return Ok(());
            }
            let h = String::from_utf8_lossy(&header).trim_end().to_ascii_lowercase();
            if h.is_empty() {
                break;
            }
            if h.starts_with("connection:") && h.contains("close") {
                close = true;
            }
        }
        let text = String::from_utf8_lossy(&line);
        let parts: Vec<&str> = text.split_whitespace().collect();
        if parts.len() != 3 {
            return Ok(());
        }
        let path = parts[1];
        let keep = !close && parts[2] == "HTTP/1.1" && served < 100;
        let mut full = format!("{}{}", root, path);
        if path.ends_with('/') {
            full.push_str("index.html");
        }
        let kind = if full.ends_with(".html") { "text/html; charset=utf-8" } else { "application/octet-stream" };
        let mut w = c;
        let status = match std::fs::read(&full) {
            Ok(body) => {
                respond(&mut w, "200 OK", kind, &body, keep)?;
                200
            }
            Err(_) => {
                respond(&mut w, "404 Not Found", "text/plain", b"not found\n", keep)?;
                404
            }
        };
        let _ = log.send(format!("{} {} {}", status, parts[0], path));
        if !keep {
            return Ok(());
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let root = args[1].clone();
    let server = TcpListener::bind(("127.0.0.1", args[2].parse::<u16>().unwrap())).unwrap();
    let (log, logs): (SyncSender<String>, Receiver<String>) = sync_channel(64);
    std::thread::spawn(move || {
        let out = std::io::stdout();
        for l in logs {
            let _ = writeln!(out.lock(), "{}", l);
        }
    });
    let (queue, jobs) = sync_channel::<TcpStream>(16);
    let jobs = Arc::new(Mutex::new(jobs));
    for _ in 0..8 {
        let (jobs, root, log) = (jobs.clone(), root.clone(), log.clone());
        std::thread::spawn(move || loop {
            let c = jobs.lock().unwrap().recv().unwrap();
            let _ = handle(&c, &root, &log);
        });
    }
    for c in server.incoming().flatten() {
        queue.send(c).unwrap();
    }
}
