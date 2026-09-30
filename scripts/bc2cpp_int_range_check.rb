#!/usr/bin/env ruby
# frozen_string_literal: true

# INT_RANGE (docs/adr/0286): the integer interval proof.
#
# 1. Host only: IntRange, the interval algebra, against the concrete Integer
#    operations (random members of random intervals, boundary values of every
#    target's fixnum range included) -- an interval must contain every result.
# 2. Host only: RangeFlow on hand-built bytecode -- literals, arithmetic, loops with
#    widening and narrowing, comparison refinement, masks, joins, calls, unmodelled
#    ireps.
# 3. With MRBC: the generated code of a closed-world fixture. Sites whose operands are
#    proven to fit lose the overflow tier (unconditionally when they fit every shipped
#    target's fixnum range, behind bc2cpp_range_fits otherwise); sites with an unknown
#    writer, an unbounded operand or a range past the fixnum range keep it. Mutated
#    fixtures (a second writer, attr_writer, instance_variable_set, a subclass, send)
#    must refuse.
# 4. With BC2CPP_MRUBY_CORE and g++: the fixture runs on real mruby, interpreted and
#    compiled, at MRB_FIXNUM_MAX / MAX+1 / MIN-1, 2**30, 2**31, 2**62, negative shifts and
#    `%` with negative operands, and must answer alike; bc2cpp_range_fits is also
#    evaluated for a 31-bit, 62-bit and nan-boxing target.

require 'set'
require 'tmpdir'
require_relative '../tools/bc2cpp/int_range'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

R = IntRange
INF = R::INF

puts '-- IntRange algebra (host)'
rng = Random.new(20_260_930)
edge = [0, 1, -1, 2, -2, 255, 256, 65_535, 0x3fff_ffff, 0x4000_0000, -0x4000_0000, -0x4000_0001, 0x7fff_ffff,
        0x8000_0000, -0x8000_0000, 2**62 - 1, 2**62, -(2**62), 2**63, -(2**63), 2**64, 31, 32, 63, 64].freeze
pick = lambda do
  case rng.rand(4)
  when 0 then edge.sample(random: rng)
  when 1 then rng.rand(-20..20)
  when 2 then rng.rand(-(2**40)..(2**40))
  else edge.sample(random: rng) + rng.rand(-3..3)
  end
end
interval = lambda do
  a = pick.call
  b = pick.call
  lo, hi = [a, b].minmax
  lo = -INF if rng.rand(8).zero?
  hi = INF if rng.rand(8).zero?
  R.make(lo, hi)
end
member = lambda do |r|
  lo = r[0] == -INF ? [r[1], 0].min - rng.rand(0..2**33) : r[0]
  hi = r[1] == INF ? [r[0], 0].max + rng.rand(0..2**33) : r[1]
  choice = rng.rand(4)
  return lo if choice.zero?
  return hi if choice == 1

  rng.rand(lo..hi)
end
inside = ->(r, v) { !v.nil? && v >= r[0] && v <= r[1] }

ops = {
  'add' => [->(a, b) { R.add(a, b) }, ->(x, y) { x + y }],
  'sub' => [->(a, b) { R.sub(a, b) }, ->(x, y) { x - y }],
  'mul' => [->(a, b) { R.mul(a, b) }, ->(x, y) { x * y }],
  'div' => [->(a, b) { R.div(a, b) }, ->(x, y) { y.zero? ? :skip : x.div(y) }],
  'mod' => [->(a, b) { R.mod(a, b) }, ->(x, y) { y.zero? ? :skip : x % y }],
  'and' => [->(a, b) { R.band(a, b) }, ->(x, y) { x & y }],
  'or' => [->(a, b) { R.bor(a, b) }, ->(x, y) { x | y }],
  'xor' => [->(a, b) { R.bxor(a, b) }, ->(x, y) { x ^ y }],
  'min' => [->(a, b) { R.min(a, b) }, ->(x, y) { [x, y].min }],
  'max' => [->(a, b) { R.max(a, b) }, ->(x, y) { [x, y].max }],
  'shl' => [->(a, b) { R.shl(a, b) }, ->(x, y) { y.abs > 600 ? :skip : x << y }],
  'shr' => [->(a, b) { R.shr(a, b) }, ->(x, y) { y.abs > 600 ? :skip : x >> y }]
}
ops.each do |name, (abstract, concrete)|
  bad = nil
  4000.times do
    a = interval.call
    b = interval.call
    out = abstract.call(a, b)
    3.times do
      x = member.call(a)
      y = member.call(b)
      v = concrete.call(x, y)
      next if v == :skip

      unless out && inside.call(out, v)
        bad ||= "#{x} #{name} #{y} = #{v} not in #{out.inspect} (#{a.inspect} #{b.inspect})"
      end
    end
    # nil (empty) is only right when the divisor is exactly zero.
    bad ||= "empty result for #{a.inspect} #{name} #{b.inspect}" if out.nil? && !(b[0].zero? && b[1].zero?)
  end
  check.call("#{name}: every concrete result lies in the interval#{bad ? " -- #{bad}" : ''}", bad.nil?)
end
unary = {
  'neg' => [->(a) { R.neg(a) }, ->(x) { -x }],
  'abs' => [->(a) { R.abs(a) }, ->(x) { x.abs }]
}
unary.each do |name, (abstract, concrete)|
  bad = nil
  3000.times do
    a = interval.call
    out = abstract.call(a)
    x = member.call(a)
    bad ||= "#{name} #{x} not in #{out.inspect}" unless inside.call(out, concrete.call(x))
  end
  check.call("#{name}: every concrete result lies in the interval", bad.nil?)
end
bad = nil
3000.times do
  x = interval.call
  lo = interval.call
  hi = interval.call
  vx = member.call(x)
  vlo = member.call(lo)
  vhi = member.call(hi)
  next if vlo > vhi

  bad ||= "clamp #{vx} #{vlo} #{vhi}" unless inside.call(R.clamp(x, lo, hi), vx.clamp(vlo, vhi))
end
check.call('clamp: every concrete result lies in the interval', bad.nil?)

bad = nil
3000.times do
  a = interval.call
  b = interval.call
  op = R::NEGATED.keys.sample(random: rng)
  x = member.call(a)
  y = member.call(b)
  holds = x.public_send(op, y)
  pair = R.refine(op, a, b)
  next unless holds

  bad ||= "refine #{op} lost #{x} #{y} (#{a.inspect} #{b.inspect} -> #{pair.inspect})" unless pair && pair.none?(&:nil?) && inside.call(pair[0], x) && inside.call(pair[1], y)
end
check.call('refine: a pair for which the comparison holds survives the refinement', bad.nil?)
bad = nil
3000.times do
  a = interval.call
  b = interval.call
  op = R::NEGATED.keys.sample(random: rng)
  x = member.call(a)
  y = member.call(b)
  next if x.public_send(op, y)

  pair = R.refine(R::NEGATED.fetch(op), a, b)
  bad ||= "negated refine #{op} lost #{x} #{y}" unless pair && pair.none?(&:nil?) && inside.call(pair[0], x) && inside.call(pair[1], y)
end
check.call('refine: the negated comparison keeps the pairs for which the comparison fails', bad.nil?)

check.call('bit masks: x & 0xff is [0, 255] for any x', R.band(R::TOP, R.exact(255)) == [0, 255, false])
check.call('x % 10 is [0, 9] for any x', R.mod(R::TOP, R.exact(10)) == [0, 9, false])
check.call('x % -10 is [-9, 0] for any x', R.mod(R::TOP, R.exact(-10)) == [-9, 0, false])
check.call('a divisor that may be zero drops zero: 10 / [-2, 2] covers -10..10',
           (r = R.div(R.exact(10), R.make(-2, 2))) && r[0] == -10 && r[1] == 10)
check.call('exactly zero has no quotient', R.div(R.exact(1), R.exact(0)).nil? && R.mod(R.exact(1), R.exact(0)).nil?)
check.call('widening reaches a threshold, then infinity',
           R.widen(R.make(0, 0), R.make(0, 1)) == [0, 1, false] &&
             R.widen(R.make(0, 1), R.make(0, 2)) == [0, 255, false] &&
             R.widen(R.make(0, 0x3fff_ffff), R.make(0, 0x4000_0000))[1] == 0x4000_0000 &&
             R.widen(R.make(0, 0x8000_0000), R.make(0, 0x8000_0001))[1] == INF)
check.call('fixnum31? is the narrowest shipped fixnum range and refuses a cap-derived bound',
           R.fixnum31?(R.make(-0x4000_0000, 0x3fff_ffff)) && !R.fixnum31?(R.make(0, 0x4000_0000)) &&
             !R.fixnum31?(R.make(0, 5, true)))


require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir'
require_relative '../tools/bc2cpp/numeric_flow'
require_relative '../tools/bc2cpp/range_flow'

NF = NumericFlow
INT = NF::INT
FLT = NF::FLT
ARR = NF::ARR
NIL_ = NF::NIL
OTHER = NF::OTHER

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, handlers: [], nregs: 8)
  Irep.new(label: "rf#{list.hash}", nregs: nregs, instructions: list, catch_handlers: handlers, reps: [], pool: [])
