# Resolution: from the root package's manifest to one version of every
# package it needs, directly or not.
#
# The graph is walked breadth first, in manifest order. A package is
# chosen where it is first reached, and every later requirement must
# accept that choice (it is an error otherwise, not a re-solve): one
# version of a package per program, as two copies of its types would be
# different types.
#
# Choosing (minimal version selection): an index package gets the lowest
# release its constraint accepts, so a build never rides a newer release
# by itself; upgrades are `clutch update`. The lock comes first: a package
# pinned there keeps its pin while the manifest still accepts it, without
# reading the index or fetching. Path packages are read where they are,
# never pinned.

require "pathname"

module Clutch
  class Resolver
    # lock: name -> Locked from clutch.lock; unlock: names to choose
    # afresh (all of them when true)
    def initialize(root, git, index, lock: {}, unlock: [])
      @root = root
      @git = git
      @index = index
      @lock = lock
      @unlock = unlock
    end

    # The packages, in the order they were reached (each a Locked with dir)
    def resolve
      chosen = {}
      why = {}
      queue = @root.deps.map { |d| [d, @root] }
      until queue.empty?
        dep, from = queue.shift
        req = "#{from == @root ? "#{@root.name} (the root)" : from.name} needs #{dep.name}#{dep.constraint ? " #{dep.constraint}" : ""}"
        if dep.name == @root.name
          raise Error, "#{req}, but that is the root package's own name"
        end
        if (have = chosen[dep.name])
          agree(have, dep, from, req, why[dep.name])
          next
        end
        pkg, manifest = choose(dep, from, req)
        chosen[dep.name] = pkg
        why[dep.name] = req
        manifest.deps.each { |d| queue << [d, manifest] }
      end
      chosen.values
    end

    private

    def choose(dep, from, req)
      case dep.kind
      when :path
        dir = File.expand_path(dep.path, from.dir)
        raise Error, "#{req}: no directory #{dir}" unless File.directory?(dir)
        m = load(dir, dep, req)
        [Locked.new(dep.name, m.version, "path", nil, nil, nil, relative(dir), dir), m]
      when :git
        pin = pinned(dep.name)
        sha = if pin && pin.source == "git" && pin.git == dep.git && pin.requested == dep.ref && pin.ref.to_s.match?(Git::SHA)
                pin.ref
              else
                @git.resolve(dep.git, dep.ref)
              end
        dir = @git.checkout(dep.git, sha, dep.name)
        m = load(dir, dep, req)
        [Locked.new(dep.name, m.version, "git", dep.git, sha, dep.ref, nil, dir), m]
      else
        pin = pinned(dep.name)
        version = pin && pin.source == "index" && pin.ref.to_s.match?(Git::SHA) && pin.git ? safe_version(pin.version) : nil
        if version && dep.constraint.satisfied_by?(version)
          repo = pin.git
          sha = pin.ref
        else
          entry = @index.entry(dep.name)
          raise Error, "#{req}, which is not in the index (#{@index}); a package outside it is { git = URL } or { path = DIR }" if entry.nil?
          release = entry.releases.select { |r| dep.constraint.satisfied_by?(r.version) }.min_by(&:version)
          if release.nil?
            have = entry.releases.map { |r| r.version.to_s }
            raise Error, "#{req}, but the index has no release it accepts (#{have.empty? ? "none" : have.join(", ")})"
          end
          version = release.version
          repo = entry.repo
          sha = release.ref
        end
        dir = @git.checkout(repo, sha, dep.name)
        m = load(dir, dep, req)
        if m.version != version
          raise Error, "#{dep.name} #{version} in the index is #{sha[0, 12]} of #{repo}, whose clutch.toml says version #{m.version}"
        end
        [Locked.new(dep.name, version, "index", repo, sha, nil, nil, dir), m]
      end
    end

    # A second requirement on a package already chosen.
    def agree(have, dep, from, req, first)
      same = case dep.kind
             when :path then have.source == "path" && have.dir == File.expand_path(dep.path, from.dir)
             when :git then have.source == "git" && have.git == dep.git && have.requested == dep.ref
             else have.source == "index"
             end
      unless same
        raise Error, "#{req} from #{describe(dep, from)}, but #{dep.name} is already #{describe_locked(have)}, since #{first}; a program has one copy of each package"
      end
      return if dep.constraint.nil? || dep.constraint.satisfied_by?(have.version)
      raise Error, "#{req}, but #{dep.name} is already #{have.version}, since #{first}; a program has one version of each package"
    end

    def load(dir, dep, req)
      m = Manifest.load(dir)
      if m.name != dep.name
        raise Error, "#{req}, but the package in #{dir} is named #{m.name}"
      end
      if dep.kind != :index && dep.constraint && !dep.constraint.satisfied_by?(m.version)
        raise Error, "#{req}, but #{dir} has version #{m.version}"
      end
      m
    end

    def pinned(name)
      return nil if @unlock == true || @unlock.include?(name)
      @lock[name]
    end

    def safe_version(text)
      Version.parse(text)
    rescue VersionError
      nil
    end

    def describe(dep, from)
      case dep.kind
      when :path then "the directory #{File.expand_path(dep.path, from.dir)}"
      when :git then "#{dep.git}#{dep.ref ? " at #{dep.ref}" : ""}"
      else "the index"
      end
    end

    def describe_locked(p)
      case p.source
      when "path" then "the directory #{p.dir}"
      when "git" then "#{p.git}#{p.requested ? " at #{p.requested}" : ""}"
      else "#{p.version} from the index"
      end
    end

    # A path package's directory as the lock records it: relative to the
    # root package when it can be.
    def relative(dir)
      Pathname.new(dir).relative_path_from(Pathname.new(@root.dir)).to_s
    rescue ArgumentError
      dir
    end
  end
end
