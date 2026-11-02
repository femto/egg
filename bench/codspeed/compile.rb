# Compiles every FILE.egg (or every *.egg directly in DIR) to C in one
# process, so that a benchmark measures the compiler (lexer, parser,
# checkers, C generation) rather than Ruby's start-up. Prints how many files compiled and how many had diagnostics.
#
# Usage: ruby bench/codspeed/compile.rb (FILE.egg|DIR)...

require_relative "../../lib/egg"

abort "usage: ruby bench/codspeed/compile.rb (FILE.egg|DIR)..." if ARGV.empty?

paths = ARGV.flat_map { |a| File.directory?(a) ? Dir[File.join(a, "*.egg")].sort : [a] }

compiled = 0
rejected = 0
paths.each do |path|
  result = Egg.compile_to_c(File.read(path), path)
  if result.diagnostics.empty?
    compiled += 1
  else
    rejected += 1
  end
end
puts "#{compiled} compiled, #{rejected} with diagnostics"
