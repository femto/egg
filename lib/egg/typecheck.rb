# Type checker.
#
# Types are canonical strings: "i64", "bool", "str", "void", "Point",
# "Pair(i64)", "[3]i64", "[]i64", "!i64". `@types` maps each one to a TInfo
# with its structure. Two pseudo types: "type" (a type used as a value,
# compile time only) and "anyerror" (an `error.X` literal, which fits any
# `!T`). "error" marks an expression that already produced a diagnostic,
# so one mistake does not cascade into many.
#
# Every expression node gets `ty` (its type) and `info` (facts for the code
# generator). Generic functions and type functions are instantiated per
# set of comptime arguments by deep-copying their AST, so each instance
# is checked and annotated on its own (as Zig does).
#
# Like Zig, the checker rejects ambiguity rather than guessing:
#   - unused local variables            (E110)
#   - `var` that is never reassigned     (E111)
#   - a non-void result that is ignored  (E113)
#   - shadowing an outer name            (E106)
# Slices are second-class (E116): they exist only as parameters, so a
# borrowed view can never outlive what it points into.
#
# Modules: the Loader has renamed every imported top-level name to
# "m.name"; `@mod` is the module whose code is being checked, and
# `qualify` turns a name as written there ("Point", "m.Point") into the
# global one. The checker also records, per function, the capabilities it
# uses directly and the functions it calls, for the capability check
# (caps.rb).
#
# Pointer operations and `extern fn` need `allow unsafe` in their own file
# (E131); unlike capabilities, this is not carried along calls.

