#!/bin/sh
# Installs Egg's eggc and clutch from a GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/femto/egg/main/install.sh | sh
#
# EGG_VERSION=0.1.0 picks a release (default: the latest); EGG_HOME is
# where it goes (default: ~/.egg); EGG_DOWNLOAD_BASE replaces the release's
# download URL (a mirror, or file:// for testing). Each release unpacks to
# $EGG_HOME/egg-VERSION-PLATFORM, and $EGG_HOME/bin/eggc and clutch link to
# the one installed last. eggc compiles through C, so it needs a C
# compiler (cc, or CC=...).
set -eu

repo="femto/egg"
home="${EGG_HOME:-$HOME/.egg}"

say() { printf 'egg: %s\n' "$*"; }
die() { printf 'egg: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) die "no release for $(uname -s); on Windows use install.ps1 in PowerShell" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) cpu=x86_64 ;;
  arm64 | aarch64) cpu=arm64 ;;
  *) die "no release for $(uname -m) on $os" ;;
esac
platform="$os-$cpu"

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
  latest() { curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q "$1" -O "$2"; }
  latest() { wget -q --max-redirect=5 -S --spider "https://github.com/$repo/releases/latest" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1 | tr -d '\r'; }
else
  die "needs curl or wget"
fi

version="${EGG_VERSION:-}"
if [ -z "$version" ]; then
  # The latest release's page is .../releases/tag/vX.Y.Z.
  version=$(latest | sed -n 's#.*/tag/v##p')
  [ -n "$version" ] || die "could not find the latest release of $repo"
fi
version="${version#v}"

name="egg-$version-$platform"
base="${EGG_DOWNLOAD_BASE:-https://github.com/$repo/releases/download/v$version}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading Egg $version for $platform"
fetch "$base/$name.tar.gz" "$tmp/$name.tar.gz" || die "no $name.tar.gz in release v$version"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "no SHA256SUMS in release v$version"

want=$(sed -n "s/^\([0-9a-f]*\)  $name.tar.gz\$/\1/p" "$tmp/SHA256SUMS")
[ -n "$want" ] || die "SHA256SUMS does not list $name.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
else
  got=$(shasum -a 256 "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
fi
[ "$got" = "$want" ] || die "$name.tar.gz does not match its SHA-256 sum; not installed"

mkdir -p "$home/bin"
rm -rf "${home:?}/$name"
tar -xzf "$tmp/$name.tar.gz" -C "$home"
for tool in eggc clutch; do
  ln -sf "../$name/bin/$tool" "$home/bin/$tool"
done
# Each run on its own line, so that set -e stops on a binary that fails.
eggc_version=$("$home/bin/eggc" --version) || die "the installed eggc does not run"
clutch_version=$("$home/bin/clutch" --version) || die "the installed clutch does not run"
say "installed $eggc_version and $clutch_version in $home"

if ! command -v "${CC:-cc}" >/dev/null 2>&1; then
  say "note: eggc compiles through C and finds no '${CC:-cc}'; install a C compiler (Xcode's command line tools, gcc or clang), or set CC"
fi

case ":$PATH:" in
  *":$home/bin:"*) ;;
  *)
    say "add it to your PATH, for example in ~/.profile, ~/.bashrc or ~/.zshrc:"
    printf '\n    export PATH="%s/bin:$PATH"\n\n' "$home"
    ;;
esac
