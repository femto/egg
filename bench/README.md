# Benchmarks

The same small programs in Egg, C, Rust, Go, Zig and Python, to see what Egg's
checks cost and how the generated code compares.

```sh
ruby bench/run.rb                # all programs, best of 5
ruby bench/run.rb matmul --runs 10
ruby bench/run.rb --slow         # also Python: takes about 3 minutes
```

Toolchains that are not on PATH are skipped. Executables go to
`bench/build/` (ignored by git). Every version of a program must print
the same output, or the run fails.

| program | what it exercises |
| --- | --- |
| fib | recursive calls, checked `+` and `-` (fib(40)) |
| sieve | a 50 MB `Buf(bool)` written and read by index: bounds checks |
| matmul | 800×800 `i64` multiply over flat buffers: checked `*`, `+` and indexing |
| collatz | `/`, `%` and `*` in a data-dependent loop |

| variant | checks |
| --- | --- |
| c | none (`cc -O2`): the baseline |
| egg | overflow and bounds (`eggc build`, `cc -O2`) |
| rust | bounds; overflow wraps (`rustc -O`) |
| rust+ovf | bounds and overflow (`-C overflow-checks=on`) |
| go | bounds; overflow wraps |
| zig-safe | bounds and overflow (`-O ReleaseSafe`) |
| python | CPython 3; only with `--slow`, 1 run |
| pypy | PyPy, a JIT; only with `--slow`, 1 run |

rust+ovf and zig-safe check what Egg checks, so they are the fair
comparison.

## Results

2026-10-26, Intel i7-9700K, macOS 14, Apple clang 15, rustc 1.99.1,
go 1.27.2, zig 0.17.0, CPython 3.11.4, PyPy 7.3.17 (Python 2.7).
`ruby bench/run.rb --slow --runs 10`: best of 10 runs for compiled
programs, 1 run for interpreters; (Nx) is the time relative to c.

| program | c | egg | rust | rust+ovf | go | zig-safe | python | pypy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| collatz | 716 ms | 754 ms (1.05x) | 402 ms (0.56x) | 984 ms (1.37x) | 604 ms (0.84x) | 937 ms (1.31x) | 38548 ms (54x) | 1353 ms (1.89x) |
| fib | 229 ms | 350 ms (1.53x) | 237 ms (1.04x) | 369 ms (1.61x) | 406 ms (1.78x) | 343 ms (1.50x) | 20062 ms (88x) | 1995 ms (8.73x) |
| matmul | 252 ms | 558 ms (2.22x) | 300 ms (1.19x) | 278 ms (1.10x) | 316 ms (1.26x) | 257 ms (1.02x) | 83300 ms (331x) | 1313 ms (5.22x) |
| sieve | 367 ms | 391 ms (1.07x) | 362 ms (0.99x) | 374 ms (1.02x) | 366 ms (1.00x) | 373 ms (1.02x) | 8224 ms (22x) | 695 ms (1.89x) |

Egg runs these programs **21 to 149 times faster than CPython** (sieve 21x,
collatz 51x, fib 57x, matmul 149x), with every integer operation and index
checked. Against PyPy, Egg is 1.8x (collatz, sieve) to 5.7x (fib) faster.

Against the versions that check as much as Egg does (rust+ovf, zig-safe):

- **fib**, **sieve**: the same cost.
- **collatz**: Egg is faster. A division only needs a check for zero and
  for the minimum divided by -1, both cheap compares, and there is no
  builtin to use instead.
- **matmul**: still about 2x. The inner loop checks bounds on every
  element; Apple clang 15 leaves those checks in the loop, while the newer
  LLVM in rustc and zig moves them out. Closing the gap would take bounds
  check elimination in eggc.

Before #6, `egg_mul` checked overflow with a division (`r / b != a`): a
64-bit `idiv` for every multiply whose operands are not zero. matmul took
5806 ms (20.89x) and fib 594 ms (2.57x). With gcc 5+ or clang, add, sub and
mul now use `__builtin_*_overflow`, which compiles to the CPU's overflow
flag. Other compilers, or `-DEGG_PORTABLE`, get the portable checks.
