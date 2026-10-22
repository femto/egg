# Egg for VS Code

Syntax highlighting for the Egg language (`.egg` files).

- Keywords, types, `@builtins`, numbers (`1_000`, `0x1F`), strings
- `fn name` definitions and calls, capitalized user types
- `use cap.io` capability declarations
- `//` comments, with `expect:` / `panic:` / `error:` test directives
- Bracket matching, auto-closing, `//` toggle comment, brace indentation

## Install

From the packaged file:

    code --install-extension egg-lang-0.0.1.vsix

Or, without packaging, copy this folder into your extensions directory and
restart VS Code:

    cp -r editors/vscode ~/.vscode/extensions/femto.egg-lang-0.0.1
