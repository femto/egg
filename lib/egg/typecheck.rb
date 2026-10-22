# Type checker for the v0 core.
#
# Types are plain strings: "i64", "bool", "void". "error" marks an
# expression that already produced a diagnostic, so one mistake does not
# cascade into many.
#
# Like Zig, the checker rejects ambiguity rather than guessing:
#   - unused local variables            (E110)
#   - `var` that is never reassigned     (E111)
#   - a non-void result that is ignored  (E113)
#   - shadowing an outer name            (E106)

module Egg
  VarInfo = Struct.new(:type, :mutable, :used, :mutated, :line, :col, :param)
  FuncSig = Struct.new(:params, :ret)

  class TypeChecker
    TYPES = %w[i64 bool void].freeze
    ARITH_OPS = %w[+ - * / %].freeze
    ORDER_OPS = %w[< <= > >=].freeze

    attr_reader :diagnostics

    def initialize(program)
      @program = program
      @diagnostics = []
      @funcs = {}
      @scopes = []
      @current = nil
    end

    def check
      collect_signatures
      @program.funcs.each { |f| check_func(f) }
      check_main
      @diagnostics
    end

    private

    # ---- top level ----------------------------------------------------

    def collect_signatures
      @program.funcs.each do |f|
        if @funcs.key?(f.name)
          err("E106", "function '#{f.name}' is defined more than once", f.line, f.col)
          next
        end
        params = []
        f.params.each do |p|
          check_type_name(p.type, p.line, p.col, false)
          params << p.type
        end
        check_type_name(f.ret, f.line, f.col, true)
        @funcs[f.name] = FuncSig.new(params, f.ret)
      end
    end

    def check_main
      sig = @funcs["main"]
      if sig.nil?
        err("E109", "program has no 'main' function", 1, 1)
      elsif !sig.params.empty? || (sig.ret != "void" && sig.ret != "i64")
        f = @program.funcs.find { |fn| fn.name == "main" }
        err("E109", "'main' must take no parameters and return void or i64", f.line, f.col)
      end
    end

    def check_type_name(name, line, col, allow_void)
      return if TYPES.include?(name) && (allow_void || name != "void")
      if name == "void"
        err("E108", "a value cannot have type void", line, col)
      else
        err("E108", "unknown type '#{name}'", line, col)
      end
    end

    def check_func(f)
      @current = f
      @scopes = [{}]
      f.params.each do |p|
        declare(p.name, VarInfo.new(p.type, false, false, false, p.line, p.col, true))
      end
      check_block(f.body)
      if f.ret != "void" && !block_returns?(f.body)
        err("E107", "function '#{f.name}' can reach its end without returning #{f.ret}", f.line, f.col)
      end
      @scopes = []
    end

    # ---- statements ---------------------------------------------------

    def check_block(block)
      @scopes << {}
      block.stmts.each { |s| check_stmt(s) }
      close_scope(@scopes.pop)
    end

    def close_scope(scope)
      scope.each do |name, info|
        next if info.param
        if !info.used
          err("E110", "local variable '#{name}' is never used", info.line, info.col)
        elsif info.mutable && !info.mutated
          err("E111", "local variable '#{name}' is never reassigned; declare it with 'const'", info.line, info.col)
        end
      end
    end

    def check_stmt(stmt)
      case stmt
      in VarDecl[name:, mutable:, type:, value:, line:, col:]
        vt = check_expr(value)
        ty = vt
        unless type.nil?
          check_type_name(type, line, col, false)
          expect_type(type, vt, value)
          ty = type
        end
        if ty == "void"
          err("E103", "cannot store a void value in '#{name}'", line, col)
          ty = "error"
        end
        stmt.ty = ty
        declare(name, VarInfo.new(ty, mutable, false, false, line, col, false))
      in Assign[name:, value:, line:, col:]
        info = lookup(name)
        vt = check_expr(value)
        if info.nil?
          err("E101", "undefined variable '#{name}'", line, col)
        elsif !info.mutable
          what = info.param ? "parameter" : "constant"
          err("E105", "cannot assign to #{what} '#{name}'", line, col)
        else
          info.mutated = true
          expect_type(info.type, vt, value)
        end
      in If[cond:, then_body:, else_body:]
        expect_type("bool", check_expr(cond), cond)
        check_block(then_body)
        case else_body
        in nil then nil
        in Block then check_block(else_body)
        in If then check_stmt(else_body)
        end
      in While[cond:, body:]
        expect_type("bool", check_expr(cond), cond)
        check_block(body)
      in Return[value:, line:, col:]
        ret = @current.ret
        if value.nil?
          err("E103", "function '#{@current.name}' must return #{ret}", line, col) if ret != "void"
        else
          vt = check_expr(value)
          if ret == "void"
            err("E103", "function '#{@current.name}' returns void and cannot return a value", line, col)
          else
            expect_type(ret, vt, value)
          end
        end
      in ExprStmt[expr:, line:, col:]
        t = check_expr(expr)
        if t != "void" && t != "error"
          err("E113", "value of type #{t} is ignored", line, col)
        end
      else
        raise "typecheck: unhandled statement #{stmt.class}"
      end
    end

    # ---- expressions --------------------------------------------------

    def check_expr(expr)
      case expr
      in IntLit then "i64"
      in BoolLit then "bool"
      in Var[name:, line:, col:]
        info = lookup(name)
        if info.nil?
          err("E101", "undefined variable '#{name}'", line, col)
          "error"
        else
          info.used = true
          info.type
        end
      in Unary[op:, operand:]
        t = check_expr(operand)
        if op == "-"
          expect_type("i64", t, operand)
          "i64"
        else
          expect_type("bool", t, operand)
          "bool"
        end
      in Binary[op:, lhs:, rhs:, line:, col:]
        check_binary(op, lhs, rhs, line, col)
      in Call[name:, args:, line:, col:]
        check_call(name, args, line, col)
      in Builtin[name:, args:, line:, col:]
        check_builtin(name, args, line, col)
      else
        raise "typecheck: unhandled expression #{expr.class}"
      end
    end

    def check_binary(op, lhs, rhs, line, col)
      lt = check_expr(lhs)
      rt = check_expr(rhs)
      if ARITH_OPS.include?(op)
        expect_type("i64", lt, lhs)
        expect_type("i64", rt, rhs)
        "i64"
      elsif ORDER_OPS.include?(op)
        expect_type("i64", lt, lhs)
        expect_type("i64", rt, rhs)
        "bool"
      elsif op == "==" || op == "!="
        if lt != "error" && rt != "error" && lt != rt
          err("E103", "cannot compare #{lt} with #{rt}", line, col)
        end
        "bool"
      else # and / or
        expect_type("bool", lt, lhs)
        expect_type("bool", rt, rhs)
        "bool"
      end
    end

    def check_call(name, args, line, col)
      sig = @funcs[name]
      arg_types = args.map { |a| check_expr(a) }
      if sig.nil?
        if lookup(name)
          err("E102", "'#{name}' is a variable, not a function", line, col)
        else
          err("E102", "undefined function '#{name}'", line, col)
        end
        return "error"
      end
      if sig.params.length != args.length
        err("E104", "'#{name}' takes #{sig.params.length} argument(s) but #{args.length} were given", line, col)
        return sig.ret
      end
      sig.params.each_with_index do |pt, i|
        expect_type(pt, arg_types[i], args[i])
      end
      sig.ret
    end

    # v0 has one builtin. `@print` is a stand-in until the `io` capability
    # lands in v2; it will move out of the core then.
    def check_builtin(name, args, line, col)
      unless name == "print"
        err("E112", "unknown builtin '@#{name}'", line, col)
        args.each { |a| check_expr(a) }
        return "error"
      end
      if args.length != 1
        err("E104", "'@print' takes 1 argument but #{args.length} were given", line, col)
        args.each { |a| check_expr(a) }
        return "void"
      end
      t = check_expr(args[0])
      if t == "void"
        err("E103", "'@print' cannot print a void value", line, col)
      end
      "void"
    end

    # ---- helpers ------------------------------------------------------

    def expect_type(want, got, node)
      return if got == "error" || want == "error" || want == got
      err("E103", "expected #{want}, found #{got}", node.line, node.col)
    end

    def block_returns?(block)
      block.stmts.any? { |s| stmt_returns?(s) }
    end

    def stmt_returns?(stmt)
      case stmt
      in Return then true
      in If[then_body:, else_body:]
        case else_body
        in nil then false
        in Block then block_returns?(then_body) && block_returns?(else_body)
        in If then block_returns?(then_body) && stmt_returns?(else_body)
        end
      else false
      end
    end

    def declare(name, info)
      if lookup(name) || @funcs.key?(name)
        err("E106", "'#{name}' shadows an existing declaration", info.line, info.col)
      end
      @scopes.last[name] = info
    end

    def lookup(name)
      i = @scopes.length - 1
      while i >= 0
        info = @scopes[i][name]
        return info unless info.nil?
        i -= 1
      end
      nil
    end

    def err(code, msg, line, col)
      @diagnostics << Diagnostic.new(code, msg, line, col)
    end
  end
end
