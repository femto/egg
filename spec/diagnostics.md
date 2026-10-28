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
| E003 | parser, checker | integer literal does not fit its type (or is above u64's maximum), or a float literal is infinite in its type (`1e400`, `1e39` as `f32`) or rounds to zero though it is not zero (`1e-400`) | use a smaller literal or a wider type; for one that rounds to zero, a larger literal, `0.0`, or `f64` instead of `f32` |
| E101 | checker | undefined variable | declare it with `const` or `var` |
| E102 | checker | undefined function, or calling a variable | define the function |
| E103 | checker | type mismatch (also: comparing structs, arrays or unions; an array where a slice is expected; two integer types in one operation; negating an unsigned value; a generic or inout function used as a value) | make both sides the same type with `@as`; no implicit conversions |
| E104 | checker | wrong number of arguments | match the function's parameter list |
| E105 | checker | assigning to, or passing as inout, a `const`, a by-value parameter, or an element of a slice or str | declare it with `var`, or make the parameter `inout`; slice and str elements are always read-only, so copy them into a `var` array |
| E106 | checker | duplicate definition (function, type, import, field, member, method) or shadowing; a type named like a built-in one (`Buf`, `i64`, ...) | rename one of them |
| E107 | checker | non-void function can reach its end without returning | add a `return` on every path |
| E108 | checker | unknown type, `void` or `type` where a value type is needed, `[_]T` outside a literal; `?T` of a pointer (already nullable), `!U` or `?U` | use a value type; write `*T` for a nullable pointer |
| E109 | checker | missing or invalid `main` (returns something else, or takes a parameter that is not a capability value, or one twice) | `fn main(out: Io) void`, `fn main() i64` or `fn main(out: Io, a: Allocator) !void` |
| E110 | checker | local variable is never used | remove it |
| E111 | checker | `var` is never changed (assigned, or passed as inout) | declare it with `const` |
| E112 | checker | unknown builtin (also: `@print`, removed in v2) | see core.md section 15; print with `out.print(x)` |
| E113 | checker | a non-void value or an error is ignored (also: a `defer` whose expression is not void) | use the value; handle an error with `try` or `catch` |
| E114 | — | reserved for the workflow profile | |
| E115 | checker | a type cannot be inferred (`.member` with no known type, `@splat` without an array type, `const e = error.X`, `null` without a pointer type) | write the type: `Color.red`, `var a: [4]i64 = ...`, `!i64` |
| E116 | checker | a slice used outside a parameter, an argument or a `for` (stored, returned, a field) | pass `a[lo..hi]` directly; slices exist only as parameters |
| E117 | checker | a place passed as `inout`, or an owned value moved into a call (a `sink` parameter), also appears in another argument of the same call (places are compared by field: `&v.data` and `v.len` do not clash); an argument that takes a slice of a method's `inout self` or moves an owned value out of it; the value of `@replace` mentions the place's variable (any part of it: `@replace(&v.data, v.len)` too) | copy the values you need into locals first (`const n = @len(b)`); a slice cannot be stored, so copy its elements or pass the indices instead |
| E118 | checker | `try` outside a function returning `!T`, or `try`/`catch` on a value that is not `!T`, `orelse` on one that is not `?T`, or a value fallback for `!void`; a block after `orelse`, or after a `catch` on a `!T` other than `!void`, that does not leave on every path (it has no value to give); `try`, or a `catch`/`orelse` that leaves (`return`/`break`/`continue`, or a block that may), inside `defer`; `errdefer` in a function that does not return `!T` | return `!T`, or handle the error with `catch`; end the block with `return`, `break` or `continue`, or give a value by calling a function (`catch |e| f(e)`); use `defer` |
| E119 | checker | a struct contains itself by value | hold an index into an array instead |
| E120 | checker | `struct { ... }` outside a type function, or a type function whose body is not `return struct { ... }` | declare the type with `const Name = struct { ... }` |
| E121 | checker | `&` outside an inout argument (in a file without `allow unsafe`, where it would take an address), or an inout argument without `&` | write `f(&x)` exactly where the parameter is `inout` |
| E122 | checker | no such field, method or member (also: reading a union's member without `switch`) | check the name; use `switch` for unions |
| E123 | checker | a struct or union literal with a missing, unknown or repeated field | name every field once; a union literal names one member |
| E124 | checker | an array literal with the wrong number of elements, or a zero-length array | match the length in `[N]T` |
| E125 | checker | a comptime argument that is not a type, or a type stored in a variable | pass a type such as `i64` |
| E126 | checker | `break` or `continue` outside a loop | move it into a loop |
| E127 | checker | a `switch` that is not over an enum, a union or an `anyerror`, misses members, repeats one, has an unreachable or misplaced `else`, or captures a payload that is not there; a switch on an error without an `else`, or with `.name` arms (an error arm is `error.Name`) | handle each member once, or end with `else` |
| E128 | checker | a `uses` line names an unknown capability, or one twice | the capabilities are `alloc` and `io` |
| E129 | loader, checker | an import that is not `const m = @import("file.egg")` or `@import("std/name")` at the top level, a file that cannot be found, a file import that leaves its module's root (the root file's directory, or the library's for std), an unknown module name, or a module used as a value | import an existing `.egg` file under the module's root, relative to the importing one, or a module by name (`"std/math"`); name something in it: `m.f(...)` |
| E130 | capabilities | a function uses a capability (directly, or through a call) that its file does not declare | add `uses io` / `uses alloc` to that file, or move the code to a file that declares it |
| E131 | checker | a pointer operation (`p.*`, `@ptrAdd`, `@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@strPtr`), an `extern fn`, a `link` or `a.str_from_c` in a file without `allow unsafe`; or `allow` with anything but `unsafe`. (`&x` outside an inout argument in such a file stays E121.) | add `allow unsafe` at the top of the file, or keep the unsafe operation in a module that has it |
| E132 | checker | an invalid `extern fn`: a name that is a C keyword, `main`, declared by the C headers the generated code includes (functions, macros, types), reserved in C (`_X`, `__x`), or starts with a generated prefix; a parameter that is not an integer, float, bool, pointer or function type, or a result that is none of those and not `void`; an `inout` parameter; or two declarations of one C function with different types | rename it, pass pointers instead of str, structs or slices |
| E133 | checker | an owned value (a `Buf(T)`, an `owned struct`, or a struct or array holding one) as a union member or a pointer's target; a `!T` or `?T` of one as a field, element, local or parameter; borrowing from a temporary one (`@len(make(a))`, `make_list(a).len`, or passing it to a plain parameter, `count(make(a))`); or `@drop` of a temporary | use a struct instead of a union; unwrap `!T` with `try`/`catch` and `?T` with `orelse`; store a temporary in a variable |
| E134 | ownership | paths that join disagree on whether a buffer (or a buffer field, `v.data`) was moved (after `if`, `switch`, `catch`, `and`/`or`), or a loop iteration (or a `break`/`continue`, or a loop condition) changes whether one from outside the loop is owned | move or free it on every path, or on none; free and reassign it within the same iteration |
| E135 | ownership | a buffer, a buffer field of a struct, or an `owned struct` not yet ended, still owned where its owner goes away (end of its block, `return`, `break`/`continue`, a `try` that returns an error), a variable or field that owns one assigned another, or an `inout` parameter that does not own all its buffers (and, for an owned struct, the struct itself) when the function returns | `a.free(v)` / `a.free(v.data)`, return it or pass it on; `defer a.free(v)` / `errdefer a.free(v)` right after making it; for an owned struct, its ending method (`defer db.close()`) |
| E136 | ownership | a variable used after its buffer or owned struct was moved (passed, assigned, returned, freed or dropped), also by a `defer` that runs after the move; a struct used whole while one of its buffer fields is moved; a field read or assigned after the whole struct was moved | use it before moving it, or give it a new buffer first (`v.data = ...`, or `v = ...` after moving all of `v`) |
| E137 | ownership | a buffer moved, reassigned or passed as `inout` (so maybe resized) inside a `for` loop over it (or over a field of it, or over a struct holding it); an element swapped (`@replace`, `@take`, `&xs[i]`) inside a `for` loop over `xs` when its elements own buffers | if the elements own no buffers, change only them (`b[i] = v`); otherwise collect changes and apply them after the loop, or loop over an index with `while` |
| E138 | checker | a `link` whose library name is not letters, digits and `_ . + -`, or starts with `.`, `+` or `-` | write the name the C compiler takes after `-l`: `link "m"` for `-lm` |
| E139 | ownership | moving an owned value out of an element of an array or buffer (`xs[i]`, `xs[i].data`), assigning over one, or moving a `for` loop variable that borrows an owned element | `a.free(@replace(&xs[i], v))` to put a new value in, `@take(&xs[i])` to take a buffer out (leaving `.empty`) |
| E140 | checker | the fill value of `a.alloc`, `a.resize` or `@splat` owns buffers or is (or holds) an owned struct, so it would be copied into every element | fill with `Buf(T).empty` (or a literal made of `.empty` buffers) and put values in with `@replace`; for owned structs use a `Buf`: start from `.empty` and `a.push` each one (an array literal cannot hold owned values, so there is no way yet to fill an array of them) |
| E141 | checker | an `owned struct` without a `deinit`, or a value holding one, freed with `a.free` or used as an element of an array or a `Buf` | give it a `deinit`; or end it with its own API (such as `close`) and keep it in a local or a struct field |
| E142 | checker | building an `owned struct` (`Db{ ... }`) or ending one with `@drop` outside the file that declares it | get one from, and end it with, the functions of its file |
| E143 | checker | an owned struct's `deinit` that is not `fn deinit(sink self: T) void` or `fn deinit(sink self: T, a: Allocator) void` | `a.free` can pass it only the value and an Allocator; end it some other way in a method of another name |
| E144 | ownership | moving, freeing, returning, assigning or `@drop`ping a plain parameter of an owned type, or any part of it: it is only borrowed | declare it `sink x: T` to take it over, or copy out the plain values you need |
| E145 | checker | a `sink` parameter whose type owns nothing (not a buffer, an `owned struct` or a value holding one; in a generic instance it is allowed) | remove `sink`: a plain parameter reads it |

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

