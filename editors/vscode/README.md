# Egg for VS Code

Language support for Egg (`.egg` files).

- Keywords, types, `@builtins`, numbers (`1_000`, `0x1F`), strings
- `fn name` definitions and calls, capitalized user types
- `use cap.io` capability declarations
- `//` comments, with `expect:` / `panic:` / `error:` test directives
- Bracket matching, auto-closing, `//` toggle comment, brace indentation
- Go to definition (F12 / Cmd-click) on functions, locals and parameters
- Hover shows a function's signature or a variable's type
- Outline and Cmd-Shift-O list the file's functions
- Errors as you type, with the same codes as `eggc check`
- Breakpoints in `.egg` files, for debugging with lldb or gdb

## Install

From the packaged file:

    code --install-extension egg-lang-0.0.3.vsix

Build it from source with `npm install && npx @vscode/vsce package
--no-dependencies` in this folder.

## Language server

Everything except highlighting and breakpoints comes from `eggc lsp`, which
uses the real lexer, parser and checker. The extension starts it from, in
order: the `egg.serverPath` setting, `bin/eggc` in an open egg checkout,
`eggc` on PATH. eggc runs on Ruby, so `ruby` must be on PATH.

v0 programs are one file, so lookups stay within the current file. While
a file has a syntax error, navigation uses its last version that parsed.

## Debugging

`eggc build -g` emits `#line` directives and compiles with `-g -O0`, so a
native debugger stops on `.egg` lines. This extension only lets you set
breakpoints; the debugging itself goes through a C debugger extension:
CodeLLDB (`vadimcn.vscode-lldb`) or C/C++ (`ms-vscode.cpptools`, for gdb).

The egg repository ships `.vscode/launch.json` and `.vscode/tasks.json`:
open a `.egg` file, set a breakpoint, press F5. Variables show under their
C names (`v_n` for `n`).
