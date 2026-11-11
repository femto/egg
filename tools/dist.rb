# Builds a release of eggc and clutch for this machine: both compiled to
# native binaries by Spinel, with the standard library and the spec beside
# them, as dist/egg-VERSION-PLATFORM.tar.gz (.zip on Windows).
#
#   ruby tools/dist.rb [--spinel PATH] [--platform NAME]
#
# PATH is the spinel compiler (default: spinel on PATH); NAME names the
# machine, such as linux-x86_64 (default: worked out from this one). The
# archive unpacks to egg-VERSION-PLATFORM/{bin,lib/std,spec}; install.sh and
# install.ps1 put that directory in place.

require "fileutils"
require "open3"
require "rbconfig"
require_relative "../lib/egg/home"
require_relative "../lib/egg/version"

ROOT = File.expand_path("..", __dir__)

def platform
  os = case RbConfig::CONFIG["host_os"]
       when /linux/ then "linux"
       when /darwin/ then "macos"
       when /mingw|mswin/ then "windows"
       else RbConfig::CONFIG["host_os"]
       end
  cpu = case RbConfig::CONFIG["host_cpu"]
        when /x86_64|x64|amd64/ then "x86_64"
        when /arm64|aarch64/ then "arm64"
        else RbConfig::CONFIG["host_cpu"]
        end
  "#{os}-#{cpu}"
end

def run(*cmd, chdir: ROOT)
  puts "+ #{cmd.join(' ')}"
  out, st = Open3.capture2e(*cmd, chdir: chdir)
  # Spinel warns about large C stack frames in the compiler; not news.
  shown = out.lines.reject { |l| l.include?("-Wframe-larger-than") || l.include?("stack frame size") }
  print shown.join
  abort "dist: failed: #{cmd.join(' ')}" unless st.success?
end

spinel = "spinel"
plat = platform
args = ARGV.dup
until args.empty?
  case args.shift
  when "--spinel" then spinel = args.shift
  when "--platform" then plat = args.shift
  else abort "usage: ruby tools/dist.rb [--spinel PATH] [--platform NAME]"
  end
end

windows = plat.start_with?("windows")
exe = windows ? ".exe" : ""
name = "egg-#{Egg::VERSION}-#{plat}"
out = File.join(ROOT, "dist", name)
FileUtils.rm_rf(out)
FileUtils.mkdir_p(File.join(out, "bin"))
FileUtils.mkdir_p(File.join(out, "lib"))

%w[eggc clutch].each do |tool|
  run(spinel, "bin/#{tool}", "-o", File.join(out, "bin", "#{tool}#{exe}"))
end
FileUtils.cp_r(File.join(ROOT, "lib", "std"), File.join(out, "lib", "std"))
FileUtils.cp_r(File.join(ROOT, "spec"), File.join(out, "spec"))
FileUtils.cp(File.join(ROOT, "README.md"), out)

# What it says about itself must be the release's version.
%w[eggc clutch].each do |tool|
  v, st = Open3.capture2(File.join(out, "bin", "#{tool}#{exe}"), "--version")
  abort "dist: #{tool} --version says #{v.inspect}, not #{tool} #{Egg::VERSION}" unless st.success? && v.strip == "#{tool} #{Egg::VERSION}"
end

archive = windows ? "#{name}.zip" : "#{name}.tar.gz"
Dir.chdir(File.join(ROOT, "dist")) do
  FileUtils.rm_f(archive)
  if windows
    run("zip", "-qr", archive, name, chdir: Dir.pwd)
  else
    run("tar", "-czf", archive, name, chdir: Dir.pwd)
  end
end
puts "dist/#{archive}"
