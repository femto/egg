require_relative "egg/diagnostic"
require_relative "egg/lexer"
require_relative "egg/ast"
require_relative "egg/parser"
require_relative "egg/loader"
require_relative "egg/typecheck"
require_relative "egg/caps"
require_relative "egg/own"
require_relative "egg/codegen_c"

module Egg
  VERSION = "0.0.2"

  # Result of compiling one source file to C.
  # Exactly one of c_source / diagnostics is meaningful. links: the C
  # libraries the program's files name with `link`, each once, to pass
  # to the C compiler as -l<name>.
  CompileResult = Struct.new(:c_source, :diagnostics, :links)

  # Result of checking: the checker (for codegen and tools), the capability
  # check, and every diagnostic.
  CheckResult = Struct.new(:program, :checker, :caps, :diagnostics)

  # Load src (the file at path; imports are found relative to it, or to the
  # current directory when path is nil), type-check it and check its
  # capabilities and who owns each buffer. Raises CompileError on a lexing, parsing or import error.
  # root: src already parsed, for tools that read the annotated AST.
  def self.check(src, path = nil, root = nil)
    program = Loader.new(src, path, root).load
    checker = TypeChecker.new(program)
    diags = checker.check
    caps = CapChecker.new(checker)
    # Capabilities and ownership are checked only on a well-typed program.
    diags = caps.check + OwnershipChecker.new(checker).check if diags.empty?
    CheckResult.new(program, checker, caps, diags)
  end

  # With debug, the C carries #line directives pointing at the .egg files
  # (for debug builds); it needs the path, and is ignored without one.
  def self.compile_to_c(src, path = nil, debug: false)
    r = check(src, path)
    return CompileResult.new(nil, r.diagnostics) unless r.diagnostics.empty?
    c = CodegenC.new(r.program, r.checker, debug && !path.nil? ? File.expand_path(path) : nil).generate
    CompileResult.new(c, [], links(r.program))
  rescue CompileError => e
    CompileResult.new(nil, [e.diagnostic])
  end

  # The libraries every loaded file links, in load order, each once.
  def self.links(program)
    names = []
    program.modules.each_value do |m|
      m.links.each { |l| names << l.name unless names.include?(l.name) }
    end
    names
  end
end
