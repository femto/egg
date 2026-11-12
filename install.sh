#!/bin/sh
# Installs Egg's eggc and clutch from a GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/femto/egg/main/install.sh | sh
#
# EGG_VERSION=0.1.0 picks a release (default: the latest); EGG_HOME is
# where it goes (default: ~/.egg); EGG_DOWNLOAD_BASE replaces the release's
# download URL (a mirror, or file:// for testing). Each release unpacks to
# $EGG_HOME/egg-VERSION-PLATFORM, and $EGG_HOME/bin/eggc and clutch link to
# the one installed last. It puts $EGG_HOME/bin on PATH in your shells'
# startup files (EGG_NO_MODIFY_PATH=1 leaves them alone). eggc compiles
# through C, so it needs a C compiler (cc, or CC=...).
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
  # Not -q, which would hide the headers -S prints.
  latest() { wget --max-redirect=5 -S --spider "https://github.com/$repo/releases/latest" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1 | tr -d '\r'; }
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

# "SUM  FILE", or "SUM *FILE" as sha256sum writes in binary mode.
want=$(tr -d '\r' < "$tmp/SHA256SUMS" | sed -n "s/^\([0-9a-fA-F]*\) [ *]$name.tar.gz\$/\1/p" | tr 'A-F' 'a-f')
[ -n "$want" ] || die "SHA256SUMS does not list $name.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
else
  got=$(shasum -a 256 "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
fi
[ "$got" = "$want" ] || die "$name.tar.gz does not match its SHA-256 sum; not installed"

# Unpacked and run in a directory of its own beside the installed ones
# first (the same file system, so putting it in place is a rename), so that
# a release that does not run here leaves what is installed alone.
mkdir -p "$home/bin"
# Absolute and without a trailing slash, since env and the startup files
# name it.
home=$(cd "$home" && pwd)
stage=$(mktemp -d "$home/.install-XXXXXX")
trap 'rm -rf "$tmp" "$stage"' EXIT INT TERM
tar -xzf "$tmp/$name.tar.gz" -C "$stage"
eggc_version=$("$stage/$name/bin/eggc" --version) || die "$name's eggc does not run here; nothing was changed"
clutch_version=$("$stage/$name/bin/clutch" --version) || die "$name's clutch does not run here; nothing was changed"
rm -rf "${home:?}/$name"
mv "$stage/$name" "$home/$name"
for tool in eggc clutch; do
  ln -sf "../$name/bin/$tool" "$home/bin/$tool"
done
say "installed $eggc_version and $clutch_version in $home"

if ! command -v "${CC:-cc}" >/dev/null 2>&1; then
  say "note: eggc compiles through C and finds no '${CC:-cc}'; install a C compiler (Xcode's command line tools, gcc or clang), or set CC"
fi

# $EGG_HOME/env (sh, bash, zsh) and env.fish put its bin on PATH, once;
# each shell's startup file sources them, as rustup and uv do.
# EGG_NO_MODIFY_PATH=1 leaves the startup files alone.
# $q is $home quoted for sh ('...'\''...'), $fq for fish, whose single
# quotes take \' and \\.
q=$(printf '%s' "$home" | sed "s/'/'\\\\''/g")
fq=$(printf '%s' "$home" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")
# ${PATH:+:$PATH}: no empty entry (the current directory) when PATH is
# empty, and no error when it is unset under set -u.
cat > "$home/env" <<EOF
# Puts Egg's eggc and clutch on PATH; install.sh wrote this.
case ":\${PATH-}:" in
  *:'$q/bin':*) ;;
  *) export PATH='$q/bin'"\${PATH:+:\$PATH}" ;;
esac
EOF
cat > "$home/env.fish" <<EOF
# Puts Egg's eggc and clutch on PATH; install.sh wrote this.
if not contains -- '$fq/bin' \$PATH
    set -gx PATH '$fq/bin' \$PATH
end
EOF

# Appends line $2 to file $1 unless it is there already.
add_line() {
  if [ -f "$1" ] && grep -qxF "$2" "$1"; then
    return 0
  fi
  mkdir -p "$(dirname "$1")"
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
    printf '\n' >> "$1"
  fi
  printf '%s\n' "$2" >> "$1"
  changed="$changed $1"
}

if [ -z "${EGG_NO_MODIFY_PATH:-}" ]; then
  changed=""
  line=". '$q/env'"
  shell_name=$(basename "${SHELL:-sh}")
  # Login shells (sh, dash, bash without a .bash_profile) read ~/.profile.
  add_line "$HOME/.profile" "$line"
  if [ -f "$HOME/.bash_profile" ]; then add_line "$HOME/.bash_profile" "$line"; fi
  if [ -f "$HOME/.bashrc" ] || [ "$shell_name" = bash ]; then add_line "$HOME/.bashrc" "$line"; fi
  # Every zsh reads .zshenv, login or not, interactive or not.
  if command -v zsh >/dev/null 2>&1 || [ "$shell_name" = zsh ]; then
    add_line "${ZDOTDIR:-$HOME}/.zshenv" "$line"
  fi
  fish_conf="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
  if command -v fish >/dev/null 2>&1 || [ "$shell_name" = fish ] || [ -d "$fish_conf" ]; then
    add_line "$fish_conf/conf.d/egg.fish" "source '$fq/env.fish'"
  fi
  if [ -n "$changed" ]; then
    say "put $home/bin on PATH in$changed"
  fi
fi

case ":$PATH:" in
  *":$home/bin:"*) ;;
  *)
    if [ -n "${EGG_NO_MODIFY_PATH:-}" ]; then
      say "to put eggc and clutch on your PATH, have your shell's startup file run:"
    else
      say "open a new terminal, or run this to use eggc and clutch in this one:"
    fi
    printf "\n    . '%s/env'        (fish: source '%s/env.fish')\n\n" "$q" "$fq"
    ;;
esac
