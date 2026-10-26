# Egg core language specification (v2)

This is the complete definition of the v2 core: the v1 language plus
integer types of every width (section 7), modules (section 16), the `io`
and `alloc` capabilities (section 17), raw pointers behind `allow unsafe`
(section 18), function values (section 19), `extern fn` (section 20), and
owned buffers with `defer` (section 21).
It is written to be loaded into a model's context in one piece, together
with `grammar.ebnf` (syntax) and `diagnostics.md` (error codes).
`eggc spec` prints all three.

Every ```egg block in this file is compiled and run by `test/run.rb`, so the
examples cannot drift from the compiler. A block's `// expect:` lines are its
required output; `// error: CODE` means it must fail with that code;
`// fails: Name` means `main` must return `error.Name`.

## 1. Programs

A program is a root file plus the files it imports (section 16). A file
holds, in any order, functions, type declarations (`const Name = struct /
enum / union(enum) { ... }`), imports (`const m = @import("m.egg")`) and
`uses` lines naming the capabilities it needs (section 17). Every function
can call every other function of its file, including itself.

The root file must have a function `main` returning `void`, `i64` or
`!void`, whose parameters are only capability values, each type at most
once: `fn main()`, `fn main(out: Io)`, `fn main(out: Io, a: Allocator)`
(E109). The runtime creates them; they are the only source of
capabilities. When `main` returns `i64`, the value becomes the process exit
status (the operating system keeps only the low bits, usually 8). When it
returns an error, the program prints `error: Name` to standard error and
exits with status 1.

Most examples below print, so they start with `uses io` and take
`out: Io`.

```egg
// expect: 3
uses io

fn main(out: Io) void {
    out.print(add(1, 2))   // add is declared below; order does not matter
}

fn add(a: i64, b: i64) i64 {
    return a + b
}
```

## 2. Lexical structure

- Source is UTF-8. Identifiers are ASCII: `[A-Za-z_][A-Za-z0-9_]*`.
- Keywords: `fn return if else while for break continue switch var const
  true false and or struct enum union try catch error inout comptime uses
  allow extern null defer errdefer`.
- Integer literals are decimal digits, optionally separated by `_`
  (`1_000_000`), at most 18446744073709551615. A literal's type comes from
  context (section 7); it must fit that type (E003). `-5` is unary minus
  applied to `5`, but checked as one literal, so `-128` fits `i8`.
- String literals are `"..."` on one line, with escapes `\n \t \\ \" \0`.
- `//` starts a comment that runs to the end of the line.
- **Newlines end statements.** A newline may also appear after a binary
  operator, after `(` `[` `{` or `,`, before `)` `]` `}`, and before `else`.
  Anywhere else inside an expression, a newline is a syntax error (E002).
- A capitalised type name followed by `{` is a type literal: a struct
  literal (`Point{ .x = 1 }`) or a union literal (`Shape{ .circle = 2 }`).
  This is why type names start with a capital letter: `if (ok) {` stays a
  block.

```egg
// expect: 6
// expect: 3
uses io

fn Pair(comptime T: type) type {
    return struct {
        a: T
        b: T
    }
}

fn sum(p: Pair(
    i64
)) i64 {
    return p.a + p.b
}

fn main(out: Io) void {
    const total = 1 +
                  2 +
                  3
    out.print(total)
    out.print(sum(
        Pair(i64){ .a = 1, .b = 2 }
    ))
}
```

## 3. Types

| Type | Values | Notes |
| --- | --- | --- |
| `i8` `i16` `i32` `i64` | signed integers of 8 to 64 bits | section 7 |
| `u8` `u16` `u32` `u64` | unsigned integers of 8 to 64 bits | section 7 |
| `usize` | unsigned, the size of a pointer | section 7 |
| `bool` | `true`, `false` | |
| `str` | immutable byte strings | section 8 |
| `void` | none | only as a function result (E108 elsewhere) |
| struct `Name` | records of named fields | section 9 |
| enum `Name` | one of a fixed set of names | section 10 |
| `union(enum)` `Name` | one member, maybe with a payload | section 10 |
| `[N]T` | N values of type T, N >= 1 | value type; section 11 |
| `[]T` | a read-only view of consecutive T | parameters only; section 11 |
| `!T` | a T or an error | section 13 |
| `*T` | the address of a T, or `null` | using one needs `allow unsafe`; section 18 |
| `fn(T, U) R` | a function | section 19 |
| `type` | a type, at compile time only | `comptime` parameters; section 14 |
| `Io` | the io capability | received by `main`, passed down; section 17 |
| `Allocator` | the alloc capability | received by `main`, passed down; section 17 |
| `Buf(T)` | an owned heap buffer of T | moved, not copied; section 21 |

