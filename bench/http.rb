# The HTTP example against the same design in other languages, and against
# the usual servers of Go and Node. Needs wrk.
#
#   egg, c, rust, go-pool, python   8 threads on a queue of 16, a logger
#                                   thread, up to 100 requests per connection
#   go-net/http, node               their standard servers, no such limits
#
# Every server reads the file for each request. wrk runs on the same machine,
# over loopback, so the numbers compare servers and are not their ceilings.
#
# Usage: ruby bench/http.rb [--runs N] [--seconds N] [NAME...]

require "fileutils"
require "open3"
require "socket"

BENCH = __dir__
ROOT = File.expand_path("..", BENCH)
HTTP = File.join(BENCH, "http")
OUT = File.join(BENCH, "build", "http")
CC = ENV["CC"] || "cc"

args = ARGV.dup
take = lambda do |flag, default|
  i = args.index(flag)
  next default if i.nil?
  v = Integer(args[i + 1])
  args.slice!(i, 2)
  v
end
runs = take.("--runs", 3)
seconds = take.("--seconds", 5)
abort "--runs and --seconds must be at least 1" if runs < 1 || seconds < 1

abort "bench/http.rb needs wrk" unless system("command -v wrk >/dev/null")
FileUtils.mkdir_p(File.join(OUT, "www"))
File.binwrite(File.join(OUT, "www", "index.html"), "<h1>egg</h1>")
srand(1)
{ "10k.bin" => 10_240, "1m.bin" => 1_048_576 }.each do |name, size|
  File.binwrite(File.join(OUT, "www", name), Random.bytes(size))
end

def build(*cmd)
  out, status = Open3.capture2e(*cmd)
  abort "#{cmd.join(' ')}\n#{out}" unless status.success?
end

def has?(tool) = system("command -v #{tool} >/dev/null")

exe = ->(name) { [File.join(OUT, name)] }
SERVERS = {
  "egg" => lambda {
    build("ruby", File.join(ROOT, "bin", "eggc"), "build", File.join(ROOT, "examples", "http_server", "server.egg"), "-o", File.join(OUT, "egg"))
    exe.("egg")
  },
  "c" => lambda {
    build(CC, "-O2", "-o", File.join(OUT, "c"), File.join(HTTP, "server.c"), "-lpthread")
    exe.("c")
  },
  "rust" => lambda {
    next nil unless has?("rustc")
    build("rustc", "-O", "-o", File.join(OUT, "rust"), File.join(HTTP, "server.rs"))
    exe.("rust")
  },
  "go-pool" => lambda {
    next nil unless has?("go")
    build("go", "build", "-o", File.join(OUT, "go-pool"), File.join(HTTP, "pool.go"))
    exe.("go-pool")
  },
  "go-net/http" => lambda {
    next nil unless has?("go")
    build("go", "build", "-o", File.join(OUT, "go-nethttp"), File.join(HTTP, "nethttp.go"))
    exe.("go-nethttp")
  },
  "node" => -> { has?("node") ? ["node", File.join(HTTP, "server.js")] : nil },
  "python" => -> { has?("python3") ? ["python3", File.join(HTTP, "server.py")] : nil },
}.freeze

TESTS = [[8, "/index.html"], [64, "/index.html"], [8, "/10k.bin"], [8, "/1m.bin"]].freeze

def seconds_of(text)
  n = text.to_f
  case text
  when /us$/ then n / 1000
  when /ms$/ then n
  when /m$/ then n * 60_000
  else n * 1000
  end
end

def wrk(port, conns, path, seconds)
  threads = conns > 8 ? 4 : 2
  out, status = Open3.capture2e("wrk", "-t#{threads}", "-c#{conns}", "-d#{seconds}s", "--latency", "http://127.0.0.1:#{port}#{path}")
  abort "wrk failed:\n#{out}" unless status.success? && out.match?(%r{Requests/sec:})
  { rps: out[%r{Requests/sec:\s+([\d.]+)}, 1].to_f,
    p50: seconds_of(out[/^\s+50%\s+(\S+)/, 1].to_s),
    p99: seconds_of(out[/^\s+99%\s+(\S+)/, 1].to_s),
    errors: out.scan(/(?:read|write|connect|timeout) (\d+)/).flatten.sum(&:to_i),
    bad: out[/Non-2xx or 3xx responses: (\d+)/, 1].to_i }
end

def wait_for(pid, port)
  100.times do
    return false unless Process.wait(pid, Process::WNOHANG).nil?
    TCPSocket.new("127.0.0.1", port).close
    return true
  rescue SystemCallError
    sleep 0.1
  end
  false
end

results = {}
port = 19_000
(args.empty? ? SERVERS.keys : args).each do |name|
  cmd = SERVERS.fetch(name).call
  next warn("#{name}: skipped") if cmd.nil?
  port += 1
  pid = spawn(*cmd, File.join(OUT, "www"), port.to_s, out: File::NULL, err: File::NULL)
  begin
    unless wait_for(pid, port)
      pid = nil
      abort "#{name} did not start"
    end
    TESTS.each do |conns, path|
      samples = (1..runs).map do
        r = wrk(port, conns, path, seconds)
        sleep 2
        r
      end
      mid = samples.sort_by { |s| s[:rps] }[samples.length / 2]
      results[[name, conns, path]] = mid
      warn format("%-12s c=%-3d %-12s %9.0f rps  p50 %8.2f ms  p99 %8.2f ms  errors %d  non-2xx %d", name, conns, path, mid[:rps], mid[:p50], mid[:p99], mid[:errors], mid[:bad])
    end
  ensure
    unless pid.nil?
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end
  sleep 3
end

names = results.keys.map(&:first).uniq
puts "| server | #{TESTS.map { |c, p| "#{p} c=#{c}" }.join(' | ')} |"
puts "| --- |#{' ---: |' * TESTS.length}"
names.each do |n|
  cells = TESTS.map { |c, p| r = results[[n, c, p]]; format("%.0f (p99 %.1f ms)", r[:rps], r[:p99]) }
  puts "| #{n} | #{cells.join(' | ')} |"
end
