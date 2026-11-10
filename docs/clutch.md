# clutch, Egg's package manager

`clutch` (a clutch of eggs) builds Egg packages and their dependencies. It
is a separate tool beside the compiler, as cargo is beside rustc: `eggc`
reads no manifest, touches no network and keeps no state, and gets each
package as `--pkg NAME=DIR`. Everything stateful (the manifest, version
selection, git, the index, the cache, the lock) is clutch's. The design
follows Spinel's `spin`.

## A package

```
chat/
  clutch.toml     the manifest
  clutch.lock     what clutch chose (a program commits it; a library does not)
  src/
    main.egg      a program's main
    chat.egg      a library's entry: @import("chat")
    util.egg      a part of it: @import("chat/util"), or "util.egg" inside
  build/          clutch build's output
```

`@import("NAME")` is `src/NAME.egg` of the package NAME and
`@import("NAME/x")` is its `src/x.egg`, the same rule as `std`. A
package's files cannot import files outside its `src/`; other packages are
reached by name only.

## clutch.toml

```toml
[package]
name = "chat"
version = "0.1.0"

[dependencies]
http = "~> 0.1"                                    # from the index
ansi = { git = "https://github.com/x/egg-ansi" }   # its default branch
term = { git = "https://...", ref = "v0.2.0" }     # a branch, tag or commit
util = { path = "../util" }                        # a directory
```

A git or path dependency may add `version = "..."`, checked against that
package's own `clutch.toml`. Constraints: `"1.2.0"` (exactly), `">= 1.2"`,
`"< 2"`, `"~> 1.2"` (1.2 up to 2.0), `"~> 1.2.3"` (1.2.3 up to 1.3.0),
`"*"`, or several joined by commas.

## Choosing versions

- **One version of each package per program**, since two copies of its
  types would be different types. The dependency graph is walked breadth
  first in manifest order; a package is chosen where it is first reached,
  and a later requirement that does not accept that choice is an error
  (there is no solver).
- **The lowest release a constraint accepts** (minimal version selection).
  A build never moves to a newer release by itself, and without a lock the
  result is still the same every time.
- **The lock comes first.** A package pinned in `clutch.lock` keeps its pin
  while the manifest still accepts it, without reading the index or the
  network. `clutch update [NAME...]` chooses afresh. A git dependency is
  pinned to a full commit SHA; a path dependency is read where it is and
  never pinned.

## The index

[femto/clutch-index](https://github.com/femto/clutch-index) is a git
repository, not a server: `packages/NAME.toml` maps a name to its
repository and releases, each a version and a full commit SHA. Publishing
is a pull request there. `CLUTCH_INDEX` names another index (a URL or, for
testing, a directory).

## The cache

`$CLUTCH_CACHE`, or `$XDG_CACHE_HOME/clutch`, or `~/.cache/clutch`:

```
git/db/<repo>-<hash>      a bare clone of each repository (and of the index)
git/src/<name>-<sha12>    a package's files at one commit, extracted once
```

Each repository is fetched at most once a run. With `CLUTCH_OFFLINE=1`
clutch never fetches, so a locked build works from the cache alone.

## Commands

```bash
clutch new chat              # a program: src/main.egg
clutch new --lib util        # a library: src/util.egg
clutch add http              # from the index, "~> MAJOR.MINOR" of its newest release
clutch add http "~> 0.2"
clutch add ansi --git URL [--ref REF]
clutch add util --path ../util
clutch remove http
clutch check                 # a library is checked through a root that imports it
clutch build [--release] [-g] [-o EXE]   # into build/NAME by default
clutch run [--release] [-g] [-- ARGS]
clutch flags                 # the --pkg flags, for running eggc by hand
clutch lock                  # resolve and write clutch.lock
clutch update [NAME...]      # ignore the lock (for those packages)
```

`CLUTCH_EGGC` names the eggc to run (default: `bin/eggc` beside clutch).

## Not yet

- The language server does not know packages yet; it will take them from
  `clutch flags`.
- `clutch publish` (writing the index file and opening the pull request).
- Per-package compilation and caching: every build still compiles the
  whole program from source. The plan is Rust's: each package compiled
  once and cached, its interface being its signatures and their
  capability and inout summaries, generics instantiated by their users.
- A package carrying C sources, and dependencies only for tests.
