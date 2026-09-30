# frozen_string_literal: true

# INT_RANGE (ADR 0286): the interval domain behind the integer range proof.
#
# A range is the frozen Array [lo, hi, cap] and says "if this value is an
# Integer, lo <= value <= hi". Bounds are exact Integers or +-Float::INFINITY, so
# the maths is that of unbounded Integers (a bigint is an Integer too): nothing
# here assumes a value fits mrb_int or the fixnum range. nil is the empty range
# (no value). A range that is not TOP is only ever a claim about Integers; a
# register that may hold anything else keeps TOP at its source (RangeFlow).
#
# +cap+ marks a range derived from the Array length cap (ARY_LEN_CAP), the one
# target-dependent bound in the domain; a consumer must guard it by the C++
# predicate that states the assumption (see codegen_range_proof.rb).
module IntRange
  INF = Float::INFINITY
  TOP = [-INF, INF, false].freeze

  # Array#size and friends are bounded by mruby's ary_expand_capa/ary_new_capa
  # check `capa > ARY_MAX_SIZE` with ARY_MAX_SIZE = min(SIZE_MAX / sizeof(mrb_value),
  # MRB_INT_MAX - 1); on a 32-bit-pointer target that is at most 2**30 - 1.
  ARY_LEN_CAP = 0x3fff_ffff
  # The narrowest fixnum range of any shipped target: word boxing on a 32-bit
  # mrb_int tags one bit (MRB_FIXNUM_MIN/MAX = INT32_MIN>>1 .. INT32_MAX>>1).
  FIXNUM31_MIN = -0x4000_0000
  FIXNUM31_MAX = 0x3fff_ffff

  # Widening thresholds, ascending. A bound that keeps growing jumps to the next
  # one, then to infinity, so every ascending chain is finite.
  THRESHOLDS = [-0x8000_0000, -0x4000_0001, -0x4000_0000, -0x1_0000, -256, -1, 0, 1, 255, 256, 0xffff, 0x1_0000,
                0x3fff_fffe, 0x3fff_ffff, 0x4000_0000, 0x7fff_ffff, 0x8000_0000].freeze

  module_function

  def make(lo, hi, cap = false)
    return nil if lo > hi

    [lo, hi, cap].freeze
  end

  def exact(value, cap = false) = [value, value, cap].freeze
  def top?(range) = range[0] == -INF && range[1] == INF
  def finite?(range) = range[0] != -INF && range[1] != INF
  def constant?(range) = range[0] == range[1]
  def nonnegative?(range) = range[0] >= 0

  def join(a, b)
    return b if a.nil?
    return a if b.nil?
    return a if a == b

    [[a[0], b[0]].min, [a[1], b[1]].max, a[2] || b[2]].freeze
  end

  def meet(a, b)
    return nil if a.nil? || b.nil?

    make([a[0], b[0]].max, [a[1], b[1]].min, a[2] || b[2])
  end

  def subset?(a, b) = a.nil? || (!b.nil? && a[0] >= b[0] && a[1] <= b[1])

  # Both operands are non-nil in every function below; callers handle bottom.
  def add(a, b) = [a[0] + b[0], a[1] + b[1], a[2] || b[2]].freeze
  def sub(a, b) = [a[0] - b[1], a[1] - b[0], a[2] || b[2]].freeze
  def neg(a) = [-a[1], -a[0], a[2]].freeze

  # 0 * infinity is 0: a bound of 0 stays 0 whatever the other factor is.
  def mul_bound(x, y)
    return 0 if (x.is_a?(Integer) && x.zero?) || (y.is_a?(Integer) && y.zero?)

    x * y
  end

  def mul(a, b)
    products = [mul_bound(a[0], b[0]), mul_bound(a[0], b[1]), mul_bound(a[1], b[0]), mul_bound(a[1], b[1])]
    [products.min, products.max, a[2] || b[2]].freeze
  end

  def abs(a)
    return a if a[0] >= 0
    return neg(a) if a[1] <= 0

    [0, [-a[0], a[1]].max, a[2]].freeze
  end

  def min(a, b) = [[a[0], b[0]].min, [a[1], b[1]].min, a[2] || b[2]].freeze
  def max(a, b) = [[a[0], b[0]].max, [a[1], b[1]].max, a[2] || b[2]].freeze

  # x.clamp(lo, hi) is min(max(x, lo), hi) when lo <= hi (else ArgumentError).
  def clamp(x, lo, hi) = min(max(x, lo), hi)

  # Integer#/ floors. Zero is excluded from the divisor: dividing by it raises
  # ZeroDivisionError, so no value flows from that case. nil when the divisor is
  # exactly zero.
  def div(a, b)
    split_divisor(b).map { |part| div_signed(a, part) }.reduce { |x, y| join(x, y) }
  end

  # The parts of +b+ on either side of zero (zero itself excluded).
  def split_divisor(b)
    parts = []
    parts << make(b[0], [b[1], -1].min, b[2]) if b[0] <= -1
    parts << make([b[0], 1].max, b[1], b[2]) if b[1] >= 1
    parts
  end

  # +b+ is entirely positive or entirely negative.
  def div_signed(a, b)
    corners = [a[0], a[1]].product([b[0], b[1]]).map { |x, y| div_bound(x, y) }
    [corners.min, corners.max, a[2] || b[2]].freeze
  end

  # floor(x / y) for y != 0 as a bound: an infinite bound keeps its magnitude
  # (an over-approximation), an infinite divisor is the limit.
  def div_bound(x, y)
    return(y.positive? ? x : -x) if x.is_a?(Float)
    return(x >= 0 ? 0 : -1) if y == INF
    return(x <= 0 ? 0 : -1) if y == -INF

    x.div(y)
  end

  def top_with(a, b) = [-INF, INF, a[2] || b[2]].freeze

  # Integer#% takes the sign of the divisor. nil when the divisor is exactly 0.
  def mod(a, b)
    split_divisor(b).map { |part| mod_signed(a, part) }.reduce { |x, y| join(x, y) }
  end

  # The cap flag of a bound follows the operand it came from, so `size & 0xff` is not
  # cap-dependent.
  def mod_signed(a, b)
    if b[0] > 0
      hi = b[1] == INF ? INF : b[1] - 1
      return [a[0], a[1], a[2]].freeze if a[0] >= 0 && a[1] < b[0] # every dividend is below every divisor

      return [0, hi, b[2]].freeze unless a[0] >= 0
      return [0, a[1], a[2]].freeze if a[1] < hi

      [0, hi, a[1] == hi ? a[2] || b[2] : b[2]].freeze
    else
      [b[0] == -INF ? -INF : b[0] + 1, 0, b[2]].freeze
    end
  end

  # Smallest k with -2**k <= x <= 2**k - 1 for every x of the range; nil when a
  # bound is infinite.
  def bit_span(a)
    return nil unless finite?(a)

    [a[0].bit_length, a[1].bit_length].max
  end

  def bitwise_hull(a, b)
    k1 = bit_span(a)
    k2 = bit_span(b)
    return top_with(a, b) unless k1 && k2

    k = [k1, k2].max
    [-(1 << k), (1 << k) - 1, a[2] || b[2]].freeze
  end

  def band(a, b)
    if a[0] >= 0 && b[0] >= 0
      cap = if a[1] < b[1] then a[2]
            elsif b[1] < a[1] then b[2]
            else a[2] || b[2]
            end
      [0, [a[1], b[1]].min, cap].freeze
    elsif a[0] >= 0
      [0, a[1], a[2]].freeze
    elsif b[0] >= 0
      [0, b[1], b[2]].freeze
    else
      bitwise_hull(a, b)
    end
  end

  def bor(a, b)
    if a[0] >= 0 && b[0] >= 0 && finite?(a) && finite?(b)
      k = [a[1].bit_length, b[1].bit_length].max
      [[a[0], b[0]].max, (1 << k) - 1, a[2] || b[2]].freeze
    else
      bitwise_hull(a, b)
    end
  end

  def bxor(a, b)
    if a[0] >= 0 && b[0] >= 0 && finite?(a) && finite?(b)
      k = [a[1].bit_length, b[1].bit_length].max
      [0, (1 << k) - 1, a[2] || b[2]].freeze
    else
      bitwise_hull(a, b)
    end
  end

  SHIFT_LIMIT = 512

  # a << n; a negative n is a right shift (Integer#<<). No claim (TOP) for a shift
  # count outside +-SHIFT_LIMIT.
  def shl(a, n)
    return top_with(a, n) unless n[0] >= -SHIFT_LIMIT && n[1] <= SHIFT_LIMIT

    los = []
    his = []
    [n[0], n[1]].each do |k|
      los << shift_bound(a[0], k)
      his << shift_bound(a[1], k)
    end
    [los.min, his.max, a[2] || n[2]].freeze
  end

  def shr(a, n) = shl(a, neg(n))

  def shift_bound(bound, count)
    return bound if bound.is_a?(Float)

    bound << count
  end

  # Widen +new_range+ against +old+ (both non-nil, old <= new).
  def widen(old, new_range)
    return new_range if old.nil?
    return old if new_range.nil?

    lo = new_range[0] < old[0] ? lower_threshold(new_range[0]) : old[0]
    hi = new_range[1] > old[1] ? upper_threshold(new_range[1]) : old[1]
    [lo, hi, old[2] || new_range[2]].freeze
  end

  def lower_threshold(value) = THRESHOLDS.reverse_each.find { |t| t <= value } || -INF
  def upper_threshold(value) = THRESHOLDS.find { |t| t >= value } || INF

  # ---- refinement by a comparison that held: the ranges of `a op b` operands ----

  # Returns [a', b'] (either nil when the comparison cannot hold).
  def refine(op, a, b)
    case op
    when '<' then [meet(a, [-INF, b[1] - 1, b[2]]), meet(b, [a[0] + 1, INF, a[2]])]
    when '<=' then [meet(a, [-INF, b[1], b[2]]), meet(b, [a[0], INF, a[2]])]
    when '>' then [meet(a, [b[0] + 1, INF, b[2]]), meet(b, [-INF, a[1] - 1, a[2]])]
    when '>=' then [meet(a, [b[0], INF, b[2]]), meet(b, [-INF, a[1], a[2]])]
    when '==' then (m = meet(a, b)) && [m, m]
    when '!=' then [exclude(a, b), exclude(b, a)]
    else [a, b]
    end
  end

  NEGATED = { '<' => '>=', '<=' => '>', '>' => '<=', '>=' => '<', '==' => '!=', '!=' => '==' }.freeze

  # +a+ without the single value +b+ when +b+ is exact and at an end of +a+.
  def exclude(a, b)
    return a unless constant?(b)

    v = b[0]
    return a unless v.is_a?(Integer)
    return make(a[0] + 1, a[1], a[2]) if a[0] == v
    return make(a[0], a[1] - 1, a[2]) if a[1] == v

    a
  end

  # ---- consumers ----

  def fits?(range, lo, hi) = range[0] >= lo && range[1] <= hi

  def fixnum31?(range) = !range[2] && fits?(range, FIXNUM31_MIN, FIXNUM31_MAX)

  # C++ integer literal for a finite bound.
  def literal(value) = value.negative? ? "(#{value}LL)" : "#{value}LL"
end
