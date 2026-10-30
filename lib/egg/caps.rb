# Capability check (design rule 1 and 2).
#
# A function uses a capability directly when it calls a method of a
# capability value (`io.print(x)` uses io, `a.concat(s, t)` uses alloc)
# or is an `extern fn ... uses io`, and indirectly when it calls a
# function that uses it, or takes a function as a value. The type checker
# records both per function (Sig#direct, Sig#calls); this pass closes them
# over the call graph and rejects every function whose capabilities are
# not all declared by its module's `uses` line (E130).
#
# Capability values cannot be created, only passed down from `main`, so a
# module that does not declare io can at most hand an Io value on; it can
# never print with it, not even inside a generic function instantiated
# with Io.
#
# Only the function where a capability enters its module is reported: the
# one that uses it directly, or calls into another module that does.
# Callers in the same module would only repeat the same error.

module Egg
  class CapChecker
    def initialize(checker)
      @checker = checker
      @caps = {} # Sig#c_name -> capabilities, sorted
    end

    def check
      sigs = @checker.concrete + @checker.externs
      sigs.each { |s| @caps[s.c_name] = s.direct.keys.sort }
      changed = true
      while changed
        changed = false
        sigs.each do |s|
          mine = @caps[s.c_name]
          s.calls.each do |callee, _, _|
            (@caps[callee.c_name] || []).each do |c|
              next if mine.include?(c)
              mine << c
              changed = true
            end
          end
          mine.sort!
        end
      end
      diags = []
      sigs.each { |s| report(s, diags) }
      diags
    end

    # The capabilities a function uses, directly or through its calls.
    def caps_of(sig)
      @caps[sig.c_name] || []
    end

    # The capabilities of a plain function or method, by its name as
    # written ("f", "Point.len"); nil if it was not checked.
    def caps_named(name)
      sig = (@checker.concrete + @checker.externs).find { |s| s.tenv.empty? && (s.owner.nil? ? s.name : "#{s.owner}.#{s.name}") == name }
      sig.nil? ? nil : caps_of(sig)
    end

    private

    def report(sig, diags)
      mod = module_of(sig)
      declared = mod.uses.map(&:name)
      where = mod.file.nil? ? "the file" : mod.file
      caps_of(sig).each do |cap|
        next if declared.include?(cap)
        hint = "add `uses #{cap}` at the top of #{where}"
        direct = sig.direct[cap]
        unless direct.nil?
          line, col, what = direct
          diags << Diagnostic.new("E130", "'#{display(sig)}' uses #{cap} (#{what}), but its module does not declare it; #{hint}", line, col, mod.file)
          next
        end
        call = sig.calls.find { |callee, _, _| caps_of(callee).include?(cap) && !module_of(callee).equal?(mod) }
        next if call.nil?
        callee, line, col = call
        diags << Diagnostic.new("E130", "'#{display(sig)}' uses #{cap} through '#{display(callee)}', but its module does not declare it; #{hint}", line, col, mod.file)
      end
    end

    def module_of(sig)
      @checker.modules[sig.func.mod || ""]
    end

    # "Point.len", "max(i64)", "m.f"
    def display(sig)
      return "#{sig.owner}.#{sig.name}" unless sig.owner.nil?
      return "#{sig.name}(#{sig.tenv.values.join(', ')})" unless sig.tenv.empty?
      sig.name
    end
  end
end
