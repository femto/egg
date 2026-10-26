# Benchmarks

The same small programs in Egg, C, Rust, Go, Zig, Python and Ruby, to see what Egg's
checks cost and how the generated code compares.

```sh
ruby bench/run.rb                # all programs, best of 5
ruby bench/run.rb matmul --runs 10
ruby bench/run.rb --slow         # also Python and Ruby: about 7 minutes
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
| ruby | CRuby; only with `--slow`, 1 run |

rust+ovf and zig-safe check what Egg checks, so they are the fair
comparison.

## Results

2026-10-26, Intel i7-9700K, macOS 14, Apple clang 15, rustc 1.99.1,
go 1.27.2, zig 0.17.0, CPython 3.11.4, PyPy 7.3.17 (Python 2.7),
Ruby 3.2.0 (built without YJIT). `ruby bench/run.rb --slow --runs 10`:
best of 10 runs for compiled programs, 1 run for interpreters; (Nx) is the
time relative to c.

| program | c | egg | rust | rust+ovf | go | zig-safe | python | pypy | ruby |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| collatz | 720 ms | 767 ms (1.07x) | 403 ms (0.56x) | 988 ms (1.37x) | 621 ms (0.86x) | 961 ms (1.34x) | 39848 ms (55x) | 1349 ms (1.87x) | 19028 ms (26x) |
| fib | 230 ms | 351 ms (1.53x) | 239 ms (1.04x) | 372 ms (1.62x) | 409 ms (1.78x) | 348 ms (1.51x) | 21760 ms (95x) | 3167 ms (14x) | 10224 ms (44x) |
| matmul | 255 ms | 590 ms (2.31x) | 347 ms (1.36x) | 283 ms (1.11x) | 354 ms (1.39x) | 313 ms (1.23x) | 88098 ms (345x) | 1370 ms (5.37x) | 41970 ms (164x) |
| sieve | 377 ms | 414 ms (1.10x) | 377 ms (1.00x) | 392 ms (1.04x) | 385 ms (1.02x) | 450 ms (1.19x) | 10253 ms (27x) | 897 ms (2.38x) | 8723 ms (23x) |

With every integer operation and index checked, Egg runs these programs:

| against | sieve | collatz | fib | matmul |
| --- | ---: | ---: | ---: | ---: |
| CPython | 25x faster | 52x | 62x | 149x |
| Ruby | 21x | 25x | 29x | 71x |
| PyPy | 2.2x | 1.8x | 9.0x | 2.3x |

The Python and Ruby versions are plain loops, as the other versions are;
NumPy would make matmul in Python hundreds of times faster. Interpreters
run once, so their times vary more between runs (PyPy's fib took 2.0 s in
an earlier run).

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
