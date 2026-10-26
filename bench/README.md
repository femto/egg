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
go 1.27.2, zig 0.17.0. Best of 5 runs; (Nx) is the time relative to c.

| program | c | egg | rust | rust+ovf | go | zig-safe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| collatz | 721 ms | 739 ms (1.02x) | 403 ms (0.56x) | 1010 ms (1.40x) | 619 ms (0.86x) | 1025 ms (1.42x) |
| fib | 231 ms | 594 ms (2.57x) | 238 ms (1.03x) | 372 ms (1.61x) | 407 ms (1.76x) | 359 ms (1.55x) |
| matmul | 278 ms | 5806 ms (20.89x) | 316 ms (1.14x) | 309 ms (1.11x) | 308 ms (1.11x) | 286 ms (1.03x) |
| sieve | 394 ms | 403 ms (1.02x) | 370 ms (0.94x) | 380 ms (0.96x) | 364 ms (0.93x) | 393 ms (1.00x) |

- **matmul**: `egg_mul` checks for overflow with a division (`r / b != a`),
  one 64-bit `idiv` per multiply. Rust and Zig use the CPU's overflow flag
  instead. Replacing the check with `__builtin_mul_overflow` made this
  program about 10 times faster in a hand-edited copy of the generated C.
- **fib**: `egg_add` / `egg_sub` compare against the limits before adding;
  the checked Rust and Zig versions cost half as much over C.
- **sieve**, **collatz**: bounds checks and division checks cost little;
  Egg is within a few percent of C.
