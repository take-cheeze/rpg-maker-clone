# frozen_string_literal: true

require_relative 'int_range'
require_relative 'range_flow'

# CodeGen: INTEGER_RANGE_PROOF (ADR 0286).
#
# NUMERIC_OPERAND_PROOF (ADR 0276) says which classes a register may hold; this
# adds "and if it is an Integer, in [lo, hi]" (IntRange, RangeFlow). Whole-program
# range facts are the join of what every visible writer stores, on top of the
# class facts that already enumerate those writers:
#   arguments      pooled over every call site (@entry_arg_numeric's keys)
#   ivars          per (family, name) group (@numeric_ivar_groups, not failed)
#   constants      per name (@numeric_const_groups, not failed)
#   returns        per tracked name (@numeric_return)
#   block params   loop counters (NUMERIC_BLOCK_PARAM_PROOF)
#   array elements per array cell (codegen_range_cells.rb)
# A fact only exists for a key the class proof admitted, so the enumeration
# argument of ADR 0276 is inherited unchanged; a key that is not admitted reads
# TOP. Facts start empty (nil, "no Integer stored yet") and only grow; a fact
# that keeps growing is widened (IntRange::THRESHOLDS), so the fixpoint is finite.
# Any post-fixpoint is sound by induction over the events of one run.
#
# Consumers: range_arith_emit (+ - * drop the overflow tier), range_cmp_emit,
# range_index_class (Array index non-negativity) -- all guarded by
# range_fit_condition, which is exact for the target: the fixnum range shared by
# every shipped target is a compile-time fact, anything wider is decided by the C++
# preprocessor-free constexpr bc2cpp_range_fits(MRB_FIXNUM_MIN/MAX).
class CodeGen
  RANGE_WIDEN_AFTER = 3
  # A range wider than this is never used to drop a check (it cannot fit any
  # fixnum), and is not printed as a C++ literal.
  RANGE_LITERAL_LIMIT = 1 << 62

  # RangeFlow's view of this CodeGen's facts.
  class RangeOracle
    def initialize(codegen)
      @cg = codegen
    end

    def entry_range(irep, reg) = @cg.range_entry_range(irep, reg)
    def ivar_entry_range(irep, name) = @cg.range_ivar_range(irep, name)
    def ivar_fact_range(irep, name) = @cg.range_ivar_range(irep, name)
    def const_range(insn) = @cg.range_const_range(insn)
    def upvar_range(irep, insn) = @cg.range_upvar_range(irep, insn)
    def pool_range(_irep, _insn) = IntRange::TOP
    def return_range(_irep, _index, insn) = @cg.range_return_range(insn)
    def element_range(query) = @cg.range_element_range(query)
    def element_in_bounds?(query) = @cg.range_cell_in_bounds?(query)
    def op_native?(sym) = @cg.numeric_op_native?(sym)
    def nil_raises?(sym) = @cg.numeric_nil_raises?(sym)
    def core_send_safe?(name, owners) = @cg.range_core_send_safe?(name, owners)
  end

  def reset_range_flow!
    @range_states = {}
    @range_writes = {}
    @range_oracle = RangeOracle.new(self)
    @range_core_safe = {}
  end

  # After compute_numeric_facts: the class facts the ranges hang on are final.
  def compute_range_facts
    reset_range_flow!
    @range_proof_ready = false
    @range_bumps = Hash.new(0)
    setup_range_facts
    setup_range_cells
    loop do
      changed = grow_range_args
      changed |= grow_range_ivars
      changed |= grow_range_consts
      changed |= grow_range_returns
      changed |= grow_range_blocks
      changed |= grow_range_cells
      break unless changed
    end
    @range_proof_ready = true
  end

  def setup_range_facts
    @range_arg = {}
    @range_ivar = {}
    @range_const = {}
    @range_return = {}
    @range_block = {}
    (@entry_arg_numeric || {}).each_key { |key| @range_arg[key] = nil }
    (@numeric_ivar_groups || {}).each do |key, group|
      @range_ivar[key] = nil unless group.failed
    end
    (@numeric_const_groups || {}).each do |name, group|
      @range_const[name] = nil unless group.failed
    end
    (@numeric_return || {}).each_key { |name| @range_return[name] = nil }
    (@numeric_block_params || {}).each do |(label, reg), mask|
      next unless mask.anybits?(NumericFlow::INT) && !@numeric_block_failed.include?(label)

      @range_block[[label, reg]] = nil
    end
  end

  # ---- flows --------------------------------------------------------------------

  def range_states_for(irep)
    reset_range_flow! unless @range_states
    return @range_states[irep.label] if @range_states.key?(irep.label)

    numeric = numeric_states_for(irep)
    writes = {}
    @range_writes[irep.label] = writes
    @range_states[irep.label] =
      numeric && RangeFlow.states(irep, @range_oracle, numeric, numeric_ivar_slots(irep),
                                  fixnum_proof_ctx(irep)[:upvars], writes)
  end

  # Forget the range flow of +label+ and every block nested in it (they read its
  # registers through GETUPVAR).
  def range_invalidate(label)
    stack = [label]
    until stack.empty?
      cur = stack.pop
      @range_states.delete(cur)
      @range_writes.delete(cur)
      stack.concat(Array(@ireps[cur]&.reps))
    end
  end

  def range_lookup(table, key)
    table && table.key?(key) ? table[key] : IntRange::TOP
  end

  # ---- the oracle's answers -----------------------------------------------------

  def range_entry_range(irep, reg)
    key = [irep.label, reg.to_i]
    return @range_block[key] if @range_block&.key?(key)

    element = cell_block_param(irep, reg)
    return element.range if element && element.mask.anybits?(NumericFlow::INT)

    owner = numeric_owner_of(irep)
    return IntRange::TOP unless owner && !range_native_fixnum_arg?(irep, reg, owner)

    range_lookup(@range_arg, key)
  end

  # NATIVE_ARG_TARGETS retypes the C++ parameter: natives call it, so the Ruby call
  # sites do not enumerate its callers.
  def range_native_fixnum_arg?(irep, reg, owner)
    return false unless owner.irep == irep.label && pure_mandatory_arity?(irep)

    mand = mandatory_arity(irep)
    r = reg.to_i
    r >= 1 && r <= mand && native_arg_types(owner, mand)[r - 1] == :fixnum
  end

  def range_ivar_range(irep, name)
    return IntRange::TOP if numeric_embedded_fixnum_ivar?(irep, name) && numeric_ivar_group(irep, name).nil?

    group = numeric_ivar_group(irep, name)
    return IntRange::TOP unless group && !group.failed

    range_lookup(@range_ivar, [group.family, group.name])
  end

  def range_const_range(insn)
    group = numeric_const_group(insn)
    group ? range_lookup(@range_const, group.name) : IntRange::TOP
  end

  def range_return_range(insn)
    name = insn.sym
    name && @range_return&.key?(name) ? @range_return[name] : IntRange::TOP
  end

  # A captured local: the defining frame's range at the creating BLOCK joined
  # with every value ever stored into the register (numeric_upvar_mask's argument).
  def range_upvar_range(irep, insn)
    index, level = insn.upvar_ref
    return IntRange::TOP unless index

    cur = irep
    ancestor = nil
    creation = nil
    (level + 1).times do
      link = numeric_block_parents[cur.label]
      return IntRange::TOP unless link

      ancestor, creation = link
      cur = ancestor
    end
    return IntRange::TOP if fixnum_proof_ctx(ancestor)[:upvars].include?(index.to_s)

    states = range_states_for(ancestor)
    state = states && states[creation]
    return IntRange::TOP unless state && index < ancestor.nregs.to_i

    IntRange.join(state[index], (@range_writes[ancestor.label] || {})[index])
  end

  # The Integer/Float bodies of `%`, `&`, `<<`... and Array#size: mruby's own,
  # with no Ruby override or prepend on the receiver's classes.
  def range_core_send_safe?(name, owners)
    @range_core_safe[[name, owners]] = compute_range_core_send_safe(name, owners) unless @range_core_safe.key?([name, owners])
    @range_core_safe[[name, owners]]
  end

  def compute_range_core_send_safe(name, owners)
    return true if builtin_class_send_safe?(name, owners)

    ancestors = owners.include?('Array') ? NUMERIC_ARRAY_ANCESTORS : NUMERIC_INT_ANCESTORS
    numeric_core_method_safe?(name, ancestors + %w[Float])
  end

  # Elements of an array in a tracked cell; TOP unless codegen_range_cells.rb
  # knows every writer of the array that +query+ reads.
  def range_element_range(query)
    range_cell_element_range(query)
  end

  # ---- growth ------------------------------------------------------------------

  # Join +contribution+ into table[key]; true when the fact changed. nil adds nothing.
  def range_join_into(table, key, contribution)
    return false if contribution.nil?

    current = table[key]
    joined = IntRange.join(current, contribution)
    return false if joined == current

    bumps = (@range_bumps[[table.object_id, key]] += 1)
    joined = IntRange.widen(current, joined) if current && bumps > RANGE_WIDEN_AFTER
    table[key] = joined
    true
  end

  # Range of register +reg+ at +idx+ as a value some fact should absorb: nil when no
  # Integer can be there, TOP when the class or the flow is unknown.
  def range_value_at(irep, idx, reg, owner)
    mask = numeric_raw_mask(irep, idx, reg, owner)
    return IntRange::TOP if mask.nil? || mask.anybits?(NumericFlow::OTHER)
    return nil unless mask.anybits?(NumericFlow::INT)

    states = range_states_for(irep)
    return IntRange::TOP unless states

    state = states[idx]
    state ? state[reg.to_i] : nil
  end

  def grow_range_args
    changed = false
    @range_arg.each_key do |key|
      sites, k = @entry_cand[key]
      next unless sites

      sites.each do |(irep, idx, recv, _argc, owner)|
        next unless range_join_into(@range_arg, key, range_value_at(irep, idx, (recv + k).to_s, owner))

        changed = true
        range_invalidate(key[0])
      end
    end
    changed
  end

  def grow_range_ivars
    changed = false
    (@numeric_ivar_groups || {}).each do |key, group|
      next unless @range_ivar.key?(key) && !group.failed

      group.sites.each do |irep, idx, reg|
        next unless range_join_into(@range_ivar, key, range_value_at(irep, idx, reg, numeric_irep_owner[irep.label]))

        changed = true
        group.readers.each { |label| range_invalidate(label) }
      end
    end
    changed
  end

  def grow_range_consts
    changed = false
    (@numeric_const_groups || {}).each do |name, group|
      next unless @range_const.key?(name) && !group.failed

      group.sites.each do |irep, idx, reg|
        next unless range_join_into(@range_const, name, range_value_at(irep, idx, reg, true))

        changed = true
        group.readers.each { |label| range_invalidate(label) }
      end
    end
    changed
  end

  def grow_range_returns
    changed = false
    @range_return.each_key do |name|
      (@registry[name] || []).each do |d|
        next unless range_join_into(@range_return, name, range_return_def(d))

        changed = true
        (@numeric_return_send_ireps[name] || []).each { |label| range_invalidate(label) }
      end
    end
    changed
  end

  def range_return_def(d)
    if d.irep.nil?
      group = @numeric_ivar_groups && @numeric_ivar_groups[[numeric_family(d.owner), d.name]]
      return IntRange::TOP if embed_type(d.owner, d.name) == :fixnum || group.nil? || group.failed

      return @range_ivar[[group.family, group.name]]
    end

    irep = @ireps[d.irep]
    return IntRange::TOP if subtree_has_nonlocal_exit?(irep)

    joined = nil
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[RETURN RETURN_BLK].include?(insn.op)

      joined = IntRange.join(joined, range_value_at(irep, idx, insn.reg, d))
    end
    joined
  end

  # Loop counters: the block's parameter ranges follow from the iterator's receiver
  # and limit at the site (see codegen_numeric_blocks.rb for why the class holds).
  def grow_range_blocks
    changed = false
    @numeric_block_sites.each do |site|
      site_ranges = range_block_site_ranges(site)
      next unless site_ranges

      site_ranges.each do |reg, range|
        key = [site.block, reg]
        next unless @range_block.key?(key)
        next unless range_join_into(@range_block, key, range)

        changed = true
        range_invalidate(site.block)
      end
    end
    changed
  end

  # reg -> range (nil: the loop never runs) for the parameters this site binds.
  def range_block_site_ranges(site)
    owner = numeric_owner_of(site.irep)
    return nil unless owner

    # The receiver counts as its Integer part (a Float receiver has no such
    # iterator); a limit that is not exactly Integer (a Float limit still runs the
    # loop) is unbounded.
    val = ->(reg, idx = site.idx) { range_value_at(site.irep, idx, reg.to_s, owner) }
    strict = lambda do |reg, idx = site.idx|
      mask = numeric_raw_mask(site.irep, idx, reg.to_s, owner)
      next IntRange::TOP if mask.nil?
      next nil if mask.zero?

      mask == NumericFlow::INT ? val.call(reg, idx) : IntRange::TOP
    end
    case site.name
    when 'times'
      n = val.call(site.recv)
      { 1 => n && IntRange.make(0, n[1] - 1, n[2]) }
    when 'upto'
      recv = val.call(site.recv)
      lim = strict.call(site.recv + 1)
      { 1 => recv && lim && IntRange.make(recv[0], lim[1], recv[2] || lim[2]) }
    when 'downto'
      recv = val.call(site.recv)
      lim = strict.call(site.recv + 1)
      { 1 => recv && lim && IntRange.make(lim[0], recv[1], recv[2] || lim[2]) }
    when 'step'
      recv = val.call(site.recv)
      lim = strict.call(site.recv + 1)
      { 1 => recv && lim && IntRange.join(recv, lim) }
    when 'each_index'
      { 1 => IntRange.make(0, IntRange::ARY_LEN_CAP - 1, true) }
    when 'each_with_index'
      { 2 => IntRange.make(0, IntRange::ARY_LEN_CAP - 1, true) }
    when 'each'
      lo = strict.call(site.recv, site.range_idx)
      hi = strict.call(site.recv + 1, site.range_idx)
      exclusive = site.irep.instructions[site.range_idx].op == 'RANGE_EXC'
      return { 1 => nil } unless lo && hi

      { 1 => IntRange.make(lo[0], exclusive ? hi[1] - 1 : hi[1], lo[2] || hi[2]) }
    end
  end

  # ---- queries the emitters use ---------------------------------------------------

  # Range of register +reg+ read by the instruction at +idx+ when the register
  # is exactly an Integer there, else nil (also nil for "no value").
  def range_operand(irep, idx, reg, owner_def)
    return nil unless @range_proof_ready && irep && idx && reg && owner_def

    mask = numeric_raw_mask(irep, idx, reg, owner_def)
    return nil if mask.nil?

    states = range_states_for(irep)
    state = states && states[idx]
    return nil unless state

    # An element read that cannot miss is an Integer although its class set also holds nil.
    unless mask == NumericFlow::INT
      return nil unless mask == (NumericFlow::INT | NumericFlow::NIL) && range_non_nil?(irep, state, reg)
    end
    state[reg.to_i]
  end

  def range_non_nil?(irep, state, reg)
    nregs = [irep.nregs.to_i, 1].max
    state[nregs + numeric_ivar_slots(irep).size + 2 * nregs + reg.to_i] == true
  end

  # How a set of ranges relates to the target's fixnum range: :never, :always (all fit
  # the narrowest shipped target, no assumption) or the C++ constexpr condition.
  def range_fit_condition(ranges)
    return :never if ranges.any?(&:nil?)
    return :never unless ranges.all? { |r| IntRange.finite?(r) && r[0] >= -RANGE_LITERAL_LIMIT && r[1] <= RANGE_LITERAL_LIMIT }

    lo = ranges.map(&:first).min
    hi = ranges.map { |r| r[1] }.max
    cap = ranges.any? { |r| r[2] }
    return :always if !cap && lo >= IntRange::FIXNUM31_MIN && hi <= IntRange::FIXNUM31_MAX

    "bc2cpp_range_fits(#{IntRange.literal(lo)}, #{IntRange.literal(hi)}, #{cap})"
  end

  def range_text(range)
    bound = ->(v) { v == IntRange::INF ? '+inf' : (v == -IntRange::INF ? '-inf' : v.to_s) }
    "[#{bound.call(range[0])}, #{bound.call(range[1])}#{range[2] ? ' (array length cap)' : ''}]"
  end

  RANGE_ARITH = { '+' => :add, '-' => :sub, '*' => :mul }.freeze

  # The arm of an ADD/SUB/MUL(-family) instruction with the overflow tier dropped
  # when both operands are exactly Integer and operands and result fit the fixnum
  # range; +generic+ (the existing arm) otherwise, and as the else of a target
  # condition. +s+ is the right operand register, or nil with the immediate +imm+.
  def range_arith_emit(sym, d, s, imm, irep, idx, owner_def, reg_offset, generic)
    return generic unless RANGE_ARITH.key?(sym) && numeric_op_native?(sym)

    left = range_operand(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
    return generic unless left

    if s
      right = range_operand(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)
      rhs = "mrb_fixnum(r#{s})"
    else
      right = IntRange.exact(imm.to_i)
      rhs = imm
    end
    return generic unless right

    result = IntRange.public_send(RANGE_ARITH.fetch(sym), left, right)
    cond = range_fit_condition([left, right, result])
    return generic if cond == :never

    note = "// RANGE_PROOF #{sym}: #{range_text(left)} #{sym} #{range_text(right)} = #{range_text(result)}, no overflow"
    pure = "r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) #{sym} #{rhs});"
    return "  #{note}\n  #{pure}\n" if cond == :always

    "  #{note}\n  if (#{cond}) {\n    #{pure}\n  } else {\n#{generic}  }\n"
  end

  # `DIV`: both operands exactly Integer and fixnum-sized, so the only arm that can run is
  # mrb_div_int_value (floor division; ZeroDivisionError and MIN / -1 handled inside).
  def range_div_emit(d, s, irep, idx, owner_def, reg_offset, generic)
    return generic unless numeric_op_native?('/')

    left = range_operand(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
    right = left && range_operand(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)
    return generic unless right

    cond = range_fit_condition([left, right])
    return generic if cond == :never

    note = "// RANGE_PROOF /: #{range_text(left)} / #{range_text(right)}, both fixnums"
    pure = "r#{d} = mrb_div_int_value(M, mrb_fixnum(r#{d}), mrb_fixnum(r#{s}));"
    return "  #{note}\n  #{pure}\n" if cond == :always

    "  #{note}\n  if (#{cond}) {\n    #{pure}\n  } else {\n#{generic}  }\n"
  end

  # `LT Ra`-family: a native fixnum comparison when both operands are exactly
  # Integers that fit the fixnum range; nil otherwise.
  def range_cmp_emit(sym, d, s, irep, idx, owner_def, reg_offset, generic)
    return generic unless numeric_op_native?(sym)

    left = range_operand(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
    right = left && range_operand(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)
    return generic unless right

    cond = range_fit_condition([left, right])
    return generic if cond == :never

    note = "// RANGE_PROOF #{sym}: #{range_text(left)} #{sym} #{range_text(right)}, both fixnums"
    pure = "r#{d} = mrb_bool_value(mrb_fixnum(r#{d}) #{sym} mrb_fixnum(r#{s}));"
    return "  #{note}\n  #{pure}\n" if cond == :always

    "  #{note}\n  if (#{cond}) {\n    #{pure}\n  } else {\n#{generic}  }\n"
  end

  # `Array.new(n)` / `Array.new(n, v)` whose size is proven a non-negative fixnum: allocate the
  # Array at its final size and fill it, instead of mrb_obj_new + a dispatched #initialize that
  # grows the buffer element by element. +generic+ is the mrb_obj_new construction, kept as the
  # else of a target condition. Only reached for the exact core Array class (compile_send).
  def range_array_new_emit(d, argv, irep, idx, reg_offset, owner_def, generic)
    return generic unless @range_proof_ready && irep && idx && [1, 2].include?(argv.size) && cell_array_new_safe?

    size_reg = argv[0][/\Ar(\d+)\z/, 1]
    return generic unless size_reg

    r = range_operand(irep, idx, unshift_proof_reg(size_reg, reg_offset), owner_def)
    return generic unless r && r[0].is_a?(Integer) && r[0] >= 0

    cond = range_fit_condition([r])
    return generic if cond == :never

    fill = argv[1] || 'mrb_nil_value()'
    pure = "    mrb_int bc2cpp_ary_n = mrb_fixnum(#{argv[0]});\n" \
           "    r#{d} = mrb_ary_new_capa(M, bc2cpp_ary_n);\n" \
           "    for (mrb_int bc2cpp_ary_i = 0; bc2cpp_ary_i < bc2cpp_ary_n; ++bc2cpp_ary_i) mrb_ary_push(M, r#{d}, #{fill});\n"
    note = "    // RANGE_PROOF Array.new: size #{range_text(r)} is a non-negative fixnum, allocated at its final size\n"
    return "#{note}#{pure}" if cond == :always

    "#{note}    if (#{cond}) {\n#{pure}    } else {\n#{generic}    }\n"
  end

  # An index register proven exactly Integer and >= 0 (so an Array read needs no wrap-around
  # of a negative index): :always, or the C++ condition that must hold (a range derived from
  # the Array length cap needs the pointer-width predicate), else nil.
  def range_nonneg_index(irep, idx, reg, owner_def, reg_offset)
    r = range_operand(irep, idx, unshift_proof_reg(reg, reg_offset), owner_def)
    return nil unless r && r[0].is_a?(Integer) && r[0] >= 0

    r[2] ? 'bc2cpp_range_fits(0LL, 0LL, true)' : :always
  end

  # The C++ expression reading element +index+ of +array+; +nn+ is range_nonneg_index's answer.
  def range_entry_call(nn, array, index)
    plain = "bc2cpp_ary_entry(M, #{array}, #{index})"
    return plain unless nn

    fast = "bc2cpp_ary_entry_nn(M, #{array}, #{index})"
    nn == :always ? fast : "(#{nn} ? #{fast} : #{plain})"
  end

  # NUMERIC_BLOCK_PARAM_PROOF / range diagnostics -------------------------------------

  def range_facts_report
    lines = []
    show = lambda do |kind, label, range|
      next if range.nil? || IntRange.top?(range)

      lines << "  RANGE#{kind} #{label} #{range_text(range)}"
    end
    (@range_arg || {}).each do |(label, k), range|
      d = @owner_of[label]
      show.call('ARG', "#{d ? "#{d.owner}##{d.name}" : "<irep #{label}>"} arg#{k}", range)
    end
    (@range_ivar || {}).each { |(family, name), range| show.call('IVAR', "#{family}#@#{name}", range) }
    (@range_const || {}).each { |name, range| show.call('CONST', name, range) }
    (@range_return || {}).each { |name, range| show.call('RET', name, range) }
    (@range_block || {}).each do |(label, reg), range|
      d = @owner_of[label]
      show.call('BLOCK', "#{d ? "#{d.owner}##{d.name}" : "<irep #{label}>"} block#{label} arg#{reg}", range)
    end
    lines.concat(range_cells_report)
    lines.sort
  end
end

# Feasibility measurement (ADR 0286): how many arithmetic / compare / index sites of the
# closed world get a proven range. Diagnostic only; the emitters never read it.
class CodeGen
  RANGE_COV_ARITH = %w[ADD SUB MUL ADDI SUBI ADDILV SUBILV DIV].freeze
  RANGE_COV_CMP = %w[LT LE GT GE EQ].freeze
  RANGE_COV_INDEX = %w[GETIDX GETIDX0 SETIDX].freeze

  # Operand registers of a site: [[reg, immediate_range_or_nil], ...]. The read
  # container / index of an index site are listed by role.
  def range_site_operands(insn)
    d = insn.reg.to_i
    case insn.op
    when 'ADD', 'SUB', 'MUL', 'DIV', 'LT', 'LE', 'GT', 'GE', 'EQ' then [[d, nil], [insn.paren_reg.to_i, nil]]
    when 'ADDI', 'SUBI' then [[d, nil], [nil, IntRange.exact(insn.imm_operand.to_i)]]
    when 'ADDILV', 'SUBILV' then [[d, nil], [nil, IntRange.exact(insn.src_and_literal.last.to_i)]]
    when 'GETIDX' then [[d + 1, nil]]
    when 'SETIDX' then [[d + 1, nil]]
    when 'GETIDX0' then [[nil, IntRange.exact(0)]]
    end
  end

  def range_coverage_report(sample_every: 1)
    stats = Hash.new(0)
    samples = []
    @ireps.each_value do |irep|
      next if irep.instructions.empty? || CoreDefs.core_source?(irep.file)

      owner = numeric_irep_owner[irep.label]
      next unless owner

      irep.instructions.each_with_index do |insn, idx|
        kind = if RANGE_COV_ARITH.include?(insn.op) then :arith
               elsif RANGE_COV_CMP.include?(insn.op) then :cmp
               elsif RANGE_COV_INDEX.include?(insn.op) then :index
               end
        next unless kind

        stats[[kind, :total]] += 1
        stats[[kind, :cell]] += 1 if kind == :index && cell_read_info(irep, idx)
        ops = range_site_operands(insn)
        next unless ops

        facts = ops.map do |reg, imm|
          if imm
            [NumericFlow::INT, imm]
          else
            [numeric_raw_mask(irep, idx, reg.to_s, owner), range_states_for(irep)&.at(idx)&.at(reg)]
          end
        end
        masks = facts.map(&:first)
        next if masks.any?(&:nil?)

        stats[[kind, :numeric]] += 1 if masks.all? { |m| NumericFlow.numeric?(m) }

        exact_int = masks.all? { |m| m == NumericFlow::INT }
        stats[[kind, :int]] += 1 if exact_int
        next unless exact_int

        ranges = facts.map(&:last)
        bounded = ranges.none?(&:nil?) && ranges.all? { |r| IntRange.finite?(r) }
        nonneg = ranges.none?(&:nil?) && ranges.last[0] >= 0
        stats[[kind, :bounded]] += 1 if bounded
        result = if bounded && kind == :arith && RANGE_ARITH.key?(sym = { 'ADD' => '+', 'SUB' => '-', 'MUL' => '*', 'ADDI' => '+', 'SUBI' => '-', 'ADDILV' => '+', 'SUBILV' => '-' }[insn.op])
                   IntRange.public_send(RANGE_ARITH.fetch(sym), ranges[0], ranges[1])
                 end
        fit = if kind == :index
                nonneg ? :nonneg : nil
              elsif bounded
                cond = range_fit_condition(ranges + [result].compact)
                cond == :always ? :always : (cond == :never ? nil : :target)
              end
        stats[[kind, fit]] += 1 if fit
        next unless fit || bounded

        samples << { file: irep.file, line: insn.lineno, owner: "#{owner.owner}##{owner.name}", op: insn.op, kind: kind,
                     fit: fit, ranges: ranges.map { |r| r && range_text(r) }, result: result && range_text(result) }
      end
    end
    [stats, samples]
  end

  # Lines for the bc2cpp.rb diagnostic: one RANGECOV line per site kind, then up to +limit+
  # sites spread evenly over the proven ones (file:line, method, operand ranges).
  def range_coverage_lines(limit = 80)
    stats, samples = range_coverage_report
    lines = []
    %i[arith cmp index].each do |kind|
      lines << "  RANGECOV #{kind} total=#{stats[[kind, :total]]} numeric=#{stats[[kind, :numeric]]} " \
               "exact_int=#{stats[[kind, :int]]} bounded=#{stats[[kind, :bounded]]} " \
               "fits_always=#{stats[[kind, :always]]} fits_target=#{stats[[kind, :target]]} " \
               "nonneg=#{stats[[kind, :nonneg]]} tracked_array_reads=#{stats[[kind, :cell]]}"
    end
    step = [samples.size / [limit, 1].max, 1].max
    samples.each_slice(step).map(&:first).first(limit).each do |s|
      lines << "  RANGESITE #{s[:file].to_s.sub(%r{\A.*/(mruby-[^/]+/)}, '\\1')}:#{s[:line]} " \
               "#{s[:owner]} #{s[:op]} #{s[:kind]} #{s[:fit].inspect} #{s[:ranges].join(' , ')}#{s[:result] ? " => #{s[:result]}" : ''}"
    end
    lines
  end
end
