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
  true false and or struct enum union try catch orelse error inout sink comptime uses
  allow extern link owned null defer errdefer`.
- Integer literals are decimal digits, optionally separated by `_`
  (`1_000_000`), at most 18446744073709551615. A literal's type comes from
  context (section 7); it must fit that type (E003). `-5` is unary minus
  applied to `5`, but checked as one literal, so `-128` fits `i8`.
- String literals are `"..."` on one line, with escapes `\n \r \t \\ \" \0`.
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
| `f32` `f64` | IEEE 754 floating point, 32 and 64 bits | section 7 |
| `bool` | `true`, `false` | |
| `str` | immutable byte strings | section 8 |
| `void` | none | only as a function result (E108 elsewhere) |
| struct `Name` | records of named fields | section 9 |
| enum `Name` | one of a fixed set of names | section 10 |
| `union(enum)` `Name` | one member, maybe with a payload | section 10 |
| `[N]T` | N values of type T, N >= 1 | value type; section 11 |
| `[]T` | a read-only view of consecutive T | parameters only; section 11 |
| `!T` | a T or an error | section 13 |
| `anyerror` | an error: `error.Name` | compared with `==`, switched on, named with `@errorName`; section 13 |
| `?T` | a T or `null` | section 13 |
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
expected type (E103), with these exceptions: a `T` fits where `!T` or
`?T` is expected, `error.X` fits any `!T`, and `null` any `?T`. Integers are not booleans: `if (1)`
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
fn name(p1: T1, inout p2: T2, sink p3: T3, comptime T: type) R { ... }
```

- A parameter is passed **by value** (the function reads it and cannot
  assign it), **`inout`** (section 12), **`sink`** or **`comptime`**
  (section 14). For an owned value (section 21) a plain parameter only
  borrows it, and `sink` takes it over; a `sink` parameter of a type that
  owns nothing is E145, except in a generic instance, where T may or may
  not own something.
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
| expression | must have type `void` (E113); a result or an error may not be dropped silently |
| `_ = e` | evaluates `e` and drops its value: not `void`, not an error union (`_ = try f()`), and nothing owned, which would never be freed (E113) |

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
| 1 | `e catch f`, `e orelse f` | `!T` / `?T`, fallback `T` | `T` (section 13) |
| 2 | `or` | bool | bool |
| 3 | `and` | bool | bool |
| 4 | `==` `!=` | both the same number type, bool, str, enum, pointer or function type; or both text (str, `[]u8`, `Buf(u8)`; section 8) | bool |
| 4 | `<` `<=` `>` `>=` | both the same number type | bool |
| 5 | `+` `-` | both the same number type | that type |
| 6 | `*` `/` | both the same number type | that type |
| 6 | `%` | both the same integer type | that type |
| 7 | unary `-`, `!`, `try`, `&` | signed integer or float / bool / `!T` / place | |
| 8 | `a.f`, `a.m(...)`, `a.*`, `a[i]`, `a[lo..hi]`, calls | | |

- `and` / `or` short-circuit: the right side is evaluated only if needed.
- Structs, unions and arrays cannot be compared with `==` (E103).
- **Evaluation is left to right.** Operands and arguments are evaluated in
  the order they are written, so `f() + g()` always calls `f` first.

### if with a value

`if (c) a else b` is an expression: `a` when the bool `c` is true, else
`b`, and only the chosen branch is evaluated. Both branches are
expressions, without braces, and the `else` is required (E002 otherwise,
and for a block in place of a branch); `else if` chains. An `if` that
starts a statement is the if statement (section 6). The else branch
reaches as far as an expression goes, as in Zig: `if (c) 1 else 2 + 3`
is `if (c) 1 else (2 + 3)`.

The branches have one type: the type the context expects, or else the
first branch's; a literal (`5`, `.red`) takes the other branch's type, so
`if (c) 1 else x` is x's type (E103 when they differ). `null` still needs
a `?T` or pointer from the context: `const m: ?i64 = if (c) x else null`. The
result must be a value: not `void`, a type or a slice (E103).

An owned value moves out of the branch that makes or names it, and the
branches must agree on what they move (E134), as the branches of an if
statement do: `if (c) b else d` moves only one of two buffers, so it is
E134; use an if statement that also frees the other one. An if
with a value cannot be borrowed from (`n(if (c) b else d)` with a plain
parameter, `for (if (c) b else d)`: E133), since it would hide which
variable is held.

```egg
// expect: -1
// expect: green
// expect: 99
uses io

