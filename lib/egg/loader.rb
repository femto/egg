# Module loader: the root file plus every file it imports, merged into one
# Program for the checker.
#
# `const m = @import("m.egg")` names another file, relative to the
# importing one. Each file is loaded once however often it is imported,
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
  # allows: UsesItem list from `allow unsafe`; links: from `link "name"`
  ModuleInfo = Struct.new(:prefix, :path, :file, :uses, :aliases, :names, :imports, :allows, :links)

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
      root = add_module("", @path, nil, root_prog)
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
      unless imp.path.end_with?(".egg")
        fail_at(mod, imp, "E129", "an import names an .egg file, found \"#{imp.path}\"")
      end
      base_dir = mod.path.nil? ? Dir.pwd : File.dirname(mod.path)
      abs = File.expand_path(imp.path, base_dir)
      found = @by_path[abs]
      return found unless found.nil?
      unless File.file?(abs)
        fail_at(mod, imp, "E129", "cannot find \"#{imp.path}\" (looked for #{abs})")
      end
      file = display_path(mod, imp.path)
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
      target = add_module(unique_prefix(abs), abs, file, prog)
      queue << [target, prog]
      target
    end

    def add_module(prefix, path, file, prog)
      names = prog.funcs.map(&:name) + prog.types.map(&:name)
      mod = ModuleInfo.new(prefix, path, file, prog.uses, {}, names, prog.imports, prog.allows || [], prog.links || [])
      @modules[prefix] = mod
      @by_path[path] = mod unless path.nil?
      prog.types.each do |d|
        d.name = Egg.qualify(mod, d.name)
        d.mod = prefix
        d.methods.each { |m| m.mod = prefix }
        @types << d
      end
      prog.funcs.each do |f|
        f.name = Egg.qualify(mod, f.name)
        f.mod = prefix
        # Methods of a type function's struct.
        st = !f.body.nil? && f.body.stmts.length == 1 && f.body.stmts[0].is_a?(Return) ? f.body.stmts[0].value : nil
        st.methods.each { |m| m.mod = prefix } if st.is_a?(StructTypeExpr)
        @funcs << f
      end
      mod
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
    # absolute import path is kept as it is.
    def display_path(mod, rel)
      return Egg.normalize_path(rel) if rel.start_with?("/")
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
