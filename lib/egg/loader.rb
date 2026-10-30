# Module loader: the root file plus every file it imports, merged into one
# Program for the checker.
#
# `const m = @import("m.egg")` names another file, relative to the
# importing one; `@import("std/map")`, without `.egg`, names a module:
# std/map.egg in the standard library's directory. A file import may not
# leave its module's root: the root file's directory for the program, the
# library's directory for std files, so a module is a self-contained tree
# (as in Zig). Each file is loaded once however often it is imported,
# and imports may form cycles (names are resolved after everything is
# loaded, as in Zig).
#
# Every module gets a prefix: "" for the root file, the file's base name
# for the others ("m", or "m_2" if two files share a name). The top-level
# functions and types of an imported module are renamed to "m.f" and
# "m.Point", so the merged program has one flat namespace and diagnostics
# read the way the code is written. Inside a module, the checker resolves
# an unqualified name against that module first (ModuleInfo#names).

module Egg
  # prefix: "" for the root; path: absolute path (nil for an unsaved root);
  # file: path shown in diagnostics (nil for the root); uses: UsesItem list;
  # aliases: import name -> prefix of the module it names;
  # names: top-level names declared in the module (unqualified);
  # allows: UsesItem list from `allow unsafe`; links: from `link "name"`;
  # root: the directory its file imports must stay inside
  ModuleInfo = Struct.new(:prefix, :path, :file, :uses, :aliases, :names, :imports, :allows, :links, :root)

  # The standard library: EGG_STD (an empty one counts as unset), or
  # lib/std beside the compiler's lib/egg (as Zig keeps it in lib/std).
  STD_ROOT = File.expand_path(ENV["EGG_STD"].to_s.empty? ? File.join(__dir__, "../std") : ENV["EGG_STD"])

  # The global name of `name` declared in module `mod`.
  def self.qualify(mod, name)
    mod.prefix.empty? ? name : "#{mod.prefix}.#{name}"
  end

  class Loader
    # root: the root file already parsed (by a tool that also needs its
    # AST), or nil to parse src here
    def initialize(src, path, root = nil)
      @src = src
      @root = root
      @path = path.nil? ? nil : File.expand_path(path)
      @display = path
      @modules = {}   # prefix -> ModuleInfo
      @by_path = {}   # absolute path -> ModuleInfo
      @funcs = []
      @types = []
    end

    def load
      root_prog = @root || Parser.new(Lexer.new(@src).tokenize).parse_program
      root = add_module("", @path, nil, root_prog, @path.nil? ? Dir.pwd : File.dirname(@path))
      queue = [[root, root_prog]]
      until queue.empty?
        mod, prog = queue.shift
        prog.imports.each do |imp|
          target = resolve_import(mod, imp, queue)
          if mod.aliases.key?(imp.name) || mod.names.include?(imp.name)
            fail_at(mod, imp, "E106", "'#{imp.name}' is declared more than once")
          end
          mod.aliases[imp.name] = target.prefix
        end
      end
      Program.new(@funcs, @types, root.uses, root.imports, @modules, root.allows, root.links)
    end

    private

    def resolve_import(mod, imp, queue)
      # A path is text: "\xff" would break the path checks and the
      # diagnostics that quote it.
      unless imp.path.valid_encoding?
        fail_at(mod, imp, "E129", "an import path must be valid UTF-8; this one has a byte that is not (from a \\xNN escape)")
      end
      if imp.path.end_with?(".egg")
        # A file of the same module, relative to the importing file.
        base_dir = mod.path.nil? ? Dir.pwd : File.dirname(mod.path)
        abs = File.expand_path(imp.path, base_dir)
        root = mod.root
        fail_outside(mod, imp, root) unless inside?(abs, root)
        file = display_path(mod, imp.path)
      else
        abs, root, file = module_path(mod, imp)
      end
      found = @by_path[abs]
      return found unless found.nil?
      unless File.file?(abs)
        fail_at(mod, imp, "E129", "cannot find \"#{imp.path}\" (looked for #{abs})")
      end
      # A symlink under the root may lead out of it: check where it goes.
      unless inside?(real(abs), real(root))
        fail_outside(mod, imp, root)
      end
      src = begin
        File.read(abs)
      rescue SystemCallError => e
        fail_at(mod, imp, "E129", "cannot read \"#{imp.path}\": #{e.message}")
      end
      prog = begin
        Parser.new(Lexer.new(src).tokenize).parse_program
      rescue CompileError => e
        e.diagnostic.file = file
        raise e
      end
      target = add_module(unique_prefix(abs), abs, file, prog, root)
      queue << [target, prog]
      target
    end

    def add_module(prefix, path, file, prog, root)
      names = prog.funcs.map(&:name) + prog.types.map(&:name)
      mod = ModuleInfo.new(prefix, path, file, prog.uses, {}, names, prog.imports, prog.allows || [], prog.links || [], root)
      @modules[prefix] = mod
      @by_path[path] = mod unless path.nil?
      prog.types.each do |d|
        d.name = Egg.qualify(mod, d.name)
        d.mod = prefix
        d.fns.each { |m| m.mod = prefix }
        @types << d
      end
      prog.funcs.each do |f|
        f.name = Egg.qualify(mod, f.name)
        f.mod = prefix
        # Methods of a type function's struct.
        st = !f.body.nil? && f.body.stmts.length == 1 && f.body.stmts[0].is_a?(Return) ? f.body.stmts[0].value : nil
        st.fns.each { |m| m.mod = prefix } if st.is_a?(StructTypeExpr)
        @funcs << f
      end
      mod
    end

    # "std/map" -> the file map.egg of the library, its root, and the
    # path shown in diagnostics (the file's own, so it can be opened);
    # "std/a/b" is a/b.egg and "std" alone is std.egg. Only std is known
    # so far.
    def module_path(mod, imp)
      parts = imp.path.split("/", -1)
      if parts.empty? || parts.any? { |p| !p.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) }
        fail_at(mod, imp, "E129", "\"#{imp.path}\" is neither a file (name.egg) nor a module name such as \"std/map\"")
      end
      unless parts[0] == "std"
        fail_at(mod, imp, "E129", "unknown module '#{parts[0]}': the modules are std and its parts (\"std/map\"); a file of this program ends in .egg")
      end
      rest = parts.length == 1 ? ["std"] : parts.drop(1)
      abs = File.join(STD_ROOT, *rest) + ".egg"
      [abs, STD_ROOT, abs]
    end

    def inside?(abs, root)
      root == "/" || abs.start_with?("#{root.chomp('/')}/")
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      path
    end

    def fail_outside(mod, imp, root)
      fail_at(mod, imp, "E129", "\"#{imp.path}\" is outside this module's root (#{root}); a file can import only files under it, and other modules by name, such as @import(\"std/map\")")
    end

    def unique_prefix(abs)
      base = File.basename(abs, ".egg").gsub(/[^A-Za-z0-9_]/, "_")
      base = "m_#{base}" if base.empty? || (base[0] >= "0" && base[0] <= "9")
      prefix = base
      n = 2
      while @modules.key?(prefix)
        prefix = "#{base}_#{n}"
        n += 1
      end
      prefix
    end

    # The imported file's path as reached from the root file's path, so a
    # diagnostic in it points at the right file from the user's shell. An
    # absolute import path, "/x" or Windows's "D:/x", is kept as it is.
    def display_path(mod, rel)
      return Egg.normalize_path(rel) if rel.start_with?("/") || rel.match?(/\A[A-Za-z]:[\/\\]/)
      from = mod.file || @display
      dir = from.nil? ? "" : File.dirname(from)
      Egg.normalize_path(dir == "." || dir.empty? ? rel : "#{dir}/#{rel}")
    end

    def fail_at(mod, imp, code, msg)
      raise CompileError.new(Diagnostic.new(code, msg, imp.line, imp.col, mod.file))
    end
  end

  # "a/./b/../c.egg" -> "a/c.egg" (no File/Pathname magic, to stay in the
  # Spinel subset).
  def self.normalize_path(path)
    abs = path.start_with?("/")
    parts = []
    path.split("/").each do |p|
      next if p.empty? || p == "."
      if p == ".." && !parts.empty? && parts.last != ".."
        parts.pop
      elsif p == ".." && abs
        next
      else
        parts << p
      end
    end
    (abs ? "/" : "") + parts.join("/")
  end
end
