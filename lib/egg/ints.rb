# Integer literal values. The compiler runs where integers are 64 bits
# (as a native binary built by Spinel), so a literal's value is an Integer
# only while it fits an i64. Above that, from 2**63 to the largest u64, it
# is kept as its decimal digits (a String): it can only be a u64 or a usize,
# and the compiler never computes with it, only checks and prints it.

module Egg
  I64_MAX = 9_223_372_036_854_775_807
  I64_MIN = -I64_MAX - 1
  I64_MAX_TEXT = "9223372036854775807"
  U64_MAX_TEXT = "18446744073709551615"
  # The digits of -i64's minimum, which is a literal only when negated.
  I64_MIN_DIGITS = "9223372036854775808"

  # Do the decimal digits (no sign) stand for at most max_text's value?
  def self.digits_le?(digits, max_text)
    d = digits.sub(/\A0+(?=.)/, "")
    d.length < max_text.length || (d.length == max_text.length && d <= max_text)
  end

  # The value of decimal digits that fit a u64: an Integer if it fits an
  # i64, else the digits themselves.
  def self.int_value(digits)
    d = digits.sub(/\A0+(?=.)/, "")
    digits_le?(d, I64_MAX_TEXT) ? d.to_i : d
  end

  # -v for a literal's value: -9223372036854775808 is i64's minimum; any
  # other big value stays text, which no integer type holds.
  def self.neg_int(v)
    return -v if v.is_a?(Integer)
    v == I64_MIN_DIGITS ? I64_MIN : "-#{v}"
  end

  # Hex or binary digits as decimal digits, worked out a digit at a time so
  # that no value passes 64 bits.
  def self.decimal_digits(digits, base)
    out = [0] # least significant first
    digits.each_char do |c|
      carry = c.to_i(16)
      out.each_index do |i|
        x = out[i] * base + carry
        out[i] = x % 10
        carry = x / 10
      end
      while carry > 0
        out << carry % 10
        carry /= 10
      end
    end
    out.reverse.join.sub(/\A0+(?=.)/, "")
  end
end