Every type that has runtime values, except slices and buffers, is a **value type**:
assignment, passing and returning copy the value (`void` and `type` have
no runtime values). There are **no implicit conversions**. Every
operator and every assignment, argument and return requires exactly the
expected type (E103), with two exceptions: a `T` fits where `!T` is
expected, and `error.X` fits any `!T`. Integers are not booleans: `if (1)`
is an error.

```egg
// error: E103
uses io

fn main(out: Io) void {
    if (1) { out.print(1) }
}
```

## 4. Declarations and names

```
const name = expr          // immutable; type inferred
const name: T = expr       // immutable; type checked against T
var name = expr            // mutable
var name: T = expr
```

Rules, all checked at compile time:

1. **Every name is declared before use** within its block (E101). Functions
   and types are the exception: they are visible everywhere in their file,
   and in other files through an import (section 16).
2. **A local lives until the end of the block that declares it.**
3. **No shadowing.** A local or parameter may not reuse the name of any
   visible local, parameter, function, type or import (E106).
4. **`const` and parameters cannot be assigned** (E105), nor can their
   fields or elements. Copy a parameter into a `var` to change it, or make
   it `inout` (section 12).
5. **Every local must be read at least once** (E110). Assigning to it, or to
   one of its fields, does not count as reading it.
6. **Every `var` must be changed at least once after its declaration**
   (E111): assigned, have a field or element assigned, or be passed as
   `inout`. If it never changes, it must be `const`.

Rules 5 and 6 follow Zig: an unused or never-changed variable is a sign the
code does not say what it means, so it is rejected rather than tolerated.

```egg
// error: E111
uses io

fn main(out: Io) void {
    var x = 1          // never changed: must be const
    out.print(x)
}
```

```egg
// error: E106
uses io

fn main(out: Io) void {
    const x = 1
    if (x > 0) {
        const x = 2    // shadows the outer x
        out.print(x)
    }
}
```

## 5. Functions

```
fn name(p1: T1, inout p2: T2, comptime T: type) R { ... }
```

- A parameter is passed **by value** (a copy the function cannot assign),
  **`inout`** (section 12) or **`comptime`** (section 14).
- A call must pass exactly as many arguments as there are parameters (E104),
  each of the declared type (E103).
- **A non-void function must return on every path** (E107). A block returns
  on every path when at least one of its statements does, where:
  - `return` always returns;
  - `if` returns only when it has an `else` and every branch returns;
  - `switch` returns when every arm returns;
  - loops never count, even `while (true)`.
- A function returning `void` or `!void` may run off its end. `return` with
  no value is allowed only there, and a `void` function cannot return a
  value (E103).
- Functions declared inside a struct or union are its methods (section 9).

```egg
// error: E107
uses io

fn sign(n: i64) i64 {
    if (n < 0) { return -1 }
}

fn main(out: Io) void {
    out.print(sign(1))
}
```

## 6. Statements

| Statement | Meaning |
| --- | --- |
| `const` / `var` declaration | section 4 |
| `x = e`, `p.f = e`, `a[i] = e` | assign to a variable, a field or an element of a mutable variable |
| `if (c) { } else if (c) { } else { }` | `c` must be `bool`; braces are required |
| `while (c) { }` | repeats while `c` is true |
| `for (xs) \|x\| { }`, `for (xs) \|x, i\| { }` | each element of an array, a slice, a `Buf` or a str (bytes as i64), with its index `i` |
| `break`, `continue` | leave or restart the innermost loop (E126 outside one) |
| `switch (x) { ... }` | section 10 |
| `return` / `return e` | section 5 |
| `defer e`, `errdefer e` | run `e` when the block is left; section 21 |
| expression | must have type `void` (E113); a result or an error may not be discarded |

Loop variables are constants; name one `_` to ignore it. Rule E113 is why
`two()` alone on a line is an error when `two` returns `i64`, and why a
`!void` call must be handled with `try` or `catch`.

```egg
// expect: 1
// expect: 3
uses io

fn main(out: Io) void {
    const xs = [4]i64{ 1, 2, 3, 4 }
    for (xs) |x, i| {
        if (x % 2 == 0) {
            continue
        }
        if (i > 2) {
            break
        }
        out.print(x)
    }
}
```

## 7. Expressions

Precedence, lowest first; binary operators are left-associative except
comparisons, which cannot be chained (`a < b < c` is E002):

