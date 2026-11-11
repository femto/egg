# Installs Egg's eggc and clutch on Windows from a GitHub release:
#
#   irm https://raw.githubusercontent.com/femto/egg/main/install.ps1 | iex
#
# $env:EGG_VERSION = "0.1.0" picks a release (default: the latest);
# $env:EGG_HOME is where it goes (default: ~\.egg); $env:EGG_DOWNLOAD_BASE
# replaces the release's download URL (a mirror, or file:/// for testing). Each release unpacks to
# $EGG_HOME\egg-VERSION-windows-x86_64, and $EGG_HOME\bin\eggc.cmd and
# clutch.cmd run the one installed last; $EGG_HOME\bin goes on your user
# PATH. eggc compiles through C, so it needs gcc (MSYS2's UCRT64, or
# RubyInstaller's Devkit) and CC=gcc.

$ErrorActionPreference = "Stop"
$repo = "femto/egg"
$home_ = if ($env:EGG_HOME) { $env:EGG_HOME } else { Join-Path $HOME ".egg" }

function Say($msg) { Write-Host "egg: $msg" }

if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
  throw "egg: there is a release for 64-bit x86 Windows only"
}

$version = $env:EGG_VERSION
if (-not $version) {
  $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}
$version = $version.TrimStart("v")

$name = "egg-$version-windows-x86_64"
$base = if ($env:EGG_DOWNLOAD_BASE) { $env:EGG_DOWNLOAD_BASE } else { "https://github.com/$repo/releases/download/v$version" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Say "downloading Egg $version for windows-x86_64"
  $zip = Join-Path $tmp "$name.zip"
  Invoke-WebRequest "$base/$name.zip" -OutFile $zip -UseBasicParsing
  $sums = (Invoke-WebRequest "$base/SHA256SUMS" -UseBasicParsing).Content
  if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
  $line = ($sums -split "`n") | Where-Object { $_ -match "^([0-9a-f]+)  $([regex]::Escape("$name.zip"))\s*$" } | Select-Object -First 1
  if (-not $line) { throw "egg: SHA256SUMS does not list $name.zip" }
  $want = ($line -split " ")[0]
  $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want) { throw "egg: $name.zip does not match its SHA-256 sum; not installed" }

  New-Item -ItemType Directory -Force -Path (Join-Path $home_ "bin") | Out-Null
  $dest = Join-Path $home_ $name
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Expand-Archive $zip -DestinationPath $home_
} finally {
  Remove-Item -Recurse -Force $tmp
}

foreach ($tool in "eggc", "clutch") {
  Set-Content -Path (Join-Path $home_ "bin\$tool.cmd") -Encoding ASCII -Value "@`"%~dp0..\$name\bin\$tool.exe`" %*"
}
$eggc = Join-Path $home_ "$name\bin\eggc.exe"
$clutch = Join-Path $home_ "$name\bin\clutch.exe"
Say "installed $(& $eggc --version) and $(& $clutch --version) in $home_"

$bin = Join-Path $home_ "bin"
$path = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not (($path -split ";") -contains $bin)) {
  [Environment]::SetEnvironmentVariable("Path", (@($bin) + ($path -split ";" | Where-Object { $_ })) -join ";", "User")
  Say "added $bin to your user PATH; open a new terminal to use eggc and clutch"
}

if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
  Say "note: eggc compiles through C and finds no gcc; install MSYS2's UCRT64 gcc (or RubyInstaller's Devkit) and set CC=gcc"
}
