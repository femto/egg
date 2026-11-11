# Where the files that come with eggc and clutch are. On Ruby, beside these
# sources. In a native binary (compiled by Spinel), __dir__ is where it was
# compiled, so they are found beside the executable instead: an install is
# PREFIX/bin/{eggc,clutch} with PREFIX/lib/std and PREFIX/spec.

module Egg
  # Running as a native binary?
  def self.native?
    RUBY_ENGINE == "spinel"
  end

  # The running program's file: argv[0], found on PATH when it is a bare
  # name, with links followed.
  def self.exe_path
    p = $0
    unless p.include?("/") || p.include?("\\")
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |d|
        [p, "#{p}.exe"].each do |name|
          f = File.join(d, name)
          return File.realpath(f) if File.file?(f) && File.executable?(f)
        end
      end
    end
    File.exist?(p) ? File.realpath(p) : File.expand_path(p)
  end

  # PREFIX for a native binary at PREFIX/bin/NAME.
  def self.install_root
    File.dirname(File.dirname(exe_path))
  end

  # The directory `rel` of the install, for a native binary that has one
  # there; otherwise `from_source`, the one beside these sources.
  def self.home_dir(rel, from_source)
    if native?
      d = File.join(install_root, rel)
      return d if File.directory?(d)
    end
    from_source
  end

  # Another program installed beside a native binary (eggc beside clutch),
  # or nil.
  def self.sibling(name)
    return nil unless native?
    dir = File.dirname(exe_path)
    [name, "#{name}.exe"].each do |n|
      f = File.join(dir, n)
      return f if File.file?(f) && File.executable?(f)
    end
    nil
  end
end