| Level | Operators | Operand types | Result |
| --- | --- | --- | --- |
| 1 | `e catch f` | `!T`, fallback `T` | `T` (section 13) |
| 2 | `or` | bool | bool |
| 3 | `and` | bool | bool |
| 4 | `==` `!=` | both the same integer type, bool, str, enum, pointer or function type | bool |
| 4 | `<` `<=` `>` `>=` | both the same integer type | bool |
| 5 | `+` `-` | both the same integer type | that type |
| 6 | `*` `/` `%` | both the same integer type | that type |
| 7 | unary `-`, `!`, `try`, `&` | signed integer / bool / `!T` / place | |
| 8 | `a.f`, `a.m(...)`, `a.*`, `a[i]`, `a[lo..hi]`, calls | | |

- `and` / `or` short-circuit: the right side is evaluated only if needed.
- Structs, unions and arrays cannot be compared with `==` (E103).
- **Evaluation is left to right.** Operands and arguments are evaluated in
  the order they are written, so `f() + g()` always calls `f` first.

### Integer types

`i8`, `i16`, `i32`, `i64` are signed and `u8`, `u16`, `u32`, `u64` unsigned,
of that many bits; `usize` is unsigned and as wide as a pointer. Indexes,
lengths (`@len`) and `for` indexes are `i64`, and so are the bytes of a
`str`.

Both operands of an arithmetic or ordering operator must have the same
type (E103): nothing converts implicitly. A literal takes its type from
the other operand or from what the context expects, and is `i64` when
nothing says otherwise:

```egg
// expect: 255
// expect: 248
uses io

fn main(out: Io) void {
    const x: u8 = 200        // the literal is a u8
    out.print(x + 55)        // so is 55
    const n = 1000           // i64
    out.print(@as(u8, n / 4 - 1) - 1)
}
```

`@as(T, x)` converts the integer `x` to the integer type `T`, and panics
`integer cast out of range` if the value does not fit. Negating an
unsigned value is E103.

### Integer arithmetic is checked

Egg has no undefined behaviour. Every integer operation, in every integer
type, either produces the mathematically correct result or stops the
program with a panic:

| Operation | Result |
| --- | --- |
| `a + b`, `a - b`, `a * b`, `-a` | exact result, or panic `integer overflow` (for unsigned types, also when `a - b` is negative) |
| `a / b` | quotient truncated toward zero; panic `division by zero` if `b == 0`; panic `integer overflow` for the minimum value of a signed type divided by `-1` |
| `a % b` | remainder with the sign of `a` (so `a == (a / b) * b + a % b`); panic `division by zero` if `b == 0`; the minimum value `% -1` is `0` |

Indexing and slicing are checked too: panic `index out of bounds` or
`slice out of bounds`. A panic prints `egg panic: <message>` to standard
error and aborts the process with a non-zero status.

```egg
// expect: -3
// expect: -1
// expect: 3
// expect: 1
uses io

fn main(out: Io) void {
    out.print(-7 / 2)
    out.print(-7 % 2)
    out.print(7 / 2)
    out.print(7 % -2)
}
```

```egg
// panic: integer overflow
uses io

fn main(out: Io) void {
    const big = 9223372036854775807
    out.print(big + 1)
}
```

```egg
// expect: 1
// expect: 2
// expect: 3
uses io

fn one(out: Io) i64 {
    out.print(1)
    return 1
}

fn two(out: Io) i64 {
    out.print(2)
    return 2
}

fn main(out: Io) void {
    out.print(one(out) + two(out))
}
```

## 8. Strings

`str` is an immutable sequence of bytes: a literal, a slice of a `str`, or
a string built with an `Allocator` (section 17). None of them is ever
freed, so a `str` is always valid.

- `@len(s)` is its length in bytes; `s[i]` is the byte at `i` as an `i64`
  (0 to 255); `s[lo..hi]` and `s[lo..]` are `str`s.
- `==` compares contents. `for (s) |b|` visits each byte.
- Building a string allocates, so it needs the alloc capability:
  `a.concat(s, t)` and `a.int_str(n)` (section 17).

```egg
// expect: 5
// expect: 104
// expect: ell
// expect: true
uses io

fn main(out: Io) void {
    const s = "hello"
    out.print(@len(s))
    out.print(s[0])
    out.print(s[1..4])
    out.print(s[1..] == "ello")
}
```

## 9. Structs and methods

