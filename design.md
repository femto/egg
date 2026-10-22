# Egg Language Design

Bingnan Zheng · 2026-10-22

English · [中文](design.zh.md)

## Overview

Egg is an AI-native systems language whose core has no capabilities at all: GC, exceptions, IO and allocation are capability modules that each program declares on demand. The name says it: everything hatches from a minimal egg.

Three principles:

1. **The core has nothing.** No GC, no exceptions, no hidden allocation, no IO, no dependency on an operating system.
2. **Capabilities are declared and checked recursively.** A module declares what it needs, and the compiler walks the call graph to confirm nothing exceeds it.
3. **Designed for AI.** The core is small enough to fit in a model's context, and every capability ships with a machine-readable spec, examples and tests.

One structural payoff: **the runtime is the restricted subset.** Go constrains its runtime with special rules such as `nosplit` and `nowritebarrier`. Egg needs none: the GC and exception machinery are capability libraries written in core code that declares no capabilities, and the compiler is an ordinary program that declares `alloc`, `gc` and `io`. The lowest layer is restricted by construction, and the compiler checks it.

A second payoff: **the core is portable by construction**, because everything that touches an operating system lives in a capability module.

## Core language

The core follows Zig but stays smaller: it keeps only features that need no runtime support. Function signatures must spell out types; bodies may infer them. This avoids whole-program type inference, which makes compilation slow and hard to make incremental.

| Area | Contents | First version |
| --- | --- | --- |
| Integers | `i8`…`i64`, `u8`…`u64`, `usize` | v0 (`i64` only) |
| Other primitives | `bool`, `f32`, `f64`, `void` | v0 |
| Composite types | `struct`, `enum`, tagged unions | v1 |
| Pointers and memory | single-item pointers, slices, arrays | v1 |
| Control flow | `if`, `while`, `for`, `switch`, all expressions | v0 (`if`, `while` first) |
| Errors | errors as values (like `!T`), `try` | v1 |
| Compile time | `comptime` parameters, generics (functions returning `type`), reflection | v1 |

**Type syntax is prefix and reads left to right**, as in Go and Zig. Every modifier sits on the left of the type it modifies:

| Type | Reads as |
| --- | --- |
| `[4]u8` | array of 4 bytes, length part of the type |
| `[3][4]u8` | 3 rows of 4 bytes; indexed `grid[2][3]` in the same order |
| `[]u8` | slice: pointer plus runtime length |
| `*[4]u8` | pointer to an array of 4 bytes |
| `?*T` | optional pointer |
| `!T` | a `T` or an error |

Rust's `[u8; 4]` was considered and rejected: it is the only form that puts the element type in the middle, and nested arrays read inside out.

Kept out of the core on purpose:

- Operator overloading and implicit conversions: mildly annoying for people, clearer for AI and reviewers
- Closures: capturing an environment usually means allocating, so it belongs to a capability
- Exceptions, GC, heap allocation, IO: all capability modules

Errors as values are in the core because they are just a return value plus a tag. Exceptions need stack unwinding, so they are not.

v0 syntax (tentative):

```
fn fib(n: i64) i64 {
    if (n < 2) { return n }
    return fib(n - 1) + fib(n - 2)
}

fn main() i64 {
    return fib(20)
}
```

## Capability system

A module declares its capabilities at the top; the compiler infers what each function actually uses and checks it recursively. Only public APIs must state their capabilities. A module that declares none is pure core code.

Core only, no capabilities:

```
fn hash(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325
    for (bytes) |b| { h = (h ^ b) * 0x100000001b3 }
    return h
}
```

Declaring what it needs:

```
use cap.alloc
use cap.io

fn read_config(a: Allocator, path: []const u8) !Config {
    const text = try io.read_file(a, path)
    defer a.free(text)
    return parse(text)
}
```

First capabilities:

| Capability | Provides | Planned |
| --- | --- | --- |
| `alloc` | heap allocation, allocator passed explicitly | v2 |
| `io` | files and standard streams, one implementation per OS | v2 |
| `gc` | GC-managed objects, implemented in core code | v3 |
| `raise` | raising and catching exceptions, implemented in core code | after v3 |

Checking rules:

1. A function may not use a capability its module did not declare.
2. The compiler infers each function's capability set along the call graph, including indirect calls.
3. A public function's capability set appears in its signature, or tooling generates it into the docs.
4. Values crossing a capability boundary follow boundary rules; for example, a GC object passed to a non-GC module must be pinned or copied.

The exact boundary rules are not settled; see Open questions.

## AI-native features

Egg assumes an AI learns the language in context rather than from training data: a new, user-extensible language has almost no training data, so its spec itself must be readable by a model.

