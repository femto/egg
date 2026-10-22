# AST node definitions.
#
# Plain Structs, consumed with `case ... in` pattern matching (no visitors,
# no `send`), so the compiler stays inside the Spinel-compilable subset and
# maps one-to-one onto Egg tagged unions when the compiler is self-hosted.
#
# Expression nodes end with two fields the type checker fills in for the
# code generator: `ty` (the expression's type, as a canonical type string,
# see types.rb) and `info` (a Hash of resolution facts, e.g. which C
# function a call targets). Generic code is deep-copied per instantiation,
# so each copy carries its own annotations.

module Egg
  # funcs: top-level functions (including generic and type-returning ones)
  # types: TypeDecl for `const Name = struct/enum { ... }`
  Program  = Struct.new(:funcs, :types)
  # owner: the struct a method belongs to (nil for free functions)
  Func     = Struct.new(:name, :params, :ret, :body, :line, :col, :owner)
  # mode: nil (by value), "inout", or "comptime"
  Param    = Struct.new(:name, :type, :line, :col, :mode)
  Block    = Struct.new(:stmts)

  # ---- types as written in the source ----------------------------------
  # A plain type is a String ("i64", "Point", "T"). Composite types:
  ArrayType   = Struct.new(:len, :elem)          # [N]T; len nil for [_]T in literals
  SliceType   = Struct.new(:elem)                # []T
  ErrType     = Struct.new(:inner)               # !T
  GenericType = Struct.new(:name, :args)         # Pair(i64): args are types
  ThisType    = Struct.new(:line, :col)          # @This() inside a struct body

  # const Name = struct { ... } / enum { ... }
  # members: FieldDecl list; methods: Func list (struct only)
  TypeDecl  = Struct.new(:name, :kind, :members, :methods, :line, :col)
  FieldDecl = Struct.new(:name, :type, :line, :col)
  # `struct { ... }` as an expression: the body of a type-returning function
  StructTypeExpr = Struct.new(:members, :methods, :line, :col, :ty, :info)

  # ---- statements --------------------------------------------------------
  VarDecl  = Struct.new(:name, :mutable, :type, :value, :line, :col, :ty) # :ty filled by the checker
  # name: the variable assigned, or the root variable of target
  # target: nil for `x = v`; a Field/Index expression for `p.x = v`, `a[i] = v`
  Assign   = Struct.new(:name, :value, :line, :col, :target)
  If       = Struct.new(:cond, :then_body, :else_body, :line, :col)       # else_body: Block, If or nil
  While    = Struct.new(:cond, :body, :line, :col)
  For      = Struct.new(:iter, :var, :index_var, :body, :line, :col)      # for (xs) |x| / |x, i|
  Break    = Struct.new(:line, :col)
  Continue = Struct.new(:line, :col)
  Return   = Struct.new(:value, :line, :col)                              # value may be nil
  ExprStmt = Struct.new(:expr, :line, :col)

  # ---- expressions -------------------------------------------------------
  IntLit     = Struct.new(:value, :line, :col, :ty, :info)
  BoolLit    = Struct.new(:value, :line, :col, :ty, :info)
  StrLit     = Struct.new(:value, :line, :col, :ty, :info)
  Var        = Struct.new(:name, :line, :col, :ty, :info)
  Unary      = Struct.new(:op, :operand, :line, :col, :ty, :info)
  Binary     = Struct.new(:op, :lhs, :rhs, :line, :col, :ty, :info)
  Call       = Struct.new(:name, :args, :line, :col, :ty, :info)
  Builtin    = Struct.new(:name, :args, :line, :col, :ty, :info)
  Field      = Struct.new(:obj, :name, :line, :col, :ty, :info)          # a.b
  Index      = Struct.new(:obj, :index, :line, :col, :ty, :info)         # a[i]
  SliceExpr  = Struct.new(:obj, :lo, :hi, :line, :col, :ty, :info)       # a[lo..hi], a[lo..]
  MethodCall = Struct.new(:obj, :name, :args, :line, :col, :ty, :info)   # a.m(...) / Type.f(...)
  StructLit  = Struct.new(:type, :fields, :line, :col, :ty, :info)       # P{ .x = 1 }; fields: [[name, expr, line, col]]
  ArrayLit   = Struct.new(:type, :items, :line, :col, :ty, :info)        # [3]i64{ 1, 2, 3 }
  EnumLit    = Struct.new(:name, :line, :col, :ty, :info)                # .red
  ErrorLit   = Struct.new(:name, :line, :col, :ty, :info)                # error.NotFound
  AddrOf     = Struct.new(:expr, :line, :col, :ty, :info)                # &x, for inout arguments
  Try        = Struct.new(:expr, :line, :col, :ty, :info)                # try e
  Catch      = Struct.new(:expr, :fallback, :line, :col, :ty, :info)     # e catch f
  TypeExpr   = Struct.new(:type, :line, :col, :ty, :info)                # a type in value position: []i64

  # A source type as text: "i64", "[3]i64", "[]str", "!i64", "Pair(i64)".
  def self.type_src(t)
    case t
    when String then t
    when ArrayType then "[#{t.len.nil? ? '_' : t.len}]#{type_src(t.elem)}"
    when SliceType then "[]#{type_src(t.elem)}"
    when ErrType then "!#{type_src(t.inner)}"
    when GenericType then "#{t.name}(#{t.args.map { |a| type_src(a) }.join(', ')})"
    when ThisType then "@This()"
    else t.to_s
    end
  end

  def self.deep_copy(node)
    Marshal.load(Marshal.dump(node))
  end
end
