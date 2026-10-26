# libc / libm FFI demo

Calls a handful of libm and libc functions directly, ported from Spinel's
`examples/ffi/libm`. libc is always linked; `link "m"` adds libm (part of
libc on macOS, its own `-lm` on Linux).

```sh
bin/eggc run examples/ffi/libm/libm.egg
```

```
1.0
4.0
1024
479425
H
pid > 0: true
```

Differences from the Spinel version: Egg prints floats as floats (the
shortest decimal that reads back the same), so `cos(0)` prints `1.0`; `sin(0.5)` is printed
to six digits only, since libms may differ in its last bit.
`strlen` cannot be declared, because the generated C already includes
`<string.h>` (E132); the demo calls `toupper` on a C string made with
`a.cstr` and reads it back with `a.str_from_c` instead.
