# Diagnostics shared by every compiler stage.
#
# Every error has a stable code (E0xx lexer/parser, E1xx checker) so that
# tools and AI agents can match on it instead of parsing English text.
# The full list lives in spec/diagnostics.md.

module Egg
  # file: the imported file the error is in, as the root file's path as
  # given (its directory) joined with the import path, so it is relative
  # to the same directory the root path is (an absolute import stays
  # absolute); nil means the root file itself.
  class Diagnostic
    attr_reader :code, :message, :line, :col
    attr_accessor :file

    def initialize(code, message, line, col, file = nil)
      @code = code
      @message = message
      @line = line
      @col = col
      @file = file
    end

    def to_text(path)
      "#{@file || path}:#{@line}:#{@col}: error[#{@code}]: #{@message}"
    end

    # Hand-written JSON so the compiler needs no gems (Spinel subset).
    def to_json_text(path)
      "{\"file\":#{Egg.json_str(@file || path)},\"line\":#{@line},\"col\":#{@col}," \
        "\"code\":#{Egg.json_str(@code)},\"message\":#{Egg.json_str(@message)}}"
    end
  end

  # Raised by the lexer and parser, which stop at the first error.
  class CompileError < StandardError
    attr_reader :diagnostic

    def initialize(diagnostic)
      super(diagnostic.message)
      @diagnostic = diagnostic
    end
  end

  def self.json_str(s)
    out = +"\""
    s.each_char do |c|
      case c
      when "\"" then out << "\\\""
      when "\\" then out << "\\\\"
      when "\n" then out << "\\n"
      when "\t" then out << "\\t"
      else out << c
      end
    end
    out << "\""
    out
  end
end
