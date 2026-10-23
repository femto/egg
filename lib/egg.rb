require_relative "egg/diagnostic"
require_relative "egg/lexer"
require_relative "egg/ast"
require_relative "egg/parser"
require_relative "egg/loader"
require_relative "egg/typecheck"
require_relative "egg/caps"
require_relative "egg/codegen_c"

module Egg
  VERSION = "0.0.2"

  # Result of compiling one source file to C.
  # Exactly one of c_source / diagnostics is meaningful.
  CompileResult = Struct.new(:c_source, :diagnostics)

  # Result of checking: the checker (for codegen and tools), the capability
  # check, and every diagnostic.
  CheckResult = Struct.new(:program, :checker, :caps, :diagnostics)

  # Load src (the file at path; imports are found relative to it, or to the
  # current directory when path is nil), type-check it and check its
  # capabilities. Raises CompileError on a lexing, parsing or import error.
  # root: src already parsed, for tools that read the annotated AST.
  def self.check(src, path = nil, root = nil)
    program = Loader.new(src, path, root).load
    checker = TypeChecker.new(program)
    diags = checker.check
    caps = CapChecker.new(checker)
    # Capabilities are checked only on a well-typed program.
    diags = caps.check if diags.empty?
    CheckResult.new(program, checker, caps, diags)
  end

  # With debug, the C carries #line directives pointing at the .egg files
  # (for debug builds).
  def self.compile_to_c(src, path = nil, debug: false)
    r = check(src, path)
    return CompileResult.new(nil, r.diagnostics) unless r.diagnostics.empty?
    CompileResult.new(CodegenC.new(r.program, r.checker, debug ? File.expand_path(path) : nil).generate, [])
  rescue CompileError => e
    CompileResult.new(nil, [e.diagnostic])
  end
end