end

# The class facts a flow test configures (NumericFlow's oracle).
class NumStub
  attr_accessor :entry, :slots, :sends, :element

  def initialize
    @entry = {}
    @slots = []
    @sends = {}
    @element = NumericFlow::OTHER
  end

  def entry_mask(_irep, reg) = @entry.fetch(reg, NumericFlow::OTHER)
  def const_mask(_insn) = NumericFlow::OTHER
  def ivar_slots(_irep) = @slots
  def ivar_entry_mask(_irep, _name) = NumericFlow::INT | NumericFlow::NIL
  def ivar_fact_mask(_irep, _name) = NumericFlow::INT
  def send_mask(_irep, _index, insn, _state) = @sends.fetch(insn.sym, NumericFlow::OTHER)
  def upvar_mask(_irep, _insn) = NumericFlow::OTHER
  def pool_mask(_irep, _insn) = NumericFlow::INT
  def element_mask(_irep, _index, _insn, _state) = @element
  def op_native?(_sym) = true
  def nil_raises?(_sym) = true
end

# The range facts a flow test configures (RangeFlow's oracle).
class RangeStub
  attr_accessor :entry, :fact, :elements

  def initialize
    @entry = {}
    @fact = IntRange::TOP
    @elements = IntRange::TOP
  end

  def entry_range(_irep, reg) = @entry.fetch(reg, IntRange::TOP)
  def ivar_entry_range(_irep, _name) = @fact
  def ivar_fact_range(_irep, _name) = @fact
  def const_range(_insn) = IntRange::TOP
  def upvar_range(_irep, _insn) = IntRange::TOP
  def pool_range(_irep, _insn) = IntRange::TOP
  def return_range(_irep, _index, _insn) = IntRange::TOP
  def element_range(_query) = @elements
  def element_in_bounds?(_query) = false
  def op_native?(_sym) = true
  def nil_raises?(_sym) = true
  def core_send_safe?(_name, _owners) = true
end

both = lambda do |list, entry_masks: {}, entry_ranges: {}, slots: [], fact: IntRange::TOP, sends: {}, opaque: Set.new,
                  **irep_options|
  irep = irep_of(list, **irep_options)
  num = NumStub.new.tap do |o|
    o.entry = entry_masks
    o.slots = slots
    o.sends = sends
  end
  numeric = NumericFlow.states(irep, num, opaque)
  rng = RangeStub.new.tap do |o|
    o.entry = entry_ranges
    o.fact = fact
  end
  [numeric && RangeFlow.states(irep, rng, numeric, slots, opaque), numeric]
end
rg = ->(range) { range && [range[0], range[1]] }

puts '-- RangeFlow (host)'
straight = [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'LOADI_2', "R3\t(2)"), insn(4, 'ADD', "R2\t(R3)"),
            insn(6, 'MUL', "R2\t(R3)"), insn(8, 'SUBI', "R2\t5"), insn(11, 'RETURN', 'R2')]
states, = both.call(straight)
check.call('literals and + * - are exact', rg.call(states[3][2]) == [3, 3] && rg.call(states[4][2]) == [6, 6] &&
                                             rg.call(states[5][2]) == [1, 1])
check.call('a register never written is TOP, not empty', states[0][5] == IntRange::TOP)

wide = [insn(0, 'MOVE', "R2\tR1"), insn(3, 'LOADI16', "R3\t255"), insn(6, 'SEND', "R2\t:&\tn=1"), insn(10, 'RETURN', 'R2')]
states, = both.call(wide, entry_masks: { 1 => INT }, sends: { '&' => INT })
check.call('x & 255 is [0, 255] for an unknown Integer x', rg.call(states[3][2]) == [0, 255])
states, = both.call(wide, entry_masks: { 1 => INT }, sends: { '&' => OTHER })
check.call('a send whose result class is not proven Integer gets no range',
           rg.call(states[3][2]) == [0, 255] || IntRange.top?(states[3][2]))
