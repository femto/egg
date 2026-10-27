# SQLite3 FFI demo: a toy blog

Posts, tags (many-to-many) and comments on SQLite, ported from Spinel's
`examples/ffi/sqlite`. It shows:

- opening and closing an in-memory database (`sqlite3 **` out-parameter
  as `&h`; `sqlite3_close_v2`)
- statements with `prepare_v2` / `step` / `finalize`, and
  `column_int64` / `column_text`
- bound parameters (`?`) instead of quoting: text goes in by pointer and
  length (`@strPtr(s)`, `@len(s)`), so it needs no 0 at the end
- `last_insert_rowid` and a few joins

## Setup

`link "sqlite3"` in `sqlite3.egg` becomes `-lsqlite3`. macOS ships the
library. Elsewhere install it (no headers needed: eggc declares the
functions itself):

```sh
sudo apt install libsqlite3-dev    # Debian / Ubuntu
sudo dnf install sqlite-devel      # Fedora
```

## Build & run

```sh
bin/eggc run examples/ffi/sqlite/blog.egg
```

```
Posts (with comment + tag counts):
  [1] Egg learns to call C  (2 comments, 3 tags)
  [2] Tasting o'tea  (1 comments, 2 tags)
  [3] Checked arithmetic is cheap  (1 comments, 2 tags)

Posts tagged 'egg':
  - Egg learns to call C
  - Checked arithmetic is cheap

Comments on the FFI post:
  alice: Wonderful — does it work with libcurl too?
  bob: I tried sqlite3 myself; the bindings are tidy.
```

## Files

- `sqlite3.egg`: the bindings. The only `allow unsafe` file: it holds
  the `extern fn` declarations and wraps them in `Db` and `Stmt`, whose
  methods take and return plain Egg values and errors.
- `blog.egg`: the program. It needs no `allow unsafe`.

## Owned handles

`Db` and `Stmt` are `owned struct`s, so the compiler checks them like
buffers:

- a copy is a move: `const d2 = db` leaves `db` unusable, so nothing can
  close it twice;
- each one must be ended on every path: forgetting `defer st.finalize()`
  is E135 at every `try` that could leave without it;
- only `sqlite3.egg` can build one (`Db{ .handle = p }`) or end one
  without SQLite (`@drop`), so `blog.egg` gets them only from `open` and
  `prepare` and ends them only with `close` and `finalize`.

Methods that only use a handle take `inout self`, so `blog.egg` keeps
them in `var`s and passes the database as `&db`.

## Notes

- SQLite's handles are opaque, so they cross as `*u8`.
- `Stmt.text` copies the column with `a.str_from_c`: SQLite's bytes last
  only until the next step.
- `SQLITE_TRANSIENT` (`(void *)-1`, which tells SQLite to copy bound text)
  is `@ptrFromInt(*u8, 18446744073709551615)`.
- Egg does not let a value go unused, so the result codes of `close` and
  `finalize` are dropped through a tiny `ignore(rc)`.

## Limits

- Nothing ties a `Stmt` to its `Db`, so the compiler does not catch
  closing the database before finalizing a statement. `close` calls
  `sqlite3_close_v2`, which makes that order safe: the connection stays
  alive until its last statement is finalized, instead of
  `sqlite3_close` refusing with `SQLITE_BUSY` and leaving it open.
- `Stmt.text` reads up to the first 0 byte, so TEXT holding a 0 byte is
  cut there (a length-aware copy with `sqlite3_column_bytes` needs a
  pointer-and-length to `str` conversion Egg does not have yet).
