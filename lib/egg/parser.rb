# Recursive-descent parser: tokens -> AST.
#
# Grammar (v0) is in spec/grammar.ebnf. Statements end at a newline or '}'.
# A newline is allowed after a binary operator, after '(' and ',', and
# before 'else'; nowhere else inside an expression.

module Egg
  class Parser
    MAX_I64 = 9_223_372_036_854_775_807

    def initialize(tokens)
      @tokens = tokens
      @pos = 0
    end

    def parse_program
      funcs = []
      skip_nl
      until at?(:eof)
        funcs << parse_func
        skip_nl
      end
      Program.new(funcs)
    end

    private

    # ---- declarations -------------------------------------------------

    def parse_func
      fn_tok = expect_kw("fn")
      name = expect(:ident, "function name")
      expect_op("(")
      params = []
      skip_nl
      unless op?(")")
        loop do
          skip_nl
          pname = expect(:ident, "parameter name")
          expect_op(":")
          ptype = expect(:ident, "parameter type")
          params << Param.new(pname.text, ptype.text, pname.line, pname.col)
          skip_nl
          break unless op?(",")
          advance
          skip_nl
          break if op?(")") # trailing comma
        end
      end
      expect_op(")")
      ret = expect(:ident, "return type")
      body = parse_block
      Func.new(name.text, params, ret.text, body, fn_tok.line, fn_tok.col)
    end

    def parse_block
      expect_op("{")
      stmts = []
      skip_nl
      until op?("}")
        if at?(:eof)
          error_here("unexpected end of file, expected '}'")
        end
        stmts << parse_stmt
        end_stmt
        skip_nl
      end
      expect_op("}")
      Block.new(stmts)
    end

    # A statement must be followed by a newline or the closing '}'.
    def end_stmt
      return if at?(:nl) || op?("}")
      error_here("expected a newline after the statement, found '#{cur.text}'")
    end

    # ---- statements ---------------------------------------------------

    def parse_stmt
      t = cur
      if kw?("var") || kw?("const")
        parse_var_decl
      elsif kw?("return")
        advance
        value = (at?(:nl) || op?("}")) ? nil : parse_expr
        Return.new(value, t.line, t.col)
      elsif kw?("if")
        parse_if
      elsif kw?("while")
        advance
        expect_op("(")
        cond = parse_expr
        expect_op(")")
        While.new(cond, parse_block, t.line, t.col)
      elsif at?(:ident) && peek_op?("=")
        advance
        advance
        skip_nl
        Assign.new(t.text, parse_expr, t.line, t.col)
      else
        ExprStmt.new(parse_expr, t.line, t.col)
      end
    end

    def parse_var_decl
      t = advance
      mutable = t.text == "var"
      name = expect(:ident, "variable name")
      type = nil
      if op?(":")
        advance
        type = expect(:ident, "type").text
      end
      expect_op("=")
      skip_nl
      value = parse_expr
      VarDecl.new(name.text, mutable, type, value, name.line, name.col, nil)
    end

    def parse_if
      t = expect_kw("if")
      expect_op("(")
      cond = parse_expr
      expect_op(")")
      then_body = parse_block
      else_body = nil
      # Allow `}` newline `else`: look past newlines for an else.
      save = @pos
      skip_nl
      if kw?("else")
        advance
        else_body = kw?("if") ? parse_if : parse_block
      else
        @pos = save
      end
      If.new(cond, then_body, else_body, t.line, t.col)
    end

    # ---- expressions --------------------------------------------------

    def parse_expr
      parse_or
    end

    def parse_or
      lhs = parse_and
      while kw?("or")
        t = advance
        skip_nl
        lhs = Binary.new("or", lhs, parse_and, t.line, t.col)
      end
      lhs
    end

    def parse_and
      lhs = parse_cmp
      while kw?("and")
        t = advance
        skip_nl
        lhs = Binary.new("and", lhs, parse_cmp, t.line, t.col)
      end
      lhs
    end

    CMP_OPS = %w[== != < <= > >=].freeze

    def parse_cmp
      lhs = parse_add
      if at?(:op) && CMP_OPS.include?(cur.text)
        t = advance
        skip_nl
        lhs = Binary.new(t.text, lhs, parse_add, t.line, t.col)
        if at?(:op) && CMP_OPS.include?(cur.text)
          error_here("comparison operators cannot be chained; use 'and'")
        end
      end
      lhs
    end

    def parse_add
      lhs = parse_mul
      while op?("+") || op?("-")
        t = advance
        skip_nl
        lhs = Binary.new(t.text, lhs, parse_mul, t.line, t.col)
      end
      lhs
    end

    def parse_mul
      lhs = parse_unary
      while op?("*") || op?("/") || op?("%")
        t = advance
        skip_nl
        lhs = Binary.new(t.text, lhs, parse_unary, t.line, t.col)
      end
      lhs
    end

    def parse_unary
      if op?("-") || op?("!")
        t = advance
        return Unary.new(t.text, parse_unary, t.line, t.col)
      end
      parse_primary
    end

    def parse_primary
      t = cur
      if at?(:int)
        advance
        # Range-check the digits before to_i: under Spinel, to_i raises on overflow.
        unless fits_i64?(t.text)
          raise CompileError.new(Diagnostic.new("E003", "integer literal #{t.text} does not fit in i64", t.line, t.col))
        end
        IntLit.new(t.text.to_i, t.line, t.col)
      elsif kw?("true") || kw?("false")
        advance
        BoolLit.new(t.text == "true", t.line, t.col)
      elsif at?(:ident)
        advance
        if op?("(")
          Call.new(t.text, parse_args, t.line, t.col)
        else
          Var.new(t.text, t.line, t.col)
        end
      elsif at?(:builtin)
        advance
        Builtin.new(t.text, parse_args, t.line, t.col)
      elsif op?("(")
        advance
        skip_nl
        e = parse_expr
        skip_nl
        expect_op(")")
        e
      else
        error_here("expected an expression, found #{describe(t)}")
      end
    end

    def parse_args
      expect_op("(")
      args = []
      skip_nl
      unless op?(")")
        loop do
          skip_nl
          args << parse_expr
          skip_nl
          break unless op?(",")
          advance
          skip_nl
          break if op?(")")
        end
      end
      expect_op(")")
      args
    end

    # ---- token helpers ------------------------------------------------

    def cur
      @tokens[@pos]
    end

    def advance
      t = @tokens[@pos]
      @pos += 1 unless t.kind == :eof
      t
    end

    def at?(kind)
      cur.kind == kind
    end

    def op?(text)
      cur.kind == :op && cur.text == text
    end

    def kw?(text)
      cur.kind == :kw && cur.text == text
    end

    def peek_op?(text)
      t = @tokens[@pos + 1]
      !t.nil? && t.kind == :op && t.text == text
    end

    def skip_nl
      advance while at?(:nl)
    end

    def expect(kind, what)
      return advance if at?(kind)
      error_here("expected #{what}, found #{describe(cur)}")
    end

    def expect_op(text)
      return advance if op?(text)
      error_here("expected '#{text}', found #{describe(cur)}")
    end

    def expect_kw(text)
      return advance if kw?(text)
      error_here("expected '#{text}', found #{describe(cur)}")
    end

    def describe(t)
      case t.kind
      when :nl then "a newline"
      when :eof then "end of file"
      else "'#{t.text}'"
      end
    end

    def fits_i64?(digits)
      d = digits.sub(/\A0+/, "")
      max = MAX_I64.to_s
      d.length < max.length || (d.length == max.length && d <= max)
    end

    def error_here(msg)
      raise CompileError.new(Diagnostic.new("E002", msg, cur.line, cur.col))
    end
  end
end
