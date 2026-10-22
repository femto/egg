# Lexer: source text -> array of Token.
#
# Newlines are significant (they end statements, like Go), so they are
# emitted as :nl tokens. The parser skips them where a statement cannot end.

module Egg
  Token = Struct.new(:kind, :text, :line, :col)

  KEYWORDS = %w[fn return if else while var const true false and or].freeze

  # Longest operators first so "==" wins over "=".
  OPERATORS = %w[== != <= >= ( ) { } , : = < > + - * / % !].freeze

  class Lexer
    def initialize(src)
      @src = src
      @pos = 0
      @line = 1
      @col = 1
      @tokens = []
    end

    def tokenize
      while @pos < @src.length
        c = @src[@pos]
        if c == "\n"
          push(:nl, "\n")
          advance
        elsif c == " " || c == "\t" || c == "\r"
          advance
        elsif c == "/" && peek(1) == "/"
          advance while @pos < @src.length && @src[@pos] != "\n"
        elsif digit?(c)
          lex_number
        elsif ident_start?(c)
          lex_ident
        elsif c == "@"
          lex_builtin
        else
          lex_operator
        end
      end
      push(:nl, "\n")
      push(:eof, "")
      @tokens
    end

    private

    def lex_number
      line = @line
      col = @col
      start = @pos
      advance while @pos < @src.length && (digit?(@src[@pos]) || @src[@pos] == "_")
      text = @src[start...@pos].delete("_")
      @tokens << Token.new(:int, text, line, col)
    end

    def lex_ident
      line = @line
      col = @col
      start = @pos
      advance while @pos < @src.length && ident_char?(@src[@pos])
      text = @src[start...@pos]
      kind = KEYWORDS.include?(text) ? :kw : :ident
      @tokens << Token.new(kind, text, line, col)
    end

    def lex_builtin
      line = @line
      col = @col
      advance # '@'
      start = @pos
      advance while @pos < @src.length && ident_char?(@src[@pos])
      if @pos == start
        raise CompileError.new(Diagnostic.new("E001", "expected a builtin name after '@'", line, col))
      end
      @tokens << Token.new(:builtin, @src[start...@pos], line, col)
    end

    def lex_operator
      OPERATORS.each do |op|
        if @src[@pos, op.length] == op
          push(:op, op)
          op.length.times { advance }
          return
        end
      end
      raise CompileError.new(Diagnostic.new("E001", "unexpected character '#{@src[@pos]}'", @line, @col))
    end

    def push(kind, text)
      @tokens << Token.new(kind, text, @line, @col)
    end

    def advance
      if @src[@pos] == "\n"
        @line += 1
        @col = 1
      else
        @col += 1
      end
      @pos += 1
    end

    def peek(n)
      @src[@pos + n]
    end

    def digit?(c)
      c >= "0" && c <= "9"
    end

    def ident_start?(c)
      (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    end

    def ident_char?(c)
      ident_start?(c) || digit?(c)
    end
  end
end
