# Builds the CodSpeed benchmark programs (bench/codspeed/*.egg) with eggc
# into bench/build/codspeed/, where codspeed.yaml runs them.
#
# Usage: ruby bench/codspeed/build.rb

require "open3"

HERE = __dir__
ROOT = File.expand_path("../..", HERE)
OUT = File.join(ROOT, "bench", "build", "codspeed")
EGGC = File.join(ROOT, "bin", "eggc")

require "fileutils"
FileUtils.mkdir_p(OUT)

failed = false
Dir[File.join(HERE, "*.egg")].sort.each do |src|
  exe = File.join(OUT, File.basename(src, ".egg"))
  out, ok = Open3.capture2e("ruby", EGGC, "build", src, "-o", exe)
  if ok.success?
    puts "built #{exe}"
  else
    warn "#{src}: build failed\n#{out}"
    failed = true
  end
end
exit(failed ? 1 : 0)
