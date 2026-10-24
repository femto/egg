# Egg

An AI-native systems language with a core that has no capabilities at all.
GC, exceptions, IO and allocation are capability modules a program declares
on demand. See the design doc ([English](docs/design.md) · [中文](docs/design.zh.md))
for the full picture.

This repository holds **eggc**, the first compiler, now partway through
**v2** (modules, capabilities, integer types, pointers, `extern fn` and
owned buffers): written
in Ruby (aiming at the subset [Spinel](https://github.com/matz/spinel)
compiles), running on CRuby 3.0+, emitting portable C99.

```
uses io

const Shape = union(enum) {
    circle: i64
    rect: Size
    empty
}

const Size = struct { w: i64, h: i64 }

fn area(s: Shape) i64 {
    switch (s) {
        .circle => |r| { return 3 * r * r }
        .rect => |sz| { return sz.w * sz.h }
        .empty => { return 0 }
    }
}

fn total(shapes: []Shape) i64 {
    var sum = 0
    for (shapes) |s| {
        sum = sum + area(s)
    }
    return sum
}

fn main(out: Io) void {
    const shapes = [3]Shape{ Shape{ .circle = 2 }, Shape{ .rect = Size{ .w = 3, .h = 4 } }, .empty }
    out.print(total(shapes[0..]))   // 24
}
```

```bash
bin/eggc run examples/fib.egg        # 6765
bin/eggc emit-c examples/fib.egg     # show the generated C
bin/eggc build examples/fib.egg -o fib
bin/eggc check file.egg --json       # diagnostics as JSON lines
bin/eggc build -g examples/fib.egg   # debug build: gdb/lldb break on .egg lines
bin/eggc spec                        # whole spec, for pasting into an AI
bin/eggc lsp                         # language server for editors (stdin/stdout)
ruby test/run.rb                     # all tests (CC=clang to switch compilers)
```

### Native eggc

Spinel compiled eggc v0 to a native binary (about 30 s; it then starts in
~5 ms instead of ~350 ms and needs no Ruby). **The v1 compiler does not
build under Spinel yet**: Spinel currently emits C that fails to compile for
it, so use CRuby for v1. With v0 sources:

```bash
mkdir -p build/bin && spinel bin/eggc -o build/bin/eggc
EGGC=build/bin/eggc ruby test/run.rb # run the LSP tests against it
```

The VS Code extension prefers `build/bin/eggc` while it is newer than every
compiler source, and falls back to `bin/eggc` on Ruby once you edit one;
rebuild to switch back.

## What eggc supports

The full definition, with tested examples, is [spec/core.md](spec/core.md).

v2:

- Modules: `const m = @import("m.egg")`, then `m.f()`, `m.Point`,
  `m.Pair(i64)`; each file loaded once, cycles allowed; diagnostics name
  the file
- Capabilities: a file declares `uses alloc, io`; `main` receives the
  capability values (`fn main(out: Io, a: Allocator)`) and passes them
  down; `out.print(x)` replaces `@print`; `a.concat(s, t)` and
  `a.int_str(n)` build strings in a program-lifetime arena
- **Capability check** (E130): following the call graph across files and
  generic instances, a function that uses a capability its file does not
  declare is rejected; hover in the editor shows what each function uses
- Integer types `i8`…`i64`, `u8`…`u64`, `usize`, all overflow-checked;
  literals take their type from context; `@as(T, x)` converts (checked)
- Raw pointers `*T`, `null`, `a.create(v)`; holding, passing and
  comparing them is safe, but pointer operations (taking an address with
  `&x` outside an `inout` argument, `p.*`, `@ptrAdd`, `@ptrCast`, ...) need
  `allow unsafe` in the file, which does not spread to importers; `p.*` on
  null panics
- Function values `fn(T) R`: passed, returned, stored in fields, called
- `extern fn toupper(c: i32) i32` (in an unsafe file) calls C; `uses io`
  on the declaration says what the C function does
- Owned buffers `Buf(T)`: `a.alloc(n, v)`, `a.free(b)`, `a.resize(&b, n, v)`;
  indexed, sliced and iterated like arrays. The **ownership check**
  follows every path: no use after a move or free (E136), no leak (E135),
  paths and loop iterations agree (E134); `defer` and `errdefer` free on
  every way out

From v1:

- Types: `i64`, `bool`, `str`, `void`; structs with methods; enums;
  tagged unions `union(enum)`; arrays `[N]T`; slices `[]T`; error unions `!T`
- `const` / `var`, assignment to mutable variables, fields and array
  elements (slice and str elements are read-only); `if`,
  `while`, `for (xs) |x, i|`, `break`, `continue`, exhaustive `switch` with
  payload capture
- Parameters by value, `inout` (passed as `&x`, with exclusivity checked),
  or `comptime T: type`; generic functions and type functions
  (`fn Pair(comptime T: type) type { return struct { ... } }`)
- Errors as values: `error.X`, `try`, `catch`; `main` may return `!void`
- Builtins: `@len`, `@sizeOf`, `@typeName`, `@splat`, `@This`, `@import`,
  `@as`; for pointers `@ptrAdd`, `@ptrCast`, `@intFromPtr`, `@ptrFromInt`,
  `@strPtr`

Design choices worth knowing:

- **Slices are second-class**: they exist only as parameters, arguments and
  `for` subjects, so a view can never outlive its array, with no lifetime
  annotations (E116).
- **Left-to-right evaluation** on every C compiler: each call is evaluated
  into a temporary in source order.
- **No undefined behaviour**: integer overflow, division by zero and
  out-of-bounds indexing panic.
- **Zig-style strictness**, all compile errors: unused locals, a `var`
  never changed, an ignored result or error, shadowing, missing returns,
  non-exhaustive switches, no implicit conversions.
- **Lazy generics**: a method of a generic type is checked only when
  called, as in Zig.

## Layout

```
bin/eggc               command-line driver
docs/design.md         design doc (English; Chinese in design.zh.md)
editors/vscode/        VS Code syntax highlighting (install the .vsix)
lib/egg/lexer.rb       source -> tokens (newlines are significant)
lib/egg/parser.rb      tokens -> AST (recursive descent)
lib/egg/ast.rb         AST as Structs
lib/egg/loader.rb      the root file and its imports, merged into one program
lib/egg/typecheck.rb   types and Zig-style strictness checks
lib/egg/caps.rb        capability check along the call graph
lib/egg/own.rb         ownership check of buffers, along every path
lib/egg/codegen_c.rb   AST -> C99 (only the runtime helpers a program uses)
lib/egg/lsp.rb         language server (a tool: uses the json and uri stdlib, not Spinel)
spec/core.md           the core language spec: types, scoping, semantics
spec/grammar.ebnf      the grammar, machine-readable
spec/diagnostics.md    every error code
examples/              programs with `// expect:` / `// panic:` / `// fails:` lines
                       (examples/lib/: modules they import)
test/errors/           programs that must fail with `// error: CODE @LINE`
test/run.rb            test runner, no gems
```

## Coding rules (to stay in the Spinel subset)

- No `send`, `define_method`, `method_missing`, `eval`
- AST nodes are Structs, handled with `case ... in`; every `case` ends in an
  `else` that raises, because Ruby does not check exhaustiveness
- No gems in the compiler (the test runner may use stdlib `open3`)

## Generated C

- Egg functions become `fn_<name>`, locals `v_<name>`, runtime helpers
  `egg_*`, so nothing an Egg program names can collide with C or the runtime
- Passes `-std=c99 -Wall -Wextra -pedantic -Werror` on gcc and clang
- No POSIX calls; only `<stdio.h>`, `<stdlib.h>`, `<stdint.h>`,
  `<stdbool.h>`, `<inttypes.h>`

## Editor support

`editors/vscode` is a VS Code extension: highlighting, go to definition,
hover, outline, errors as you type (all served by `eggc lsp`) and
breakpoints. Install it with:

```bash
code --install-extension editors/vscode/egg-lang-0.0.5.vsix
```

Or in VS Code: Extensions view → `...` menu → *Install from VSIX...* →
pick `editors/vscode/egg-lang-0.0.5.vsix`. Reload the window and `.egg`
files are highlighted.

To work on the extension without repackaging, build it once, symlink the
folder and reload (rerun the build after changing `extension.js`):

```bash
(cd editors/vscode && npm install && npm run vscode:prepublish)
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/femto.egg-lang-0.0.5
```

Rebuild the `.vsix` with `cd editors/vscode && npx @vscode/vsce package --no-dependencies`.

## Debugging

`eggc build -g` puts `#line` directives in the generated C and compiles with
`-g -O0`, so gdb and lldb break, step and show the stack in `.egg` source:

```bash
bin/eggc build -g examples/loops.egg -o build/loops
lldb build/loops -o "breakpoint set --file loops.egg --line 37" -o run
```

In VS Code (with the extension above, plus CodeLLDB or the C/C++
extension): open a `.egg` file, click the gutter to set a breakpoint, pick
*Debug .egg (lldb)* or *Debug .egg (gdb)* and press F5. The repo's
`.vscode/tasks.json` builds the current file into `build/` first.

Limits: variables show under their C names (`v_n` for `n`), and stepping
into a checked operation lands in a C runtime helper (`egg_add` and so on);
use step over.