const Color = enum { red, green }

fn name(c: Color) str {
    return if (c == .red) "red" else "green"
}

fn main(out: Io) void {
    const x: i64 = -3
    out.print(if (x < 0) -1 else 1)
    out.print(name(if (x > 0) .red else .green))
    const m: ?i64 = if (x > 0) x else null
    out.print(m orelse 99)
}
```

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

### Floating-point types

`f32` and `f64` are IEEE 754 single and double precision. A literal with
a fraction or an exponent (`1.5`, `2e10`, `6.02e-23`) is a float: `f64`,
or `f32` where the context wants one. An integer literal also becomes a
float where one is expected, so `x * 2` with `x: f64` needs no `2.0`; a
fraction never becomes an integer. A literal that does not fit its type
(`1e400`, or `1e39` as an `f32`), or that is not zero but rounds to zero
(`1e-400`), is E003.

Float arithmetic follows IEEE 754 and never panics: `1.0 / 0.0` is `inf`,
`0.0 / 0.0` is `nan`, and results round to the nearest value. That is
defined behaviour, not overflow. There is no `%` on floats (declare C's
`fmod`, section 20). `@as` converts between any two number types:
to a float it rounds to the nearest value; from a float to an integer it
truncates toward zero and panics `float cast out of range` if the result
does not fit, or the value is `nan` or infinite.

`out.print` and `a.float_str(x)` write the shortest decimal that reads
back as the same value; a finite value always has a `.` or an exponent:
`0.1`, `3.0`, `1e+16`, `1.5e-07`. The others are `nan`, `inf` and `-inf`.

```egg
// expect: 0.30000000000000004
// expect: 3.5
// expect: 1e+16
// expect: 0.1
// expect: inf
// expect: -7
uses io

fn half(x: f64) f64 {
    return x / 2
}

fn main(out: Io) void {
    out.print(0.1 + 0.2)
    out.print(half(7))
    out.print(1e16)
    const f: f32 = 0.1
    out.print(f)
    const zero = 0.0
    out.print(1 / zero)
    out.print(@as(i64, -7.9))
}
```

```egg
// panic: float cast out of range
uses io

fn main(out: Io) void {
    const big = 1e10
    out.print(@as(i32, big))
}
```

```egg
// error: E103
uses io

fn main(out: Io) void {
    const n = 3
    out.print(1.5 * n)       // i64 and f64: convert n with @as(f64, n)
}
```

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

```egg
// expect: 13
// expect: 3
uses io

