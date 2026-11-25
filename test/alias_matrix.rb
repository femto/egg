# Aliases of owned elements, every way round (ruby test/alias_matrix.rb).
#
# An element of a container (a MultiArrayList column, a Buf, an array) is
# held by a for loop, a switch capture, a read-only borrow or slice,
# reached directly, through a local slice of the container, or through a
# slice with two sources; and it is changed (@take, @replace, a function
# taking it inout, a field of it) directly, through a writable local slice,
# or through a named borrow of the element. Each program whose element
# owns memory must be rejected: the holder would read freed memory (or see
# its element change under it). The same shapes over a plain i64 element
# must compile, or be rejected only by the slice rules every element obeys
# (E149: no write while a read-only view is in use; E105: a column's
# element is passed as inout through a writable column).
#
# Programs that compile are built and run (with AddressSanitizer where the
# C compiler has it) and must run cleanly. Exits 1 on any failure.

require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/egg"

Encoding.default_external = Encoding::UTF_8

module AliasMatrix
  HEAD = <<~E
    uses alloc, io

    const U = union(enum) { text: Buf(u8), none }
    const S = struct { b: Buf(u8), k: i64 }
    const R = struct { b: Buf(u8), u: U, st: S, n: i64 }

    fn drop(a: Allocator, inout x: Buf(u8)) void {
        a.free(@take(&x))
    }

    fn dropu(a: Allocator, inout x: U) void {
        a.free(@replace(&x, U.none))
    }

    fn drops(a: Allocator, inout x: S) void {
        a.free(@take(&x.b))
    }

    fn bump(inout x: i64) void {
        x = x + 1
    }

    fn no() bool {
        return false
    }

  E

  INIT = { "b" => 'a.concat("hi", "")', "u" => 'U{ .text = a.concat("yo", "") }', "st" => 'S{ .b = a.concat("st", ""), .k = 1 }', "n" => "1" }
  TY = { "b" => "Buf(u8)", "u" => "U", "st" => "S", "n" => "i64" }

  # A container kind: names of the two containers for element kind k, their
  # declarations, the view (a slice-like expression), and the writable slice.
  def self.cont(ck, k, idx)
    name = "#{k}#{idx}"
    case ck
    when "col"
      decl = ->(_mut) { "    var l#{idx}: MultiArrayList(R) = .empty\n    defer a.free(l#{idx})\n    l#{idx}.append(a, R{ .b = #{INIT["b"]}, .u = #{INIT["u"]}, .st = #{INIT["st"]}, .n = 1 })\n" }
      { var: "l#{idx}", decl: decl, view: "l#{idx}.items(.#{k})", slice: "l#{idx}.items(.#{k})", wslice: "&l#{idx}.items(.#{k})" }
    when "buf"
      decl = ->(_mut) { "    var #{name}: Buf(#{TY[k]}) = .empty\n" + "    defer a.free(#{name})\n" + "    a.push(&#{name}, #{INIT[k]})\n" }
      { var: name, decl: decl, view: name, slice: "#{name}[0..]", wslice: "&#{name}[0..]" }
    when "arr"
      decl = ->(mut) { "    #{mut ? "var" : "const"} #{name} = [1]#{TY[k]}{ #{INIT[k]} }\n" + (k == "n" ? "" : "    defer a.free(#{name})\n") }
      { var: name, decl: decl, view: name, slice: "#{name}[0..]", wslice: "&#{name}[0..]" }
    end
  end

  OPS = {
    "b" => { "take" => ->(p) { "a.free(@take(&#{p}))" }, "inout" => ->(p) { "drop(a, &#{p})" } },
    "u" => { "take" => ->(p) { "a.free(@replace(&#{p}, U.none))" }, "inout" => ->(p) { "dropu(a, &#{p})" } },
    "st" => { "take" => ->(p) { "a.free(@take(&#{p}.b))" }, "inout" => ->(p) { "drops(a, &#{p})" }, "field" => ->(p) { "drop(a, &#{p}.b)" } },
    "n" => { "bump" => ->(p) { "bump(&#{p})" } },
  }
  USE = { "b" => ->(x) { "io.print(#{x})" }, "st" => ->(x) { "io.print(#{x}.b)" }, "n" => ->(x) { "io.print(#{x})" } }

  def self.each_program
  %w[col buf arr].each do |ck|
    %w[b u st n].each do |k|
      c1 = cont(ck, k, 1)
      c2 = cont(ck, k, 2)
      # holders: [name, alias, code given mutation lines]
      hal = {
        "direct" => ["", c1[:view], c1],
        "salias" => ["    const hc = #{c1[:slice]}\n", "hc", c1],
        "multi" => ["    const flag = no()\n    const hc = if (flag) #{c1[:slice]} else #{c2[:slice]}\n", "hc", c2],
      }
      hal.each do |hk, (hdecl, h, target)|
        kinds = k == "u" ? %w[switch sborrow] : (k == "n" ? %w[loop] : %w[loop cborrow cslice])
        kinds.each do |kind|
          next if kind == "sborrow" && hk == "multi"
          # mutation aliases on the container the holder views
          mal = {
            "direct" => ["", "#{target[:view]}[0]"],
            "slice" => ["inout c = #{target[:wslice]}\n", "c[0]"],
            "borrow" => ["inout c = #{target[:wslice]}\ninout e = &c[0]\n", "e"],
          }
          mal.each do |mk, (mdecl, place)|
            OPS[k].each do |ok, op|
              mut = mdecl + op.(place) + "\n"
              ind = ->(s, d) { s.lines.map { |l| (" " * d) + l }.join }
              body = case kind
                     when "loop" then "    for (#{h}) |x| {\n#{ind.(mut, 8)}        #{USE[k].("x")}\n    }\n"
                     when "cborrow" then "    const r = &#{h}[0]\n    if (true) {\n#{ind.(mut, 8)}    }\n    #{USE[k].("r")}\n"
                     when "cslice" then "    const v = #{h == c1[:view] ? c1[:slice] : h}\n    if (true) {\n#{ind.(mut, 8)}    }\n    #{USE[k].("v[0]")}\n"
                     when "switch" then "    switch (#{h}[0]) {\n        .text => |t| {\n#{ind.(mut, 12)}            io.print(t)\n        }\n        .none => {}\n    }\n"
                     when "sborrow" then "    const hb = &#{h}[0]\n    switch (hb) {\n        .text => |t| {\n#{ind.(mut, 12)}            io.print(t)\n        }\n        .none => {}\n    }\n"
                     end
              body = hdecl + body
              mutated = [c1, c2].select { |c| mut.include?(c[:var]) }.map { |c| c[:var] }
              used = [c1, c2].select { |c| body.include?(c[:var]) }
              setup = used.map { |c| c[:decl].(mutated.include?(c[:var])) }.uniq.join
              prog = HEAD + "fn main(io: Io, a: Allocator) void {\n" + setup + body + "}\n"
              yield "#{k == "n" ? "plain" : "owned"}_#{ck}_#{k}_#{hk}_#{kind}_#{mk}_#{ok}", prog
            end
          end
        end
      end
    end
  end
  end
