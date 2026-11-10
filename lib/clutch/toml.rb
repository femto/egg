# The part of TOML that clutch.toml, clutch.lock and the index's package
# files use: [table] and [a.b] headers, [[array]] tables, and key = value
# with basic and literal strings, integers, booleans, arrays and inline
# tables. Keys are bare or quoted; dotted keys are not supported.

module Clutch
  class TomlError < StandardError; end

  module Toml
    def self.parse(text, file = "TOML")
      Reader.new(text, file).parse
    end

    # A string as TOML writes it.
    def self.quote(s)
      out = +'"'
      s.each_char do |c|
        out << case c
               when '"' then '\\"'
               when "\\" then "\\\\"
               when "\n" then "\\n"
               when "\t" then "\\t"
               else c.ord < 0x20 ? format("\\u%04X", c.ord) : c
               end
      end
      out << '"'
    end

    class Reader
      def initialize(text, file)
        @s = text
        @file = file
        @i = 0
        @line = 1
        @headers = {}.compare_by_identity   # tables a [header] has defined
      end

      def parse
        root = {}
        table = root
        loop do
          skip_blank_lines
          break if eof?
          if peek == "["
            table = header(root)
          else
            key = read_key
            skip_space
            expect("=")
            skip_space
            if table.key?(key)
              fail "'#{key}' is given twice"
            end
            table[key] = value
          end
          end_of_line
        end
        root
      end

      private

      def header(root)
        array = @s[@i, 2] == "[["
        @i += array ? 2 : 1
        skip_space
        path = [read_key]
        skip_space
        while peek == "."
          @i += 1
          skip_space
          path << read_key
          skip_space
        end
        expect(array ? "]]" : "]")
        t = root
        path[0...-1].each do |k|
          t[k] ||= {}
          t = t[k]
          t = t.last if t.is_a?(Array)
          fail "'#{k}' is not a table" unless t.is_a?(Hash)
        end
        last = path[-1]
        if array
          t[last] ||= []
          fail "'#{last}' is not an array of tables" unless t[last].is_a?(Array)
          t[last] << {}
          t[last].last
        else
          t[last] ||= {}
          fail "'#{last}' is not a table" unless t[last].is_a?(Hash)
          fail "[#{path.join(".")}] is given twice" if @headers.key?(t[last])
          @headers[t[last]] = true
          t[last]
        end
      end

      def value
        c = peek
        case c
        when '"' then basic_string
        when "'" then literal_string
        when "[" then array
        when "{" then inline_table
        else
          word = @s[@i..][/\A[A-Za-z0-9_+\-.]+/]
          fail "expected a value" if word.nil?
          @i += word.length
          case word
          when "true" then true
          when "false" then false
          when /\A[+-]?\d[\d_]*\z/ then word.delete("_").to_i
          else fail "'#{word}' is not a value (a string needs quotes)"
          end
        end
      end

      def basic_string
        @i += 1
        out = +""
        loop do
          fail "unterminated string" if eof? || peek == "\n"
          c = @s[@i]
          @i += 1
          return out if c == '"'
          if c == "\\"
            e = @s[@i]
            @i += 1
            out << case e
                   when '"' then '"'
                   when "\\" then "\\"
                   when "n" then "\n"
                   when "t" then "\t"
                   when "r" then "\r"
                   when "u", "U"
                     n = e == "u" ? 4 : 8
                     hex = @s[@i, n]
                     fail "bad \\#{e} escape" unless hex&.match?(/\A\h{#{n}}\z/)
                     @i += n
                     begin
                       hex.to_i(16).chr(Encoding::UTF_8)
                     rescue RangeError
                       fail "bad \\#{e} escape: #{hex} is not a Unicode scalar value"
                     end
                   else fail "unknown escape \\#{e}"
                   end
          else
            out << c
          end
        end
      end

      def literal_string
        @i += 1
        j = @s.index("'", @i)
        fail "unterminated string" if j.nil? || @s[@i...j].include?("\n")
        out = @s[@i...j]
        @i = j + 1
        out
      end

      def array
        @i += 1
        out = []
        loop do
          skip_blank_lines
          if peek == "]"
            @i += 1
            return out
          end
          out << value
          skip_blank_lines
          if peek == ","
            @i += 1
          elsif peek != "]"
            fail "expected ',' or ']' in an array"
          end
        end
      end

      def inline_table
        @i += 1
        out = {}
        skip_space
        if peek == "}"
          @i += 1
          return out
        end
        loop do
          skip_space
          key = read_key
          skip_space
          expect("=")
          skip_space
          fail "'#{key}' is given twice" if out.key?(key)
          out[key] = value
          skip_space
          if peek == ","
            @i += 1
          elsif peek == "}"
            @i += 1
            return out
          else
            fail "expected ',' or '}' in an inline table"
          end
        end
      end

      def read_key
        case peek
        when '"' then basic_string
        when "'" then literal_string
        else
          k = @s[@i..][/\A[A-Za-z0-9_-]+/]
          fail "expected a key" if k.nil?
          @i += k.length
          k
        end
      end

      def expect(t)
        fail "expected '#{t}'" unless @s[@i, t.length] == t
        @i += t.length
      end

      def end_of_line
        skip_space
        skip_comment
        return if eof?
        fail "expected the end of the line" unless peek == "\n" || peek == "\r"
      end

      def skip_space
        @i += 1 while peek == " " || peek == "\t"
      end

      def skip_comment
        @i += 1 until eof? || peek == "\n" if peek == "#"
      end

      def skip_blank_lines
        loop do
          skip_space
          skip_comment
          if peek == "\n"
            @i += 1
            @line += 1
          elsif peek == "\r" && @s[@i + 1] == "\n"
            @i += 2
            @line += 1
          else
            return
          end
        end
      end

      def peek
        @s[@i]
      end

      def eof?
        @i >= @s.length
      end

      def fail(msg)
        raise TomlError, "#{@file}:#{@line}: #{msg}"
      end
    end
  end
end
