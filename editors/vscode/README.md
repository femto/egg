# Egg for VS Code

Syntax highlighting and breakpoints for the Egg language (`.egg` files).

- Keywords, types, `@builtins`, numbers (`1_000`, `0x1F`), strings
- `fn name` definitions and calls, capitalized user types
- `use cap.io` capability declarations
- `//` comments, with `expect:` / `panic:` / `error:` test directives
- Bracket matching, auto-closing, `//` toggle comment, brace indentation
- Breakpoints in `.egg` files, for debugging with lldb or gdb

## Install

From the packaged file:

    code --install-extension egg-lang-0.0.2.vsix

Or, without packaging, copy this folder into your extensions directory and
restart VS Code:

    cp -r editors/vscode ~/.vscode/extensions/femto.egg-lang-0.0.2

## Debugging

`eggc build -g` emits `#line` directives and compiles with `-g -O0`, so a
native debugger stops on `.egg` lines. This extension only lets you set
breakpoints; the debugging itself goes through a C debugger extension:
CodeLLDB (`vadimcn.vscode-lldb`) or C/C++ (`ms-vscode.cpptools`, for gdb).

The egg repository ships `.vscode/launch.json` and `.vscode/tasks.json`:
open a `.egg` file, set a breakpoint, press F5. Variables show under their
C names (`v_n` for `n`).
