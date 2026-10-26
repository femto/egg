# Benchmarks: the same programs in Egg, C, Rust, Go, Zig, Python and Ruby.
#
# Each program is built with every toolchain found on PATH, run once to
# warm up and then RUNS times, timed by wall clock; the table shows the fastest run of each, and how
# many times slower than C it is. All versions of a program must print the
# same output (stdout and stderr together: Zig prints with std.debug.print).
#
#   c          cc -O2, no checks: the baseline
#   egg        eggc build (C with overflow and bounds checks, cc -O2)
#   rust       rustc -O: bounds checks, overflow wraps
#   rust+ovf   rustc -O -C overflow-checks=on: both checked, like Egg
#   go         go build: bounds checks, overflow wraps
#   zig-safe   zig -O ReleaseSafe: both checked, like Egg
#
# With --slow, also the interpreters, which take minutes: run once each,
# without a warm-up run.
#
#   python     python3 (CPython)
#   pypy       pypy (a JIT)
#   ruby       ruby (CRuby)
#
# Usage: ruby bench/run.rb [NAME...] [--runs N] [--slow]

require "open3"

BENCH = __dir__
ROOT = File.expand_path("..", BENCH)
OUT = File.join(BENCH, "build")
CC = ENV["CC"] || "cc"

args = ARGV.dup
runs = 5
if (i = args.index("--runs"))
  runs = Integer(args[i + 1])
  abort "--runs must be at least 1" if runs < 1
  args.slice!(i, 2)
end
slow = !args.delete("--slow").nil?
names = args.empty? ? Dir[File.join(BENCH, "egg", "*.egg")].map { |f| File.basename(f, ".egg") }.sort : args

# [label, tool, source dir, extension, build command; for an interpreter,
# the command that runs the source instead]
VARIANTS = [
  ["c", CC, "c", "c", ->(src, exe) { [CC, "-std=c99", "-O2", "-o", exe, src] }],
  ["egg", "ruby", "egg", "egg", ->(src, exe) { ["ruby", File.join(ROOT, "bin", "eggc"), "build", src, "-o", exe] }],
  ["rust", "rustc", "rust", "rs", ->(src, exe) { ["rustc", "-O", "-o", exe, src] }],
  ["rust+ovf", "rustc", "rust", "rs", ->(src, exe) { ["rustc", "-O", "-C", "overflow-checks=on", "-o", exe, src] }],
  ["go", "go", "go", "go", ->(src, exe) { ["go", "build", "-o", exe, src] }],
  ["zig-safe", "zig", "zig", "zig", ->(src, exe) { ["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "-femit-bin=#{exe}", src] }],
].freeze

INTERPRETERS = [
  ["python", "python3", "python", "py", ->(src) { ["python3", src] }],
  ["pypy", "pypy", "python", "py", ->(src) { ["pypy", src] }],
  ["ruby", "ruby", "ruby", "rb", ->(src) { ["ruby", src] }],
].freeze

def on_path?(tool)
  return File.executable?(tool) if tool.include?(File::SEPARATOR) # CC=/usr/bin/clang
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, tool)) }
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

variants = (slow ? VARIANTS + INTERPRETERS : VARIANTS).select do |label, tool|
  on_path?(tool) || (warn("skipping #{label}: #{tool} not found"); false)
end

Dir.mkdir(OUT) unless Dir.exist?(OUT)
results = {} # name -> label -> seconds (nil: failed)
failed = false

names.each do |name|
  results[name] = {}
  expected = nil
  variants.each do |label, _, dir, ext, build|
    src = File.join(BENCH, dir, "#{name}.#{ext}")
    unless File.exist?(src)
      warn "#{name}/#{label}: #{src} not found"
      failed = true
      next
    end
    interpreted = INTERPRETERS.any? { |v| v[0] == label }
    if interpreted
      cmd = build.(src)
      n = 1
    else
      exe = File.join(OUT, "#{name}-#{label}")
      out, ok = Open3.capture2e(*build.(src, exe))
      unless ok.success?
        warn "#{name}/#{label}: build failed\n#{out}"
        failed = true
        next
      end
      cmd = [exe]
      n = runs
      # One untimed run first: macOS scans a new executable the first time
      # it starts, which can add hundreds of milliseconds.
      Open3.capture2e(exe)
    end
    best = nil
    n.times do
      t = now
      out, ok = Open3.capture2e(*cmd)
      dt = now - t
      unless ok.success?
        warn "#{name}/#{label}: exited with #{ok.exitstatus}\n#{out}"
        failed = true
        break
      end
      expected ||= out
      if out != expected
        warn "#{name}/#{label}: printed #{out.inspect}, expected #{expected.inspect}"
        failed = true
        break
      end
      best = dt if best.nil? || dt < best
    end
    results[name][label] = best
    $stderr.print "."
  end
end
$stderr.puts

labels = variants.map(&:first)
puts "| program | " + labels.join(" | ") + " |"
puts "| --- |" + " ---: |" * labels.length
results.each do |name, times|
  base = times["c"]
  cells = labels.map do |l|
    t = times[l]
    next "—" if t.nil?
    ms = format("%.0f ms", t * 1000)
    next ms if base.nil? || l == "c"
    r = t / base
    format(r >= 10 ? "%s (%.0fx)" : "%s (%.2fx)", ms, r)
  end
  puts "| #{name} | " + cells.join(" | ") + " |"
end
puts
puts "best of #{runs} runs#{slow ? " (interpreters: 1 run)" : ""}; (Nx) = time relative to c"
exit(failed ? 1 : 0)
