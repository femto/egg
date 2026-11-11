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
# test/pkg/         -- packages given with eggc --pkg NAME=DIR: app/ uses
#                      greet/ and shout/ (escape/ must stay in its root).
# clutch            -- the package manager on packages made here: path, git
#                      and index dependencies, the lock, and its errors
#                      (skipped without git).
# eggc lsp          -- the language server answers definition, hover,
#                      outline and diagnostics requests. EGGC=path tests
#                      another eggc, such as a Spinel-built one.
#
# Usage: ruby test/run.rb

require "json"
require "rbconfig"
require "open3"
require "shellwords"
require "socket"
require "timeout"
require "tmpdir"
require_relative "../lib/egg"

# Sources and program output are UTF-8 whatever the locale's default encoding is.
Encoding.default_external = Encoding::UTF_8

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
def check_program(name, src, dir, path = nil, debug: false, lib_dirs: [], pkgs: {})
  result = Egg.compile_to_c(src, path, debug: debug, pkgs: pkgs)
  unless result.diagnostics.empty?
    return report(false, name, result.diagnostics.map { |d| d.to_text(name) }.join("\n"))
  end
  if debug
    bad = bad_line_marks(result.c_source, src, File.expand_path(path), result.skipped || [])
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
def bad_line_marks(c_source, src, path, skipped = [])
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
    # and generate no code (an extern fn only a prototype). A const at
    # the top level, not indented, is an alias or a constant.
    declares = text.match?(/\A(uses|allow|extern|link)\s/) || src.lines[i].match?(/\Aconst[ \t]+\w+[ \t]*(:[^=]*)?=[ \t]*+(?!(owned[ \t]+)?struct\b|enum\b|union\b)/)
    # An else-if comparing types (K == i64) is decided at compile time, and
    # @compileError stands only in a branch that is never generated.
    # The right side must name a type, so a runtime `x == y` is not taken
    # for one.
    ty = /(?:[A-Z]\w*|[iuf]\d+|usize|str|bool|anyerror|void)\b/
    comptime = text.match?(/\A\} else if \((\s*!?\s*\w+\s*[!=]=\s*#{ty}\s*(and|or)?)+\s*\) \{\z/) || text.start_with?("@compileError(")
    # A closing brace generates nothing, nor does the `}) orelse {` that
    # closes a catch block and opens the fallback of the optional it gave.
    code << i + 1 unless continued || declares || comptime || text.match?(/\A\}( else \{|\) orelse \{)?\z/)
    prev = text
  end
  code -= unemitted_lines(skipped, src)
  (marked - code) + (code - marked)
end

# The lines of the functions the compiler checked but did not emit as C
# (skipped: [module, line]; nil is this file), so they have no #line
# marks: from `fn` to the brace that closes it at its indentation.
def unemitted_lines(skipped, src)
  lines = src.lines
  skipped.select { |mod, _| mod.nil? || mod.empty? }.flat_map do |_, line|
    indent = lines[line - 1][/\A\s*/]
    close = (line...lines.length).find { |j| lines[j].match?(/\A#{indent}\}\s*\z/) }
    (line..((close || line - 1) + 1)).to_a
  end
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

# The language server gives a file in a clutch package that package's
# packages, from clutch flags (with --test under test/).
def check_lsp_packages(dir)
  root = File.join(dir, "lsp_pkgs")
  FileUtils.rm_rf(root)
  FileUtils.mkdir_p(root)
  clutch = ->(at, *args) { Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin", "clutch"), *args, chdir: File.join(root, at)) }
  clutch.(".", "new", "app")
  clutch.(".", "new", "--lib", "hello")
  File.write(File.join(root, "hello", "src", "hello.egg"), "fn hi() str {\n    return \"hi\"\n}\n")
  File.write(File.join(root, "app", "clutch.toml"), File.read(File.join(root, "app", "clutch.toml")) + "hello = { path = \"../hello\" }\n")
  main = "uses io\n\nconst hello = @import(\"hello\")\n\nfn main(io: Io) void {\n    io.print(hello.hi())\n}\n"
  test = File.read(File.join(root, "hello", "test", "hello.egg")).sub("lib.add(2, 3) != 5", "@len(lib.hi()) != 2")
  uri = ->(*parts) { "file://#{File.join(root, *parts)}" }
  open = ->(u, text) { { "method" => "textDocument/didOpen", "params" => { "textDocument" => { "uri" => u, "text" => text } } } }
  session = ->(*docs) { lsp_session([{ "id" => 1, "method" => "initialize", "params" => {} }, *docs, { "id" => 2, "method" => "shutdown" }, { "method" => "exit" }])[1] }
  diags = session.(open.(uri.("app", "src", "main.egg"), main), open.(uri.("hello", "test", "hello.egg"), test),
                   open.(uri.("hello", "src", "hello.egg"), main.sub("hello.hi()", "\"x\"")))
  report(diags[0] == [], "lsp: a program's packages come from clutch", diags[0].inspect)
  report(diags[1] == [], "lsp: a test sees its own package", diags[1].inspect)
  report(diags[2]&.any? { |d| d["code"] == "E129" && d["message"].include?("unknown module 'hello'") }, "lsp: a package does not see itself outside test/", diags[2].inspect)
  File.write(File.join(root, "app", "clutch.toml"), File.read(File.join(root, "app", "clutch.toml")).sub("../hello", "../nowhere"))
  diags = session.(open.(uri.("app", "src", "main.egg"), main))
  report(diags[0]&.any? { |d| d["code"] == "clutch" && d["message"].include?("no directory") }, "lsp: clutch's error is a diagnostic", diags[0].inspect)
  diags = session.(open.(uri.("app", "src", "main.egg"), main.sub("fn main", "fn main(")))
  report(diags[0]&.any? { |d| d["code"] == "clutch" }, "lsp: clutch's error is kept with a syntax error", diags[0].inspect)
  # The answer is kept until a manifest it depends on changes, a path
  # package's too.
  require_relative "../lib/egg/lsp"
  File.write(File.join(root, "app", "clutch.toml"), File.read(File.join(root, "app", "clutch.toml")).sub("../nowhere", "../hello"))
  packages = Egg::LSP::Packages.new
  main_file = File.join(root, "app", "src", "main.egg")
  first = packages.for(main_file)
  hello_toml = File.join(root, "hello", "clutch.toml")
  File.write(hello_toml, File.read(hello_toml) + "nope = { path = \"../nope\" }\n")
  later = Time.now + 5
  File.utime(later, later, hello_toml)
  second = packages.for(main_file)
  report(first[1].nil? && File.realpath(first[0]["hello"].to_s) == File.realpath(File.join(root, "hello", "src")) && second[1].to_s.include?("no directory"), "lsp: a path package's manifest is watched", [first, second].inspect)
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

    fn main(io: Io) void {
        const v = f() catch |e| {
            io.print(@errorName(e))
            return
        }
        io.print(v)
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
def fs_readable?(path)
  File.read(path)
  true
rescue SystemCallError
  false
end

def check_fs_errors(dir)
  work = File.join(dir, "fs_errors")
  FileUtils.mkdir_p(work)
  locked = File.join(work, "locked.txt")
  File.write(locked, "secret")
  File.chmod(0o000, locked)
  keep = File.join(work, "keep.txt")
  File.write(keep, "keep")
  File.chmod(0o444, keep)
  # chmod cannot stop Windows reading a file; a deny rule can.
  deny = Gem.win_platform? ? "#{ENV["USERNAME"]}:(R)" : nil
  system("icacls", locked, "/deny", deny, out: File::NULL) if deny
  begin
    if fs_readable?(locked)
      puts "  skip  fs permission errors (the file is readable anyway)"
    else
      check_program("fs_permission", <<~EGG, work)
        // expect: PermissionDenied
        // expect: PermissionDenied
        uses alloc, fs, io

        fn main(io: Io, files: Fs, a: Allocator) void {
            const b = files.read(a, "locked.txt") catch |e| {
                io.print(@errorName(e))
                files.write("keep.txt", "new") catch |e2| {
                    io.print(@errorName(e2))
                }
                return
            }
            a.free(b)
        }
      EGG
      report(File.read(keep) == "keep", "a refused fs.write leaves the file as it was", File.read(keep))
    end
  ensure
    system("icacls", locked, "/remove:d", ENV["USERNAME"], out: File::NULL) if deny
    File.chmod(0o644, locked, keep)
  end
  unless File.exist?("/dev/full")
    puts "  skip  fs.write reports a full disk (no /dev/full)"
    return
  end
  check_program("fs_full_disk", <<~EGG, work)
    // expect: IoFailed
    uses fs, io

    fn main(io: Io, files: Fs) void {
        files.write("/dev/full", "data") catch |e| {
            io.print(@errorName(e))
        }
    }
  EGG
end

# Failures of open files that a program cannot set up by itself.
def check_file_errors(dir)
  work = File.join(dir, "file_errors")
  FileUtils.mkdir_p(File.join(work, "folder"))
  check_program("file_open_dir", <<~EGG, work)
    // expect: IsDirectory
    uses fs, io

    fn main(io: Io, files: Fs) void {
        const r = files.open("folder") catch |e| {
            io.print(@errorName(e))
            return
        }
        r.close()
    }
  EGG
  check_program("file_create_dir", <<~EGG, work)
    // expect: IsDirectory
    uses fs, io

    fn main(io: Io, files: Fs) void {
        const w = files.create("folder") catch |e| {
            io.print(@errorName(e))
            return
        }
        w.close()
    }
  EGG
  unless File.exist?("/dev/full")
    puts "  skip  a Writer reports a full disk (no /dev/full)"
    return
  end
  check_program("file_full_disk", <<~EGG, work)
    // expect: IoFailed
    uses fs, io

    fn write(files: Fs) !void {
        const w = try files.create("/dev/full")
        defer w.close()
        try w.print("data")
        try w.flush()
    }

    fn main(io: Io, files: Fs) void {
        write(files) catch |e| {
            io.print(@errorName(e))
        }
    }
  EGG
end

# Failures of the network that need another side, played here by Ruby. Only
# the loopback address is used.
def check_net(dir)
  closed = TCPServer.new("127.0.0.1", 0)
  free_port = closed.addr[1]
  closed.close
  check_program("net_refused", <<~EGG, dir)
    // expect: ConnectionRefused
    uses io, net

    fn main(io: Io, net: Net) void {
        const c = net.tcp_connect("127.0.0.1", #{free_port}) catch |e| {
            io.print(@errorName(e))
            return
        }
        c.close()
    }
  EGG
  check_program("net_bad_host", <<~EGG, dir)
    // expect: HostNotFound
    uses io, net

    fn main(io: Io, net: Net) void {
        const r = net.resolve("a\\x00b", 80) catch |e| {
            io.print(@errorName(e))
            return
        }
        io.print(r)
    }
  EGG
  # Some networks answer every name, so see what this one does first.
  answered = begin
    Addrinfo.getaddrinfo("no-such-host.invalid", 80)
    true
  rescue SocketError
    false
  end
  if answered
    puts "  skip  a name that does not resolve (this network answers every name)"
  else
    check_program("net_no_host", <<~EGG, dir)
      // expect: HostNotFound
      uses io, net

      fn main(io: Io, net: Net) void {
          const c = net.tcp_connect("no-such-host.invalid", 80) catch |e| {
              io.print(@errorName(e))
              return
          }
          c.close()
      }
    EGG
  end
  check_program("net_in_use", <<~EGG, dir)
    // expect: AddressInUse
    uses io, net

    fn main(io: Io, net: Net) !void {
        const l = try net.tcp_listen("127.0.0.1", 0)
        defer l.close()
        const m = net.tcp_listen("127.0.0.1", l.port()) catch |e| {
            io.print(@errorName(e))
            return
        }
        m.close()
    }
  EGG
  check_program("net_timeout", <<~EGG, dir)
    // expect: TimedOut
    // expect: TimedOut
    uses alloc, io, net

    fn wait(io: Io, c: TcpConn, a: Allocator) void {
        const b = c.read_all(a) catch |e| {
            io.print(@errorName(e))
            return
        }
        a.free(b)
    }

    fn main(io: Io, net: Net, a: Allocator) !void {
        const l = try net.tcp_listen("127.0.0.1", 0)
        defer l.close()
        const c = try net.tcp_connect("127.0.0.1", l.port())
        defer c.close()
        const peer = try l.accept()
        defer peer.close()
        try c.set_timeout(100)
        wait(io, c, a)
        const u = try net.udp_bind("127.0.0.1", 0)
        defer u.close()
        try u.set_timeout(100)
        var buf: Buf(u8) = .empty
        defer a.free(buf)
        const from = u.recv_from(a, &buf, 16) catch |e| {
            io.print(@errorName(e))
            return
        }
        io.print(from)
    }
  EGG
  # The other side goes away: the write fails, it does not kill the program.
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  gone = Thread.new { server.accept.close }
  check_program("net_reset", <<~EGG, dir)
    // expect: ConnectionReset
    uses io, net

    fn pump(c: TcpConn) !void {
        var i = 0
        while (i < 100000) {
            try c.write("0123456789012345678901234567890123456789")
            i = i + 1
        }
    }

    fn main(io: Io, net: Net) !void {
        const c = try net.tcp_connect("127.0.0.1", #{port})
        defer c.close()
        pump(c) catch |e| {
            io.print(@errorName(e))
        }
    }
  EGG
  gone.kill
  server.close

  # A server written in Egg, with Ruby as its client.
  path = File.join(dir, "net_server.egg")
  File.write(path, <<~EGG)
    uses alloc, io, net

    fn main(io: Io, net: Net, a: Allocator) !void {
        const l = try net.tcp_listen("127.0.0.1", 0)
        defer l.close()
        io.eprint(l.port())
        const c = try l.accept()
        defer c.close()
        var line: Buf(u8) = .empty
        defer a.free(line)
        while (try c.read_line(a, &line)) {
            try c.write(line)
            try c.write("!\\n")
        }
    }
  EGG
  Open3.popen3(*eggc_command, "run", path) do |_, _, stderr, thread|
    first = Timeout.timeout(60) { stderr.gets }
    if first.nil?
      report(false, "a server in Egg answers Ruby", "the server did not start")
      next
    end
    sock = TCPSocket.new("127.0.0.1", first.to_i)
    sock.write("one\ntwo\n")
    sock.close_write
    got = Timeout.timeout(10) { sock.read }
    sock.close
    report(thread.value.success? && got.lines.map(&:chomp) == %w[one! two!], "a server in Egg answers Ruby", got.inspect)
  rescue Timeout::Error
    Process.kill("KILL", thread.pid)
    report(false, "a server in Egg answers Ruby", "timed out")
  end
end

# Threads really run at once. Output is checked by Ruby because its order
# is not known.
def check_threads(dir)
  noisy = File.join(dir, "threads_noisy.egg")
  File.write(noisy, <<~EGG)
    uses alloc, io, thread

    const Worker = owned struct {
        t: Thread

        fn deinit(sink self: Worker, a: Allocator) void {
            self.t.join()
            @forget(self)
        }
    }

    fn talk(io: Io, id: i64) void {
        var i = 0
        while (i < 2000) {
            io.print("thread ", id, " line ", i, " end")
            i = i + 1
        }
    }

    fn main(io: Io, a: Allocator, threads: Threads) void {
        var workers: Buf(Worker) = .empty
        defer a.free(workers)
        var id = 0
        while (id < 4) {
            a.push(&workers, Worker{ .t = threads.spawn(talk, io, id) })
            id = id + 1
        }
    }
  EGG
  out, err, status = Open3.capture3(*eggc_command, "run", noisy)
  got = out.lines.map(&:chomp)
  whole = got.all? { |l| l.match?(/\Athread \d line \d+ end\z/) }
  report(status.success? && got.length == 8000 && whole, "lines from threads do not mix", "#{got.length} lines, #{err}")

  server = File.join(dir, "threads_server.egg")
  File.write(server, <<~EGG)
    uses alloc, io, net, thread

    fn serve(sink c: TcpConn, a: Allocator) void {
        defer c.close()
        var line: Buf(u8) = .empty
        defer a.free(line)
        while (true) {
            const more = c.read_line(a, &line) catch {
                return
            }
            if (!more) {
                return
            }
            c.write(line) catch {
                return
            }
            c.write("!\\n") catch {
                return
            }
        }
    }

    fn main(io: Io, net: Net, a: Allocator, threads: Threads) !void {
        const l = try net.tcp_listen("127.0.0.1", 0)
        defer l.close()
        io.eprint(l.port())
        const first = threads.spawn(serve, try l.accept(), a)
        defer first.join()
        const second = threads.spawn(serve, try l.accept(), a)
        defer second.join()
    }
  EGG
  Open3.popen3(*eggc_command, "run", server) do |_, _, stderr, thread|
    first = Timeout.timeout(60) { stderr.gets }
    if first.nil?
      report(false, "a server serves two connections at once", "the server did not start")
      next
    end
    port = first.to_i
    idle = TCPSocket.new("127.0.0.1", port)
    busy = TCPSocket.new("127.0.0.1", port)
    # Answered while the first connection says nothing.
    busy.write("hi\n")
    answer = Timeout.timeout(10) { busy.gets }
    busy.close
    idle.write("late\n")
    late = Timeout.timeout(10) { idle.gets }
    idle.close
    report(thread.value.success? && answer&.chomp == "hi!" && late&.chomp == "late!", "a server serves two connections at once", [answer, late].inspect)
  rescue Timeout::Error
    Process.kill("KILL", thread.pid)
    report(false, "a server serves two connections at once", "timed out")
  end
end

# A channel of capacity 0: send returns only after recv took the value. The
# program waits for a line on stdin before it receives.
def check_rendezvous(dir)
  path = File.join(dir, "rendezvous.egg")
  File.write(path, <<~EGG)
    uses alloc, io, thread

    fn worker(sink tx: Sender(i64), io: Io) void {
        defer tx.close()
        io.eprint("before")
        tx.send(7)
        io.eprint("after")
    }

    fn main(io: Io, a: Allocator, threads: Threads) !void {
        const rx = threads.channel(i64, 0)
        defer rx.close()
        const t = threads.spawn(worker, rx.sender(), io)
        defer t.join()
        var line: Buf(u8) = .empty
        defer a.free(line)
        _ = try io.read_line(a, &line)
        while (rx.recv()) |v| {
            io.print(v)
        }
    }
  EGG
  Open3.popen3(*eggc_command, "run", path) do |stdin, stdout, stderr, thread|
    first = Timeout.timeout(60) { stderr.gets }
    if first.nil?
      report(false, "a sender on a channel of capacity 0 waits for the receiver", "the program did not start")
      next
    end
    early = begin
      Timeout.timeout(0.5) { stderr.gets }
    rescue Timeout::Error
      nil
    end
    stdin.puts("go")
    stdin.close
    second = Timeout.timeout(10) { stderr.gets }
    ok = first.chomp == "before" && early.nil? && second&.chomp == "after" && stdout.read.chomp == "7" && thread.value.success?
    report(ok, "a sender on a channel of capacity 0 waits for the receiver", [first, early.nil?, second].inspect)
  rescue Timeout::Error
    Process.kill("KILL", thread.pid)
    report(false, "a sender on a channel of capacity 0 waits for the receiver", "timed out")
  end
end

# The example HTTP server, with Ruby as its clients.
def check_http_server(dir)
  root = File.join(dir, "www")
  FileUtils.mkdir_p(File.join(root, "sub"))
  File.binwrite(File.join(root, "index.html"), "<h1>egg</h1>")
  File.binwrite(File.join(root, "note.txt"), "hello\n")
  blob = (0..255).map(&:chr).join * 4096
  File.binwrite(File.join(root, "blob.bin"), blob)
  File.write(File.join(dir, "secret.txt"), "secret")
  ask = lambda do |port, text|
    sock = TCPSocket.new("127.0.0.1", port)
    sock.binmode
    sock.write(text)
    got = Timeout.timeout(10) { sock.read }
    sock.close
    got
  end
  # Built first: stopping it must stop the server, not a driver around it.
  source = File.join(ROOT, "examples", "http_server", "server.egg")
  exe = File.join(dir, "http_server")
  built, status = Open3.capture2e(*eggc_command, "build", source, "-o", exe)
  return report(false, "http server builds", built) unless status.success?
  Open3.popen3(exe, root, "0") do |_, _, stderr, thread|
    begin
      first = Timeout.timeout(60) { stderr.gets }
      port = first.to_s[/\d+/].to_i
      if port.zero?
        report(false, "http server starts", first.inspect)
        next
      end
      head = ->(path) { ask.(port, "GET #{path} HTTP/1.0\r\nHost: x\r\n\r\n") }
      status = ->(text) { text[/\AHTTP\/1\.1 (\d+)/, 1] }
      index = head.("/")
      report(status.(index) == "200" && index.include?("text/html") && index.end_with?("<h1>egg</h1>"), "http serves the index", index)
      note = head.("/note.txt")
      report(note.include?("text/plain") && note.include?("Content-Length: 6\r\n") && note.end_with?("hello\n"), "http serves a file", note)
      big = head.("/blob.bin")
      body = big.split("\r\n\r\n", 2)[1]
      report(status.(big) == "200" && body == blob, "http serves binary data whole", big.bytesize.to_s)
      report(head.("/note.txt?v=1").end_with?("hello\n"), "http ignores the query", "")
      report(status.(head.("/missing")) == "404", "http 404", "")
      headed = ask.(port, "HEAD /note.txt HTTP/1.0\r\n\r\n")
      report(status.(headed) == "200" && headed.include?("Content-Length: 6\r\n") && headed.end_with?("\r\n\r\n"), "http answers HEAD with the length and no body", headed)
      # Closed with the rest unread, so the client may see a reset.
      long = begin
        ask.(port, "GET /#{"x" * 100_000} HTTP/1.0\r\n\r\n")
      rescue SystemCallError
        ""
      end
      # Refused with 431, or reset before the answer is read.
      report(long.empty? || status.(long) == "431", "http refuses a head that is too long", long[0, 40].to_s)
      report(status.(head.("/sub")) == "404", "http 404 for a directory", "")
      report(status.(head.("/../secret.txt")) == "403", "http refuses to leave the root", "")
      report(status.(ask.(port, "POST / HTTP/1.0\r\n\r\n")) == "405", "http 405", "")
      idle = TCPSocket.new("127.0.0.1", port)
      many = (1..40).map { Thread.new { status.(head.("/note.txt")) } }.map(&:value)
      idle.close
      report(many.all? { |s| s == "200" }, "http serves 40 at once beside an idle connection", many.uniq.inspect)
      # Reads one response; nil once the server has closed.
      answer = lambda do |sock|
        head = Timeout.timeout(10) { sock.gets("\r\n\r\n") }
        next nil if head.nil?
        [head, Timeout.timeout(10) { sock.read(head[/Content-Length: (\d+)/, 1].to_i) }]
      end
      open = lambda do
        sock = TCPSocket.new("127.0.0.1", port)
        sock.binmode
        sock
      end
      closed = ->(sock) { Timeout.timeout(10) { sock.read } == "" }
      get11 = "GET /note.txt HTTP/1.1\r\nHost: x\r\n\r\n"

      sock = open.()
      sock.write(get11)
      one = answer.(sock)
      sock.write(get11)
      two = answer.(sock)
      report(one && two && one[0].include?("Connection: keep-alive") && two[1] == "hello\n", "http keeps a connection open", [one, two].inspect)
      sock.write(get11 * 3)
      report((1..3).all? { answer.(sock)&.last == "hello\n" }, "http answers pipelined requests", "")
      sock.close

      sock = open.()
      sock.write("GET /note.txt HTTP/1.1\r\nHost: x\r\ncOnNeCtIoN: foo, CLOSE\r\n\r\n")
      one = answer.(sock)
      report(one && one[0].include?("Connection: close") && closed.(sock), "http closes when asked, in any case", one.inspect)
      sock.close

      sock = open.()
      sock.write("GET /note.txt HTTP/1.0\r\n\r\n")
      one = answer.(sock)
      report(one && one[0].include?("Connection: close") && closed.(sock), "http/1.0 closes by default", one.inspect)
      sock.close

      sock = open.()
      sock.write("GET /note.txt HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
      one = answer.(sock)
      sock.write(get11)
      report(one && one[0].include?("Connection: keep-alive") && answer.(sock), "http/1.0 keeps when asked", one.inspect)
      sock.close

      # What follows a request with a body must not run as a request.
      sock = open.()
      sock.write("GET /note.txt HTTP/1.1\r\nContent-Length: 28\r\n\r\nGET /index.html HTTP/1.1\r\n\r\n")
      one = answer.(sock)
      report(one && one[0].include?("Connection: close") && closed.(sock), "http closes after a request with a body", one.inspect)
      sock.close

      sock = open.()
      sock.write("GET /note.txt HTTP/1.1\r\nContent-Length: 0\r\n\r\n" + get11)
      one = answer.(sock)
      report(one && one[0].include?("Connection: keep-alive") && answer.(sock), "http keeps open after an empty body", one.inspect)
      sock.close

      # Each of these could frame a body: what follows must not run.
      ["Content-Length: 0, 28", "Content-Length: 0\r\nContent-Length: 28", "Content-Length : 28", "Transfer-Encoding : chunked",
       "tRaNsFeR-eNcOdInG: chunked", "X: a\r\n Content-Length: 28", "no colon", ": 28"].each do |h|
        sock = open.()
        sock.write("GET /missing HTTP/1.1\r\n#{h}\r\n\r\nGET /index.html HTTP/1.1\r\n\r\n")
        one = answer.(sock)
        report(one && one[0].include?("Connection: close") && closed.(sock), "http does not run a hidden request: #{h.inspect}", one.inspect)
        sock.close
      end

      sock = open.()
      sock.write("POST / HTTP/1.1\r\n\r\nGET /index.html HTTP/1.1\r\n\r\n")
      one = answer.(sock)
      report(one && one[0].include?(" 405 ") && closed.(sock), "http closes after a method it refuses", one.inspect)
      sock.close

      sock = open.()
      99.times do
        sock.write(get11)
        answer.(sock)
      end
      sock.write(get11)
      one = answer.(sock)
      report(one && one[0].include?("Connection: close") && closed.(sock), "http closes after 100 requests", one.inspect)
      sock.close

      sock = open.()
      sock.write(get11)
      answer.(sock)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      gone = closed.(sock)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      report(gone && took > 1 && took < 4, "http closes an idle connection", took.to_s)
      sock.close

      Process.kill("KILL", thread.pid)
    rescue Timeout::Error, SystemCallError => e
      Process.kill("KILL", thread.pid)
      report(false, "http server", e.message)
    end
  end
end

# inout parameters passed by pointer are restrict in the C (E117 makes them
# the only way to their value during the call); slices and plain ones not.
def check_restrict
  src = <<~EGG
    uses alloc
    const S = struct {
        n: i64
    }
    fn bump(inout s: S, by: i64) void {
        s.n = s.n + by
    }
    fn fill(a: Allocator, inout out: Buf(u8), inout xs: []i64, s: []u8) void {
        for (s) |c| {
            a.push(&out, c)
        }
        xs[0] = 1
    }
    fn main(a: Allocator) void {
        var s = S{ .n = 0 }
        bump(&s, 2)
        var b: Buf(u8) = .empty
        defer a.free(b)
        var x = [1]i64{ 0 }
        fill(a, &b, &x[0..], "hi")
    }
  EGG
  c = Egg.compile_to_c(src).c_source.to_s
  ok = c.include?("void fn_bump(ty_S *EGG_RESTRICT v_s, int64_t v_by)") &&
       c.include?("void fn_fill(egg_allocator v_a, ty_Buf_u8 *EGG_RESTRICT v_out, ty__i64 v_xs, ty__u8 v_s)")
  report(ok, "inout parameters by pointer are restrict", c.lines.grep(/^void fn_(bump|fill)\(/).join)
end

# What a program sees on its command line, and the order of its two output
# streams: eprint must not overtake what print wrote before it.
def check_args(dir)
  src = <<~EGG
    uses args, io

    fn main(io: Io, args: Args) void {
        var i = 1
        while (i < args.len()) {
            io.print("[", args.get(i), "]")
            i = i + 1
        }
        io.eprint("to stderr ", args.len())
        if (@len(args.get(0)) == 0) {
            io.print("no name")
        }
        io.print("after")
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
  env = File.join(dir, "args_env.egg")
  File.write(env, <<~EGG)
    uses args, io

    fn main(io: Io, args: Args) void {
        io.print("[", args.env("EGG_TEST_VALUE") orelse "unset", "]")
        io.print("[", args.env("EGG_TEST_EMPTY") orelse "unset", "]")
        io.print(args.env("EGG_TEST_MISSING") orelse "unset")
        io.print(args.env("EGG_TEST=VALUE") orelse "no name")
        io.print(args.env("") orelse "no name")
        io.print(args.env("EGG\\0X") orelse "no name")
    }
  EGG
  out, err, status = Open3.capture3({ "EGG_TEST_VALUE" => "héllo, world", "EGG_TEST_EMPTY" => "", "EGG_TEST_MISSING" => nil }, *eggc_command, "run", env)
  got = out.lines.map(&:chomp)
  report(status.success? && got == ["[héllo, world]", "[]", "unset", "no name", "no name", "no name"], "args.env reads the environment", "#{got.inspect} #{err}")
  order = File.join(dir, "args_order.egg")
  File.write(order, <<~EGG)
    uses io

    fn main(io: Io) void {
        io.print("first")
        io.eprint("second")
        io.print("third")
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

    fn main(io: Io, a: Allocator) !void {
        var line: Buf(u8) = .empty
        defer a.free(line)
        while (try io.read_line(a, &line)) {
            io.print("[", line, "]")
        }
        io.print("end ", @len(line))
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

    fn main(io: Io, a: Allocator) !void {
        const data = try io.read_all(a)
        defer a.free(data)
        var sum = 0
        for (data) |b| {
            sum = sum + @as(i64, b)
        }
        io.print(@len(data), " ", sum)
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

    fn main(io: Io, a: Allocator) !void {
        io.print("name?")
        var line: Buf(u8) = .empty
        defer a.free(line)
        if (try io.read_line(a, &line)) {
            io.print("hello ", line)
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

# Paths and arguments are UTF-8 on every system: Windows would otherwise
# read them in its ANSI code page, whatever that is on the machine.
def check_utf8(dir)
  work = File.join(dir, "utf8")
  FileUtils.mkdir_p(work)
  File.binwrite(File.join(work, "读.txt"), "你好")
  path = File.join(work, "utf8.egg")
  File.write(path, <<~EGG)
    uses alloc, args, fs, io

    fn main(io: Io, args: Args, files: Fs, a: Allocator) !void {
        const b = try files.read(a, "读.txt")
        defer a.free(b)
        try files.write("写.txt", b)
        const c = try files.read(a, args.get(1))
        defer a.free(c)
        io.print(@len(args.get(1)), " ", @len(c))
        try files.write(args.get(2), args.get(1))
    }
  EGG
  exe = File.join(work, "utf8")
  _, status = Open3.capture2e(*eggc_command, "build", path, "-o", exe)
  return report(false, "build utf8", "failed") unless status.success?
  out, err, status = Open3.capture3(exe, "读.txt", "参数.txt", chdir: work)
  names = Dir.children(work).map { |n| (n.encoding == Encoding::US_ASCII ? n.dup.force_encoding("UTF-8") : n.encode("UTF-8")).unicode_normalize(:nfc) }
  ok = status.success? && out.strip == "#{"读.txt".bytesize} 6" && names.include?("写.txt") && names.include?("参数.txt") &&
       File.binread(File.join(work, "参数.txt")).force_encoding("UTF-8") == "读.txt"
  report(ok, "fs and args take UTF-8 names", "#{out.inspect}, #{names.inspect}, stderr: #{err}")
end

def check_lsp_capture
  uri = "file:///t/a.egg"
  src = <<~EGG
    fn pick() ?i64 {
        return 1
    }

    fn main() void {
        if (pick()) |v| {
            _ = v
        }
    }
  EGG
  doc = { "uri" => uri }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/definition", "params" => { "textDocument" => doc, "position" => { "line" => 6, "character" => 12 } } },
    { "id" => 3, "method" => "shutdown" },
    { "method" => "exit" }
  ]
  replies, diags, status, err = lsp_session(req)
  start = replies.dig(2, "result", "range", "start")
  ok = diags.first == [] && start == { "line" => 5, "character" => 17 } && status.success? && err.empty?
  report(ok, "lsp definition of a captured value", "#{start.inspect}, #{diags.first.inspect}, #{err}")
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

    fn main(io: Io) void {
        var p = Point{ .x = 1 }
        p.bump()
        for ([2]i64{ 1, 2 }) |v| {
            io.print(v + p.x)
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

    fn main(io: Io) void {
        const p = Pair(i64){ .a = 1, .b = 2 }
        const q: Pair(i64) = p.swap()
        io.print(q.a + area(.empty))
        for ([2]i64{ 3, 4 }) |_, i| {
            io.print(i)
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
    { "id" => 8, "method" => "textDocument/definition", "params" => at.(31, 18) }, # i in io.print(i)
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
  report(hover == "fn main(io: Io) void  // uses io", "lsp hover shows capabilities despite E130", hover.inspect)
  at = ->(id) { replies.dig(id, "result", "contents", "value").to_s.lines[1].to_s.strip }
  report(at.(4) == "extern fn toupper(c: i32) i32  // allow unsafe" && at.(5) == "fn upper(b: u8) u8  // allow unsafe",
         "lsp hover marks extern fns and unsafe files", [at.(4), at.(5)].inspect)
  d = diags[1]&.first
  ok = d && d["code"] == "E130" && d["range"]["start"] == { "line" => 0, "character" => 0 } && d["message"].include?("lib/quiet_print.egg:3:8: ")
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

    fn main(io: Io) void {
        var x = 1
        const p = &x
        defer io.print(p.* + 1)
        io.print(p == null)
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

    fn main(io: Io) void {
        var total = 0
        total = add(total, 2)
        io.print(total + @len("x"))
    }
  EGG
  doc = { "uri" => uri }
  at = ->(line, ch) { { "textDocument" => doc, "position" => { "line" => line, "character" => ch } } }
  edit = ->(text) { { "method" => "textDocument/didChange", "params" => { "textDocument" => doc, "contentChanges" => [{ "text" => text }] } } }
  req = [
    { "id" => 1, "method" => "initialize", "params" => {} },
    { "method" => "textDocument/didOpen", "params" => { "textDocument" => doc.merge("text" => src) } },
    { "id" => 2, "method" => "textDocument/definition", "params" => at.(8, 13) },  # add( in main
    { "id" => 3, "method" => "textDocument/definition", "params" => at.(9, 14) },  # total in io.print
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
  report(hover.(12) == "fn main(io: Io) void  // uses io", "lsp hover shows the capabilities a function uses", hover.(12).inspect)
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

# Packages through eggc --pkg: a package's entry and its parts, a package
# importing another, its root, and the flag's mistakes.
def check_packages(dir)
  pkg = File.join(ROOT, "test", "pkg")
  main = File.join(pkg, "app", "main.egg")
  pkgs = { "greet" => File.join(pkg, "greet"), "shout" => File.join(pkg, "shout") }
  check_program("pkg/app/main.egg", File.read(main), dir, main, pkgs: pkgs)
  check_program("pkg/app/main.egg -g", File.read(main), dir, main, debug: true, pkgs: pkgs)
  eggc = eggc_command
  out, err, st = Open3.capture3(*eggc, "run", main, "--pkg", "greet=#{pkgs["greet"]}", "--pkg=shout=#{pkgs["shout"]}")
  report(st.success? && out.lines.first == "hello\n", "eggc run --pkg NAME=DIR and --pkg=NAME=DIR", "#{out}#{err}")
  r = Egg.compile_to_c(File.read(main), main, pkgs: { "greet" => pkgs["greet"] })
  d = r.diagnostics.first
  ok = d && d.code == "E129" && d.message.include?("unknown module 'shout'") && d.message.include?("clutch add shout") && d.file == File.join(pkgs["greet"], "greet.egg")
  report(ok, "a package missing its own dependency is E129 in its file", d&.to_text("main.egg"))
  src = "const e = @import(\"escape\")\nfn main() void {\n}\n"
  r = Egg.compile_to_c(src, File.join(pkg, "app", "x.egg"), pkgs: { "escape" => File.join(pkg, "escape") })
  d = r.diagnostics.first
  report(d && d.code == "E129" && d.message.include?("outside this module's root"), "a package's file import stays in its directory", d&.to_text("x.egg"))
  # outer's directory holds the package inner: inner's files keep inner's
  # root even when outer reaches them by a file import.
  nest = File.join(dir, "nest")
  FileUtils.mkdir_p(File.join(nest, "inner"))
  File.write(File.join(nest, "secret.egg"), "fn f() void {\n}\n")
  File.write(File.join(nest, "outer.egg"), "const i = @import(\"inner/inner.egg\")\n")
  File.write(File.join(nest, "inner", "inner.egg"), "const s = @import(\"../secret.egg\")\n")
  src = "const o = @import(\"outer\")\nfn main() void {\n}\n"
  r = Egg.compile_to_c(src, File.join(dir, "x.egg"), pkgs: { "outer" => nest, "inner" => File.join(nest, "inner") })
  d = r.diagnostics.first
  ok = d && d.code == "E129" && d.message.include?("outside this module's root (#{File.join(nest, "inner")})")
  report(ok, "a package inside another's directory keeps its own root", d&.to_text("x.egg"))
  [
    [["--pkg", "std=#{pkg}"], "cannot name a package std"],
    [["--pkg", "greet=#{File.join(pkg, "nope")}"], "no such directory"],
    [["--pkg", "1x=#{pkg}"], "NAME a plain name"],
    [["--pkg", "greet"], "NAME a plain name"],
    [["--pkg", "a=#{pkg}", "--pkg", "a=#{pkg}"], "the package a twice"],
    [["--pkg"], "usage:"]
  ].each do |flags, want|
    _, err, st = Open3.capture3(*eggc, "check", main, *flags)
    report(st.exitstatus == 2 && err.include?(want), "eggc #{flags.join(" ")} is refused", err)
  end
end

# clutch in dir/clutch, with its own cache and index there.
def check_clutch(dir)
  have_git = begin
    Open3.capture3("git", "--version")[2].success?
  rescue SystemCallError
    false
  end
  return puts("  skip  clutch (no git)") unless have_git
  root = File.join(dir, "clutch")
  FileUtils.rm_rf(root)
  FileUtils.mkdir_p(root)
  env = { "CLUTCH_CACHE" => File.join(root, "cache"), "CLUTCH_INDEX" => File.join(root, "index"), "CLUTCH_OFFLINE" => nil,
          "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }
  clutch = ->(at, *args, extra: {}) { Open3.capture3(env.merge(extra), RbConfig.ruby, File.join(ROOT, "bin", "clutch"), *args, chdir: File.join(root, at)) }
  git = ->(at, *args) { Open3.capture3(env, "git", *args, chdir: File.join(root, at)) }
  edit = ->(file, from, to) { f = File.join(root, file); File.write(f, File.read(f).sub(from, to)) }

  out, err, st = clutch.(".", "new", "app")
  report(st.success? && File.file?(File.join(root, "app", "src", "main.egg")), "clutch new makes a program", "#{out}#{err}")
  out, err, st = clutch.("app", "run")
  report(st.success? && out == "hello from app\n", "clutch run runs a new program", "#{out}#{err}")

  # shout: a library in a git repository with three tagged releases, and
  # an index listing them.
  clutch.(".", "new", "--lib", "shout")
  git.("shout", "init", "-q")
  shas = {}
  %w[0.1.0 0.2.0 0.3.0].each do |v|
    edit.("shout/clutch.toml", /^version = .*$/, "version = \"#{v}\"")
    File.write(File.join(root, "shout", "src", "shout.egg"), "fn loud() str {\n    return \"v#{v}\"\n}\n")
    git.("shout", "add", "-A")
    git.("shout", "commit", "-qm", v)
    git.("shout", "tag", "v#{v}")
    shas[v] = git.("shout", "rev-parse", "HEAD")[0].strip
  end
  FileUtils.mkdir_p(File.join(root, "index", "packages"))
  repo = File.join(root, "shout")
  File.write(File.join(root, "index", "packages", "shout.toml"),
             "name = \"shout\"\nrepo = #{repo.inspect}\n" + shas.map { |v, sha| "\n[[release]]\nversion = \"#{v}\"\nref = \"#{sha}\"\n" }.join)
  File.write(File.join(root, "app", "src", "main.egg"), "uses io\n\nconst shout = @import(\"shout\")\n\nfn main(io: Io) void {\n    io.print(shout.loud())\n}\n")
  _, err, st = clutch.("app", "build")
  report(!st.success? && err.include?("unknown module 'shout'") && err.include?("clutch add shout"), "an undeclared package points at clutch add", err)
  out, err, st = clutch.("app", "add", "shout")
  toml = File.read(File.join(root, "app", "clutch.toml"))
  report(st.success? && toml.include?("shout = \"~> 0.3\"") && out.include?("added shout 0.3.0"), "clutch add takes the newest release's ~>", "#{out}#{err}#{toml}")
  out, err, st = clutch.("app", "run")
  report(st.success? && out == "v0.3.0\n", "clutch run builds with an index package", "#{out}#{err}")
  edit.("app/clutch.toml", /^shout = .*$/, "shout = \">= 0.2\"")
  out, err, st = clutch.("app", "run")
  report(st.success? && out == "v0.3.0\n", "the lock keeps a pin the manifest still accepts", "#{out}#{err}")
  out, err, st = clutch.("app", "update")
  report(st.success? && out == "shout 0.2.0\n", "clutch update chooses the lowest accepted release", "#{out}#{err}")
  # With no index to read: the lock and the cache are enough.
  out, err, st = clutch.("app", "run", extra: { "CLUTCH_OFFLINE" => "1", "CLUTCH_INDEX" => File.join(root, "no-index") })
  report(st.success? && out == "v0.2.0\n", "a locked build runs offline from the cache", "#{out}#{err}")
  _, err, st = clutch.("app", "update", "shuot")
  report(!st.success? && err.include?("shuot is not a package of app"), "clutch update of an unknown name", err)
  _, err, st = clutch.("app", "lock", "extra")
  report(st.exitstatus == 2 && err.include?("usage:"), "clutch lock takes no names", err)
  lock_file = File.join(root, "app", "clutch.lock")
  good_lock = File.read(lock_file)
  File.write(lock_file, good_lock.sub(/^ref = .*$/, "ref = \"abc\""))
  _, err, st = clutch.("app", "build")
  report(!st.success? && err.include?("needs git and a full commit SHA"), "a damaged clutch.lock is refused", err)
  File.write(lock_file, good_lock)
  lock = File.read(File.join(root, "app", "clutch.lock"))
  report(lock.include?("ref = \"#{shas["0.2.0"]}\"") && lock.include?("source = \"index\""), "clutch.lock pins the full SHA", lock)
  out, err, st = clutch.("app", "flags")
  want = ["--pkg", "shout=#{File.join(root, "cache", "git", "src", "shout-#{shas["0.2.0"][0, 12]}", "src")}"]
  report(st.success? && Shellwords.split(out) == want, "clutch flags gives eggc --pkg", "#{out}#{err}")

  edit.("app/clutch.toml", /^shout = .*$/, "shout = { git = #{repo.inspect}, ref = \"v0.1.0\" }")
  out, err, st = clutch.("app", "run")
  report(st.success? && out == "v0.1.0\n", "a git dependency at a tag", "#{out}#{err}")
  edit.("app/clutch.toml", /^shout = .*$/, "shout = { git = #{repo.inspect} }")
  out, err, st = clutch.("app", "run")
  report(st.success? && out == "v0.3.0\n", "a git dependency at its default branch", "#{out}#{err}")

  # greet: a library by path that needs shout = 0.1.0 itself.
  clutch.(".", "new", "--lib", "greet")
  File.write(File.join(root, "greet", "clutch.toml"), File.read(File.join(root, "greet", "clutch.toml")) + "shout = \"= 0.1.0\"\n")
  File.write(File.join(root, "greet", "src", "greet.egg"), "const shout = @import(\"shout\")\n\nfn hi() str {\n    return shout.loud()\n}\n")
  out, err, st = clutch.("greet", "check")
  report(st.success?, "clutch check checks a library with its dependencies", "#{out}#{err}")
  edit.("app/clutch.toml", /^shout = .*$/, "greet = { path = \"../greet\" }")
  File.write(File.join(root, "app", "src", "main.egg"), "uses io\n\nconst greet = @import(\"greet\")\n\nfn main(io: Io) void {\n    io.print(greet.hi())\n}\n")
  out, err, st = clutch.("app", "run")
  report(st.success? && out == "v0.1.0\n", "a path package's own dependency comes along", "#{out}#{err}")
  edit.("app/clutch.toml", /^greet = .*$/, "shout = \"~> 0.2\"\ngreet = { path = \"../greet\" }")
  _, err, st = clutch.("app", "build")
  report(!st.success? && err.include?("greet needs shout = 0.1.0, but shout is already 0.2.0"), "two versions of one package are refused", err)
  _, err, st = clutch.("app", "add", "zzz")
  report(!st.success? && err.include?("zzz is not in the index"), "clutch add of an unknown package", err)
  edit.("app/clutch.toml", /^shout = .*$/, "shout = \"~> 9.0\"")
  _, err, st = clutch.("app", "build")
  report(!st.success? && err.include?("no release it accepts (0.1.0, 0.2.0, 0.3.0)"), "a constraint no release meets", err)
  edit.("app/clutch.toml", /^shout = .*$/, "shout = 1")
  _, err, st = clutch.("app", "build")
  report(!st.success? && err.include?("clutch.toml: dependency shout: give a version"), "a malformed dependency", err)
  edit.("app/clutch.toml", /^shout = .*$/, "shout = \"\"")
  _, err, st = clutch.("app", "build")
  report(!st.success? && err.include?("an empty version constraint"), "an empty constraint is refused", err)

  check_clutch_publish(root, clutch, git, edit)
  check_clutch_test(root, clutch, git, edit)
end

# clutch test, dev-dependencies, and the tests as publish's gate.
def check_clutch_test(root, clutch, git, edit)
  clutch.(".", "new", "--lib", "tlib")
  tlib = File.join(root, "tlib")
  out, err, st = clutch.("tlib", "test")
  report(st.success? && out == "  ok    tlib\n1 passed, 0 failed\n", "clutch new --lib makes a test that passes", "#{out}#{err}")
  File.write(File.join(tlib, "test", "out.egg"), "uses io\n\nfn main(io: Io) void {\n    io.print(\"hi\")\n}\n")
  File.write(File.join(tlib, "test", "out.expected"), "hi\n")
  File.write(File.join(tlib, "test", "bad.egg"), "uses io\n\n// Not UTF-8 output, which the report shows as it is.\nfn main(io: Io) !void {\n    const b = [_]u8{ 255, 10 }\n    io.print(b[0..2])\n    return error.Bad\n}\n")
  out, err, st = clutch.("tlib", "test")
  report(st.exitstatus == 1 && out.include?("  FAIL  bad (exited with 1)") && out.include?("  ok    out") && out.include?("2 passed, 1 failed"), "clutch test runs every test/*.egg", "#{out}#{err}")
  out, err, st = clutch.("tlib", "test", "out", "tlib")
  report(st.success? && out == "  ok    out\n  ok    tlib\n2 passed, 0 failed\n", "clutch test NAME runs those tests", "#{out}#{err}")
  _, err, st = clutch.("tlib", "test", "nope")
  report(!st.success? && err.include?("no test nope (the tests: bad, out, tlib)"), "clutch test of an unknown test", err)
  File.write(File.join(tlib, "test", "out.expected"), "bye\n")
  out, err, st = clutch.("tlib", "test", "out")
  report(!st.success? && out.include?("FAIL  out (printed other than test/out.expected)") && out.include?("        hi"), "a test prints its .expected", "#{out}#{err}")
  File.delete(File.join(tlib, "test", "bad.egg"))
  File.write(File.join(tlib, "test", "out.expected"), "hi\n")

  # A dev-dependency: for the tests, not the package.
  out, err, st = clutch.("tlib", "add", "shout", "--dev")
  toml = File.read(File.join(tlib, "clutch.toml"))
  report(st.success? && toml.include?("[dev-dependencies]\nshout = \"~> 0.3\"") && out.include?("(for the tests)"), "clutch add --dev", "#{out}#{err}#{toml}")
  File.write(File.join(tlib, "test", "loud.egg"), "uses io\n\nconst shout = @import(\"shout\")\n\nfn main(io: Io) void {\n    io.print(shout.loud())\n}\n")
  File.write(File.join(tlib, "test", "loud.expected"), "v0.3.0\n")
  out, err, st = clutch.("tlib", "test", "loud")
  report(st.success?, "a test uses a dev-dependency", "#{out}#{err}")
  out, err, st = clutch.("tlib", "lock")
  report(st.success? && out == "shout 0.3.0 (dev)\n", "clutch lock marks a dev-dependency", "#{out}#{err}")
  out, err, st = clutch.("tlib", "flags")
  report(st.success? && out.strip.empty?, "clutch flags leaves the dev-dependencies out", "#{out}#{err}")
  src = File.join(tlib, "src", "tlib.egg")
  good = File.read(src)
  File.write(src, "const shout = @import(\"shout\")\n\n" + good)
  _, err, st = clutch.("tlib", "check")
  report(!st.success? && err.include?("unknown module 'shout'"), "the package cannot use a dev-dependency", err)
  File.write(src, good)
  File.write(File.join(tlib, "clutch.toml"), File.read(File.join(tlib, "clutch.toml")).sub("[dependencies]\n", "[dependencies]\nshout = \"~> 0.3\"\n"))
  _, err, st = clutch.("tlib", "check")
  report(!st.success? && err.include?("shout is in both [dependencies] and [dev-dependencies]"), "a package in both tables", err)
  manifest = File.read(File.join(tlib, "clutch.toml"))
  File.write(File.join(tlib, "clutch.toml"), "dev-dependencies = false\n" + manifest.sub(/\[dev-dependencies\]\n.*\n/, ""))
  _, err, st = clutch.("tlib", "check")
  report(!st.success? && err.include?("[dev-dependencies] must be a table"), "dev-dependencies that are not a table", err)
  File.write(File.join(tlib, "clutch.toml"), manifest)
  edit.("tlib/clutch.toml", /\[dependencies\]\nshout = .*\n/, "[dependencies]\n")
  out, err, st = clutch.("tlib", "remove", "shout")
  report(st.success? && !File.read(File.join(tlib, "clutch.toml")).include?("shout"), "clutch remove drops a dev-dependency", "#{out}#{err}")
  File.delete(File.join(tlib, "test", "loud.egg"))

  # publish runs the tests.
  git.("tlib", "init", "-q")
  git.("tlib", "remote", "add", "origin", tlib)
  File.write(File.join(tlib, "test", "out.expected"), "bye\n")
  git.("tlib", "add", "-A")
  git.("tlib", "commit", "-qm", "failing")
  out, err, st = clutch.("tlib", "publish", "--dry-run")
  report(!st.success? && err.include?("does not pass clutch test") && out.include?("FAIL  out"), "clutch publish runs clutch test first", "#{out}#{err}")
  File.write(File.join(tlib, "test", "out.expected"), "hi\n")
  git.("tlib", "commit", "-qam", "passing")
  out, err, st = clutch.("tlib", "publish", "--dry-run")
  report(st.success? && out.include?("  ok    out") && out.include?("name = \"tlib\""), "clutch publish of a package whose tests pass", "#{out}#{err}")
end

# clutch publish into the directory index under root.
def check_clutch_publish(root, clutch, git, edit)
  clutch.(".", "new", "--lib", "pub")
  pub = File.join(root, "pub")
  index_file = File.join(root, "index", "packages", "pub.toml")
  commit = ->(msg) { git.("pub", "add", "-A"); git.("pub", "commit", "-qm", msg); git.("pub", "rev-parse", "HEAD")[0].strip }
  _, err, st = clutch.("pub", "publish")
  report(!st.success? && err.include?("is not in a git repository"), "clutch publish needs a git repository", err)
  git.("pub", "init", "-q")
  _, err, st = clutch.("pub", "publish")
  report(!st.success? && err.include?("uncommitted changes"), "clutch publish needs a clean tree", err)
  sha1 = commit.("0.1.0")
  _, err, st = clutch.("pub", "publish")
  report(!st.success? && err.include?("no remote origin"), "clutch publish needs a repository to name", err)
  out, err, st = clutch.("pub", "publish", "--repo", pub, "--dry-run")
  report(st.success? && out.include?("ref = \"#{sha1}\"") && !File.exist?(index_file), "clutch publish --dry-run writes nothing", "#{out}#{err}")
  git.("pub", "remote", "add", "origin", pub)
  out, err, st = clutch.("pub", "publish")
  want = "name = \"pub\"\nrepo = #{pub.inspect}\n\n[[release]]\nversion = \"0.1.0\"\nref = \"#{sha1}\"\n"
  report(st.success? && File.read(index_file) == want, "clutch publish adds a package to the index", "#{out}#{err}")
  _, err, st = clutch.("pub", "publish")
  report(!st.success? && err.include?("pub 0.1.0 is already in the index"), "a release is published once", err)
  edit.("pub/clutch.toml", /^version = .*$/, "version = \"0.3.0\"")
  sha3 = commit.("0.3.0")
  out, err, st = clutch.("pub", "publish")
  report(st.success?, "clutch publish adds 0.3.0", "#{out}#{err}")
  edit.("pub/clutch.toml", /^version = .*$/, "version = \"0.2.0\"")
  sha2 = commit.("0.2.0")
  out, err, st = clutch.("pub", "publish")
  order = File.read(index_file).scan(/^ref = "(\h+)"/).flatten
  report(st.success? && order == [sha1, sha2, sha3], "releases stay oldest first", "#{out}#{err}#{File.read(index_file)}")
  edit.("pub/clutch.toml", /^version = .*$/, "version = \"0.4.0\"")
  commit.("0.4.0")
  _, err, st = clutch.("pub", "publish", "--repo", File.join(root, "shout"))
  report(!st.success? && err.include?("push") && err.include?("first"), "clutch publish needs the commit in the repository", err)
  File.write(File.join(pub, "src", "pub.egg"), "fn broken() i64 {\n    return \"no\"\n}\n")
  commit.("broken")
  _, err, st = clutch.("pub", "publish")
  report(!st.success? && err.include?("does not pass clutch check") && !File.read(index_file).include?("0.4.0"), "clutch publish runs clutch check first", err)
  report(err.include?(File.join(pub, "src", "pub.egg")) && !err.include?("clutch-publish-") && !err.include?("wrote clutch.lock"), "clutch publish's check names the package's own files", err)
  _, err, st = clutch.("pub", "publish", "--dry-run", extra: { "CLUTCH_EGGC" => File.join(root, "no-eggc") })
  report(st.exitstatus == 1 && err.include?("clutch: cannot run eggc"), "clutch publish without an eggc to run", err)
  out, _, st = git.("pub", "status", "--porcelain", "--ignored")
  report(st.success? && out.empty?, "clutch publish writes nothing into the package", out)
  # A file the repository does not have (ignored here) is not checked.
  File.write(File.join(pub, ".gitignore"), "/src/pub.egg\n/build/\n/clutch.lock\n")
  git.("pub", "rm", "-q", "--cached", "src/pub.egg")
  File.write(File.join(pub, "src", "pub.egg"), "fn ok() i64 {\n    return 1\n}\n")
  commit.("ignored")
  _, err, st = clutch.("pub", "publish", "--dry-run")
  report(!st.success? && err.include?("has no src/pub.egg"), "clutch publish checks the release, not the work tree", err)
  git.("pub", "reset", "-q", "--hard", "HEAD~1")
  File.write(index_file, File.read(index_file).sub(/^repo = .*$/, "repo = \"https://example.com/other\""))
  _, err, st = clutch.("pub", "publish", "--dry-run")
  report(!st.success? && err.include?("a name belongs to the package that first took it"), "a name in the index belongs to its repository", err)
  File.write(File.join(pub, "clutch.toml"), File.read(File.join(pub, "clutch.toml")) + "greet = { path = \"../greet\" }\n")
  commit.("path dep")
  _, err, st = clutch.("pub", "publish", "--dry-run")
  report(!st.success? && err.include?("depends on greet by path"), "a package with a path dependency is not published", err)
  _, err, st = clutch.("pub", "check", extra: { "CLUTCH_EGGC" => File.join(root, "no-eggc") })
  report(st.exitstatus == 1 && err.include?("clutch: cannot run eggc"), "clutch check without an eggc to run", err)
end

# A locale whose decimal point is a comma, set by C code: parse_float and
# printing floats still use '.'. Skipped where no such locale is installed.
def check_locale(dir)
  numeric = RUBY_PLATFORM.include?("linux") ? 1 : 4  # LC_NUMERIC: glibc 1; macOS and Windows 4
  src = <<~EGG
    uses io, alloc
    allow unsafe

    const text = @import("std/text")

    extern fn setlocale(category: i32, name: *u8) *u8

    fn main(io: Io, a: Allocator) void {
        const names = [_]str{ "de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8", "de-DE", "German" }
        for (names) |n| {
            if (@intFromPtr(setlocale(#{numeric}, a.cstr(n))) != 0) {
                io.print(text.parse_float("1.5") orelse -1)
                io.print(text.parse_float("-2.25e2") orelse -1)
                var b: Buf(u8) = .empty
                defer a.free(b)
                a.append_float(&b, 0.1 + 0.2)
                io.print(b)
                return
            }
        }
        io.print("skip")
    }
  EGG
  r = Egg.compile_to_c(src, nil)
  return report(false, "locale", r.diagnostics.map { |d| d.to_text("locale.egg") }.join("\n")) unless r.diagnostics.empty?
  base = File.join(dir, "locale")
  File.write("#{base}.c", r.c_source)
  _, err, st = Open3.capture3(CC, *CFLAGS, "-o", base, "#{base}.c")
  return report(false, "locale", err) unless st.success?
  out, err, st = Open3.capture3(base)
  return puts("  skip  a comma decimal point (no such locale)") if out == "skip\n"
  report(st.success? && out == "1.5\n-225.0\n0.30000000000000004\n", "a comma decimal point leaves parse_float and printing alone", "#{out}#{err}")
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

  puts "packages"
  check_packages(dir)
  check_clutch(dir)

  puts "lsp"
  check_lsp_packages(dir)
  check_lsp
  check_lsp_generics
  check_lsp_v1
  check_lsp_catch
  check_lsp_alias
  check_lsp_capture
  check_fs_errors(dir)
  check_file_errors(dir)
  check_net(dir)
  check_threads(dir)
  check_rendezvous(dir)
  check_http_server(dir)
  check_args(dir)
  check_restrict
  check_locale(dir)
  check_stdin(dir)
  check_utf8(dir)
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
