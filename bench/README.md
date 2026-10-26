# Benchmarks

The same small programs in Egg, C, Rust, Go and Zig, to see what Egg's
checks cost and how the generated code compares.

```sh
ruby bench/run.rb                # all programs, best of 5
ruby bench/run.rb matmul --runs 10
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

rust+ovf and zig-safe check what Egg checks, so they are the fair
comparison.

## Results

2026-10-26, Intel i7-9700K, macOS 14, Apple clang 15, rustc 1.99.1,
go 1.27.2, zig 0.17.0. Best of 10 runs; (Nx) is the time relative to c.

| program | c | egg | rust | rust+ovf | go | zig-safe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| collatz | 728 ms | 768 ms (1.05x) | 404 ms (0.56x) | 983 ms (1.35x) | 625 ms (0.86x) | 944 ms (1.30x) |
| fib | 231 ms | 353 ms (1.53x) | 238 ms (1.03x) | 371 ms (1.61x) | 408 ms (1.77x) | 346 ms (1.50x) |
| matmul | 266 ms | 623 ms (2.35x) | 335 ms (1.26x) | 272 ms (1.02x) | 315 ms (1.19x) | 277 ms (1.04x) |
| sieve | 394 ms | 388 ms (0.98x) | 395 ms (1.00x) | 398 ms (1.01x) | 364 ms (0.92x) | 389 ms (0.99x) |

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