end

PLAIN_OK = %w[E149 E105].freeze
CC = ENV["CC"] || "cc"
failures = []
counts = Hash.new(0)
Dir.mktmpdir do |dir|
  asan = Open3.capture2e(CC, "-fsanitize=address", "-x", "c", "-o", File.join(dir, "probe"), "-", stdin_data: "int main(void){return 0;}\n")[1].success?
  AliasMatrix.each_program do |name, src|
    r = Egg.compile_to_c(src, "#{name}.egg")
    codes = r.diagnostics.map(&:code).uniq
    owned = name.start_with?("owned")
    unless codes.empty?
      if owned || (codes - PLAIN_OK).empty?
        counts[owned ? :owned_rejected : :plain_rejected] += 1
      else
        failures << "#{name}: rejected with #{codes.join(", ")}: #{r.diagnostics.first.message}"
      end
      next
    end
    if owned
      failures << "#{name}: accepted, but it changes an owned element something else holds"
      next
    end
    c = File.join(dir, "#{name}.c")
    bin = File.join(dir, name)
    File.write(c, r.c_source)
    flags = ["-std=c99", "-g"] + (asan ? ["-fsanitize=address"] : [])
    out, st = Open3.capture2e(CC, *flags, "-o", bin, c, *r.links.map { |l| "-l#{l}" })
    (failures << "#{name}: C compiler failed: #{out[0, 300]}"; next) unless st.success?
    out, st = Open3.capture2e(bin)
    if !st.success? || out.include?("AddressSanitizer")
      failures << "#{name}: #{out[/AddressSanitizer: [a-z-]+/] || "exit #{st.exitstatus}"}"
    else
      counts[:plain_ran] += 1
    end
  end
  puts "alias matrix: #{counts[:owned_rejected]} owned rejected, #{counts[:plain_ran]} plain ran#{asan ? " under ASan" : ""}, #{counts[:plain_rejected]} plain kept by the slice rules"
end
failures.each { |f| puts "  FAIL  #{f}" }
exit(failures.empty? ? 0 : 1)
