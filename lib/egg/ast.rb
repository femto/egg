# AST node definitions.
#
# Plain Structs, consumed with `case ... in` pattern matching (no visitors,
# no `send`), so the compiler stays inside the Spinel-compilable subset and
# maps one-to-one onto Egg tagged unions when the compiler is self-hosted.

module Egg
  Program  = Struct.new(:funcs)
  Func     = Struct.new(:name, :params, :ret, :body, :line, :col)
  Param    = Struct.new(:name, :type, :line, :col)
  Block    = Struct.new(:stmts)

  # Statements
  VarDecl  = Struct.new(:name, :mutable, :type, :value, :line, :col, :ty) # :ty filled by the checker
  Assign   = Struct.new(:name, :value, :line, :col)
  If       = Struct.new(:cond, :then_body, :else_body, :line, :col)       # else_body: Block, If or nil
  While    = Struct.new(:cond, :body, :line, :col)
  Return   = Struct.new(:value, :line, :col)                              # value may be nil
  ExprStmt = Struct.new(:expr, :line, :col)

  # Expressions
  IntLit   = Struct.new(:value, :line, :col)
  BoolLit  = Struct.new(:value, :line, :col)
  Var      = Struct.new(:name, :line, :col)
  Unary    = Struct.new(:op, :operand, :line, :col)
  Binary   = Struct.new(:op, :lhs, :rhs, :line, :col)
  Call     = Struct.new(:name, :args, :line, :col)
  Builtin  = Struct.new(:name, :args, :line, :col)
end
