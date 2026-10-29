# Lexer: source text -> array of Token.
#
# Newlines are significant (they end statements, like Go), so they are
# emitted as :nl tokens. The parser skips them where a statement cannot end.

module Egg
  # len: the token's length in the source, when it differs from text's
  # (a character literal 'a' has text "97").
  Token = Struct.new(:kind, :text, :line, :col, :len)

  KEYWORDS = %w[fn return if else while var const true false and or
                struct enum union switch for break continue try catch orelse error inout sink comptime uses allow extern link owned null defer errdefer].freeze

  # Longest operators first so "==" wins over "=" and ".." over ".".
  OPERATORS = %w[== != <= >= => << >> .. ( ) { } [ ] , : = < > + - * / % ! ? . | & ^ ~].freeze

  class Lexer
    def initialize(src)
      # Source is UTF-8 whatever the locale's default encoding is.
      @src = src.encoding == Encoding::UTF_8 ? src : src.dup.force_encoding(Encoding::UTF_8)
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
    # both sides, so 0..n stays a range). 0xff and 0b1010 are integers,
    # kept as their decimal value.
    def lex_number
      line = @line
      col = @col
      start = @pos
      if @src[@pos] == "0" && (@src[@pos + 1] == "x" || @src[@pos + 1] == "b")
        return lex_radix(line, col)
      end
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

    def lex_radix(line, col)
      start = @pos
      hex = @src[@pos + 1] == "x"
      advance
      advance
      advance while @pos < @src.length && ident_char?(@src[@pos])
      text = @src[start...@pos]
      digits = text[2..].delete("_")
      valid = hex ? digits.match?(/\A[0-9A-Fa-f]+\z/) : digits.match?(/\A[01]+\z/)
      unless valid && text[2] != "_"
        what = hex ? "a hex literal needs hex digits after 0x, as in 0xff" : "a binary literal needs 0s and 1s after 0b, as in 0b1010"
        raise CompileError.new(Diagnostic.new("E001", "#{what}, found '#{text}'", line, col))
      end
      @tokens << Token.new(:int, digits.to_i(hex ? 16 : 2).to_s, line, col, @pos - start)
    end

    def lex_digits
      advance while @pos < @src.length && (digit?(@src[@pos]) || @src[@pos] == "_")
    end

    def digit_at?(i)
      i < @src.length && digit?(@src[i])
    end

    # "..." on one line, with escapes \n \r \t \\ \" \0, \xNN (any byte,
    # so a str need not be UTF-8) and \u{N} (a code point, written as its
    # UTF-8 bytes). The text is built as bytes and kept in a UTF-8 String.
    def lex_string
      line = @line
      col = @col
      advance # opening quote
      out = +""
      out.force_encoding(Encoding::BINARY)
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
          ecol = @col
          advance
          e = @pos < @src.length ? @src[@pos] : ""
          if CHAR_ESCAPES.key?(e) && e != "'"
            out << CHAR_ESCAPES[e].chr
            advance
          elsif e == "x"
            unless @src[@pos + 1, 2].to_s.match?(/\A\h\h\z/)
              raise CompileError.new(Diagnostic.new("E001", "\\x in a string needs two hex digits, as in \\xff", @line, ecol))
            end
            out << @src[@pos + 1, 2].to_i(16).chr
            3.times { advance }
          elsif e == "u"
            advance
            utf8_bytes(lex_code_point(ecol)).each { |b| out << b.chr }
          else
            raise CompileError.new(Diagnostic.new("E001", "unknown escape '\\#{e}' in string (\\n \\r \\t \\\\ \\\" \\0 \\xNN \\u{N})", @line, ecol))
          end
        else
          out << c.dup.force_encoding(Encoding::BINARY)
          advance
        end
      end
      out.force_encoding(Encoding::UTF_8)
      @tokens << Token.new(:string, out, line, col)
    end

    # {N} after \u: 1 to 6 hex digits naming a Unicode scalar value (not a
    # surrogate, at most 10FFFF).
    def lex_code_point(ecol)
      text = @src[@pos, 8].to_s
      m = text.match(/\A\{(\h{1,6})\}/)
      if m.nil?
        raise CompileError.new(Diagnostic.new("E001", "\\u needs a code point in braces, 1 to 6 hex digits, as in \\u{e9}", @line, ecol))
      end
      cp = m[1].to_i(16)
      if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)
        raise CompileError.new(Diagnostic.new("E001", "\\u{#{m[1]}} is not a Unicode scalar value (a surrogate, or above 10FFFF)", @line, ecol))
      end
      m[0].length.times { advance }
      cp
    end

    def utf8_bytes(cp)
      if cp < 0x80
        [cp]
      elsif cp < 0x800
        [0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)]
      elsif cp < 0x10000
        [0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)]
      else
        [0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)]
      end
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
        if e == "" || e == "\n"
          raise CompileError.new(Diagnostic.new("E001", "unterminated character literal", line, col))
        elsif CHAR_ESCAPES.key?(e)
          value = CHAR_ESCAPES[e]
          advance
        elsif e == "x" && @src[@pos + 1, 2].to_s.match?(/\A\h\h\z/)
          value = @src[@pos + 1, 2].to_i(16)
          3.times { advance }
        elsif e == "u"
          raise CompileError.new(Diagnostic.new("E001", "a character literal holds one byte, and \\u{N} is a code point that may need several: use a string (\"\\u{e9}\"), or \\xNN for a byte", @line, @col))
        else
          raise CompileError.new(Diagnostic.new("E001", "unknown escape '\\#{e}' in character literal (\\n \\r \\t \\\\ \\' \\\" \\0 \\xNN)", @line, @col))
        end
      elsif !c.valid_encoding?
        raise CompileError.new(Diagnostic.new("E001", "a character literal holds one byte, and this one is not valid UTF-8: use \\xNN for a byte", line, col))
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
      @tokens << Token.new(:int, value.to_s, line, col, @col - col)
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