module Egg
  VarInfo = Struct.new(:type, :mutable, :used, :mutated, :line, :col, :param, :inout)
  # params: [[type, mode]] (comptime parameters removed); ret: type
  # direct: capability -> [line, col, what] for its first direct use
  # calls: [[Sig, line, col]] for every call in the body
  # unused: names of parameters the body never reads (Egg allows them; C
  # warns, so codegen marks them used)
  Sig = Struct.new(:name, :params, :ret, :func, :c_name, :tenv, :this, :owner, :checked, :direct, :calls, :unused)
  # fields: [[name, type, line]]; members (enum): names; member_lines: their lines
  # mod: prefix of the module that declares the type (for #line marks)
  TInfo = Struct.new(:canon, :kind, :fields, :members, :elem, :len, :inner, :c_name, :line, :col, :member_lines, :fn_line, :return_line, :mod)

  class TypeChecker
    # Io and Allocator are capability values: opaque, and only `main`
    # receives them (from the runtime); everything else is passed them.
    INT_TYPES = %w[i8 i16 i32 i64 u8 u16 u32 u64 usize].freeze
    # Literal ranges; usize is checked as u64 here and against the
    # target's real width (SIZE_MAX) at run time.
    INT_RANGE = {
      "i8" => [-128, 127], "i16" => [-32_768, 32_767],
      "i32" => [-2_147_483_648, 2_147_483_647],
      "i64" => [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807],
      "u8" => [0, 255], "u16" => [0, 65_535], "u32" => [0, 4_294_967_295],
      "u64" => [0, 18_446_744_073_709_551_615], "usize" => [0, 18_446_744_073_709_551_615]
    }.freeze
    PRIMS = (INT_TYPES + %w[bool str void Io Allocator]).freeze
    CAP_TYPES = { "Io" => "io", "Allocator" => "alloc" }.freeze
    CAPABILITIES = %w[alloc io].freeze
    # Methods of capability values: name -> [parameter types, result]
    # ("printable" accepts integers, bool, str and enums; "integer" any
    # integer type).
    CAP_METHODS = {
      "Io" => { "print" => [["printable"], "void"] },
      "Allocator" => { "concat" => [%w[str str], "str"], "int_str" => [["integer"], "str"],
                       "create" => [["value"], "pointer to the value"] }
    }.freeze
    ARITH_OPS = %w[+ - * / %].freeze
    ORDER_OPS = %w[< <= > >=].freeze
    # Builtins and how many arguments each takes.
    BUILTIN_ARITY = { "len" => 1, "sizeOf" => 1, "typeName" => 1, "splat" => 1, "as" => 2,
                      "ptrAdd" => 2, "ptrCast" => 2, "intFromPtr" => 1, "ptrFromInt" => 2, "strPtr" => 1 }.freeze
    # Builtins that need `allow unsafe`.
    UNSAFE_BUILTINS = %w[ptrAdd ptrCast intFromPtr ptrFromInt strPtr].freeze
    BUILTINS = BUILTIN_ARITY.keys.freeze

    # Names an extern fn may not take: C keywords, and the functions of the
    # C headers the generated code includes (redeclaring one with Egg's
    # types would not compile).
    C_RESERVED = %w[
      auto break case char const continue default do double else enum extern float for goto if inline int long
      register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while
      _Bool _Complex _Imaginary bool true false main
      remove rename tmpfile tmpnam fclose fflush fopen freopen setbuf setvbuf fprintf fscanf printf scanf snprintf
      sprintf sscanf vfprintf vfscanf vprintf vscanf vsnprintf vsprintf vsscanf fgetc fgets fputc fputs getc getchar
      gets putc putchar puts ungetc fread fwrite fgetpos fseek fsetpos ftell rewind clearerr feof ferror perror
      stdin stdout stderr
      atof atoi atol atoll strtod strtof strtold strtol strtoll strtoul strtoull rand srand calloc free malloc realloc
      abort atexit exit _Exit getenv system bsearch qsort abs labs llabs div ldiv lldiv mblen mbtowc wctomb mbstowcs
      wcstombs
      memcpy memmove strcpy strncpy strcat strncat memcmp strcmp strcoll strncmp strxfrm memchr strchr strcspn strpbrk
      strrchr strspn strstr strtok memset strerror strlen
      imaxabs imaxdiv strtoimax strtoumax wcstoimax wcstoumax
    ].freeze
    # Prefixes of generated C names.
    C_PREFIXES = %w[egg_ fn_ ty_ v_ f_ m_ _t].freeze

    attr_reader :diagnostics, :types, :type_order, :concrete, :error_names, :main_sig, :modules, :externs

    def initialize(program)
      @program = program
      @diagnostics = []
      @types = {}          # canon -> TInfo
      @type_order = []     # canons in registration order
      @decls = {}          # name -> TypeDecl
      @type_fns = {}       # name -> Func returning `type`
      @generic_fns = {}    # name -> Func with comptime parameters
      @sigs = {}           # key -> Sig ("f", "Point.len", "max(i64)", "Pair(i64).sum")
      @concrete = []       # Sigs whose bodies are checked, in order: code to emit
      @queue = []
      @error_names = []    # error.X names; the id of X is its index + 1
      @c_names = {}
      @scopes = []
      @tenv = {}
      @this = nil
      @current = nil
      @loop_depth = 0
      @externs = []        # Sigs of extern fns, in order
      @extern_c = {}       # C name -> Sig, to catch clashing declarations
      @modules = program.modules || { "" => ModuleInfo.new("", nil, nil, program.uses || [], {}, [], [], program.allows || []) }
      @mod = @modules[""]
      PRIMS.each { |p| @types[p] = TInfo.new(p, :prim) }
    end

    def check
      collect
      until @queue.empty?
        sig = @queue.shift
        check_body(sig)
      end
      check_main
      check_recursive_structs
      @diagnostics
    end

    def c_type_name(canon)
      @types[canon].c_name
    end

    private

    # ---- top level ----------------------------------------------------

    def collect
      @modules.each_value { |m| in_module(m.prefix) { check_uses(m) } }
      @program.types.each do |d|
        in_module(d.mod) do
          if @decls.key?(d.name) || PRIMS.include?(base_name(d.name))
            err("E106", "type '#{d.name}' is defined more than once", d.line, d.col)
            next
          end
          @decls[d.name] = d
        end
      end
      @program.funcs.each do |f|
        in_module(f.mod) do
          if @decls.key?(f.name) || @sigs.key?(f.name) || @type_fns.key?(f.name) || @generic_fns.key?(f.name)
            err("E106", "function '#{f.name}' is defined more than once", f.line, f.col)
            next
          end
          if !f.ext.nil?
            sig = new_sig(f.name, f, base_name(f.name), {}, nil, nil)
            sig.checked = true # no body
            @sigs[f.name] = sig
          elsif f.ret == "type"
            @type_fns[f.name] = f
          elsif f.params.any? { |p| p.mode == "comptime" }
            @generic_fns[f.name] = f
          else
            @sigs[f.name] = new_sig(f.name, f, c_name("fn_#{f.name}"), {}, nil, nil)
          end
        end
      end
      # Types first (so signatures can refer to them), then signatures.
      @decls.each_value { |d| register_decl(d) }
      @program.funcs.each do |f|
        sig = @sigs[f.name]
        next if sig.nil? || sig.func != f
        build_sig(sig)
        if f.ext.nil?
          enqueue(sig)
        else
          in_module(f.mod) { check_extern(sig) }
        end
      end
    end

    # extern fn name(params) R [uses ...]: a C function called by its own
    # name. Only scalars and pointers cross, so the C types are exact.
    def check_extern(sig)
      f = sig.func
      return unless require_unsafe("extern fn", f.line, f.col)
      c = sig.c_name
      if C_RESERVED.include?(c) || C_PREFIXES.any? { |p| c.start_with?(p) }
        err("E132", "an extern fn cannot be named '#{c}': it is a C keyword, a function of the C headers eggc includes, or a prefix eggc uses", f.line, f.col)
        return
      end
      if f.params.any? { |p| !p.mode.nil? }
        err("E132", "an extern fn takes its parameters by value; no inout or comptime", f.line, f.col)
        return
      end
      bad = sig.params.map(&:first).find { |t| t != "error" && !c_scalar?(t) }
      bad ||= sig.ret unless sig.ret == "void" || sig.ret == "error" || c_scalar?(sig.ret)
      unless bad.nil?
        err("E132", "an extern fn passes only integers, bool, pointers and function values (and may return void), not #{bad}", f.line, f.col)
        return
      end
      f.ext.each do |u|
        if CAPABILITIES.include?(u.name)
          sig.direct[u.name] ||= [u.line, u.col, "extern fn #{c}"]
        else
          err("E128", "unknown capability '#{u.name}' (capabilities: #{CAPABILITIES.join(', ')})", u.line, u.col)
        end
      end
      other = @extern_c[c]
      if !other.nil? && (other.params != sig.params || other.ret != sig.ret)
        err("E132", "extern fn '#{c}' is declared elsewhere with a different signature", f.line, f.col)
        return
      end
      @extern_c[c] ||= sig
      @externs << sig if other.nil?
      @c_names[c] = true
    end

    # A type that crosses into C as itself.
    def c_scalar?(t)
      int?(t) || t == "bool" || %i[ptr fn].include?(@types[t]&.kind)
    end

    # `uses alloc, io`: known capabilities, each named once.
    def check_uses(m)
      seen = {}
      m.uses.each do |u|
        if !CAPABILITIES.include?(u.name)
          err("E128", "unknown capability '#{u.name}' (capabilities: #{CAPABILITIES.join(', ')})", u.line, u.col)
        elsif seen[u.name]
          err("E128", "capability '#{u.name}' is declared twice", u.line, u.col)
        end
        seen[u.name] = true
      end
      m.allows.each do |u|
        err("E131", "only `allow unsafe` exists, found `allow #{u.name}`", u.line, u.col) unless u.name == "unsafe"
      end
    end

    # Is the current module `allow unsafe`?
    def unsafe?
      @mod.allows.any? { |u| u.name == "unsafe" }
    end

    # Pointer operations need `allow unsafe` in the file (E131).
    def require_unsafe(what, line, col)
      return true if unsafe?
      where = @mod.file.nil? ? "the file" : @mod.file
      err("E131", "#{what} needs `allow unsafe`: add it at the top of #{where}", line, col)
      false
    end

    # "*T", registered.
    def ptr_type(inner)
      canon = "*#{inner}"
      register(canon, :ptr, nil, nil).inner = inner
      canon
    end

    # The type a pointer type points to, or nil.
    def pointee(t)
      info = @types[t]
      info&.kind == :ptr ? info.inner : nil
    end

    # Methods are keyed apart from functions, which may be named "m.f".
    def method_key(owner, name)
      "#{owner}::#{name}"
    end

    def new_sig(name, func, c_name, tenv, this, owner)
      Sig.new(name, nil, nil, func, c_name, tenv, this, owner, false, {}, [])
    end

    # "m.Point" -> "Point"
    def base_name(name)
      i = name.rindex(".")
      i.nil? ? name : name[(i + 1)..]
    end

    def in_module(prefix)
      saved = @mod
      @mod = @modules[prefix || ""]
      yield
    ensure
      @mod = saved
    end

    # A name as written in the current module -> its global name: "Point"
    # declared here -> "m.Point"; "u.Point" with `const u = @import(...)`
    # -> that module's "Point". Anything else is returned unchanged (a
    # primitive, a local, or an unknown name the caller reports).
    def qualify(name)
      dot = name.index(".")
      if dot.nil?
        return @mod.names.include?(name) ? Egg.qualify(@mod, name) : name
      end
      prefix = @mod.aliases[name[0...dot]]
      return name if prefix.nil?
      target = @modules[prefix]
      rest = name[(dot + 1)..]
      target.names.include?(rest) ? Egg.qualify(target, rest) : name
    end

    # The module an expression names (`m` with `const m = @import(...)`),
    # or nil.
    def module_ref(e)
      return nil unless e.is_a?(Var) && lookup(e.name).nil?
      prefix = @mod.aliases[e.name]
      prefix.nil? ? nil : @modules[prefix]
    end

    def enqueue(sig)
      return if sig.checked
      sig.checked = true
      @queue << sig
    end

    # main returns void, i64 or !void, and takes only capability values
    # (each at most once), which the runtime creates.
    def check_main
      sig = @sigs["main"]
      if sig.nil?
        err("E109", "program has no 'main' function", 1, 1)
      else
        f = sig.func
        types = sig.params.map(&:first)
        bad = sig.params.any? { |t, mode| !CAP_TYPES.key?(t) || !mode.nil? } || types.uniq.length != types.length
        if bad
          err("E109", "'main' takes only capability values, each at most once, such as (out: Io, a: Allocator)", f.line, f.col)
        elsif !%w[void i64 !void].include?(sig.ret)
          err("E109", "'main' must return void, i64 or !void", f.line, f.col)
        end
      end
      @main_sig = sig
    end

    # Resolve parameter and return types of a signature (in its type env).
    def build_sig(sig)
      f = sig.func
      with_env(sig.tenv, sig.this, f.mod) do
        sig.params = []
        f.params.each do |p|
          next if p.mode == "comptime"
          t = resolve_type(p.type, p.line, p.col)
          if t == "void" || t == "type"
            err("E108", t == "void" ? "a value cannot have type void" : "only a comptime parameter can have type 'type'", p.line, p.col)
            t = "error"
          end
          sig.params << [t, p.mode]
        end
        r = resolve_type(f.ret, f.line, f.col)
        if r.start_with?("[]")
          err("E116", "a function cannot return a slice; slices exist only as parameters", f.line, f.col)
        elsif r == "type"
          err("E120", "only a type function (`fn Name(comptime T: type) type`) returns 'type'", f.line, f.col)
        end
        sig.ret = r
      end
    end

    # ---- types --------------------------------------------------------

    def with_env(tenv, this, mod)
      saved = [@tenv, @this, @mod]
      @tenv = tenv
      @this = this
      @mod = @modules[mod || ""]
      yield
    ensure
      @tenv, @this, @mod = saved
    end

    def register(canon, kind, line, col)
      info = @types[canon]
      return info unless info.nil?
      info = TInfo.new(canon, kind)
      info.line = line
      info.col = col
      info.c_name = c_name("ty_#{canon}")
      @types[canon] = info
      @type_order << canon
      info
    end

    # A unique C identifier derived from `base`.
    def c_name(base)
      clean = base.gsub(/[^A-Za-z0-9_]+/, "_").sub(/_+\z/, "")
      name = clean
      n = 2
      while @c_names.key?(name)
        name = "#{clean}_#{n}"
        n += 1
      end
      @c_names[name] = true
      name
    end

    def register_decl(d)
      return @types[d.name] if @types.key?(d.name)
      info = register(d.name, d.kind, d.line, d.col)
      info.mod = d.mod || ""
      # A type is registered on first use, maybe from another module; its
      # own errors belong to its file.
      in_module(d.mod) { register_members(d, info) }
      info
    end

    def register_members(d, info)
      if d.kind == :enum
        names = d.members.map(&:name)
        dup = names.find { |n| names.count(n) > 1 }
        err("E106", "enum member '#{dup}' is listed twice", d.line, d.col) unless dup.nil?
        info.members = names
        info.member_lines = d.members.map(&:line)
      elsif d.kind == :union
        with_env({}, d.name, d.mod) { info.fields = resolve_fields(d.members, true) }
        d.methods.each do |m|
          m.owner = d.name
          add_method(d.name, m, {}, d.name)
        end
      else
        with_env({}, d.name, d.mod) { info.fields = resolve_fields(d.members) }
        d.methods.each do |m|
          m.owner = d.name
          add_method(d.name, m, {}, d.name)
        end
      end
    end

    # Methods of plain types are checked eagerly; methods of a generic
    # instance only when called (lazy, as in Zig), so Stack(T) can have a
    # method that needs `>` on T and still be used with a T that has none.
    def add_method(owner, m, tenv, this, eager = true)
      key = method_key(owner, m.name)
      if @sigs.key?(key) || @types[owner]&.fields&.any? { |f, _| f == m.name }
        err("E106", "'#{m.name}' is defined more than once in #{owner}", m.line, m.col)
        return
      end
      sig = new_sig(m.name, m, c_name("fn_#{owner}__#{m.name}"), tenv, this, owner)
      @sigs[key] = sig
      build_sig(sig)
      enqueue(sig) if eager
    end

    # Struct fields, or union members (a union member may have no payload:
    # its type is "void").
    def resolve_fields(members, union = false)
      fields = []
      members.each do |f|
        if fields.any? { |n, _| n == f.name }
          err("E106", "#{union ? 'member' : 'field'} '#{f.name}' is declared twice", f.line, f.col)
          next
        end
        if union && f.type.nil?
          fields << [f.name, "void", f.line]
          next
        end
        t = resolve_type(f.type, f.line, f.col)
        if t == "void" || t == "type"
          err("E108", "a field cannot have type #{t}", f.line, f.col)
          t = "error"
        elsif t.start_with?("[]")
          err("E116", "a struct cannot hold a slice; slices exist only as parameters", f.line, f.col)
          t = "error"
        end
        fields << [f.name, t, f.line]
      end
      fields
    end

    # Source type -> canonical type string (registering composite types).
    def resolve_type(t, line, col)
      case t
      when String
        return @tenv[t] if @tenv.key?(t)
        return t if PRIMS.include?(t) || t == "type"
        q = qualify(t)
        decl = @decls[q]
        return register_decl(decl).canon unless decl.nil?
        if @type_fns.key?(q)
          err("E108", "'#{t}' is a type function; write #{t}(...) with its arguments", line, col)
        else
          err("E108", "unknown type '#{t}'#{module_hint(t)}", line, col)
        end
        "error"
      when ArrayType
        if t.len.nil?
          err("E108", "an array type needs a length; [_]T is only for array literals", line, col)
          return "error"
        end
        if t.len < 1
          err("E124", "an array needs at least one element", line, col)
          return "error"
        end
        elem = resolve_type(t.elem, line, col)
        return "error" if elem == "error"
        return value_type_error(elem, "an array element", line, col) unless storable?(elem)
        canon = "[#{t.len}]#{elem}"
        info = register(canon, :array, line, col)
        info.elem = elem
        info.len = t.len
        canon
      when SliceType
        elem = resolve_type(t.elem, line, col)
        return "error" if elem == "error"
        return value_type_error(elem, "a slice element", line, col) unless storable?(elem)
        canon = "[]#{elem}"
        info = register(canon, :slice, line, col)
        info.elem = elem
        canon
      when ErrType
        inner = resolve_type(t.inner, line, col)
        return "error" if inner == "error"
        if inner.start_with?("!") || inner.start_with?("[]") || inner == "type"
          err("E108", "!#{inner} is not a valid error union", line, col)
          return "error"
        end
        canon = "!#{inner}"
        info = register(canon, :err, line, col)
        info.inner = inner
        canon
      when GenericType
        args = t.args.map { |a| resolve_type(a, line, col) }
        return "error" if args.include?("error")
        instantiate_type_fn(qualify(t.name), args, line, col, t.name)
      when PtrType
        inner = resolve_type(t.inner, line, col)
        return "error" if inner == "error"
        return value_type_error(inner, "a pointer's target", line, col) unless storable?(inner)
        ptr_type(inner)
      when FnType
        params = t.params.map { |p| resolve_type(p, line, col) }
        ret = resolve_type(t.ret, line, col)
        return "error" if params.include?("error") || ret == "error"
        bad = params.find { |p| p == "void" || p == "type" || p == "anyerror" }
        return value_type_error(bad, "a function parameter", line, col) unless bad.nil?
        if ret.start_with?("[]") || ret == "type"
          err("E108", "a function type cannot return #{ret}", line, col)
          return "error"
        end
        fn_type(params, ret)
      when ThisType
        return @this unless @this.nil?
        err("E108", "@This() is only valid inside a struct", line, col)
        "error"
      else
        raise "typecheck: unknown type node #{t.inspect}"
      end
    end

    # "fn(i64, bool) i64", registered: params in fields, result in inner.
    def fn_type(params, ret)
      canon = "fn(#{params.join(', ')}) #{ret}"
      info = register(canon, :fn, nil, nil)
      info.fields = params
      info.inner = ret
      canon
    end

    def storable?(t)
      !(t == "void" || t == "type" || t == "anyerror" || t.start_with?("[]"))
    end

    def value_type_error(t, what, line, col)
      if t.start_with?("[]")
        err("E116", "#{what} cannot be a slice; slices exist only as parameters", line, col)
      else
        err("E108", "#{what} cannot have type #{t}", line, col)
      end
      "error"
    end

    # Pair(i64): run the type function at compile time. Its body must be
    # `return struct { ... }`; T is substituted by deep-copying the struct.
    # name: global name; written: as in the source, for messages
    def instantiate_type_fn(name, args, line, col, written = name)
      f = @type_fns[name]
      if f.nil?
        err("E108", "'#{written}' is not a type function#{module_hint(written)}", line, col)
        return "error"
      end
      canon = "#{name}(#{args.join(', ')})"
      return canon if @types.key?(canon)
      if f.params.length != args.length || f.params.any? { |p| p.mode != "comptime" || p.type != "type" }
        err("E104", "'#{name}' takes #{f.params.length} type argument(s) but #{args.length} were given", line, col)
        return "error"
      end
      body = f.body.stmts
      unless body.length == 1 && body[0].is_a?(Return) && body[0].value.is_a?(StructTypeExpr)
        in_module(f.mod) { err("E120", "a type function's body must be `return struct { ... }`", f.line, f.col) }
        return "error"
      end
      st = Egg.deep_copy(body[0].value)
      tenv = {}
      f.params.each_with_index { |p, i| tenv[p.name] = args[i] }
      info = register(canon, :struct, st.line, st.col)
      info.mod = f.mod || ""
      info.fn_line = f.line
      info.return_line = body[0].line
      with_env(tenv, canon, f.mod) { info.fields = resolve_fields(st.members) }
      in_module(f.mod) do
        st.methods.each do |m|
          m.owner = canon
          add_method(canon, m, tenv, canon, false)
        end
      end
      canon
    end

    def check_recursive_structs
      state = {}
      @type_order.each { |c| visit_value_deps(c, state, []) }
    end

    # A struct that contains itself by value would be infinitely large.
    def visit_value_deps(canon, state, path)
      return if state[canon] == :done
      info = @types[canon]
      return if info.nil?
      if state[canon] == :visiting
        cycle = path.drop_while { |c| c != canon } + [canon]
        first = @types[cycle[0]]
        in_module(first.mod) { err("E119", "#{cycle.join(' -> ')}: a struct cannot contain itself by value", first.line || 1, first.col || 1) }
        return
      end
      state[canon] = :visiting
      value_deps(info).each { |d| visit_value_deps(d, state, path + [canon]) }
      state[canon] = :done
    end

    def value_deps(info)
      case info.kind
      when :struct then (info.fields || []).map { |_, t| t }
      when :union then (info.fields || []).map { |_, t| t }.reject { |t| t == "void" }
      when :array then [info.elem]
      when :err then [info.inner]
      else []
      end
    end

    # ---- function bodies ----------------------------------------------

    def check_body(sig)
      f = sig.func
      @concrete << sig
      with_env(sig.tenv, sig.this, f.mod) do
        @current = sig
        @scopes = [{}]
        @loop_depth = 0
        runtime = f.params.reject { |p| p.mode == "comptime" }
        runtime.each_with_index do |p, i|
          t, mode = sig.params[i]
          declare(p.name, VarInfo.new(t, mode == "inout", false, false, p.line, p.col, true, mode == "inout"))
        end
        f.params.each do |p|
          next unless p.mode == "comptime"
          declare(p.name, VarInfo.new("type", false, true, false, p.line, p.col, true, false))
        end
        check_block(f.body)
        sig.unused = @scopes[0].select { |_, info| info.param && !info.used && info.type != "type" }.keys
        ret = sig.ret
        if ret != "void" && ret != "!void" && ret != "error" && !block_returns?(f.body)
          err("E107", "function '#{f.name}' can reach its end without returning #{ret}", f.line, f.col)
        end
        @scopes = []
      end
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
        declared = type.nil? ? nil : resolve_type(type, line, col)
        vt = check_expr(value, declared)
        ty = declared.nil? ? vt : declared
        expect_type(declared, vt, value) unless declared.nil?
        if ty == "void"
          err("E103", "cannot store a void value in '#{name}'", line, col)
          ty = "error"
        elsif ty == "type"
          err("E125", "'#{name}' would hold a type; types exist only at compile time", line, col)
          ty = "error"
        elsif ty == "anyerror"
          err("E115", "cannot infer the type of '#{name}'; give it a type such as !i64", line, col)
          ty = "error"
        elsif ty.start_with?("[]")
          err("E116", "'#{name}' cannot hold a slice; slices exist only as parameters", line, col)
          ty = "error"
        end
        stmt.ty = ty
        declare(name, VarInfo.new(ty, mutable, false, false, line, col, false, false))
      in Assign[name:, value:, line:, col:, target:]
        if target.nil?
          info = lookup(name)
          if info.nil?
            vt = check_expr(value)
            err("E101", "undefined variable '#{name}'", line, col)
          else
            vt = check_expr(value, info.type)
            if !info.mutable
              what = info.param ? "parameter" : "constant"
              err("E105", "cannot assign to #{what} '#{name}'", line, col)
            else
              info.mutated = true
              expect_type(info.type, vt, value)
            end
          end
        else
          t = check_lvalue(target, "assign to")
          vt = check_expr(value, t)
          expect_type(t, vt, value)
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
        @loop_depth += 1
        check_block(body)
        @loop_depth -= 1
      in For[iter:, var:, index_var:, body:, line:, col:]
        # A slice may be iterated directly: it lives only as long as the loop.
        it = iter.is_a?(SliceExpr) ? check_slice_arg(iter, nil) : check_expr(iter)
        elem = elem_type(it)
        if elem.nil? && it != "error"
          err("E103", "'for' needs an array, a slice or a str, found #{it}", iter.line, iter.col)
        end
        @loop_depth += 1
        @scopes << {}
        declare(var, VarInfo.new(elem || "error", false, false, false, line, col, false, false)) unless var == "_"
        declare(index_var, VarInfo.new("i64", false, false, false, line, col, false, false)) unless index_var.nil? || index_var == "_"
        check_block(body)
        close_scope(@scopes.pop)
        @loop_depth -= 1
      in Switch[subject:, arms:, line:, col:]
        check_switch(stmt, subject, arms, line, col)
      in Break[line:, col:]
        err("E126", "'break' outside a loop", line, col) if @loop_depth.zero?
      in Continue[line:, col:]
        err("E126", "'continue' outside a loop", line, col) if @loop_depth.zero?
      in Return[value:, line:, col:]
        ret = @current.ret
        if value.nil?
          if ret != "void" && ret != "!void" && ret != "error"
            err("E103", "function '#{@current.func.name}' must return #{ret}", line, col)
          end
        else
          if ret == "void"
            check_expr(value)
            err("E103", "function '#{@current.func.name}' returns void and cannot return a value", line, col)
          else
            vt = check_expr(value, ret)
            expect_type(ret, vt, value)
          end
        end
      in ExprStmt[expr:, line:, col:]
        t = check_expr(expr)
        if t.start_with?("!")
          err("E113", "the error in this #{t} is ignored; handle it with 'try' or 'catch'", line, col)
        elsif t != "void" && t != "error"
          err("E113", "value of type #{t} is ignored", line, col)
        end
      else
        raise "typecheck: unhandled statement #{stmt.class}"
      end
    end

    # switch over an enum or a union: every member handled once, or an else.
    def check_switch(stmt, subject, arms, line, col)
      t = check_expr(subject)
      info = @types[t]
      if t != "error" && (info.nil? || (info.kind != :enum && info.kind != :union))
        err("E127", "switch needs an enum or a union(enum), found #{t}", subject.line, subject.col)
      end
      ok = t != "error" && !info.nil? && (info.kind == :enum || info.kind == :union)
      members = ok ? (info.kind == :enum ? info.members : info.fields.map(&:first)) : []
      seen = {}
      has_else = false
      arms.each do |arm|
        payload = nil
        if arm.names.nil?
          err("E127", "switch has more than one else", arm.line, arm.col) if has_else
          err("E127", "else must be the last arm of a switch", arm.line, arm.col) unless arm.equal?(arms.last)
          # else covers several members, so there is no single payload.
          err("E127", "an else arm has no payload to capture", arm.line, arm.col) unless arm.capture.nil?
          has_else = true
        elsif ok
          arm.names.each do |n|
            if !members.include?(n)
              err("E122", "#{t} has no member '#{n}'", arm.line, arm.col)
            elsif seen[n]
              err("E127", "'.#{n}' is handled twice", arm.line, arm.col)
            end
            seen[n] = true
          end
          if !arm.capture.nil?
            if info.kind == :enum
              err("E127", "an enum member has no payload to capture", arm.line, arm.col)
            elsif arm.names.length != 1
              err("E127", "a payload can be captured only in an arm for a single member", arm.line, arm.col)
            else
              payload = info.fields.find { |n, _| n == arm.names[0] }&.[](1)
              if payload == "void"
                err("E127", "'.#{arm.names[0]}' has no payload to capture", arm.line, arm.col)
                payload = nil
              end
            end
          end
        end
        @scopes << {}
        unless arm.capture.nil? || arm.capture == "_"
          # An else capture is already an error; do not also call it unused.
          declare(arm.capture, VarInfo.new(payload || "error", false, arm.names.nil?, false, arm.line, arm.col, false, false))
        end
        check_block(arm.body)
        close_scope(@scopes.pop)
      end
      return unless ok
      missing = members.reject { |m| seen[m] }
      if !missing.empty? && !has_else
        err("E127", "switch does not handle #{missing.map { |m| ".#{m}" }.join(', ')}; add arms or an else", line, col)
      elsif missing.empty? && has_else
        err("E127", "every member is already handled, so the else can never run", line, col)
      end
      stmt_info = { kind: info.kind, members: members }
      stmt.subject.info[:switch] = stmt_info
    end

    def elem_type(t)
      return "i64" if t == "str"
      info = @types[t]
      return nil if info.nil?
      return info.elem if info.kind == :array || info.kind == :slice
      nil
    end

    # Type of an assignable place (x, p.f, a[i]); requires a mutable root.
    def check_lvalue(e, verb)
      case e
      in Var[name:, line:, col:]
        info = lookup(name)
        e.info = { local: true, inout: info&.inout }
        if info.nil?
          err("E101", "undefined variable '#{name}'", line, col)
          e.ty = "error"
          return "error"
        end
        if !info.mutable
          what = info.param ? "parameter" : "constant"
          err("E105", "cannot #{verb} #{what} '#{name}'", line, col)
        else
          info.mutated = true
        end
        e.ty = info.type
      in Field[obj:, name:, line:, col:]
        t = check_lvalue(obj, verb)
        e.ty = field_type(t, name, line, col)
        e.info = {}
        e.ty
      in Index[obj:, index:, line:, col:]
        t = check_lvalue(obj, verb)
        expect_type("i64", check_expr(index), index)
        if t.start_with?("[]") || t == "str"
          err("E105", "cannot #{verb} an element of a #{t == 'str' ? 'str' : 'slice'}: it is read-only", line, col)
        end
        e.ty = index_type(t, line, col)
        e.info = { len: @types[t]&.len }
        e.ty
      in Deref[expr: ptr, line:, col:]
        # Writing through a pointer: the pointer itself need not be a var.
        e.info = {}
        t = check_expr(ptr)
        return(e.ty = "error") if t == "error" || !require_unsafe("'.*'", line, col)
        inner = pointee(t)
        if inner.nil?
          err("E103", "'.*' needs a pointer, found #{t}", line, col)
          return(e.ty = "error")
        end
        e.ty = inner
      else
        err("E105", "can only #{verb} a variable, a field or an element", e.line, e.col)
        check_expr(e)
        "error"
      end
    end

    # &place in an `allow unsafe` file: a pointer to a mutable place (a
    # var, its fields and elements, or a place behind a pointer).
    def address_of(place)
      t = check_lvalue(place, "take the address of")
      mark_root_used(place)
      return "error" if t == "error"
      unless storable?(t)
        err("E108", "cannot take the address of a #{t}", place.line, place.col)
        return "error"
      end
      ptr_type(t)
    end

    # ---- expressions --------------------------------------------------

    # expected: the type the context wants, used to type `.member`,
    # `error.X`, @splat and array literals; nil if the context has none.
    def check_expr(e, expected = nil)
      e.info ||= {}
      e.ty = infer(e, expected)
    end

    def infer(e, expected)
      case e
      in IntLit[value:, line:, col:]
        int_lit(value, int_target(expected), line, col)
      in BoolLit then "bool"
      in StrLit then "str"
      in Var[name:, line:, col:]
        info = lookup(name)
        unless info.nil?
          info.used = true
          if info.type == "type"
            e.info[:type] = @tenv[name]
            return "type"
          end
          e.info[:local] = true
          e.info[:inout] = info.inout
          return info.type
        end
        t = type_named(name)
        unless t.nil?
          e.info[:type] = t
          return "type"
        end
        q = qualify(name)
        if @sigs.key?(q)
          return fn_value(e, @sigs[q], name, line, col)
        elsif @generic_fns.key?(q)
          err("E103", "'#{name}' is a generic function; call it with (...)", line, col)
          "error"
        elsif @mod.aliases.key?(name)
          err("E129", "'#{name}' is a module; name something in it, such as #{name}.f(...)", line, col)
        else
          err("E101", "undefined variable '#{name}'", line, col)
        end
        "error"
      in TypeExpr[type:, line:, col:]
        e.info[:type] = resolve_type(type, line, col)
        "type"
      in Unary[op:, operand:, line:, col:]
        if op == "-" && operand.is_a?(IntLit)
          # -128 as one literal, so it fits i8.
          t = int_target(expected) || "i64"
          if !signed?(t)
            err("E103", "cannot negate a #{t}: it is unsigned", line, col)
            return "error"
          end
          operand.info = {}
          operand.ty = int_lit(-operand.value, t, operand.line, operand.col)
          e.info[:neg_lit] = true
          return operand.ty
        end
        t = check_expr(operand, op == "-" ? int_target(expected) : nil)
        if op == "-"
          if t != "error" && !signed?(t)
            err("E103", int?(t) ? "cannot negate a #{t}: it is unsigned" : "expected a signed integer, found #{t}", line, col)
            return "error"
          end
          t
        else
          expect_type("bool", t, operand)
          "bool"
        end
      in Binary[op:, lhs:, rhs:, line:, col:]
        check_binary(op, lhs, rhs, line, col, expected)
      in Call[name:, args:, line:, col:]
        check_call(e, name, args, line, col)
      in MethodCall[obj:, name:, args:, line:, col:]
        check_method_call(e, obj, name, args, line, col)
      in Builtin[name:, args:, line:, col:]
        check_builtin(e, name, args, expected, line, col)
      in Field[obj:, name:, line:, col:]
        unless module_ref(obj).nil?
          # m.Point / m.Color: a type of another module
          obj.info = {}
          obj.ty = "module"
          t = type_named("#{obj.name}.#{name}")
          if t.nil?
            q = qualify("#{obj.name}.#{name}")
            if @sigs.key?(q)
              return fn_value(e, @sigs[q], "#{obj.name}.#{name}", line, col)
            elsif @generic_fns.key?(q)
              err("E103", "'#{obj.name}.#{name}' is a generic function; call it with (...)", line, col)
            elsif @type_fns.key?(q)
              err("E108", "'#{obj.name}.#{name}' is a type function; write #{obj.name}.#{name}(...) with its arguments", line, col)
            else
              err("E122", "module '#{obj.name}' declares no '#{name}'", line, col)
            end
            return "error"
          end
          e.info[:type] = t
          return "type"
        end
        t = check_expr(obj)
        if t == "type"
          enum_t = obj.info[:type]
          info = @types[enum_t]
          return union_tag_value(e, info, enum_t, name, line, col) if info&.kind == :union
          if info&.kind == :enum
            idx = info.members.index(name)
            if idx.nil?
              err("E122", "#{enum_t} has no member '#{name}'", line, col)
              return "error"
            end
            e.info[:enum_index] = idx
            return enum_t
          end
          err("E122", "#{enum_t || 'this type'} has no member '#{name}'", line, col) unless enum_t.nil?
          return "error"
        end
        field_type(t, name, line, col)
      in Index[obj:, index:, line:, col:]
        t = check_expr(obj)
        expect_type("i64", check_expr(index), index)
        e.info[:len] = @types[t]&.len
        index_type(t, line, col)
      in SliceExpr[obj:, lo:, hi:, line:, col:]
        check_slice(e, obj, lo, hi, line, col)
      in StructLit[type:, fields:, line:, col:]
        check_struct_lit(e, type, fields, line, col)
      in ArrayLit[type:, items:, line:, col:]
        check_array_lit(type, items, expected, line, col)
      in EnumLit[name:, line:, col:]
        target = expected
        target = @types[expected].inner if !expected.nil? && @types[expected]&.kind == :err
        info = target.nil? ? nil : @types[target]
        if !info.nil? && info.kind == :union
          return union_tag_value(e, info, target, name, line, col)
        end
        if info.nil? || info.kind != :enum
          err("E115", "cannot infer the enum type of '.#{name}'; write Type.#{name}", line, col) unless expected == "error"
          return "error"
        end
        idx = info.members.index(name)
        if idx.nil?
          err("E122", "#{target} has no member '#{name}'", line, col)
          return "error"
        end
        e.info[:enum_index] = idx
        target
      in ErrorLit[name:]
        e.info[:error_id] = error_id(name)
        "anyerror"
      in Try[expr:, line:, col:]
        inner_expected = expected.nil? || expected == "error" ? nil : "!#{expected}"
        inner_expected = nil unless !inner_expected.nil? && @types.key?(inner_expected)
        t = check_expr(expr, inner_expected)
        return "error" if t == "error"
        unless t.start_with?("!")
          err("E118", "'try' needs an error union (!T), found #{t}", line, col)
          return "error"
        end
        unless @current.ret.start_with?("!")
          err("E118", "'try' can only be used in a function that returns !T; '#{@current.func.name}' returns #{@current.ret}", line, col)
        end
        @types[t].inner
      in Catch[expr:, fallback:, line:, col:]
        t = check_expr(expr)
        return "error" if t == "error"
        unless t.start_with?("!")
          err("E118", "'catch' needs an error union (!T), found #{t}", line, col)
          check_expr(fallback)
          return "error"
        end
        inner = @types[t].inner
        if inner == "void"
          # `f() catch g()`: on error, run g(), which must be void.
          ft = check_expr(fallback)
          if ft != "void" && ft != "error"
            err("E118", "the fallback of a !void catch is an action and must be void, found #{ft}", fallback.line, fallback.col)
          end
          return "void"
        end
        ft = check_expr(fallback, inner)
        expect_type(inner, ft, fallback)
        inner
      in AddrOf[expr: place, line:, col:]
        unless unsafe?
          err("E121", "'&' marks an inout argument; it is only allowed directly in a call (taking an address needs `allow unsafe`)", line, col)
          return "error"
        end
        address_of(place)
      in Deref[expr: ptr, line:, col:]
        t = check_expr(ptr)
        return "error" if t == "error" || !require_unsafe("'.*'", line, col)
        inner = pointee(t)
        if inner.nil?
          err("E103", "'.*' needs a pointer, found #{t}", line, col)
          return "error"
        end
        inner
      in NullLit[line:, col:]
        t = expected
        t = @types[t].inner if !t.nil? && @types[t]&.kind == :err
        if t.nil? || pointee(t).nil?
          err("E115", "cannot infer the pointer type of null; give it a type such as *i64", line, col) unless expected == "error"
          return "error"
        end
        t
      in StructTypeExpr[line:, col:]
        err("E120", "'struct { ... }' is only allowed as the body of a type function", line, col)
        "error"
      else
        raise "typecheck: unhandled expression #{e.class}"
      end
    end

    # `.none` / `Shape.none`: a union member without a payload.
    def union_tag_value(e, info, t, name, line, col)
      idx = info.fields.index { |n, _| n == name }
      if idx.nil?
        err("E122", "#{t} has no member '#{name}'", line, col)
        return "error"
      end
      if info.fields[idx][1] != "void"
        err("E123", "'#{name}' carries a #{info.fields[idx][1]}; write #{t}{ .#{name} = value }", line, col)
        return "error"
      end
      e.info[:union_tag] = idx
      t
    end

    # A type named by an identifier in a value position, or nil.
    def type_named(name)
      return @tenv[name] if @tenv.key?(name)
      return name if PRIMS.include?(name)
      d = @decls[qualify(name)]
      return register_decl(d).canon unless d.nil?
      nil
    end

    # "; there is no import named 'u'" for "u.Point" without the import.
    def module_hint(name)
      dot = name.index(".")
      return "" if dot.nil?
      m = name[0...dot]
      @mod.aliases.key?(m) ? "; module '#{m}' declares no '#{name[(dot + 1)..]}'" : "; there is no import named '#{m}'"
    end

    def field_type(t, name, line, col)
      return "error" if t == "error"
      info = @types[t]
      if info&.kind == :union
        err("E122", "#{t} is a union; read its members with switch", line, col)
        return "error"
      end
      if info.nil? || info.kind != :struct
        err("E122", "a #{t} has no field '#{name}'", line, col)
        return "error"
      end
      f = info.fields.find { |n, _| n == name }
      if f.nil?
        hint = @sigs.key?(method_key(t, name)) ? "; '#{name}' is a method, call it with (...)" : ""
        err("E122", "#{t} has no field '#{name}'#{hint}", line, col)
        return "error"
      end
      f[1]
    end

    def index_type(t, line, col)
      return "error" if t == "error"
      elem = elem_type(t)
      return elem unless elem.nil?
      err("E103", "cannot index a #{t}", line, col)
      "error"
    end

    # Both operands of an arithmetic or ordering operator have one integer
    # type; a literal takes the other side's type (or, for arithmetic, the
    # type the context expects), so `x + 1` works for any integer x.
    def check_binary(op, lhs, rhs, line, col, expected = nil)
      arith = ARITH_OPS.include?(op)
      typed_by_other = (op == "==" || op == "!=" || arith || ORDER_OPS.include?(op))
      hint = arith ? int_target(expected) : nil
      if typed_by_other && untyped_lit?(lhs) && !untyped_lit?(rhs)
        rt = check_expr(rhs, hint)
        lt = check_expr(lhs, rt)
      else
        lt = check_expr(lhs, hint)
        rt = check_expr(rhs, typed_by_other ? lt : nil)
      end
      if arith || ORDER_OPS.include?(op)
        if lt != "error" && !int?(lt)
          err("E103", "'#{op}' needs integers, found #{lt}", lhs.line, lhs.col)
        elsif rt != "error" && !int?(rt)
          err("E103", "'#{op}' needs integers, found #{rt}", rhs.line, rhs.col)
        elsif lt != "error" && rt != "error" && lt != rt
          err("E103", "'#{op}' needs both sides of one type, found #{lt} and #{rt}; convert one with @as", line, col)
        end
        return arith ? (int?(lt) ? lt : "error") : "bool"
      elsif op == "==" || op == "!="
        if lt != "error" && rt != "error"
          if lt != rt
            err("E103", "cannot compare #{lt} with #{rt}", line, col)
          elsif !comparable?(lt)
            err("E103", "cannot compare values of type #{lt} with #{op}; compare their fields", line, col)
          end
        end
        "bool"
      else # and / or
        expect_type("bool", lt, lhs)
        expect_type("bool", rt, rhs)
        "bool"
      end
    end

    def comparable?(t)
      %w[bool str].include?(t) || int?(t) || [:enum, :ptr, :fn].include?(@types[t]&.kind)
    end

    def int?(t)
      INT_TYPES.include?(t)
    end

    def signed?(t)
      int?(t) && t.start_with?("i")
    end

    # The integer type a literal should take where `expected` is wanted
    # (T, or the T of !T), or nil.
    def int_target(expected)
      return nil if expected.nil?
      return expected if int?(expected)
      info = @types[expected]
      info&.kind == :err && int?(info.inner) ? info.inner : nil
    end

    # A literal whose type comes from context: 5, -5, .red, null.
    def untyped_lit?(e)
      e.is_a?(IntLit) || e.is_a?(EnumLit) || e.is_a?(NullLit) ||
        (e.is_a?(Unary) && e.op == "-" && e.operand.is_a?(IntLit))
    end

    def int_lit(value, t, line, col)
      t ||= "i64"
      lo, hi = INT_RANGE[t]
      if value < lo || value > hi
        err("E003", "integer literal #{value} does not fit in #{t} (#{lo} to #{hi})", line, col)
        return "error"
      end
      t
    end

    def printable?(t)
      %w[bool str].include?(t) || int?(t) || @types[t]&.kind == :enum
    end

    # ---- calls --------------------------------------------------------

    # name: as written ("f", or "m.f" for a call into module m)
    def check_call(e, written, args, line, col)
      local = lookup(written)
      return check_indirect_call(e, local, args, written, line, col) unless local.nil?
      name = qualify(written)
      if @type_fns.key?(name)
        types = args.map { |a| type_arg(a) }
        return "error" if types.include?("error")
        e.info[:type] = instantiate_type_fn(name, types, line, col)
        return "type"
      end
      gf = @generic_fns[name]
      unless gf.nil?
        sig = instantiate_generic_fn(gf, args, line, col)
        return "error" if sig.nil?
        runtime_args = []
        gf.params.each_with_index { |p, i| runtime_args << args[i] unless p.mode == "comptime" }
        e.info[:c_name] = sig.c_name
        e.info[:args] = runtime_args
        e.info[:params] = sig.params
        record_call(sig, line, col)
        check_args(sig, runtime_args, written, line, col)
        return sig.ret
      end
      sig = @sigs[name]
      if sig.nil?
        args.each { |a| check_expr(a) }
        if written.include?(".") && @mod.aliases.key?(written[0...written.index(".")])
          err("E102", "undefined function '#{written}'#{module_hint(written)}", line, col)
        else
          err("E102", "undefined function '#{written}'", line, col)
        end
        return "error"
      end
      e.info[:c_name] = sig.c_name
      e.info[:args] = args
      e.info[:params] = sig.params
      record_call(sig, line, col)
      check_args(sig, args, written, line, col)
      sig.ret
    end

    # A function used as a value: its type is fn(...) R. Whoever takes the
    # value can call it, so for the capability check this is a call edge
    # (a module may hand out a function that uses its capabilities, as it
    # may hand out a capability value).
    def fn_value(e, sig, name, line, col)
      if sig.params.any? { |_, mode| !mode.nil? }
        err("E103", "'#{name}' has inout parameters, so it cannot be used as a value", line, col)
        return "error"
      end
      return "error" if sig.params.any? { |t, _| t == "error" } || sig.ret == "error"
      enqueue(sig)
      record_call(sig, line, col)
      e.info[:fn_ref] = sig.c_name
      fn_type(sig.params.map(&:first), sig.ret)
    end

    # f(args) where f is a local of function type.
    def check_indirect_call(e, info, args, written, line, col)
      ft = @types[info.type]
      info.used = true
      unless ft&.kind == :fn
        args.each { |a| check_expr(a) }
        err("E102", "'#{written}' is a variable, not a function", line, col) unless info.type == "error"
        return "error"
      end
      e.info[:indirect] = true
      e.info[:args] = args
      e.info[:params] = ft.fields.map { |t| [t, nil] }
      check_args(Sig.new(written, e.info[:params], ft.inner), args, written, line, col)
      ft.inner
    end

    # A call edge for the capability check.
    def record_call(sig, line, col)
      @current.calls << [sig, line, col] unless @current.nil?
    end

    # A comptime argument: must name a type.
    def type_arg(a)
      t = check_expr(a)
      return "error" if t == "error"
      if t != "type"
        err("E125", "this argument must be a type, found a value of type #{t}", a.line, a.col)
        return "error"
      end
      a.info[:type]
    end

    def instantiate_generic_fn(f, args, line, col)
      if f.params.length != args.length
        err("E104", "'#{f.name}' takes #{f.params.length} argument(s) but #{args.length} were given", line, col)
        args.each { |a| check_expr(a) }
        return nil
      end
      tenv = {}
      f.params.each_with_index do |p, i|
        next unless p.mode == "comptime"
        if p.type != "type"
          err("E125", "comptime parameter '#{p.name}' must have type 'type'", p.line, p.col)
          return nil
        end
        t = type_arg(args[i])
        return nil if t == "error"
        tenv[p.name] = t
      end
      key = "#{f.name}(#{tenv.values.join(', ')})"
      sig = @sigs[key]
      return sig unless sig.nil?
      copy = Egg.deep_copy(f)
      sig = new_sig(f.name, copy, c_name("fn_#{key}"), tenv, nil, nil)
      @sigs[key] = sig
      build_sig(sig)
      enqueue(sig)
      sig
    end

    def check_method_call(e, obj, name, args, line, col)
      unless module_ref(obj).nil?
        # m.f(...): a function of another module
        obj.info = {}
        obj.ty = "module"
        e.info[:static] = true
        return check_call(e, "#{obj.name}.#{name}", args, line, col)
      end
      t = check_expr(obj)
      return check_all_error(args) if t == "error"
      return check_cap_method(e, obj, t, name, args, line, col) if CAP_METHODS.key?(t)
      if t == "type"
        owner = obj.info[:type]
        sig = @sigs[method_key(owner, name)]
        if sig.nil?
          err("E122", "#{owner} has no function '#{name}'", line, col)
          return check_all_error(args)
        end
        enqueue(sig)
        record_call(sig, line, col)
        e.info[:c_name] = sig.c_name
        e.info[:static] = true
        e.info[:args] = args
        e.info[:params] = sig.params
        check_args(sig, args, "#{owner}.#{name}", line, col)
        return sig.ret
      end
      sig = @sigs[method_key(t, name)]
      field = @types[t]&.kind == :struct ? (@types[t].fields || []).find { |n, _| n == name } : nil
      if sig.nil? && !field.nil? && @types[field[1]]&.kind == :fn
        # s.f(args) where f is a field of function type
        ft = @types[field[1]]
        e.info[:field_call] = true
        e.info[:args] = args
        e.info[:params] = ft.fields.map { |pt| [pt, nil] }
        check_args(Sig.new(name, e.info[:params], ft.inner), args, name, line, col, [obj])
        return ft.inner
      end
      if sig.nil?
        hint = (@types[t]&.fields || []).any? { |n, _| n == name } ? "; '#{name}' is a field" : ""
        err("E122", "#{t} has no method '#{name}'#{hint}", line, col)
        return check_all_error(args)
      end
      self_t, self_mode = sig.params[0]
      if self_t != t
        err("E122", "'#{name}' is not a method of #{t}: its first parameter is not #{t}; call it as #{t}.#{name}(...)", line, col)
        return check_all_error(args)
      end
      if self_mode == "inout"
        check_lvalue(obj, "modify")
        mark_root_used(obj)
      end
      enqueue(sig)
      record_call(sig, line, col)
      e.info[:c_name] = sig.c_name
      e.info[:self_inout] = self_mode == "inout"
      e.info[:args] = args
      e.info[:params] = sig.params.drop(1)
      rest = Sig.new(sig.name, sig.params.drop(1), sig.ret)
      check_args(rest, args, name, line, col, [obj])
      sig.ret
    end

    # out.print(x), a.concat(s, t): a direct use of a capability.
    def check_cap_method(e, obj, t, name, args, line, col)
      m = CAP_METHODS[t][name]
      if m.nil?
        err("E122", "#{t} has no method '#{name}' (methods: #{CAP_METHODS[t].keys.join(', ')})", line, col)
        return check_all_error(args)
      end
      cap = CAP_TYPES[t]
      @current.direct[cap] ||= [line, col, "#{t}.#{name}"]
      params, ret = m
      if params.length != args.length
        err("E104", "'#{name}' takes #{params.length} argument(s) but #{args.length} were given", line, col)
        return check_all_error(args)
      end
      params.each_with_index do |pt, i|
        a = args[i]
        if pt == "printable"
          at = check_expr(a)
          if at == "void"
            err("E103", "'#{name}' cannot print a void value", a.line, a.col)
          elsif at != "error" && !printable?(at)
            err("E103", "'#{name}' prints integers, bool, str and enums, not #{at}", a.line, a.col)
          end
        elsif pt == "integer"
          at = check_expr(a)
          err("E103", "'#{name}' needs an integer, found #{at}", a.line, a.col) unless at == "error" || int?(at)
        elsif pt == "value"
          # a.create(v): a copy of v in the arena; returns *T
          at = check_expr(a)
          return "error" if at == "error"
          return value_type_error(at, "an allocated value", a.line, a.col) unless storable?(at)
          ret = ptr_type(at)
        else
          expect_type(pt, check_expr(a, pt), a)
        end
      end
      e.info[:cap_method] = "#{t}.#{name}"
      ret
    end

    def check_all_error(args)
      args.each { |a| check_expr(a) }
      "error"
    end

    # Check call arguments against a signature, including inout (&x) and
    # slice parameters, and the exclusivity rule (E117).
    def check_args(sig, args, name, line, col, receivers = [])
      if sig.params.length != args.length
        err("E104", "'#{name}' takes #{sig.params.length} argument(s) but #{args.length} were given", line, col)
        args.each { |a| a.is_a?(AddrOf) ? check_expr(a.expr) : (a.is_a?(SliceExpr) ? check_slice_arg(a, nil) : check_expr(a)) }
        return
      end
      inout_roots = []
      sig.params.each_with_index do |(pt, mode), i|
        a = args[i]
        if mode == "inout"
          unless a.is_a?(AddrOf)
            err("E121", "parameter #{i + 1} of '#{name}' is inout: pass a variable as &x", a.line, a.col)
            check_expr(a)
            next
          end
          a.info = {}
          t = check_lvalue(a.expr, "pass as inout")
          mark_root_used(a.expr)
          a.ty = t
          expect_type(pt, t, a)
          root = root_name(a.expr)
          inout_roots << [root, a] unless root.nil?
        elsif a.is_a?(SliceExpr)
          at = check_slice_arg(a, pt)
          expect_type(pt, at, a)
        elsif a.is_a?(AddrOf) && !pointee(pt).nil?
          at = check_expr(a, pt)
          expect_type(pt, at, a)
        elsif a.is_a?(AddrOf)
          err("E121", "parameter #{i + 1} of '#{name}' is not inout; remove the '&'", a.line, a.col)
          check_expr(a.expr)
        else
          at = check_expr(a, pt)
          if pt.start_with?("[]") && (@types[at]&.kind == :array)
            err("E103", "expected #{pt}, found #{at}; pass a slice of it: x[0..]", a.line, a.col)
          else
            expect_type(pt, at, a)
          end
        end
      end
      # Exclusivity: a variable passed as inout may not appear anywhere else
      # in the same call, so the callee never sees two views of it.
      others = receivers + args
      inout_roots.each do |root, a|
        clash = others.find { |o| !o.equal?(a) && mentions?(o, root) }
        next if clash.nil?
        err("E117", "'#{root}' is passed as inout and also used by another argument of the same call", a.line, a.col)
      end
    end

    def check_slice_arg(a, _expected)
      a.info = {}
      @slice_ok = true
      begin
        a.ty = infer(a, nil)
      ensure
        @slice_ok = false
      end
    end

    def check_slice(e, obj, lo, hi, line, col)
      t = check_expr(obj)
      expect_type("i64", check_expr(lo), lo)
      expect_type("i64", check_expr(hi), hi) unless hi.nil?
      return "error" if t == "error"
      e.info[:len] = @types[t]&.len
      return "str" if t == "str"
      info = @types[t]
      if info.nil? || (info.kind != :array && info.kind != :slice)
        err("E103", "cannot slice a #{t}", line, col)
        return "error"
      end
      unless @slice_ok
        err("E116", "a slice can only be passed directly as an argument; slices exist only as parameters", line, col)
        return "error"
      end
      canon = "[]#{info.elem}"
      register(canon, :slice, line, col).elem = info.elem
      canon
    end

    def root_name(e)
      case e
      in Var[name:] then name
      in Field[obj:] then root_name(obj)
      in Index[obj:] then root_name(obj)
      else nil
      end
    end

    def mark_root_used(e)
      root = root_name(e)
      info = root.nil? ? nil : lookup(root)
      info.used = true unless info.nil?
    end

    # Does expression e read variable `name` anywhere?
    def mentions?(e, name)
      case e
      in Var[name: n] then n == name
      in IntLit | BoolLit | StrLit | EnumLit | ErrorLit | TypeExpr then false
      in Unary[operand:] then mentions?(operand, name)
      in Binary[lhs:, rhs:] then mentions?(lhs, name) || mentions?(rhs, name)
      in Call[args:] then args.any? { |a| mentions?(a, name) }
      in Builtin[args:] then args.any? { |a| mentions?(a, name) }
      in MethodCall[obj:, args:] then mentions?(obj, name) || args.any? { |a| mentions?(a, name) }
      in Field[obj:] then mentions?(obj, name)
      in Index[obj:, index:] then mentions?(obj, name) || mentions?(index, name)
      in SliceExpr[obj:, lo:, hi:] then mentions?(obj, name) || mentions?(lo, name) || (!hi.nil? && mentions?(hi, name))
      in StructLit[fields:] then fields.any? { |f| mentions?(f[1], name) }
      in ArrayLit[items:] then items.any? { |i| mentions?(i, name) }
      in AddrOf[expr:] then mentions?(expr, name)
      in Deref[expr:] then mentions?(expr, name)
      in Try[expr:] then mentions?(expr, name)
      in Catch[expr:, fallback:] then mentions?(expr, name) || mentions?(fallback, name)
      else false
      end
    end

    def check_struct_lit(e, type, fields, line, col)
      t = resolve_type(type, line, col)
      return check_all_error(fields.map { |f| f[1] }) if t == "error"
      info = @types[t]
      if info.kind == :union
        if fields.length != 1
          err("E123", "a #{t} value sets exactly one member, found #{fields.length}", line, col)
          return check_all_error(fields.map { |f| f[1] })
        end
        fname, value, fl, fc = fields[0]
        idx = info.fields.index { |n, _| n == fname }
        if idx.nil?
          err("E123", "#{t} has no member '#{fname}'", fl, fc)
          check_expr(value)
          return t
        end
        payload = info.fields[idx][1]
        if payload == "void"
          err("E123", "'#{fname}' has no payload; write .#{fname} or #{t}.#{fname}", fl, fc)
          check_expr(value)
          return t
        end
        vt = check_expr(value, payload)
        expect_type(payload, vt, value)
        e.info[:union_tag] = idx
        e.info[:member] = fname
        return t
      end
      if info.kind != :struct
        err("E123", "#{t} is not a struct", line, col)
        return check_all_error(fields.map { |f| f[1] })
      end
      seen = {}
      fields.each do |fname, value, fl, fc|
        decl = info.fields.find { |n, _| n == fname }
        if decl.nil?
          err("E123", "#{t} has no field '#{fname}'", fl, fc)
          check_expr(value)
          next
        end
        if seen[fname]
          err("E123", "field '#{fname}' is given twice", fl, fc)
        end
        seen[fname] = true
        vt = check_expr(value, decl[1])
        expect_type(decl[1], vt, value)
      end
      missing = info.fields.map(&:first).reject { |n| seen[n] }
      unless missing.empty?
        err("E123", "#{t} literal is missing #{missing.map { |m| "'#{m}'" }.join(', ')}", line, col)
      end
      t
    end

    def check_array_lit(type, items, _expected, line, col)
      elem = resolve_type(type.elem, line, col)
      return check_all_error(items) if elem == "error"
      return check_all_error(items) if value_type_error_if(elem, line, col)
      len = type.len.nil? ? items.length : type.len
      if len < 1
        err("E124", "an array needs at least one element", line, col)
        return "error"
      end
      if items.length != len
        err("E124", "[#{len}]#{elem} literal needs #{len} element(s), found #{items.length}", line, col)
      end
      items.each do |i|
        it = check_expr(i, elem)
        expect_type(elem, it, i)
      end
      canon = "[#{len}]#{elem}"
      info = register(canon, :array, line, col)
      info.elem = elem
      info.len = len
      canon
    end

    def value_type_error_if(t, line, col)
      return false if storable?(t)
      value_type_error(t, "an array element", line, col)
      true
    end

    # ---- builtins -----------------------------------------------------

    def check_builtin(e, name, args, expected, line, col)
      if name == "print"
        err("E112", "@print was removed: printing needs the io capability; write `uses io`, take `out: Io` in main and call out.print(x)", line, col)
        return check_all_error(args)
      end
      if name == "import"
        err("E129", "@import is only allowed as a top-level `const name = @import(\"file.egg\")`", line, col)
        return check_all_error(args)
      end
      unless BUILTINS.include?(name)
        err("E112", "unknown builtin '@#{name}' (builtins: #{BUILTINS.map { |b| "@#{b}" }.join(', ')}, and @This, @import)", line, col)
        return check_all_error(args)
      end
      arity = BUILTIN_ARITY[name]
      if args.length != arity
        err("E104", "'@#{name}' takes #{arity} argument(s) but #{args.length} were given", line, col)
        return check_all_error(args)
      end
      a = args[0]
      if UNSAFE_BUILTINS.include?(name) && !require_unsafe("@#{name}", line, col)
        return check_all_error(args)
      end
      case name
      when "ptrAdd"
        # @ptrAdd(p, n): p moved by n elements (n may be negative)
        t = check_expr(a)
        expect_type("i64", check_expr(args[1], "i64"), args[1])
        return "error" if t == "error"
        return t unless pointee(t).nil?
        err("E103", "@ptrAdd needs a pointer, found #{t}", a.line, a.col)
        "error"
      when "ptrCast"
        # @ptrCast(*U, p): the same address as a pointer to U
        t = type_arg(a)
        pt = check_expr(args[1])
        return "error" if t == "error" || pt == "error"
        if pointee(t).nil? || pointee(pt).nil?
          err("E103", "@ptrCast converts a pointer to another pointer type, found #{pointee(t).nil? ? t : pt}", line, col)
          return "error"
        end
        t
      when "strPtr"
        # @strPtr(s): a pointer to the bytes of s, for C (not 0-terminated)
        expect_type("str", check_expr(a, "str"), a)
        ptr_type("u8")
      when "intFromPtr"
        t = check_expr(a)
        err("E103", "@intFromPtr needs a pointer, found #{t}", a.line, a.col) unless t == "error" || !pointee(t).nil?
        "usize"
      when "ptrFromInt"
        t = type_arg(a)
        expect_type("usize", check_expr(args[1], "usize"), args[1])
        return "error" if t == "error"
        if pointee(t).nil?
          err("E103", "@ptrFromInt makes a pointer, not a #{t}", a.line, a.col)
          return "error"
        end
        t
      when "as"
        # @as(T, x): x converted to the integer type T; panics at run time
        # if the value does not fit (a literal is checked now).
        t = type_arg(a)
        x = args[1]
        if t != "error" && !int?(t)
          err("E103", "@as converts between integer types, not to #{t}", line, col)
          check_expr(x)
          return "error"
        end
        xt = check_expr(x, t == "error" ? nil : t)
        if xt != "error" && !int?(xt)
          err("E103", "@as converts an integer, found #{xt}", x.line, x.col)
          return "error"
        end
        t
      when "len"
        t = a.is_a?(SliceExpr) ? check_slice_arg(a, nil) : check_expr(a)
        if t != "error" && t != "str" && !%i[array slice].include?(@types[t]&.kind)
          err("E103", "'@len' needs an array, a slice or a str, found #{t}", line, col)
        end
        e.info[:len] = @types[t]&.len
        "i64"
      when "sizeOf"
        t = type_arg(a)
        e.info[:type] = t
        if t != "error" && !storable?(t) && !t.start_with?("!")
          err("E125", "@sizeOf needs a type with values, found #{t}", line, col)
        end
        "i64"
      when "typeName"
        e.info[:type] = type_arg(a)
        "str"
      when "splat"
        info = expected.nil? ? nil : @types[expected]
        if info.nil? || info.kind != :array
          err("E115", "cannot infer the array type for @splat; give the variable a type such as [8]i64", line, col) unless expected == "error"
          check_expr(a)
          return "error"
        end
        vt = check_expr(a, info.elem)
        expect_type(info.elem, vt, a)
        expected
      end
    end

    # ---- helpers ------------------------------------------------------

    # Does a value of type `got` fit where `want` is expected? T fits !T,
    # and an error.X literal fits any !T.
    def fits?(want, got)
      return true if got == "error" || want == "error" || want.nil? || want == got
      if want.start_with?("!")
        return true if got == "anyerror"
        return true if @types[want].inner == got
      end
      false
    end

    def expect_type(want, got, node)
      return if fits?(want, got)
      err("E103", "expected #{want}, found #{got}", node.line, node.col)
    end

    def error_id(name)
      i = @error_names.index(name)
      return i + 1 unless i.nil?
      @error_names << name
      @error_names.length
    end

    def block_returns?(block)
      block.stmts.any? { |s| stmt_returns?(s) }
    end

    def stmt_returns?(stmt)
      case stmt
      in Return then true
      in Switch[arms:] then arms.all? { |a| block_returns?(a.body) }
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
      q = qualify(name)
      if lookup(name) || @sigs.key?(q) || @generic_fns.key?(q) || @type_fns.key?(q) || @decls.key?(q) || @mod.aliases.key?(name)
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
      @diagnostics << Diagnostic.new(code, msg, line, col, @mod&.file)
    end
  end
end
