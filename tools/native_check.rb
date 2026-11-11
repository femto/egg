# Checks that a native eggc (built by Spinel) says exactly what eggc on
# Ruby says: the C it emits, its diagnostics and its exit status, for every
# example, error test, std module and egg example in the spec.
#
#   ruby tools/native_check.rb PATH/TO/eggc

require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
native = ARGV[0] or abort "usage: ruby tools/native_check.rb PATH/TO/eggc"
native = File.expand_path(native)

Dir.mktmpdir do |dir|
  files = %w[examples/**/*.egg test/errors/*.egg lib/std/*.egg].flat_map { |g| Dir[File.join(ROOT, g)] }.sort
  File.read(File.join(ROOT, "spec", "core.md")).scan(/```egg\n(.*?)```/m).each_with_index do |(block), i|
    f = File.join(dir, format("spec_%03d.egg", i + 1))
    File.write(f, block)
    files << f
  end
  differ = []
  files.each do |f|
    cmds = [["emit-c", f]]
    cmds << ["check", "--json", f] if f.include?("test/errors")
    cmds.each do |args|
      r = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin", "eggc"), *args, chdir: ROOT)
      # The same std for both: diagnostics in it name its files.
      n = Open3.capture3({ "EGG_STD" => File.join(ROOT, "lib", "std") }, native, *args, chdir: ROOT)
      next if r[0] == n[0] && r[1] == n[1] && r[2].exitstatus == n[2].exitstatus
      differ << "#{args.join(' ')}: exit #{r[2].exitstatus} on Ruby, #{n[2].exitstatus} native\n  ruby:   #{(r[1] + r[0])[0, 300].inspect}\n  native: #{(n[1] + n[0])[0, 300].inspect}"
    end
  end
  puts differ
  puts "#{files.length} files, #{differ.length} differ"
  exit(differ.empty? ? 0 : 1)
end
