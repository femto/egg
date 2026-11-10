# Versions (MAJOR.MINOR.PATCH, numbers only) and the constraints a
# dependency puts on them:
#
#   "1.2.0"  "= 1.2.0"   exactly 1.2.0
#   ">= 1.2", "> 1.2", "< 2", "<= 2.1"
#   "~> 1.2"             1.2 or newer, below 2.0
#   "~> 1.2.3"           1.2.3 or newer, below 1.3.0
#   "*"                  any version
#   ">= 1.2, < 1.5"      all of them
#
# A constraint may give fewer than three parts; the missing ones are 0.

module Clutch
  class VersionError < StandardError; end

  Version = Struct.new(:parts) do
    include Comparable

    def self.parse(text)
      unless text.is_a?(String) && text.match?(/\A\d+(\.\d+){0,2}\z/)
        raise VersionError, "#{text.inspect} is not a version such as 1.2.0"
      end
      parts = text.split(".").map(&:to_i)
      parts << 0 while parts.length < 3
      new(parts)
    end

    def <=>(other)
      parts <=> other.parts
    end

    def to_s
      parts.join(".")
    end
  end

  class Constraint
    attr_reader :text

    def self.parse(text)
      new(text)
    end

    def initialize(text)
      unless text.is_a?(String)
        raise VersionError, "a version constraint is a string such as \"~> 1.2\", not #{text.inspect}"
      end
      @text = text.strip
      @tests = []
      raise VersionError, "an empty version constraint (\"*\" accepts any version)" if @text.empty?
      return if @text == "*"
      @text.split(",").each do |part|
        m = part.strip.match(/\A(~>|>=|<=|>|<|=)?\s*(\S+)\z/)
        raise VersionError, "#{text.inspect} is not a version constraint such as \"~> 1.2\"" if m.nil?
        op = m[1] || "="
        v = Version.parse(m[2])
        if op == "~>"
          given = m[2].split(".").length
          raise VersionError, "\"~> #{m[2]}\" needs two or three parts, such as \"~> 1.2\"" if given < 2
          upper = v.parts.dup
          upper[given - 2] += 1
          (given - 1...3).each { |i| upper[i] = 0 }
          @tests << [">=", v] << ["<", Version.new(upper)]
        else
          @tests << [op, v]
        end
      end
    end

    def satisfied_by?(v)
      @tests.all? do |op, w|
        case op
        when "=" then v == w
        when ">=" then v >= w
        when "<=" then v <= w
        when ">" then v > w
        when "<" then v < w
        end
      end
    end

    def to_s
      @text
    end
  end
end
