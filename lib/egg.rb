require_relative "egg/diagnostic"
require_relative "egg/lexer"
require_relative "egg/ast"
require_relative "egg/parser"
require_relative "egg/typecheck"
require_relative "egg/codegen_c"

module Egg
  VERSION = "0.0.1"

  # Result of compiling one source file to C.
  # Exactly one of c_source / diagnostics is meaningful.
  CompileResult = Struct.new(:c_source, :diagnostics)

  # With source_path, the C carries #line directives pointing at it
  # (for debug builds).
  def self.compile_to_c(src, source_path = nil)
    tokens = Lexer.new(src).tokenize
    program = Parser.new(tokens).parse_program
    checker = TypeChecker.new(program)
    diags = checker.check
    return CompileResult.new(nil, diags) unless diags.empty?
    CompileResult.new(CodegenC.new(program, checker, source_path).generate, [])
  rescue CompileError => e
    CompileResult.new(nil, [e.diagnostic])
  end
end
