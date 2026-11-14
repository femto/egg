# The version of Egg's tools: eggc and clutch share it. A release is the
# tag v<VERSION> (the release workflow refuses any other).

require "open3"

module Egg
  VERSION = "0.2.1"

  # VERSION, or VERSION-dev+COMMIT when running from a git checkout that is
  # not the release's tag. A native binary says VERSION: it is built from
  # the tag.
  def self.version_text
    return VERSION if native?
    root = File.expand_path("../..", __dir__)
    return VERSION unless File.exist?(File.join(root, ".git"))
    tag, _, st = Open3.capture3("git", "-C", root, "describe", "--tags", "--exact-match", "HEAD")
    return VERSION if st.success? && tag.strip == "v#{VERSION}"
    sha, _, st = Open3.capture3("git", "-C", root, "rev-parse", "--short", "HEAD")
    st.success? ? "#{VERSION}-dev+#{sha.strip}" : "#{VERSION}-dev"
  rescue SystemCallError
    "#{VERSION}-dev"
  end
end
