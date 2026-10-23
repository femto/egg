# Test runner (no gems).
#
# examples/*.egg    -- compiled and run; "// expect: X" lines give stdout,
#                      "// panic: MSG" means the program must abort with MSG,
#                      "// fails: Name" means main must return error.Name.
# test/errors/*.egg -- must fail to compile; "// error: CODE @LINE" lines
#                      list the diagnostics that must appear.
#                      Each example is also built in debug mode (-g, with
#                      #line directives) and must behave the same.
# spec/core.md      -- every ```egg block is a test of one of the kinds above
#                      ("// error: CODE" there needs no line), so the spec
#                      cannot drift from the compiler.
# eggc lsp          -- the language server answers definition, hover,
#                      outline and diagnostics requests. EGGC=path tests
#                      another eggc, such as a Spinel-built one.
#
# Usage: ruby test/run.rb

require "json"
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
  fails = comment_values(src, "fails").first
  if panic
    ok = !status.success? && err.include?("egg panic: #{panic}")
    report(ok, name, "expected panic '#{panic}', got status #{status.exitstatus}, stderr: #{err}")
  elsif fails
    # main returned an error: exit status 1 and "error: Name" on stderr.
    want = comment_values(src, "expect")
    got = out.lines.map(&:chomp)
    ok = status.exitstatus == 1 && err.lines.map(&:chomp).include?("error: #{fails}") && got == want
    report(ok, name, "expected error.#{fails} after #{want.inspect}\ngot status #{status.exitstatus}, #{got.inspect}\n#{err}")
  else
    want = comment_values(src, "expect")
    got = out.lines.map(&:chomp)
    report(status.success? && got == want, name, "expected #{want.inspect}\ngot      #{got.inspect}\n#{err}")
  end
end

