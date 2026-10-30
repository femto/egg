# Test runner (no gems).
#
# examples/*.egg    -- compiled and run; "// expect: X" lines give stdout,
#                      "// panic: MSG" means the program must abort with MSG,
#                      "// fails: Name" means main must return error.Name.
# test/errors/*.egg -- must fail to compile; "// error: CODE @LINE" lines
#                      list the diagnostics that must appear
#                      ("CODE @lib/m.egg:LINE" for one in an imported file).
#                      Imported files live in subdirectories, which are
#                      not run themselves.
#                      Each example is also built in debug mode (-g, with
#                      #line directives) and must behave the same.
# spec/core.md      -- every ```egg block is a test of one of the kinds above
#                      ("// error: CODE" there needs no line), so the spec
#                      cannot drift from the compiler.
# examples/complex/ -- larger programs (a parser, Dijkstra, a VM, ...),
#                      run like examples/*.egg.
# examples/ffi/*/   -- programs (files with "// expect:") calling C
#                      libraries; skipped when a library they link is not
#                      installed.
# test/link/        -- `link` and eggc's -l/-L against a C library built
#                      here (linktest.c).
# eggc lsp          -- the language server answers definition, hover,
#                      outline and diagnostics requests. EGGC=path tests
#                      another eggc, such as a Spinel-built one.
#
# Usage: ruby test/run.rb

require "json"
require "rbconfig"
require "open3"
require "timeout"
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

