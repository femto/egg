# clutch publish: the package's current commit as a release in the index.
#
# The package must be a library at the root of a clean git work tree whose
# HEAD its repository already has (pushed), with no path dependencies.
# clutch checks the release as users will get it (the files at that commit,
# from the repository), runs clutch check, then adds a [[release]] to
# packages/NAME.toml: in place for an index that is a directory, and as a
# pull request (through gh) for one on GitHub.

require "open3"
require "tmpdir"

module Clutch
  class Publish
    attr_reader :name, :version, :repo, :sha

    def initialize(dir, repo: nil, git: Git.new, index: nil)
      @dir = dir
      @repo_given = repo
      @git = git
      @index = index || Index.new(git)
    end

    # Checks the release; raises Error naming what stands in the way.
    def prepare
      m = Manifest.load(@dir)
      @name = m.name
      @version = m.version
      top = local_git("rev-parse", "--show-toplevel", what: "#{@dir} is not in a git repository")
      unless File.realpath(top) == File.realpath(@dir)
        raise Error, "#{@name}'s clutch.toml is not at the root of its git repository (#{top}), where users of the index look for it"
      end
      dirty = local_git("status", "--porcelain")
      raise Error, "#{@dir} has uncommitted changes: commit and push them first" unless dirty.empty?
      @sha = local_git("rev-parse", "HEAD", what: "#{@dir} has no commit yet")
      @repo = Publish.normalize(@repo_given || local_git("remote", "get-url", "origin", what: "#{@dir} has no remote origin: add one, or give --repo URL"), @dir)
      if Publish.local?(@repo) && !@index.local?
        raise Error, "#{@repo} is not a repository others can fetch (a path or file:// URL); push the package somewhere public and give --repo URL"
      end
      begin
        @git.resolve(@repo, @sha)
      rescue Error => e
        raise Error, "#{e.message}: push #{@sha[0, 12]} first"
      end
      pub = Manifest.load(@git.checkout(@repo, @sha, @name))
      unless pub.name == @name && pub.version == @version
        raise Error, "#{@repo} at #{@sha[0, 12]} holds #{pub.name} #{pub.version}, not #{@name} #{@version}"
      end
      unless File.file?(pub.lib_file)
        raise Error, "an index package is a library, but #{@name} has no src/#{@name}.egg"
      end
      if (d = pub.deps.find { |x| x.kind == :path })
        raise Error, "#{@name} depends on #{d.name} by path (#{d.path}), which its users cannot fetch: depend on it from the index or by git"
      end
      self
    end

    # packages/NAME.toml with this release added, in version order.
    def index_text
      entry = @index.entry(@name)
      release = "[[release]]\nversion = #{Toml.quote(@version.to_s)}\nref = #{Toml.quote(@sha)}\n"
      if entry.nil?
        return "name = #{Toml.quote(@name)}\nrepo = #{Toml.quote(@repo)}\n\n#{release}"
      end
      unless Publish.normalize(entry.repo, @dir) == @repo
        raise Error, "#{@name} in the index is #{entry.repo}, not #{@repo}: a name belongs to the package that first took it, so choose another"
      end
      if (same = entry.releases.find { |r| r.version == @version })
        raise Error, "#{@name} #{@version} is already in the index (at #{same.ref[0, 12]}); a release never changes, so publish a new version"
      end
      text = @index.text(@name)
      text += "\n" unless text.end_with?("\n")
      later = entry.releases.index { |r| r.version > @version }
      return "#{text}\n#{release}" if later.nil?
      # Before the later release's header, keeping the file oldest first.
      lines = text.lines
      at = lines.each_index.select { |i| lines[i].match?(/\A\s*\[\[\s*release\s*\]\]/) }[later]
      lines.insert(at, release, "\n")
      lines.join
    end

    # Adds the release to the index; what was done, for the user.
    def submit(text)
      if @index.local_dir?
        file = File.join(@index.to_s, "packages", "#{@name}.toml")
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, text)
        return "added #{@name} #{@version} to #{file}"
      end
      gh = Publish.github(@index.to_s)
      raise Error, "the index #{@index} is not on GitHub: open a pull request there that makes packages/#{@name}.toml the text above" if gh.nil?
      pull_request(*gh, text)
    end

    # url as the index records it: GitHub's ssh forms as https, no .git or
    # trailing /, and a local path absolute (from dir).
    def self.normalize(url, dir)
      u = url.strip.sub(%r{/+\z}, "")
      u = u.sub(%r{\A(?:git@github\.com:|ssh://git@github\.com/)}, "https://github.com/")
      u = u.sub(/\.git\z/, "") if u.start_with?("https://github.com/")
      return File.expand_path(u, dir) if local?(u) && !u.start_with?("file://")
      u
    end

    def self.local?(url)
      url.start_with?("file://") || !url.match?(%r{\A[A-Za-z][A-Za-z0-9+.-]+://|\A[^/\\]+@[^/\\]+:})
    end

    # [owner, repo] of a GitHub URL, or nil.
    def self.github(url)
      m = url.match(%r{\Ahttps://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?\z})
      m && [m[1], m[2]]
    end

    private

    def pull_request(owner, repo, text)
      run("gh", "--version", what: "gh (GitHub's CLI) is not installed: install it, or open a pull request against #{@index} that makes packages/#{@name}.toml the text above")
      login = run("gh", "api", "user", "-q", ".login", what: "gh is not logged in (gh auth login)")
      ssh = try("gh", "config", "get", "git_protocol", "-h", "github.com") == "ssh"
      target = "#{owner}/#{repo}"
      head = target
      if try("gh", "api", "repos/#{target}", "-q", ".permissions.push") != "true"
        run("gh", "repo", "fork", target, "--clone=false", what: "could not fork #{target}")
        head = try("gh", "api", "--paginate", "repos/#{target}/forks", "-q", ".[] | select(.owner.login == \"#{login}\") | .full_name")
        raise Error, "forked #{target}, but found no fork of #{login}'s" if head.empty?
        head = head.lines.first.strip
      end
      branch = "#{@name}-#{@version}"
      push_url = ssh ? "git@github.com:#{head}.git" : "https://github.com/#{head}.git"
      Dir.mktmpdir("clutch-publish-") do |tmp|
        work = File.join(tmp, "index")
        run("git", "clone", "--quiet", "--depth", "1", "https://github.com/#{target}.git", work, what: "could not clone #{target}")
        file = File.join(work, "packages", "#{@name}.toml")
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, text)
        run("git", "-C", work, "checkout", "--quiet", "-b", branch)
        run("git", "-C", work, "add", File.join("packages", "#{@name}.toml"))
        run("git", "-C", work, "commit", "--quiet", "-m", "#{@name} #{@version}", what: "could not commit to the index")
        push = ["git", "-C", work]
        push += ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"] unless ssh
        3.times do |i|
          # A new fork may take a moment to accept pushes.
          _, err, st = Open3.capture3(*push, "push", "--quiet", push_url, "#{branch}:#{branch}")
          break if st.success?
          raise Error, "could not push the branch #{branch} to #{head}: #{err.strip}" if i == 2
          sleep 3
        end
      end
      body = "clutch publish: #{@name} #{@version}\n\nrepo: #{@repo}\nref: #{@sha}\nclutch check: passed\n"
      head_ref = head == target ? branch : "#{head.split("/")[0]}:#{branch}"
      url = run("gh", "pr", "create", "--repo", target, "--head", head_ref, "--title", "#{@name} #{@version}", "--body", body,
                what: "pushed #{branch}, but could not open the pull request")
      "opened #{url} adding #{@name} #{@version}"
    end

    def local_git(*args, what: nil)
      run("git", "-C", @dir, *args, what: what)
    end

    # A command's output, stripped; raises Error with what (or its own
    # error output) when it fails.
    def run(*args, what: nil)
      out, err, st = capture(args)
      return out.strip if st&.success?
      raise Error, what || "#{args.join(" ")} failed: #{err.strip}"
    end

    # A command's output, stripped, or "" when it fails.
    def try(*args)
      out, _, st = capture(args)
      st&.success? ? out.strip : ""
    end

    def capture(args)
      Open3.capture3(*args)
    rescue SystemCallError => e
      ["", e.message, nil]
    end
  end
end
