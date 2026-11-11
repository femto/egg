# clutch's commands. Everything that touches a manifest, the lock, git or
# the network is here; eggc only gets --pkg NAME=DIR for each package.

require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

module Clutch
  USAGE = <<~TEXT
    usage: clutch COMMAND [ARGS]

      new NAME [--lib]        make a package in the directory NAME: a program
                              (src/main.egg), or with --lib a library
                              (src/NAME.egg)
      add NAME [VERSION]      depend on NAME from the index (VERSION such as
                              "~> 1.2"; the newest release's ~> by default)
      add NAME --git URL [--ref REF]
      add NAME --path DIR
      add NAME ... --dev      any of these as a dev-dependency, for the tests
      remove NAME             drop a dependency
      check                   type-check the package (src/main.egg, or the
                              library's src/NAME.egg)
      build [--release] [-g] [-o EXE]
                              build src/main.egg into build/NAME
      run [--release] [-g] [-- ARGS]
                              build and run it
      test [NAME...]          build and run each test/NAME.egg: it passes
                              when it exits 0 and prints test/NAME.expected
                              (if there is one)
      flags [--test]          the eggc flags for the dependencies (--pkg NAME=DIR);
                              with --test, those a test is built with (the
                              dev-dependencies and the package itself too)
      lock                    resolve and write clutch.lock
      update [NAME...]        choose versions afresh, ignoring clutch.lock
      publish [--repo URL] [--dry-run]
                              add this commit as a release to the index: a
                              pull request through gh (pushed, clean, and
                              passing clutch check and clutch test first)

    The commands after new work in the package holding the current
    directory. CLUTCH_INDEX names the package index, CLUTCH_CACHE the cache,
    CLUTCH_OFFLINE=1 builds from the cache alone, and CLUTCH_EGGC is the
    eggc to run.
  TEXT

  class CLI
    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    # The exit status.
    def run
      cmd = @argv.shift
      case cmd
      when "new" then cmd_new
      when "add" then cmd_add
      when "remove" then cmd_remove
      when "check" then cmd_eggc("check")
      when "build" then cmd_eggc("build")
      when "run" then cmd_eggc("run")
      when "test" then cmd_test
      when "flags" then cmd_flags
      when "lock" then @argv.empty? ? cmd_lock([]) : usage
      when "update" then cmd_lock(@argv.empty? ? true : @argv)
      when "publish" then cmd_publish
      when "help", "-h", "--help"
        @out.print USAGE
        0
      else
        @err.print USAGE
        2
      end
    rescue Error, TomlError => e
      @err.puts "clutch: #{e.message}"
      1
    end

    private

    def cmd_new
      lib = !@argv.delete("--lib").nil?
      name = @argv.shift
      return usage unless name && @argv.empty?
      pkg = File.basename(name)
      unless pkg.match?(NAME) && pkg != "std"
        raise Error, "#{pkg.inspect} cannot name a package: use letters, digits and _, not starting with a digit (and not std)"
      end
      raise Error, "#{name} already exists" if File.exist?(name)
      FileUtils.mkdir_p(File.join(name, "src"))
      File.write(File.join(name, "clutch.toml"), <<~TOML)
        [package]
        name = #{Toml.quote(pkg)}
        version = "0.1.0"

        [dependencies]
      TOML
      # A library's users choose its dependencies' versions, so its lock is
      # not kept; a program's is.
      File.write(File.join(name, ".gitignore"), lib ? "/build/\n/clutch.lock\n" : "/build/\n")
      if lib
        File.write(File.join(name, "src", "#{pkg}.egg"), <<~EGG)
          // The package #{pkg}: @import("#{pkg}") is this file.

          fn add(a: i64, b: i64) i64 {
              return a + b
          }
        EGG
        FileUtils.mkdir_p(File.join(name, "test"))
        File.write(File.join(name, "test", "#{pkg}.egg"), <<~EGG)
          // A test of #{pkg}, run by clutch test: it passes when main
          // returns without an error.
          uses io

          const lib = @import("#{pkg}")

          fn main(io: Io) !void {
              if (lib.add(2, 3) != 5) {
                  io.print("add(2, 3) is not 5")
                  return error.Failed
              }
          }
        EGG
      else
        File.write(File.join(name, "src", "main.egg"), <<~EGG)
          uses io

          fn main(io: Io) void {
              io.print("hello from #{pkg}")
          }
        EGG
      end
      @out.puts "made #{lib ? "the library" : "the program"} #{pkg} in #{name}/"
      0
    end

    def cmd_add
      dev = !@argv.delete("--dev").nil?
      name = @argv.shift
      return usage if name.nil?
      opts = {}
      until @argv.empty?
        a = @argv.shift
        if %w[--git --ref --path].include?(a)
          v = @argv.shift
          return usage if v.nil?
          opts[a] = v
        elsif opts[:version].nil? && !a.start_with?("--")
          opts[:version] = a
        else
          return usage
        end
      end
      raise Error, "#{name.inspect} is not a package name" unless name.match?(NAME)
      raise Error, "--ref goes with --git" if opts["--ref"] && !opts["--git"]
      raise Error, "give one of --git and --path" if opts["--git"] && opts["--path"]
      dir = project_dir
      m = Manifest.load(dir)
      raise Error, "#{name} is already a dependency of #{m.name}" if m.deps.any? { |d| d.name == name }
      raise Error, "#{name} is already a dev-dependency of #{m.name}" if m.dev_deps.any? { |d| d.name == name }
      spec = if opts["--git"]
               parts = ["git = #{Toml.quote(opts["--git"])}"]
               parts << "ref = #{Toml.quote(opts["--ref"])}" if opts["--ref"]
               parts << "version = #{Toml.quote(opts[:version])}" if opts[:version]
               "{ #{parts.join(", ")} }"
             elsif opts["--path"]
               parts = ["path = #{Toml.quote(opts["--path"])}"]
               parts << "version = #{Toml.quote(opts[:version])}" if opts[:version]
               "{ #{parts.join(", ")} }"
             else
               Toml.quote(opts[:version] || newest(name))
             end
      file = File.join(dir, "clutch.toml")
      before = File.read(file)
      File.write(file, add_line(before, "#{name} = #{spec}", dev ? "dev-dependencies" : "dependencies"))
      begin
        pkgs = resolve(dir)
      rescue Error, TomlError
        File.write(file, before)
        raise
      end
      got = pkgs.find { |p| p.name == name }
      @out.puts "added #{name} #{got.version}#{dev ? " (for the tests)" : ""}"
      0
    end

    def cmd_remove
      name = @argv.shift
      return usage unless name && @argv.empty?
      dir = project_dir
      file = File.join(dir, "clutch.toml")
      text = File.read(file)
      lines = text.lines
      section = nil
      hit = nil
      lines.each_with_index do |l, i|
        if (h = l[/\A\s*\[([^\]]*)\]/, 1])
          section = h.strip
        elsif %w[dependencies dev-dependencies].include?(section) && l.match?(/\A\s*"?#{Regexp.escape(name)}"?\s*=/)
          hit = i
        end
      end
      raise Error, "#{name} is not a dependency" if hit.nil?
      lines.delete_at(hit)
      File.write(file, lines.join)
      begin
        resolve(dir)
      rescue Error, TomlError
        File.write(file, text)
        raise
      end
      @out.puts "removed #{name}"
      0
    end

    def cmd_lock(unlock)
      dir = project_dir
      pkgs = resolve(dir, unlock: unlock)
      pkgs.each do |p|
        notes = [p.source == "index" ? nil : p.source, p.dev ? "dev" : nil].compact
        @out.puts "#{p.name} #{p.version}#{notes.empty? ? "" : " (#{notes.join(", ")})"}"
      end
      0
    end

    def cmd_flags
      test = !@argv.delete("--test").nil?
      return usage unless @argv.empty?
      dir = project_dir
      m = Manifest.load(dir)
      pkgs = resolve(dir, manifest: m)
      flags = test ? test_flags(m, pkgs) : pkg_flags(pkgs)
      @out.puts flags.map { |a| shell_word(a) }.join(" ")
      0
    end

    # The --pkg flags of m's tests: its dependencies, dev-dependencies and
    # m itself.
    def test_flags(m, pkgs)
      flags = pkg_flags(pkgs, dev: true)
      flags += ["--pkg", "#{m.name}=#{m.src_dir}"] if File.directory?(m.src_dir)
      flags
    end

    # dir: the package (the one holding the current directory by default);
    # shown_as: for dir a copy of the package, the package's own directory,
    # named in eggc's messages in place of the copy's (whose lock is not
    # kept)
    def cmd_eggc(command, dir = nil, shown_as: nil)
      program_args = []
      if (i = @argv.index("--"))
        return usage unless command == "run"
        program_args = @argv[(i + 1)..]
        @argv = @argv[0...i]
      end
      passed = []
      out = nil
      until @argv.empty?
        a = @argv.shift
        if (a == "--release" || a == "-g") && command != "check"
          passed << a
        elsif a == "-o" && command == "build"
          out = @argv.shift
          return usage if out.nil?
        else
          return usage
        end
      end
      dir ||= project_dir
      m = Manifest.load(dir)
      pkgs = resolve(dir, manifest: m, write_lock: shown_as.nil?)
      flags = pkg_flags(pkgs)
      file = m.main_file
      if command == "check" && !File.file?(file) && File.file?(m.lib_file)
        # A library has no main: check it through a root that imports it
        # by name, as its users will.
        file = File.join(dir, "build", "check_#{m.name}.egg")
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "// Written by clutch check: the library #{m.name}, imported as its users do.\nconst lib = @import(#{Toml.quote(m.name)})\n\nfn main() void {\n}\n")
        flags += ["--pkg", "#{m.name}=#{m.src_dir}"]
      end
      unless File.file?(file)
        raise Error, command == "check" ? "#{m.name} has neither src/main.egg nor src/#{m.name}.egg" : "#{m.name} has no src/main.egg to #{command} (a library is checked with clutch check)"
      end
      args = [command, file] + passed + flags
      if command == "build"
        out ||= File.join(dir, "build", m.name)
        FileUtils.mkdir_p(File.dirname(File.expand_path(out)))
        args += ["-o", out]
      end
      args += ["--"] + program_args unless program_args.empty?
      cannot = ->(why) { raise Error, "cannot run eggc (#{eggc.join(" ")}): #{why}" }
      if shown_as.nil?
        ran = system(*eggc, *args)
        cannot.("no such program, or it cannot be started") if ran.nil?
        return ran ? 0 : $?.exitstatus || 1
      end
      out, err, st = begin
        Open3.capture3(*eggc, *args)
      rescue SystemCallError => e
        cannot.(e.message)
      end
      copies = [File.realpath(dir), dir].uniq
      shown = ->(t) { shown_text(t, copies, shown_as) }
      @out.print shown.(out)
      @err.print shown.(err)
      st.exitstatus || 1
    end

    def cmd_publish
      dry = !@argv.delete("--dry-run").nil?
      repo = nil
      if (i = @argv.index("--repo"))
        repo = @argv[i + 1]
        return usage if repo.nil?
        @argv.slice!(i, 2)
      end
      return usage unless @argv.empty?
      pub = Publish.new(project_dir, repo: repo).prepare
      text = pub.index_text
      # The gate: the release as its users get it checks and passes its
      # tests. In a copy, so neither the cache nor the package's own
      # directory is written.
      Dir.mktmpdir("clutch-publish-") do |tmp|
        copy = File.join(tmp, pub.name)
        FileUtils.cp_r(pub.release_dir, copy)
        unless cmd_eggc("check", copy, shown_as: pub.dir).zero?
          raise Error, "#{pub.name} #{pub.version} does not pass clutch check; nothing was published"
        end
        if !test_names(copy).empty? && !run_tests(copy, [], shown_as: pub.dir).zero?
          raise Error, "#{pub.name} #{pub.version} does not pass clutch test; nothing was published"
        end
      end
      if dry
        @out.print text
        @err.puts "clutch: --dry-run: #{pub.name} #{pub.version} (#{pub.sha[0, 12]}) is ready; the index's packages/#{pub.name}.toml would be the text above"
        return 0
      end
      begin
        @out.puts pub.submit(text)
      rescue Error
        @out.print text
        raise
      end
      0
    end

    def cmd_test
      return usage if @argv.any? { |a| a.start_with?("-") }
      run_tests(project_dir, @argv)
    end

    # The names of dir's tests, test/NAME.egg.
    def test_names(dir)
      Dir[File.join(dir, "test", "*.egg")].map { |f| File.basename(f, ".egg") }.sort
    end

    # Builds and runs dir's tests (names, or all of them); the exit status.
    # shown_as: as for cmd_eggc.
    def run_tests(dir, names, shown_as: nil)
      all = test_names(dir)
      raise Error, "no tests: a test is a program test/NAME.egg, passing when it exits 0" if all.empty?
      if (bad = names.find { |n| !all.include?(n) })
        raise Error, "no test #{bad} (the tests: #{all.join(", ")})"
      end
      names = all if names.empty?
      m = Manifest.load(dir)
      pkgs = resolve(dir, manifest: m, write_lock: shown_as.nil?)
      flags = test_flags(m, pkgs)
      copies = shown_as.nil? ? [] : [File.realpath(dir), dir].uniq
      shown = ->(t) { shown_text(t, copies, shown_as) }
      cannot = ->(why) { raise Error, "cannot run eggc (#{eggc.join(" ")}): #{why}" }
      failed = 0
      names.each do |n|
        src = File.join(dir, "test", "#{n}.egg")
        exe = File.join(dir, "build", "test", n)
        FileUtils.mkdir_p(File.dirname(exe))
        out, err, st = begin
          Open3.capture3(*eggc, "build", src, "-o", exe, *flags)
        rescue SystemCallError => e
          cannot.(e.message)
        end
        why = nil
        if st.success?
          out, err, st = Open3.capture3(exe, chdir: dir)
          expected = File.join(dir, "test", "#{n}.expected")
          if !st.success?
            why = "exited with #{st.exitstatus || st.termsig && "signal #{st.termsig}"}"
          elsif File.file?(expected) && File.binread(expected) != out.b
            why = "printed other than test/#{n}.expected"
          end
        else
          why = "does not build"
        end
        if why.nil?
          @out.puts "  ok    #{n}"
        else
          failed += 1
          @out.puts "  FAIL  #{n} (#{why})"
          [out, err].each { |t| @out.print shown.(t).gsub(/^/n, "        ") unless t.empty? }
        end
      end
      @out.puts "#{names.length - failed} passed, #{failed} failed"
      failed.zero? ? 0 : 1
    end

    # Resolves dir's package and writes the lock; the resolved packages.
    # unlock: names to choose afresh, each a package of the program
    # (or true for all).
    # write_lock: false to leave the lock as it is.
    def resolve(dir, unlock: [], manifest: nil, write_lock: true)
      m = manifest || Manifest.load(dir)
      git = Git.new
      pkgs = Resolver.new(m, git, Index.new(git), lock: Lock.read(dir), unlock: unlock).resolve
      if unlock.is_a?(Array)
        missing = unlock.reject { |n| pkgs.any? { |p| p.name == n } }
        raise Error, "#{missing[0]} is not a package of #{m.name} (clutch update takes the names of its packages)" unless missing.empty?
      end
      @err.puts "clutch: wrote clutch.lock" if write_lock && Lock.write(dir, pkgs)
      pkgs
    end

    # text (a program's output, any bytes) with each of copies replaced
    # by shown_as.
    def shown_text(text, copies, shown_as)
      copies.reduce(text.b) { |acc, c| acc.gsub(c.b, shown_as.b) }
    end

    # The --pkg flags; with dev, for the tests, the dev-dependencies too.
    def pkg_flags(pkgs, dev: false)
      pkgs.select { |p| dev || !p.dev }.flat_map { |p| ["--pkg", "#{p.name}=#{File.join(p.dir, "src")}"] }
    end

    # a, quoted for a POSIX shell when it needs to be.
    def shell_word(a)
      a.match?(%r{\A[A-Za-z0-9_@%+=:,./-]+\z}) ? a : "'#{a.gsub("'", "'\\\\''")}'"
    end

    def eggc
      return Shellwords.split(ENV["CLUTCH_EGGC"]) unless ENV["CLUTCH_EGGC"].to_s.empty?
      [RbConfig.ruby, File.expand_path("../../bin/eggc", __dir__)]
    end

    # The newest release of name in the index, as a ~> constraint.
    def newest(name)
      git = Git.new
      index = Index.new(git)
      entry = index.entry(name)
      raise Error, "#{name} is not in the index (#{index}); a package outside it is added with --git URL or --path DIR" if entry.nil?
      top = entry.releases.map(&:version).max
      raise Error, "#{name} has no releases in the index" if top.nil?
      "~> #{top.parts[0]}.#{top.parts[1]}"
    end

    # text with line added at the end of its [table] (made if there is
    # none).
    def add_line(text, line, table = "dependencies")
      lines = text.lines
      lines[-1] += "\n" if !lines.empty? && !lines[-1].end_with?("\n")
      start = lines.index { |l| l.match?(/\A\s*\[\s*#{Regexp.escape(table)}\s*\]/) }
      if start.nil?
        lines << "\n" unless lines.empty? || lines[-1].strip.empty?
        lines << "[#{table}]\n" << "#{line}\n"
        return lines.join
      end
      stop = (start + 1...lines.length).find { |i| lines[i].match?(/\A\s*\[/) } || lines.length
      last = stop - 1
      last -= 1 while last > start && lines[last].strip.empty?
      lines.insert(last + 1, "#{line}\n")
      lines.join
    end

    # The directory of the clutch.toml holding the current directory.
    def project_dir
      d = Dir.pwd
      loop do
        return d if File.file?(File.join(d, "clutch.toml"))
        up = File.dirname(d)
        raise Error, "no clutch.toml here or in any directory above (clutch new NAME makes a package)" if up == d
        d = up
      end
    end

    def usage
      @err.print USAGE
      2
    end
  end
end