```
const Point = struct {
    x: i64
    y: i64

    fn len2(self: Point) i64 { return self.x * self.x + self.y * self.y }
    fn move(inout self: Point, dx: i64) void { self.x = self.x + dx }
    fn origin() Point { return Point{ .x = 0, .y = 0 } }
}
```

- A literal names every field exactly once (E123): `Point{ .x = 1, .y = 2 }`.
- `p.x` reads a field (E122 if there is none); `p.x = 3` assigns it when
  `p` is mutable.
- A function inside a struct is a method if its first parameter has the
  struct's type: `p.len2()` passes `p` by value; `p.move(1)` passes it as
  `inout`, so `p` must be a `var` or an `inout` parameter. Any function inside the struct can be
  called as `Point.origin()` or `Point.len2(p)`.
- A struct cannot contain itself by value (E119).
- Field types may be anything except `void`, `type` and slices (E116).

```egg
// expect: 25
// expect: 4
uses io

fn main(out: Io) void {
    var p = Point.origin()
    p.move(3, 4)
    out.print(p.len2())
    out.print(p.y)
}

const Point = struct {
    x: i64
    y: i64

    fn origin() Point {
        return Point{ .x = 0, .y = 0 }
    }

    fn len2(self: Point) i64 {
        return self.x * self.x + self.y * self.y
    }

    fn move(inout self: Point, dx: i64, dy: i64) void {
        self.x = self.x + dx
        self.y = self.y + dy
    }
}
```

## 10. Enums, unions and switch

```
const Light = enum { red, yellow, green }
const Shape = union(enum) { circle: i64, rect: Size, empty }
```

- An enum value is written `Light.red`, or `.red` where the type is known
  from context (a typed declaration, an argument, a return, a comparison).
  Otherwise `.red` is E115. Enums compare with `==` and print as their name.
- A union value holds exactly one member. A member with a payload is
  written `Shape{ .circle = 2 }`; one without, `.empty` or `Shape.empty`.
  A union's payload is read only with `switch` (E122 on `u.circle`).
- Unions may have methods, like structs.

`switch` is a statement over an enum or a union (E127 otherwise):

```
switch (shape) {
    .circle => |r| { ... }          // |r| binds the payload
    .rect, .empty => { ... }        // several members, no capture
    else => { ... }                 // anything not listed; must be last
}
```

It must handle every member exactly once, or end with `else`; an `else`
that can never run is also an error (E127). `break` and `continue` in an
arm act on the enclosing loop.

```egg
// expect: 24
// expect: green
uses io

fn main(out: Io) void {
    const shapes = [3]Shape{ Shape{ .circle = 2 }, Shape{ .rect = Size{ .w = 3, .h = 4 } }, .empty }
    var total = 0
    for (shapes) |s| {
        total = total + s.area()
    }
    out.print(total)
    out.print(next(.red))
}

const Size = struct { w: i64, h: i64 }

const Shape = union(enum) {
    circle: i64
    rect: Size
    empty

    fn area(self: Shape) i64 {
        switch (self) {
            .circle => |r| {
                return 3 * r * r
            }
            .rect => |sz| {
                return sz.w * sz.h
            }
            .empty => {
                return 0
            }
        }
    }
}

const Light = enum { red, yellow, green }

fn next(l: Light) Light {
    switch (l) {
        .red => {
            return .green
        }
        else => {
            return .red
        }
    }
}
```

```egg
// error: E127
uses io

const Light = enum { red, green }

fn main(out: Io) void {
    switch (Light.red) {
        .red => {
            out.print(1)
        }
    }
}
```

## 11. Arrays and slices

`[N]T` is a value: N elements stored inline, copied on assignment. Write a
literal as `[3]i64{ 1, 2, 3 }` or `[_]i64{ 1, 2, 3 }` (length from the
elements), or fill one with `@splat(v)` where the type is known. `a[i]` is
bounds-checked; `@len(a)` is N.

`[]T` is a **slice**: a read-only view of consecutive elements of an array,
written `a[lo..hi]` or `a[lo..]`. Slices are **second-class** (E116): a
slice can be a parameter type, an argument, or the subject of `for`, and
nothing else. It cannot be stored in a variable or a field, or returned. So
a view can never outlive the array it looks into, without any lifetime
annotations. An array is not implicitly a slice: pass `a[0..]` (E103).

```egg
// expect: 10
// expect: 5
// expect: 3
uses io

fn sum(xs: []i64) i64 {
    var total = 0
    for (xs) |x| {
        total = total + x
    }
    return total
}

fn main(out: Io) void {
    const a = [4]i64{ 1, 2, 3, 4 }
    out.print(sum(a[0..]))
    out.print(sum(a[1..3]))
    const zeros: [3]i64 = @splat(1)
    out.print(sum(zeros[0..]))
}
```