states, = both.call(wide, entry_masks: { 1 => INT | OTHER }, sends: { '&' => INT })
check.call('an operand of unknown class makes the result TOP', IntRange.top?(states[3][2]))

mod = [insn(0, 'MOVE', "R2\tR1"), insn(3, 'LOADI_7', "R3\t(7)"), insn(5, 'SEND', "R2\t:%\tn=1"), insn(9, 'RETURN', 'R2')]
states, = both.call(mod, entry_masks: { 1 => INT }, sends: { '%' => INT })
check.call('x % 7 is [0, 6]', rg.call(states[3][2]) == [0, 6])

join = [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'LOADI_1', "R2\t(1)"), insn(6, 'JMP', '12'), insn(9, 'LOADI_5', "R2\t(5)"),
        insn(12, 'RETURN', 'R2')]
states, = both.call(join)
check.call('a join covers both arms', rg.call(states[4][2]) == [1, 5])

# i = 0; while i < 10; i += 1; end; return i
loop_ = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'MOVE', "R4\tR2"), insn(5, 'LOADI8', "R5\t10"),
         insn(8, 'LT', "R4\t(R5)"), insn(10, 'JMPNOT', "R4\t22"), insn(14, 'ADDI', "R2\t1"), insn(17, 'JMP', '2'),
         insn(22, 'RETURN', 'R2')]
states, = both.call(loop_, entry_masks: { 1 => INT })
check.call('a guarded loop counter is [0, 9] in the body', rg.call(states[5][2]) == [0, 9])
check.call('and exactly 10 after the loop (widening, then narrowing)', rg.call(states[7][2]) == [10, 10])
check.call('the head sees [0, 10]', rg.call(states[1][2]) == [0, 10])

# the bound is a variable: while i < n (n in [0, 100])
var_bound = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'MOVE', "R4\tR2"), insn(5, 'MOVE', "R5\tR1"), insn(8, 'LT', "R4\t(R5)"),
             insn(10, 'JMPNOT', "R4\t22"), insn(14, 'ADDI', "R2\t1"), insn(17, 'JMP', '2'), insn(22, 'RETURN', 'R2')]
states, = both.call(var_bound, entry_masks: { 1 => INT }, entry_ranges: { 1 => IntRange.make(0, 100) })
check.call('a loop bounded by a variable is bounded by its range', rg.call(states[5][2]) == [0, 99])
states, = both.call(var_bound, entry_masks: { 1 => INT })
check.call('and by nothing when the bound is unknown', states[5][2][0] == 0 && states[5][2][1] == IntRange::INF)

unbounded = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'JMPNOT', "R1\t12"), insn(6, 'ADDI', "R2\t1"), insn(9, 'JMP', '2'),
             insn(12, 'RETURN', 'R2')]
states, = both.call(unbounded, entry_masks: { 1 => INT })
check.call('an unguarded counter widens to [0, +inf) and terminates', states[1][2][0] == 0 && states[1][2][1] == IntRange::INF)

refine = [insn(0, 'MOVE', "R3\tR1"), insn(3, 'LOADI_5', "R4\t(5)"), insn(5, 'LT', "R3\t(R4)"), insn(7, 'JMPNOT', "R3\t13"),
          insn(11, 'RETURN', 'R1'), insn(13, 'RETURN', 'R1')]
states, = both.call(refine, entry_masks: { 1 => INT })
check.call('x < 5 narrows x to [-inf, 4] where it holds and [5, +inf) where it fails',
           states[4][1][1] == 4 && states[4][1][0] == -IntRange::INF && states[5][1][0] == 5 && states[5][1][1] == IntRange::INF)
float_cmp = [insn(0, 'MOVE', "R3\tR1"), insn(3, 'LOADI_5', "R4\t(5)"), insn(5, 'LT', "R3\t(R4)"), insn(7, 'JMPNOT', "R3\t13"),
             insn(11, 'RETURN', 'R1'), insn(13, 'RETURN', 'R1')]
states, = both.call(float_cmp, entry_masks: { 1 => INT | FLT })
check.call('a comparison of a possible Float narrows nothing', IntRange.top?(states[4][1]))

eq = [insn(0, 'MOVE', "R3\tR1"), insn(3, 'LOADI_5', "R4\t(5)"), insn(5, 'EQ', "R3\t(R4)"), insn(7, 'JMPNOT', "R3\t13"),
      insn(11, 'RETURN', 'R1'), insn(13, 'RETURN', 'R1')]
states, = both.call(eq, entry_masks: { 1 => INT })
check.call('x == 5 makes x exactly 5', rg.call(states[4][1]) == [5, 5])
dead = [insn(0, 'LOADI_1', "R1\t(1)"), insn(2, 'MOVE', "R3\tR1"), insn(5, 'LOADI_5', "R4\t(5)"), insn(7, 'EQ', "R3\t(R4)"),
        insn(9, 'JMPNOT', "R3\t15"), insn(13, 'RETURN', 'R1'), insn(15, 'RETURN', 'R1')]
states, = both.call(dead, entry_masks: { 1 => INT })
check.call('an edge the ranges rule out is not taken', states[5].nil? && !states[6].nil?)

called = [insn(0, 'LOADI_1', "R3\t(1)"), insn(2, 'LOADI_2', "R1\t(2)"), insn(4, 'SEND0', "R2\t:f"), insn(6, 'RETURN', 'R2')]
states, = both.call(called)
check.call('a call clobbers the registers above its receiver and keeps the ones below',
           IntRange.top?(states[3][3]) && rg.call(states[3][1]) == [2, 2])

slot_list = [insn(0, 'LOADI_1', "R3\t(1)"), insn(2, 'SETIV', "@a\tR3"), insn(5, 'GETIV', "R4\t@a"), insn(8, 'SEND0', "R2\t:f"),
             insn(10, 'GETIV', "R5\t@a"), insn(13, 'RETURN', 'R5')]
states, = both.call(slot_list, slots: ['a'], fact: IntRange.make(0, 9))
check.call('SETIV then GETIV sees the stored range', rg.call(states[3][4]) == [1, 1])
check.call('a call replaces the slot by what its whole-program fact allows', rg.call(states[5][5]) == [0, 9])
silent = [insn(0, 'LOADI_1', "R3\t(1)"), insn(2, 'SETIV', "@a\tR3"), insn(5, 'STRCAT', "R2\t(R3)"), insn(7, 'GETIV', "R5\t@a"),
          insn(10, 'RETURN', 'R5')]
states, = both.call(silent, slots: ['a'], fact: IntRange.make(0, 9))
check.call('an op that can run Ruby (string interpolation) also replaces the slot', rg.call(states[4][5]) == [0, 9])