- **Machine-readable spec** in the repo's `spec/` directory, with the full core definition small enough to load into context at once.
- **Every capability module ships three things**: a spec, examples and tests. A capability without them cannot be published.
- **Structured diagnostics**: the compiler can emit errors as JSON with location, rule number and suggested fixes, so an AI can repair code on its own.
- **One canonical format**: a built-in formatter with no options, so generated code is uniform.
- **Regular, unambiguous syntax**: one way to write each construct, no operator overloading, no implicit conversions.
- **Capability checks as a safety net**: generated code may be wrong, but the compiler guarantees it uses no undeclared capability.

Code somewhat longer than Rust is an acceptable cost: when most code is generated, explicitness helps both the AI and the reviewer see what it does.

## Compiler architecture

The first compiler, `eggc`, is written in the Ruby subset Spinel can compile: it runs directly on CRuby during development and is compiled to a native binary with Spinel for release. It emits C and hands it to the system C compiler.

Pipeline:

1. Lexing (`lexer.rb`)
2. Recursive-descent parsing into an AST (`parser.rb`)
3. Type checking (`typecheck.rb`)
4. Capability checking, from v2 (`caps.rb`)
5. C code generation (`codegen_c.rb`)
6. Invoking the C compiler to produce an executable

Layout:

```
egg/
├── bin/eggc
├── lib/egg/
│   ├── lexer.rb
│   ├── ast.rb
│   ├── parser.rb
│   ├── typecheck.rb
│   ├── caps.rb
│   └── codegen_c.rb
├── spec/          # machine-readable language spec
├── examples/
└── test/
```

Coding rules (to stay inside the Spinel subset):

- No `send`, `define_method`, `method_missing` or `eval`.
- AST nodes are `Struct`s, handled with `case … in` pattern matching rather than double-dispatch visitors.
- Every `case … in` ends with an `else` that raises a clear error naming the node type, since Ruby does not check exhaustiveness.
- No gems; the parser is hand-written.
- Test early how well Spinel infers types for an array holding several node types; if it struggles, switch to a single `Node` class with a `kind` field.

These rules also prepare for rewriting the compiler in Egg: `case … in` maps almost one to one onto Egg's `switch` over tagged unions.

## Bootstrapping and portability

The bootstrap chain starts from a C compiler and contains no prebuilt binary that must be trusted. Users need only a C compiler, not Ruby.

Chain:

1. A C compiler builds CRuby.
2. CRuby runs the `eggc` Ruby sources directly and compiles Egg programs to C.
3. Optional: Spinel compiles `eggc` to a native binary for speed.
4. From v4: `eggc` is rewritten in Egg and compiled by the previous generation.
5. Check: the second- and third-generation compilers produce byte-identical output.

Distribution follows Nim and Zig: ship the C that `eggc` generates, and users build it with any C compiler (MSVC, clang, MinGW).

Windows:

- CRuby and Spinel are developer tools; Windows users never need them.
- `zig cc -target x86_64-windows-gnu` cross-compiles a Windows build from Linux.
- Windows developers can work in WSL.
- Spinel already has a native Windows build (MinGW-w64 against the UCRT, see its win32.mk), so a Spinel-compiled eggc can ship as a Windows binary.

The C that Egg generates must be portable from day one:

- Standard C only (C99 or C11); the core calls no POSIX API.
- All platform-specific code lives in capability modules; for example, `cap.io` has one implementation each for Linux, macOS and Windows, chosen at comptime by target.

## Roadmap

Each phase ends at a gate that can be checked automatically. v3 is the first real test of the runtime-is-the-subset design; v4 is self-hosting.

| Phase | Scope | Acceptance gate |
| --- | --- | --- |
| v0 · Core subset | `i64`, functions, `if`, `while`, `return`; emits C for the system C compiler | `fib.egg` compiles and prints 6765 |
| v1 · Types and comptime | `struct`, `enum`, tagged unions, slices; error values, comptime generics, reflection | Generic `Pair` and error-value examples pass their tests |
| v2 · Capability checks | `alloc` and `io` capabilities; recursive check along the call graph | Programs using undeclared capabilities are rejected |
| v3 · GC written in core | `gc` library uses only core code | `gc` declares no capabilities and passes the capability check |
| v4 · Self-hosting | `eggc` rewritten in Egg, compiled by the previous generation | Generation 2 and 3 output is byte-identical |

## Open questions

- [ ] Semicolons at the end of statements? The examples omit them; weigh against parser simplicity.
- [ ] Syntax for capabilities in signatures: `fn f() !void with io`, or only module-level declarations with generated docs?
- [ ] Granularity: is `io` one capability, or split into `fs`, `net` and `stdio`?
- [ ] Rules for GC objects crossing a capability boundary: pin, copy or forbid?
- [ ] Conservative scanning or a shadow stack with precise scanning for the GC? The latter allows a moving GC but costs something on every call.
- [ ] Exceptions via `setjmp`/`longjmp` or a check after every call? The latter fits a shadow stack more simply.
- [ ] How does comptime run in the Spinel-written compiler: interpret the AST, or generate C and run it?
- [ ] Can users define their own capabilities, or does the first version ship only built-in ones?
