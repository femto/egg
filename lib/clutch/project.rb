# clutch.toml, a package's manifest, and clutch.lock, what resolution
# chose.
#
#   [package]
#   name = "chat"
#   version = "0.1.0"
#
#   [dependencies]
#   http = "~> 0.1"                                    # from the index
#   ansi = { git = "https://github.com/x/egg-ansi" }   # its default branch
#   term = { git = "https://...", ref = "v0.2.0" }     # a branch, tag or SHA
#   util = { path = "../util" }                        # a directory
#
# A git or path dependency may also give `version = "~> 1.2"`, checked
# against its clutch.toml. A package's code is under src/: src/<name>.egg
# is @import("<name>"), and src/main.egg the program's main, if any.

module Clutch
  class Error < StandardError; end

  NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  # kind: :index, :git or :path; constraint: a Constraint or nil;
  # git, ref: for :git; path: for :path, as written
  Dep = Struct.new(:name, :kind, :constraint, :git, :ref, :path)

  class Manifest
    attr_reader :dir, :name, :version, :deps

    def self.load(dir)
      path = File.join(dir, "clutch.toml")
      raise Error, "no clutch.toml in #{dir}" unless File.file?(path)
      new(dir, File.read(path), path)
    end

    def initialize(dir, text, file)
      @dir = dir
      @file = file
      doc = Toml.parse(text, file)
      known(doc, %w[package dependencies], "")
      pkg = doc["package"]
      raise Error, "#{file}: [package] is missing" unless pkg.is_a?(Hash)
      known(pkg, %w[name version], "[package] ")
      @name = pkg["name"]
      unless @name.is_a?(String) && @name.match?(NAME) && @name != "std"
        raise Error, "#{file}: the package's name is a plain name such as http (not std), not #{@name.inspect}"
      end
      begin
        @version = Version.parse(pkg["version"])
      rescue VersionError => e
        raise Error, "#{file}: [package] version: #{e.message}"
      end
      deps = doc["dependencies"] || {}
      raise Error, "#{file}: [dependencies] must be a table" unless deps.is_a?(Hash)
      @deps = deps.map { |n, spec| dep(n, spec) }
    end

    def src_dir
      File.join(@dir, "src")
    end

    def main_file
      File.join(src_dir, "main.egg")
    end

    def lib_file
      File.join(src_dir, "#{@name}.egg")
    end

    private

    def dep(name, spec)
      where = "#{@file}: dependency #{name}"
      raise Error, "#{where}: a name is a plain name such as http" unless name.match?(NAME)
      raise Error, "#{where}: std is the standard library, not a package" if name == "std"
      raise Error, "#{where}: a package cannot depend on itself" if name == @name
      if spec.is_a?(String)
        return Dep.new(name, :index, constraint(spec, where))
      end
      raise Error, "#{where}: give a version (\"~> 1.2\") or a table ({ git = ... } or { path = ... })" unless spec.is_a?(Hash)
      known(spec, %w[git ref path version], "dependency #{name}: ")
      c = spec.key?("version") ? constraint(spec["version"], where) : nil
      if spec.key?("git") == spec.key?("path")
        raise Error, "#{where}: give one of git and path"
      end
      if spec.key?("git")
        raise Error, "#{where}: git is a URL" unless spec["git"].is_a?(String) && !spec["git"].empty?
        raise Error, "#{where}: ref is a branch, tag or commit" if spec.key?("ref") && !(spec["ref"].is_a?(String) && !spec["ref"].empty?)
        Dep.new(name, :git, c, spec["git"], spec["ref"])
      else
        raise Error, "#{where}: ref goes with git" if spec.key?("ref")
        raise Error, "#{where}: path is a directory" unless spec["path"].is_a?(String) && !spec["path"].empty?
        Dep.new(name, :path, c, nil, nil, spec["path"])
      end
    end

    def constraint(text, where)
      Constraint.parse(text)
    rescue VersionError => e
      raise Error, "#{where}: #{e.message}"
    end

    def known(table, keys, where)
      extra = table.keys - keys
      return if extra.empty?
      raise Error, "#{@file}: #{where}unknown key '#{extra[0]}' (known: #{keys.join(", ")})"
    end
  end

  # One package as resolved. source: "index", "git" or "path"; git, ref:
  # the repository and the full commit SHA (index and git); requested: the
  # ref the manifest asked for (git); path: as the manifest wrote it;
  # dir: the package's directory on disk.
  Locked = Struct.new(:name, :version, :source, :git, :ref, :requested, :path, :dir)

  module Lock
    HEADER = "# clutch.lock: what clutch chose for each dependency. Written by clutch; do not edit.\n"

    # name -> Locked (without dir), or {} when there is no lock
    def self.read(dir)
      path = File.join(dir, "clutch.lock")
      return {} unless File.file?(path)
      doc = Toml.parse(File.read(path), path)
      bad = ->(why) { raise Error, "#{path}: #{why}; delete the file and clutch writes it again" }
      bad.("[lock] holds one table per package") unless doc["lock"].nil? || doc["lock"].is_a?(Hash)
      out = {}
      (doc["lock"] || {}).each do |name, e|
        bad.("[lock.#{name}] is not a table") unless e.is_a?(Hash)
        str = ->(k) { e[k].nil? || e[k].is_a?(String) ? e[k] : bad.("[lock.#{name}] #{k} is not a string") }
        version = str.("version")
        source = str.("source")
        bad.("[lock.#{name}] has no version") if version.nil?
        case source
        when "index", "git"
          bad.("[lock.#{name}] needs git and a full commit SHA as ref") unless str.("git") && str.("ref").to_s.match?(/\A\h{40}\z/)
        when "path"
          bad.("[lock.#{name}] needs path") if str.("path").nil?
        else
          bad.("[lock.#{name}] source is index, git or path, not #{source.inspect}")
        end
        out[name] = Locked.new(name, version, source, str.("git"), str.("ref"), str.("requested"), str.("path"))
      end
      out
    end

    def self.text(packages)
      out = +HEADER
      packages.sort_by(&:name).each do |p|
        out << "\n[lock.#{p.name}]\n"
        out << "version = #{Toml.quote(p.version.to_s)}\n"
        out << "source = #{Toml.quote(p.source)}\n"
        out << "git = #{Toml.quote(p.git)}\n" if p.git
        out << "ref = #{Toml.quote(p.ref)}\n" if p.ref
        out << "requested = #{Toml.quote(p.requested)}\n" if p.requested
        out << "path = #{Toml.quote(p.path)}\n" if p.path
      end
      out
    end

    # Writes the lock if it changed; true when it did.
    def self.write(dir, packages)
      path = File.join(dir, "clutch.lock")
      t = text(packages)
      return false if File.file?(path) && File.read(path) == t
      File.write(path, t)
      true
    end
  end
end
