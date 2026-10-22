# Egg core language specification (v1)

This is the complete definition of the v1 core. It is written to be loaded
into a model's context in one piece, together with `grammar.ebnf` (syntax)
and `diagnostics.md` (error codes). `eggc spec` prints all three.

Every ```egg block in this file is compiled and run by `test/run.rb`, so the
examples cannot drift from the compiler. A block's `// expect:` lines are its
required output; `// error: CODE` means it must fail with that code;
`// fails: Name` means `main` must return `error.Name`.

## 1. Programs

A program is one source file containing functions and type declarations
(`const Name = struct / enum / union(enum) { ... }`), in any order. Every
function can call every other function, including itself.

There must be a function `main` with no parameters returning `void`, `i64`
or `!void` (E109). When `main` returns `i64`, the value becomes the process
exit status (the operating system keeps only the low bits, usually 8). When
it returns an error, the program prints `error: Name` to standard error and
exits with status 1.

```egg
// expect: 3
fn main() void {
    @print(add(1, 2))   // add is declared below; order does not matter
}

fn add(a: i64, b: i64) i64 {
    return a + b
}
```

## 2. Lexical structure

- Source is UTF-8. Identifiers are ASCII: `[A-Za-z_][A-Za-z0-9_]*`.
- Keywords: `fn return if else while for break continue switch var const
  true false and or struct enum union try catch error inout comptime`.
- Integer literals are decimal digits, optionally separated by `_`
  (`1_000_000`). The value must be at most 9223372036854775807 (E003).
  There are no negative literals; `-5` is unary minus applied to `5`.
- String literals are `"..."` on one line, with escapes `\n \t \\ \" \0`.
- `//` starts a comment that runs to the end of the line.
- **Newlines end statements.** A newline may also appear after a binary
  operator, after `(` `[` `{` or `,`, and before `else`. Anywhere else inside
  an expression, a newline is a syntax error (E002).
- A name that starts with a capital letter followed by `{` is a struct
  literal (`Point{ .x = 1 }`), so type names start with a capital letter.

```egg
// expect: 6
fn main() void {
    const total = 1 +
                  2 +
                  3
    @print(total)
}
```

## 3. Types

| Type | Values | Notes |
| --- | --- | --- |
| `i64` | signed 64-bit integers | the only numeric type |
| `bool` | `true`, `false` | |
| `str` | immutable byte strings | literals only in v1; see section 8 |
| `void` | none | only as a function result (E108 elsewhere) |
| struct `Name` | records of named fields | section 9 |
| enum `Name` | one of a fixed set of names | section 10 |
| `union(enum)` `Name` | one member, maybe with a payload | section 10 |
| `[N]T` | N values of type T, N >= 1 | value type; section 11 |
| `[]T` | a read-only view of consecutive T | parameters only; section 11 |
| `!T` | a T or an error | section 13 |
| `type` | a type, at compile time only | `comptime` parameters; section 14 |

Every type except slices is a **value type**: assignment, passing and
returning copy the value. There are **no implicit conversions**. Every
operator and every assignment, argument and return requires exactly the
expected type (E103), with two exceptions: a `T` fits where `!T` is
expected, and `error.X` fits any `!T`. Integers are not booleans: `if (1)`
is an error.

```egg
// error: E103
fn main() void {
    if (1) { @print(1) }
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
   and types are the exception: they are visible everywhere.
2. **A local lives until the end of the block that declares it.**
3. **No shadowing.** A local or parameter may not reuse the name of any
   visible local, parameter, function or type (E106).
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
fn main() void {
    var x = 1          // never changed: must be const
    @print(x)
}
```

```egg
// error: E106
fn main() void {
    const x = 1
    if (x > 0) {
        const x = 2    // shadows the outer x
        @print(x)
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
fn sign(n: i64) i64 {
    if (n < 0) { return -1 }
}

fn main() void {
    @print(sign(1))
}
```

## 6. Statements

| Statement | Meaning |
| --- | --- |
| `const` / `var` declaration | section 4 |
| `x = e`, `p.f = e`, `a[i] = e` | assign to a variable, a field or an element of a mutable variable |
| `if (c) { } else if (c) { } else { }` | `c` must be `bool`; braces are required |
| `while (c) { }` | repeats while `c` is true |
| `for (xs) \|x\| { }`, `for (xs) \|x, i\| { }` | each element of an array, a slice or a str (bytes as i64), with its index `i` |
| `break`, `continue` | leave or restart the innermost loop (E126 outside one) |
| `switch (x) { ... }` | section 10 |
| `return` / `return e` | section 5 |
| expression | must have type `void` (E113); a result or an error may not be discarded |

Loop variables are constants; name one `_` to ignore it. Rule E113 is why
`two()` alone on a line is an error when `two` returns `i64`, and why a
`!void` call must be handled with `try` or `catch`.

