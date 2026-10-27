# Type checker.
#
# Types are canonical strings: "i64", "bool", "str", "void", "Point",
# "Pair(i64)", "[3]i64", "[]i64", "!i64". `@types` maps each one to a TInfo
# with its structure. Two pseudo types: "type" (a type used as a value,
# compile time only) and "anyerror" (an error: an `error.X` literal, or e
# in `catch |e|`; it fits any `!T` and may be stored and passed). "error" marks an expression that already produced a diagnostic,
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
#
# Buf(T) is an owned heap buffer. A struct or array holding one is owned
# too. Owned values live in locals, parameters, results, struct fields,
# arrays and buffers, but not in unions or behind pointers (E133); who
# owns each one at each point is checked afterwards, along every path
# through each function (own.rb).
#
# An `owned struct` (a resource, such as a database handle) is owned even
# without buffers. Only its own file may build one (Db{ ... }) or end one
# (@drop(v)), so elsewhere it ends only through its API. Without a
# `deinit` a.free cannot end it, so it lives in locals, parameters, results
# and struct fields, not in arrays or buffers (E141); with one, a.free
# calls it, and those are allowed.
#
# ?T is a T or null, unwrapped with `orelse`; an owned ?T, like an owned
# !T, must be unwrapped right away.

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
  # resource: an `owned struct`; deinit: its deinit method's Sig, if any
  TInfo = Struct.new(:canon, :kind, :fields, :members, :elem, :len, :inner, :c_name, :line, :col, :member_lines, :fn_line, :return_line, :mod, :resource, :deinit)

  class TypeChecker
    # Io and Allocator are capability values: opaque, and only `main`
    # receives them (from the runtime); everything else is passed them.
    INT_TYPES = %w[i8 i16 i32 i64 u8 u16 u32 u64 usize].freeze
    # Literal ranges; usize is checked as u64 here, and a usize literal
    # above 32 bits against the target's real width (SIZE_MAX) at run time.
    INT_RANGE = {
      "i8" => [-128, 127], "i16" => [-32_768, 32_767],
      "i32" => [-2_147_483_648, 2_147_483_647],
      "i64" => [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807],
      "u8" => [0, 255], "u16" => [0, 65_535], "u32" => [0, 4_294_967_295],
      "u64" => [0, 18_446_744_073_709_551_615], "usize" => [0, 18_446_744_073_709_551_615]
    }.freeze
    FLOAT_TYPES = %w[f32 f64].freeze
    # The largest finite f32, and half its smallest subnormal (below it a
    # literal rounds to zero), for checking literals.
    F32_MAX = 3.4028234663852886e38
    F32_TINY = 7.006492321624085e-46
    PRIMS = (INT_TYPES + FLOAT_TYPES + %w[bool str void Io Allocator]).freeze
    CAP_TYPES = { "Io" => "io", "Allocator" => "alloc" }.freeze
    CAPABILITIES = %w[alloc io].freeze
    # Methods of capability values: name -> [parameter types, result]
    # ("printable" accepts numbers, bool, str and enums; "integer" any
    # integer type, "float" f32 or f64, "cstring" a *u8 to 0-terminated
    # bytes, read in an `allow unsafe` file).
    CAP_METHODS = {
      "Io" => { "print" => [["printable"], "void"] },
      "Allocator" => { "concat" => [%w[str str], "str"], "int_str" => [["integer"], "str"],
                       "float_str" => [["float"], "str"],
                       "cstr" => [["str"], "*u8"], "str_from_c" => [["cstring"], "str"],
                       "create" => [["value"], "pointer to the value"],
                       "alloc" => [%w[i64 element], "Buf(T)"], "free" => [["buffer"], "void"],
                       "resize" => [%w[inout_buffer i64 element], "void"],
                       "push" => [%w[inout_buffer element], "void"], "pop" => [["inout_buffer"], "?T"] }
    }.freeze
    # Type names the language defines; no declaration may take them.
    RESERVED_TYPES = (PRIMS + ["Buf"]).freeze
    ARITH_OPS = %w[+ - * / %].freeze
    ORDER_OPS = %w[< <= > >=].freeze
    # Builtins and how many arguments each takes.
    BUILTIN_ARITY = { "len" => 1, "sizeOf" => 1, "typeName" => 1, "splat" => 1, "as" => 2,
                      "replace" => 2, "take" => 1, "drop" => 1, "errorName" => 1,
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
      NULL EOF BUFSIZ FILENAME_MAX FOPEN_MAX L_tmpnam SEEK_CUR SEEK_END SEEK_SET TMP_MAX _IOFBF _IOLBF _IONBF
      EXIT_FAILURE EXIT_SUCCESS RAND_MAX MB_CUR_MAX SIZE_MAX PTRDIFF_MIN PTRDIFF_MAX SIG_ATOMIC_MIN SIG_ATOMIC_MAX
      WCHAR_MIN WCHAR_MAX WINT_MIN WINT_MAX FILE fpos_t size_t div_t ldiv_t lldiv_t imaxdiv_t wchar_t
      __bool_true_false_are_defined
    ].freeze
    # Families of names those headers also define: int8_t, INT8_MAX,
    # INT64_C, PRId64, ...; and C's reserved _X and __x names.
    C_RESERVED_PATTERNS = [
      /\Au?int(_least|_fast)?\d+_t\z/, /\Au?int(ptr|max)_t\z/,
      /\AU?INT(_LEAST|_FAST)?\d+_(MIN|MAX|C)\z/, /\AU?INT(PTR|MAX)_(MIN|MAX|C)\z/,
      /\A(PRI|SCN)[a-zA-Z0-9_]+\z/, /\A_[A-Z_]/
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
      @registering = 0     # depth of register_decl calls under way
      @elem_checks = []    # E141 checks waiting for those to finish
      @externs = []        # Sigs of extern fns, every declaration, in order
      @extern_c = {}       # C name -> Sig, to catch clashing declarations
      @modules = program.modules || { "" => ModuleInfo.new("", nil, nil, program.uses || [], {}, [], [], program.allows || [], program.links || []) }
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
          if @decls.key?(d.name) || RESERVED_TYPES.include?(base_name(d.name))
            builtin = RESERVED_TYPES.include?(base_name(d.name)) ? " (#{base_name(d.name)} is built in)" : ""
            err("E106", "type '#{d.name}' is defined more than once#{builtin}", d.line, d.col)
            next
          end
          @decls[d.name] = d
        end
      end
      @program.funcs.each do |f|
        in_module(f.mod) do
          # Buf(...) always means the built-in type, so no function may take the name.
          builtin = base_name(f.name) == "Buf"
          if @decls.key?(f.name) || @sigs.key?(f.name) || @type_fns.key?(f.name) || @generic_fns.key?(f.name) || builtin
            err("E106", "function '#{f.name}' is defined more than once#{builtin ? ' (Buf is built in)' : ''}", f.line, f.col)
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
      if C_RESERVED.include?(c) || C_RESERVED_PATTERNS.any? { |r| c.match?(r) } || C_PREFIXES.any? { |p| c.start_with?(p) }
        err("E132", "an extern fn cannot be named '#{c}': it is a C keyword, a name the C headers eggc includes declare, reserved in C, or uses a prefix of generated names", f.line, f.col)
        return
      end
      if f.params.any? { |p| !p.mode.nil? }
        err("E132", "an extern fn takes its parameters by value; no inout, sink or comptime", f.line, f.col)
        return
      end
      bad = sig.params.map(&:first).find { |t| t != "error" && !c_scalar?(t) }
      bad ||= sig.ret unless sig.ret == "void" || sig.ret == "error" || c_scalar?(sig.ret)
      unless bad.nil?
        err("E132", "an extern fn passes only integers, floats, bool, pointers and function values (and may return void), not #{bad}", f.line, f.col)
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
      # Every declaration is kept: each is checked against its own file's
      # capabilities, even when another file declares the same C function.
      @externs << sig
      @c_names[c] = true
    end

    # A type that crosses into C as itself.
    def c_scalar?(t)
      num?(t) || t == "bool" || %i[ptr fn].include?(@types[t]&.kind)
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
      m.links.each do |l|
        next unless require_unsafe("`link`", l.line, l.col)
        # Passed to the C compiler as -l<name>, so it must not read as a flag.
        unless l.name.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.+-]*\z/)
          err("E138", "'#{l.name}' is not a library name: write the part after -l, as in link \"m\" for -lm", l.line, l.col)
        end
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
          elsif owned_err?(t)
            err("E133", "a parameter cannot be a #{t}; unwrap it with #{unwrap_how(t)} and pass the #{@types[t].inner}", p.line, p.col)
            t = "error"
          elsif p.mode == "sink" && t != "error" && !owned?(t) && (sig.tenv.nil? || sig.tenv.empty?)
            # In a generic instance T may or may not own something.
            err("E145", "'sink' takes ownership, but #{t} owns nothing; remove 'sink' (a plain parameter reads it)", p.line, p.col)
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
      info.resource = d.owned == true
      # A type is registered on first use, maybe from another module; its
      # own errors belong to its file.
      @registering += 1
      begin
        in_module(d.mod) { register_members(d, info) }
      ensure
        @registering -= 1
      end
      flush_elem_checks if @registering.zero?
      info
    end

    # E141 checks met while types are being registered wait until every
    # one is done: Node { kids: Buf(Node) } resolves Buf(Node) before
    # Node's deinit is known.
    def flush_elem_checks
      until @elem_checks.empty?
        elem, what, line, col, mod = @elem_checks.shift
        saved = @mod
        @mod = mod
        begin
          resource_elem_error(elem, what, line, col)
        ensure
          @mod = saved
        end
      end
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
        d.fns.each do |m|
          m.owner = d.name
          add_method(d.name, m, {}, d.name)
        end
      else
        with_env({}, d.name, d.mod) { info.fields = resolve_fields(d.members) }
        d.fns.each do |m|
          m.owner = d.name
          add_method(d.name, m, {}, d.name)
        end
        set_deinit(d, info) if info.resource
      end
    end

    # An owned struct's `deinit`, which a.free calls: fn deinit(self: T)
    # void, or with a second parameter `a: Allocator`.
    def set_deinit(d, info)
      m = d.fns.find { |f| f.name == "deinit" }
      return if m.nil?
      sig = @sigs[method_key(d.name, "deinit")]
      return if sig.nil? || sig.params.nil?
      ok = sig.ret == "void" && sig.params[0] == [d.name, "sink"] &&
           (sig.params.length == 1 || (sig.params.length == 2 && sig.params[1] == ["Allocator", nil]))
      unless ok
        in_module(d.mod) do
          err("E143", "deinit of an owned struct must be fn deinit(sink self: #{d.name}) void, or take a second parameter a: Allocator: a.free calls it with nothing else", m.line, m.col)
        end
        return
      end
      info.deinit = sig
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
        elsif owned_err?(t)
          err("E133", "a #{union ? 'union' : 'struct'} cannot hold a #{t}; unwrap it with #{unwrap_how(t)} and store the #{@types[t].inner}", f.line, f.col)
          t = "error"
        elsif union && owned?(t)
          err("E133", "a union cannot hold a #{t}: only one member is live at a time, so its buffers could not be followed; use a struct", f.line, f.col)
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
        return t if PRIMS.include?(t) || t == "type" || t == "anyerror"
        if t == "Buf"
          err("E108", "Buf needs its element type: Buf(T), such as Buf(u8)", line, col)
          return "error"
        end
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
        return owned_place_error(elem, "an array element", line, col) if owned_err?(elem)
        return "error" if resource_elem_error(elem, "an array element", line, col)
        canon = "[#{t.len}]#{elem}"
        info = register(canon, :array, line, col)
        info.elem = elem
        info.len = t.len
        canon
      when SliceType
        elem = resolve_type(t.elem, line, col)
        return "error" if elem == "error"
        return value_type_error(elem, "a slice element", line, col) unless storable?(elem)
        return owned_place_error(elem, "a slice element", line, col) if owned_err?(elem)
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
      when OptType
        inner = resolve_type(t.inner, line, col)
        return "error" if inner == "error"
        unless storable?(inner) && !inner.start_with?("!") && !inner.start_with?("?")
          err("E108", "?#{inner} is not a valid optional", line, col)
          return "error"
        end
        unless pointee(inner).nil?
          err("E108", "?#{inner} is not needed: a pointer can already be null", line, col)
          return "error"
        end
        opt_type(inner)
      when GenericType
        args = t.args.map { |a| resolve_type(a, line, col) }
        return "error" if args.include?("error")
        return buf_type(args, line, col) if t.name == "Buf"
        instantiate_type_fn(qualify(t.name), args, line, col, t.name)
      when PtrType
        inner = resolve_type(t.inner, line, col)
        return "error" if inner == "error"
        return value_type_error(inner, "a pointer's target", line, col) unless storable?(inner)
        return owned_place_error(inner, "a pointer's target", line, col) if owned_or_err?(inner)
        ptr_type(inner)
      when FnType
        params = t.params.map { |p| resolve_type(p, line, col) }
        ret = resolve_type(t.ret, line, col)
        return "error" if params.include?("error") || ret == "error"
        bad = params.find { |p| p == "void" || p == "type" }
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

    # Is the function being checked an instance of a generic one (or a
    # method of a type function's struct), where T may be any type?
    def generic_instance?
      !@current.nil? && !@current.tenv.nil? && !@current.tenv.empty?
    end

    # ?T: a T or null.
    def opt_type(inner)
      canon = "?#{inner}"
      register(canon, :opt, nil, nil).inner = inner
      canon
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
      !(t == "void" || t == "type" || t.start_with?("[]"))
    end

    # Buf(T): an owned buffer of T. Its elements may be owned too.
    def buf_type(args, line, col)
      if args.length != 1
        err("E104", "Buf takes one type argument, its element type, but #{args.length} were given", line, col)
        return "error"
      end
      elem = args[0]
      return value_type_error(elem, "a Buf element", line, col) unless storable?(elem)
      return owned_place_error(elem, "a Buf element", line, col) if owned_err?(elem)
      return "error" if resource_elem_error(elem, "a Buf element", line, col)
      canon = "Buf(#{elem})"
      register(canon, :buf, line, col).elem = elem
      canon
    end

    # An owned value: a buffer, or a struct or array holding one. It is
    # moved, not copied (own.rb).
    def owned?(t)
      info = @types[t]
      return false if info.nil?
      case info.kind
      when :buf then true
      when :array then owned?(info.elem)
      when :struct then info.resource || (info.fields || []).any? { |_, ft, _| owned?(ft) }
      else false
      end
    end
    public :owned?

    # The `owned struct` without a deinit that t is or holds (in a field
    # or element, at any depth), or nil: what a.free cannot end. One with a
    # deinit ends its own fields.
    def resource_in(t, seen = {})
      return nil if seen[t]
      seen[t] = true
      info = @types[t]
      return nil if info.nil?
      case info.kind
      when :array, :buf then resource_in(info.elem, seen)
      when :struct
        return(info.deinit.nil? ? t : nil) if info.resource
        (info.fields || []).each do |_, ft, _|
          r = resource_in(ft, seen)
          return r unless r.nil?
        end
        nil
      else nil
      end
    end

    # Methods that take an owned struct t by value (self: T): the ways its
    # API ends one, for messages.
    def enders(t)
      @sigs.values.select { |g| g.owner == t && g.params&.first == [t, "sink"] }.map(&:name)
    end
    public :enders

    # The owned struct, with a deinit or not, that t is or holds, or nil.
    def any_resource(t, seen = {})
      return nil if seen[t]
      seen[t] = true
      info = @types[t]
      case info&.kind
      when :array, :buf then any_resource(info.elem, seen)
      when :struct
        return t if info.resource
        info.fields.each do |_, ft, _|
          r = any_resource(ft, seen)
          return r unless r.nil?
        end
        nil
      end
    end

    # The deinit methods a.free runs to free a value of type t.
    def deinits(t, out = [], seen = {})
      return out if seen[t]
      seen[t] = true
      info = @types[t]
      case info&.kind
      when :array, :buf then deinits(info.elem, out, seen)
      when :struct
        if info.resource
          out << info.deinit unless info.deinit.nil?
        else
          info.fields.each { |_, ft, _| deinits(ft, out, seen) }
        end
      end
      out
    end

    # Declared in the file being checked?
    def own_type?(t)
      (@types[t].mod || "") == (@mod.prefix || "")
    end

    def resource_elem_error(elem, what, line, col)
      if @registering.positive?
        @elem_checks << [elem, what, line, col, @mod]
        return false
      end
      r = resource_in(elem)
      return false if r.nil?
      held = r == elem ? "" : " (it holds a #{r})"
      err("E141", "#{what} cannot be a #{elem}#{held}: #{r} is an owned struct without a deinit, so a.free could not end it; give #{r} a deinit method, or keep it in a local or a struct field", line, col)
      true
    end

    # !T or ?T with an owned T: it must be unwrapped right away.
    def owned_err?(t)
      info = @types[t]
      %i[err opt].include?(info&.kind) && owned?(info.inner)
    end

    def unwrap_how(t)
      @types[t].kind == :opt ? "orelse" : "try or catch"
    end

    def owned_or_err?(t)
      owned?(t) || owned_err?(t)
    end

    def owned_place_error(t, what, line, col)
      err("E133", "#{what} cannot be a #{t}; owned values live in locals, parameters, results, struct fields, arrays and buffers", line, col)
      "error"
    end

    # Borrowing from an owned value (b[i], b[lo..], @len(b), for (b), v.f)
    # needs a place that owns it: a temporary would never be freed.
    def check_borrowed(obj, t)
      return unless owned?(t) && !owned_place?(obj)
      err("E133", "this #{t} is a temporary that would never be freed; store it in a variable first", obj.line, obj.col)
    end

    # A variable, or a field or element of one.
    def owned_place?(e)
      case e
      in Var then true
      in Field[obj:] then owned_place?(obj)
      in Index[obj:] then owned_place?(obj)
      else false
      end
    end

    # An owned value made without taking anything: Buf(T).empty, and
    # literals and @splat built only of those. a.alloc, a.resize and @splat
    # copy their fill value, which is safe only for these.
    def empty_value?(e)
      return true unless owned?(e.ty)
      return false unless any_resource(e.ty).nil?
      case e
      in Field[info: { buf_empty: true }] | EnumLit[info: { buf_empty: true }] then true
      in StructLit[fields:] then fields.all? { |f| empty_value?(f[1]) }
      in ArrayLit[items:] then items.all? { |i| empty_value?(i) }
      in Builtin[name: "splat", args:] then empty_value?(args[0])
      else false
      end
    end

    def check_empty_fill(a, what)
      return if a.ty.nil? || a.ty == "error" || empty_value?(a)
      r = any_resource(a.ty)
      unless r.nil?
        err("E140", "#{what} would copy this #{a.ty} into every element, but #{r} is an owned struct and cannot be copied; start from .empty and a.push each one", a.line, a.col)
        return
      end
      err("E140", "#{what} copies this #{a.ty} into every element, but it owns buffers; fill with #{empty_hint(a.ty)} and put values in with @replace", a.line, a.col)
    end

    def empty_hint(t)
      info = @types[t]
      case info.kind
      when :buf then "#{t}.empty"
      when :array then "@splat(#{empty_hint(info.elem)})"
      else "a #{t} literal of empty buffers"
      end
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
        st.fns.each do |m|
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
      when :err, :opt then [info.inner]
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
        elsif ty.start_with?("[]")
          err("E116", "'#{name}' cannot hold a slice; slices exist only as parameters", line, col)
          ty = "error"
        elsif owned_err?(ty)
          err("E133", "'#{name}' cannot hold a #{ty}; unwrap it right away with #{unwrap_how(ty)}", line, col)
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
        check_borrowed(iter, it)
        elem = elem_type(it)
        if elem.nil? && it != "error"
          err("E103", "'for' needs an array, a slice, a Buf or a str, found #{it}", iter.line, iter.col)
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
      in Defer[expr:, err:, line:, col:]
        what = err ? "errdefer" : "defer"
        if err && !@current.ret.start_with?("!") && @current.ret != "error"
          err("E118", "'errdefer' runs when the function returns an error, but '#{@current.func.name}' returns #{@current.ret}; use defer", line, col)
        end
        t = check_expr(expr)
        if contains_try?(expr)
          err("E118", "'try' and 'orelse/catch return/break/continue' cannot be used in #{what}: leaving from there would skip the rest", line, col)
        elsif t != "void" && t != "error"
          err("E113", "#{what} runs an action, which must be void; found #{t}", line, col)
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
      return check_error_switch(stmt, arms, line, col) if t == "anyerror"
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
            if n.start_with?("error.")
              err("E127", "#{n} is an error, but this switch is on a #{t}", arm.line, arm.col)
            elsif !members.include?(n)
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

    # switch over an error (e in catch |e|): arms name errors; since error
    # names are open, an else is required.
    def check_error_switch(stmt, arms, line, col)
      seen = {}
      has_else = false
      arms.each do |arm|
        if arm.names.nil?
          err("E127", "switch has more than one else", arm.line, arm.col) if has_else
          err("E127", "else must be the last arm of a switch", arm.line, arm.col) unless arm.equal?(arms.last)
          has_else = true
        else
          arm.names.each do |n|
            if !n.start_with?("error.")
              err("E127", "a switch on an error has arms such as error.#{n}, not .#{n}", arm.line, arm.col)
            elsif seen[n]
              err("E127", "'#{n}' is handled twice", arm.line, arm.col)
            else
              error_id(n.delete_prefix("error."))
            end
            seen[n] = true
          end
        end
        err("E127", "an error has no payload to capture", arm.line, arm.col) unless arm.capture.nil?
        @scopes << {}
        check_block(arm.body)
        close_scope(@scopes.pop)
      end
      err("E127", "a switch on an error needs an else: any error name may reach it", line, col) unless has_else
      stmt.subject.info ||= {}
      stmt.subject.info[:switch] = { kind: :error }
    end

    def elem_type(t)
      return "i64" if t == "str"
      info = @types[t]
      return nil if info.nil?
      return info.elem if %i[array slice buf].include?(info.kind)
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
        if @types[t]&.resource && !own_type?(t)
          err("E142", "#{t} is an owned struct, so only its own file can change its fields", line, col)
        end
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
      return owned_place_error(t, "a pointer's target", place.line, place.col) if owned?(t)
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
        t = num_target(expected)
        float?(t) ? t : int_lit(value, t, line, col)
      in FloatLit[text:, line:, col:]
        t = num_target(expected)
        float_lit(text, float?(t) ? t : "f64", line, col)
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
          t = num_target(expected) || "i64"
          if float?(t)
            operand.info = {}
            operand.ty = t
            e.info[:neg_lit] = true
            return t
          end
          if !signed?(t)
            err("E103", "cannot negate a #{t}: it is unsigned", line, col)
            return "error"
          end
          operand.info = {}
          operand.ty = int_lit(-operand.value, t, operand.line, operand.col)
          e.info[:neg_lit] = true
          return operand.ty
        end
        t = check_expr(operand, op == "-" ? num_target(expected) : nil)
        if op == "-"
          if t != "error" && !signed?(t) && !float?(t)
            err("E103", int?(t) ? "cannot negate a #{t}: it is unsigned" : "expected a signed integer or a float, found #{t}", line, col)
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
        check_method_call(e, obj, name, args, line, col, expected)
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
          if info&.kind == :buf
            if name == "empty"
              e.info[:buf_empty] = true
              return enum_t
            end
            err("E122", "#{enum_t} has no member '#{name}' (Buf(T).empty is an empty buffer)", line, col)
            return "error"
          end
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
        check_borrowed(obj, t)
        field_type(t, name, line, col)
      in Index[obj:, index:, line:, col:]
        t = check_expr(obj)
        check_borrowed(obj, t)
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
        if !info.nil? && info.kind == :buf && name == "empty"
          e.info[:buf_empty] = true
          return target
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
      in Catch[expr:, fallback:, line:, col:, capture:]
        t = check_expr(expr)
        ok = t != "error" && t.start_with?("!")
        err("E118", "'catch' needs an error union (!T), found #{t}", line, col) unless ok || t == "error"
        inner = ok ? @types[t].inner : nil
        # The error, named by |e|, is in scope only in the fallback.
        @scopes << {}
        unless capture.nil? || capture[0] == "_"
          declare(capture[0], VarInfo.new("anyerror", false, false, false, capture[1], capture[2], false, false))
        end
        if inner == "void" && !fallback_jump?(fallback) && !fallback.is_a?(Block)
          # `f() catch g()`: on error, run g(), which must be void.
          ft = check_expr(fallback)
          if ft != "void" && ft != "error"
            err("E118", "the fallback of a !void catch is an action and must be void, found #{ft}", fallback.line, fallback.col)
          end
        else
          check_orelse_fallback(fallback, inner, "catch", line, col)
        end
        close_scope(@scopes.pop)
        ok ? inner : "error"
      in Orelse[expr:, fallback:, line:, col:]
        t = check_expr(expr)
        unless @types[t]&.kind == :opt
          err("E118", "'orelse' needs an optional (?T), found #{t}", line, col) unless t == "error"
          check_orelse_fallback(fallback, nil, "orelse", line, col)
          return "error"
        end
        inner = @types[t].inner
        check_orelse_fallback(fallback, inner, "orelse", line, col)
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
        return t if @types[t]&.kind == :opt
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
      hint = arith ? num_target(expected) : nil
      # The typed side goes first and types the literal; of two literals,
      # a float one does (2 * 1.5 is f64).
      if typed_by_other && untyped_lit?(lhs) && (!untyped_lit?(rhs) || (float_lit?(rhs) && !float_lit?(lhs)))
        rt = check_expr(rhs, hint)
        lt = check_expr(lhs, rt)
      else
        lt = check_expr(lhs, hint)
        rt = check_expr(rhs, typed_by_other ? lt : nil)
      end
      if op == "%"
        # No float remainder: C's fmod (libm) is one extern fn away.
        if lt != "error" && !int?(lt)
          err("E103", "'%' needs integers, found #{lt}#{float?(lt) ? ' (for floats, declare fmod from libm)' : ''}", lhs.line, lhs.col)
        elsif rt != "error" && !int?(rt)
          err("E103", "'%' needs integers, found #{rt}#{float?(rt) ? ' (for floats, declare fmod from libm)' : ''}", rhs.line, rhs.col)
        elsif lt != "error" && rt != "error" && lt != rt
          err("E103", "'%' needs both sides of one type, found #{lt} and #{rt}; convert one with @as", line, col)
        end
        return int?(lt) ? lt : "error"
      elsif arith || ORDER_OPS.include?(op)
        if lt != "error" && !num?(lt)
          err("E103", "'#{op}' needs numbers, found #{lt}", lhs.line, lhs.col)
        elsif rt != "error" && !num?(rt)
          err("E103", "'#{op}' needs numbers, found #{rt}", rhs.line, rhs.col)
        elsif lt != "error" && rt != "error" && lt != rt
          err("E103", "'#{op}' needs both sides of one type, found #{lt} and #{rt}; convert one with @as", line, col)
        end
        return arith ? (num?(lt) ? lt : "error") : "bool"
      elsif op == "==" || op == "!="
        if lt != "error" && rt != "error"
          if lt != rt
            err("E103", "cannot compare #{lt} with #{rt}", line, col)
          elsif owned?(lt)
            err("E103", "cannot compare #{lt} with #{op}: it owns buffers; compare their elements", line, col)
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
      %w[bool str anyerror].include?(t) || num?(t) || [:enum, :ptr, :fn].include?(@types[t]&.kind)
    end

    def int?(t)
      INT_TYPES.include?(t)
    end

    def float?(t)
      FLOAT_TYPES.include?(t)
    end

    def num?(t)
      int?(t) || float?(t)
    end

    def signed?(t)
      int?(t) && t.start_with?("i")
    end

    # The number type a literal should take where `expected` is wanted
    # (T, or the T of !T or ?T), or nil.
    def num_target(expected)
      return nil if expected.nil?
      return expected if num?(expected)
      info = @types[expected]
      %i[err opt].include?(info&.kind) && num?(info.inner) ? info.inner : nil
    end

    # A literal whose type comes from context: 5, -5, 1.5, .red, null.
    def untyped_lit?(e)
      e.is_a?(IntLit) || e.is_a?(FloatLit) || e.is_a?(EnumLit) || e.is_a?(NullLit) ||
        (e.is_a?(Unary) && e.op == "-" && (e.operand.is_a?(IntLit) || e.operand.is_a?(FloatLit)))
    end

    def float_lit?(e)
      e.is_a?(FloatLit) || (e.is_a?(Unary) && e.op == "-" && e.operand.is_a?(FloatLit))
    end

    # A float literal of type t: it must be finite there, and not round
    # to zero unless it is zero (it is rounded to the nearest value of t).
    def float_lit(text, t, line, col)
      v = text.to_f
      if v.infinite? || (t == "f32" && v.abs > F32_MAX)
        err("E003", "float literal #{text} does not fit in #{t}", line, col)
        return "error"
      end
      if text.split(/[eE]/)[0].match?(/[1-9]/) && (v.zero? || (t == "f32" && v.abs < F32_TINY))
        err("E003", "float literal #{text} is too small for #{t}: it rounds to zero", line, col)
        return "error"
      end
      t
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
      %w[bool str].include?(t) || num?(t) || @types[t]&.kind == :enum
    end

    # ---- calls --------------------------------------------------------

    # name: as written ("f", or "m.f" for a call into module m)
    def check_call(e, written, args, line, col)
      local = lookup(written)
      return check_indirect_call(e, local, args, written, line, col) unless local.nil?
      name = qualify(written)
      if written == "Buf"
        types = args.map { |a| type_arg(a) }
        return "error" if types.include?("error")
        e.info[:type] = buf_type(types, line, col)
        return e.info[:type] == "error" ? "error" : "type"
      end
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

    def check_method_call(e, obj, name, args, line, col, expected = nil)
      unless module_ref(obj).nil?
        # m.f(...): a function of another module
        obj.info = {}
        obj.ty = "module"
        e.info[:static] = true
        return check_call(e, "#{obj.name}.#{name}", args, line, col)
      end
      t = check_expr(obj)
      return check_all_error(args) if t == "error"
      return check_cap_method(e, obj, t, name, args, line, col, expected) if CAP_METHODS.key?(t)
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
      elsif self_mode.nil?
        check_borrowed(obj, t)
      end
      enqueue(sig)
      record_call(sig, line, col)
      e.info[:c_name] = sig.c_name
      e.info[:self_inout] = self_mode == "inout"
      e.info[:self_sink] = self_mode == "sink"
      e.info[:args] = args
      e.info[:params] = sig.params.drop(1)
      rest = Sig.new(sig.name, sig.params.drop(1), sig.ret)
      check_args(rest, args, name, line, col, [obj])
      if self_mode == "inout"
        # The arguments are computed before the call, so reading plain
        # values of self is fine; a slice of it or a buffer moved out of it
        # would not be.
        path = inout_path(obj)
        clash = path.nil? ? nil : args.find { |a| holds?(a, path) }
        unless clash.nil?
          err("E117", "'#{path}' is passed to '#{name}' as inout self, and this argument borrows from it or moves part of it; copy what you need into a local first", clash.line, clash.col)
        end
      elsif self_mode == "sink" && owned?(t)
        # self is moved into the call, as for a sink argument.
        path = place_path(obj)
        clash = path.nil? ? nil : args.find { |a| mentions_path?(a, path) }
        unless clash.nil?
          err("E117", "'#{path}' is moved into '#{name}' as sink self and also used by this argument; copy what you need into a local first", clash.line, clash.col)
        end
      end
      sig.ret
    end

    # out.print(x), a.concat(s, t): a direct use of a capability.
    def check_cap_method(e, obj, t, name, args, line, col, expected = nil)
      m = CAP_METHODS[t][name]
      if m.nil?
        err("E122", "#{t} has no method '#{name}' (methods: #{CAP_METHODS[t].keys.join(', ')})", line, col)
        return check_all_error(args)
      end
      cap = CAP_TYPES[t]
      @current.direct[cap] ||= [line, col, "#{t}.#{name}"]
      params, ret = m
      ret = ptr_type("u8") if ret == "*u8"
      pop = ret == "?T"
      if params.length != args.length
        err("E104", "'#{name}' takes #{params.length} argument(s) but #{args.length} were given", line, col)
        return check_all_error(args)
      end
      # The element type of a.alloc / a.resize: from the buffer, or from
      # the type the context expects (`var b: Buf(u8) = a.alloc(4, 0)`).
      want = expected
      want = @types[want].inner if !want.nil? && @types[want]&.kind == :err
      elem = owned?(want) ? @types[want].elem : nil
      params.each_with_index do |pt, i|
        a = args[i]
        if pt == "element"
          at = check_expr(a, elem)
          return "error" if at == "error"
          expect_type(elem, at, a) unless elem.nil?
          return value_type_error(at, "a Buf element", a.line, a.col) unless storable?(at)
          return owned_place_error(at, "a Buf element", a.line, a.col) if owned_err?(at)
          check_empty_fill(a, "a.#{name}") unless name == "push"
          ret = buf_type([at], a.line, a.col) if name == "alloc"
        elsif pt == "buffer"
          at = check_expr(a)
          if at != "error" && !owned?(at) && generic_instance? && storable?(at)
            # In a generic instance T may or may not own something: freeing
            # a T that owns nothing does nothing.
            nil
          elsif at != "error" && !owned?(at)
            err("E103", "'#{name}' frees a Buf, or a struct or array holding buffers; found #{at}", a.line, a.col)
          elsif at != "error" && !(r = resource_in(at)).nil?
            held = r == at ? "" : ", which holds a #{r}"
            err("E141", "a.free cannot end a #{at}#{held}: #{r} is an owned struct without a deinit; end it with its own API (such as a close method)", a.line, a.col)
          elsif at != "error"
            # a.free calls the deinit of each owned struct it frees.
            deinits(at).each { |g| @current.calls << [g, line, col] }
          end
        elsif pt == "inout_buffer"
          unless a.is_a?(AddrOf)
            err("E121", "'#{name}' changes the buffer in place: pass it as &b", a.line, a.col)
            check_expr(a)
            return "error"
          end
          a.info = {}
          at = check_lvalue(a.expr, "resize")
          mark_root_used(a.expr)
          a.ty = at
          return "error" if at == "error"
          unless @types[at]&.kind == :buf
            err("E103", "'#{name}' changes the length of a Buf, found #{at}", a.line, a.col)
            return "error"
          end
          elem = @types[at].elem
          ret = opt_type(elem) if pop
          path = inout_path(a.expr)
          clash = args.find { |o| !o.equal?(a) && !path.nil? && mentions_path?(o, path) }
          unless clash.nil?
            err("E117", "'#{path}' is passed as inout and also used by another argument of the same call", a.line, a.col)
          end
        elsif pt == "printable"
          at = check_expr(a)
          if at == "void"
            err("E103", "'#{name}' cannot print a void value", a.line, a.col)
          elsif at != "error" && !printable?(at)
            err("E103", "'#{name}' prints numbers, bool, str and enums, not #{at}", a.line, a.col)
          end
        elsif pt == "integer"
          at = check_expr(a)
          err("E103", "'#{name}' needs an integer, found #{at}", a.line, a.col) unless at == "error" || int?(at)
        elsif pt == "cstring"
          # Reading bytes up to a 0 through a pointer: as unsafe as p.*.
          unless require_unsafe("a.#{name}", line, col)
            check_expr(a)
            return "error"
          end
          want = ptr_type("u8")
          expect_type(want, check_expr(a, want), a)
        elsif pt == "float"
          # A literal here is an f64: a.float_str(10).
          at = check_expr(a, "f64")
          err("E103", "'#{name}' needs a float, found #{at}", a.line, a.col) unless at == "error" || float?(at)
        elsif pt == "value"
          # a.create(v): a copy of v in the arena; returns *T
          at = check_expr(a)
          return "error" if at == "error"
          return value_type_error(at, "an allocated value", a.line, a.col) unless storable?(at)
          return owned_place_error(at, "a pointer's target", a.line, a.col) if owned_or_err?(at)
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
          path = inout_path(a.expr)
          inout_roots << [path, a] unless path.nil?
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
          check_borrowed(a, at) if mode.nil? && !empty_value?(a)
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
      inout_roots.each do |path, a|
        clash = others.find { |o| !o.equal?(a) && mentions_path?(o, path) }
        next if clash.nil?
        err("E117", "'#{path}' is passed as inout and also used by another argument of the same call", a.line, a.col)
      end
      # Likewise a value moved into the call (sink): another argument must
      # not borrow from it (a slice of it would outlive a free in the
      # callee). Several borrows of one value are fine.
      args.each_with_index do |a, i|
        next unless sig.params[i][1] == "sink"
        path = place_path(a)
        next if path.nil? || !owned?(a.ty)
        clash = others.find { |o| !o.equal?(a) && mentions_path?(o, path) }
        next if clash.nil?
        err("E117", "'#{path}' is moved into this call and also used by another argument of the same call", a.line, a.col)
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
      check_borrowed(obj, t)
      expect_type("i64", check_expr(lo), lo)
      expect_type("i64", check_expr(hi), hi) unless hi.nil?
      return "error" if t == "error"
      e.info[:len] = @types[t]&.len
      return "str" if t == "str"
      info = @types[t]
      if info.nil? || !%i[array slice buf].include?(info.kind)
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

    # "v", "v.f.g" for a variable or a chain of fields of one; else nil.
    def place_path(e)
      case e
      in Var[name:] then name
      in Field[obj:, name:]
        p = place_path(obj)
        p.nil? ? nil : "#{p}.#{name}"
      else nil
      end
    end

    # The place an inout argument hands over: v.f for &v.f, and the whole
    # container for an element (&v.data[i] -> v.data).
    def inout_path(e)
      p = place_path(e)
      return p unless p.nil?
      case e
      in Field[obj:] then inout_path(obj)
      in Index[obj:] then inout_path(obj)
      else nil
      end
    end

    def overlap?(a, b)
      a == b || a.start_with?("#{b}.") || b.start_with?("#{a}.")
    end

    # Does e take a slice of `path` (or of something overlapping it) or
    # move an owned part of it? Plain values read from it are copies.
    def holds?(e, path)
      p = place_path(e)
      return owned?(e.ty) && overlap?(p, path) unless p.nil?
      case e
      in SliceExpr[obj:, lo:, hi:] then mentions_path?(obj, path) || holds?(lo, path) || (!hi.nil? && holds?(hi, path))
      in Index[obj:, index:] then (place_path(obj).nil? && holds?(obj, path)) || holds?(index, path)
      in Field[obj:] then holds?(obj, path)
      in Builtin[name: "len"] then false
      in Unary[operand:] then holds?(operand, path)
      in Binary[lhs:, rhs:] then holds?(lhs, path) || holds?(rhs, path)
      in Call[args:, info:] then sunk(args, info).any? { |x| holds?(x, path) }
      in Builtin[args:] then args.any? { |x| holds?(x, path) }
      in MethodCall[obj:, args:, info:]
        # A borrowed argument is given back when the call returns.
        own_obj = info.nil? || info[:params].nil? || info[:self_sink]
        (own_obj && holds?(obj, path)) || sunk(args, info).any? { |x| holds?(x, path) }
      in StructLit[fields:] then fields.any? { |f| holds?(f[1], path) }
      in ArrayLit[items:] then items.any? { |x| holds?(x, path) }
      in AddrOf[expr:] then mentions_path?(expr, path)
      in Try[expr:] then holds?(expr, path)
      in Catch[expr:, fallback:] then holds?(expr, path) || (!(fb = fallback_expr(fallback)).nil? && holds?(fb, path))
      in Orelse[expr:, fallback:] then holds?(expr, path) || (!(fb = fallback_expr(fallback)).nil? && holds?(fb, path))
      else false
      end
    end

    # The arguments of a call that it takes ownership of: those passed to
    # sink parameters, or all of them when the parameters are not known
    # (Allocator methods take what they are given).
    def sunk(args, info)
      params = info&.[](:params)
      return args if params.nil? || params.length != args.length
      args.each_index.select { |i| params[i][1] == "sink" }.map { |i| args[i] }
    end

    # Does e read `path`, a part of it, or something it is part of?
    def mentions_path?(e, path)
      root = path.split(".").first
      return false unless mentions?(e, root)
      paths = []
      collect_paths(e, paths)
      paths.any? { |p| overlap?(p, path) }
    end

    # The longest place paths in e (v.a.b counts once, not also v and v.a).
    def collect_paths(e, out)
      p = place_path(e)
      return out << p unless p.nil?
      case e
      in Unary[operand:] then collect_paths(operand, out)
      in Binary[lhs:, rhs:] then [lhs, rhs].each { |x| collect_paths(x, out) }
      in Call[args:] then args.each { |x| collect_paths(x, out) }
      in Builtin[args:] then args.each { |x| collect_paths(x, out) }
      in MethodCall[obj:, args:] then [obj, *args].each { |x| collect_paths(x, out) }
      in Field[obj:] then collect_paths(obj, out)
      in Index[obj:, index:] then [obj, index].each { |x| collect_paths(x, out) }
      in SliceExpr[obj:, lo:, hi:] then [obj, lo, hi].compact.each { |x| collect_paths(x, out) }
      in StructLit[fields:] then fields.each { |f| collect_paths(f[1], out) }
      in ArrayLit[items:] then items.each { |x| collect_paths(x, out) }
      in AddrOf[expr:] then collect_paths(expr, out)
      in Deref[expr:] then collect_paths(expr, out)
      in Try[expr:] then collect_paths(expr, out)
      in Catch[expr:, fallback:] then [expr, fallback_expr(fallback)].compact.each { |x| collect_paths(x, out) }
      in Orelse[expr:, fallback:] then [expr, fallback_expr(fallback)].compact.each { |x| collect_paths(x, out) }
      else nil
      end
      out
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
      in IntLit | FloatLit | BoolLit | StrLit | EnumLit | ErrorLit | TypeExpr then false
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
      in Catch[expr:, fallback:] then mentions?(expr, name) || (!(fb = fallback_expr(fallback)).nil? && mentions?(fb, name))
      in Orelse[expr:, fallback:] then mentions?(expr, name) || (!(fb = fallback_expr(fallback)).nil? && mentions?(fb, name))
      else false
      end
    end

    # Does expression e contain a `try`?
    def contains_try?(e)
      case e
      in Try then true
      in Var | IntLit | FloatLit | BoolLit | StrLit | EnumLit | ErrorLit | TypeExpr | NullLit then false
      in Unary[operand:] then contains_try?(operand)
      in Binary[lhs:, rhs:] then contains_try?(lhs) || contains_try?(rhs)
      in Call[args:] then args.any? { |a| contains_try?(a) }
      in Builtin[args:] then args.any? { |a| contains_try?(a) }
      in MethodCall[obj:, args:] then contains_try?(obj) || args.any? { |a| contains_try?(a) }
      in Field[obj:] then contains_try?(obj)
      in AddrOf[expr:] then contains_try?(expr)
      in Deref[expr:] then contains_try?(expr)
      in Index[obj:, index:] then contains_try?(obj) || contains_try?(index)
      in SliceExpr[obj:, lo:, hi:] then contains_try?(obj) || contains_try?(lo) || (!hi.nil? && contains_try?(hi))
      in StructLit[fields:] then fields.any? { |f| contains_try?(f[1]) }
      in ArrayLit[items:] then items.any? { |i| contains_try?(i) }
      in Catch[expr:, fallback: Return | Break | Continue] then true
      in Catch[expr:, fallback: Block => b] then contains_try?(expr) || block_jumps?(b)
      in Orelse[expr:, fallback: Block => b] then contains_try?(expr) || block_jumps?(b)
      in Catch[expr:, fallback:] then contains_try?(expr) || contains_try?(fallback)
      in Orelse[expr:, fallback: Return | Break | Continue] then true
      in Orelse[expr:, fallback:] then contains_try?(expr) || contains_try?(fallback)
      else false
      end
    end

    # The fallback of orelse: a value of the inner type, or a way out.
    def check_orelse_fallback(f, inner, what = "orelse", line = nil, col = nil)
      case f
      in Return | Break | Continue then check_stmt(f)
      in Block
        check_block(f)
        unless inner == "void" || block_leaves?(f)
          err("E118", "the block after #{what} gives no value, so it must leave with return, break or continue (to give a value, call a function: #{what == 'catch' ? 'catch |e| f(e)' : 'orelse f()'})", line, col)
        end
      else
        ft = check_expr(f, inner)
        expect_type(inner, ft, f) unless inner.nil?
      end
    end

    def fallback_jump?(f)
      f.is_a?(Return) || f.is_a?(Break) || f.is_a?(Continue)
    end

    # Does every path through the block leave it by return, break or
    # continue?
    def block_leaves?(block)
      block.stmts.any? { |s| stmt_leaves?(s) }
    end

    def stmt_leaves?(stmt)
      case stmt
      in Return | Break | Continue then true
      in Switch[arms:] then arms.all? { |a| block_leaves?(a.body) }
      in If[then_body:, else_body:]
        case else_body
        in nil then false
        in Block then block_leaves?(then_body) && block_leaves?(else_body)
        in If then block_leaves?(then_body) && stmt_leaves?(else_body)
        end
      else false
      end
    end

    # Can this block leave the code around it (return, break, continue or
    # try anywhere in it)? Not allowed in a defer.
    def block_jumps?(block)
      block.stmts.any? do |s|
        case s
        in Return | Break | Continue then true
        in If[cond:, then_body:, else_body:]
          contains_try?(cond) || block_jumps?(then_body) || (!else_body.nil? && block_jumps?(else_body.is_a?(Block) ? else_body : Block.new([else_body])))
        in While[cond:, body:] then contains_try?(cond) || block_has_return?(body)
        in For[iter:, body:] then contains_try?(iter) || block_has_return?(body)
        in Switch[subject:, arms:] then contains_try?(subject) || arms.any? { |a| block_jumps?(a.body) }
        in VarDecl[value:] then contains_try?(value)
        in Assign[value:] then contains_try?(value)
        in ExprStmt[expr:] then contains_try?(expr)
        else false
        end
      end
    end

    # Inside a loop's own body break and continue stay inside it.
    def block_has_return?(block)
      block.stmts.any? do |s|
        case s
        in Return then true
        in If[cond:, then_body:, else_body:]
          contains_try?(cond) || block_has_return?(then_body) || (!else_body.nil? && block_has_return?(else_body.is_a?(Block) ? else_body : Block.new([else_body])))
        in While[cond:, body:] then contains_try?(cond) || block_has_return?(body)
        in For[iter:, body:] then contains_try?(iter) || block_has_return?(body)
        in Switch[subject:, arms:] then contains_try?(subject) || arms.any? { |a| block_has_return?(a.body) }
        in VarDecl[value:] then contains_try?(value)
        in Assign[value:] then contains_try?(value)
        in ExprStmt[expr:] then contains_try?(expr)
        else false
        end
      end
    end

    # The expression in an orelse fallback (a return's value), or nil. A
    # block in a value context always leaves, so the call it is in never
    # runs after it.
    def fallback_expr(f)
      case f
      in Return[value:] then value
      in Break | Continue | Block then nil
      else f
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
      if info.resource && !own_type?(t)
        err("E142", "#{t} is an owned struct, so only its own file can build one; get one from its API", line, col)
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
      return check_all_error(items) if resource_elem_error(elem, "an array element", line, col)
      if owned_or_err?(elem)
        owned_place_error(elem, "an array element", line, col)
        return check_all_error(items)
      end
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
        # @as(T, x): the number x converted to the number type T; panics at
        # run time if the value does not fit an integer T (a literal is
        # checked now). Floats round to the nearest value.
        t = type_arg(a)
        x = args[1]
        if t != "error" && !num?(t)
          err("E103", "@as converts between number types, not to #{t}", line, col)
          check_expr(x)
          return "error"
        end
        xt = check_expr(x, t == "error" ? nil : t)
        if xt != "error" && !num?(xt)
          err("E103", "@as converts a number, found #{xt}", x.line, x.col)
          return "error"
        end
        t
      when "len"
        t = a.is_a?(SliceExpr) ? check_slice_arg(a, nil) : check_expr(a)
        check_borrowed(a, t)
        if t != "error" && t != "str" && !%i[array slice buf].include?(@types[t]&.kind)
          err("E103", "'@len' needs an array, a slice, a Buf or a str, found #{t}", line, col)
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
      when "errorName"
        t = check_expr(a)
        err("E103", "@errorName needs an anyerror (error.X, or e in catch |e|), found #{t}", a.line, a.col) unless t == "anyerror" || t == "error"
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
        check_empty_fill(a, "@splat") if vt == info.elem
        expected
      when "replace", "take"
        check_swap(name, args, line, col)
      when "drop"
        check_drop(a)
      end
    end

    # @drop(v): ends an owned struct without running anything, in the file
    # that declares it (its API's way to say the resource is released).
    def check_drop(a)
      t = check_expr(a)
      return "void" if t == "error"
      unless @types[t]&.resource
        err("E103", "@drop ends an owned struct, found #{t}#{owned?(t) ? '; free buffers with a.free' : ''}", a.line, a.col)
        return "void"
      end
      unless own_type?(t)
        err("E142", "#{t} is an owned struct, so only its own file can @drop one; end it with its API", a.line, a.col)
        return "void"
      end
      unless a.is_a?(Var) || a.is_a?(Field)
        err("E133", "@drop needs a variable or a field of one, not a temporary #{t}", a.line, a.col)
      end
      "void"
    end

    # @replace(&place, v): puts v in the place and gives back what was
    # there; @take(&place) puts Buf(T).empty there. The way to get an owned
    # value out of an array or buffer element.
    def check_swap(name, args, line, col)
      a = args[0]
      unless a.is_a?(AddrOf)
        err("E121", "'@#{name}' changes a place: pass it as &x", a.line, a.col)
        check_all_error(args)
        return "error"
      end
      a.info = {}
      t = check_lvalue(a.expr, name)
      mark_root_used(a.expr)
      a.ty = t
      if name == "take"
        return "error" if t == "error"
        unless @types[t]&.kind == :buf
          err("E103", "'@take' needs a Buf, found #{t}; use @replace(&x, v) and give the value to put back", a.line, a.col)
          return "error"
        end
        return t
      end
      v = args[1]
      vt = check_expr(v, t == "error" ? nil : t)
      expect_type(t, vt, v)
      root = root_name(a.expr)
      if !root.nil? && mentions?(v, root)
        err("E117", "'#{root}' is changed by this @replace and also used by its value; compute the value into a local first", v.line, v.col)
      end
      t
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
      return true if want.start_with?("?") && @types[want].inner == got
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
