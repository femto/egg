# Test runner (no gems).
#
# examples/*.egg    -- compiled and run; "// expect: X" lines give stdout,
#                      "// panic: MSG" means the program must abort with MSG.
# test/errors/*.egg -- must fail to compile; "// error: CODE @LINE" lines
#                      list the diagnostics that must appear.
#                      Each example is also built in debug mode (-g, with
#                      #line directives) and must behave the same.
# spec/core.md      -- every ```egg block is a test of one of the kinds above
#                      ("// error: CODE" there needs no line), so the spec
#                      cannot drift from the compiler.
#
# Usage: ruby test/run.rb

require "open3"
require "tmpdir"
require_relative "../lib/egg"

ROOT = File.expand_path("..", __dir__)
CC = ENV["CC"] || "cc"
CFLAGS = ["-std=c99", "-Wall", "-Wextra", "-pedantic", "-Werror", "-O2"].freeze

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

# Compile, build and run a program; check its output or panic.
# With source_path, build in debug mode and also check the #line directives.
def check_program(name, src, dir, source_path = nil)
  result = Egg.compile_to_c(src, source_path)
  unless result.diagnostics.empty?
    return report(false, name, result.diagnostics.map { |d| d.to_text(name) }.join("\n"))
  end
  if source_path
    bad = bad_line_marks(result.c_source, src)
    return report(false, name, "#line marks missing or wrong on lines #{bad.inspect}") unless bad.empty?
  end
  base = File.join(dir, name.gsub(/[^A-Za-z0-9_.-]/, "_"))
  File.write("#{base}.c", result.c_source)
  flags = source_path ? CFLAGS - ["-O2"] + ["-g", "-O0"] : CFLAGS
  _, cc_err, cc_status = Open3.capture3(CC, *flags, "-o", base, "#{base}.c")
  return report(false, name, "C compiler failed:\n#{cc_err}") unless cc_status.success?
  out, err, status = Open3.capture3(base)
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

# Every line that starts code must get a #line mark, and nothing else may:
# returns the lines that differ. Lines of only "}" or "} else {" start
# nothing, and neither do continuation lines (after "," "(" or an operator).
def bad_line_marks(c_source, src)
  marked = c_source.scan(/^#line (\d+) /).map { |m| m[0].to_i }.uniq
  texts = src.lines.map { |l| l.sub(%r{//.*}, "").strip }
  code = []
  prev = ""
  texts.each_with_index do |text, i|
    next if text.empty?
    continued = prev.match?(/(,|\(|\band|\bor|[-+*\/%<>=!])\z/)
    code << i + 1 unless continued || text.match?(/\A\}( else \{)?\z/)
    prev = text
  end
  (marked - code) + (code - marked)
end

# Compile and require the listed diagnostics. "CODE @LINE" checks the line
# too; a bare "CODE" checks only the code.
def check_errors(name, src)
  want = comment_values(src, "error").map do |v|
    code, at = v.split(" @")
    [code, at&.to_i]
  end
  result = Egg.compile_to_c(src)
  got = result.diagnostics.map { |d| [d.code, d.line] }
  missing = want.reject do |code, line|
    got.any? { |c, l| c == code && (line.nil? || l == line) }
  end
  detail = "expected #{want.inspect}\ngot      #{result.diagnostics.map { |d| d.to_text(name) }.join("\n         ")}"
  report(!want.empty? && missing.empty?, name, detail)
end

Dir.mktmpdir do |dir|
  puts "examples"
  Dir[File.join(ROOT, "examples", "*.egg")].sort.each do |path|
    check_program(File.basename(path), File.read(path), dir)
    check_program("#{File.basename(path)} -g", File.read(path), dir, path)
  end

  puts "errors"
  Dir[File.join(ROOT, "test", "errors", "*.egg")].sort.each do |path|
    check_errors(File.basename(path), File.read(path))
  end

  puts "spec/core.md"
  spec = File.read(File.join(ROOT, "spec", "core.md"))
  section = "intro"
  block = nil
  block_line = 0
  spec.lines.each_with_index do |line, i|
    if block.nil?
      section = line.sub(/^#+\s*/, "").strip if line.start_with?("#")
      if line.strip == "```egg"
        block = +""
        block_line = i + 2
      end
    elsif line.strip == "```"
      name = "core.md:#{block_line} (#{section})"
      if comment_values(block, "error").empty?
        check_program(name, block, dir)
      else
        check_errors(name, block)
      end
      block = nil
    else
      block << line
    end
  end
end

puts
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
