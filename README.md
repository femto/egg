# Egg

An AI-native systems language with a core that has no capabilities at all.
GC, exceptions, IO and allocation are capability modules a program declares
on demand. See the design doc ([English](docs/design.md) · [中文](docs/design.zh.md))
for the full picture.

This repository holds **eggc v0**: the first compiler, written in the Ruby
subset that [Spinel](https://github.com/matz/spinel) compiles. It runs on
CRuby today and emits portable C99.

```
fn fib(n: i64) i64 {
    if (n < 2) { return n }
    return fib(n - 1) + fib(n - 2)
}

fn main() void {
    @print(fib(20))
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

## What v0 supports

- Types: `i64`, `bool`, `void` (return type only)
- `fn`, `const` / `var` (with optional type), assignment
- `if` / `else if` / `else`, `while`, `return`
- Operators: `+ - * / %`, comparisons, `and` `or` `!`, unary `-`
- `@print(x)`: a temporary builtin until the `io` capability arrives in v2

Checks in the Zig spirit, all compile errors: unused locals, a `var` never
reassigned, an ignored non-void result, shadowing, missing returns, no
implicit conversions. Arithmetic is checked at run time: overflow and
division by zero panic instead of being undefined behaviour.

## Layout

```
bin/eggc               command-line driver
docs/design.md         design doc (English; Chinese in design.zh.md)
editors/vscode/        VS Code syntax highlighting (install the .vsix)
lib/egg/lexer.rb       source -> tokens (newlines are significant)
lib/egg/parser.rb      tokens -> AST (recursive descent)
lib/egg/ast.rb         AST as Structs
lib/egg/typecheck.rb   types and Zig-style strictness checks
lib/egg/codegen_c.rb   AST -> C99 (only the runtime helpers a program uses)
lib/egg/lsp.rb         language server (a tool: uses the json stdlib, not Spinel)
spec/core.md           the core language spec: types, scoping, semantics
spec/grammar.ebnf      the grammar, machine-readable
spec/diagnostics.md    every error code
examples/              programs with `// expect:` / `// panic:` lines
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
code --install-extension editors/vscode/egg-lang-0.0.3.vsix
```

Or in VS Code: Extensions view → `...` menu → *Install from VSIX...* →
pick `editors/vscode/egg-lang-0.0.3.vsix`. Reload the window and `.egg`
files are highlighted.

To work on the extension without repackaging, build it once, symlink the
folder and reload (rerun the build after changing `extension.js`):

```bash
(cd editors/vscode && npm install && npm run vscode:prepublish)
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/femto.egg-lang-0.0.3
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
