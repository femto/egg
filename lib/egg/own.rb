require "set"

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
# A local slice (`const s = b[lo..hi]`) borrows the place it views until its
# last use, not to the end of its block: while s is used later, b cannot be
# moved, assigned, resized or passed as inout, nor its elements written
# (E149). A writable one (`inout s = &b[lo..hi]`) is exclusive: while s is used
# later, b cannot be read either, except through s or a slice of s. Later means the rest of each enclosing block, a loop around the
# slice, and the defers still to run, on the paths that really go there: code
# ending in return, break or continue does not reach what it jumps past.
#
# An `owned struct` (a resource) is owned for itself, not only for its
# buffers: its `v.#` path is followed like a buffer, and `@forget(v)` (in its
# own file) moves just that path, so its buffer fields must still be
# given away on their own.
#
# A path whose state is unknown after an error is "poison": it is not
# reported again.

module Egg
  class OwnershipChecker
    # names: buffer variables declared in this block; defers: Defer nodes
    Frame = Struct.new(:names, :defers, :slices)
    # What runs after the current statement of a block: stmts, the statements
    # after it; stmt, that statement; loop: the enclosing loop starts again.
    Later = Struct.new(:stmts, :stmt, :loop)
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
      @frames = [Frame.new([], [], [])]
      @slices = {}
      @slice_errs = Set.new
      @rest = []
      @now = nil
      @stmt = nil
      @leaving = false
      @ran = []
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
        ran = @ran
        @ran = ran.dup
        f.defers.reverse_each do |d|
          @ran << d
          run_defer(d, line, col) if !d.err || error
        end
        @ran = ran
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

    # Code run on the way out of the function: only its defers still use a
    # slice.
    def leaving
      saved = @leaving
      @leaving = true
      yield
    ensure
      @leaving = saved
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
      saved = [@now, @stmt]
      stmts.each_with_index do |s, i|
        break if @st.nil? # the rest cannot be reached
        @rest << Later.new(stmts[(i + 1)..], s, false)
        @stmt = s
        @now = stmt_head(s)
        walk_stmt(s)
        @rest.pop
      end
      @now, @stmt = saved
    end

    # The part of a statement that runs at once: for one with blocks, what
    # decides which of them runs.
    def stmt_head(s)
      case s
      in If[cond:] then cond
      in While[cond:] then cond
      in For[iter:] then iter
      in Switch[subject:] then subject
      in Select[arms:] then arms.flat_map { |a| [a.chan, a.call, a.value].compact }
      in Defer then nil
      else s
      end
    end

    # ---- local slices ----------------------------------------------------

    # A local slice borrows what it views until its last use. @slices: its
    # name -> [the paths it views, how deep in @rest it was declared, whether
    # it is writable, the slice it was taken from]. A slice taken from a
    # place views one path; the result of a call that lends a slice views
    # every argument the callee's signature says it borrows.

    def place_path(e)
      case e
      in Var[name:] then @slices.key?(name) ? @slices[name][0].first : name
      in Field[obj:, name:]
        path = place_path(obj)
        path.nil? ? nil : "#{path}.#{name}"
      in Index[obj:] then place_path(obj)
      in SliceExpr[obj:] then place_path(obj)
      else nil
      end
    end

    # The paths a slice-valued expression views (none for static text).
    def paths_of(e)
      case e
      in Var[name:] then @slices.key?(name) ? @slices[name][0] : [name]
      in Field[obj:, name:] then paths_of(obj).map { |p| "#{p}.#{name}" }
      in Index[obj:] then paths_of(obj)
      in SliceExpr[obj:] then paths_of(obj)
      in Call | MethodCall then (e.info&.dig(:borrow_args) || []).flat_map { |a| paths_of(a) }.uniq
      in Orelse | Catch
        fb = e.fallback
        fb = nil if fb.is_a?(Return) || fb.is_a?(Break) || fb.is_a?(Continue) || fb.is_a?(Block)
        (paths_of(e.expr) + (fb.nil? ? [] : paths_of(fb))).uniq
      in Try[expr:] then paths_of(expr)
      else []
      end
    end

    # depth: where in @rest its block's statements are (a capture is
    # declared before its block runs).
    def declare_slice(name, value, writable, depth = @rest.length - 1)
      paths = paths_of(value)
      return if paths.empty?
      @slices[name] = [paths, depth, writable, place_root(value)]
      @frames.last.slices << name
    end

    def slice_type?(t)
      t = t[1..] if t.start_with?("!")
      t = t[1..] if t.start_with?("?")
      t.start_with?("[]")
    end

    def place_root(e)
      case e
      in Var[name:] then name
      in Field | Index | SliceExpr then place_root(e.obj)
      else nil
      end
    end

    # The slices name goes through: itself, and those it was taken from.
    def views_of(name)
      out = []
      while @slices.key?(name)
        out << name
        name = @slices[name][3]
      end
      out
    end

    # Does this node, or anything in it, read the variable name?
    def reads?(node, name)
      case node
      when Var then node.name == name
      when Assign then node.name == name || reads?(node.target, name) || reads?(node.value, name)
      when Array then node.any? { |n| reads?(n, name) }
      when Struct then node.each_pair.any? { |k, v| !%i[info ty].include?(k) && reads?(v, name) }
      else false
      end
    end

    # Structured code makes this simple: what runs later is the rest of each
    # enclosing block, out to the block that declared the slice, and all of a
    # loop around it, unless a block ends by jumping past them.
    def live?(name, depth)
      waiting = @frames.flat_map(&:defers).reject { |d| @ran.any? { |r| r.equal?(d) } }
      return true if reads?(waiting, name)
      return false if @leaving
      return true if !@now.nil? && reads?(@now, name)
      i = @rest.length - 1
      while i >= depth
        later = @rest[i]
        stop = later.stmts.index { |s| jump?(s) }
        return true if reads?(stop.nil? ? later.stmts : later.stmts[..stop], name)
        case stop.nil? ? later.stmt : later.stmts[stop]
        in Return then return false
        in Break
          i -= 1 until i < 0 || @rest[i].loop
          i -= 1
        in Continue
          i -= 1 until i < 0 || @rest[i].loop
        else i -= 1
        end
      end
      false
    end

    def jump?(stmt)
      case stmt
      in Return | Break | Continue then true
      else false
      end
    end

    # Something changes path: no slice of it may be used afterwards, except
    # the ones the change goes through (by: the variable it starts from).
    def check_slices(path, line, col, what, by = nil)
      return if path.nil?
      through = views_of(by)
      @slices.each do |name, (viewed, depth, _, _, kind)|
        next if through.include?(name)
        next unless viewed.any? { |v| overlap?(v, path) } && live?(name, depth)
        slice_err("'#{path}' cannot be #{what} here: the #{kind == :borrow ? "borrow" : "slice"} '#{name}' of it is used later", line, col)
      end
    end

    # One report for one place: a.free(b) both reads b and moves it.
    def slice_err(msg, line, col)
      return unless @slice_errs.add?([line, col])
      err("E149", msg, line, col)
    end

    # A read of e: no other way in may write what it reads while it is used.
    def check_read(e)
      return unless @slices.any? { |_, s| s[2] }
      path = place_path(e)
      return if path.nil?
      through = views_of(place_root(e))
      @slices.each do |name, (viewed, depth, writable, _, kind)|
        next if !writable || through.include?(name)
        next unless viewed.any? { |v| overlap?(v, path) } && live?(name, depth)
        slice_err("'#{path}' cannot be read here: the writable #{kind == :borrow ? "borrow" : "slice"} '#{name}' of it is used later", e.line, e.col)
      end
    end

    # pre: declares loop variables in the block's frame.
    def walk_block(block, pre = nil)
      @frames << Frame.new([], [], [])
      pre&.call
      walk_stmts(block.stmts)
      leave(@frames.length - 1, false, nil, nil, "at the end of its block") unless @st.nil?
      @frames.last.names.each do |n|
        under(n).each { |k| @st.delete(k) } unless @st.nil?
        @decl.delete(n)
      end
      @frames.last.slices.each { |n| @slices.delete(n) }
      @frames.pop
    end

    def walk_stmt(stmt)
      case stmt
      in VarDecl[name:, value: AddrOf[expr: place, info: { borrow: Symbol => kind }], line:, col:, ty:]
        # const r = &p / inout r = &p: r stands for p until its last use.
        writable = kind == :mut
        if writable
          check_slices(place_path(place), line, col, "borrowed as writable", place_root(place))
          walk_place(place)
        else
          walk(place, true)
        end
        if owned?(ty)
          text = place_text(place)
          how = writable ? "; to take its value out, swap one in with @replace(&#{name}, v)" : ""
          @borrowed[name] = [:borrow, "it borrows '#{text}'#{how}"]
          declare(name, :borrowed, line, col, ty)
        end
        path = place_path(place)
        unless path.nil?
          @slices[name] = [[path], @rest.length - 1, writable, place_root(place), :borrow]
          @frames.last.slices << name
        end
      in VarDecl[name:, value:, line:, col:, ty:, inout:]
        check_slices(place_path(value), line, col, "lent as a writable slice", place_root(value)) if inout
        @read_whole = value.obj if inout # judged just above
        walk(value, value.is_a?(SliceExpr) || ty.start_with?("[]"))
        declare(name, :local, line, col, ty) if owned?(ty)
        declare_slice(name, value, inout == true) if slice_type?(ty)
      in Assign[name:, value:, line:, col:, target:]
        check_slices(target.nil? ? name : place_path(target), line, col, "assigned", target.nil? ? nil : place_root(target))
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
      in If[cond:, then_body:, else_body:, line:, col:, capture:]
        walk(cond)
        start = @st
        @st = dup(start)
        inner = capture.nil? ? nil : @types[cond.ty].inner
        pre = !inner.nil? && owned?(inner) ? -> { declare(capture, :local, line, col, inner) } : nil
        # if (find(s)) |v|: v views what the optional slice does.
        pre = -> { declare_slice(capture, cond, false, @rest.length) } if !inner.nil? && slice_type?(inner)
        walk_block(then_body, pre)
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
        # for (trim(s)) |c|: what the result views stays put while it runs.
        lent = %w[Call MethodCall Orelse Catch Try].include?(iter.class.name.split("::").last) && slice_type?(iter.ty) ? paths_of(iter).reject { |p| @iterated.key?(p) } : []
        lent.each { |p| @iterated[p] = line }
        elem = iter.ty == "str" ? nil : @types[iter.ty]&.elem
        # An element that owns buffers is only borrowed by the loop variable.
        pre = nil
        if !elem.nil? && owned?(elem)
          @borrowed[var] = place_text(iter.is_a?(SliceExpr) ? iter.obj : iter)
          pre = -> { declare(var, :borrowed, line, col, elem) }
        end
        walk_loop(body, line, col, pre)
        @iterated.delete(root) if fresh
        lent.each { |p| @iterated.delete(p) }
      in Switch[subject:, arms:, line:, col:] if owned?(subject.ty) && @types[subject.ty].kind == :union
        walk_union_switch(subject, arms, line, col)
      in Switch[subject:, arms:, line:, col:]
        walk(subject)
        start = @st
        ends = arms.map do |arm|
          @st = dup(start)
          walk_block(arm.body)
          @st
        end
        merge(ends, line, col, "this switch")
      in Select[arms:, line:, col:]
        # Every head is evaluated before waiting; a sent value moves only
        # in its own arm, so the other arms still have it.
        arms.each do |arm|
          walk(arm.chan, true) unless arm.chan.nil?
          walk(arm.call.obj, true) unless arm.call.nil?
          walk(arm.value) unless arm.value.nil?
        end
        start = @st
        ends = arms.map do |arm|
          @st = dup(start)
          pre = nil
          if arm.kind == :send
            pre = -> { walk(arm.call) }
          elsif arm.kind == :recv && !arm.capture.nil?
            elem = @types[arm.chan.ty]&.elem
            pre = -> { declare(arm.capture, :local, arm.line, arm.col, elem) } if !elem.nil? && owned?(elem)
          end
          walk_block(arm.body, pre)
          @st
        end
        merge(ends, line, col, "this select")
      in Break[line:, col:]
        loop_exit(line, col, "break")
      in Continue[line:, col:]
        loop_exit(line, col, "continue")
      in Return[value:, line:, col:]
        walk(value) unless value.nil?
        return_paths(value).each do |error|
          leaving { simulate { leave(0, error, line, col, "at this return") } }
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

    # switch over an owned union. The subject is only borrowed, and so is
    # each capture, unless an arm moves its capture (or part of it): then
    # that arm takes the payload out, which moves the whole union, and the
    # capture is owned and must be given away there. An arm for members
    # that own nothing leaves the union :gone, which agrees with both owned
    # and moved where the arms join: on that path there is nothing to free.
    def walk_union_switch(subject, arms, line, col)
      info = @types[subject.ty]
      walk(subject, true)
      return if @st.nil?
      path = path_of(subject)
      kind = path.nil? ? nil : @decl[root(path)][0]
      text = place_text(subject)
      member = ->(n) { info.fields.find { |m, _| m == n }&.[](1) }
      start = @st
      ends = arms.map do |arm|
        @st = dup(start)
        pre = nil
        t = arm.names&.length == 1 ? member.(arm.names[0]) : nil
        if !arm.capture.nil? && arm.capture != "_" && !t.nil? && owned?(t)
          cap = arm.capture
          if !path.nil? && kind != :bparam && kind != :borrowed && probe_moves?(arm, cap, t, path)
            pre = lambda do
              use(path, arm.line, arm.col, false)
              declare(cap, :local, arm.line, arm.col, t)
            end
          else
            why = case kind
                  when :bparam then "'#{text}', which is only borrowed here; to take its payload, declare parameter '#{root(path)}' as sink"
                  when :borrowed
                    c = @borrowed[root(path)]
                    c.is_a?(Array) ? "'#{text}', which #{c[1].delete_prefix("it ")}" : "'#{text}', which only borrows an element of '#{c}'"
                  else "'#{text}', which cannot be moved; swap it out with @replace(&#{text}, v) and switch on that"
                  end
            pre = lambda do
              @borrowed[cap] = [:payload, "it borrows the payload of #{why}"]
              declare(cap, :borrowed, arm.line, arm.col, t)
            end
          end
        elsif !path.nil? && !arm.names.nil? && arm.names.all? { |n| (m = member.(n)) == "void" || !owned?(m) }
          under(path).each { |k| @st[k] = [:gone, nil] if @st[k][0] == :owned }
        end
        walk_block(arm.body, pre)
        @st
      end
      merge(ends, line, col, "this switch")
    end

    # Whether the arm moves its capture (or part of it), found by walking
    # it once with the capture owned and nothing reported.
    def probe_moves?(arm, cap, t, path)
      saved = [@st, @diags, @seen, @slices, @slice_errs, @iterated, @borrowed, @res, @grew, @probe, @probe_hit, @read_whole]
      @st = dup(@st)
      @diags = []
      @seen = {}
      @slices = @slices.dup
      @slice_errs = @slice_errs.dup
      @iterated = @iterated.dup
      @borrowed = @borrowed.dup
      @res = @res.dup
      @probe = cap
      @probe_hit = false
      under(path).each { |k| @st[k] = [:moved, arm.line] }
      walk_block(arm.body, -> { declare(cap, :local, arm.line, arm.col, t) })
      @probe_hit
    ensure
      @st, @diags, @seen, @slices, @slice_errs, @iterated, @borrowed, @res, @grew, @probe, hit, @read_whole = saved
      @probe_hit = hit
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
      @rest << Later.new([@stmt], nil, true)
      walk_block(body, pre)
      @rest.pop
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
      # :gone (a union whose member owns nothing) takes the others' state.
      live.flat_map(&:keys).uniq.each do |n|
        next unless live.any? { |s| s[n]&.[](0) == :gone }
        other = live.map { |s| s[n] }.find { |v| !v.nil? && v[0] != :gone } || [:owned, nil]
        live.each { |s| s[n] = other if s[n]&.[](0) == :gone }
      end
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
      if e.is_a?(Var) || e.is_a?(Field)
        check_read(e) unless @read_whole.equal?(e)
        @read_whole = e.obj if e.is_a?(Field) # v.f does not read all of v
      end
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
            check_slices(place_path(obj), obj.line, obj.col, "changed", place_root(obj))
            check_inout_arg(obj, info[:sig], 0, obj.line, obj.col)
            walk_place(obj)
          else
            # self is borrowed unless the method takes `sink self`, or it
            # closes a file; capability values own nothing.
            cap = info&.[](:cap_method)
            ends = !cap.nil? && %w[close join detach].include?(cap.split(".").last)
            walk(obj, !info.nil? && !ends && (!cap.nil? || (!info[:params].nil? && !info[:self_sink])))
          end
        end
        # m.f(K, x): a generic call into a module; info[:args] has no types.
        walk_args(info&.[](:args) || args, info)
      in Builtin[name: "forget", args:, line:, col:]
        path = path_of(args[0])
        path.nil? ? walk(args[0]) : forget(path, line, col)
      in Builtin[name: "replace" | "take" => name, args:, line:, col:]
        place = args[0].expr
        check_slices(place_path(place), line, col, "changed", place_root(place))
        check_elem_change(place, line, col, name == "take" ? "taken from" : "replaced")
        walk_place(place)
        walk(args[1]) if name == "replace"
      in Builtin[name: "swap", args:, line:, col:]
        args[0].info[:places].each do |p|
          check_slices(place_path(p), line, col, "changed", place_root(p))
          check_elem_change(p, line, col, "swapped")
        end
        walk_place(args[0].expr)
        walk(args[1])
        walk(args[2])
      in Builtin[name:, args:]
        # @len, @strPtr and @bufPtr look at a buffer without taking it.
        # Through @bufPtr C may write it, so no slice of it may be in use.
        check_slices(place_path(args[0]), e.line, e.col, "written through @bufPtr", place_root(args[0])) if name == "bufPtr"
        args.each { |a| walk(a, %w[len strPtr bufPtr].include?(name)) }
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
        leaving { simulate { leave(0, true, line, col, "if this try returns an error") } } unless @st.nil?
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

    # Capability methods that take what they are given: a.free and a.push,
    # and a Poller's add and add_listener, which take the socket.
    # The others (io.print, a.concat, a.append_str, ...) only read theirs.
    TAKING_CAP_METHODS = %w[Allocator.free Allocator.push Poller.add Poller.add_listener].freeze

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
          check_slices(place_path(a.expr), a.line, a.col, "changed", place_root(a.expr))
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
      @probe_hit = true if !@probe.nil? && root(path) == @probe
      check_slices(path, line, col, "moved")
      if @decl[root(path)][0] == :bparam
        borrowed_param_error(path, "moved", line, col)
        return
      end
      if @decl[root(path)][0] == :borrowed
        c = @borrowed[root(path)]
        if c.is_a?(Array)
          err("E139", "'#{path}' cannot be moved: #{c[1]}", line, col)
          return
        end
        err("E139", "'#{path}' only borrows an element of '#{c}' for one iteration; it cannot be moved. Take the element out with @take(&#{c}[i]) or @replace(&#{c}[i], v), looping over an index", line, col)
        return
      end
      check_iterated(path, line, col, "moved")
      paths.each { |k| @st[k] = [:moved, line] }
    end

    # @forget(v): moves only v.#, the owned struct itself.
    def forget(path, line, col)
      leaf = "#{path}.#"
      return if @st[leaf].nil? || @st[leaf][0] == :poison
      if @st[leaf][0] == :moved
        moved_error(path, leaf, line, col)
        @st[leaf] = [:poison, nil]
        return
      end
      if @decl[root(path)][0] == :bparam
        borrowed_param_error(path, "forgotten", line, col)
        return
      end
      check_iterated(path, line, col, "forgotten")
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
      what = if m == path && @res.key?(moved) then "'#{path}' was moved or forgotten on line #{at}"
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