```egg
// error: E116
uses io

fn main(out: Io) void {
    const a = [3]i64{ 1, 2, 3 }
    const view = a[0..2]
    out.print(@len(view))
}
```

## 12. inout parameters

An `inout` parameter lets a function change its caller's variable. The
argument is written `&x`, so a reader of the call can see it: `x` (or a
field or element of it) must be a `var` or an `inout` parameter, and `&`
is allowed nowhere else (E121). Inside the function, the parameter reads
and assigns like a local.

**Exclusivity** (E117): a variable passed as `inout` may not appear in any
other argument of the same call, so a function never sees two views of the
same memory.

```egg
// expect: 21
uses io

fn swap(inout a: i64, inout b: i64) void {
    const t = a
    a = b
    b = t
}

fn main(out: Io) void {
    var x = 1
    var y = 2
    swap(&x, &y)
    out.print(x * 10 + y)
}
```

```egg
// error: E117
uses io

fn add_into(inout acc: i64, x: i64) void {
    acc = acc + x
}

fn main(out: Io) void {
    var total = 1
    add_into(&total, total)
    out.print(total)
}
```

## 13. Errors

Errors are values. `!T` holds either a `T` or an error; `error.Name` is an
error (names are global, and need no declaration).

- A function returning `!T` returns either a `T` or an `error.Name`.
- `try e` unwraps `e: !T`: on an error, the current function returns that
  error at once. It is allowed only in a function that returns `!U` (E118).
- `e catch f` unwraps `e: !T`, using `f: T` when `e` is an error. For a
  `!void`, the fallback is an action of type `void`: `check() catch log()`.
- A `!T` result cannot be ignored (E113): `try` it or `catch` it.

```egg
// expect: 42
// expect: -1
// fails: Empty
uses io

fn parse_digit(c: i64) !i64 {
    if (c < 48 or c > 57) {
        return error.NotADigit
    }
    return c - 48
}

fn parse(s: str) !i64 {
    if (@len(s) == 0) {
        return error.Empty
    }
    var n = 0
    for (s) |c| {
        n = n * 10 + try parse_digit(c)
    }
    return n
}

fn main(out: Io) !void {
    out.print(try parse("42"))
    out.print(parse("4x") catch -1)
    out.print(try parse(""))
}
```

## 14. Generics: comptime

A `comptime T: type` parameter takes a type, known at compile time. A
function with one is instantiated for each set of type arguments, and each
instance is type-checked on its own, as in Zig:

```
fn max(comptime T: type, a: T, b: T) T { ... }    // max(i64, 3, 9)
```

A **type function** returns `type` and its body is exactly
`return struct { ... }`. `Pair(i64)` then names a struct type; inside the
struct, `@This()` is that type.

A comptime argument must be a type (E125), and `type` values exist only at
compile time: no variable or field can hold one.

```egg
// expect: 2
// expect: 9
// expect: Pair(bool)
uses io

fn Pair(comptime T: type) type {
    return struct {
        a: T
        b: T

        fn swap(self: @This()) @This() {
            return @This(){ .a = self.b, .b = self.a }
        }
    }
}

fn max(comptime T: type, a: T, b: T) T {
    if (a > b) {
        return a
    }
    return b
}

fn main(out: Io) void {
    const p = Pair(i64){ .a = 1, .b = 2 }
    out.print(p.swap().a)
    out.print(max(i64, 3, 9))
    out.print(@typeName(Pair(bool)))
}
```

## 15. Builtins

Builtins start with `@`; any other name is E112.

| Builtin | Meaning |
| --- | --- |
| `@len(x)` | length of an array, a slice, a `Buf` or a `str`, as `i64` |
| `@sizeOf(T)` | size of a value of type T in bytes, as `i64` |
| `@typeName(T)` | the type's name, as a `str` |
| `@splat(v)` | an array with every element `v`; the array type comes from context (E115) |
| `@This()` | inside a struct or union: its own type |
| `@import("m.egg")` | another file as a module; only as `const m = @import(...)` at the top level (section 16, E129) |
| `@as(T, x)` | the integer x as integer type T; panics `integer cast out of range` if it does not fit (section 7) |

Builtins for pointers, which need `allow unsafe` (section 18):

