# frozen_string_literal: true

require 'set'
require_relative 'int_range'
require_relative 'numeric_flow'

# RANGE_FLOW (ADR 0286): a forward interval dataflow over one irep, run beside NumericFlow
# (ADR 0276). It answers "if this register holds an Integer, in which [lo, hi]?" at each
# instruction. NumericFlow supplies the classes: an operand whose class set is not
# Integer/Float, or whose operator is not the core body, gets TOP, so a range is never a claim
# about a value a user method computed.
#
# State per instruction, one Array: a range per register and ivar slot; per register the
# variable it still copies (origin), the comparison of two variables it still holds (cond), and
# a "not nil" bit for an element read that cannot miss. A conditional branch narrows the operands
# of the comparison it tests. Loop heads widen (IntRange::THRESHOLDS) after two growth steps and
# two narrowing rounds recover the exit bounds. nil is the empty range (no Integer stored yet).
#
# The oracle (RangeOracle in codegen_range_proof.rb is the program-internal one;
# a record/schema oracle plugs in through the same methods):
#   entry_range(irep, reg)            range of an incoming argument
#   ivar_entry_range(irep, name)      a slot's range on method entry
#   ivar_fact_range(irep, name)       what any callee may leave in a slot
#   const_range(insn)                 GETCONST/GETMCNST
#   upvar_range(irep, insn)           GETUPVAR (a captured local)
#   pool_range(irep, insn)            LOADL
#   return_range(irep, index, insn)   a call to a tracked method name
#   element_range(query)              GETIDX/GETIDX0/first/last/[]/min/max of a container;
#                                     +query+ is a RangeFlow::ElementQuery
#   element_in_bounds?(query)         the read cannot miss (the index is inside the array,
#                                     or the array is not empty for first/last/min/max)
#   op_native?(sym), nil_raises?(sym), core_send_safe?(name, owners)
# Each answers IntRange::TOP (or false) when it proves nothing.
module RangeFlow
  TOP = IntRange::TOP
  NUM = NumericFlow::NUM
  INT = NumericFlow::INT
  FLT = NumericFlow::FLT
  NUMERIC_OWNERS = %w[Integer Float Numeric].freeze
  COND_OPS = { 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=', 'EQ' => '==' }.freeze
  # What an element read asks the oracle. +key_range+ / +key_literal+ describe the
  # index (an Integer range, or a literal Symbol/String/Integer when it is one).
  ElementQuery = Struct.new(:irep, :index, :insn, :recv_reg, :recv_mask, :key_reg, :key_range, :key_mask, :key_literal,
                            :reader, keyword_init: true)

  module_function

  # states(irep, oracle, numeric_states, slots, opaque_regs, writes) -> index -> state
  # (nil for an unreached instruction), or nil when NumericFlow did not model
  # the irep. +writes+, when given, receives per register the join of every range
  # stored into it.
  def states(irep, oracle, numeric_states, slots, opaque_regs, writes = nil)
    return nil unless numeric_states

    program = BytecodeIR.for(irep)
    insns = irep.instructions
    nregs = [irep.nregs.to_i, 1].max
    ctx = { irep: irep, oracle: oracle, numeric: numeric_states, opaque: opaque_regs, nregs: nregs,
            slots: slots, slot_of: slots.each_with_index.to_h { |name, k| [name, nregs + k] },
            n: nregs + slots.size, facts: slots.map { |name| oracle.ivar_fact_range(irep, name) } }
    ctx[:origin_base] = ctx[:n]
    ctx[:cond_base] = ctx[:n] + nregs
    ctx[:nn_base] = ctx[:n] + 2 * nregs
    extra = NumericFlow.enter_edges(irep)
    succ = Array.new(insns.length) { |i| NumericFlow.successors(program, extra, i) }
    preds = Array.new(insns.length) { [] }
    succ.each_with_index { |list, i| list.each { |s| preds[s] << i } }
    back = Set.new
    succ.each_with_index { |list, i| list.each { |s| back << s if s <= i } }

    entry = Array.new(ctx[:n], TOP)
    (1..nregs - 1).each do |r|
      entry[r] = oracle.entry_range(irep, r) unless opaque_regs.include?(r.to_s)
    end
    slots.each_with_index { |name, k| entry[nregs + k] = oracle.ivar_entry_range(irep, name) }
    entry.concat(Array.new(nregs, 0))
    entry.concat(Array.new(nregs, nil))
    entry.concat(Array.new(nregs, false))

    ins = Array.new(insns.length)
    outs = Array.new(insns.length)
    visits = Array.new(insns.length, 0)
    ins[0] = entry
    work = [0]
    queued = Set[0]
    until work.empty?
      i = work.shift
      queued.delete(i)
      out = transfer(i, insns[i], ins[i], ctx, nil)
      next if outs[i] == out

      outs[i] = out
      succ[i].each do |s|
        edge = refine_edge(program, insns[i], i, s, out, ctx)
        next unless edge

        merged = join_state(ins[s], edge, ctx)
        if merged != ins[s] && back.include?(s) && ins[s]
          visits[s] += 1
          merged = widen_state(ins[s], merged, ctx) if visits[s] > 2
        end
        next if merged == ins[s]

        ins[s] = merged
        work << s if queued.add?(s)
      end
    end
    narrow(program, insns, ins, outs, succ, preds, ctx, entry)
    if writes
      ins.each_with_index { |st, i| transfer(i, insns[i], st, ctx, writes) if st }
    end
    ins
  end

  # Decreasing iteration from a post-fixpoint: recompute every in-state as the
  # plain join over its predecessors' out-states. Each round stays sound because
  # the result of one transfer step from a sound state is sound.
  def narrow(program, insns, ins, outs, succ, preds, ctx, entry)
    2.times do
      changed = false
      insns.each_index do |i|
        next unless ins[i]

        incoming = i.zero? ? [entry] : []
        preds[i].each do |p|
          next unless outs[p]

          edge = refine_edge(program, insns[p], p, i, outs[p], ctx)
          incoming << edge if edge
        end
        next if incoming.empty?

        fresh = incoming.reduce(nil) { |acc, st| join_state(acc, st, ctx) }
        fresh = ins[i].each_with_index.map { |old, k| k < ctx[:n] ? (IntRange.meet(old, fresh[k]) || fresh[k]) : fresh[k] }
        next if fresh == ins[i]

        ins[i] = fresh
        outs[i] = transfer(i, insns[i], fresh, ctx, nil)
        changed = true
      end
      break unless changed
    end
  end

  def join_state(old, new, ctx)
    return new.dup if old.nil?

    n = ctx[:n]
    joined = old.each_with_index.map do |m, k|
      if k < n then IntRange.join(m, new[k])
      elsif k < ctx[:cond_base] then m == new[k] ? m : 0
      elsif k < ctx[:nn_base] then m == new[k] ? m : nil
      else m && new[k]
      end
    end
    joined == old ? old : joined
  end

  def widen_state(old, new, ctx)
    n = ctx[:n]
    new.each_with_index.map do |m, k|
      k < n && m != old[k] ? IntRange.widen(old[k], m) : m
    end
  end

  # The state along edge insn -> target: a tested comparison of two variables
  # narrows them; nil when the edge cannot be taken.
  def refine_edge(program, insn, index, target, state, ctx)
    return state unless %w[JMPIF JMPNOT].include?(insn.op)

    goto = program.address_to_index[insn.branch_target]
    fall = index + 1
    return state if goto == fall || (target != goto && target != fall)

    cond = state[ctx[:cond_base] + insn.reg.to_i]
    return state unless cond

    taken = target == goto
    truthy = insn.op == 'JMPIF' ? taken : !taken
    op, lref, rref, lrange, rrange = cond
    op = IntRange::NEGATED.fetch(op) unless truthy
    pair = IntRange.refine(op, lrange, rrange)
    return nil if pair.nil? || pair.any?(&:nil?)

    out = state
    [[lref, pair[0]], [rref, pair[1]]].each do |ref, range|
      next unless ref

      met = IntRange.meet(out[ref], range)
      return nil unless met

      if met != out[ref]
        out = out.dup if out.equal?(state)
        out[ref] = met
      end
    end
    out
  end

  # ---- transfer --------------------------------------------------------------

  def mask_of(ctx, index, reg)
    st = ctx[:numeric][index]
    (st && reg < st.length && st[reg]) || NumericFlow::OTHER
  end

  def numericish?(mask, nil_raises)
    return false unless mask.positive?

    (mask & ~(nil_raises ? (NUM | NumericFlow::NIL) : NUM)).zero?
  end

  def loadi_value(insn)
    case insn.op
    when 'LOADI__1' then -1
    when /\ALOADI_(\d)\z/ then Regexp.last_match(1).to_i
    else insn.imm_operand&.to_i
    end
  end

  # Value of a LOADL pool entry that is an Integer, else nil.
  def pool_integer(entry)
    return nil unless entry.is_a?(Hash)

    case entry[:type]
    when :int32, :int64 then entry[:raw][/=(-?\d+)\z/, 1]&.to_i
    when :bigint
      digits = entry[:digits]
      base = entry[:base].to_i
      return nil unless digits && base.abs.between?(2, 36)

      value = digits.to_i(base.abs)
      base.negative? ? -value : value
    end
  end

  def transfer(index, insn, state, ctx, writes)
    op = insn.op
    if NumericFlow::NO_WRITE_OPS.include?(op)
      # SETIDX writes no register but may call a user #[]=.
      silent = ctx[:numeric][index]
      return state unless op == 'SETIDX' && silent && NumericFlow.silent_call?(insn, silent, ctx)

      out = state.dup
      ctx[:facts].each_with_index do |fact, k|
        out[ctx[:nregs] + k] = IntRange.join(out[ctx[:nregs] + k], fact)
        invalidate_ref(out, ctx[:nregs] + k, ctx)
      end
      return out
    end

    oracle = ctx[:oracle]
    irep = ctx[:irep]
    nregs = ctx[:nregs]
    ob = ctx[:origin_base]
    cb = ctx[:cond_base]
    nnb = ctx[:nn_base]
    if op == 'SETIV'
      slot = ctx[:slot_of][insn.ivar]
      return state unless slot

      out = state.dup
      out[slot] = state[insn.regs.first.to_i]
      invalidate_ref(out, slot, ctx)
      return out
    end

    reg = insn.reg
    a = reg&.to_i
    return state if a.nil? || a >= nregs

    out = state.dup
    set = lambda do |r, range|
      range = TOP if ctx[:opaque].include?(r.to_s)
      out[r] = range
      writes[r] = IntRange.join(writes[r], range) if writes
      invalidate_ref(out, r, ctx)
      out[ob + r] = 0
      out[cb + r] = nil
      out[nnb + r] = false
    end

    if NumericFlow::CALL_OPS.include?(op)
      ctx[:nn] = false
      result = %w[SEND SEND0 SSEND SSEND0].include?(op) ? send_range(index, insn, state, ctx) : TOP
      ((a + 1)...nregs).each { |r| set.call(r, TOP) }
      ctx[:facts].each_with_index do |fact, k|
        out[nregs + k] = IntRange.join(out[nregs + k], fact)
        invalidate_ref(out, nregs + k, ctx)
      end
      set.call(a, result)
      out[nnb + a] = ctx[:nn] && !ctx[:opaque].include?(a.to_s)
      return out
    end

    numeric_mask = ->(r) { mask_of(ctx, index, r) }
    case op
    when /\ALOADI/
      value = loadi_value(insn)
      set.call(a, value ? IntRange.exact(value) : TOP)
    when 'LOADL'
      entry = insn.pool_index && irep.pool[insn.pool_index.to_i]
      value = pool_integer(entry)
      set.call(a, value ? IntRange.exact(value) : oracle.pool_range(irep, insn))
    when 'MOVE'
      src = insn.regs[1].to_i
      range = src < nregs ? state[src] : TOP
      origin = src < nregs ? (state[ob + src].positive? ? state[ob + src] : src + 1) : 0
      set.call(a, range)
      out[ob + a] = origin if origin.positive? && origin - 1 != a && !ctx[:opaque].include?(a.to_s) &&
                              !ctx[:opaque].include?((origin - 1).to_s)
      out[nnb + a] = src < nregs && state[nnb + src] && !ctx[:opaque].include?(a.to_s)
    when 'GETCONST', 'GETMCNST'
      set.call(a, oracle.const_range(insn))
    when 'GETUPVAR'
      set.call(a, oracle.upvar_range(irep, insn))
    when 'GETIV'
      slot = ctx[:slot_of][insn.ivar]
      set.call(a, slot ? state[slot] : TOP)
      out[ob + a] = slot + 1 if slot && !ctx[:opaque].include?(a.to_s)
    when 'ADD', 'SUB', 'MUL', 'DIV'
      b = insn.paren_reg.to_i
      sym = { 'ADD' => '+', 'SUB' => '-', 'MUL' => '*', 'DIV' => '/' }.fetch(op)
      set.call(a, b < nregs ? arith_range(ctx, index, sym, state[a], state[b], numeric_mask.call(a), numeric_mask.call(b)) : TOP)
    when 'ADDI', 'SUBI'
      sym = op == 'ADDI' ? '+' : '-'
      imm = insn.imm_operand&.to_i
      set.call(a, imm ? arith_range(ctx, index, sym, state[a], IntRange.exact(imm), numeric_mask.call(a), INT) : TOP)
    when 'ADDILV', 'SUBILV'
      sym = op == 'ADDILV' ? '+' : '-'
      b = insn.regs[1].to_i
      imm = insn.src_and_literal&.last&.to_i
      result = imm ? arith_range(ctx, index, sym, state[a], IntRange.exact(imm), numeric_mask.call(a), INT) : TOP
      [b, b + 1].each { |r| set.call(r, TOP) if r < nregs }
      set.call(a, result)
    when 'LT', 'LE', 'GT', 'GE', 'EQ'
      compare(ctx, index, insn, a, state, out, set)
    when 'GETIDX', 'GETIDX0'
      ctx[:nn] = false
      set.call(a, element_read(index, insn, state, ctx))
      out[nnb + a] = ctx[:nn] && !ctx[:opaque].include?(a.to_s)
    else
      set.call(a, TOP)
    end
    silent = ctx[:numeric][index]
    if silent && NumericFlow.silent_call?(insn, silent, ctx)
      # Ruby this op may run (see NumericFlow::SILENT_CALL_OPS) can store into any slot.
      ctx[:facts].each_with_index do |fact, k|
        out[nregs + k] = IntRange.join(out[nregs + k], fact)
        invalidate_ref(out, nregs + k, ctx)
      end
    end
    out
  end

  # Kill every origin/cond that mentions +ref+ (a register or slot index).
  def invalidate_ref(out, ref, ctx)
    ob = ctx[:origin_base]
    cb = ctx[:cond_base]
    ctx[:nregs].times do |r|
      out[ob + r] = 0 if out[ob + r] == ref + 1
      cond = out[cb + r]
      out[cb + r] = nil if cond && (cond[1] == ref || cond[2] == ref)
    end
  end

  def arith_range(ctx, index, sym, left, right, lmask, rmask)
    oracle = ctx[:oracle]
    return TOP unless oracle.op_native?(sym)

    nil_raises = oracle.nil_raises?(sym)
    return TOP unless numericish?(lmask, nil_raises) && numericish?(rmask, nil_raises)
    # No Integer on a side (nil) means no Integer result.
    return nil if left.nil? || right.nil?

    case sym
    when '+' then IntRange.add(left, right)
    when '-' then IntRange.sub(left, right)
    when '*' then IntRange.mul(left, right)
    when '/' then IntRange.div(left, right) || TOP
    end
  end

  # `LT Ra`: R[a] = R[a] < R[a+1]. The comparison is remembered only when both
  # operands are exactly Integer, the operator is the core body and the operands
  # still mirror a variable.
  def compare(ctx, index, insn, a, state, out, set)
    b = a + 1
    op = COND_OPS.fetch(insn.op)
    ob = ctx[:origin_base]
    usable = b < ctx[:nregs] && mask_of(ctx, index, a) == INT && mask_of(ctx, index, b) == INT &&
             ctx[:oracle].op_native?(op) && !state[a].nil? && !state[b].nil?
    lref = usable ? origin_ref(state, ob, a) : nil
    rref = usable ? origin_ref(state, ob, b) : nil
    lrange = state[a]
    rrange = usable ? state[b] : TOP
    set.call(a, TOP)
    return unless usable && (lref || rref)

    out[ctx[:cond_base] + a] = [op, lref, rref, lrange, rrange].freeze
  end

  def origin_ref(state, ob, reg)
    o = state[ob + reg]
    o.positive? ? o - 1 : nil
  end

  # ---- sends and element reads --------------------------------------------------

  ARRAY_ELEMENT_READERS = %w[first last at [] fetch min max sample].freeze

  def send_range(index, insn, state, ctx)
    name = insn.sym
    return TOP unless name

    oracle = ctx[:oracle]
    tracked = oracle.return_range(ctx[:irep], index, insn)
    return tracked unless tracked.equal?(TOP)
    return TOP if insn.op.start_with?('SS')

    recv = insn.reg.to_i
    return TOP if recv >= ctx[:nregs]

    argc = insn.op.end_with?('0') ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
    return TOP unless argc

    rmask = mask_of(ctx, index, recv)
    rrange = state[recv]
    arg = ->(k) { recv + 1 + k < ctx[:nregs] ? [state[recv + 1 + k], mask_of(ctx, index, recv + 1 + k)] : [TOP, NumericFlow::OTHER] }
    if rmask == NumericFlow::ARR
      return array_send(index, insn, state, ctx, name, argc)
    end
    return TOP unless numericish?(rmask, false) && oracle.core_send_safe?(name, NUMERIC_OWNERS)

    integer_send(ctx, name, argc, rmask, rrange, arg)
  end

  def integer_send(ctx, name, argc, rmask, rrange, arg)
    return nil if rrange.nil?

    int_only = rmask == INT
    case argc
    when 0
      case name
      when '-@' then IntRange.neg(rrange)
      when '~' then int_only ? IntRange.sub(IntRange.exact(-1), rrange) : TOP
      when 'abs', 'magnitude' then IntRange.abs(rrange)
      when 'succ', 'next' then int_only ? IntRange.add(rrange, IntRange.exact(1)) : TOP
      when 'pred' then int_only ? IntRange.sub(rrange, IntRange.exact(1)) : TOP
      when 'to_i', 'to_int', 'floor', 'ceil', 'round', 'truncate' then int_only ? rrange : TOP
      else TOP
      end
    when 1
      other, omask = arg.call(0)
      return TOP unless numericish?(omask, false)
      return nil if other.nil?

      case name
      when '%', 'modulo' then IntRange.mod(rrange, other) || TOP
      when '&' then omask == INT ? IntRange.band(rrange, other) : TOP
      when '|' then omask == INT ? IntRange.bor(rrange, other) : TOP
      when '^' then omask == INT ? IntRange.bxor(rrange, other) : TOP
      when '<<' then int_only && omask == INT ? IntRange.shl(rrange, other) : TOP
      when '>>' then int_only && omask == INT ? IntRange.shr(rrange, other) : TOP
      when 'div' then int_only && omask == INT ? (IntRange.div(rrange, other) || TOP) : TOP
      when 'min' then TOP
      else TOP
      end
    when 2
      low, lmask = arg.call(0)
      high, hmask = arg.call(1)
      return TOP unless name == 'clamp' && int_only && lmask == INT && hmask == INT
      return nil if low.nil? || high.nil?

      IntRange.clamp(rrange, low, high)
    else TOP
    end
  end

  def array_send(index, insn, state, ctx, name, argc)
    oracle = ctx[:oracle]
    return TOP unless oracle.core_send_safe?(name, %w[Array])

    if %w[size length count].include?(name) && argc.zero?
      return IntRange.make(0, IntRange::ARY_LEN_CAP, true)
    end
    return TOP unless ARRAY_ELEMENT_READERS.include?(name)

    recv = insn.reg.to_i
    key_reg = argc == 1 ? recv + 1 : nil
    indexed = %w[[] at fetch].include?(name)
    return TOP if argc > 1 || (argc == 1 && !indexed) || (argc.zero? && indexed)
    # A Range or other index selects a slice, not an element.
    return TOP if key_reg && (key_reg >= ctx[:nregs] || mask_of(ctx, index, key_reg) != INT)

    query = ElementQuery.new(irep: ctx[:irep], index: index, insn: insn, recv_reg: recv,
                             recv_mask: NumericFlow::ARR, key_reg: key_reg,
                             key_range: key_reg && key_reg < ctx[:nregs] ? state[key_reg] : nil,
                             key_mask: key_reg ? INT : nil, key_literal: nil, reader: name)
    ctx[:nn] = oracle.element_in_bounds?(query)
    oracle.element_range(query)
  end

  def element_read(index, insn, state, ctx)
    a = insn.reg.to_i
    recv, key_reg = insn.op == 'GETIDX' ? [a, a + 1] : [insn.regs[1].to_i, nil]
    return TOP if recv >= ctx[:nregs]

    rmask = mask_of(ctx, index, recv)
    key_range = if insn.op == 'GETIDX0' then IntRange.exact(0)
                elsif key_reg < ctx[:nregs] then state[key_reg]
                end
    key_mask = insn.op == 'GETIDX0' ? INT : (key_reg < ctx[:nregs] ? mask_of(ctx, index, key_reg) : NumericFlow::OTHER)
    query = ElementQuery.new(irep: ctx[:irep], index: index, insn: insn, recv_reg: recv, recv_mask: rmask,
                             key_reg: key_reg, key_range: key_range, key_mask: key_mask, key_literal: nil,
                             reader: '[]')
    # A Range or other index selects a slice of an Array, not an element.
    return TOP if rmask == NumericFlow::ARR && key_mask != INT

    ctx[:nn] = ctx[:oracle].element_in_bounds?(query)
    ctx[:oracle].element_range(query)
  end
end
