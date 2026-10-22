# Language server for editors: `eggc lsp` speaks LSP over stdin/stdout.
#
# Supports go to definition, hover, document symbols (outline) and live
# diagnostics. Everything comes from the real lexer, parser and checker,
# so the editor sees exactly what the compiler sees.
#
# This file is a tool, not part of the compiler: it uses the json stdlib
# and is loaded only by `eggc lsp`, so the compiler stays in the Spinel
# subset.

require "json"

module Egg
  module LSP
    # A declared name: a function, method, type, parameter or local.
    Decl = Struct.new(:kind, :name, :line, :col, :detail, :end_line, :end_col)
    # A use (or the declaration itself) of a name at line:col.
    Ref = Struct.new(:line, :col, :length, :decl)

    # Everything the server knows about one version of one file.
    # Lines and columns are 1-based, as in the compiler.
    class Index
      attr_reader :diagnostics, :funcs

      def initialize(src)
        @refs = []
        @funcs = []
        @tokens = nil
        @tokens = Lexer.new(src).tokenize
        program = Parser.new(@tokens).parse_program
        @diagnostics = TypeChecker.new(program).check
        build(program)
        @parsed = true
      rescue CompileError => e
        @diagnostics = [e.diagnostic]
        @parsed = false
      end

      # False when lexing or parsing failed; there is then nothing to index.
      def parsed?
        @parsed
      end

      # The declaration of the name at line:col, or nil.
      def decl_at(line, col)
        ref = @refs.find { |r| r.line == line && col >= r.col && col < r.col + r.length }
        # The cursor may sit just past the end of a name.
        ref ||= @refs.find { |r| r.line == line && col == r.col + r.length }
        ref&.decl
      end

      # Length of the token starting at line:col, for diagnostic ranges.
      def token_length(line, col)
        return 1 if @tokens.nil?
        t = @tokens.find { |tok| tok.line == line && tok.col == col && tok.kind != :nl && tok.kind != :eof }
        return 1 if t.nil?
        t.kind == :builtin ? t.text.length + 1 : [t.text.length, 1].max
      end

      private

      def build(program)
        @by_pos = {}
        @tokens.each_with_index { |t, i| @by_pos["#{t.line}:#{t.col}"] = i }
        globals = {}
        @types = {}
        @methods = {}
        bodies = []
        # Types: `const Name = struct/enum {`; the decl sits on its name.
        (program.types || []).each do |td|
          i = @by_pos["#{td.line}:#{td.col}"]
          name_tok = @tokens[i - 2]
          close = closing_brace(i)
          decl = Decl.new(:type, td.name, name_tok.line, name_tok.col,
                          "const #{td.name} = #{td.kind}", close.line, close.col + 1)
          @funcs << [decl, name_tok.line, name_tok.col]
          @types[td.name] ||= decl
          ref(decl.line, decl.col, decl)
          td.methods.each do |m|
            mdecl = func_decl(m, "#{td.name}.#{m.name}")
            @funcs << [mdecl, m.line, m.col]
            @methods["#{td.name}.#{m.name}"] ||= mdecl
            bodies << [m, mdecl, false]
          end
        end
        program.funcs.each do |f|
          decl = func_decl(f, f.name)
          @funcs << [decl, f.line, f.col]
          first = !globals.key?(f.name) # E106; the first definition wins
          globals[f.name] = decl if first
          bodies << [f, decl, first]
        end
        @funcs.sort_by! { |_, l, c| [l, c] }
        @globals = globals
        bodies.each do |f, decl, first|
          ref(decl.line, decl.col, decl) if first || f.owner
          @scopes = [{}]
          f.params.each do |p|
            mode = p.mode.nil? ? "" : "#{p.mode} "
            declare(Decl.new(:param, p.name, p.line, p.col, "#{mode}#{p.name}: #{Egg.type_src(p.type)}  (parameter)", nil, nil))
          end
          walk_block(f.body)
          walk_type_fn(f.body)
        end
      end

      def func_decl(f, label)
        i = @by_pos["#{f.line}:#{f.col}"]
        name_tok = @tokens[i + 1]
        close = closing_brace(i)
        params = f.params.map { |p| "#{p.mode.nil? ? '' : "#{p.mode} "}#{p.name}: #{Egg.type_src(p.type)}" }.join(", ")
        Decl.new(:fn, label, name_tok.line, name_tok.col,
                 "fn #{f.name}(#{params}) #{Egg.type_src(f.ret)}", close.line, close.col + 1)
      end

      # Methods inside `return struct { ... }` of a type function.
      def walk_type_fn(body)
        st = body.stmts.length == 1 && body.stmts[0].is_a?(Return) ? body.stmts[0].value : nil
        return unless st.is_a?(StructTypeExpr)
        st.methods.each do |m|
          saved = @scopes
          @scopes = [{}]
          m.params.each do |p|
            declare(Decl.new(:param, p.name, p.line, p.col, "#{p.name}: #{Egg.type_src(p.type)}  (parameter)", nil, nil))
          end
          walk_block(m.body)
          @scopes = saved
        end
      end

      # The '}' that closes the body of the function whose 'fn' is token i.
      def closing_brace(i)
        i += 1 until @tokens[i].kind == :op && @tokens[i].text == "{"
        depth = 0
        loop do
          t = @tokens[i]
          if t.kind == :op && t.text == "{"
            depth += 1
          elsif t.kind == :op && t.text == "}"
            depth -= 1
            return t if depth.zero?
          end
          i += 1
        end
      end

      def walk_block(block)
        @scopes << {}
        block.stmts.each { |s| walk_stmt(s) }
        @scopes.pop
      end

      def walk_stmt(stmt)
        case stmt
        in VarDecl[name:, mutable:, value:, line:, col:, ty:]
          walk_expr(value) # the value cannot see the name being declared
          kw = mutable ? "var" : "const"
          declare(Decl.new(:local, name, line, col, "#{kw} #{name}: #{ty}", nil, nil))
        in Assign[name:, value:, line:, col:, target:]
          if target.nil?
            use(name, line, col)
          else
            walk_expr(target)
          end
          walk_expr(value)
        in For[iter:, var:, index_var:, body:, line:, col:]
          walk_expr(iter)
          @scopes << {}
          declare(Decl.new(:local, var, line, col, "#{var}  (loop item)", nil, nil)) unless var == "_"
          declare(Decl.new(:local, index_var, line, col, "#{index_var}: i64  (loop index)", nil, nil)) unless index_var.nil?
          walk_block(body)
          @scopes.pop
        in Break | Continue then nil
        in Switch[subject:, arms:]
          walk_expr(subject)
          arms.each do |arm|
            @scopes << {}
            unless arm.capture.nil?
              declare(Decl.new(:local, arm.capture, arm.line, arm.col, "#{arm.capture}  (payload)", nil, nil))
            end
            walk_block(arm.body)
            @scopes.pop
          end
        in If[cond:, then_body:, else_body:]
          walk_expr(cond)
          walk_block(then_body)
          case else_body
          in nil then nil
          in Block then walk_block(else_body)
          in If then walk_stmt(else_body)
          end
        in While[cond:, body:]
          walk_expr(cond)
          walk_block(body)
        in Return[value:]
          walk_expr(value) unless value.nil?
        in ExprStmt[expr:]
          walk_expr(expr)
        else
          raise "lsp: unhandled statement #{stmt.class}"
        end
      end

      def walk_expr(expr)
        case expr
        in IntLit | BoolLit | StrLit | EnumLit | ErrorLit | TypeExpr | StructTypeExpr then nil
        in Var[name:, line:, col:]
          decl = @types[name]
          if !decl.nil? && lookup_local(name).nil?
            ref(line, col, decl, name.length)
          else
            use(name, line, col)
          end
        in Field[obj:]
          walk_expr(obj)
        in Index[obj:, index:]
          walk_expr(obj)
          walk_expr(index)
        in SliceExpr[obj:, lo:, hi:]
          walk_expr(obj)
          walk_expr(lo)
          walk_expr(hi) unless hi.nil?
        in MethodCall[obj:, name:, args:, line:, col:]
          walk_expr(obj)
          owner = obj.info.nil? ? nil : (obj.info[:type] || obj.ty)
          decl = owner.nil? ? nil : @methods["#{owner}.#{name}"]
          ref(line, col, decl, name.length) unless decl.nil?
          args.each { |a| walk_expr(a) }
        in StructLit[type:, fields:, line:, col:]
          # The literal sits on its '{'; the type name is the token before.
          decl = type.is_a?(String) ? @types[type] : nil
          i = @by_pos["#{line}:#{col}"]
          name_tok = decl.nil? || i.nil? ? nil : @tokens[i - 1]
          ref(name_tok.line, name_tok.col, decl, type.length) if !name_tok.nil? && name_tok.text == type
          fields.each { |f| walk_expr(f[1]) }
        in ArrayLit[items:]
          items.each { |i| walk_expr(i) }
        in AddrOf[expr: inner]
          walk_expr(inner)
        in Try[expr: inner]
          walk_expr(inner)
        in Catch[expr: inner, fallback:]
          walk_expr(inner)
          walk_expr(fallback)
        in Unary[operand:]
          walk_expr(operand)
        in Binary[lhs:, rhs:]
          walk_expr(lhs)
          walk_expr(rhs)
        in Call[name:, args:, line:, col:]
          decl = @globals[name]
          ref(line, col, decl, name.length) unless decl.nil?
          args.each { |a| walk_expr(a) }
        in Builtin[args:]
          args.each { |a| walk_expr(a) }
        else
          raise "lsp: unhandled expression #{expr.class}"
        end
      end

      def declare(decl)
        @scopes.last[decl.name] = decl
        ref(decl.line, decl.col, decl)
      end

      def lookup_local(name)
        i = @scopes.length - 1
        while i >= 0
          d = @scopes[i][name]
          return d unless d.nil?
          i -= 1
        end
        nil
      end

      def use(name, line, col)
        decl = nil
        i = @scopes.length - 1
        while i >= 0 && decl.nil?
          decl = @scopes[i][name]
          i -= 1
        end
        ref(line, col, decl, name.length) unless decl.nil?
      end

      def ref(line, col, decl, length = decl.name.length)
        @refs << Ref.new(line, col, length, decl)
      end
    end

    # JSON-RPC over stdio, one file at a time (v0 programs are one file).
    class Server
      SYMBOL_FUNCTION = 12

      def initialize(input = $stdin, output = $stdout)
        @in = input
        @out = output
        @in.binmode
        @out.binmode
        @docs = {}   # uri -> latest Index
        @good = {}   # uri -> latest Index that parsed, for navigation
        @shutdown = false
      end

      def run
        while (msg = read_message)
          handle(msg)
        end
        @shutdown ? 0 : 1
      end

      private

      def read_message
        length = nil
        while (line = @in.gets)
          line = line.chomp
          break if line.empty?
          length = line.split(":", 2)[1].strip.to_i if line.downcase.start_with?("content-length:")
        end
        return nil if line.nil? || length.nil?
        JSON.parse(@in.read(length).force_encoding("UTF-8"))
      end

      def send_message(obj)
        body = JSON.generate(obj)
        @out.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        @out.flush
      end

      def handle(msg)
        id = msg["id"]
        params = msg["params"] || {}
        case msg["method"]
        when "initialize"
          reply(id, {
            "capabilities" => {
              "textDocumentSync" => 1, # full text on every change
              "definitionProvider" => true,
              "hoverProvider" => true,
              "documentSymbolProvider" => true
            },
            "serverInfo" => { "name" => "eggc", "version" => Egg::VERSION }
          })
        when "shutdown"
          @shutdown = true
          reply(id, nil)
        when "exit"
          exit(@shutdown ? 0 : 1)
        when "textDocument/didOpen"
          doc = params["textDocument"]
          update(doc["uri"], doc["text"])
        when "textDocument/didChange"
          changes = params["contentChanges"]
          update(params["textDocument"]["uri"], changes.last["text"]) unless changes.empty?
        when "textDocument/didClose"
          uri = params["textDocument"]["uri"]
          @docs.delete(uri)
          @good.delete(uri)
          notify("textDocument/publishDiagnostics", { "uri" => uri, "diagnostics" => [] })
        when "textDocument/definition"
          decl = decl_for(params)
          uri = params["textDocument"]["uri"]
          reply(id, decl.nil? ? nil : { "uri" => uri, "range" => name_range(decl) })
        when "textDocument/hover"
          decl = decl_for(params)
          reply(id, decl.nil? ? nil : {
            "contents" => { "kind" => "markdown", "value" => "```egg\n#{decl.detail}\n```" }
          })
        when "textDocument/documentSymbol"
          index = @good[params["textDocument"]["uri"]]
          reply(id, index.nil? ? [] : index.funcs.map { |decl, line, col| symbol(decl, line, col) })
        else
          # Unknown requests get an error; unknown notifications are ignored.
          send_message({ "jsonrpc" => "2.0", "id" => id,
                         "error" => { "code" => -32601, "message" => "method not found: #{msg['method']}" } }) unless id.nil?
        end
      end

      def update(uri, text)
        index = Index.new(text)
        @docs[uri] = index
        @good[uri] = index if index.parsed?
        diags = index.diagnostics.map do |d|
          {
            "range" => range(d.line, d.col, d.line, d.col + index.token_length(d.line, d.col)),
            "severity" => 1,
            "code" => d.code,
            "source" => "eggc",
            "message" => d.message
          }
        end
        notify("textDocument/publishDiagnostics", { "uri" => uri, "diagnostics" => diags })
      end

      # While a file has a syntax error, navigation uses its last version
      # that parsed.
      def decl_for(params)
        index = @good[params["textDocument"]["uri"]]
        return nil if index.nil?
        pos = params["position"]
        index.decl_at(pos["line"] + 1, pos["character"] + 1)
      end

      def symbol(decl, line, col)
        {
          "name" => decl.name,
          "detail" => decl.detail,
          "kind" => SYMBOL_FUNCTION,
          "range" => range(line, col, decl.end_line, decl.end_col),
          "selectionRange" => name_range(decl)
        }
      end

      def name_range(decl)
        range(decl.line, decl.col, decl.line, decl.col + decl.name.length)
      end

      # 1-based compiler positions -> 0-based LSP positions.
      def range(line, col, end_line, end_col)
        {
          "start" => { "line" => line - 1, "character" => col - 1 },
          "end" => { "line" => end_line - 1, "character" => end_col - 1 }
        }
      end

      def reply(id, result)
        send_message({ "jsonrpc" => "2.0", "id" => id, "result" => result })
      end

      def notify(method, params)
        send_message({ "jsonrpc" => "2.0", "method" => method, "params" => params })
      end
    end
  end
end