| Builtin | Meaning |
| --- | --- |
| `@ptrAdd(p, n)` | p moved by n elements (`n: i64`, may be negative) |
| `@ptrCast(*U, p)` | the same address as a `*U` |
| `@intFromPtr(p)` | the address as a `usize` |
| `@ptrFromInt(*T, n)` | the address `n: usize` as a `*T` |
| `@strPtr(s)` | a `*u8` to the bytes of the `str` s (not 0-terminated; do not write through it) |

v1's `@print` is gone: printing is io, so it is `out.print(x)` with the io
capability (section 17). `@print` is E112.

## 16. Modules

```
const shapes = @import("lib/shapes.egg")
```

imports another file, as a path relative to the importing file ending in
`.egg` (a missing file is E129). The name, here `shapes`, is local to the
importing file and reaches the top-level names of the imported one:

| Written | Means |
| --- | --- |
| `shapes.perimeter(r)` | a function |
| `shapes.Rect`, `shapes.Box(i64)` | a type, a type function's type |
| `shapes.Rect{ .w = 1, .h = 2 }` | a struct literal |
| `shapes.Kind.rect`, `shapes.Rect.square(3)` | an enum member, a function of a type |
| `shapes.biggest(i64, xs[0..])` | a generic function |

A name not declared by the module is E102 (function), E108 (type) or E122;
an import name used as a value is E129. Imported names are not visible
unqualified, and every top-level name is visible to importers (there is
no `pub` yet).

Each file is loaded once, however many files import it, so all importers
see the same types. Imports may form cycles. Diagnostics name the file
an error is in, and call imported things by the file's base name
(`shapes.perimeter`), whatever the import is called.

```
// lib/shapes.egg: declares no capabilities
const Rect = struct {
    w: i64
    h: i64

    fn area(self: Rect) i64 {
        return self.w * self.h
    }
}

// main.egg
uses io

const shapes = @import("lib/shapes.egg")

fn main(out: Io) void {
    out.print(shapes.Rect{ .w = 2, .h = 3 }.area())   // 6
}
```

`examples/modules.egg` and its `examples/lib/` files are the tested
version of this section.

## 17. Capabilities

A capability is something the core does not have: io and heap allocation
in v2. A file declares the capabilities it needs on a `uses` line:

```
uses alloc, io
```

Naming an unknown capability, or one twice, is E128. Each capability comes
with a value type that is the only way to use it:

| Capability | Value | Methods |
| --- | --- | --- |
| `io` | `Io` | `out.print(x)`: prints an integer, `bool`, `str` or enum and a newline to standard output |
| `alloc` | `Allocator` | `a.concat(s, t) str`: s followed by t; `a.int_str(n) str`: the integer n in decimal; `a.create(v) *T`: a pointer to a copy of v; `a.alloc(n, v) Buf(T)`, `a.free(b)`, `a.resize(&b, n, v)`: buffers, section 21 |

Capability values cannot be created or compared. `main` receives them
from the runtime, and other code gets them as arguments; they may be
stored in locals and struct fields like any value.

**The check (E130).** A function *uses* a capability when it calls a
method of its value, or calls a function that uses it. The compiler
follows the call graph, across files and through generic instances, and
rejects a function whose file does not declare every capability it uses.
So a file without `uses io` cannot print, even with an `Io` it was given,
and even inside a generic function instantiated with `Io`: it can only
pass the value on. The error is reported where the capability enters the
file: at the method call, or at the call into another file.

```egg
// error: E130
fn main(out: Io) void {
    out.print(1)       // no `uses io`
}
```

Strings and `a.create` pointers live as long as the program: they are
never freed, so nothing can use them after being freed. Memory that is
freed comes as a `Buf(T)`, whose owner the compiler checks (section 21).

```egg
// expect: total: 42
// expect: -7
uses alloc, io

const Log = struct {
    out: Io
    a: Allocator

    fn show(self: Log, label: str, n: i64) void {
        self.out.print(self.a.concat(label, self.a.int_str(n)))
    }
}

fn main(out: Io, a: Allocator) void {
    const log = Log{ .out = out, .a = a }
    log.show("total: ", 42)
    out.print(a.int_str(-7))
}
```

`eggc` lists the capabilities a function uses when the language server
shows it (hover).

## 18. Pointers and allow unsafe

`*T` is the address of a `T`, or `null`. Pointer types can be written,
stored, passed, returned and compared with `==` anywhere, and `a.create(v)`
makes one; `null` takes its pointer type from context (E115 otherwise).
*Using* a pointer needs the line

```
allow unsafe
```

in the file (anything else after `allow` is E131). Then:

