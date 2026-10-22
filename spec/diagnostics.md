# Egg diagnostics (v0)

Every diagnostic has a stable code. Tools and AI agents should match on the
code, not the message text. `eggc check FILE --json` prints one JSON object
per line:

```json
{"file":"a.egg","line":4,"col":11,"code":"E110","message":"local variable 'unused' is never used"}
```

| Code | Stage | Meaning | Typical fix |
|------|-------|---------|-------------|
| E001 | lexer | unexpected character | remove it |
| E002 | parser | syntax error (also: chained comparison `a < b < c`) | follow spec/grammar.ebnf |
| E003 | parser | integer literal does not fit in i64 | use a smaller literal |
| E101 | checker | undefined variable | declare it with `const` or `var` |
| E102 | checker | undefined function, or calling a variable | define the function |
| E103 | checker | type mismatch | make both sides the same type; no implicit conversions |
| E104 | checker | wrong number of arguments | match the function's parameter list |
| E105 | checker | assignment to a `const` or a parameter | declare it with `var`, or copy the parameter into a `var` |
| E106 | checker | duplicate definition or shadowing | rename one of them |
| E107 | checker | non-void function can reach its end without returning | add a `return` on every path |
| E108 | checker | unknown type, or `void` used as a value type | use i64 or bool |
| E109 | checker | missing or invalid `main` | `fn main() void` or `fn main() i64` |
| E110 | checker | local variable is never used | remove it |
| E111 | checker | `var` is never reassigned | declare it with `const` |
| E112 | checker | unknown builtin | v0 has only `@print` |
| E113 | checker | non-void value is ignored | use the value, or store it |

Runtime panics (the program aborts with `egg panic: <message>`):

| Message | Cause |
|---------|-------|
| integer overflow | `+ - *`, unary `-`, or `/` whose result does not fit in i64 |
| division by zero | `/` or `%` with a zero divisor |
