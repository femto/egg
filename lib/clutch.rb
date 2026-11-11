# clutch: Egg's package manager. It reads clutch.toml, resolves and fetches
# the dependencies (from directories, git repositories and the package
# index), writes clutch.lock, and runs eggc with --pkg NAME=DIR for each.
require_relative "egg/home"
require_relative "egg/version"
require_relative "clutch/toml"
require_relative "clutch/version"
require_relative "clutch/project"
require_relative "clutch/git"
require_relative "clutch/resolve"
require_relative "clutch/publish"
require_relative "clutch/cli"

module Clutch
  # eggc's and clutch's version is one (egg/version.rb).
  VERSION = Egg::VERSION
end
