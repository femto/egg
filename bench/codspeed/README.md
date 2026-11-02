# CodSpeed benchmarks

[CodSpeed](https://codspeed.io) runs the benchmarks in `codspeed.yaml` (at the
repository root) on every push to main and on pull requests, with its CPU
simulation instrument, and reports any change in performance on the PR.

There are three groups:

| group | what it measures |
| --- | --- |
| `compile ...`, `diagnose ...` | the compiler in one process (`compile.rb`): lexing, parsing, checking and C generation of the examples, and the diagnostics for `test/errors` |
| `eggc ...` | the eggc command line, Ruby start-up included |
| `run ...` | the code eggc generates: the programs here, built with `eggc build` |

The programs here are the ones in `bench/egg/` with smaller inputs (fib(30),
a 5M sieve, collatz up to 300K, a 200×200 matmul), so that each run takes a
few milliseconds natively and stays quick under simulation. `multiply` in
`matmul.egg` takes its buffers with `sink`, which the current compiler
requires (`bench/egg/matmul.egg` does not build without it).

```sh
ruby bench/codspeed/build.rb                 # build into bench/build/codspeed/
codspeed run -m simulation                   # needs the CodSpeed CLI
```
