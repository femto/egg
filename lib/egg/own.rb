# Ownership check (linear buffers).
#
# A Buf(T) has exactly one owner. Passing it by value, assigning it,
# returning it or freeing it (`a.free(b)`) moves it: the variable it came
# from no longer owns anything, and using it again is E136. Indexing,
# slicing, `@len`, `for` and `&b` only borrow it. Every buffer must be
# given away before its owner goes out of scope (E135): freed, moved, or
# returned; an inout parameter must own one again whenever the function
# returns. So a buffer is freed exactly once, and never used after.
#
# The check follows every path through a function, after type checking:
# the state of each buffer variable (owned or moved) is tracked statement
# by statement. Where paths join (after an if, a switch, a catch, the right
# side of and/or) they must agree on each variable, and each iteration of
# a loop must leave it as the loop found it (E134). `defer` and `errdefer`
# statements are replayed at every way out of their block: its end, a
# return, a break or continue, and a `try` that returns an error.
#
# While `for (b)` iterates over a buffer, the loop holds on to it: the body
# may read and write its elements, but not move, reassign or resize it
# (E137).
#
# A variable whose state is unknown after an error is "poison": it is not
# reported again.

module Egg
  class OwnershipChecker
    # names: buffer variables declared in this block; defers: Defer nodes
    Frame = Struct.new(:names, :defers)
    # depth: index of the loop body's frame; entry: the state at its start
    Loop = Struct.new(:depth, :entry)

    def initialize(checker)
      @checker = checker
      @types = checker.types
      @diags = []
      @seen = {}
    end

    def check
      @checker.concrete.each { |sig| check_func(sig) }
      @diags
    end

    private

    def owned?(t)
      @types[t]&.kind == :buf
    end

    def check_func(sig)
      @sig = sig
      @file = @checker.modules[sig.func.mod || ""].file
      @frames = [Frame.new([], [])]
      @loops = []
      @st = {}     # name -> [:owned | :moved | :poison, line of the move]
      @decl = {}   # name -> [:local | :param | :inout, line, col]
      @defer_ctx = nil
      @iterated = {} # buffer variable -> line of the for loop iterating it
      runtime = sig.func.params.reject { |p| p.mode == "comptime" }
      runtime.each_with_index do |p, i|
        t, mode = sig.params[i]
        declare(p.name, mode == "inout" ? :inout : :param, p.line, p.col) if owned?(t)
      end
      walk_stmts(sig.func.body.stmts)
      leave(0, false, nil, nil, "when '#{sig.func.name}' ends") unless @st.nil?
    end

    def declare(name, kind, line, col)
      @frames.last.names << name
      @decl[name] = [kind, line, col]
      @st[name] = [:owned, nil] unless @st.nil?
    end

    def err(code, msg, line, col)
      key = [code, msg, line, col, @file]
      return if @seen[key]
      @seen[key] = true
      @diags << Diagnostic.new(code, msg, line, col, @file)
    end

    # ---- ways out -------------------------------------------------------

    # Leave the frames from the innermost down to index `down`: run their
    # defers (and errdefers, when the function returns an error), then
    # check that each buffer declared there has been given away. line nil:
    # the end of a block, reported at each variable's declaration.
    def leave(down, error, line, col, where)
      i = @frames.length - 1
      while i >= down
        f = @frames[i]
        f.defers.reverse_each { |d| run_defer(d, line, col) if !d.err || error }
        f.names.each { |n| check_released(n, line, col, where) }
        i -= 1
      end
    end

    def check_released(name, line, col, where)
      sym, at = @st[name]
      kind, dl, dc = @decl[name]
      l = line || dl
      c = line.nil? ? dc : col
      if kind == :inout
        return unless sym == :moved
        err("E135", "inout parameter '#{name}' was moved on line #{at} and must own a buffer again #{where}; give it a new one (#{name} = ...)", l, c)
      elsif sym == :owned
        what = kind == :param ? "parameter '#{name}'" : "'#{name}'"
        fix = where.include?("try") ? "free it on that path with `errdefer a.free(#{name})` or `defer a.free(#{name})`" : "free it (a.free(#{name})), return it or pass it on"
        err("E135", "#{what} still owns its buffer #{where}; #{fix}", l, c)
      end
    end

    # Run the block on a copy of the state, then go back to the original:
    # for a way out that the code after it does not take.
    def simulate
      saved = @st
      @st = dup(saved)
      yield
    ensure
      @st = saved
    end

    # exit_line nil: the end of the defer's own block.
    def run_defer(d, exit_line, exit_col)
      saved = @defer_ctx
      @defer_ctx = exit_line.nil? ? [d.line, d.line, d.col] : [d.line, exit_line, exit_col]
      walk(d.expr)
    ensure
      @defer_ctx = saved
    end

    # ---- statements -----------------------------------------------------

    def walk_stmts(stmts)
      stmts.each do |s|
        break if @st.nil? # the rest cannot be reached
        walk_stmt(s)
      end
    end

    def walk_block(block)
      @frames << Frame.new([], [])
      walk_stmts(block.stmts)
      leave(@frames.length - 1, false, nil, nil, "at the end of its block") unless @st.nil?
      @frames.last.names.each do |n|
        @st&.delete(n)
        @decl.delete(n)
      end
      @frames.pop
    end

    def walk_stmt(stmt)
      case stmt
      in VarDecl[name:, value:, line:, col:, ty:]
        walk(value)
        declare(name, :local, line, col) if owned?(ty)
      in Assign[name:, value:, line:, col:, target:]
        if target.nil?
          walk(value)
          if @decl.key?(name)
            check_iterated(name, line, col, "assigned")
            sym, = @st[name]
            if sym == :owned
              err("E135", "assigning to '#{name}' would lose the buffer it owns; free it first (a.free(#{name}))", line, col)
            end
            @st[name] = [:owned, nil]
          end
        else
          walk_place(target)
          walk(value)
        end
      in If[cond:, then_body:, else_body:, line:, col:]
        walk(cond)
        start = @st
        @st = dup(start)
        walk_block(then_body)
        after_then = @st
        @st = dup(start)
        case else_body
        in nil then nil
        in Block then walk_block(else_body)
        in If then walk_stmt(else_body)
        end
        merge([after_then, @st], line, col, "this if")
      in While[cond:, body:, line:, col:]
        before = dup(@st)
        walk(cond)
        changed = differing(before, @st)
        changed.each do |n|
          err("E134", "the condition of this loop moves '#{n}', but it runs again on every iteration", line, col)
          @st[n] = [:poison, nil]
        end
        walk_loop(body, line, col)
      in For[iter:, body:, line:, col:]
        walk(iter, true)
        root = iter_root(iter)
        fresh = !root.nil? && !@iterated.key?(root)
        @iterated[root] = line if fresh
        walk_loop(body, line, col)
        @iterated.delete(root) if fresh
      in Switch[subject:, arms:, line:, col:]
        walk(subject)
        start = @st
        ends = arms.map do |arm|
          @st = dup(start)
          walk_block(arm.body)
          @st
        end
        merge(ends, line, col, "this switch")
      in Break[line:, col:]
        loop_exit(line, col, "break")
      in Continue[line:, col:]
        loop_exit(line, col, "continue")
      in Return[value:, line:, col:]
        walk(value) unless value.nil?
        return_paths(value).each do |error|
          simulate { leave(0, error, line, col, "at this return") }
        end
        @st = nil
      in Defer
        @frames.last.defers << stmt
      in ExprStmt[expr:]
        walk(expr)
      else
        raise "own: unhandled statement #{stmt.class}"
      end
    end

    # The buffer variable a for loop iterates over (b, or b[lo..hi]), or nil.
    def iter_root(iter)
      v = iter.is_a?(SliceExpr) ? iter.obj : iter
      v.is_a?(Var) && @decl.key?(v.name) && owned?(v.ty) ? v.name : nil
    end

    def check_iterated(name, line, col, what)
      at = @iterated[name]
      return if at.nil?
      err("E137", "'#{name}' cannot be #{what} here: the for loop on line #{at} is iterating over it", line, col)
    end

    # Does this return leave with an error (true), without one (false),
    # or maybe either ([false, true])?
    def return_paths(value)
      return [false] unless @sig.ret.start_with?("!")
      return [false] if value.nil?
      return [true] if value.is_a?(ErrorLit)
      value.ty.to_s.start_with?("!") ? [false, true] : [false]
    end

    def walk_loop(body, line, col)
      entry = dup(@st)
      @loops << Loop.new(@frames.length, entry)
      walk_block(body)
      unless @st.nil?
        loop_mismatch(entry, @st, line, col, "at the end of an iteration of this loop")
      end
      @loops.pop
      # After the loop, as at its start: it may have run zero times.
      @st = entry
    end

    def loop_exit(line, col, what)
      loop = @loops.last
      return @st = nil if loop.nil? # E126, already reported
      simulate do
        leave(loop.depth, false, line, col, "at this #{what}")
        loop_mismatch(loop.entry, @st, line, col, "at this #{what}")
      end
      @st = nil
    end

    # Every way out of an iteration must leave each outer buffer variable
    # as the loop found it.
    def loop_mismatch(entry, now, line, col, where)
      differing(entry, now).each do |n|
        was = entry[n][0] == :owned ? "owns a buffer" : "has been moved"
        is = now[n][0] == :owned ? "owns one" : "has been moved"
        err("E134", "'#{n}' #{was} when the loop starts but #{is} #{where}; each iteration must leave it as it found it", line, col)
        entry[n] = [:poison, nil]
      end
    end

    # Names whose state differs between two states (poison matches all).
    def differing(a, b)
      a.keys.select do |n|
        x = a[n][0]
        y = b[n]&.[](0)
        !y.nil? && x != y && x != :poison && y != :poison
      end
    end

    # Join the states at the ends of several paths (nil: a path that
    # returned or left a loop). They must agree on each variable.
    def merge(states, line, col, what)
      live = states.compact
      return @st = nil if live.empty?
      out = dup(live[0])
      out.each_key do |n|
        syms = live.map { |s| s[n][0] }
        if syms.include?(:poison)
          out[n] = [:poison, nil]
        elsif syms.uniq.length > 1
          err("E134", "'#{n}' is moved on some paths through #{what} but not on others; move or free it on every path, or on none", line, col)
          out[n] = [:poison, nil]
        else
          moved = live.find { |s| s[n][0] == :moved }
          out[n] = moved[n] unless moved.nil?
        end
      end
      @st = out
    end

    def dup(st)
      st&.dup
    end

    # ---- expressions ----------------------------------------------------

    # borrow: e is only looked at (b[i], @len(b), for (b)), not moved.
    def walk(e, borrow = false)
      return if @st.nil?
      case e
      in Var[name:, line:, col:]
        use(name, line, col, borrow) if @decl.key?(name) && owned?(e.ty)
      in IntLit | FloatLit | BoolLit | StrLit | EnumLit | ErrorLit | TypeExpr | NullLit | StructTypeExpr then nil
      in Unary[operand:] then walk(operand)
      in Binary[op:, lhs:, rhs:, line:, col:]
        walk(lhs)
        if op == "and" || op == "or"
          # The right side runs only sometimes.
          start = @st
          @st = dup(start)
          walk(rhs)
          merge([start, @st], line, col, "this #{op}")
        else
          walk(rhs)
        end
      in Call[args:] then walk_args(args)
      in MethodCall[obj:, args:]
        walk(obj) unless obj.ty == "module" || obj.ty == "type"
        walk_args(args)
      in Builtin[name:, args:]
        args.each { |a| walk(a, name == "len") }
      in Field[obj:] then walk(obj, true)
      in Index[obj:, index:]
        walk(obj, true)
        walk(index)
      in SliceExpr[obj:, lo:, hi:]
        walk(obj, true)
        walk(lo)
        walk(hi) unless hi.nil?
      in StructLit[fields:] then fields.each { |f| walk(f[1]) }
      in ArrayLit[items:] then items.each { |i| walk(i) }
      in AddrOf[expr: place] then walk_place(place)
      in Deref[expr: ptr] then walk(ptr)
      in Try[expr: inner, line:, col:]
        walk(inner)
        simulate { leave(0, true, line, col, "if this try returns an error") } unless @st.nil?
      in Catch[expr: inner, fallback:, line:, col:]
        walk(inner)
        start = @st
        @st = dup(start)
        walk(fallback)
        merge([start, @st], line, col, "this catch")
      else
        raise "own: unhandled expression #{e.class}"
      end
    end

    def walk_args(args)
      args.each do |a|
        if a.is_a?(AddrOf)
          # inout: the callee may replace or resize it
          check_iterated(a.expr.name, a.line, a.col, "passed as inout") if a.expr.is_a?(Var) && @decl.key?(a.expr.name)
          walk_place(a.expr)
        else
          walk(a)
        end
      end
    end

    # A place written or passed as inout: its root variable is borrowed.
    def walk_place(p)
      case p
      in Var[name:, line:, col:]
        use(name, line, col, true) if @decl.key?(name)
      in Field[obj:] then walk_place(obj)
      in Index[obj:, index:]
        walk_place(obj)
        walk(index)
      in Deref[expr: ptr] then walk(ptr)
      else walk(p)
      end
    end

    def use(name, line, col, borrow)
      sym, at = @st[name]
      case sym
      when :moved
        if @defer_ctx.nil?
          err("E136", "'#{name}' was moved on line #{at} and no longer owns a buffer; it cannot be used here", line, col)
        else
          d_line, l, c = @defer_ctx
          err("E136", "the defer on line #{d_line} uses '#{name}', which was moved on line #{at} before the defer runs here", l, c)
        end
        @st[name] = [:poison, nil]
      when :owned
        unless borrow
          check_iterated(name, line, col, "moved")
          @st[name] = [:moved, line]
        end
      end
    end
  end
end