fn main(out: Io) void {
    const crlf = "\r\n"
    out.print(crlf[0])        // \r is byte 13
    out.print(@len("a\r\n"))
}
```

### Text that is freed: Buf(u8)

A `str` is never freed, so a program that builds strings as it runs
should build them in a **`Buf(u8)`** instead: an ordinary buffer (section
21), which owns its bytes and is freed with `a.free`. Three Allocator
methods add text at its end, growing it as `a.push` does:

| Written | Adds |
| --- | --- |
| `a.append_str(&b, s)` | the bytes of the text s |
| `a.append_int(&b, n)` | the integer n in decimal |
| `a.append_float(&b, x)` | the float x as `out.print` writes it |

**Text** here is a `str`, a `[]u8`, a `Buf(u8)`, or a slice of one of
them; each is only read. Text in any of these forms:

- is lent to a `[]u8` parameter (`fn count(s: []u8) i64` takes
  `count("abc")`, `count(b)` and `count(b[1..])`). A slice cannot be
  stored, so the bytes cannot outlive a Buf(u8) that is freed or grown;
- prints with `out.print`, as its bytes;
- compares with `==` and `!=` by its bytes, whatever kind each side is
  (`b == "id=7"`, `b[0..2] == s`); a slice may be compared directly;
- is copied into a `str` by `a.concat(s, t)`, which lives as long as the
  program: `a.concat(b, "")` keeps the text of b after b is freed.

The `Buf(u8)` itself follows the buffer rules: `a.append_str(&b, b)` is
E117, growing it while `for (b)` reads it is E137, and a temporary one
cannot be lent (E133). Appending needs a `Buf(u8)` and text (E103).

```egg
// expect: id=7, x=1.5
// expect: true
// expect: 2
uses io, alloc

fn count(s: []u8, c: u8) i64 {
    var n: i64 = 0
    for (s) |x| {
        if (x == c) {
            n = n + 1
        }
    }
    return n
}