# The text after "// key: "; only the one space after the colon goes, so
# "// expect:   x" expects "  x". A test may hold bytes that are not
# UTF-8 (to check that eggc rejects them), so those are scrubbed here.
def comment_values(src, key)
  src.scrub.lines.filter_map { |l| l[%r{^\s*//\s*#{key}: ?(.*)$}, 1]&.rstrip }
end

# Compile, build and run a program; check its output or panic.
# path: the file, so imports resolve (nil for a spec block). With debug,
# build in debug mode and also check the #line directives. lib_dirs: where
# the C compiler looks for the libraries the program links.
def check_program(name, src, dir, path = nil, debug: false, lib_dirs: [])
  result = Egg.compile_to_c(src, path, debug: debug)
  unless result.diagnostics.empty?
    return report(false, name, result.diagnostics.map { |d| d.to_text(name) }.join("\n"))
  end
  if debug
    bad = bad_line_marks(result.c_source, src, File.expand_path(path))
    return report(false, name, "#line marks missing or wrong on lines #{bad.inspect}") unless bad.empty?
  end
  base = File.join(dir, name.gsub(/[^A-Za-z0-9_.-]/, "_"))
  File.write("#{base}.c", result.c_source)
  # The debug build also tests the portable overflow checks, which gcc
  # and clang otherwise replace with their builtins.
  flags = debug ? CFLAGS - ["-O2"] + ["-g", "-O0", "-DEGG_PORTABLE"] : CFLAGS
  links = lib_dirs.map { |d| "-L#{d}" } + result.links.map { |l| "-l#{l}" }
  _, cc_err, cc_status = Open3.capture3(CC, *flags, "-o", base, "#{base}.c", *links)
  return report(false, name, "C compiler failed:\n#{cc_err}") unless cc_status.success?
  # In its scratch directory: a program may leave files behind.
  out, err, status = Open3.capture3(File.expand_path(base), chdir: dir)
  panic = comment_values(src, "panic").first
  fails = comment_values(src, "fails").first
  if panic
    # Output printed before the panic must survive it.
    want = comment_values(src, "expect")
    got = out.lines.map(&:chomp)
    ok = !status.success? && err.include?("egg panic: #{panic}") && got == want
    report(ok, name, "expected panic '#{panic}' after #{want.inspect}\ngot status #{status.exitstatus}, #{got.inspect}, stderr: #{err}")
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

# Every line of the file at path that starts code must get a #line mark,
# and nothing else may: returns the lines that differ. (Marks for imported
# files are not checked here.) Lines of only "}" or "} else {" start
# nothing, and neither do continuation lines (after "," "(" "[" or an operator,
# or a `.field = value` line of a struct literal).
def bad_line_marks(c_source, src, path)
  marked = c_source.scan(/^#line (\d+) "(.*)"$/).select { |_, f| f == path }.map { |m| m[0].to_i }.uniq
  texts = src.lines.map { |l| l.sub(%r{//.*}, "").strip }
  code = []
  prev = ""
  texts.each_with_index do |text, i|
    next if text.empty?
    # A line continues the previous one after "," "(" "[" or an operator, and
    # when it is a `.field = value` line of a multi-line struct literal.
    continued = prev.match?(/(,|\(|\[|\band|\bor|[-+*\/%<>=!])\z/) || text.match?(/\A\.\w+\s*=(?![=>])/)
    # An if with a value split over lines: its branches and its else.
    # (String literals are blanked first, so a " else " in one does not count.)
    bare = prev.gsub(/"(?:\\.|[^"\\])*"/, '""')
    continued ||= (bare.match?(/\bif \(.*\)\z/) && !bare.include?(" else ")) || prev == "else" || text == "else" || text.start_with?("else if (")
    # `uses`, `allow`, `@import`, `extern fn` and type alias lines declare,
    # and generate no code (an extern fn only a prototype). Only a const at
    # the top level, not indented, can be an alias.
    declares = text.match?(/\A(uses|allow|extern|link)\s/) || src.lines[i].match?(/\Aconst \w+ = (?!(owned )?struct\b|enum\b|union\b)/)
    # An else-if comparing types (K == i64) is decided at compile time, and
    # @compileError stands only in a branch that is never generated.
    # The right side must name a type, so a runtime `x == y` is not taken
    # for one.
    ty = /(?:[A-Z]\w*|[iuf]\d+|usize|str|bool|anyerror|void)\b/
    comptime = text.match?(/\A\} else if \((\s*!?\s*\w+\s*[!=]=\s*#{ty}\s*(and|or)?)+\s*\) \{\z/) || text.start_with?("@compileError(")
    code << i + 1 unless continued || declares || comptime || text.match?(/\A\}( else \{)?\z/)
    prev = text
  end
  (marked - code) + (code - marked)
end

# Compile and require the listed diagnostics. "CODE @LINE" checks the line
# too; a bare "CODE" checks only the code.
def check_errors(name, src, path = nil)
  want = comment_values(src, "error").map do |v|
    code, at = v.split(" @")
    file, line = at.nil? ? [nil, nil] : (at.include?(":") ? at.split(":") : [nil, at])
    [code, file, line&.to_i]
  end
  result = Egg.compile_to_c(src, path)
  missing = want.reject do |code, file, line|
    result.diagnostics.any? do |d|
      same_file = file.nil? ? d.file.nil? : !d.file.nil? && d.file.end_with?(file)
      d.code == code && (line.nil? || (d.line == line && same_file))
    end
  end
  detail = "expected #{want.inspect}\ngot      #{result.diagnostics.map { |d| d.to_text(name) }.join("\n         ")}"
  report(!want.empty? && missing.empty?, name, detail)
end

# bin/eggc as a command. EGGC names a native build; a script runs through
# Ruby, since Windows has no #! lines.
def eggc_command
  ENV["EGGC"] ? [ENV["EGGC"]] : [RbConfig.ruby, File.join(ROOT, "bin", "eggc")]
end

# Run one LSP session against bin/eggc lsp; returns responses by id and
# the diagnostics notifications in order.
def lsp_session(messages)
  input = messages.map do |m|
    body = JSON.generate(m.merge("jsonrpc" => "2.0"))
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end.join
  out, err, status = Open3.capture3(*eggc_command, "lsp", stdin_data: input, binmode: true)
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

# A diagnostic on a character literal underlines all of it: '\xff' is six
# characters of source, though its token is the integer 255.
def check_lsp_char
  uri = "file:///t/ch.egg"
  src = "fn main() void {\n    const x: i8 = '\\xff'\n}\n"
  doc = { "uri" => uri }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 5, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  _, diags, status, err = lsp_session(req)
  r = diags.first&.find { |d| d["code"] == "E003" }&.dig("range")
  span = r && [r["start"]["character"], r["end"]["character"]]
  report(span == [18, 24], "lsp diagnostic range covers a character literal", diags.inspect)
  report(status.success? && err.empty?, "lsp char session ends cleanly", err)
end

# catch |e|: the error's name is declared for the fallback.
def check_lsp_catch
  uri = "file:///t/c.egg"
  src = <<~EGG
    uses io

    fn f() !i64 { return error.Bad }

    fn main(out: Io) void {
        const v = f() catch |e| {
            out.print(@errorName(e))
            return
        }
        out.print(v)
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/definition", "params" => at.(6, 29) },  # e in @errorName(e)
    { "id" => 3, "method" => "textDocument/hover", "params" => at.(6, 29) },
    { "id" => 5, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  start = ->(id) { r = replies.dig(id, "result", "range", "start"); r && [r["line"], r["character"]] }
  hover = replies.dig(3, "result", "contents", "value").to_s
  report(diags.first == [], "lsp catch source has no errors", diags.first.inspect)
  report(start.(2) == [5, 25], "lsp definition of a catch capture is its name", start.(2).inspect)
  report(hover.include?("anyerror"), "lsp hover on a catch capture shows anyerror", hover)
  report(status.success? && err.empty?, "lsp catch session ends cleanly", err)
end

# v1 syntax: types and methods in the outline, method and type navigation.
# Fs errors a program cannot set up by itself. As root permissions do not
# apply, and /dev/full is only on some systems.
def check_fs_errors(dir)
  work = File.join(dir, "fs_errors")
  FileUtils.mkdir_p(work)
  locked = File.join(work, "locked.txt")
  File.write(locked, "secret")
  File.chmod(0o000, locked)
  keep = File.join(work, "keep.txt")
  File.write(keep, "keep")
  File.chmod(0o444, keep)
  begin
    if File.readable?(locked)
      puts "  skip  fs permission errors (the file is readable anyway)"
    else
      check_program("fs_permission", <<~EGG, work)
        // expect: PermissionDenied
        // expect: PermissionDenied
        uses alloc, fs, io

        fn main(out: Io, files: Fs, a: Allocator) void {
            const b = files.read(a, "locked.txt") catch |e| {
                out.print(@errorName(e))
                files.write("keep.txt", "new") catch |e2| {
                    out.print(@errorName(e2))
                }
                return
            }
            a.free(b)
        }
      EGG
      report(File.read(keep) == "keep", "a refused fs.write leaves the file as it was", File.read(keep))
    end
  ensure
    File.chmod(0o644, locked, keep)
  end
  unless File.exist?("/dev/full")
    puts "  skip  fs.write reports a full disk (no /dev/full)"
    return
  end
  check_program("fs_full_disk", <<~EGG, work)
    // expect: IoFailed
    uses fs, io

    fn main(out: Io, files: Fs) void {
        files.write("/dev/full", "data") catch |e| {
            out.print(@errorName(e))
        }
    }
  EGG
end

# What a program sees on its command line, and the order of its two output
# streams: eprint must not overtake what print wrote before it.
def check_args(dir)
  src = <<~EGG
    uses args, io

    fn main(out: Io, args: Args) void {
        var i = 1
        while (i < args.len()) {
            out.print("[", args.get(i), "]")
            i = i + 1
        }
        out.eprint("to stderr ", args.len())
        if (@len(args.get(0)) == 0) {
            out.print("no name")
        }
        out.print("after")
    }
  EGG
  path = File.join(dir, "args_run.egg")
  File.write(path, src)
  out, err, status = Open3.capture3(*eggc_command, "run", path, "--", "-g", "a b", "", "--")
  got = out.lines.map(&:chomp)
  ok = status.success? && got == ["[-g]", "[a b]", "[]", "[--]", "after"] && err.lines.map(&:chomp) == ["to stderr 5"]
  report(ok, "eggc run passes what follows -- to the program", "status #{status.exitstatus}, #{got.inspect}, stderr: #{err}")
  out, status = Open3.capture2e(*eggc_command, "run", path)
  got = out.lines.map(&:chomp)
  report(status.success? && got == ["to stderr 1", "after"], "eprint with no arguments", got.inspect)
  order = File.join(dir, "args_order.egg")
  File.write(order, <<~EGG)
    uses io

    fn main(out: Io) void {
        out.print("first")
        out.eprint("second")
        out.print("third")
    }
  EGG
  out, status = Open3.capture2e(*eggc_command, "run", order)
  got = out.lines.map(&:chomp)
  report(status.success? && got == %w[first second third], "eprint comes after what was printed", got.inspect)
  _, _, status = Open3.capture3(*eggc_command, "check", path, "--", "x")
  report(status.exitstatus == 2, "only eggc run takes program arguments", "status #{status.exitstatus}")
end

# Standard input: line endings, a last line with none, empty lines, bytes
# text mode would change, and a prompt that must show before the read.
def check_stdin(dir)
  lines = File.join(dir, "stdin_lines.egg")
  File.write(lines, <<~EGG)
    uses alloc, io

    fn main(out: Io, a: Allocator) !void {
        var line: Buf(u8) = .empty
        defer a.free(line)
        while (try out.read_line(a, &line)) {
            out.print("[", line, "]")
        }
        out.print("end ", @len(line))
    }
  EGG
  [["one\ntwo\n", %w[[one] [two] end\ 0]],
   ["one\r\n\r\nlast", ["[one]", "[]", "[last]", "end 0"]],
   ["\n", ["[]", "end 0"]],
   ["", ["end 0"]],
   ["a\rb\n", ["[a\rb]", "end 0"]]].each do |input, want|
    out, err, status = Open3.capture3(*eggc_command, "run", lines, stdin_data: input, binmode: true)
    got = out.gsub("\r\n", "\n").lines.map(&:chomp)
    report(status.success? && got == want, "read_line of #{input.inspect}", "#{got.inspect}, stderr: #{err}")
  end

  all = File.join(dir, "stdin_all.egg")
  File.write(all, <<~EGG)
    uses alloc, io

    fn main(out: Io, a: Allocator) !void {
        const data = try out.read_all(a)
        defer a.free(data)
        var sum = 0
        for (data) |b| {
            sum = sum + @as(i64, b)
        }
        out.print(@len(data), " ", sum)
    }
  EGG
  # Long enough to grow the buffer; \r\n and Ctrl-Z change in text mode.
  bytes = ([13, 10, 0, 26, 255] * 2000).pack("C*")
  out, err, status = Open3.capture3(*eggc_command, "run", all, stdin_data: bytes, binmode: true)
  want = "#{bytes.bytesize} #{bytes.bytes.sum}"
  report(status.success? && out.strip == want, "read_all keeps the bytes as they are", "#{out.inspect}, stderr: #{err}")

  prompt = File.join(dir, "stdin_prompt.egg")
  File.write(prompt, <<~EGG)
    uses alloc, io

    fn main(out: Io, a: Allocator) !void {
        out.print("name?")
        var line: Buf(u8) = .empty
        defer a.free(line)
        if (try out.read_line(a, &line)) {
            out.print("hello ", line)
        }
    }
  EGG
  Open3.popen2(*eggc_command, "run", prompt) do |stdin, stdout, thread|
    # Without the flush the prompt would wait in the buffer, and so would we.
    shown = Timeout.timeout(60) { stdout.gets }
    stdin.puts("egg")
    stdin.close
    report(shown&.chomp == "name?" && stdout.gets&.chomp == "hello egg" && thread.value.success?, "a prompt shows before the read", shown.inspect)
  rescue Timeout::Error
    Process.kill("KILL", thread.pid)
    report(false, "a prompt shows before the read", "timed out")
  end

  if Gem.win_platform?
    puts "  skip  a failed read of standard input (no closed descriptor)"
    return
  end
  exe = File.join(dir, "stdin_closed")
  _, status = Open3.capture2e(*eggc_command, "build", all, "-o", exe)
  return report(false, "build stdin_closed", "failed") unless status.success?
  out_path = "#{exe}.out"
  pid = spawn(exe, in: :close, out: out_path, err: out_path)
  Process.wait(pid)
  report($?.exitstatus == 1 && File.read(out_path).include?("error: IoFailed"), "reading a closed standard input is IoFailed", File.read(out_path))
end

def check_lsp_alias
  uri = "file:///t/a.egg"
  src = <<~EGG
    const Op = fn(i64, Buf(u8)) ?i64
    const Id = i64

    fn main() Id {
        return 0
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/definition", "params" => at.(3, 10) },  # Id in main's result
    { "id" => 3, "method" => "textDocument/hover", "params" => at.(3, 10) },
    { "id" => 4, "method" => "textDocument/hover", "params" => at.(0, 6) },
    { "id" => 5, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 6, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  hover = ->(id) { replies.dig(id, "result", "contents", "value").to_s }
  op = replies[5]["result"].find { |s| s["name"] == "Op" }
  range = op&.dig("range", "end")
  report(diags.first == [], "lsp alias source has no errors", diags.first.inspect)
  report(replies.dig(2, "result", "range", "start", "line") == 1, "lsp definition of a type alias", replies[2].inspect)
  report(hover.(3).include?("const Id = i64"), "lsp hover on a type alias", hover.(3))
  report(hover.(4).include?("const Op = fn(i64, Buf(u8)) ?i64"), "lsp hover spells out the aliased type", hover.(4))
  report(range == { "line" => 0, "character" => 32 }, "lsp alias symbol ends with its type", range.inspect)
  report(op&.fetch("kind") == 11, "lsp outline gives an alias its own symbol kind", op.inspect)
  report(status.success? && err.empty?, "lsp alias session ends cleanly", err)
end

def check_lsp_v1
  uri = "file:///t/b.egg"
  src = <<~EGG
    uses io

    const Point = struct {
        x: i64

        fn bump(inout self: Point) void {
            self.x = self.x + 1
        }
    }

    fn main(out: Io) void {
        var p = Point{ .x = 1 }
        p.bump()
        for ([2]i64{ 1, 2 }) |v| {
            out.print(v + p.x)
        }
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(12, 7) },  # p.bump()
    { "id" => 4, "method" => "textDocument/definition", "params" => at.(11, 13) }, # Point{
    { "id" => 5, "method" => "textDocument/definition", "params" => at.(14, 18) }, # v in the loop
    { "id" => 6, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, _, status, err = lsp_session(req)
  start = ->(id) { r = replies.dig(id, "result", "range", "start"); r && [r["line"], r["character"]] }
  names = (replies.dig(2, "result") || []).map { |x| x["name"] }
  report(names == %w[Point Point.bump main], "lsp v1 outline lists types and methods", names.inspect)
  report(start.(3) == [5, 7], "lsp v1 definition of a method", start.(3).inspect)
  report(start.(4) == [2, 6], "lsp v1 definition of a type from a literal", start.(4).inspect)
  report(start.(5) == [13, 26], "lsp v1 definition of a loop variable is its name", start.(5).inspect)
  report(status.success? && err.empty?, "lsp v1 session ends cleanly", err)
end

# Generics, annotations, switch payloads and symbol kinds.
def check_lsp_generics
  uri = "file:///t/c.egg"
  src = <<~EGG
    uses io

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

    fn main(out: Io) void {
        const p = Pair(i64){ .a = 1, .b = 2 }
        const q: Pair(i64) = p.swap()
        out.print(q.a + area(.empty))
        for ([2]i64{ 3, 4 }) |_, i| {
            out.print(i)
        }
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(28, 28) }, # p.swap()
    { "id" => 4, "method" => "textDocument/definition", "params" => at.(27, 15) }, # Pair(i64){
    { "id" => 5, "method" => "textDocument/definition", "params" => at.(15, 11) }, # s: Shape
    { "id" => 6, "method" => "textDocument/definition", "params" => at.(28, 13) }, # q: Pair(i64)
    { "id" => 7, "method" => "textDocument/definition", "params" => at.(18, 19) }, # r in r * r
    { "id" => 8, "method" => "textDocument/definition", "params" => at.(31, 18) }, # i in out.print(i)
    { "id" => 9, "method" => "textDocument/definition", "params" => at.(30, 26) }, # the _ binding
    { "id" => 10, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  start = ->(id) { r = replies.dig(id, "result", "range", "start"); r && [r["line"], r["character"]] }
  syms = (replies.dig(2, "result") || []).map { |x| [x["name"], x["kind"]] }
  report(diags.first == [], "lsp generics source has no errors", diags.first.inspect)
  report(syms == [["Pair", 12], ["Pair.swap", 6], ["Shape", 23], ["area", 12], ["main", 12]],
         "lsp outline kinds: functions, methods, types", syms.inspect)
  report(start.(3) == [7, 11], "lsp definition of a generic method", start.(3).inspect)
  report(start.(4) == [2, 3], "lsp definition from a generic literal", start.(4).inspect)
  report(start.(5) == [13, 6] && start.(6) == [2, 3], "lsp definition from type annotations", [start.(5), start.(6)].inspect)
  report(start.(7) == [17, 20], "lsp definition of a switch payload is its name", start.(7).inspect)
  report(start.(8) == [30, 29], "lsp definition of a loop index is its name", start.(8).inspect)
  report(replies.key?(9) && replies.dig(9, "result").nil?, "lsp '_' is not a variable", replies[9].inspect)
  report(status.success? && err.empty?, "lsp generics session ends cleanly", err)
end

# Imports resolve next to the open file; an error in an imported file is
# shown at the top of the open one.
def check_lsp_modules
  good = File.join(ROOT, "examples", "modules.egg")
  bad = File.join(ROOT, "test", "errors", "cap_in_module.egg")
  undeclared = File.join(ROOT, "test", "errors", "cap_undeclared.egg")
  cchar = File.join(ROOT, "examples", "lib", "cchar.egg")
  open_doc = ->(path) { { "method" => "textDocument/didOpen", "params" => { "textDocument" => { "uri" => "file://#{path}", "text" => File.read(path) } } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    open_doc.(good),
    open_doc.(bad),
    open_doc.(undeclared),
    open_doc.(cchar),
    { "id" => 4, "method" => "textDocument/hover", "params" => { "textDocument" => { "uri" => "file://#{cchar}" }, "position" => { "line" => 3, "character" => 11 } } },
    { "id" => 5, "method" => "textDocument/hover", "params" => { "textDocument" => { "uri" => "file://#{cchar}" }, "position" => { "line" => 5, "character" => 4 } } },
    { "id" => 3, "method" => "textDocument/hover", "params" => { "textDocument" => { "uri" => "file://#{undeclared}" }, "position" => { "line" => 2, "character" => 4 } } },
    { "id" => 2, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  report(diags[0] == [], "lsp resolves imports next to the file", diags[0].inspect)
  hover = replies.dig(3, "result", "contents", "value").to_s.lines[1].to_s.strip
  report(hover == "fn main(out: Io) void  // uses io", "lsp hover shows capabilities despite E130", hover.inspect)
  at = ->(id) { replies.dig(id, "result", "contents", "value").to_s.lines[1].to_s.strip }
  report(at.(4) == "extern fn toupper(c: i32) i32  // allow unsafe" && at.(5) == "fn upper(b: u8) u8  // allow unsafe",
         "lsp hover marks extern fns and unsafe files", [at.(4), at.(5)].inspect)
  d = diags[1]&.first
  ok = d && d["code"] == "E130" && d["range"]["start"] == { "line" => 0, "character" => 0 } && d["message"].include?("lib/quiet_print.egg:3:9: ")
  report(ok, "lsp shows an error in an imported file at the top", diags[1].inspect)
  report(status.success? && err.empty?, "lsp modules session ends cleanly", err)
end

# Imports by absolute path, unreadable imports, and debug without a path.
# A file import stays inside its module's root; other modules go by name.
def check_loader(dir)
  inner = File.join(dir, "app", "main.egg")
  r = Egg.compile_to_c("const m = @import(\"../loader_lib.egg\")\nfn main() void {\n}\n", inner)
  d = r.diagnostics.first
  report(d && d.code == "E129" && d.message.include?("outside this module's root"), "a file import cannot leave the module's root", d&.to_text("main.egg"))
  r = Egg.compile_to_c("const m = @import(\"nope/x\")\nfn main() void {\n}\n", inner)
  d = r.diagnostics.first
  report(d && d.code == "E129" && d.message.include?("unknown module 'nope'"), "an unknown module is E129", d&.to_text("main.egg"))
  r = Egg.compile_to_c("const m = @import(\"std/../x\")\nfn main() void {\n}\n", inner)
  d = r.diagnostics.first
  report(d && d.code == "E129" && d.message.include?("neither a file"), "a module path has only names", d&.to_text("main.egg"))
  r = Egg.compile_to_c("const m = @import(\"std/\")\nfn main() void {\n}\n", inner)
  d = r.diagnostics.first
  report(d && d.code == "E129" && d.message.include?("neither a file"), "a module path cannot end in /", d&.to_text("main.egg"))
  # A symlink inside the root that leads out of it.
  app = File.join(dir, "linked")
  FileUtils.mkdir_p(app)
  File.write(File.join(dir, "secret.egg"), "fn f() void {\n}\n")
  link = File.join(app, "escape.egg")
  File.symlink(File.join(dir, "secret.egg"), link) unless File.symlink?(link)
  r = Egg.compile_to_c("const m = @import(\"escape.egg\")\nfn main() void {\n}\n", File.join(app, "main.egg"))
  d = r.diagnostics.first
  report(d && d.code == "E129" && d.message.include?("outside this module's root"), "a symlink cannot lead an import out of the root", d&.to_text("main.egg"))
  lib = File.join(dir, "loader_lib.egg")
  File.write(lib, "fn f() void {\n    const x =\n}\n")
  r = Egg.compile_to_c("const m = @import(\"#{lib}\")\nfn main() void {\n}\n", File.join(dir, "main.egg"))
  d = r.diagnostics.first
  report(d && d.code == "E002" && d.file == lib, "an absolute import keeps its path in diagnostics", d&.to_text("main.egg"))
  drive = Egg.normalize_path("D:/a/../../b/./c.egg")
  report(drive == "D:/b/c.egg", "a path keeps its Windows drive", drive)
  locked = File.join(dir, "locked.egg")
  File.write(locked, "fn f() void {\n}\n")
  File.chmod(0o000, locked)
  begin
    if File.readable?(locked)
      # Permissions do not apply (running as root): nothing to check.
      puts "  skip  an unreadable import is E129 (the file is readable anyway)"
    else
      r = Egg.compile_to_c("const m = @import(\"#{locked}\")\nfn main() void {\n}\n", File.join(dir, "main.egg"))
      d = r.diagnostics.first
      report(d && d.code == "E129" && d.message.include?("cannot read"), "an unreadable import is E129", d&.to_text("main.egg"))
    end
  ensure
    File.chmod(0o644, locked)
  end
  r = Egg.compile_to_c("fn main() void {\n}\n", nil, debug: true)
  report(r.diagnostics.empty? && !r.c_source.include?("#line"), "debug without a path builds without #line marks")
end

# Pointer expressions (p.*, null), also inside a defer, are indexed
# without crashing the server.
def check_lsp_pointers
  doc = { "uri" => "file:///t/p.egg" }
  src = <<~EGG
    uses io
    allow unsafe

    fn main(out: Io) void {
        var x = 1
        const p = &x
        defer out.print(p.* + 1)
        out.print(p == null)
        x = 2
    }
  EGG
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 3, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, _, status, err = lsp_session(req)
  names = (replies.dig(2, "result") || []).map { |x| x["name"] }
  report(names.include?("main") && status.success? && err.empty?, "lsp indexes p.* and null inside defer", "#{names.inspect}\n#{err}")
end

# An extern fn's symbol covers its whole declaration, over several lines.
def check_lsp_extern
  doc = { "uri" => "file:///t/e.egg" }
  src = <<~EGG
    allow unsafe

    extern fn write(
        fd: i32,
        buf: *u8,
        n: usize
    ) i64 uses io

    fn main() void {
    }
  EGG
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 3, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, _, status, err = lsp_session(req)
  sym = (replies.dig(2, "result") || []).find { |x| x["name"] == "write" }
  stop = sym && sym["range"]["end"]
  report(stop == { "line" => 6, "character" => 13 }, "lsp extern fn symbol spans its declaration", sym.inspect)
  report(status.success? && err.empty?, "lsp extern session ends cleanly", err)
end

def check_lsp
  uri = "file:///t/a.egg"
  src = <<~EGG
    uses io

    fn add(a: i64, b: i64) i64 {
        return a + b
    }

    fn main(out: Io) void {
        var total = 0
        total = add(total, 2)
        out.print(total + @len("x"))
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  edit = ->(text) { { "method" => "textDocument/didChange", "params" => { "textDocument" => doc, "contentChanges" => [{ "text" => text }] } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/definition", "params" => at.(8, 13) },  # add( in main
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(9, 14) },  # total in out.print
    { "id" => 4, "method" => "textDocument/definition", "params" => at.(8, 4) },   # total = ...
    { "id" => 5, "method" => "textDocument/definition", "params" => at.(3, 11) },  # a in add
    { "id" => 6, "method" => "textDocument/definition", "params" => at.(9, 23) },  # @len: nothing
    { "id" => 7, "method" => "textDocument/hover", "params" => at.(8, 12) },
    { "id" => 8, "method" => "textDocument/hover", "params" => at.(7, 8) },
    { "id" => 9, "method" => "textDocument/documentSymbol", "params" => { "textDocument" => doc } },
    { "id" => 12, "method" => "textDocument/hover", "params" => at.(6, 4) },        # main: uses io
    edit.(src.sub("add(total, 2)", "add(totl, 2)")),
    edit.(src.sub("return a + b", "return a +")),
    { "id" => 10, "method" => "textDocument/definition", "params" => at.(8, 13) }, # last good version
    { "id" => 11, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  result = ->(id) { replies.dig(id, "result") }
  start = ->(id) { result.(id) && result.(id)["range"]["start"].values_at("line", "character") }
  hover = ->(id) { result.(id) && result.(id)["contents"]["value"].lines[1].to_s.strip }
  report(result.(1)&.dig("capabilities", "definitionProvider") == true, "lsp initialize")
  report(start.(2) == [2, 3], "lsp definition of a function", start.(2).inspect)
  report(start.(3) == [7, 8] && start.(4) == [7, 8], "lsp definition of a local", [start.(3), start.(4)].inspect)
  report(start.(5) == [2, 7], "lsp definition of a parameter", start.(5).inspect)
  report(replies.key?(6) && result.(6).nil?, "lsp definition on a builtin is empty", replies[6].inspect)
  report(hover.(7) == "fn add(a: i64, b: i64) i64" && hover.(8) == "var total: i64", "lsp hover", [hover.(7), hover.(8)].inspect)
  report(hover.(12) == "fn main(out: Io) void  // uses io", "lsp hover shows the capabilities a function uses", hover.(12).inspect)
  names = (result.(9) || []).map { |sym| sym["name"] }
  report(names == %w[add main], "lsp document symbols", names.inspect)
  codes = diags.map { |ds| ds.map { |d| d["code"] } }
  report(codes == [[], ["E101"], ["E002"]], "lsp diagnostics follow edits", codes.inspect)
  e101 = diags[1] && diags[1][0] && diags[1][0]["range"]
  report(e101 == { "start" => { "line" => 8, "character" => 16 }, "end" => { "line" => 8, "character" => 20 } },
         "lsp diagnostic range covers the token", e101.inspect)
  report(start.(10) == [2, 3], "lsp navigation survives a syntax error", start.(10).inspect)
  report(status.success? && err.empty?, "lsp shutdown and exit", "status #{status.exitstatus}, stderr: #{err}")
end

# Can the C compiler link library `lib`?
def have_lib?(lib, dir)
  c = File.join(dir, "have_lib.c")
  File.write(c, "int main(void) { return 0; }\n")
  _, _, st = Open3.capture3(CC, "-o", File.join(dir, "have_lib"), c, "-l#{lib}")
  st.success?
end

# Build test/link/linktest.c into dir/liblinktest.a, then link it through
# `link` in an imported module, and through eggc's -l and -L.
def check_link(dir)
  link = File.join(ROOT, "test", "link")
  obj = File.join(dir, "linktest.o")
  _, err, st = Open3.capture3(CC, "-std=c99", "-c", "-o", obj, File.join(link, "linktest.c"))
  _, err2, st2 = Open3.capture3("ar", "rcs", File.join(dir, "liblinktest.a"), obj) if st.success?
  return report(false, "build liblinktest.a", "#{err}#{err2}") unless st.success? && st2.success?
  main = File.join(link, "main.egg")
  check_program("link/main.egg", File.read(main), dir, main, lib_dirs: [dir])
  check_program("link/main.egg -g", File.read(main), dir, main, debug: true, lib_dirs: [dir])
  eggc = [RbConfig.ruby, File.join(ROOT, "bin", "eggc")]
  out, err, st = Open3.capture3(*eggc, "run", main, "-L", dir)
  report(st.success? && out == "42\n", "eggc run links what `link` names", "#{out}#{err}")
  cli = File.join(link, "cli.egg")
  out, err, st = Open3.capture3(*eggc, "run", cli, "-L#{dir}", "-llinktest")
  report(st.success? && out == "73\n", "eggc run -L DIR -lLIB", "#{out}#{err}")
  out, err, st = Open3.capture3(*eggc, "run", cli, "-L", dir, "-l", "linktest")
  report(st.success? && out == "73\n", "eggc run -L DIR -l LIB", "#{out}#{err}")
  _, _, st = Open3.capture3(*eggc, "run", cli)
  report(!st.success?, "eggc run without -l fails to link", "status #{st.exitstatus}")
end

Dir.mktmpdir do |dir|
  puts "examples"
  Dir[File.join(ROOT, "examples", "*.egg")].sort.each do |path|
    check_program(File.basename(path), File.read(path), dir, path)
    check_program("#{File.basename(path)} -g", File.read(path), dir, path, debug: true)
  end

  puts "examples/complex"
  Dir[File.join(ROOT, "examples", "complex", "*.egg")].sort.each do |path|
    name = path.delete_prefix("#{ROOT}/examples/")
    check_program(name, File.read(path), dir, path)
    check_program("#{name} -g", File.read(path), dir, path, debug: true)
  end

  puts "examples/ffi"
  Dir[File.join(ROOT, "examples", "ffi", "*", "*.egg")].sort.each do |path|
    src = File.read(path)
    next if comment_values(src, "expect").empty? # a module, not a program
    name = path.delete_prefix("#{ROOT}/examples/")
    links = Egg.compile_to_c(src, path).links || []
    missing = links.reject { |l| have_lib?(l, dir) }
    unless missing.empty?
      puts "  skip  #{name} (no #{missing.map { |l| "lib#{l}" }.join(', ')})"
      next
    end
    check_program(name, src, dir, path)
    check_program("#{name} -g", src, dir, path, debug: true)
  end

  puts "errors"
  Dir[File.join(ROOT, "test", "errors", "*.egg")].sort.each do |path|
    check_errors(File.basename(path), File.read(path), path)
  end

  puts "loader"
  check_loader(dir)

  puts "link"
  check_link(dir)

  puts "lsp"
  check_lsp
  check_lsp_generics
  check_lsp_v1
  check_lsp_catch
  check_lsp_alias
  check_fs_errors(dir)
  check_args(dir)
  check_stdin(dir)
  check_lsp_char
  check_lsp_modules
  check_lsp_extern
  check_lsp_pointers

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
