# Test runner (no gems).
#
# examples/*.egg  -- compiled and run; "// expect: X" lines give stdout,
#                    "// panic: MSG" means the program must abort with MSG.
# test/errors/*.egg -- must fail to compile; "// error: CODE @LINE" lines
#                    list the diagnostics that must appear.
#
# Usage: ruby test/run.rb

require "open3"
require "tmpdir"
require_relative "../lib/egg"

ROOT = File.expand_path("..", __dir__)
CC = ENV["CC"] || "cc"

$pass = 0
$fail = 0

def report(ok, name, detail = nil)
  if ok
    $pass += 1
    puts "  ok    #{name}"
  else
    $fail += 1
    puts "  FAIL  #{name}"
    puts detail.gsub(/^/, "        ") if detail
  end
end

def comment_values(src, key)
  src.lines.filter_map { |l| l[%r{^\s*//\s*#{key}:\s*(.*)$}, 1]&.strip }
end

puts "examples"
Dir.mktmpdir do |dir|
  Dir[File.join(ROOT, "examples", "*.egg")].sort.each do |path|
    name = File.basename(path)
    src = File.read(path)
    result = Egg.compile_to_c(src)
    unless result.diagnostics.empty?
      report(false, name, result.diagnostics.map { |d| d.to_text(name) }.join("\n"))
      next
    end
    c_path = File.join(dir, "#{name}.c")
    exe = File.join(dir, name)
    File.write(c_path, result.c_source)
    _, cc_err, cc_status = Open3.capture3(CC, "-std=c99", "-Wall", "-Wextra", "-pedantic", "-Werror", "-O2", "-o", exe, c_path)
    unless cc_status.success?
      report(false, name, "C compiler failed:\n#{cc_err}")
      next
    end
    out, err, status = Open3.capture3(exe)
    panic = comment_values(src, "panic").first
    if panic
      ok = !status.success? && err.include?("egg panic: #{panic}")
      report(ok, name, "expected panic '#{panic}', got status #{status.exitstatus}, stderr: #{err}")
    else
      want = comment_values(src, "expect")
      got = out.lines.map(&:chomp)
      report(status.success? && got == want, name, "expected #{want.inspect}\ngot      #{got.inspect}\n#{err}")
    end
  end
end

puts "errors"
Dir[File.join(ROOT, "test", "errors", "*.egg")].sort.each do |path|
  name = File.basename(path)
  src = File.read(path)
  want = comment_values(src, "error").map do |v|
    code, at = v.split(" @")
    [code, at.to_i]
  end
  result = Egg.compile_to_c(src)
  got = result.diagnostics.map { |d| [d.code, d.line] }
  missing = want - got
  detail = "expected #{want.inspect}\ngot      #{result.diagnostics.map { |d| d.to_text(name) }.join("\n         ")}"
  report(!want.empty? && missing.empty?, name, detail)
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
