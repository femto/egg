# Recursive-descent parser: tokens -> AST.
#
# Grammar is in spec/grammar.ebnf. Statements end at a newline or '}'.
# A newline is allowed after a binary operator, after '(' '[' '{' and ',',
# before ')' ']' '}', and before 'else'; nowhere else inside an expression.
#
# Loops are written `while true` rather than `loop do` so a CompileError
# raised inside keeps its diagnostic under older Spinel builds.

module Egg
  class Parser
    MAX_I64 = 9_223_372_036_854_775_807
    # The largest literal (u64); the checker checks it against its type.
    MAX_U64 = 18_446_744_073_709_551_615

    def initialize(tokens)
      @tokens = tokens
      @pos = 0
    end

    def parse_program
      funcs = []
      types = []
      uses = []
      imports = []
      allows = []
      links = []
      skip_nl
      until at?(:eof)
        if kw?("const")
          d = parse_type_decl
          if d.is_a?(ImportDecl)
            imports << d
          else
            types << d
          end
        elsif kw?("uses")
          parse_uses(uses)
        elsif kw?("allow")
          advance
          parse_names(allows, "what to allow (unsafe)")
          end_stmt
        elsif kw?("link")
          advance
          lib = expect(:string, "a C library name in quotes, as in link \"m\"")
          links << UsesItem.new(lib.text, lib.line, lib.col)
          end_stmt
        elsif kw?("extern")
          funcs << parse_extern
        else
          funcs << parse_func(nil)
        end
        skip_nl
      end
      Program.new(funcs, types, uses, imports, nil, allows, links)
    end

    # uses alloc, io
    def parse_uses(into)
      expect_kw("uses")
      parse_names(into, "capability name")
      end_stmt
    end

    # name, name, ...
    def parse_names(into, what)
      while true
        n = expect(:ident, what)
        into << UsesItem.new(n.text, n.line, n.col)
        break unless op?(",")
        advance
      end
    end

    # extern fn name(params) R [uses alloc, io]: a C function, no body.
    def parse_extern
      expect_kw("extern")
      fn_tok = expect_kw("fn")
      name = expect(:ident, "function name")
      params = parse_params
      ret = parse_type
      ext = []
      if kw?("uses")
        advance
        parse_names(ext, "capability name")
      end
      end_stmt
      Func.new(name.text, params, ret, nil, fn_tok.line, fn_tok.col, nil, nil, ext)
    end

    private

    # ---- declarations -------------------------------------------------

    def parse_func(owner)
      fn_tok = expect_kw("fn")
      name = expect(:ident, "function name")
      params = parse_params
      ret = parse_type
      body = parse_block
      Func.new(name.text, params, ret, body, fn_tok.line, fn_tok.col, owner)
    end

    def parse_params
      expect_op("(")
      params = []
      skip_nl
      unless op?(")")
        while true
          skip_nl
          mode = nil
          if kw?("inout") || kw?("comptime")
            mode = advance.text
          end
          pname = expect(:ident, "parameter name")
          expect_op(":")
          ptype = parse_type
          params << Param.new(pname.text, ptype, pname.line, pname.col, mode)
          skip_nl
          break unless op?(",")
          advance
          skip_nl
          break if op?(")") # trailing comma
        end
      end
      expect_op(")")
      params
    end

    # T | m.T | Name(T, ...) | [N]T | [_]T | []T | !T | *T | fn(T, ...) R | @This()
    def parse_type
      if op?("!")
        advance
        return ErrType.new(parse_type)
      end
      if op?("?")
        advance
        return OptType.new(parse_type)
      end
      if op?("*")
        advance
        return PtrType.new(parse_type)
      end
      if kw?("fn")
        advance
        expect_op("(")
        params = parse_comma_list(")") { parse_type }
        return FnType.new(params, parse_type)
      end
      if op?("[")
        advance
        skip_nl
        if op?("]")
          advance
          return SliceType.new(parse_type)
        end
        len = nil
        if at?(:int)
          len_tok = advance
          unless fits_i64?(len_tok.text)
            raise CompileError.new(Diagnostic.new("E003", "array length #{len_tok.text} does not fit in i64", len_tok.line, len_tok.col))
          end
          len = len_tok.text.to_i
        elsif at?(:ident) && cur.text == "_"
          advance
        else
          error_here("expected an array length or '_', found #{describe(cur)}")
        end
        expect_op("]")
        return ArrayType.new(len, parse_type)
      end
      if at?(:builtin) && cur.text == "This"
        t = advance
        expect_op("(")
        expect_op(")")
        return ThisType.new(t.line, t.col)
      end
      name = expect(:ident, "type").text
      # m.Point: a type of an imported module
      if op?(".")
        advance
        name = "#{name}.#{expect(:ident, "type name after '.'").text}"
      end
      if op?("(")
        advance
        args = parse_comma_list(")") { parse_type }
        return GenericType.new(name, args)
      end
      name
    end

    # const Name = struct { field: T, fn method(...) R { ... } }
    # const Name = owned struct { ... }
    # const Name = enum { a, b, c }
    # const name = @import("file.egg")
    def parse_type_decl
      expect_kw("const")
      name = expect(:ident, "type name")
      expect_op("=")
      if at?(:builtin) && cur.text == "import"
        advance
        expect_op("(")
        path = expect(:string, "a file path such as \"util.egg\"")
        expect_op(")")
        end_stmt
        ImportDecl.new(name.text, path.text, name.line, name.col)
      elsif kw?("struct") || kw?("owned")
        t = advance
        owned = t.text == "owned"
        expect_kw("struct") if owned
        members, methods = parse_struct_body(name.text)
        TypeDecl.new(name.text, :struct, members, methods, t.line, t.col, nil, owned)
      elsif kw?("union")
        t = advance
        expect_op("(")
        expect_kw("enum")
        expect_op(")")
        expect_op("{")
        members = []
        methods = []
        skip_nl
        until op?("}")
          if kw?("fn")
            methods << parse_func(name.text)
          else
            m = expect(:ident, "union member")
            mtype = nil
            if op?(":")
              advance
              mtype = parse_type
            end
            members << FieldDecl.new(m.text, mtype, m.line, m.col)
            advance if op?(",")
          end
          skip_nl
        end
        expect_op("}")
        error_here("a union needs at least one member") if members.empty?
        TypeDecl.new(name.text, :union, members, methods, t.line, t.col)
      elsif kw?("enum")
        t = advance
        expect_op("{")
        members = []
        skip_nl
        until op?("}")
          m = expect(:ident, "enum member")
          members << FieldDecl.new(m.text, nil, m.line, m.col)
          advance if op?(",")
          skip_nl
        end
        expect_op("}")
        error_here("an enum needs at least one member") if members.empty?
        TypeDecl.new(name.text, :enum, members, [], t.line, t.col)
      else
        error_here("expected 'struct', 'enum', 'union(enum)' or '@import' (a top-level const declares a type or a module)")
      end
    end

    # { field: T, ... fn m(...) R { } ... }  -> [fields, methods]
    def parse_struct_body(owner)
      expect_op("{")
      members = []
      methods = []
      skip_nl
      until op?("}")
        if kw?("fn")
          methods << parse_func(owner)
        else
          m = expect(:ident, "field name")
          expect_op(":")
          members << FieldDecl.new(m.text, parse_type, m.line, m.col)
          advance if op?(",")
        end
        skip_nl
      end
      expect_op("}")
      [members, methods]
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
      elsif kw?("for")
        parse_for
      elsif kw?("switch")
        parse_switch
      elsif kw?("break")
        advance
        Break.new(t.line, t.col)
      elsif kw?("continue")
        advance
        Continue.new(t.line, t.col)
      elsif kw?("defer") || kw?("errdefer")
        advance
        Defer.new(parse_expr, t.text == "errdefer", t.line, t.col)
      else
        e = parse_expr
        if op?("=")
          advance
          skip_nl
          value = parse_expr
          root = assign_root(e)
          error_at(t, "only a variable, a field or an element can be assigned to") if root.nil?
          target = e.is_a?(Var) ? nil : e
          Assign.new(root, value, t.line, t.col, target)
        else
          ExprStmt.new(e, t.line, t.col)
        end
      end
    end

    # The variable at the root of an assignable expression, or nil.
    # ("*" for a place behind a pointer: p.* = v, p.*.x = v)
    def assign_root(e)
      case e
      in Var[name:] then name
      in Field[obj:] then assign_root(obj)
      in Index[obj:] then assign_root(obj)
      in Deref then "*"
      else nil
      end
    end

    def parse_var_decl
      t = advance
      mutable = t.text == "var"
      name = expect(:ident, "variable name")
      type = nil
      if op?(":")
        advance
        type = parse_type
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

    # for (xs) |x| { }   for (xs) |x, i| { }
    def parse_for
      t = expect_kw("for")
      expect_op("(")
      iter = parse_expr
      expect_op(")")
      expect_op("|")
      var = expect(:ident, "loop variable")
      index_var = nil
      if op?(",")
        advance
        index_var = expect(:ident, "index variable").text
      end
      expect_op("|")
      For.new(iter, var.text, index_var, parse_block, t.line, t.col)
    end

    # switch (x) {
    #     .a, .b => { ... }
    #     .c => |payload| { ... }
    #     else => { ... }
    # }
    def parse_switch
      t = expect_kw("switch")
      expect_op("(")
      subject = parse_expr
      expect_op(")")
      expect_op("{")
      arms = []
      skip_nl
      until op?("}")
        at = cur
        names = nil
        if kw?("else")
          advance
        else
          names = []
          while true
            expect_op(".")
            names << expect(:ident, "member name").text
            break unless op?(",")
            advance
            skip_nl
          end
        end
        expect_op("=>")
        capture = nil
        if op?("|")
          advance
          capture = expect(:ident, "payload name").text
          expect_op("|")
        end
        arms << SwitchArm.new(names, capture, parse_block, at.line, at.col)
        advance if op?(",")
        skip_nl
      end
      expect_op("}")
      Switch.new(subject, arms, t.line, t.col)
    end

    # ---- expressions --------------------------------------------------

    def parse_expr
      lhs = parse_or
      while kw?("catch") || kw?("orelse")
        t = advance
        skip_nl
        lhs = t.text == "catch" ? Catch.new(lhs, parse_or, t.line, t.col) : Orelse.new(lhs, parse_orelse_fallback, t.line, t.col)
      end
      lhs
    end

    # After orelse: a value, or `return [e]`, `break`, `continue`.
    def parse_orelse_fallback
      t = cur
      if kw?("return")
        advance
        value = (at?(:nl) || op?("}") || op?(")") || op?("]") || op?(",") || op?("..")) ? nil : parse_or
        Return.new(value, t.line, t.col)
      elsif kw?("break")
        advance
        Break.new(t.line, t.col)
      elsif kw?("continue")
        advance
        Continue.new(t.line, t.col)
      else
        parse_or
      end
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
      if kw?("try")
        t = advance
        return Try.new(parse_unary, t.line, t.col)
      end
      if op?("&")
        t = advance
        return AddrOf.new(parse_unary, t.line, t.col)
      end
      parse_postfix(parse_primary)
    end

    # a.b   a.b(...)   a.*   a[i]   a[lo..hi]   Type{ .f = v }
    def parse_postfix(e)
      while true
        if op?(".")
          dot = advance
          if op?("*")
            advance
            e = Deref.new(e, dot.line, dot.col)
            next
          end
          name = expect(:ident, "field or method name")
          if op?("(")
            e = MethodCall.new(e, name.text, parse_args, name.line, name.col)
          else
            e = Field.new(e, name.text, name.line, name.col)
          end
        elsif op?("[")
          t = advance
          skip_nl
          lo = op?("..") ? nil : parse_expr
          skip_nl
          if op?("..")
            advance
            skip_nl
            hi = op?("]") ? nil : parse_expr
            skip_nl
            expect_op("]")
            error_at(t, "a slice needs a start index: write a[0..n]") if lo.nil?
            e = SliceExpr.new(e, lo, hi, t.line, t.col)
          else
            expect_op("]")
            e = Index.new(e, lo, t.line, t.col)
          end
        elsif op?("{") && struct_type_head?(e)
          t = cur
          e = StructLit.new(type_of_head(e), parse_struct_fields, t.line, t.col)
        else
          return e
        end
      end
    end

    # Struct literal syntax needs a capitalised type name (Point{ ... },
    # Pair(i64){ ... }, m.Point{ ... }, @This(){ ... }), so that
    # `if (ok) {` stays a block.
    def struct_type_head?(e)
      case e
      in Var[name:] then upper?(name)
      in Call[name:] then upper?(name)
      in Field[obj: Var, name:] then upper?(name)
      in MethodCall[obj: Var, name:] then upper?(name)
      in TypeExpr[type: ThisType] then true
      else false
      end
    end

    def type_of_head(e)
      type_of_expr(e)
    end

    # A type written in a value position (an argument of Pair(...)).
    def type_of_expr(e)
      case e
      in Var[name:] then name
      in Call[name:, args:] then GenericType.new(name, args.map { |a| type_of_expr(a) })
      in Field[obj: Var[name: m], name:] then "#{m}.#{name}"
      in MethodCall[obj: Var[name: m], name:, args:] then GenericType.new("#{m}.#{name}", args.map { |a| type_of_expr(a) })
      in TypeExpr[type:] then type
      else error_at(e, "expected a type")
      end
    end

    def upper?(name)
      c = name[0]
      c >= "A" && c <= "Z"
    end

    def parse_primary
      t = cur
      if at?(:int)
        advance
        # Range-check the digits before to_i: under Spinel, to_i raises on overflow.
        unless fits?(t.text, MAX_U64)
          raise CompileError.new(Diagnostic.new("E003", "integer literal #{t.text} does not fit in any integer type (the largest is u64)", t.line, t.col))
        end
        IntLit.new(t.text.to_i, t.line, t.col)
      elsif at?(:float)
        advance
        FloatLit.new(t.text, t.line, t.col)
      elsif kw?("true") || kw?("false")
        advance
        BoolLit.new(t.text == "true", t.line, t.col)
      elsif kw?("null")
        advance
        NullLit.new(t.line, t.col)
      elsif op?("*") || kw?("fn")
        # *T, fn(T) R as a value: a type argument such as @ptrCast(*u8, p)
        TypeExpr.new(parse_type, t.line, t.col)
      elsif at?(:string)
        advance
        StrLit.new(t.text, t.line, t.col)
      elsif at?(:ident)
        advance
        if op?("(")
          Call.new(t.text, parse_args, t.line, t.col)
        else
          Var.new(t.text, t.line, t.col)
        end
      elsif at?(:builtin)
        if t.text == "This"
          return TypeExpr.new(parse_type, t.line, t.col)
        end
        advance
        Builtin.new(t.text, parse_args, t.line, t.col)
      elsif op?(".")
        advance
        name = expect(:ident, "enum member after '.'")
        EnumLit.new(name.text, t.line, t.col)
      elsif kw?("error")
        advance
        expect_op(".")
        name = expect(:ident, "error name after 'error.'")
        ErrorLit.new(name.text, t.line, t.col)
      elsif kw?("struct")
        advance
        members, methods = parse_struct_body(nil)
        StructTypeExpr.new(members, methods, t.line, t.col)
      elsif op?("[")
        type = parse_type
        if op?("{")
          error_at(t, "an array literal needs an array type such as [3]i64") unless type.is_a?(ArrayType)
          ArrayLit.new(type, parse_list_items, t.line, t.col)
        else
          TypeExpr.new(type, t.line, t.col)
        end
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

    # { .a = e, .b = e }  (commas and/or newlines between fields)
    def parse_struct_fields
      expect_op("{")
      fields = []
      skip_nl
      until op?("}")
        expect_op(".")
        name = expect(:ident, "field name")
        expect_op("=")
        skip_nl
        fields << [name.text, parse_expr, name.line, name.col]
        advance if op?(",")
        skip_nl
      end
      expect_op("}")
      fields
    end

    # { e, e, e }
    def parse_list_items
      expect_op("{")
      parse_comma_list("}") { parse_expr }
    end

    # Items separated by commas, with an optional trailing comma, up to and
    # including `close`; the opening token is already consumed. Newlines
    # may follow the opening token and each comma, and precede `close`.
    def parse_comma_list(close)
      items = []
      skip_nl
      until op?(close)
        items << yield
        skip_nl
        break unless op?(",")
        advance
        skip_nl
      end
      expect_op(close)
      items
    end

    def parse_args
      expect_op("(")
      args = []
      skip_nl
      unless op?(")")
        while true
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
      when :string then "a string"
      else "'#{t.text}'"
      end
    end

    def fits_i64?(digits)
      fits?(digits, MAX_I64)
    end

    def fits?(digits, max_value)
      d = digits.sub(/\A0+/, "")
      max = max_value.to_s
      d.length < max.length || (d.length == max.length && d <= max)
    end

    def error_here(msg)
      raise CompileError.new(Diagnostic.new("E002", msg, cur.line, cur.col))
    end

    def error_at(node, msg)
      raise CompileError.new(Diagnostic.new("E002", msg, node.line, node.col))
    end
  end
end
