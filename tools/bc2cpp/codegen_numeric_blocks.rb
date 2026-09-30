# frozen_string_literal: true

require_relative 'numeric_flow'

# CodeGen: NUMERIC_BLOCK_PARAM_PROOF (ADR 0286).
#
# The counter of a literal-block loop over mruby's own iterators is an Integer:
# `n.times { |i| }`, `a.upto(b) { |i| }`, `a.downto(b)`, `a.step(limit, by)` on
# Integer operands, `ary.each_index { |i| }`, `ary.each_with_index { |x, i| }` and
# `(a..b).each { |i| }` on Integer endpoints. The block irep's parameter register is
# then INT on entry, which is what lets NumericFlow (and RangeFlow) see `i + 1` and
# `a[i]` inside the loop. The class set joins the numeric fixpoint (compute_numeric_facts).
#
# Why sound: the block is a literal (`BLOCK` immediately before the `SENDB`, the
# shape mrbc emits), so the only code that ever yields to it is that iterator.
# The iterator is mruby's own Ruby (mrblib/numeric.rb, array.rb, enum.rb) or range.c,
# established by numeric_core_method_safe? (no non-core definition of the name on the
# receiver's ancestors, no prepend), and its counter starts from an Integer and
# advances by Integer#+ / #- (numeric_op_native?), so it stays Integer whatever the
# limit argument is. A receiver whose class set is not exactly what the iterator
# needs fails the fact for good (mask OTHER), like every numeric fact.
class CodeGen
  NumericBlockSite = Struct.new(:irep, :idx, :block, :name, :argc, :recv, :range_idx, keyword_init: true)

  NUMERIC_INT_ANCESTORS = %w[Integer Numeric Comparable Kernel Object BasicObject].freeze
  NUMERIC_ARRAY_ANCESTORS = %w[Array Enumerable Kernel Object BasicObject].freeze
  # name -> allowed argument counts
  NUMERIC_BLOCK_LOOP_ARGC = { 'times' => [0], 'upto' => [1], 'downto' => [1], 'step' => [1, 2],
                              'each_index' => [0], 'each_with_index' => [0], 'each' => [0] }.freeze

  def setup_numeric_block_params
    @numeric_block_params = {}
    @numeric_block_sites = numeric_block_sites
    @numeric_block_failed = Set.new
  end

  # Every `recv.name(args) { |params| ... }` with a literal block, in program order.
  def numeric_block_sites
    sites = []
    @ireps.each_value do |irep|
      next if irep.instructions.empty?

      layout = ->(insn) { NUMERIC_BLOCK_LOOP_ARGC.key?(insn.sym) && insn.plain_fixed_argc? ? insn.argc + 1 : nil }
      each_block_site(irep, send_ops: %w[SENDB], layout: layout) do |insn, idx, _block_insn, dest_reg, block_irep|
        next unless NUMERIC_BLOCK_LOOP_ARGC.fetch(insn.sym).include?(insn.argc)

        range_idx = nil
        if insn.sym == 'each'
          # `(a..b).each`: the RANGE op writes the receiver right before the BLOCK.
          before = idx >= 2 ? irep.instructions[idx - 2] : nil
          next unless before && %w[RANGE_INC RANGE_EXC].include?(before.op) && before.reg == dest_reg

          range_idx = idx - 2
        end
        sites << NumericBlockSite.new(irep: irep, idx: idx, block: block_irep.label, name: insn.sym, argc: insn.argc,
                                      recv: dest_reg.to_i, range_idx: range_idx)
      end
    end
    sites
  end

  # mruby's own definition of +name+ is the only one an object with these +ancestors+
  # can reach: no definition of the name in the closed world sits on them (mruby's
  # own Ruby, `core`, is compiled apart from the registry and never a rival), no
  # native or non-core outside Ruby defines it there (ClosedWorld#core_ruby_arm_safe?,
  # ADR 0270), and no prepend or unknown mixin can put another body in front.
  def numeric_core_method_safe?(name, ancestors)
    @numeric_core_method_safe ||= {}
    key = [name, ancestors]
    return @numeric_core_method_safe[key] if @numeric_core_method_safe.key?(key)

    defs = @registry[name] || []
    @numeric_core_method_safe[key] =
      !@closed_world.nil? && defs.none? { |d| d.owner == '<native>' || (ancestors.include?(d.owner) && !d.core) } &&
      ancestors.all? { |o| @closed_world.core_ruby_arm_safe?(name, o) } &&
      ancestors.none? { |o| !Array(@prepended_modules[o]).empty? || @unknown_mixins.include?(o) } ? true : false
  end

  NUMERIC_RANGE_ANCESTORS = %w[Range Enumerable Kernel Object BasicObject].freeze

  # Range#each (mrblib/range.rb) walks Integer endpoints with Integer#succ.
  def numeric_range_each_safe?
    (builtin_class_send_safe?('each', %w[Range]) || numeric_core_method_safe?('each', NUMERIC_RANGE_ANCESTORS)) &&
      (builtin_class_send_safe?('succ', %w[Integer Numeric]) || numeric_core_method_safe?('succ', NUMERIC_INT_ANCESTORS)) ? true : false
  end

  # Register -> class set the site gives the block's parameters, {} while an
  # operand is still unreached, or nil when the site cannot be modelled.
  def numeric_block_site_masks(site)
    owner = numeric_owner_of(site.irep)
    return nil unless owner

    mask = ->(reg) { numeric_raw_mask(site.irep, site.idx, reg, owner) }
    int_or_less = ->(m) { !m.nil? && (m & ~NumericFlow::NUM).zero? }
    recv = mask.call(site.recv)
    return nil if recv.nil?

    case site.name
    when 'times'
      return nil unless numeric_core_method_safe?('times', NUMERIC_INT_ANCESTORS) && numeric_op_native?('+') &&
                        numeric_op_native?('<')

      int_or_less.call(recv) ? { 1 => NumericFlow::INT } : nil
    when 'upto', 'downto', 'step'
      names = { 'upto' => %w[+ <=], 'downto' => %w[- >=], 'step' => %w[+ - <= >= ==] }.fetch(site.name)
      return nil unless numeric_core_method_safe?(site.name, NUMERIC_INT_ANCESTORS) && names.all? { |s| numeric_op_native?(s) }

      args = (1..site.argc).map { |k| mask.call(site.recv + k) }
      return nil unless int_or_less.call(recv) && args.all? { |m| int_or_less.call(m) }
      # `1.step(2.5)` and a Float step yield Floats: every operand must be Integer.
      if site.name == 'step'
        return nil unless [recv, *args].all? { |m| m.zero? || m == NumericFlow::INT }
      elsif !recv.zero? && recv != NumericFlow::INT
        return nil
      end

      { 1 => NumericFlow::INT }
    when 'each_index'
      return nil unless numeric_core_method_safe?('each_index', NUMERIC_ARRAY_ANCESTORS) && numeric_op_native?('+')

      recv.zero? || recv == NumericFlow::ARR ? { 1 => NumericFlow::INT } : nil
    when 'each_with_index'
      return nil unless numeric_core_method_safe?('each_with_index', NUMERIC_ARRAY_ANCESTORS) && numeric_op_native?('+')

      recv.zero? || recv == NumericFlow::ARR ? { 2 => NumericFlow::INT } : nil
    when 'each'
      return nil unless numeric_range_each_safe?

      # Both endpoints are the operands of the RANGE op right before the BLOCK.
      lo = numeric_raw_mask(site.irep, site.range_idx, site.recv, owner)
      hi = numeric_raw_mask(site.irep, site.range_idx, site.recv + 1, owner)
      return nil if lo.nil? || hi.nil?

      [lo, hi].all? { |m| m.zero? || m == NumericFlow::INT } ? { 1 => NumericFlow::INT } : nil
    end
  end

  # One growth pass; true when a parameter class set grew or a fact failed.
  def grow_numeric_block_params
    changed = false
    @numeric_block_sites.each do |site|
      facts = numeric_block_site_masks(site)
      if facts.nil?
        # Not modelled: every parameter register of this block is unknown for good.
        next if @numeric_block_failed.include?(site.block)

        @numeric_block_failed << site.block
        @numeric_block_params.delete_if { |(label, _), _| label == site.block }
        numeric_invalidate(site.block)
        changed = true
        next
      end
      next if @numeric_block_failed.include?(site.block)

      block_irep = @ireps[site.block]
      declared = block_irep && pure_mandatory_arity?(block_irep) ? mandatory_arity(block_irep) : 0
      facts.each do |reg, mask|
        # A register the block does not declare is one of its locals (starts nil).
        next if reg > declared

        key = [site.block, reg]
        current = @numeric_block_params[key] || 0
        next if (current | mask) == current

        @numeric_block_params[key] = current | mask
        numeric_invalidate(site.block)
        changed = true
      end
    end
    changed
  end

  def numeric_block_param_mask(irep, reg)
    return nil if @numeric_block_failed.nil? || @numeric_block_failed.include?(irep.label)

    @numeric_block_params[[irep.label, reg.to_i]] || cell_block_param_mask(irep, reg)
  end
end
