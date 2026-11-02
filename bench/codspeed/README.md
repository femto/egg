# CodSpeed benchmarks

[CodSpeed](https://codspeed.io) runs the benchmarks in `codspeed.yaml` (at the
repository root) on every push to main and on pull requests, with its CPU
simulation instrument, and reports any change in performance on the PR.

There are four groups:

| group | what it measures |
| --- | --- |
| `compile ...`, `diagnose ...` | the compiler in one process (`compile.rb`): lexing, parsing, checking and C generation of the examples, and the diagnostics for `test/errors` |
| `eggc ...` | the eggc command line, Ruby start-up included |
| `run ...` | the code eggc generates: the programs here, built with `eggc build` |
| `http ...` | the HTTP servers of `bench/http/` against `examples/http_server`: egg, c, rust, go-pool, go-net/http and python, each serving `/index.html` (12 B) and `/10k.bin` (10 KiB) |

The programs here are the ones in `bench/egg/` with smaller inputs (fib(30),
a 5M sieve, collatz up to 300K, a 200×200 matmul), so that each run takes a
few milliseconds natively and stays quick under simulation.

For the `http` benchmarks, `http_load.c` starts a server, waits until it
accepts connections, sends 200 GET requests on 4 keep-alive connections,
checks that each response is a 200 with the whole body, and stops it. The
client is the same for every server, about a tenth of the measure of the egg
one. Simulation counts the CPU work in user space (start-up, parsing
requests, building responses, the logger thread) and not the time in system
calls or waiting, so these benchmarks compare how much CPU each server spends
per request; `ruby bench/http.rb` still measures throughput and latency with
`wrk`. Two notes:

- node is left out: CodSpeed does not measure the node binary itself, so its
  number would be meaningless.
- The Go servers are built without cgo and run with
  `GODEBUG=asyncpreemptoff=1`: valgrind, which the simulation uses, does not
  handle Go's cgo start-up or its preemption signals.

Because `http_load` starts the server as a child process, the workflow sets
`simulation-track-subprocess: true` (CodSpeed runner 5.2 or later). Building
the servers needs `cc`, `rustc` and `go`.

```sh
ruby bench/codspeed/build.rb                 # build into bench/build/codspeed/
codspeed run -m simulation --simulation-track-subprocess   # needs the CodSpeed CLI
```
