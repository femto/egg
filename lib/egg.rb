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

  def self.compile_to_c(src)
    tokens = Lexer.new(src).tokenize
    program = Parser.new(tokens).parse_program
    diags = TypeChecker.new(program).check
    return CompileResult.new(nil, diags) unless diags.empty?
    CompileResult.new(CodegenC.new(program).generate, [])
  rescue CompileError => e
    CompileResult.new(nil, [e.diagnostic])
  end
end