fn main(out: Io, a: Allocator) void {
    var b: Buf(u8) = .empty
    defer a.free(b)
    a.append_str(&b, "id=")
    a.append_int(&b, 7)
    a.append_str(&b, ", x=")
    a.append_float(&b, 1.5)
    out.print(b)
    out.print(b[0..4] == "id=7")
    out.print(count(b, 61))
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
  `inout`, so `p` must be a `var` or an `inout` parameter; a `sink self`
  method takes `p` over (section 21). Any function inside the struct can be
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

**Exclusivity** (E117): a place passed as `inout` may not appear in any
other argument of the same call, so a function never sees two views of the
same memory. Places are compared by their fields: `&v.data` and `v.len`
are separate, `&v` and `v.len` are not. A method's `inout self` is looser,
since the other arguments are computed before the call: they may read
plain values of it (`l.push(a, l.len)`), but not take a slice of it or
move an owned value out of it.

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
- `e catch |err| f` also names the error, an `anyerror`, for the fallback
  only; `|_|` discards it, and an `err` the fallback never uses is E110. The fallback of a catch may instead leave (`catch return`,
  `catch |err| return err`, `catch break`, `catch continue`), or be a
  block. A block for a `!void` runs and then the code after it; for a `!T`
  there is no value it could give, so it must leave with `return`,
  `break` or `continue` on every path (E118); to give a value per error,
  call a function: `catch |err| fallback_for(err)`. None of these may be
  inside a `defer` (E118).
- A `!T` result cannot be ignored (E113): `try` it or `catch` it.
- `anyerror` is the type of an error. It is an ordinary value type: it
  can be stored, passed and returned (`var last: anyerror =
  error.None`), and it fits where a `!T` is expected, so `return err`
  returns it. Errors compare with `==` and `!=`; `@errorName(err)` is
  the name, such as `"NotFound"`. `switch (err)` has arms
  `error.Name => { ... }`, and since error names are open it must have
  an `else` (E127); an error arm has no payload.

```egg
// expect: 0: Zero
// expect: -3: negative
// expect: 4 = 4
uses alloc, io

fn check(x: i64) !i64 {
    if (x == 0) {
        return error.Zero
    }
    if (x < 0) {
        return error.Neg
    }
    return x
}

fn explain(e: anyerror) str {
    switch (e) {
        error.Neg => { return "negative" }
        else => { return @errorName(e) }
    }
}

fn main(out: Io, a: Allocator) void {
    const xs = [_]i64{ 0, -3, 4 }
    for (xs) |x| {
        const v = check(x) catch |e| {
            out.print(a.concat(a.concat(a.int_str(x), ": "), explain(e)))
            continue
        }
        out.print(a.concat(a.concat(a.int_str(x), " = "), a.int_str(v)))
    }
}
```

`?T` holds either a `T` or `null`, as in Zig. T may be any value type but
a pointer (which can already be null), `!U` or `?U` (E108).

- A `T` or `null` fits where a `?T` is expected: `var best: ?i64 = null`,
  then `best = 7`.
- `e orelse f` unwraps `e: ?T`, giving `f: T` when `e` is null (E118 if
  `e` is not an optional). The fallback may instead leave: `orelse return`
  (or `return v`), `orelse break`, `orelse continue`, or be a block that
  leaves on every path (`orelse { log(); return }`, E118); not inside a
  `defer` (E118).
- A `?T` cannot be printed or compared, and a `?T` result cannot be
  ignored (E113). An owned one (`?Buf(u8)`, `?Db`) must be unwrapped
  right away, like an owned `!T` (E133).

```egg
// expect: 4
// expect: -1
// expect: 9
uses io

fn first(xs: []i64) ?i64 {
    if (@len(xs) == 0) {
        return null
    }
    return xs[0]
}

fn main(out: Io) void {
    out.print(first([2]i64{ 4, 5 }[0..]) orelse -1)
    var best: ?i64 = null
    out.print(best orelse -1)
    best = 9
    out.print(best orelse -1)
}
```

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

**Choosing by type.** An `if` whose condition compares types (`K == str`,
`K != i64`, joined by `and`, `or` and `!`) is decided at compile time:
only the branch it chooses is checked and generated, so one generic
function can do different things per type, and an `else if` chain picks
the first branch whose types match. Types compare nowhere else (E103).
`@compileError("message")` reports E146 with that message where it is
checked, so it marks a branch no type should choose; such a branch needs
no `return`.

```egg
// expect: 3
// expect: 7
uses io

fn size(comptime T: type, x: T) i64 {
    if (T == str) {
        return @len(x)
    } else if (T == i64) {
        return x
    } else {
        @compileError("size takes a str or an i64")
    }
}

fn main(out: Io) void {
    out.print(size(str, "abc"))
    out.print(size(i64, 7))
}
```

```egg
// error: E146
uses io

fn size(comptime T: type, x: T) i64 {
    if (T == str) {
        return @len(x)
    } else {
        @compileError("size takes a str")
    }
}

fn main(out: Io) void {
    out.print(size(bool, true))
}
```

## 15. Builtins

Builtins start with `@`; any other name is E112.

| Builtin | Meaning |
| --- | --- |
| `@len(x)` | length of an array, a slice, a `Buf` or a `str`, as `i64` |
| `@sizeOf(T)` | size of a value of type T in bytes, as `i64` |
| `@typeName(T)` | the type's name, as a `str` |
| `@errorName(e)` | the name of the error `e: anyerror`, without `error.`, as a `str` (section 13) |
| `@compileError("msg")` | E146 with that message wherever it is checked: everywhere except in a comptime `if` branch that is not chosen (section 14); msg must be a string literal |
| `@splat(v)` | an array with every element `v`; the array type comes from context (E115) |
| `@replace(&p, v)` | puts v in the place p and returns what was there (section 21) |
| `@take(&p)` | `@replace(&p, Buf(T).empty)` for a buffer place p (section 21) |
| `@drop(v)` | ends the owned struct v without running anything; only in the file that declares its type (section 21) |
| `@This()` | inside a struct or union: its own type |
| `@import("m.egg")` | another file as a module; only as `const m = @import(...)` at the top level (section 16, E129) |
| `@as(T, x)` | the number x as number type T; to an integer type it panics `integer cast out of range` (from an integer) or `float cast out of range` (from a float) if it does not fit (section 7) |

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
`.egg` (a missing file is E129). A string without `.egg` names a
**module** instead: `@import("std/math")` is `math.egg` of the standard
library (`"std/a/b"` is `a/b.egg` in it, and `"std"` alone is `std.egg`),
which ships with the compiler in `lib/std` (the `EGG_STD`
environment variable points elsewhere); `std` is the only module name so far. A file
import may not leave its module's root, the directory of the root file
for a program and the library's directory for `std` (E129): a module is
a self-contained tree, and reaches others only by name. The name, here
`shapes`, is local to the importing file and reaches the top-level names
of the imported one:

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
| `io` | `Io` | `out.print(x)`: prints an integer, a float, `bool`, `str` or enum and a newline to standard output |
| `alloc` | `Allocator` | `a.concat(s, t) str`: s followed by t (any text, section 8); `a.append_str(&b, s)`, `a.append_int(&b, n)`, `a.append_float(&b, x)`: text at the end of a `Buf(u8)`, section 8; `a.int_str(n) str`: the integer n in decimal; `a.float_str(x) str`: the float x as `out.print` writes it; `a.cstr(s) *u8`, `a.str_from_c(p) str`: C strings, section 20; `a.create(v) *T`: a pointer to a copy of v; `a.alloc(n, v) Buf(T)`, `a.free(b)`, `a.resize(&b, n, v)`, `a.push(&b, v)`, `a.pop(&b) ?T`: buffers, section 21 |

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
parameters and result are integers, floats, `bool`, pointers or function types
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

C strings end in a 0 byte; a `str` has a length instead and no 0. Two
`Allocator` methods convert, copying into the program-lifetime arena:
`a.cstr(s) *u8` is s followed by a 0 (C sees s up to its first 0 byte),
and `a.str_from_c(p) str` is the bytes at p up to the first 0. Making a
pointer is safe, but `a.str_from_c` reads through one, so it needs
`allow unsafe` (E131); on `null` it panics `null pointer dereference`.
Where a C function takes a pointer and a length, `@strPtr(s)` and
`@len(s)` pass a `str` without copying.

```egg
// expect: HELLO
uses io, alloc
allow unsafe

extern fn toupper(c: i32) i32

fn main(out: Io, a: Allocator) void {
    const p = a.cstr("hello")
    var i = 0
    while (@ptrAdd(p, i).* != 0) {
        const c = @ptrAdd(p, i)
        c.* = @as(u8, toupper(@as(i32, c.*)))
        i = i + 1
    }
    out.print(a.str_from_c(p))
}
```

A C function outside the C library is linked with `link`, also only in
an `allow unsafe` file:

```
allow unsafe
link "sqlite3"

extern fn sqlite3_libversion_number() i32
```

`eggc build` and `eggc run` pass `-lsqlite3` to the C compiler for every
`link` in every file the program loads, so a program that imports a
module wrapping a library links it without saying so. The name is what
follows `-l`: letters, digits and `_ . + -`, not starting with `.`, `+`
or `-` (E138). eggc's own `-l LIB` links one more library, and `-L DIR`
tells the C compiler where to look.

## 21. Buffers, ownership and defer

`Buf(T)` is a buffer of T on the heap, with a length fixed until it is
resized. `a.alloc(n, v)` makes one holding n copies of v (T is v's type,
or the element type the context expects); `a.free(b)` frees it (E103
for a value that owns nothing, except in a generic instance, where
freeing a storable value that owns nothing does nothing, so one generic container
serves owned and plain values alike);
`a.resize(&b, n, v)` changes its length to n, filling new elements with v.
A negative length panics with `negative buffer length`. `a.push(&b, v)`
moves v in at the end (a buffer has a capacity: a push onto a full one
raises it to 4 if it is below 2, and doubles it otherwise, so a push costs
amortized O(1)), and `a.pop(&b)` moves the last element out as a
`?T` (`null` when b is empty); a pushed value is not copied, so it may be
an owned one. A `Buf(?U)` pops a `??U`, unwrapped with two orelses, the
outer one for an empty buffer: `(a.pop(&b) orelse 0) orelse -1`. These
three work only on a `Buf` (E103).

A buffer is used like an array: `b[i]` (bounds-checked; `b[i] = v` needs
a `var` or an `inout` parameter), `@len(b)`, `for (b)`, and `b[lo..hi]`,
a slice of it. These **borrow** it, and so does passing it to a plain
parameter. Everything else **moves** it: assigning it, passing it to a
`sink` parameter, returning it, `a.free(b)` and `a.push(&bs, b)`.

**Borrowed and sink parameters.** A plain parameter of an owned type
borrows the caller's value for the call: the function may read it, index
it, slice it, loop over it, copy plain fields out of it and pass it on to
another plain parameter, but not move any of it (free it, return it,
assign it, pass it to `sink`, `@drop` it; E144), and it does not have to
give it away. Like a slice, a borrow cannot outlive the call. A `sink`
parameter takes the value over: the caller's variable is moved, and the
function must give it away on every path (E135). The call is written the
same either way, `f(b)`. One value may be borrowed by several arguments
of a call; it may not be both borrowed and passed as `inout` (E117), and
a value moved into a `sink` parameter may not appear in another argument.
A borrowed temporary would never be freed, so `count(a.alloc(2, 0))` is
E133 unless `count` takes it by `sink`; `.empty` may be borrowed. The
parameters of a function type (`fn(Buf(i64)) i64`) are plain, so a
function value borrows its owned arguments.

```egg
// expect: 3
// expect: 3
uses alloc, io

fn count(b: Buf(i64)) i64 {
    return @len(b)
}

fn eat(a: Allocator, sink b: Buf(i64)) void {
    a.free(b)
}

fn main(out: Io, a: Allocator) void {
    const b = a.alloc(3, 0)
    out.print(count(b))       // borrowed: b is still owned here
    out.print(count(b))
    eat(a, b)                 // moved
}
```

```egg
// error: E144
uses alloc

fn eat(a: Allocator, b: Buf(i64)) void {
    a.free(b)                 // b is only borrowed: declare it sink b
}

fn main(a: Allocator) void {
    const b = a.alloc(3, 0)
    eat(a, b)
    a.free(b)
}
```

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

An owned value moved into a call may not appear in another argument of it
(E117), so a slice of it cannot outlive it. Owned values cannot be compared
or printed, except a `Buf(u8)`, which is text (section 8).

**Owned structs and containers.** A struct with a `Buf` field, an array of
buffers and a buffer of buffers are owned too: they move like a buffer,
and `a.free(v)` frees everything they hold, the elements of an array or
buffer in order and a struct's fields last declared first (they may
depend on earlier ones). A `!T` or `?T` of one
must be unwrapped right away (`try`, `catch`, `orelse`); one cannot be a union
member or a pointer's target (E133). Borrowing from a temporary, as in
`@len(make(a))` or `make_list(a).len`, is E133 too: nothing could free it.

