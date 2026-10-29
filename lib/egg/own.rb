# Ownership check (linear buffers).
#
# A Buf(T) has exactly one owner, and so does a struct or array holding
# one (an owned value). Passing it to a `sink` parameter, assigning it,
# returning it or freeing it (`a.free(v)`) moves it: the variable it came
# from no longer owns anything, and using it again is E136. Passing it to
# a plain parameter, indexing, slicing, `@len`, `for`, reading a field and
# `&v` only borrow it. A plain parameter is itself borrowed: the function
# reads it but cannot move any of it (E144), and does not have to give it
# away. Every owned value must
# be given away before its owner goes out of scope (E135): freed, moved,
# or returned; an inout parameter must own all of it again whenever the
# function returns. So a buffer is freed exactly once, and never used
# after.
#
# The state is kept per path: a buffer variable is one path, `b`; a struct
# variable is one path per buffer field, `v.data` (nested: `v.inner.data`),
# plus `v.#` for the rest of it. Moving `v.data` moves only that path, so
# `v` is partly moved: its other fields can still be used, `v` as a whole
# cannot, until `v.data = ...` gives it a buffer again. Moving `v` moves
# all its paths. Elements of arrays and buffers are not followed: they can
# be borrowed, but taken out only with @take/@replace (E139).
#
# The check follows every path through a function, after type checking:
# the state of each path (owned or moved) is tracked statement by
# statement. Where paths join (after an if, a switch, a catch, the right
# side of and/or) they must agree on each one, and each iteration of a
# loop must leave it as the loop found it (E134). `defer` and `errdefer`
# statements are replayed at every way out of their block: its end, a
# return, a break or continue, and a `try` that returns an error.
#
# While `for (b)` iterates over a buffer, the loop holds on to it: the body
# may read and write its elements, but not move, reassign or resize it
# (E137); if its elements own buffers, the body may not replace them
# either, and the loop variable only borrows each one. A call that takes
# an inout argument is judged by what the callee may change: each
# function has a summary of the parts of its inout parameters it may
# move, reassign or resize (itself or through the functions it calls), so
# `s.bump()` inside `for (s.items)` is fine when bump only changes
# s.hits. The summaries are computed first, to a fixed point (a call to a
# function not summarized yet, as in recursion, adds nothing until it
# is), and a callee without a body (a function value, an Allocator
# method) may change all of its argument.
#
# An `owned struct` (a resource) is owned for itself, not only for its
# buffers: its `v.#` path is followed like a buffer, and `@drop(v)` (in its
# own file) moves just that path, so its buffer fields must still be
# given away on their own.
#
# A path whose state is unknown after an error is "poison": it is not
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
      # Summaries first: re-run until no function's summary grows. Each
      # run only adds paths, and there are finitely many, so this ends.
      @summary = {}.compare_by_identity
      while true
        @grew = false
        @checker.concrete.each { |sig| check_func(sig) }
        break unless @grew
      end
      @diags = []
      @seen = {}
      @checker.concrete.each { |sig| check_func(sig) }
      @diags
    end

    private

    def owned?(t)
      @checker.owned?(t)
    end

    def check_func(sig)
      @sig = sig
      @file = @checker.modules[sig.func.mod || ""].file
      @frames = [Frame.new([], [])]
      @loops = []
      @st = {}     # path -> [:owned | :moved | :poison, line of the move]
      @decl = {}   # name -> [:local | :param | :bparam | :inout | :borrowed, line, col]
      @defer_ctx = nil
      @iterated = {} # path -> line of the for loop iterating it
      @borrowed = {} # loop variable borrowing an owned element -> its container, as written
      @res = {}      # v.# path of an owned struct -> its type
      @summary[sig] ||= {}
      @param_index = {}
      runtime = sig.func.params.reject { |p| p.mode == "comptime" }
      runtime.each_with_index do |p, i|
        t, mode = sig.params[i]
        kind = { "inout" => :inout, "sink" => :param }.fetch(mode, :bparam)
        @param_index[p.name] = i
        declare(p.name, kind, p.line, p.col, t) if owned?(t)
      end
      walk_stmts(sig.func.body.stmts)
      leave(0, false, nil, nil, "when '#{sig.func.name}' ends") unless @st.nil?
    end

    def declare(name, kind, line, col, t)
      # An earlier variable of this name (in a block now left) may have
      # had another type.
      @res.delete_if { |k, _| root(k) == name }
      @frames.last.names << name
      @decl[name] = [kind, line, col]
      leaves(name, t).each { |l| @st[l] = [:owned, nil] } unless @st.nil?
    end

    # ---- paths ----------------------------------------------------------

    # The paths whose state is kept for a value of type t at `path`.
    def leaves(path, t)
      info = @types[t]
      return [path] unless info.kind == :struct
      @res["#{path}.#"] = t if info.resource
      owned_fields = info.fields.select { |_, ft, _| owned?(ft) }
      ["#{path}.#"] + owned_fields.flat_map { |f, ft, _| leaves("#{path}.#{f}", ft) }
    end

    # A path that must be given away: a buffer, or an owned struct's v.#.
    def tracked?(leaf)
      !rest?(leaf) || @res.key?(leaf)
    end

    # The kept paths at `path` or inside it.
    def under(path, st = @st)
      st.keys.select { |k| k == path || k.start_with?("#{path}.") }
    end

    # v.# -> v
    def shown(leaf)
      leaf.delete_suffix(".#")
    end

    def rest?(leaf)
      leaf.end_with?(".#")
    end

    def root(path)
      path.split(".").first
    end

    # "v" or "v.f.g" for a followed variable or a chain of fields of one.
    def path_of(e)
      case e
      in Var[name:] then @decl.key?(name) ? name : nil
      in Field[obj:, name:]
        p = path_of(obj)
        !p.nil? && @types[obj.ty]&.kind == :struct ? "#{p}.#{name}" : nil
      else nil
      end
    end

    # Source text of a place, for messages.
    def place_text(e)
      case e
      in Var[name:] then name
      in Field[obj:, name:] then "#{place_text(obj)}.#{name}"
      in Index[obj:] then "#{place_text(obj)}[i]"
      in Deref[expr:] then "#{place_text(expr)}.*"
      else "this value"
      end
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
      kind, dl, dc = @decl[name]
      return if kind == :borrowed || kind == :bparam
      l = line || dl
      c = line.nil? ? dc : col
      paths = under(name).select { |k| tracked?(k) }
      if kind == :inout
        moved = paths.find { |k| @st[k][0] == :moved }
        return if moved.nil?
        at = @st[moved][1]
        if @res.key?(moved)
          m = shown(moved)
          err("E135", "inout parameter '#{name}' must hold a #{@res[moved]} again #{where}, but #{m == name ? 'it' : "'#{m}'"} was moved on line #{at}; give it a new one (#{m} = ...)", l, c)
        elsif moved == name
          err("E135", "inout parameter '#{name}' was moved on line #{at} and must own a buffer again #{where}; give it a new one (#{name} = ...)", l, c)
        else
          err("E135", "inout parameter '#{name}' must own all its buffers again #{where}, but '#{moved}' was moved on line #{at}; give it a new one (#{moved} = ...)", l, c)
        end
        return
      end
      owned = paths.select { |k| @st[k][0] == :owned }
      return if owned.empty?
      res = owned.find { |k| @res.key?(k) }
      unless res.nil?
        it = shown(res)
        what = kind == :param && it == name ? "parameter '#{name}'" : "'#{it}'"
        ends = @checker.enders(@res[res]).map { |m| "#{it}.#{m}()" }
        how = ends.empty? ? "end it with its API" : "end it with #{ends.join(' or ')}"
        err("E135", "#{what} is a #{@res[res]} that is still open #{where}; #{how}, return it or pass it on", l, c)
        return
      end
      # All of it, or the first part still owned.
      it = owned.length == paths.length ? name : owned[0]
      what = kind == :param && it == name ? "parameter '#{name}'" : "'#{it}'"
      its = it == name && paths != [name] ? "its buffers" : "its buffer"
      fix = where.include?("try") ? "free it on that path with `errdefer a.free(#{it})` or `defer a.free(#{it})`" : "free it (a.free(#{it})), return it or pass it on"
      err("E135", "#{what} still owns #{its} #{where}; #{fix}", l, c)
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

    # pre: declares loop variables in the block's frame.
    def walk_block(block, pre = nil)
      @frames << Frame.new([], [])
      pre&.call
      walk_stmts(block.stmts)
      leave(@frames.length - 1, false, nil, nil, "at the end of its block") unless @st.nil?
      @frames.last.names.each do |n|
        under(n).each { |k| @st.delete(k) } unless @st.nil?
        @decl.delete(n)
      end
      @frames.pop
    end

    def walk_stmt(stmt)
      case stmt
      in VarDecl[name:, value:, line:, col:, ty:]
        walk(value)
        declare(name, :local, line, col, ty) if owned?(ty)
      in Assign[name:, value:, line:, col:, target:]
        if target.nil?
          walk(value)
          assign_path(name, line, col) if @decl.key?(name) && !@st.nil?
        elsif owned?(target.ty)
          walk(value)
          path = path_of(target)
          if path.nil?
            walk_place(target)
            err("E139", "assigning to '#{place_text(target)}' would lose the buffers it holds; swap the new value in and free the old one: a.free(@replace(&#{place_text(target)}, v))", line, col)
          elsif !@st.nil?
            assign_path(path, line, col)
          end
        else
          walk_place(target)
          walk(value)
        end
      in If[cond: BoolLit[value: true], then_body:, else_body: nil]
        # Always taken (also what a comptime if folds to).
        walk_block(then_body)
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
      in For[iter:, var:, body:, line:, col:]
        walk(iter, true)
        root = iter_root(iter)
        fresh = !root.nil? && !@iterated.key?(root)
        @iterated[root] = line if fresh
        elem = iter.ty == "str" ? nil : @types[iter.ty]&.elem
        # An element that owns buffers is only borrowed by the loop variable.
        pre = nil
        if !elem.nil? && owned?(elem)
          @borrowed[var] = place_text(iter.is_a?(SliceExpr) ? iter.obj : iter)
          pre = -> { declare(var, :borrowed, line, col, elem) }
        end
        walk_loop(body, line, col, pre)
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

    # `path = v`: what it held must have been moved; it owns all of v now.
    def assign_path(path, line, col)
      check_iterated(path, line, col, "assigned")
      if path.include?(".")
        parent = path[0...path.rindex(".")]
        sym, at = @st["#{parent}.#"]
        if sym == :moved
          err("E136", "'#{parent}' was moved on line #{at}; give it a whole new value (#{parent} = ...) instead of one field", line, col)
          return
        end
      end
      owned = under(path).select { |k| tracked?(k) }.find { |k| @st[k][0] == :owned }
      if !owned.nil? && @res.key?(owned)
        where = shown(owned) == path ? "it holds" : "in '#{shown(owned)}'"
        err("E135", "assigning to '#{path}' would lose the open #{@res[owned]} #{where}; end it first", line, col)
      elsif !owned.nil?
        lost = owned == path ? "the buffer it owns" : "the buffer in '#{owned}'"
        err("E135", "assigning to '#{path}' would lose #{lost}; free it first (a.free(#{owned}))", line, col)
      end
      under(path).each { |k| @st[k] = [:owned, nil] }
    end

    # The owned value a for loop iterates over (b, v.data, or a slice of
    # one), or nil.
    def iter_root(iter)
      v = iter.is_a?(SliceExpr) ? iter.obj : iter
      p = path_of(v)
      !p.nil? && owned?(v.ty) ? p : nil
    end

    def overlap?(a, b)
      a == b || a.start_with?("#{b}.") || b.start_with?("#{a}.")
    end

    def check_iterated(path, line, col, what)
      note_change(path)
      key = @iterated.keys.find { |k| overlap?(k, path) }
      return if key.nil?
      err("E137", "'#{path}' cannot be #{what} here: the for loop on line #{@iterated[key]} is iterating over #{key == path ? 'it' : "'#{key}'"}", line, col)
    end

    # A change to `path`, rooted at an inout parameter, goes into this
    # function's summary as the parameter's index and the rest of the path
    # ("" for all of it, ".items" for its items field).
    def note_change(path)
      r = root(path)
      d = @decl[r]
      return if d.nil? || d[0] != :inout || !@param_index.key?(r)
      changes = (@summary[@sig][@param_index[r]] ||= [])
      rest = path[r.length..]
      return if changes.include?(rest)
      changes << rest
      @grew = true
    end

    # &place passed as parameter `i` of `callee` (nil when unknown): check
    # each part of it the callee may change against the for loops here.
    def check_inout_arg(place, callee, i, line, col)
      check_elem_change(place, line, col, "passed as inout", false)
      p = path_of(place)
      return if p.nil?
      if callee.nil? || callee.func.nil?
        check_iterated(p, line, col, "passed as inout")
        return
      end
      (@summary.dig(callee, i) || []).each do |rest|
        changed = "#{p}#{rest}"
        note_change(changed)
        key = @iterated.keys.find { |k| overlap?(k, changed) }
        next if key.nil?
        via = changed == p ? "" : " (through '#{p}')"
        err("E137", "'#{callee.name}' may move, reassign or resize '#{changed}'#{via}, but the for loop on line #{@iterated[key]} is iterating over #{key == changed ? 'it' : "'#{key}'"}; loop over an index with while, or make the change after the loop", line, col)
      end
    end

    # A place changed in place (&x, @replace): if it is (in) an element of
    # an array or buffer whose elements own buffers, a for loop over that
    # container would see a stale copy. whole: the place itself changes
    # too (false for an inout argument, which check_inout_arg judges).
    def check_elem_change(place, line, col, what, whole = true)
      p = place
      while p.is_a?(Field) || p.is_a?(Index)
        if p.is_a?(Index) && owned?(p.ty)
          c = path_of(p.obj)
          check_iterated(c, line, col, "#{what} (its elements own buffers)") unless c.nil?
        end
        p = p.obj
      end
      return unless whole
      c = path_of(place)
      check_iterated(c, line, col, what) unless c.nil?
    end

    # Does this return leave with an error (true), without one (false),
    # or maybe either ([false, true])?
    def return_paths(value)
      return [false] unless @sig.ret.start_with?("!")
      return [false] if value.nil?
      return [true] if value.is_a?(ErrorLit) || value.ty == "anyerror"
      value.ty.to_s.start_with?("!") ? [false, true] : [false]
    end

    def walk_loop(body, line, col, pre = nil)
      entry = dup(@st)
      @loops << Loop.new(@frames.length, entry)
      walk_block(body, pre)
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
        next unless tracked?(n)
        was = entry[n][0] == :owned ? (@res.key?(n) ? "is open" : "owns a buffer") : "has been moved"
        is = now[n][0] == :owned ? (@res.key?(n) ? "is open" : "owns one") : "has been moved"
        err("E134", "'#{shown(n)}' #{was} when the loop starts but #{is} #{where}; each iteration must leave it as it found it", line, col)
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
        elsif syms.uniq.length > 1 && !tracked?(n)
          # Moved whole on one path, field by field on another: either way
          # nothing is owned; the rest of it can no longer be used.
          out[n] = live.find { |s| s[n][0] == :moved }[n]
        elsif syms.uniq.length > 1
          err("E134", "'#{shown(n)}' is moved on some paths through #{what} but not on others; move or free it on every path, or on none", line, col)
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
      in Field[info: { buf_empty: true }] then nil
      in IntLit | FloatLit | BoolLit | StrLit | EnumLit | ErrorLit | TypeExpr | NullLit | StructTypeExpr then nil
      in Unary[operand:] then walk(operand)
      in Binary[op: "==" | "!=" | "<" | "<=" | ">" | ">=", lhs:, rhs:]
        # Comparing (text, the only owned values these take) only reads.
        walk(lhs, true)
        walk(rhs, true)
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
      # info[:args]: the runtime arguments, without a generic call's types.
      in Call[args:, info:] then walk_args(info&.[](:args) || args, info)
      in MethodCall[obj:, args:, info:]
        unless obj.ty == "module" || obj.ty == "type"
          if info&.[](:self_inout)
            check_inout_arg(obj, info[:sig], 0, obj.line, obj.col)
            walk_place(obj)
          else
            # self is borrowed unless the method takes `sink self`;
            # Allocator methods (no params) take what they are given.
            walk(obj, !info.nil? && !info[:params].nil? && !info[:self_sink])
          end
        end
        # m.f(K, x): a generic call into a module; info[:args] has no types.
        walk_args(info&.[](:args) || args, info)
      in Builtin[name: "drop", args:, line:, col:]
        path = path_of(args[0])
        path.nil? ? walk(args[0]) : drop(path, line, col)
      in Builtin[name: "replace" | "take" => name, args:, line:, col:]
        place = args[0].expr
        check_elem_change(place, line, col, name == "take" ? "taken from" : "replaced")
        walk_place(place)
        walk(args[1]) if name == "replace"
      in Builtin[name:, args:]
        args.each { |a| walk(a, name == "len") }
      in Field[obj:, line:, col:]
        path = path_of(e)
        if path.nil?
          walk(obj, true)
          moved_out(e, line, col) if owned?(e.ty) && !borrow
        elsif owned?(e.ty)
          use(path, line, col, borrow)
        else
          read(path, line, col)
        end
      in Index[obj:, index:, line:, col:]
        walk(obj, true)
        walk(index)
        moved_out(e, line, col) if owned?(e.ty) && !borrow
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
        case fallback
        in Return | Break | Continue then walk_stmt(fallback)
        in Block then walk_block(fallback)
        else walk(fallback)
        end
        merge([start, @st], line, col, "this catch")
      in IfExpr[cond:, then_expr:, else_expr:, line:, col:]
        # Each branch runs only sometimes; they must agree on what moved.
        walk(cond)
        start = @st
        @st = dup(start)
        walk(then_expr)
        taken = @st
        @st = dup(start)
        walk(else_expr)
        merge([taken, @st], line, col, "this if")
      in Orelse[expr: inner, fallback:, line:, col:]
        walk(inner)
        start = @st
        @st = dup(start)
        case fallback
        in Return | Break | Continue then walk_stmt(fallback)
        in Block then walk_block(fallback)
        else walk(fallback)
        end
        merge([start, @st], line, col, "this orelse")
      else
        raise "own: unhandled expression #{e.class}"
      end
    end

    # Capability methods that take what they are given: a.free and a.push.
    # The others (out.print, a.concat, a.append_str, ...) only read theirs.
    TAKING_CAP_METHODS = %w[Allocator.free Allocator.push].freeze

    # A plain parameter borrows its argument, a sink parameter takes it.
    # Without known parameters (capability methods) every argument is
    # taken by a.free and a.push and borrowed by the rest.
    def walk_args(args, info = nil)
      params = info&.[](:params)
      params = nil unless params.nil? || params.length == args.length
      cap = info&.[](:cap_method)
      callee = info&.[](:sig)
      # A method's own parameters start after self.
      shift = callee.nil? || callee.params.length == args.length ? 0 : 1
      args.each_with_index do |a, i|
        if a.is_a?(AddrOf)
          # inout: the callee may replace or resize what its summary says
          check_inout_arg(a.expr, callee, i + shift, a.line, a.col) unless a.expr.is_a?(SliceExpr)
          walk_place(a.expr)
        elsif params.nil? && !cap.nil?
          walk(a, !TAKING_CAP_METHODS.include?(cap))
        else
          walk(a, !params.nil? && params[i][1].nil?)
        end
      end
    end

    # A place written or passed as inout: it is borrowed.
    def walk_place(p)
      case p
      in Var[name:, line:, col:]
        use(name, line, col, true) if @decl.key?(name)
      in Field[obj:, line:, col:]
        path = path_of(p)
        if path.nil?
          walk_place(obj)
        elsif owned?(p.ty)
          use(path, line, col, true)
        else
          read(path, line, col)
        end
      in Index[obj:, index:]
        walk_place(obj)
        walk(index)
      in Deref[expr: ptr] then walk(ptr)
      else walk(p)
      end
    end

    # Use the owned value at `path` (all of it): borrow it, or move it.
    def use(path, line, col, borrow)
      paths = under(path)
      return if paths.empty?
      if paths.any? { |k| @st[k][0] == :poison }
        # Not reported again; but a move still moves the rest.
        paths.each { |k| @st[k] = [:moved, line] unless @st[k][0] == :poison } unless borrow
        return
      end
      moved = paths.find { |k| @st[k][0] == :moved }
      unless moved.nil?
        moved_error(path, moved, line, col)
        paths.each { |k| @st[k] = [:poison, nil] }
        return
      end
      return if borrow
      if @decl[root(path)][0] == :bparam
        borrowed_param_error(path, "moved", line, col)
        return
      end
      if @decl[root(path)][0] == :borrowed
        c = @borrowed[root(path)]
        err("E139", "'#{path}' only borrows an element of '#{c}' for one iteration; it cannot be moved. Take the element out with @take(&#{c}[i]) or @replace(&#{c}[i], v), looping over an index", line, col)
        return
      end
      check_iterated(path, line, col, "moved")
      paths.each { |k| @st[k] = [:moved, line] }
    end

    # @drop(v): moves only v.#, the owned struct itself.
    def drop(path, line, col)
      leaf = "#{path}.#"
      return if @st[leaf].nil? || @st[leaf][0] == :poison
      if @st[leaf][0] == :moved
        moved_error(path, leaf, line, col)
        @st[leaf] = [:poison, nil]
        return
      end
      if @decl[root(path)][0] == :bparam
        borrowed_param_error(path, "dropped", line, col)
        return
      end
      check_iterated(path, line, col, "dropped")
      @st[leaf] = [:moved, line]
    end

    def borrowed_param_error(path, what, line, col)
      name = root(path)
      t = @sig.params[@sig.func.params.reject { |p| p.mode == "comptime" }.index { |p| p.name == name }][0]
      err("E144", "'#{path}' cannot be #{what}: parameter '#{name}' is only borrowed; to take it over, declare it as `sink #{name}: #{t}`", line, col)
    end

    # Read a plain field at `path` (v.len): v must not have been moved.
    def read(path, line, col)
      p = path
      while p.include?(".")
        p = p[0...p.rindex(".")]
        sym, = @st["#{p}.#"]
        next if sym.nil?
        moved_error(path, "#{p}.#", line, col) if sym == :moved
        @st["#{p}.#"] = [:poison, nil] if sym == :moved
        return
      end
    end

    def moved_error(path, moved, line, col)
      at = @st[moved][1]
      m = shown(moved)
      what = if m == path && @res.key?(moved) then "'#{path}' was moved or dropped on line #{at}"
             elsif m == path then "'#{path}' was moved on line #{at} and no longer owns a buffer"
             elsif path.start_with?("#{m}.") then "'#{m}' was moved on line #{at}"
             else "'#{m}' was moved on line #{at}, so '#{path}' does not own all its buffers"
             end
      if @defer_ctx.nil?
        err("E136", "#{what}; it cannot be used here", line, col)
      else
        d_line, l, c = @defer_ctx
        err("E136", "the defer on line #{d_line} uses '#{path}', but #{what} before the defer runs here", l, c)
      end
    end

    # Moving a value out of an element (xs[i], xs[i].f): not followed, so
    # not allowed.
    def moved_out(e, line, col)
      p = e
      p = p.obj while p.is_a?(Field)
      return unless p.is_a?(Index)
      t = place_text(e)
      how = @types[e.ty].kind == :buf ? "take it with @take(&#{t}) or swap it with @replace(&#{t}, v)" : "swap it out with @replace(&#{t}, v)"
      err("E139", "cannot move '#{t}' out of an element of '#{place_text(p.obj)}'; #{how}", line, col)
    end
  end
end