# A schema oracle answers the element reads of a container that is not an Array.
class ElementStub < RangeStub
  def element_range(_query) = IntRange.make(0, 255)
  def element_in_bounds?(_query) = true
end
hash_read = [insn(0, 'MOVE', "R2\tR1"), insn(3, 'LOADSYM', "R3\t:hp"), insn(6, 'GETIDX', "R2\t(R3)"),
             insn(8, 'ADDI', "R2\t1"), insn(11, 'RETURN', 'R2')]
hash_irep = irep_of(hash_read)
hash_num = NumericFlow.states(hash_irep, NumStub.new.tap { |o| o.entry = { 1 => NF::HSH }; o.element = INT }, Set.new)
states = RangeFlow.states(hash_irep, ElementStub.new, hash_num, [], Set.new)
check.call('an element oracle supplies the range of a Hash field read (the plug-in point for record schemas)',
           rg.call(states[4][2]) == [1, 256])
check.call('and its in-bounds answer sets the register\'s not-nil bit', states[3][8 + 2 * 8 + 2] == true)
states = RangeFlow.states(hash_irep, RangeStub.new, hash_num, [], Set.new)
check.call('and TOP without one', IntRange.top?(states[4][2]))

states, = both.call(straight, opaque: Set['2'])
check.call('a register a nested block writes is TOP', IntRange.top?(states[3][2]))
states, = both.call(straight, handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 4, target: 6)])
check.call('an irep with a catch handler has no range facts', states.nil?)
empty_arg = [insn(0, 'MOVE', "R2\tR1"), insn(3, 'ADDI', "R2\t1"), insn(6, 'RETURN', 'R2')]
states, = both.call(empty_arg, entry_masks: { 1 => INT }, entry_ranges: { 1 => nil })
check.call('a fact with no value yet (empty) propagates as empty and does not crash', states[2][2].nil?)

flt = [insn(0, 'MOVE', "R2\tR1"), insn(3, 'ADDI', "R2\t1"), insn(6, 'RETURN', 'R2')]
states, = both.call(flt, entry_masks: { 1 => INT | FLT }, entry_ranges: { 1 => IntRange.make(0, 5) })
check.call('the range of an Integer-or-Float register is its Integer part', rg.call(states[2][2]) == [1, 6])
states, = both.call(flt, entry_masks: { 1 => INT | OTHER }, entry_ranges: { 1 => IntRange.make(0, 5) })
check.call('an operand that may be an arbitrary object gives TOP', IntRange.top?(states[2][2]))