The fields of a struct variable are followed one by one. Moving `v.data`
(freeing it, passing it on) leaves `v` **partly moved**: its other fields
can still be used, but `v` as a whole cannot (E136) until `v.data = ...`
gives it a buffer again. When `v` goes away, every buffer field must have
been moved (E135). An `inout` struct parameter must own all its buffers
again when the function returns, so a method `fn push(inout self: List,
...)` may resize `self.data` in place.

Elements of arrays and buffers are not followed: `xs[i]` can be borrowed
(`xs[i][j]`, `@len(xs[i])`, `xs[i].len`, `&xs[i]`), but moving it out or
assigning over it is E139. Elements are swapped instead:

- `Buf(T).empty` (or `.empty` where the type is known) is a buffer with no
  elements, which owns no memory and costs nothing to free;
- `@replace(&p, v)` puts `v` in the place `p` and returns what was there;
  `@take(&p)` is `@replace(&p, Buf(T).empty)` for a buffer place. The
  place is found first, then the value is computed. The value may not
  mention the place's variable at all, not even another field of it
  (E117): `@replace(&v.data, v.len)` is rejected, unlike the field-by-field
  rule for `inout` arguments.

`a.alloc`, `a.resize` and `@splat` copy their fill value, so for owned
elements it must be made of `.empty` buffers (E140): `a.alloc(n,
Buf(u8).empty)`, `List{ .data = .empty, .len = 0 }`. Shrinking a buffer of
buffers with `a.resize` frees the elements cut off. While `for (xs) |x|`
iterates over owned elements, `x` only borrows each one (moving it is
E139), and the body may not swap elements of `xs` (E137).

