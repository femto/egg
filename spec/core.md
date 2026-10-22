# Egg core language specification (v0)

This is the complete definition of the v0 core. It is written to be loaded
into a model's context in one piece, together with `grammar.ebnf` (syntax)
and `diagnostics.md` (error codes). `eggc spec` prints all three.

Every ```egg block in this file is compiled and run by `test/run.rb`, so the
examples cannot drift from the compiler. A block's `// expect:` lines are its
required output; `// error: CODE` means it must fail with that code.

## 1. Programs

A program is one source file containing only function declarations, in any
order. Every function can call every other function, including itself.

There must be a function `main` with no parameters returning `void` or `i64`
(E109). When `main` returns `i64`, the value becomes the process exit status
(the operating system keeps only the low bits, usually 8).

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
- Keywords: `fn return if else while var const true false and or`.
- Integer literals are decimal digits, optionally separated by `_`
  (`1_000_000`). The value must be at most 9223372036854775807 (E003).
  There are no negative literals; `-5` is unary minus applied to `5`.
- `//` starts a comment that runs to the end of the line.
- **Newlines end statements.** A newline may also appear after a binary
  operator, after `(` or `,`, and before `else`. Anywhere else inside an
  expression, a newline is a syntax error (E002).

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
| `i64` | signed 64-bit integers | the only numeric type in v0 |
| `bool` | `true`, `false` | |
| `void` | none | only as a function return type (E108 elsewhere) |

There are **no implicit conversions**. Every operator and every assignment,
argument and return requires exactly the expected type (E103). In
particular, integers are not booleans: `if (1)` is an error.

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
   are the exception: they are visible everywhere.
2. **A local lives until the end of the block that declares it.**
3. **No shadowing.** A local or parameter may not reuse the name of any
   visible local, parameter or function (E106). Two functions may not share
   a name (E106).
4. **`const` and parameters cannot be assigned** (E105). Copy a parameter
   into a `var` to change it.
5. **Every local must be read at least once** (E110). Assigning to it does
   not count as reading it.
6. **Every `var` must be assigned at least once after its declaration**
   (E111). If it never changes, it must be `const`.

Rules 5 and 6 follow Zig: an unused or never-changed variable is a sign the
code does not say what it means, so it is rejected rather than tolerated.

```egg
// error: E111
fn main() void {
    var x = 1          // never reassigned: must be const
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
fn name(p1: T1, p2: T2) R { ... }
```

- Parameter types must be `i64` or `bool`; the return type may also be `void`.
- A call must pass exactly as many arguments as there are parameters (E104),
  each of the declared type (E103).
- Arguments are passed by value.
- **A non-void function must return on every path** (E107). A block returns
  on every path when at least one of its statements does, where:
  - `return` always returns;
  - `if` returns only when it has an `else` and both branches return
    (for `else if` chains: every branch, including the final `else`);
  - `while` never counts, even `while (true)`.
- `return` with no value is allowed only in a `void` function, and a `void`
  function cannot return a value (E103).

```egg
// expect: 1
// expect: 2
// expect: 3
fn classify(n: i64) i64 {
    if (n < 0) {
        return 1
    } else if (n == 0) {
        return 2
    } else {
        return 3
    }
}

fn main() void {
    @print(classify(-5))
    @print(classify(0))
    @print(classify(7))
}
```

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
| `const` / `var` declaration | see section 4 |
| `name = expr` | assign to a `var` of the same type |
| `if (cond) { } else if (cond) { } else { }` | `cond` must be `bool`; braces are required |
| `while (cond) { }` | repeats while `cond` is true; `cond` must be `bool` |
| `return` / `return expr` | see section 5 |
| expression | must have type `void` (E113); a non-void result may not be discarded |

Rule E113 is why `two()` alone on a line is an error when `two` returns
`i64`: dropping a result silently is how errors get ignored.

```egg
// error: E113
fn two() i64 { return 2 }

fn main() void {
    two()
}
```

## 7. Expressions

Precedence, lowest first; all binary operators are left-associative except
comparisons, which cannot be chained (`a < b < c` is E002):

| Level | Operators | Operand types | Result |
| --- | --- | --- | --- |
| 1 | `or` | bool | bool |
| 2 | `and` | bool | bool |
| 3 | `==` `!=` | both i64 or both bool | bool |
| 3 | `<` `<=` `>` `>=` | i64 | bool |
| 4 | `+` `-` | i64 | i64 |
| 5 | `*` `/` `%` | i64 | i64 |
| 6 | unary `-` | i64 | i64 |
| 6 | unary `!` | bool | bool |

- `and` / `or` short-circuit: the right side is evaluated only if needed.
- Parentheses group as usual.

### Integer arithmetic is checked

Egg has no undefined behaviour. Every `i64` operation either produces the
mathematically correct result or stops the program with a panic:

| Operation | Result |
| --- | --- |
| `a + b`, `a - b`, `a * b`, `-a` | exact result, or panic `integer overflow` |
| `a / b` | quotient truncated toward zero; panic `division by zero` if `b == 0`; panic `integer overflow` for `-9223372036854775807 - 1` divided by `-1` |
| `a % b` | remainder with the sign of `a` (so `a == (a / b) * b + a % b`); panic `division by zero` if `b == 0`; the minimum value `% -1` is `0` |

A panic prints `egg panic: <message>` to standard error and aborts the
process with a non-zero status.

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

### Evaluation order

Intended semantics: operands and arguments are evaluated left to right.
**Known gap in the v0 compiler:** it emits operands as C function arguments,
whose evaluation order C leaves unspecified, so two calls with visible side
effects in one expression (`f() + g()` where both `@print`) may run in either
order. Programs should not rely on that order until this is fixed in v1.

## 8. Builtins

Builtins start with `@`. v0 has exactly one; any other name is E112.

| Builtin | Meaning |
| --- | --- |
| `@print(x)` | `x` is `i64` or `bool`; prints it and a newline to standard output; returns `void` |

`@print` is temporary. When the `io` capability arrives in v2, printing moves
out of the core, and a program will have to declare `use cap.io` to print.

## 9. Not in v0

Strings, arrays, slices, pointers, structs, enums, tagged unions, error
values, `for`, `switch`, `comptime`, modules and capabilities. See the design
document's roadmap for when each arrives.

## 10. A complete program

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