| Written | Means |
| --- | --- |
| `&place` | the address of a `var`, or of its field or element (a `const` is E105) |
| `p.*` | the `T` that p points to; also a place: `p.* = v`, `p.*.x = v` |
| `@ptrAdd`, `@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@strPtr` | section 15 |
| `extern fn` | section 20 |

Without `allow unsafe` these are E131 (and `&x` outside an inout argument
stays E121). The compiler cannot check what pointers point to: a pointer
can outlive the variable it points into, and `@ptrAdd` can leave the
object. The one check is that `p.*` on `null` panics with
`null pointer dereference`.

`allow unsafe` is local to its file: a file that imports an unsafe module
does not need it, so an unsafe module can offer a safe API. Unlike a
capability, it does not travel along the call graph. The language server
marks functions of an unsafe file in hover.

```egg
// expect: 6
// expect: 42
uses io, alloc
allow unsafe

const Node = struct {
    value: i64
    next: *Node
}

fn sum(list: *Node) i64 {
    var total = 0
    var p = list
    while (p != null) {
        total = total + p.*.value
        p = p.*.next
    }
    return total
}

fn bump(p: *i64) void {
    p.* = p.* + 1
}

fn main(out: Io, a: Allocator) void {
    var list: *Node = null
    list = a.create(Node{ .value = 1, .next = list })
    list = a.create(Node{ .value = 5, .next = list })
    out.print(sum(list))
    var x = 41
    bump(&x)
    out.print(x)
}
```

```egg
// error: E131
uses io, alloc

fn main(out: Io, a: Allocator) void {
    const p = a.create(5)    // fine: making a pointer is safe
    out.print(p.*)           // reading through it is not
}
```

## 19. Function values

A function's name, used without calling it, is a value of type
`fn(T, U) R` (its parameter and result types). It can be stored, passed,
returned, compared with `==`, and called: `f(x)` for a local or parameter
`f`, `s.f(x)` for a field. A generic function, or one with an `inout`
parameter, is not a value (E103). There are no closures.

```egg
// expect: 8
// expect: 15
uses io

const Op = struct {
    run: fn(i64, i64) i64
}

fn add(a: i64, b: i64) i64 {
    return a + b
}

fn mul(a: i64, b: i64) i64 {
    return a * b
}

fn twice(f: fn(i64, i64) i64, x: i64) i64 {
    return f(x, x)
}

fn main(out: Io) void {
    out.print(twice(add, 4))
    const op = Op{ .run = mul }
    out.print(op.run(3, 5))
}
```

For the capability check, taking a function as a value counts as calling
it: the function that takes it uses what it uses. Whoever receives the
value may call it, as whoever receives an `Io` may print: a module without
`uses io` can call a printing function it was handed, but cannot make one.

## 20. extern fn

In an `allow unsafe` file,

```
extern fn toupper(c: i32) i32
extern fn write(fd: i32, buf: *u8, n: usize) i64 uses io
```

declares a C function, called by its own name. It has no body. Its
parameters and result are integers, `bool`, pointers or function types
(the result may be `void`), so the C types are exact; anything else, an
`inout` parameter, a C keyword, `main` (the generated entry point), a
name the C headers the generated code includes already declare
(functions such as `puts` and `malloc`, macros such as `NULL` and
`INT8_MAX`, types such as `size_t` and `int8_t`), a name C reserves
(`_X`, `__x`), or a name starting with a prefix the generated code uses
(`egg_`, `fn_`, ...) is E132. So is declaring the same C function twice
with different types. Declaring it twice with the same types is fine;
each declaration's `uses` is checked against its own file.

C can do anything, so the declaration says which capabilities the
function uses after `uses`, and calling it uses them (E130 if its file
does not declare them). Whoever writes the declaration is responsible for
it being true.

```egg
// expect: 65
uses io
allow unsafe

extern fn toupper(c: i32) i32

fn main(out: Io) void {
    out.print(toupper(97))
}
```

## 21. Buffers, ownership and defer

`Buf(T)` is a buffer of T on the heap, with a length fixed until it is
resized. `a.alloc(n, v)` makes one holding n copies of v (T is v's type,
or the element type the context expects); `a.free(b)` frees it;
`a.resize(&b, n, v)` changes its length to n, filling new elements with v.
A negative length panics with `negative buffer length`.

A buffer is used like an array: `b[i]` (bounds-checked; `b[i] = v` needs
a `var` or an `inout` parameter), `@len(b)`, `for (b)`, and `b[lo..hi]`,
a slice of it. These **borrow** it. Everything else **moves** it:
assigning it, passing it by value, returning it, and `a.free(b)`.

