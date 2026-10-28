# Lexer: source text -> array of Token.
#
# Newlines are significant (they end statements, like Go), so they are
# emitted as :nl tokens. The parser skips them where a statement cannot end.

module Egg
  Token = Struct.new(:kind, :text, :line, :col)

  KEYWORDS = %w[fn return if else while var const true false and or
                struct enum union switch for break continue try catch orelse error inout sink comptime uses allow extern link owned null defer errdefer].freeze

  # Longest operators first so "==" wins over "=" and ".." over ".".
  OPERATORS = %w[== != <= >= => .. ( ) { } [ ] , : = < > + - * / % ! ? . | &].freeze

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
        elsif c == "\""
          lex_string
        elsif c == "'"
          lex_char
        else
          lex_operator
        end
      end
      push(:nl, "\n")
      push(:eof, "")
      @tokens
    end

    private

    # 42, or a float: 1.5, 2e10, 6.02e-23 (a '.' must have a digit on
    # both sides, so 0..n stays a range).
    def lex_number
      line = @line
      col = @col
      start = @pos
      kind = :int
      lex_digits
      if @src[@pos] == "." && digit_at?(@pos + 1)
        kind = :float
        advance
        lex_digits
      end
      if (@src[@pos] == "e" || @src[@pos] == "E") &&
         (digit_at?(@pos + 1) || ((@src[@pos + 1] == "+" || @src[@pos + 1] == "-") && digit_at?(@pos + 2)))
        kind = :float
        advance
        advance unless digit?(@src[@pos])
        lex_digits
      end
      text = @src[start...@pos].delete("_")
      @tokens << Token.new(kind, text, line, col)
    end

    def lex_digits
      advance while @pos < @src.length && (digit?(@src[@pos]) || @src[@pos] == "_")
    end

    def digit_at?(i)
      i < @src.length && digit?(@src[i])
    end

    # "..." on one line, with escapes \n \r \t \\ \" \0.
    def lex_string
      line = @line
      col = @col
      advance # opening quote
      out = +""
      while true
        if @pos >= @src.length || @src[@pos] == "\n"
          raise CompileError.new(Diagnostic.new("E001", "unterminated string literal", line, col))
        end
        c = @src[@pos]
        if c == "\""
          advance
          break
        end
        if c == "\\"
          advance
          e = @pos < @src.length ? @src[@pos] : ""
          if e == "n" then out << "\n"
          elsif e == "r" then out << "\r"
          elsif e == "t" then out << "\t"
          elsif e == "\\" then out << "\\"
          elsif e == "\"" then out << "\""
          elsif e == "0" then out << "\0"
          else
            raise CompileError.new(Diagnostic.new("E001", "unknown escape '\\#{e}' in string", @line, @col))
          end
          advance
        else
          out << c
          advance
        end
      end
      @tokens << Token.new(:string, out, line, col)
    end

    CHAR_ESCAPES = { "n" => 10, "r" => 13, "t" => 9, "\\" => 92, "'" => 39, "\"" => 34, "0" => 0 }.freeze

    # 'a': one byte, an integer literal like 97 (typed by its context).
    # Escapes \n \r \t \\ \' \" \0 and \xNN.
    def lex_char
      line = @line
      col = @col
      advance # opening quote
      c = @src[@pos]
      if c.nil? || c == "\n"
        raise CompileError.new(Diagnostic.new("E001", "unterminated character literal", line, col))
      elsif c == "'"
        raise CompileError.new(Diagnostic.new("E001", "empty character literal; a character literal holds one byte", line, col))
      elsif c == "\\"
        advance
        e = @src[@pos] || ""
        if CHAR_ESCAPES.key?(e)
          value = CHAR_ESCAPES[e]
          advance
        elsif e == "x" && @src[@pos + 1, 2].to_s.match?(/\A\h\h\z/)
          value = @src[@pos + 1, 2].to_i(16)
          3.times { advance }
        else
          raise CompileError.new(Diagnostic.new("E001", "unknown escape '\\#{e}' in character literal (\\n \\r \\t \\\\ \\' \\\" \\0 \\xNN)", @line, @col))
        end
      elsif c.bytesize > 1
        raise CompileError.new(Diagnostic.new("E001", "'#{c}' is #{c.bytesize} bytes; a character literal holds one byte: use a string, or \\xNN for a byte", line, col))
      else
        value = c.ord
        advance
      end
      unless @src[@pos] == "'"
        what = @pos >= @src.length || @src[@pos] == "\n" ? "unterminated character literal" : "a character literal holds one byte; use a string for several"
        raise CompileError.new(Diagnostic.new("E001", what, line, col))
      end
      advance
      @tokens << Token.new(:int, value.to_s, line, col)
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