**Owned structs.** `const Db = owned struct { ... }` declares a struct
that is owned for itself, with or without buffers: a resource such as an
open file or a database handle, which must be released exactly once. It
moves like a buffer, so a copy cannot release it again (E136), and it
must be given away on every path (E135, E134). Only the file that
declares it may build one (`Db{ ... }`) or end one with `@drop(v)`, which
runs nothing (E142); everywhere else a value comes from that file's
functions and ends by being passed to one that takes it by `sink`, such
as `fn close(sink self: Db) void { ...; @drop(self) }`. Methods that only
read it take `self`, methods that change it `inout self`; only its file
may change its fields (assign them,
pass them as `inout`, `@replace` them; E142), though any file may read
them. `@drop` ends only the struct itself: buffers in its fields must
still be freed, and it needs a variable or a field of one, not a
temporary (E133).

An owned struct may have a **deinit**: `fn deinit(sink self: T) void`,
or `fn deinit(sink self: T, a: Allocator) void` (E143 for any other
shape). It is
what `a.free` calls to end one, so it must end everything the struct
holds, and a struct holding owned structs ends each by its deinit. Only
with a deinit may an owned struct, or something holding one, be freed
with `a.free` or be an element of an array or a `Buf` (E141). Neither
`a.alloc`, `a.resize` nor `@splat` can copy one into elements (E140):
fill a `Buf` with `a.push`. A deinit is never called on its own: a local
must still be ended explicitly (E135), with `x.deinit()` (`x.deinit(a)`
for the form that takes an allocator) or any other `sink self` method.

