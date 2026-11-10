# Fetching: git repositories and the package index, cached under
# $CLUTCH_CACHE (default $XDG_CACHE_HOME/clutch, or ~/.cache/clutch).
#
#   git/db/<repo>       a bare clone of each repository
#   git/src/<name>-<sha> a package's files at one commit, never changed
#
# Each repository is fetched at most once a run, and never with
# CLUTCH_OFFLINE=1, which builds from the cache alone.

require "digest"
require "fileutils"
require "open3"

module Clutch
  def self.cache_dir
    return File.expand_path(ENV["CLUTCH_CACHE"]) unless ENV["CLUTCH_CACHE"].to_s.empty?
    base = ENV["XDG_CACHE_HOME"].to_s.empty? ? File.join(Dir.home, ".cache") : ENV["XDG_CACHE_HOME"]
    File.join(File.expand_path(base), "clutch")
  end

  def self.offline?
    !ENV["CLUTCH_OFFLINE"].to_s.empty? && ENV["CLUTCH_OFFLINE"] != "0"
  end

  class Git
    SHA = /\A\h{40}\z/

    def initialize(cache = Clutch.cache_dir)
      @cache = cache
      @fetched = {}
    end

    # The full SHA of ref (a branch, tag or commit; nil for the default
    # branch) in the repository at url.
    def resolve(url, ref)
      db = repo(url)
      if ref&.match?(SHA)
        fetch(url) unless commit?(db, ref)
        raise Error, "#{url} has no commit #{ref}" unless commit?(db, ref)
        return ref.downcase
      end
      fetch(url)
      sha = rev_parse(db, ref.nil? ? "HEAD" : ref)
      sha ||= rev_parse(db, "refs/tags/#{ref}") unless ref.nil?
      raise Error, "#{url} has no #{ref.nil? ? "default branch" : "branch, tag or commit '#{ref}'"}" if sha.nil?
      sha
    end

    # The package's files at sha, extracted once into the cache.
    def checkout(url, sha, name)
      dest = File.join(@cache, "git", "src", "#{name}-#{sha[0, 12]}")
      return dest if File.directory?(dest)
      db = repo(url)
      fetch(url) unless commit?(db, sha)
      raise Error, "#{url} has no commit #{sha}" unless commit?(db, sha)
      tmp = "#{dest}.tmp-#{Process.pid}"
      FileUtils.rm_rf(tmp)
      FileUtils.mkdir_p(tmp)
      # Into tmp through an index file of its own (not tar, which on
      # Windows may be one that reads C: as a host name).
      idx = "#{tmp}.index"
      env = { "GIT_INDEX_FILE" => idx }
      git("--git-dir", db, "--work-tree", tmp, "read-tree", sha, env: env)
      git("--git-dir", db, "--work-tree", tmp, "checkout-index", "-a", "-f", env: env)
      File.delete(idx)
      begin
        File.rename(tmp, dest)
      rescue SystemCallError
        # Another clutch got there first.
        FileUtils.rm_rf(tmp)
        raise unless File.directory?(dest)
      end
      dest
    end

    # The text of path at the default branch's newest commit, or nil.
    def read(url, path)
      db = repo(url)
      fetch(url)
      out, _, st = Open3.capture3("git", "--git-dir", db, "show", "HEAD:#{path}")
      st.success? ? out : nil
    end

    private

    def repo(url)
      slug = url.sub(%r{/+\z}, "").sub(/\.git\z/, "").split(%r{[/:\\]}).last.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
      db = File.join(@cache, "git", "db", "#{slug}-#{Digest::SHA256.hexdigest(url)[0, 12]}")
      return db if File.directory?(db)
      raise Error, "#{url} is not in the cache, and CLUTCH_OFFLINE is set" if Clutch.offline?
      FileUtils.mkdir_p(File.dirname(db))
      tmp = "#{db}.tmp-#{Process.pid}"
      FileUtils.rm_rf(tmp)
      git("clone", "--bare", "--quiet", url, tmp)
      begin
        File.rename(tmp, db)
      rescue SystemCallError
        FileUtils.rm_rf(tmp)
        raise unless File.directory?(db)
      end
      @fetched[url] = true
      db
    end

    def fetch(url)
      return if @fetched[url] || Clutch.offline?
      git("--git-dir", repo(url), "fetch", "--quiet", "--prune", "--force", url,
          "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*")
      @fetched[url] = true
    end

    def commit?(db, sha)
      _, _, st = Open3.capture3("git", "--git-dir", db, "cat-file", "-e", "#{sha}^{commit}")
      st.success?
    end

    def rev_parse(db, ref)
      out, _, st = Open3.capture3("git", "--git-dir", db, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      st.success? ? out.strip : nil
    end

    def git(*args, env: {})
      _, err, st = Open3.capture3(env, "git", *args)
      raise Error, "git #{args.join(" ")} failed: #{err.strip}" unless st.success?
    end
  end

  # The package index: a git repository (or, for testing, a directory)
  # with packages/<name>.toml for each package:
  #
  #   name = "http"
  #   repo = "https://github.com/someone/egg-http"
  #   [[release]]
  #   version = "0.1.0"
  #   ref = "<full commit SHA in repo>"
  #
  # CLUTCH_INDEX names it; the default is femto/clutch-index on GitHub.
  class Index
    DEFAULT = "https://github.com/femto/clutch-index"

    Release = Struct.new(:version, :ref)
    Entry = Struct.new(:name, :repo, :releases)

    def initialize(git, where = ENV["CLUTCH_INDEX"].to_s.empty? ? DEFAULT : ENV["CLUTCH_INDEX"])
      @git = git
      @where = where
      @entries = {}
    end

    # name -> Entry, or nil when the index has no such package
    def entry(name)
      return @entries[name] if @entries.key?(name)
      file = "packages/#{name}.toml"
      text = File.directory?(@where) ? (File.file?(File.join(@where, file)) ? File.read(File.join(@where, file)) : nil) : @git.read(@where, file)
      @entries[name] = text.nil? ? nil : parse(name, text, "#{@where}/#{file}")
    end

    def to_s
      @where
    end

    private

    def parse(name, text, file)
      doc = Toml.parse(text, file)
      raise Error, "#{file}: name is #{doc["name"].inspect}, not #{name.inspect}" unless doc["name"] == name
      raise Error, "#{file}: repo is missing" unless doc["repo"].is_a?(String) && !doc["repo"].empty?
      releases = (doc["release"] || []).map do |r|
        raise Error, "#{file}: a [[release]] needs version and a full commit SHA as ref" unless r.is_a?(Hash) && r["ref"].is_a?(String) && r["ref"].match?(Git::SHA)
        begin
          Release.new(Version.parse(r["version"]), r["ref"].downcase)
        rescue VersionError => e
          raise Error, "#{file}: #{e.message}"
        end
      end
      Entry.new(name, doc["repo"], releases)
    end
  end
end
