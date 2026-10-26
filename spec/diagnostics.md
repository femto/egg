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
| E003 | parser, checker | integer literal does not fit its type (or is above u64's maximum), or a float literal is infinite in its type (`1e400`, `1e39` as `f32`) or rounds to zero though it is not zero (`1e-400`) | use a smaller literal or a wider type; for one that rounds to zero, write `0.0` or use `f64` instead of `f32` |
| E101 | checker | undefined variable | declare it with `const` or `var` |
| E102 | checker | undefined function, or calling a variable | define the function |
| E103 | checker | type mismatch (also: comparing structs, arrays or unions; an array where a slice is expected; two integer types in one operation; negating an unsigned value; a generic or inout function used as a value) | make both sides the same type with `@as`; no implicit conversions |
| E104 | checker | wrong number of arguments | match the function's parameter list |
| E105 | checker | assigning to, or passing as inout, a `const`, a by-value parameter, or an element of a slice or str | declare it with `var`, or make the parameter `inout`; slice and str elements are always read-only, so copy them into a `var` array |
| E106 | checker | duplicate definition (function, type, import, field, member, method) or shadowing; a type named like a built-in one (`Buf`, `i64`, ...) | rename one of them |
| E107 | checker | non-void function can reach its end without returning | add a `return` on every path |
| E108 | checker | unknown type, `void` or `type` where a value type is needed, `[_]T` outside a literal | use a value type |
| E109 | checker | missing or invalid `main` (returns something else, or takes a parameter that is not a capability value, or one twice) | `fn main(out: Io) void`, `fn main() i64` or `fn main(out: Io, a: Allocator) !void` |
| E110 | checker | local variable is never used | remove it |
| E111 | checker | `var` is never changed (assigned, or passed as inout) | declare it with `const` |
| E112 | checker | unknown builtin (also: `@print`, removed in v2) | see core.md section 15; print with `out.print(x)` |
| E113 | checker | a non-void value or an error is ignored (also: a `defer` whose expression is not void) | use the value; handle an error with `try` or `catch` |
| E114 | — | reserved for the workflow profile | |
| E115 | checker | a type cannot be inferred (`.member` with no known type, `@splat` without an array type, `const e = error.X`, `null` without a pointer type) | write the type: `Color.red`, `var a: [4]i64 = ...`, `!i64` |
| E116 | checker | a slice used outside a parameter, an argument or a `for` (stored, returned, a field) | pass `a[lo..hi]` directly; slices exist only as parameters |
| E117 | checker | a variable passed as `inout`, or a buffer moved into a call, also appears in another argument of the same call | copy the other argument into a local first (`const n = @len(b)`) |
| E118 | checker | `try` outside a function returning `!T`, or `try`/`catch` on a value that is not `!T`, or a value fallback for `!void`; `try` inside `defer`; `errdefer` in a function that does not return `!T` | return `!T`, or handle the error with `catch`; use `defer` |
| E119 | checker | a struct contains itself by value | hold an index into an array instead |
| E120 | checker | `struct { ... }` outside a type function, or a type function whose body is not `return struct { ... }` | declare the type with `const Name = struct { ... }` |
| E121 | checker | `&` outside an inout argument (in a file without `allow unsafe`, where it would take an address), or an inout argument without `&` | write `f(&x)` exactly where the parameter is `inout` |
| E122 | checker | no such field, method or member (also: reading a union's member without `switch`) | check the name; use `switch` for unions |
| E123 | checker | a struct or union literal with a missing, unknown or repeated field | name every field once; a union literal names one member |
| E124 | checker | an array literal with the wrong number of elements, or a zero-length array | match the length in `[N]T` |
| E125 | checker | a comptime argument that is not a type, or a type stored in a variable | pass a type such as `i64` |
| E126 | checker | `break` or `continue` outside a loop | move it into a loop |
| E127 | checker | a `switch` that is not over an enum or union, misses members, repeats one, has an unreachable or misplaced `else`, or captures a payload that is not there | handle each member once, or end with `else` |
| E128 | checker | a `uses` line names an unknown capability, or one twice | the capabilities are `alloc` and `io` |
| E129 | loader, checker | an import that is not `const m = @import("file.egg")` at the top level, a file that cannot be found, or a module used as a value | import an existing `.egg` file, relative to the importing one; name something in it: `m.f(...)` |
| E130 | capabilities | a function uses a capability (directly, or through a call) that its file does not declare | add `uses io` / `uses alloc` to that file, or move the code to a file that declares it |
| E131 | checker | a pointer operation (`p.*`, `@ptrAdd`, `@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@strPtr`), an `extern fn`, a `link` or `a.str_from_c` in a file without `allow unsafe`; or `allow` with anything but `unsafe`. (`&x` outside an inout argument in such a file stays E121.) | add `allow unsafe` at the top of the file, or keep the unsafe operation in a module that has it |
| E132 | checker | an invalid `extern fn`: a name that is a C keyword, `main`, declared by the C headers the generated code includes (functions, macros, types), reserved in C (`_X`, `__x`), or starts with a generated prefix; a parameter that is not an integer, float, bool, pointer or function type, or a result that is none of those and not `void`; an `inout` parameter; or two declarations of one C function with different types | rename it, pass pointers instead of str, structs or slices |
| E133 | checker | a `Buf(T)` somewhere other than a local, a parameter or a result: a struct or union field, an array, slice or `Buf` element, a pointer's target; a `!Buf(T)` local or parameter; or borrowing from a temporary buffer (`@len(make(a))`) | keep buffers in local variables and pass them by value or as `inout`; unwrap `!Buf(T)` with `try`/`catch`; store a temporary in a variable |
| E134 | ownership | paths that join disagree on whether a buffer was moved (after `if`, `switch`, `catch`, `and`/`or`), or a loop iteration (or a `break`/`continue`, or a loop condition) changes whether a buffer from outside the loop is owned | move or free it on every path, or on none; free and reassign it within the same iteration |
| E135 | ownership | a buffer still owned where its owner goes away (end of its block, `return`, `break`/`continue`, a `try` that returns an error), a variable that owns one assigned another, or an `inout` buffer parameter that does not own one when the function returns | `a.free(b)`, return it or pass it on; `defer a.free(b)` / `errdefer a.free(b)` right after making it |
| E136 | ownership | a buffer variable used after its buffer was moved (passed, assigned, returned or freed), also by a `defer` that runs after the move | use it before moving it, or give the variable a new buffer first |
| E137 | ownership | a buffer moved, reassigned or passed as `inout` (so maybe resized) inside a `for` loop over it | change the elements only (`b[i] = v`); collect changes and apply them after the loop, or loop over an index with `while` |
| E138 | checker | a `link` whose library name is not letters, digits and `_ . + -`, or starts with `.`, `+` or `-` | write the name the C compiler takes after `-l`: `link "m"` for `-lm` |

Runtime panics (the program aborts with `egg panic: <message>`):

| Message | Cause |
|---------|-------|
| integer overflow | `+ - *`, unary `-`, or `/` whose result does not fit its integer type |
| division by zero | `/` or `%` with a zero divisor |
| index out of bounds | `a[i]` with `i < 0` or `i >= @len(a)` |
| slice out of bounds | `a[lo..hi]` unless `0 <= lo <= hi <= @len(a)` |
| integer cast out of range | `@as(T, x)` where x does not fit T |
| float cast out of range | `@as(T, x)` from a float to an integer type T, where x truncated does not fit T, or x is nan or infinite |
| null pointer dereference | `p.*` where p is `null` |
| negative buffer length | `a.alloc(n, v)` or `a.resize(&b, n, v)` with `n < 0` |
| out of memory | an `Allocator` could not get memory from the system, a concatenated string's length does not fit in i64, or a buffer's size in bytes does not fit in `usize` |

A `main` returning `!void` that returns an error prints `error: Name` to standard error and exits with status 1.