# Every line that starts code must get a #line mark, and nothing else may:
# returns the lines that differ. Lines of only "}" or "} else {" start
# nothing, and neither do continuation lines (after "," "(" "[" or an operator,
# or a `.field = value` line of a struct literal).
def bad_line_marks(c_source, src)
  marked = c_source.scan(/^#line (\d+) /).map { |m| m[0].to_i }.uniq
  texts = src.lines.map { |l| l.sub(%r{//.*}, "").strip }
  code = []
  prev = ""
  texts.each_with_index do |text, i|
    next if text.empty?
    # A line continues the previous one after "," "(" "[" or an operator, and
    # when it is a `.field = value` line of a multi-line struct literal.
    continued = prev.match?(/(,|\(|\[|\band|\bor|[-+*\/%<>=!])\z/) || text.match?(/\A\.\w+\s*=(?![=>])/)
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

# Run one LSP session against bin/eggc lsp; returns responses by id and
# the diagnostics notifications in order.
def lsp_session(messages)
  input = messages.map do |m|
    body = JSON.generate(m.merge("jsonrpc" => "2.0"))
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end.join
  out, err, status = Open3.capture3(ENV["EGGC"] || File.join(ROOT, "bin", "eggc"), "lsp", stdin_data: input)
  replies = {}
  diags = []
  out.split(/Content-Length: \d+\r\n\r\n/).reject(&:empty?).each do |text|
    msg = JSON.parse(text)
    if msg["method"] == "textDocument/publishDiagnostics"
      diags << msg["params"]["diagnostics"]
    else
      replies[msg["id"]] = msg
    end
  end
  [replies, diags, status, err]
end

# v1 syntax: types and methods in the outline, method and type navigation.
def check_lsp_v1
  uri = "file:///t/b.egg"
  src = <<~EGG
    const Point = struct {
        x: i64

        fn bump(inout self: Point) void {
            self.x = self.x + 1
        }
    }

    fn main() void {
        var p = Point{ .x = 1 }
        p.bump()
        for ([2]i64{ 1, 2 }) |v| {
            @print(v + p.x)
        }
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(10, 7) },  # p.bump()
    { "id" => 4, "method" => "textDocument/definition", "params" => at.(9, 13) },  # Point{
    { "id" => 5, "method" => "textDocument/definition", "params" => at.(12, 15) }, # v in the loop
    { "id" => 6, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, _, status, err = lsp_session(req)
  start = ->(id) { r = replies.dig(id, "result", "range", "start"); r && [r["line"], r["character"]] }
  names = (replies.dig(2, "result") || []).map { |x| x["name"] }
  report(names == %w[Point Point.bump main], "lsp v1 outline lists types and methods", names.inspect)
  report(start.(3) == [3, 7], "lsp v1 definition of a method", start.(3).inspect)
  report(start.(4) == [0, 6], "lsp v1 definition of a type from a literal", start.(4).inspect)
  report(start.(5) == [11, 26], "lsp v1 definition of a loop variable is its name", start.(5).inspect)
  report(status.success? && err.empty?, "lsp v1 session ends cleanly", err)
end

# Generics, annotations, switch payloads and symbol kinds.
def check_lsp_generics
  uri = "file:///t/c.egg"
  src = <<~EGG
    fn Pair(comptime T: type) type {
        return struct {
            a: T
            b: T

            fn swap(self: @This()) @This() {
                return @This(){ .a = self.b, .b = self.a }
            }
        }
    }

    const Shape = union(enum) { circle: i64, empty }

    fn area(s: Shape) i64 {
        switch (s) {
            .circle => |r| {
                return r * r
            }
            .empty => {
                return 0
            }
        }
    }

    fn main() void {
        const p = Pair(i64){ .a = 1, .b = 2 }
        const q: Pair(i64) = p.swap()
        @print(q.a + area(.empty))
        for ([2]i64{ 3, 4 }) |_, i| {
            @print(i)
        }
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(26, 28) }, # p.swap()
    { "id" => 4, "method" => "textDocument/definition", "params" => at.(25, 15) }, # Pair(i64){
    { "id" => 5, "method" => "textDocument/definition", "params" => at.(13, 11) }, # s: Shape
    { "id" => 6, "method" => "textDocument/definition", "params" => at.(26, 13) }, # q: Pair(i64)
    { "id" => 7, "method" => "textDocument/definition", "params" => at.(16, 19) }, # r in r * r
    { "id" => 8, "method" => "textDocument/definition", "params" => at.(29, 15) }, # i in @print(i)
    { "id" => 9, "method" => "textDocument/definition", "params" => at.(28, 26) }, # the _ binding
    { "id" => 10, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  start = ->(id) { r = replies.dig(id, "result", "range", "start"); r && [r["line"], r["character"]] }
  syms = (replies.dig(2, "result") || []).map { |x| [x["name"], x["kind"]] }
  report(diags.first == [], "lsp generics source has no errors", diags.first.inspect)
  report(syms == [["Pair", 12], ["Pair.swap", 6], ["Shape", 23], ["area", 12], ["main", 12]],
         "lsp outline kinds: functions, methods, types", syms.inspect)
  report(start.(3) == [5, 11], "lsp definition of a generic method", start.(3).inspect)
  report(start.(4) == [0, 3], "lsp definition from a generic literal", start.(4).inspect)
  report(start.(5) == [11, 6] && start.(6) == [0, 3], "lsp definition from type annotations", [start.(5), start.(6)].inspect)
  report(start.(7) == [15, 20], "lsp definition of a switch payload is its name", start.(7).inspect)
  report(start.(8) == [28, 29], "lsp definition of a loop index is its name", start.(8).inspect)
  report(replies.key?(9) && replies.dig(9, "result").nil?, "lsp '_' is not a variable", replies[9].inspect)
  report(status.success? && err.empty?, "lsp generics session ends cleanly", err)
end

def check_lsp
  uri = "file:///t/a.egg"
  src = <<~EGG
    fn add(a: i64, b: i64) i64 {
        return a + b
    }

    fn main() void {
        var total = 0
        total = add(total, 2)
        @print(total)
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  edit = ->(text) { { "method" => "textDocument/didChange", "params" => { "textDocument" => doc, "contentChanges" => [{ "text" => text }] } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/definition", "params" => at.(6, 13) },  # add( in main
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(7, 11) },  # total in @print
    { "id" => 4, "method" => "textDocument/definition", "params" => at.(6, 4) },   # total = ...
    { "id" => 5, "method" => "textDocument/definition", "params" => at.(1, 11) },  # a in add
    { "id" => 6, "method" => "textDocument/definition", "params" => at.(7, 6) },   # @print: nothing
    { "id" => 7, "method" => "textDocument/hover", "params" => at.(6, 12) },
    { "id" => 8, "method" => "textDocument/hover", "params" => at.(5, 8) },
    { "id" => 9, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    edit.(src.sub("add(total, 2)", "add(totl, 2)")),
    edit.(src.sub("return a + b", "return a +")),
    { "id" => 10, "method" => "textDocument/definition", "params" => at.(6, 13) }, # last good version
    { "id" => 11, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  result = ->(id) { replies.dig(id, "result") }
  start = ->(id) { result.(id) && result.(id)["range"]["start"].values_at("line", "character") }
  hover = ->(id) { result.(id) && result.(id)["contents"]["value"].lines[1].to_s.strip }
  report(result.(1)&.dig("capabilities", "definitionProvider") == true, "lsp initialize")
  report(start.(2) == [0, 3], "lsp definition of a function", start.(2).inspect)
  report(start.(3) == [5, 8] && start.(4) == [5, 8], "lsp definition of a local", [start.(3), start.(4)].inspect)
  report(start.(5) == [0, 7], "lsp definition of a parameter", start.(5).inspect)
  report(replies.key?(6) && result.(6).nil?, "lsp definition on a builtin is empty", replies[6].inspect)
  report(hover.(7) == "fn add(a: i64, b: i64) i64" && hover.(8) == "var total: i64", "lsp hover", [hover.(7), hover.(8)].inspect)
  names = (result.(9) || []).map { |sym| sym["name"] }
  report(names == %w[add main], "lsp document symbols", names.inspect)
  codes = diags.map { |ds| ds.map { |d| d["code"] } }
  report(codes == [[], ["E101"], ["E002"]], "lsp diagnostics follow edits", codes.inspect)
  e101 = diags[1] && diags[1][0] && diags[1][0]["range"]
  report(e101 == { "start" => { "line" => 6, "character" => 16 }, "end" => { "line" => 6, "character" => 20 } },
         "lsp diagnostic range covers the token", e101.inspect)
  report(start.(10) == [0, 3], "lsp navigation survives a syntax error", start.(10).inspect)
  report(status.success? && err.empty?, "lsp shutdown and exit", "status #{status.exitstatus}, stderr: #{err}")
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

  puts "lsp"
  check_lsp
  check_lsp_generics
  check_lsp_v1

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
