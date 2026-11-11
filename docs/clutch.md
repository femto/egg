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
  test/
    parse.egg     a test: a program of its own, run by clutch test
    parse.expected  what it must print (optional)
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

[dev-dependencies]                                 # for the tests only
check = "~> 0.2"
```

A git or path dependency may add `version = "..."`, checked against that
package's own `clutch.toml`. Constraints: `"1.2.0"` (exactly), `">= 1.2"`,
`"< 2"`, `"~> 1.2"` (1.2 up to 2.0), `"~> 1.2.3"` (1.2.3 up to 1.3.0),
`"*"`, or several joined by commas.

A dev-dependency is for the package's tests: `src/` cannot import it, its
users do not get it, and a dependency's own dev-dependencies are never
read. It is resolved after the dependencies, so it never changes what they
resolve to, and it is recorded in the lock like them.

## Tests

Each `test/NAME.egg` is a test: a program with a `main`, built with the
package (`@import("NAME")`), its dependencies and its dev-dependencies, and
run in the package's directory. It passes when it exits 0 (a `main` that
returns an error fails) and, if there is a `test/NAME.expected`, prints
exactly that. `clutch test` runs them all, `clutch test NAME...` some;
`clutch new --lib` makes one.

## Choosing versions

- **One version of each package per program**, since two copies of its
  types would be different types. The dependency graph is walked breadth
  first in manifest order; a package is chosen where it is first reached,
  and a later requirement that does not accept that choice is an error
  (there is no solver).
- **The lowest release a constraint accepts** (minimal version selection).
  A build never moves to a newer release by itself: an index dependency
  resolves the same way until the index gains or loses a release its
  constraint accepts. A git dependency on a branch follows the branch, and
  a path dependency is whatever its directory holds, so a repeatable build
  needs the lock.
- **The lock comes first.** A package pinned in `clutch.lock` keeps its pin
  while the manifest still accepts it, and choosing it reads neither the
  index nor the repository. Its files still come from the cache, fetched
  if that commit is not there yet. `clutch update [NAME...]` chooses afresh.
  A git dependency is pinned to a full commit SHA; a path dependency is
  read where it is and never pinned.

## The index

[femto/clutch-index](https://github.com/femto/clutch-index) is a git
repository, not a server: `packages/NAME.toml` maps a name to its
repository and releases, each a version and a full commit SHA. Publishing
is a pull request there. `CLUTCH_INDEX` names another index (a URL or, for
testing, a directory).

## Publishing

`clutch publish`, in a library's repository, adds its current commit to the
index as the version its `clutch.toml` gives:

- The package is a library (`src/NAME.egg`) at the root of a git work tree
  with nothing uncommitted, and its repository (`origin`, or `--repo URL`)
  has the commit on a branch or tag: clutch fetches it from there and
  checks the release as its users will get it, whose `clutch.toml` must
  give the same name and version. A path or `file://` repository is
  refused (only a test index, a directory, takes one), and so is a path
  dependency, which users could not fetch.
- The version must be new to the index, and the name, if the index has it,
  must belong to the same repository: a name belongs to the package that
  first took it. The release is added in version order.
- Last, `clutch check` and, if it has tests, `clutch test` must pass on a
  copy of the release (not the work tree, which may hold files the
  repository does not).
- Then, for an index on GitHub, clutch clones it, commits
  `packages/NAME.toml` on a branch `NAME-VERSION` (in a fork when you
  cannot push to the index), and opens the pull request with `gh`. An
  index that is a directory is written in place.

`--dry-run` does every check and prints the file it would write. Publishing
writes nothing into the package's directory.

## The cache

`$CLUTCH_CACHE`, or `$XDG_CACHE_HOME/clutch`, or `~/.cache/clutch`:

```
git/db/<repo>-<hash>      a bare clone of each repository (and of the index)
git/src/<name>-<sha12>    a package's files at one commit, extracted once
```

Each repository is fetched at most once a run. With `CLUTCH_OFFLINE=1`
clutch never fetches: a locked build then works when the cache already
holds every pinned commit, and fails naming what is missing otherwise.

## Commands

```bash
clutch new chat              # a program: src/main.egg
clutch new --lib util        # a library: src/util.egg
clutch add http              # from the index, "~> MAJOR.MINOR" of its newest release
clutch add http "~> 0.2"
clutch add ansi --git URL [--ref REF]
clutch add util --path ../util
clutch add check --dev       # a dev-dependency (with any of the forms above)
clutch remove http
clutch check                 # a library is checked through a root that imports it
clutch build [--release] [-g] [-o EXE]   # into build/NAME by default
clutch run [--release] [-g] [-- ARGS]
clutch test [NAME...]        # build and run test/*.egg
clutch flags                 # the --pkg flags, for running eggc by hand
clutch lock                  # resolve and write clutch.lock
clutch update [NAME...]      # ignore the lock (for those packages)
clutch publish [--repo URL] [--dry-run]   # this commit as a release (a pull request to a GitHub index)
```

`CLUTCH_EGGC` names the eggc to run (default: `bin/eggc` beside clutch).

## Not yet

- The language server does not know packages yet; it will take them from
  `clutch flags`.
- Per-package compilation and caching: every build still compiles the
  whole program from source. The plan is Rust's: each package compiled
  once and cached, its interface being its signatures and their
  capability and inout summaries, generics instantiated by their users.
- A package carrying C sources.
- Tests inside the source (`test "name" { ... }` blocks): a test is a
  program for now.
