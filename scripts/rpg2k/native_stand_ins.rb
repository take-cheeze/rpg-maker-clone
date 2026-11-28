# frozen_string_literal: true

# CRuby stand-ins for mruby-rpg2k's native arithmetic (src/rgss_ext.cxx), for the harnesses that load
# mruby-rpg2k/mrblib under CRuby. They give the native results; mruby-rpg2k/test/test.rb holds the native ones to the
# same cases.
module Game
  INT32_RANGE = (-0x8000_0000..0x7fff_ffff).freeze

  def self.var_op(op, cur, val)
    a = cur.clamp(INT32_RANGE)
    b = val.clamp(INT32_RANGE)
    trunc = ->(n, d) { (n.abs / d.abs) * ((n < 0) == (d < 0) ? 1 : -1) }
    r = case op
        when 0 then b
        when 1 then a + b
        when 2 then a - b
        when 3 then a * b
        when 4 then b.zero? ? a : trunc.(a, b)
        when 5 then b.zero? ? 0 : a - b * trunc.(a, b)
        else a
        end
    r.clamp(INT32_RANGE)
  end

  def self.mul_div(a, b, c)
    raise ZeroDivisionError, 'divided by 0' if c.zero?

    q = a * b / c
    raise RangeError, 'integer overflow in mul_div' unless [a, b, q].all? { |v| INT32_RANGE.cover?(v) }

    q
  end

  # Actor#calc_exp's RPG2000 Float loop as it was in Ruby before it moved to C. scripts/rpg2k/exp_curve_check.rb holds
  # the native to this over every editor input, so it stays the Ruby it was.
  def self.exp_curve(basic, increase, correction_in, n, cap)
    base = basic.to_f
    inflation = 1.5 + increase * 0.01
    correction = correction_in.to_f
    result = 0
    i = 0
    while i < n
      term = correction + base
      return cap if result >= 0 && base >= 0 && correction >= 0 && inflation >= 1 && result + term >= cap

      result += term.to_i
      base *= inflation
      inflation = ((n + 1) * 0.002 + 0.8) * (inflation - 1) + 1
      i += 1
    end
    result > cap ? cap : result
  end
end

# PEEK_ROWS: the harnesses' map events and event pages are Hashes standing in for LCF::Array2D tables, so they answer
# the row peeks Scene::Map and Game::EventPage read them with.
class Hash
  def each_peek(&) = each(&)

  def peek(id) = self[id]
end
