# SQLite3 FFI demo: a toy blog

Posts, tags (many-to-many) and comments on SQLite, ported from Spinel's
`examples/ffi/sqlite`. It shows:

- opening and closing an in-memory database (`sqlite3 **` out-parameter
  as `&h`)
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

## Notes

- SQLite's handles are opaque, so they cross as `*u8`.
- `Stmt.text` copies the column with `a.str_from_c`: SQLite's bytes last
  only until the next step.
- `SQLITE_TRANSIENT` (`(void *)-1`, which tells SQLite to copy bound text)
  is `@ptrFromInt(*u8, 18446744073709551615)`.
- Egg does not let a value go unused, so the result codes of `close` and
  `finalize` are dropped through a tiny `ignore(rc)`.