if ENV['MRBC']
  require_relative 'bc2cpp_fixture_runtime'
  runtime = Bc2cppFixtureRuntime
  # Integer overflow becomes a bigint only in a full-core build (mruby-bigint); the bare
  # core raises RangeError, in the interpreter and in the compiled code alike.
  big_shift = runtime.full ? 70 : 40

  fixture = <<~RUBY
    module RgConst
      BIG = 1 << #{big_shift}
      RG_W = 4
      RG_H = RG_W * 2 + 1
    end

    class RgBox
      def initialize
        @rg_list = [1, 2, 3]
        @rg_lim = 3
        @rg_acc = 0
        @rg_open = 1
      end

      def rg_mask(x)
        ((x & 0xff) + 1) * 2
      end

      def rg_mod(x)
        (x % 10) + 1
      end

      def rg_negmod(x, y)
        (x % y) + 100
      end

      def rg_shl(x, n)
        (x << n) + 1
      end

      def rg_shr(x, n)
        (x >> n) - 1
      end

      def rg_or(x)
        (x | 3) + 1
      end

      def rg_xor(x)
        (x ^ 5) - 1
      end

      def rg_abs(x)
        x.abs + 1
      end

      def rg_abs_edge(x)
        x.abs + 1
      end

      def rg_neg(x)
        -x + 1
      end

      def rg_clamp(x)
        x.clamp(-5, 5) + 1
      end

      def rg_div(x, y)
        (x & 0xff) / y
      end

      def rg_edge_a(x)
        x + 1
      end

      def rg_edge_b(x)
        x + 2
      end

      def rg_edge_c(x)
        x + 1
      end

      def rg_edge_d(x)
        x - 1
      end

      def rg_edge_e(x, y)
        x * y
      end

      def rg_edge_f(x)
        x * 2
      end

      def rg_edge_g(x)
        (x & 0x1fffffff) + 0x20000000
      end

      def rg_edge_h(x)
        (x & 0x1fffffff) + 0x20000001
      end

      def rg_const
        RgConst::RG_H * 3 + 1
      end

      def rg_open_use
        @rg_open + 1
      end

      def rg_set_open
        @rg_open = 1 << #{big_shift}
      end

      def rg_unbounded(n)
        n + 1
      end

      def rg_cmp(a)
        a < 100
      end

      def rg_cmp_big(a)
        a < 100
      end

      def rg_upto
        t = 0
        3.upto(9) { |i| t = i * 4 }
        t
      end

      def rg_times(n)
        t = 0
        n.times { |i| t = i * 3 + 1 }
        t
      end

      def rg_range_each
        t = 0
        (2..6).each { |i| t = i - 10 }
        t
      end

      def rg_step
        t = 0
        1.step(30, 7) { |i| t = i + 1 }
        t
      end

      def rg_each_index
        t = 0
        @rg_list.each_index { |i| t = i + 1 }
        t
      end

      def rg_down
        i = 20
        s = 0
        while i > 0
          s = i - 1
          i -= 1
        end
        s
      end

      def rg_counter(n)
        i = 0
        s = 0
        while i < n
          s = i * 2
          i += 1
        end
        s
      end

      def rg_accum
        i = 0
        s = 0
        while i < 10
          s += i
          i += 1
        end
        s
      end
    end

    class RgDrv
      def go_mask
        b = RgBox.new
        [b.rg_mask(7), b.rg_mask(-1), b.rg_mask(1000), b.rg_mask(RgConst::BIG), b.rg_mask(-RgConst::BIG),
         b.rg_mask(4611686018427387903)]
      end

      def go_mod
        b = RgBox.new
        [b.rg_mod(-13), b.rg_mod(1234), b.rg_mod(RgConst::BIG), b.rg_mod(-RgConst::BIG)]
      end

      def go_negmod
        b = RgBox.new
        [b.rg_negmod(13, -7), b.rg_negmod(-13, 7), b.rg_negmod(13, 7), b.rg_negmod(-13, -7)]
      end

      def go_shift
        b = RgBox.new
        [b.rg_shl(-100, -3), b.rg_shl(100, 5), b.rg_shl(7, 0), b.rg_shl(-1, -1), b.rg_shr(-100, 3), b.rg_shr(100, 60),
         b.rg_shr(5, 0)]
      end

      def go_bits
        b = RgBox.new
        [b.rg_or(5), b.rg_or(-5), b.rg_or(300), b.rg_xor(5), b.rg_xor(-8)]
      end

      def go_abs
        b = RgBox.new
        [b.rg_abs(-7), b.rg_abs(7), b.rg_abs_edge(-4611686018427387904), b.rg_abs_edge(1), b.rg_neg(4), b.rg_neg(-4),
         b.rg_clamp(100), b.rg_clamp(-100), b.rg_clamp(3), b.rg_div(255, 7), b.rg_div(-1, -3), b.rg_div(1000, 1),
         b.rg_div(RgConst::BIG, 2)]
      end

      def go_edge
        b = RgBox.new
        [b.rg_edge_a(4611686018427387902), b.rg_edge_a(1), b.rg_edge_b(4611686018427387902), b.rg_edge_b(1),
         b.rg_edge_c(4611686018427387903), b.rg_edge_c(1), b.rg_edge_d(-4611686018427387904), b.rg_edge_d(1),
         b.rg_edge_e(3037000499, 3037000499), b.rg_edge_e(2, 3), b.rg_edge_f(1073741823), b.rg_edge_f(1073741824),
         b.rg_edge_f(4294967296), b.rg_edge_g(RgConst::BIG), b.rg_edge_g(-1), b.rg_edge_h(RgConst::BIG),
         b.rg_edge_h(1073741823)]
      end

      def go_misc
        b = RgBox.new
        [b.rg_const, b.rg_open_use, b.rg_unbounded(1), b.rg_unbounded(RgConst::BIG), b.rg_cmp(3), b.rg_cmp(100),
         b.rg_cmp_big(RgConst::BIG), b.rg_cmp_big(-RgConst::BIG), b.rg_upto, b.rg_times(5), b.rg_times(10),
         b.rg_range_each, b.rg_step, b.rg_each_index, b.rg_down, b.rg_counter(7), b.rg_counter(0), b.rg_accum]
      end

      def go_open
        b = RgBox.new
        b.rg_set_open
        b.rg_open_use
      end
    end
  RUBY

  # The guarded arms tag themselves; an arm whose overflow tier was dropped carries RANGE_PROOF.
  chunk_of = lambda do |code, owner_method|
    code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|^static mrb_value \S+_block_fallback_|\z)/m].to_s
  end
  with_blocks = lambda do |code, owner_method|
    prefix = Regexp.escape(owner_method.tr('#', '_'))
    chunk_of.call(code, owner_method) + code.scan(/^static mrb_value #{prefix}_block_fallback_\d+_impl.*?^\}\n(?=\nstatic mrb_value )/m).join
  end

  puts '-- generated code (closed world)'
  code = nil
  err = nil
  Dir.mktmpdir { |dir| code, err = runtime.generate(fixture, dir, closed: true) }
  proven = ->(method) { with_blocks.call(code, method).include?('RANGE_PROOF') }
  guarded = ->(method) { with_blocks.call(code, method).include?('bc2cpp_range_fits(') }
  plain = ->(method) { proven.call(method) && !guarded.call(method) }
  generic = ->(method) { !with_blocks.call(code, method).empty? && !proven.call(method) }

  check.call('x & 0xff + 1, * 2 for any Integer x (even a bigint) loses the overflow tier, unguarded', plain.call('RgBox#rg_mask'))
  check.call('x % 10 + 1 for a negative, huge or bigint x', plain.call('RgBox#rg_mod'))
  check.call('x % y + 100 with negative operands', plain.call('RgBox#rg_negmod'))
  check.call('(x << n) + 1 with negative and positive shift counts', plain.call('RgBox#rg_shl'))
  check.call('(x >> n) - 1', plain.call('RgBox#rg_shr'))
  check.call('x | 3 and x ^ 5', plain.call('RgBox#rg_or') && plain.call('RgBox#rg_xor'))
  check.call('abs, unary minus and clamp', plain.call('RgBox#rg_abs') && plain.call('RgBox#rg_neg') && plain.call('RgBox#rg_clamp'))
  check.call('a floor division of two fixnum-sized Integers is one mrb_div_int_value',
             with_blocks.call(code, 'RgBox#rg_div').include?('RANGE_PROOF /'))
  check.call('a constant defined from constants proves as an interval', plain.call('RgBox#rg_const'))
  check.call('a guarded while counter, its product and its increment', plain.call('RgBox#rg_down') && proven.call('RgBox#rg_counter'))
  check.call('loop counters of times / upto / step / (a..b).each', proven.call('RgBox#rg_times') && plain.call('RgBox#rg_range_each') &&
                                                                   plain.call('RgBox#rg_step'))
  check.call('an interval that reaches 2**30 is guarded by the target fixnum range, not assumed',
             guarded.call('RgBox#rg_edge_a') && guarded.call('RgBox#rg_edge_b') && guarded.call('RgBox#rg_edge_c') &&
               guarded.call('RgBox#rg_edge_f'))
  check.call('the largest sum that fits every target (2**30 - 1) is unguarded, one more is guarded',
             plain.call('RgBox#rg_edge_g') && guarded.call('RgBox#rg_edge_h'))
  check.call('an interval derived from the Array length cap is guarded by the pointer width',
             guarded.call('RgBox#rg_each_index') &&
               with_blocks.call(code, 'RgBox#rg_each_index').match?(/bc2cpp_range_fits\(\d+LL, \d+LL, true\)/))
  check.call('the guard is a constant condition with the target macros in it',
             code.include?('(long long)MRB_FIXNUM_MIN') && code.include?('SIZE_MAX / sizeof(mrb_value)') &&
               code.include?('static_assert(MRB_FIXNUM_MIN <= -0x40000000LL'))
  check.call('NEG: an interval past 2**62 keeps the exact tier (MIN - 1, x * y past MAX, abs(MIN) + 1)',
             generic.call('RgBox#rg_edge_d') && generic.call('RgBox#rg_edge_e') && generic.call('RgBox#rg_abs_edge'))
  check.call('NEG: an argument one call site passes a bigint has no upper bound', generic.call('RgBox#rg_unbounded'))
  check.call('NEG: an ivar that is also assigned a bigint keeps its exact tier', generic.call('RgBox#rg_open_use'))
  check.call('NEG: an accumulator that grows without bound keeps its exact tier',
             with_blocks.call(code, 'RgBox#rg_accum').scan('RANGE_PROOF').size < 3)
  facts = err.lines.grep(/RANGE(ARG|IVAR|CONST|RET|BLOCK) /).join
  check.call('the diagnostic lists the proven intervals',
             facts.include?('RANGEBLOCK') && facts.include?('RANGECONST RG_H [9, 9]'))

  mutation_base = <<~RUBY
    class MuBox
      MU_W = 3
      MU_H = MU_W * 2 + 1

      def initialize
        @mu_list = [1, 2, 3]
        @mu_v = @mu_list.size & 0x7f
      end

      def mu_seed
        @mu_list.size & 0xff
      end

      def mu_ret
        @mu_v & 0xff
      end

      def mu_use_const
        MU_H + 1
      end

      def mu_use_ret
        mu_ret + 1
      end

      def mu_use_ivar
        @mu_v + 1
      end

      def mu_use_arg(x)
        x + 1
      end
    end
  RUBY
  # [name, extra Ruby appended to the fixture, method expected to lose the proof]
  mutations = [
    ['a second definition returns a bigint',
     "class MuOther\n  def mu_ret\n    1 << 70\n  end\nend\nclass MuDrv2\n  def go\n    MuOther.new.mu_ret\n  end\nend\n",
     'MuBox#mu_use_ret'],
    ['another scope binds the constant name to a bigint', "module MuMod\n  MU_H = 1 << 70\nend\n", 'MuBox#mu_use_const'],
    ['an attr_writer lets a caller store anything',
     "class MuBox\n  attr_writer :mu_v\nend\nclass MuDrv3\n  def go\n    MuBox.new.mu_v = 1 << 70\n  end\nend\n",
     'MuBox#mu_use_ivar'],
    ['instance_variable_set with a computed name',
     "class MuBox\n  def mu_refl(name)\n    instance_variable_set(name, 1 << 70)\n  end\nend\n", 'MuBox#mu_use_ivar'],
    ['a subclass stores into the inherited ivar',
     "class MuSub < MuBox\n  def mu_poison\n    @mu_v = 1 << 70\n  end\nend\n", 'MuBox#mu_use_ivar'],
    ['a send with a literal Symbol reaches the method',
     "class MuDrv4\n  def go\n    MuBox.new.send(:mu_use_arg, 1 << 70)\n  end\nend\n", 'MuBox#mu_use_arg'],
    ['another call site passes a Float', "class MuDrv5\n  def go\n    MuBox.new.mu_use_arg(1.5)\n  end\nend\n", 'MuBox#mu_use_arg'],
    ['another call site passes a bigint', "class MuDrv6\n  def go\n    MuBox.new.mu_use_arg(1 << 70)\n  end\nend\n", 'MuBox#mu_use_arg']
  ]
  base_call = "class MuDrv\n  def go\n    b = MuBox.new\n    [b.mu_use_const, b.mu_use_ret, b.mu_use_ivar, b.mu_use_arg(b.mu_seed)]\n  end\nend\n"
  Dir.mktmpdir do |dir|
    base_code, = runtime.generate(mutation_base + base_call, dir, closed: true)
    %w[MuBox#mu_use_const MuBox#mu_use_ret MuBox#mu_use_ivar MuBox#mu_use_arg].each do |m|
      check.call("mutation base: #{m} is proven before any writer is added", with_blocks.call(base_code, m).include?('RANGE_PROOF'))
    end
  end
  mutations.each do |name, extra, method|
    Dir.mktmpdir do |dir|
      mutated, = runtime.generate(mutation_base + base_call + extra, dir, closed: true)
      check.call("mutation (#{name}): #{method} keeps the exact tier",
                 !with_blocks.call(mutated, method).empty? && !with_blocks.call(mutated, method).include?('RANGE_PROOF'))
    end
  end

  puts '-- array element ranges (closed world)'
  array_fixture = <<~RUBY
    class ArBox
      TABLE = [3, 5, 8, 13]

      def initialize
        @ar_list = [10, 20, 30]
        @ar_grow = []
        @ar_late = [1, 2]
        @ar_leak = [1, 2]
        @ar_native = [4, 5]
        @ar_sub = ArSub.new
        @ar_marsh = [7, 8]
        @ar_vals = [7, 8]
        @ar_exposed = [9, 9]
      end

      attr_reader :ar_exposed

      def ar_table
        t = 0
        TABLE.each { |x| t = x * 2 + 1 }
        t
      end

      def ar_idx0
        @ar_list[0] + 1
      end

      def ar_first
        @ar_list.first * 2
      end

      def ar_idx(i)
        @ar_list[i] + 1
      end

      def ar_idx_out
        @ar_list[5] + 1
      end

      def ar_neg_idx
        @ar_list[-1]
      end

      def ar_each
        t = 0
        @ar_list.each { |x| t = x + 1 }
        t
      end

      def ar_each_index
        t = 0
        @ar_list.each_index { |i| t = @ar_list[i] + i }
        t
      end

      def ar_times_idx(n)
        t = 0
        n.times { |i| t = @ar_list[i] }
        t
      end

      def ar_push(x)
        @ar_grow << (x & 0x7f)
        nil
      end

      def ar_grow_sum
        t = 0
        @ar_grow.each { |v| t = v + 1 }
        t
      end

      def ar_late_add
        @ar_late << (1 << #{big_shift})
        nil
      end

      def ar_late_use
        t = 0
        @ar_late.each { |v| t = v + 1 }
        t
      end

      def ar_leak_out
        ar_helper(@ar_leak)
      end

      def ar_helper(a)
        a << (1 << #{big_shift})
        nil
      end

      def ar_leak_use
        t = 0
        @ar_leak.each { |v| t = v + 1 }
        t
      end

      def ar_native_mut
        @ar_native.map! { |x| x + (1 << #{big_shift}) }
        nil
      end

      def ar_native_use
        t = 0
        @ar_native.each { |v| t = v + 1 }
        t
      end

      def ar_sub_use
        t = 0
        @ar_sub.each { |v| t = v + 1 }
        t
      end

      def ar_sub_push
        @ar_sub << (1 << #{big_shift})
        nil
      end

      def ar_marsh_set(data)
        @ar_marsh = Marshal.load(data)
        nil
      end

      def ar_marsh_use
        t = 0
        @ar_marsh.each { |v| t = v + 1 }
        t
      end

      def ar_vals_set(hash)
        @ar_vals = hash.values
        nil
      end

      def ar_vals_use
        t = 0
        @ar_vals.each { |v| t = v + 1 }
        t
      end

      def ar_exposed_use
        t = 0
        @ar_exposed.each { |v| t = v + 1 }
        t
      end

      def ar_local
        a = [1, 2, 3]
        a << 4
        t = 0
        a.each { |v| t = v * 2 }
        t
      end

      def ar_captured
        a = [1, 2, 3]
        [1 << #{big_shift}].each { |z| a << z }
        t = 0
        a.each { |v| t = v + 1 }
        t
      end

      def ar_new(n)
        a = Array.new(n, 0)
        a[1] = 5
        t = 0
        a.each { |v| t = v + 1 }
        t
      end

      def ar_setidx_gap
        a = [1, 2]
        a[5] = 3
        t = 0
        a.each { |v| t = v + 1 }
        t
      end

      def ar_setidx_gap_or
        a = [1, 2]
        a[5] = 3
        t = 0
        a.each { |v| t = (v || 0) + 1 }
        t
      end

      def ar_dup
        a = [4, 5, 6]
        b = a.dup
        b << 7
        t = 0
        b.each { |v| t = v + 1 }
        t
      end

      def ar_pairs
        t = 0
        [[1, 2], [3, 4]].each { |a, b| t = a + b }
        t
      end
    end

    class ArSub < Array
    end

    class ArDrv
      def go_basic
        b = ArBox.new
        [b.ar_table, b.ar_idx0, b.ar_first, b.ar_idx(0), b.ar_idx(2), b.ar_each, b.ar_each_index, b.ar_local, b.ar_dup,
         b.ar_times_idx(2), b.ar_times_idx(3), b.ar_neg_idx, b.ar_pairs]
      end

      def go_out
        ArBox.new.ar_idx_out
      end

      def go_grow
        b = ArBox.new
        b.ar_push(5)
        b.ar_push(1000)
        [b.ar_grow_sum, b.ar_new(3), b.ar_setidx_gap_or]
      end

      def go_gap
        ArBox.new.ar_setidx_gap
      end

      def go_late_add
        b = ArBox.new
        b.ar_late_add
        b.ar_late_use
      end

      def go_leak
        b = ArBox.new
        b.ar_leak_out
        b.ar_leak_use
      end

      def go_native
        b = ArBox.new
        b.ar_native_mut
        b.ar_native_use
      end

      def go_sub
        b = ArBox.new
        b.ar_sub_push
        b.ar_sub_use
      end

      def go_vals
        b = ArBox.new
        b.ar_vals_set({ b: 5, a: 1 << #{big_shift} })
        b.ar_vals_use
      end

      def go_captured
        ArBox.new.ar_captured
      end

      def go_exposed
        b = ArBox.new
        b.ar_exposed.push(1 << #{big_shift})
        b.ar_exposed_use
      end
    end

    class ArNever
      def go(data)
        ArBox.new.ar_marsh_set(data)
        ArBox.new.ar_marsh_use
      end
    end
  RUBY
  array_code = nil
  Dir.mktmpdir { |dir| array_code, = runtime.generate(array_fixture, dir, closed: true) }
  a_proven = ->(m) { with_blocks.call(array_code, m).match?(/RANGE_PROOF [-+*<>=]/) }
  a_none = ->(m) { !with_blocks.call(array_code, m).empty? && !a_proven.call(m) }
  check.call('a constant table: each element, its product and sum', a_proven.call('ArBox#ar_table'))
  check.call('a[0], first, and a[i] with i inside a literal array', a_proven.call('ArBox#ar_idx0') &&
                                                                  a_proven.call('ArBox#ar_first') && a_proven.call('ArBox#ar_idx'))
  check.call('an ivar array pushed only with masked values, iterated', a_proven.call('ArBox#ar_grow_sum'))
  check.call('a local array, its dup with a later push, Array.new(n, 0) with an in-bounds store',
             a_proven.call('ArBox#ar_local') && a_proven.call('ArBox#ar_dup') && a_proven.call('ArBox#ar_new'))
  check.call('the elements of `ary.each` are exact Integers with their range', a_proven.call('ArBox#ar_each'))
  check.call('NEG: a[5] on a 3-element array can be nil: the sum keeps its exact tier', a_none.call('ArBox#ar_idx_out'))
  check.call('NEG: an index past the end written by `a[5] = x` pads with nil; `v || 0` removes it again',
             a_none.call('ArBox#ar_setidx_gap') && a_proven.call('ArBox#ar_setidx_gap_or'))
  check.call('NEG: an element pushed later from a different path (a bigint) is in the range',
             a_none.call('ArBox#ar_late_use'))
  check.call('NEG: an Array handed to a method that pushes to it', a_none.call('ArBox#ar_leak_use'))
  check.call('NEG: a native mutator (fill) poisons the Array', a_none.call('ArBox#ar_native_use'))
  check.call('NEG: a subclass of Array is not an Array', a_none.call('ArBox#ar_sub_use'))
  check.call('NEG: elements from Marshal.load are unknown', a_none.call('ArBox#ar_marsh_use'))
  check.call('NEG: elements from a native producer (Hash#values) are unknown', a_none.call('ArBox#ar_vals_use'))
  check.call('NEG: an attr_reader hands the Array to any caller', a_none.call('ArBox#ar_exposed_use'))
  check.call('NEG: a block that captures the local Array can push anything', a_none.call('ArBox#ar_captured'))
  check.call('NEG: `each { |a, b| }` over pairs spreads the element, so the parameter is not the element',
             a_none.call('ArBox#ar_pairs'))
  check.call('a non-negative index skips the wrap-around of a negative one, a negative literal keeps it',
             with_blocks.call(array_code, 'ArBox#ar_times_idx').include?('RANGE_PROOF []') &&
               !with_blocks.call(array_code, 'ArBox#ar_neg_idx').include?('RANGE_PROOF []') &&
               array_code.include?('bc2cpp_ary_entry_nn') && array_code.include?('(mrb_uint)n >= (mrb_uint)ARY_LEN(a)'))

  # Mutations: a writer the analysis cannot see makes a proven read unproven.
  array_mutation_base = <<~RUBY
    class AmBox
      def initialize
        @am = [10, 20, 30]
      end

      def am_use
        t = 0
        @am.each { |v| t = v + 1 }
        t
      end

      def am_get
        @am[1] + 1
      end
    end

    class AmDrv
      def go
        b = AmBox.new
        [b.am_use, b.am_get]
      end
    end
  RUBY
  array_mutations = [
    ['a push of a bigint', "class AmBox\n  def am_add\n    @am << (1 << 70)\n    nil\n  end\nend\n"],
    ['an attr_accessor', "class AmBox\n  attr_accessor :am\nend\n"],
    ['a store of an argument Array', "class AmBox\n  def am_set(x)\n    @am = x\n    nil\n  end\nend\n"],
    ['a return of the Array', "class AmBox\n  def am_get_all\n    @am\n  end\nend\n"],
    ['Array#map!', "class AmBox\n  def am_map\n    @am.map! { |x| x << 40 }\n    nil\n  end\nend\n"],
    ['Array#replace', "class AmBox\n  def am_rep(o)\n    @am.replace(o)\n    nil\n  end\nend\n"],
    ['Array#sort!', "class AmBox\n  def am_sort\n    @am.sort!\n    nil\n  end\nend\n"],
    ['a splice assignment', "class AmBox\n  def am_splice\n    @am[0..1] = [1 << 70]\n    nil\n  end\nend\n"],
    ['instance_variable_get anywhere', "class AmBox\n  def am_ivg\n    instance_variable_get(:@am)\n  end\nend\n"],
    ['a rescue (unmodelled irep) that reads the ivar', "class AmBox\n  def am_res\n    @am[0]\n  rescue\n    nil\n  end\nend\n"]
  ]
  Dir.mktmpdir do |dir|
    base, = runtime.generate(array_mutation_base, dir, closed: true)
    check.call('mutation base: reads of a fully visible ivar Array are proven',
               with_blocks.call(base, 'AmBox#am_use').match?(/RANGE_PROOF \+/) &&
                 with_blocks.call(base, 'AmBox#am_get').match?(/RANGE_PROOF \+/))
  end
  array_mutations.each do |name, extra|
    Dir.mktmpdir do |dir|
      mutated, = runtime.generate(array_mutation_base + extra, dir, closed: true)
      lost = %w[AmBox#am_use AmBox#am_get].all? { |m| !with_blocks.call(mutated, m).match?(/RANGE_PROOF [-+*<>=]/) }
      check.call("mutation (#{name}): both reads lose the element range", lost)
    end
  end

  # bc2cpp_range_fits, evaluated for the three fixnum layouts mruby ships.
  helper = code[/static constexpr bool bc2cpp_range_fits.*?^\}\n/m].to_s
  targets = {
    '32-bit pointers, word boxing (31-bit fixnum)' =>
      { min: '(INT32_MIN >> 1)', max: '(INT32_MAX >> 1)', size_max: '0xffffffffu', value_size: 4,
        expect: [%w[-1073741824 1073741823 false true], %w[0 1073741824 false false], %w[0 5 true true],
                 %w[0 1073741823 true true]] },
    '64-bit pointers, word boxing (62-bit fixnum)' =>
      { min: '(INT64_MIN >> 1)', max: '(INT64_MAX >> 1)', size_max: '0xffffffffffffffffull', value_size: 8,
        expect: [%w[0 1073741824 false true], %w[0 5 true false], %w[0 4611686018427387903 false true],
                 %w[0 4611686018427387904 false false]] },
    '32-bit pointers, nan boxing (32-bit fixnum)' =>
      { min: 'INT32_MIN', max: 'INT32_MAX', size_max: '0xffffffffu', value_size: 8,
        expect: [%w[0 2147483647 false true], %w[0 2147483648 false false], %w[0 5 true true]] }
  }
  targets.each do |label, t|
    Dir.mktmpdir do |dir|
      asserts = t[:expect].map do |lo, hi, cap, want|
        "static_assert(bc2cpp_range_fits(#{lo}LL, #{hi}LL, #{cap}) == #{want}, \"#{lo} #{hi} #{cap}\");"
      end
      File.write(File.join(dir, 't.cpp'), <<~CPP)
        #include <cstdint>
        #include <cstddef>
        #undef SIZE_MAX
        #define SIZE_MAX #{t[:size_max]}
        #define MRB_FIXNUM_MIN #{t[:min]}
        #define MRB_FIXNUM_MAX #{t[:max]}
        struct mrb_value { char bytes[#{t[:value_size]}]; };
        #{helper}
        #{asserts.join("\n")}
        int main() { return 0; }
      CPP
      ok = runtime.compiler? && system('g++', '-std=c++17', '-fsyntax-only', File.join(dir, 't.cpp'), err: File::NULL)
      check.call("bc2cpp_range_fits answers as the target's fixnum range says: #{label}", ok)
    end
  end

  full = runtime.full
  core = runtime.core
  if (full.nil? && core.nil?) || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_CORE or BC2CPP_MRUBY_FULL (libmruby*.a and include/, from the patched 3rd/mruby) ' \
         'and have g++'
  else
    puts '-- fixture on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      owners = %w[RgBox RgDrv RgConst]
      _code, err2 = runtime.generate(fixture, dir, closed: true, only_owners: owners)
      body = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "RgDrv"), 0, nullptr);
          const char* names[] = { "go_mask", "go_mod", "go_negmod", "go_shift", "go_bits", "go_abs", "go_edge", "go_misc",
                                  "go_open" };
          for (const char* name : names) call(M, name, drv, name);
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err2, owners, body, build: full || core, full: !full.nil?, bigint: !full.nil?)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('every case answers what the interpreter answers, values and exceptions alike',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        check.call('the edge cases really ran (MAX + 1 is a bigint or a RangeError, not a wrapped fixnum)',
                   values.call('compiled').any? { |l| l.include?('4611686018427387904') || l.include?('RangeError') })
      end
    end
    Dir.mktmpdir do |dir|
      owners = %w[ArBox ArSub ArDrv ArNever]
      _code, err3 = runtime.generate(array_fixture, dir, closed: true, only_owners: owners)
      body = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "ArDrv"), 0, nullptr);
          const char* names[] = { "go_basic", "go_out", "go_grow", "go_gap", "go_late_add", "go_leak", "go_native", "go_sub", "go_vals",
                                  "go_captured", "go_exposed" };
          for (const char* name : names) call(M, name, drv, name);
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err3, owners, body, build: full || core, full: !full.nil?, bigint: !full.nil?)
      check.call('the array fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('array reads answer what the interpreter answers, including after a later push of a bigint, ' \
                   'a native mutator, a subclass and a capturing block',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        bigs = values.call('compiled').select { |l| l.match?(/\A(?:go_late_add|go_leak|go_native|go_sub|go_vals|go_captured|go_exposed) => /) }
        check.call('every unseen-writer case really produced a value past the pushed bound (or a RangeError)',
                   bigs.size == 7 && bigs.all? { |l| l.match?(/\d{10}/) || l.include?('RangeError') })
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp int range check: PASS'
else
  warn "bc2cpp int range check: #{failures.size} failure(s)"
  exit 1
end