A struct holding an owned struct is owned, and is followed field by
field as above.

```egg
// expect: open 1
// expect: 101
// expect: closed 1
uses io

const File = owned struct {
    fd: i64

    fn write(inout self: File, out: Io, n: i64) void {
        out.print(100 * self.fd + n)
    }

    fn close(sink self: File, out: Io) void {
        out.print("closed 1")
        @drop(self)
    }
}

fn open(out: Io) File {
    out.print("open 1")
    return File{ .fd = 1 }
}

fn main(out: Io) void {
    var f = open(out)
    defer f.close(out)
    f.write(out, 1)
}
```

```egg
// error: E135
uses io

const File = owned struct {
    fd: i64

    fn close(sink self: File) void {
        @drop(self)
    }
}

fn main(out: Io) void {
    const f = File{ .fd = 1 }
    out.print(f.fd)          // f is never closed
}
```

```egg
// expect: 2
// expect: 1
// expect: 2
uses alloc, io

const Conn = owned struct {
    id: i64

    fn deinit(sink self: Conn) void {
        @drop(self)
    }
}

fn open(id: i64) Conn {
    return Conn{ .id = id }
}

fn main(out: Io, a: Allocator) void {
    var pool: Buf(Conn) = .empty
    defer a.free(pool)               // deinit on each one left
    a.push(&pool, open(1))
    a.push(&pool, open(2))
    out.print(@len(pool))
    const c = a.pop(&pool) orelse return
    out.print(@len(pool))
    out.print(c.id)
    c.deinit()
}
```

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
fn doubled(a: Allocator, sink b: Buf(i64)) Buf(i64) {
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
// expect: 3
// expect: 33
// expect: 2
uses alloc, io

const List = struct {
    data: Buf(i64)
    len: i64

    fn push(inout self: List, a: Allocator, x: i64) void {
        if (self.len == @len(self.data)) {
            a.resize(&self.data, 2 * self.len + 1, 0)
        }
        self.data[self.len] = x
        self.len = self.len + 1
    }
}

fn main(out: Io, a: Allocator) void {
    var l = List{ .data = .empty, .len = 0 }
    l.push(a, 1)
    l.push(a, 2)
    l.push(a, 30)
    out.print(l.len)
    out.print(l.data[0] + l.data[1] + l.data[2])
    a.free(l)                // frees l.data

    var rows = a.alloc(2, Buf(u8).empty)
    defer a.free(rows)       // frees each row, then rows
    a.free(@replace(&rows[1], a.alloc(2, 7)))
    const row = @take(&rows[1])
    out.print(@len(row))
    a.free(row)
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

**Pools instead of an arena.** There is no arena allocator that frees
everything at once: nothing could stop a value allocated from it from
being used after the arena is gone. Data that is built together and
dropped together goes in a **pool** instead: a `Buf` of plain records
that refer to each other by index. The pool is one owned value, so one
`a.free` releases all of it. An index is a plain `i64`: one from another
pool, or one left over after a `pop`, reads the wrong record or panics
with `index out of bounds`, but never touches freed memory (a wrapper such
as `const NodeId = struct { i: i64 }` keeps indices of different pools
apart). A record that holds its own `Buf` is freed record by record; to
keep it at one `free` per pool, put variable-length parts in a shared pool
too and keep a start and a count, which suits data built once and then
read, such as a syntax tree:

```egg
// expect: 0 1 3 4 2 5
// expect: 20
uses alloc, io

const Op = enum { num, add, mul }

// A node's children are kids[first_kid .. first_kid + kid_count].
const Node = struct { op: Op, val: i64, first_kid: i64, kid_count: i64 }

const Tree = struct {
    nodes: Buf(Node)
    kids: Buf(i64)

    fn num(inout self: Tree, a: Allocator, v: i64) i64 {
        a.push(&self.nodes, Node{ .op = .num, .val = v, .first_kid = 0, .kid_count = 0 })
        return @len(self.nodes) - 1
    }

    // l and r are built first, so their ids go to the end of kids.
    fn bin(inout self: Tree, a: Allocator, op: Op, l: i64, r: i64) i64 {
        const first = @len(self.kids)
        a.push(&self.kids, l)
        a.push(&self.kids, r)
        a.push(&self.nodes, Node{ .op = op, .val = 0, .first_kid = first, .kid_count = 2 })
        return @len(self.nodes) - 1
    }

    fn eval(self: Tree, id: i64) i64 {
        const n = self.nodes[id]
        if (n.op == .num) {
            return n.val
        }
        var acc: i64 = 0
        if (n.op == .mul) {
            acc = 1
        }
        for (self.kids[n.first_kid..n.first_kid + n.kid_count]) |k| {
            if (n.op == .add) {
                acc = acc + self.eval(k)
            } else {
                acc = acc * self.eval(k)
            }
        }
        return acc
    }
}

fn main(out: Io, a: Allocator) void {
    var t = Tree{ .nodes = .empty, .kids = .empty }
    defer a.free(t)                  // the whole tree: two buffers
    // (2 + 3) * (4 * 1)
    const sum = t.bin(a, .add, t.num(a, 2), t.num(a, 3))
    const prod = t.bin(a, .mul, t.num(a, 4), t.num(a, 1))
    const root = t.bin(a, .mul, sum, prod)
    var ids = ""
    for (t.kids) |k| {
        ids = a.concat(ids, a.concat(a.int_str(k), " "))
    }
    out.print(ids[0..@len(ids) - 1])
    out.print(t.eval(root))
}
```

## 22. Not yet

Closures, unwrapping an optional by capture (`if (x) |v|`, `while (x)
|v|`) or `x.?`, optional owned fields (`?Db` in a struct), many-item
pointers, reflection beyond
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
