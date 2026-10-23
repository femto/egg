# Egg diagnostics (v2)

Every diagnostic has a stable code. Tools and AI agents should match on the
code, not the message text. `eggc check FILE --json` prints one JSON object
per line. `file` is the file the error is in, which may be one the
program imports:

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
| E103 | checker | type mismatch (also: comparing structs, arrays or unions; an array where a slice is expected) | make both sides the same type; no implicit conversions |
| E104 | checker | wrong number of arguments | match the function's parameter list |
| E105 | checker | assigning to, or passing as inout, a `const`, a by-value parameter, or an element of a slice or str | declare it with `var`, or make the parameter `inout`; slice and str elements are always read-only, so copy them into a `var` array |
| E106 | checker | duplicate definition (function, type, import, field, member, method) or shadowing | rename one of them |
| E107 | checker | non-void function can reach its end without returning | add a `return` on every path |
| E108 | checker | unknown type, `void` or `type` where a value type is needed, `[_]T` outside a literal | use a value type |
| E109 | checker | missing or invalid `main` (returns something else, or takes a parameter that is not a capability value, or one twice) | `fn main(out: Io) void`, `fn main() i64` or `fn main(out: Io, a: Allocator) !void` |
| E110 | checker | local variable is never used | remove it |
| E111 | checker | `var` is never changed (assigned, or passed as inout) | declare it with `const` |
| E112 | checker | unknown builtin (also: `@print`, removed in v2) | see core.md section 15; print with `out.print(x)` |
| E113 | checker | a non-void value or an error is ignored | use the value; handle an error with `try` or `catch` |
| E114 | — | reserved for the workflow profile | |
| E115 | checker | a type cannot be inferred (`.member` with no known type, `@splat` without an array type, `const e = error.X`) | write the type: `Color.red`, `var a: [4]i64 = ...`, `!i64` |
| E116 | checker | a slice used outside a parameter, an argument or a `for` (stored, returned, a field) | pass `a[lo..hi]` directly; slices exist only as parameters |
| E117 | checker | a variable passed as `inout` also appears in another argument of the same call | copy the other argument into a local first |
| E118 | checker | `try` outside a function returning `!T`, or `try`/`catch` on a value that is not `!T`, or a value fallback for `!void` | return `!T`, or handle the error with `catch` |
| E119 | checker | a struct contains itself by value | hold an index into an array instead |
| E120 | checker | `struct { ... }` outside a type function, or a type function whose body is not `return struct { ... }` | declare the type with `const Name = struct { ... }` |
| E121 | checker | `&` outside an inout argument, or an inout argument without `&` | write `f(&x)` exactly where the parameter is `inout` |
| E122 | checker | no such field, method or member (also: reading a union's member without `switch`) | check the name; use `switch` for unions |
| E123 | checker | a struct or union literal with a missing, unknown or repeated field | name every field once; a union literal names one member |
| E124 | checker | an array literal with the wrong number of elements, or a zero-length array | match the length in `[N]T` |
| E125 | checker | a comptime argument that is not a type, or a type stored in a variable | pass a type such as `i64` |
| E126 | checker | `break` or `continue` outside a loop | move it into a loop |
| E127 | checker | a `switch` that is not over an enum or union, misses members, repeats one, has an unreachable or misplaced `else`, or captures a payload that is not there | handle each member once, or end with `else` |
| E128 | checker | a `uses` line names an unknown capability, or one twice | the capabilities are `alloc` and `io` |
| E129 | loader, checker | an import that is not `const m = @import("file.egg")` at the top level, a file that cannot be found, or a module used as a value | import an existing `.egg` file, relative to the importing one; name something in it: `m.f(...)` |
| E130 | capabilities | a function uses a capability (directly, or through a call) that its file does not declare | add `uses io` / `uses alloc` to that file, or move the code to a file that declares it |

Runtime panics (the program aborts with `egg panic: <message>`):

| Message | Cause |
|---------|-------|
| integer overflow | `+ - *`, unary `-`, or `/` whose result does not fit in i64 |
| division by zero | `/` or `%` with a zero divisor |
| index out of bounds | `a[i]` with `i < 0` or `i >= @len(a)` |
| slice out of bounds | `a[lo..hi]` unless `0 <= lo <= hi <= @len(a)` |
| out of memory | an `Allocator` could not get memory from the system, or a concatenated string's length does not fit in i64 |

A `main` returning `!void` that returns an error prints `error: Name` to standard error and exits with status 1.