**Each buffer has one owner.** A move hands it on, and the variable it
came from owns nothing until it is assigned a new buffer. The compiler
follows every path through each function and checks:

- a variable is not used after its buffer was moved (E136), so nothing is
  used after being freed and nothing is freed twice;
- every buffer is moved before its owner goes away: at the end of its
  block, at a return, break or continue, and where a `try` returns an
  error; and a variable that still owns one is not assigned another
  (E135). So nothing leaks. An `inout` buffer parameter belongs to the
  caller, so it must own a buffer whenever the function returns;
- paths that join agree on what was moved (after an `if`, a `switch`, a
  `catch`, the right side of `and`/`or`), and an iteration of a loop
  leaves each buffer from outside it as it found it (E134);
- while `for (b)` iterates over a buffer, the body may change its
  elements but not move, reassign or resize it, nor pass it as `inout`
  (E137).

A buffer lives only in a local, a parameter or a result: not in a field,
an array, another buffer or behind a pointer, and a `!Buf(T)` must be
unwrapped with `try` or `catch` right away (E133). Borrowing from a
temporary, as in `@len(make(a))`, is E133 too: nothing could free it. A
buffer moved into a call may not appear in another argument of it (E117),
so a slice of it cannot outlive it. Buffers cannot be compared or printed.

**defer.** `defer e` runs the void expression `e` when its block is left,
however that happens: at its end, at `return` (after the value is
computed), `break`, `continue`, or a `try` that returns an error. Several
run last first. `errdefer e`, only in a function returning `!T`, runs only
when the function returns an error. Neither may contain `try` (E118). The
ownership check counts what they do at every way out, so
`defer a.free(b)` right after making b frees it exactly once.

```egg
// expect: 10
// expect: 20
// expect: 5
uses alloc, io

fn sum(xs: []i64) i64 {
    var total = 0
    for (xs) |x| {
        total = total + x
    }
    return total
}

// Takes the buffer, frees it, and returns a new one.
fn doubled(a: Allocator, b: Buf(i64)) Buf(i64) {
    var out = a.alloc(@len(b), 0)
    for (b) |x, i| {
        out[i] = 2 * x
    }
    a.free(b)
    return out
}

fn range(a: Allocator, n: i64) !Buf(i64) {
    var b = a.alloc(n, 0)
    errdefer a.free(b)       // only if an error leaves the function
    var i = 0
    while (i < n) {
        if (i > 99) {
            return error.TooLong
        }
        b[i] = i + 1
        i = i + 1
    }
    return b
}

fn main(out: Io, a: Allocator) !void {
    var b = try range(a, 4)
    defer a.free(b)          // whatever b owns when main returns
    out.print(sum(b[0..]))
    b = doubled(a, b)        // moved in, and a new buffer back
    out.print(sum(b[0..]))
    a.resize(&b, 5, 0)
    out.print(@len(b))
}
```

```egg
// error: E136
uses alloc, io

fn main(out: Io, a: Allocator) void {
    const b = a.alloc(3, 0)
    a.free(b)
    out.print(b[0])          // b was moved by a.free
}
```

```egg
// error: E135
uses alloc, io

fn main(out: Io, a: Allocator) void {
    const b = a.alloc(3, 0)
    out.print(@len(b))       // b is never freed
}
```

```egg
// error: E134
uses alloc, io

fn main(out: Io, a: Allocator) void {
    const b = a.alloc(3, 0)
    if (@len(b) > 2) {
        a.free(b)            // freed on one path only
    }
    out.print(1)
}
```

## 22. Not yet

Closures, optional types
(`?*T`) and many-item pointers, floating point, reflection beyond
`@sizeOf`/`@typeName`, private (non-`pub`) names, and capabilities other
than `io` and `alloc`. See the design document's roadmap for when each
arrives.

## 23. A complete program

```egg
// expect: 21
// expect: 6765
// expect: true
uses io

fn gcd(a: i64, b: i64) i64 {
    var x = a
    var y = b
    while (y != 0) {
        const t = x % y
        x = y
        y = t
    }
    return x
}

fn fib(n: i64) i64 {
    var a = 0
    var b = 1
    var k = 0
    while (k < n) {
        const next = a + b
        a = b
        b = next
        k = k + 1
    }
    return a
}

fn main(out: Io) void {
    out.print(gcd(1071, 462))
    out.print(fib(20))
    out.print(gcd(10, 4) == 2 and fib(10) == 55)
}
```