```egg
// expect: 1
// expect: 3
fn main() void {
    const xs = [4]i64{ 1, 2, 3, 4 }
    for (xs) |x, i| {
        if (x % 2 == 0) {
            continue
        }
        if (i > 2) {
            break
        }
        @print(x)
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
| 4 | `==` `!=` | both i64, bool, str or the same enum | bool |
| 4 | `<` `<=` `>` `>=` | i64 | bool |
| 5 | `+` `-` | i64 | i64 |
| 6 | `*` `/` `%` | i64 | i64 |
| 7 | unary `-`, `!`, `try`, `&` | i64 / bool / `!T` / place | |
| 8 | `a.f`, `a.m(...)`, `a[i]`, `a[lo..hi]`, calls | | |

- `and` / `or` short-circuit: the right side is evaluated only if needed.
- Structs, unions and arrays cannot be compared with `==` (E103).
- **Evaluation is left to right.** Operands and arguments are evaluated in
  the order they are written, so `f() + g()` always calls `f` first.

### Integer arithmetic is checked

Egg has no undefined behaviour. Every `i64` operation either produces the
mathematically correct result or stops the program with a panic:

| Operation | Result |
| --- | --- |
| `a + b`, `a - b`, `a * b`, `-a` | exact result, or panic `integer overflow` |
| `a / b` | quotient truncated toward zero; panic `division by zero` if `b == 0`; panic `integer overflow` for `-9223372036854775807 - 1` divided by `-1` |
| `a % b` | remainder with the sign of `a` (so `a == (a / b) * b + a % b`); panic `division by zero` if `b == 0`; the minimum value `% -1` is `0` |

Indexing and slicing are checked too: panic `index out of bounds` or
`slice out of bounds`. A panic prints `egg panic: <message>` to standard
error and aborts the process with a non-zero status.

```egg
// expect: -3
// expect: -1
// expect: 3
// expect: 1
fn main() void {
    @print(-7 / 2)
    @print(-7 % 2)
    @print(7 / 2)
    @print(7 % -2)
}
```

```egg
// panic: integer overflow
fn main() void {
    const big = 9223372036854775807
    @print(big + 1)
}
```

```egg
// expect: 1
// expect: 2
// expect: 3
fn one() i64 {
    @print(1)
    return 1
}

fn two() i64 {
    @print(2)
    return 2
}

fn main() void {
    @print(one() + two())
}
```

## 8. Strings

`str` is an immutable sequence of bytes. In v1 every `str` is a literal or
a slice of one, so it never needs freeing.

- `@len(s)` is its length in bytes; `s[i]` is the byte at `i` as an `i64`
  (0 to 255); `s[lo..hi]` and `s[lo..]` are `str`s.
- `==` compares contents. `for (s) |b|` visits each byte.
- Strings cannot be concatenated in v1: that needs an allocator (v2).

```egg
// expect: 5
// expect: 104
// expect: ell
// expect: true
fn main() void {
    const s = "hello"
    @print(@len(s))
    @print(s[0])
    @print(s[1..4])
    @print(s[1..] == "ello")
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
  `inout`, so `p` must be a `var`. Any function inside the struct can be
  called as `Point.origin()` or `Point.len2(p)`.
- A struct cannot contain itself by value (E119).
- Field types may be anything except `void`, `type` and slices (E116).

```egg
// expect: 25
// expect: 4
fn main() void {
    var p = Point.origin()
    p.move(3, 4)
    @print(p.len2())
    @print(p.y)
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
fn main() void {
    const shapes = [3]Shape{ Shape{ .circle = 2 }, Shape{ .rect = Size{ .w = 3, .h = 4 } }, .empty }
    var total = 0
    for (shapes) |s| {
        total = total + s.area()
    }
    @print(total)
    @print(next(.red))
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
const Light = enum { red, green }

fn main() void {
    switch (Light.red) {
        .red => {
            @print(1)
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
fn sum(xs: []i64) i64 {
    var total = 0
    for (xs) |x| {
        total = total + x
    }
    return total
}

fn main() void {
    const a = [4]i64{ 1, 2, 3, 4 }
    @print(sum(a[0..]))
    @print(sum(a[1..3]))
    const zeros: [3]i64 = @splat(1)
    @print(sum(zeros[0..]))
}
```

```egg
// error: E116
fn main() void {
    const a = [3]i64{ 1, 2, 3 }
    const view = a[0..2]
    @print(@len(view))
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
fn swap(inout a: i64, inout b: i64) void {
    const t = a
    a = b
    b = t
}

fn main() void {
    var x = 1
    var y = 2
    swap(&x, &y)
    @print(x * 10 + y)
}
```

```egg
// error: E117
fn add_into(inout acc: i64, x: i64) void {
    acc = acc + x
}

fn main() void {
    var total = 1
    add_into(&total, total)
    @print(total)
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

fn main() !void {
    @print(try parse("42"))
    @print(parse("4x") catch -1)
    @print(try parse(""))
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

fn main() void {
    const p = Pair(i64){ .a = 1, .b = 2 }
    @print(p.swap().a)
    @print(max(i64, 3, 9))
    @print(@typeName(Pair(bool)))
}
```

## 15. Builtins

Builtins start with `@`; any other name is E112.

| Builtin | Meaning |
| --- | --- |
| `@print(x)` | prints an `i64`, `bool`, `str` or enum and a newline to standard output |
| `@len(x)` | length of an array, a slice or a `str`, as `i64` |
| `@sizeOf(T)` | size of a value of type T in bytes, as `i64` |
| `@typeName(T)` | the type's name, as a `str` |
| `@splat(v)` | an array with every element `v`; the array type comes from context (E115) |
| `@This()` | inside a struct or union: its own type |

`@print` is temporary. When the `io` capability arrives in v2, printing moves
out of the core, and a program will need an `Out` capability to print.

## 16. Not in v1

Pointers, function values, closures, allocation and anything that owns
memory, string building, integer types other than `i64`, floating point,
reflection beyond `@sizeOf`/`@typeName`, modules, and capabilities. See the
design document's roadmap for when each arrives.

## 17. A complete program

```egg
// expect: 21
// expect: 6765
// expect: true
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

fn main() void {
    @print(gcd(1071, 462))
    @print(fib(20))
    @print(gcd(10, 4) == 2 and fib(10) == 55)
}
```
