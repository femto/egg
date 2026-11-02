# Builds what codspeed.yaml runs, into bench/build/codspeed/:
#
# - the benchmark programs (bench/codspeed/*.egg), with eggc
# - the HTTP servers of bench/http/ (egg, c, rust, go-pool, go-nethttp; node
#   and python run from source), the load client http_load.c and the www/
#   directory they serve
#
# Usage: ruby bench/codspeed/build.rb

require "fileutils"
require "open3"

HERE = __dir__
ROOT = File.expand_path("../..", HERE)
HTTP = File.join(ROOT, "bench", "http")
OUT = File.join(ROOT, "bench", "build", "codspeed")
EGGC = File.join(ROOT, "bin", "eggc")
CC = ENV["CC"] || "cc"

FileUtils.mkdir_p(OUT)

$failed = false
def build(what, *cmd, env: {})
  log, status = Open3.capture2e(env, *cmd)
  if status.success?
    puts "built #{what}"
  else
    warn "#{what}: build failed\n#{cmd.join(' ')}\n#{log}"
    $failed = true
  end
rescue SystemCallError => e
  warn "#{what}: build failed: #{e.message}"
  $failed = true
end

def out(name)
  File.join(OUT, name)
end

Dir[File.join(HERE, "*.egg")].sort.each do |src|
  exe = out(File.basename(src, ".egg"))
  build(exe, "ruby", EGGC, "build", src, "-o", exe)
end

# The HTTP benchmarks.
FileUtils.mkdir_p(out("www"))
File.binwrite(out("www/index.html"), "<h1>egg</h1>")
srand(1)
File.binwrite(out("www/10k.bin"), Random.bytes(10_240))

build(out("http_load"), CC, "-O2", "-o", out("http_load"), File.join(HERE, "http_load.c"))
build(out("http-egg"), "ruby", EGGC, "build", File.join(ROOT, "examples", "http_server", "server.egg"), "-o", out("http-egg"))
build(out("http-c"), CC, "-O2", "-o", out("http-c"), File.join(HTTP, "server.c"), "-lpthread")
build(out("http-rust"), "rustc", "-O", "-o", out("http-rust"), File.join(HTTP, "server.rs"))
# Without cgo: the Go runtime's cgo start-up does not run under valgrind,
# which CodSpeed's simulation uses.
no_cgo = { "CGO_ENABLED" => "0" }
build(out("http-go-pool"), "go", "build", "-o", out("http-go-pool"), File.join(HTTP, "pool.go"), env: no_cgo)
build(out("http-go-nethttp"), "go", "build", "-o", out("http-go-nethttp"), File.join(HTTP, "nethttp.go"), env: no_cgo)

exit($failed ? 1 : 0)
