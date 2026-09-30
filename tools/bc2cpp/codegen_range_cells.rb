# frozen_string_literal: true

require_relative 'array_cells'

# CodeGen: ARRAY_ELEMENT_RANGE_PROOF (ADR 0286).
#
# Which Arrays have every writer visible, and what do their elements look like? The
# token flow of array_cells.rb finds, per irep, where an Array may go; this driver
#
#   1. runs it over every irep, collecting events (stores into ivar/constant cells,
#      escapes, element writes, element reads, iterations);
#   2. unifies the allocation tokens stored into one cell (Steensgaard), poisons every
#      class an Array escaped from or unknown data was stored into, and poisons every cell
#      an unmodelled irep touches;
#   3. grows, as part of the range fixpoint, one summary per class: the class set of its
#      elements (NumericFlow bits), their Integer range, and a lower bound of the
#      length. Lengths only ever grow (only non-shrinking writers are whitelisted), so
#      the minimum over every allocation of a class is a lower bound of every Array in it.
#
# A cell is admitted only where the class facts (ADR 0276) already say every write to
# the ivar / constant is visible, and where nothing can hand the Array to unknown code
# through the ivar: an attr_reader, instance_variable_get / instance_variables, or
# const_get / constants anywhere in the program refuse it.
#
# The summary answers, for a read of `a[i]` / `a.first` / an element block parameter:
# the element class set, range, and whether the read can miss (nil) -- see
# numeric_element_mask, range_cell_element_range and range_cell_in_bounds?.
class CodeGen
  CELL_LEAKING_IVAR_NAMES = %w[instance_variable_get instance_variables].freeze
  CELL_LEAKING_CONST_NAMES = %w[const_get constants const_missing].freeze
  CELL_INF = Float::INFINITY

  # Everything the token flows found.
  CellState = Struct.new(:tokens, :keys, :parent, :poisoned, :stores, :allocs, :writes, :const_writes, :unknown_writes,
                         :edges, :concats, :reads, :iters, :iter_by_label, :summary, :bumps, :readers,
                         keyword_init: true)

  # What ArrayCells asks about the program.
  class CellEnv
    def initialize(codegen, state)
      @cg = codegen
      @st = state
    end

    def token(key)
      @st.tokens[key] ||= begin
        @st.keys << key
        @st.keys.size + 1
      end
    end

    def mask(irep, idx, reg)
      @cg.numeric_raw_mask(irep, idx, reg.to_s, @cg.numeric_irep_owner[irep.label] || true)
    end

    def exact_array?(irep, idx, reg) = mask(irep, idx, reg) == NumericFlow::ARR
    def ivar_cell(irep, name) = @cg.cell_ivar_key(irep, name)
    def const_cell(insn) = @cg.cell_const_key(insn.const_name)
    def const_cell_named(insn) = @cg.cell_const_key(insn.const_name)
    def array_class_const?(insn) = insn.const_name == 'Array' && @cg.cell_array_class_const?
    def array_method_safe?(name) = @cg.cell_array_method_safe?(name)
    def array_new_safe? = @cg.cell_array_new_safe?
    def discards_return?(irep) = @cg.cell_discards_return?(irep)
    def captured(irep) = @cg.cell_captured_regs(irep)
    def opaque(irep) = @cg.fixnum_proof_ctx(irep)[:upvars]
  end

  # Collects the flow's events into a CellState.
  class CellSink < ArrayCells::Sink
    def initialize(state, env)
      super()
      @st = state
      @env = env
    end

    def at(irep, index, insn) = (@where = [irep.label, index, insn.op, insn.sym])
    def escape(tokens) = poison_bits(tokens)
    def poison(tokens) = poison_bits(tokens)
    def store(tokens, cell, _irep, _index) = (@st.stores << [tokens, @env.token(cell)])
    def alloc(token, irep, index, len) = (@st.allocs[token] = { irep: irep, index: index, len: len, reg: nil })
    def alloc_length(token, _irep, _index, reg) = (@st.allocs[token][:reg] = reg)
    def write(tokens, irep, index, reg, flag) = (@st.writes << [tokens, irep, index, reg, flag])
    def write_const(tokens, mask) = (@st.const_writes << [tokens, mask])
    def write_unknown(tokens) = (@st.unknown_writes << tokens)
    def edge(src, dst, kind) = (@st.edges << [src, dst, kind])
    def concat(dst, src) = (@st.concats << [dst, src])
    def read(tokens, irep, index, reader) = (@st.reads[[irep.label, index]] = [tokens, reader])
    def iterate(tokens, irep, index, label, params) = (@st.iters << [tokens, irep, index, label, params])

    def poison_bits(mask)
      mask = ArrayCells.tracked(mask)
      while mask.nonzero?
        low = mask & -mask
        @st.poisoned << (low.bit_length - 1)
        mask ^= low
      end
    end
  end

  # ---- admission ------------------------------------------------------------------

  def cell_names_mentioned?(names)
    @ireps.each_value.any? do |irep|
      irep.instructions.any? { |i| i.sym && names.include?(i.sym) && (i.op == 'LOADSYM' || i.op.include?('SEND')) }
    end
  end

  def cell_prerequisites?
    @numeric_ivar_groups && @numeric_const_groups && @closed_world && @closed_world.global_refusal.nil? &&
      !@numeric_ivar_disabled
  end

  def cell_ivar_reader_names
    @cell_ivar_reader_names ||= begin
      names = Set.new
      @registry.each_value do |defs|
        defs.each do |d|
          next unless d.kind == :ivar_accessor && d.irep.nil? && !d.name.end_with?('=')

          names << [numeric_family(d.owner), d.name]
        end
      end
      names
    end
  end

  def cell_ivar_key(irep, name)
    return nil if @cell_ivar_disabled || name.nil?

    group = numeric_ivar_group(irep, name)
    return nil unless group && !group.failed
    return nil if cell_ivar_reader_names.include?([group.family, group.name])

    [:iv, group.family, group.name]
  end

  def cell_const_key(name)
    return nil if @cell_const_disabled || name.nil?

    group = @numeric_const_groups[name]
    group && !group.failed ? [:cs, name] : nil
  end

  # The bare constant `Array` is ::Array: no constant assignment, and no class or module named
  # Array opened anywhere but at the top level (`class Array` / `class ::Array` in the root
  # irep), and nothing that rebinds constants at run time. Native code never defines another
  # `Array` under a namespace in this project (a native binding is not enumerated here).
  def cell_array_class_const?
    return @cell_array_const unless @cell_array_const.nil?

    @cell_array_const = compute_cell_array_class_const
  end

  ROOT_IREP_LABEL = '0'

  def compute_cell_array_class_const
    return false if @numeric_const_groups.nil? || !(@numeric_const_groups['Array']&.sites || []).empty?
    return false if cell_names_mentioned?(%w[const_set remove_const const_missing])

    @ireps.each_value.all? do |irep|
      irep.instructions.each_with_index.all? do |insn, idx|
        next true unless %w[CLASS MODULE].include?(insn.op) && insn.sym == 'Array'

        outer = irep.last_writer(idx - 1, insn.reg)
        outer&.op == 'OCLASS' || (outer&.op == 'LOADNIL' && irep.label == ROOT_IREP_LABEL)
      end
    end
  end

  def cell_array_method_safe?(name)
    @cell_array_safe ||= {}
    return @cell_array_safe[name] if @cell_array_safe.key?(name)

    @cell_array_safe[name] = (builtin_class_send_safe?(name, %w[Array]) ||
                              numeric_core_method_safe?(name, NUMERIC_ARRAY_ANCESTORS)) ? true : false
  end

  # `Array.new` reaches the core Array#initialize: ordinary construction, and no Ruby
  # `initialize` on Array.
  def cell_array_new_safe?
    @cell_array_new_safe = compute_cell_array_new_safe if @cell_array_new_safe.nil?
    @cell_array_new_safe
  end

  def compute_cell_array_new_safe
    @closed_world.standard_constructor_lookup? && (@registry['initialize'] || []).none? { |d| d.owner == 'Array' } &&
      @closed_world.core_ruby_arm_safe?('initialize', 'Array') ? true : false
  end

  # ---- methods whose result nobody uses -------------------------------------------------
  #
  # `def add(x); @list << x; end` and `def initialize; @list = []; end` end by returning the
  # Array, which is no leak when no caller looks at the result. A name qualifies when every
  # definition and call is visible (the name_fully_visible? argument of NUMERIC_RETURN_PROOF:
  # no native or outside Ruby defines or spells it, no method_missing), no Symbol or String
  # can name it at run time, no definition of it calls `super`, and every call site overwrites
  # the result register with its very next instruction (statement position). `initialize` is
  # called by Class#new, which drops the result; it qualifies while nothing spells it and no
  # `super` uses a result.

  # Instructions that overwrite their leading register without reading it.
  CELL_STATEMENT_STARTS = %w[LOADL LOADSYM LOADNIL LOADSELF LOADTRUE LOADFALSE GETIV GETGV GETSV GETCV STRING].freeze

  def cell_result_unused?(irep, idx)
    call = irep.instructions[idx]
    nxt = irep.instructions[idx + 1]
    return false unless nxt && call.reg

    lead = nxt.reg
    return false unless lead == call.reg

    nxt.op.start_with?('LOADI') || CELL_STATEMENT_STARTS.include?(nxt.op) ||
      (nxt.op == 'MOVE' && nxt.regs[1] != lead)
  end

  def cell_discarded_result_names
    @cell_discarded_names ||= compute_cell_discarded_result_names
  end

  def compute_cell_discarded_result_names
    names = Set.new
    return names unless @foreign_method_names && @outside_tokens && @closed_world&.global_refusal.nil?

    supers = Set.new
    @registry.each_value do |defs|
      defs.each do |d|
        irep = d.irep && @ireps[d.irep]
        supers << d.name if irep && cell_subtree_has_op?(irep, 'SUPER')
      end
    end
    aliased = numeric_aliased_names
    candidates = @registry.keys.select do |name|
      name != 'initialize' && !@foreign_method_names.include?(name) && !@outside_tokens.include?(name) &&
        !numeric_dynamically_named?(name) && !supers.include?(name) && !aliased.include?(name) &&
        @closed_world.name_fully_visible?(name)
    end.to_set
    sites = Hash.new(0)
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.sym && candidates.include?(insn.sym) && insn.op.include?('SEND')

        sites[insn.sym] += 1
        candidates.delete(insn.sym) unless cell_result_unused?(irep, idx)
      end
    end
    # A method nothing calls may still be called from outside what the program shows.
    candidates.select { |name| sites[name].positive? }.to_set
  end

  def cell_subtree_has_op?(irep, op, seen = Set.new)
    return false unless seen.add?(irep.label)

    irep.instructions.any? { |i| i.op == op } ||
      Array(irep.reps).any? { |l| (child = @ireps[l]) && cell_subtree_has_op?(child, op, seen) }
  end

  # Nothing calls `initialize` but Class#new, and no `super` uses a result.
  def cell_initialize_discarded?
    return @cell_initialize_discarded unless @cell_initialize_discarded.nil?

    @cell_initialize_discarded = compute_cell_initialize_discarded
  end

  def compute_cell_initialize_discarded
    return false unless @closed_world&.global_refusal.nil? && @closed_world&.standard_constructor_lookup?

    @ireps.each_value.none? do |irep|
      irep.instructions.each_with_index.any? do |insn, idx|
        next true if insn.sym == 'initialize' && (insn.op == 'LOADSYM' || insn.op.include?('SEND'))

        # A `super` in an initialize: its result must be dropped or returned.
        insn.op == 'SUPER' && numeric_irep_owner[irep.label]&.name == 'initialize' &&
          !(cell_result_unused?(irep, idx) || irep.instructions[idx + 1]&.op == 'RETURN')
      end
    end
  end

  # Is +irep+ the body of a method whose result nobody uses?
  def cell_discards_return?(irep)
    owner = numeric_irep_owner[irep.label]
    return false unless owner && owner.irep == irep.label

    owner.name == 'initialize' ? cell_initialize_discarded? : cell_discarded_result_names.include?(owner.name)
  end

  # Registers of +irep+ a nested block reads or writes (GETUPVAR / SETUPVAR).
  def cell_captured_regs(irep)
    @cell_captured ||= {}
    return @cell_captured[irep.label] if @cell_captured.key?(irep.label)

    found = Set.new
    walk = lambda do |label, depth|
      child = @ireps[label]
      next unless child

      child.instructions.each do |insn|
        next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

        index, level = insn.upvar_ref
        found << index if index && level + 1 == depth
      end
      Array(child.reps).each { |c| walk.call(c, depth + 1) }
    end
    Array(irep.reps).each { |c| walk.call(c, 1) }
    @cell_captured[irep.label] = found
  end

  # ---- collection (once) -------------------------------------------------------------

  def setup_range_cells
    @cells = nil
    @cell_captured = nil
    @cell_ivar_reader_names = nil
    @cell_discarded_names = nil
    @cell_initialize_discarded = nil
    return unless cell_prerequisites?

    @cell_ivar_disabled = cell_names_mentioned?(CELL_LEAKING_IVAR_NAMES)
    @cell_const_disabled = cell_names_mentioned?(CELL_LEAKING_CONST_NAMES)
    state = CellState.new(tokens: {}, keys: [], parent: {}, poisoned: Set.new, stores: [], allocs: {}, writes: [],
                          const_writes: [], unknown_writes: [], edges: [], concats: [], reads: {}, iters: [],
                          iter_by_label: {}, summary: {}, bumps: Hash.new(0), readers: nil)
    env = CellEnv.new(self, state)
    sink = CellSink.new(state, env)
    @ireps.each_value do |irep|
      next if irep.instructions.empty?

      cell_poison_touched(irep, env, state) if ArrayCells.states(irep, env, sink).nil?
    end
    cell_unify(state)
    @cells = state
    # The class facts of stage one saw every element read as unknown; the flows are redone
    # with the cells (the range fixpoint keeps the summaries current).
    reset_numeric_flow!
    reset_range_flow!
  end

  # An irep the token flow cannot model: any cell it reads or writes can leak there.
  def cell_poison_touched(irep, env, state)
    irep.instructions.each do |insn|
      key = case insn.op
            when 'GETIV', 'SETIV' then cell_ivar_key(irep, insn.ivar)
            when 'GETCONST', 'SETCONST', 'GETMCNST', 'SETMCNST' then cell_const_key(insn.const_name)
            end
      state.poisoned << env.token(key) if key
    end
  end

  def cell_find(state, bit)
    parent = state.parent[bit] || bit
    return bit if parent == bit

    state.parent[bit] = cell_find(state, parent)
  end

  def cell_bits(mask)
    bits = []
    mask = ArrayCells.tracked(mask)
    while mask.nonzero?
      low = mask & -mask
      bits << (low.bit_length - 1)
      mask ^= low
    end
    bits
  end

  def cell_unify(state)
    state.stores.each do |tokens, cell_bit|
      state.poisoned << cell_bit unless (tokens & ArrayCells::UNK).zero?
      cell_bits(tokens).each do |bit|
        ra = cell_find(state, bit)
        rb = cell_find(state, cell_bit)
        state.parent[ra] = rb unless ra == rb
      end
    end
    state.poisoned = state.poisoned.map { |bit| cell_find(state, bit) }.to_set
    readers = Hash.new { |h, k| h[k] = Set.new }
    state.reads.each do |(label, _idx), (tokens, _reader)|
      cell_bits(tokens).each { |bit| readers[cell_find(state, bit)] << label }
    end
    state.iters.each do |tokens, _irep, _idx, label, _params|
      cell_bits(tokens).each { |bit| readers[cell_find(state, bit)] << label }
    end
    state.iters.each { |ev| state.iter_by_label[ev[3]] = ev }
    state.readers = readers
  end

  def cell_roots(tokens)
    cell_bits(tokens).map { |bit| cell_find(@cells, bit) }.uniq
  end

  # ---- the fixpoint step ---------------------------------------------------------------

  CellSummary = Struct.new(:mask, :range, :len)

  # Recompute every class summary from the current facts and merge it (monotonically) into
  # the stored one; true when any summary changed.
  def grow_range_cells
    return false unless @cells

    changed = false
    cell_fresh_summaries.each do |root, sum|
      old = @cells.summary[root]
      merged = old.nil? ? sum : cell_merge(root, old, sum)
      next if old && merged.to_a == old.to_a

      @cells.summary[root] = merged
      changed = true
      Array(@cells.readers[root]).each do |label|
        numeric_invalidate(label)
        range_invalidate(label)
      end
    end
    changed
  end

  def cell_merge(root, old, sum)
    range = IntRange.join(old.range, sum.range)
    if old.range && range != old.range && (@cells.bumps[root] += 1) > RANGE_WIDEN_AFTER
      range = IntRange.widen(old.range, range)
    end
    CellSummary.new(old.mask | sum.mask, range, [old.len, sum.len].min)
  end

  # The length a fresh Array from this allocation site has at least. CELL_INF means "no
  # constraint yet" (the size expression has no value so far).
  def cell_alloc_length(info)
    return CELL_INF if info[:len] == :derived
    return info[:len] if info[:len]
    return 0 unless info[:reg]

    owner = numeric_irep_owner[info[:irep].label] || true
    range = range_value_at(info[:irep], info[:index], info[:reg].to_s, owner)
    return CELL_INF if range.nil?
    return 0 unless range[0].is_a?(Integer)

    [range[0], 0].max
  end

  def cell_fresh_summaries
    st = @cells
    sums = Hash.new { |h, k| h[k] = CellSummary.new(0, nil, CELL_INF) }
    st.allocs.each do |token, info|
      root = cell_find(st, token)
      sums[root].len = [sums[root].len, cell_alloc_length(info)].min
    end
    # A copy is as long as its source (a subset, only as long as nothing).
    loop do
      moved = false
      st.edges.each do |src, dst, kind|
        droot = cell_find(st, dst)
        bound = kind == :subset ? 0 : cell_roots(src).map { |r| sums[r].len }.min
        next if bound.nil? || sums[droot].len <= bound

        sums[droot].len = bound
        moved = true
      end
      break unless moved
    end
    st.writes.each { |tokens, irep, idx, reg, flag| cell_apply_write(sums, tokens, irep, idx, reg, flag) }
    st.const_writes.each { |tokens, mask| cell_roots(tokens).each { |r| sums[r].mask |= mask } }
    st.unknown_writes.each { |tokens| cell_roots(tokens).each { |r| sums[r].mask |= NumericFlow::OTHER } }
    cell_propagate_elements(sums)
    st.poisoned.each { |root| sums[root].mask |= NumericFlow::OTHER }
    sums
  end

  # elements(dst) includes elements(src) along every copy and concat edge.
  def cell_propagate_elements(sums)
    st = @cells
    pairs = st.edges.map { |src, dst, _kind| [cell_roots(src), [cell_find(st, dst)]] } +
            st.concats.map { |dst, src| [cell_roots(src), cell_roots(dst)] }
    loop do
      moved = false
      pairs.each do |srcs, dsts|
        srcs.product(dsts).each do |s, d|
          next if s == d

          src_mask = sums[s].mask | (st.poisoned.include?(s) ? NumericFlow::OTHER : 0)
          new_mask = sums[d].mask | src_mask
          new_range = IntRange.join(sums[d].range, sums[s].range)
          next if new_mask == sums[d].mask && new_range == sums[d].range

          sums[d].mask = new_mask
          sums[d].range = new_range
          moved = true
        end
      end
      break unless moved
    end
  end

  # One element write: the value's class set and range join into every class the
  # receiver may be; a write that may land past the end pads with nil.
  def cell_apply_write(sums, tokens, irep, idx, reg, flag)
    owner = numeric_irep_owner[irep.label] || true
    mask = numeric_raw_mask(irep, idx, reg.to_s, owner)
    mask = NumericFlow::OTHER if mask.nil?
    range = mask.anybits?(NumericFlow::INT) ? range_value_at(irep, idx, reg.to_s, owner) : nil
    roots = cell_roots(tokens)
    if flag == :gap
      mask |= NumericFlow::NIL
    elsif flag == :indexed
      key = range_value_at(irep, idx, (reg.to_i - 1).to_s, owner)
      shortest = roots.map { |r| sums[r].len }.min
      inside = key && shortest && shortest != CELL_INF && key[0] >= 0 && key[1] < shortest
      # An index with no value yet cannot write anything yet.
      mask |= NumericFlow::NIL unless inside || key.nil?
    end
    roots.each do |r|
      sums[r].mask |= mask
      sums[r].range = IntRange.join(sums[r].range, range)
    end
  end

  # ---- queries ---------------------------------------------------------------------------

  CellRead = Struct.new(:mask, :range, :len, :reader)

  # The element facts for the read at (+irep+, +idx+), or nil when any class it may read
  # is unknown, poisoned, or holds elements the analysis cannot classify.
  def cell_read_info(irep, idx)
    return nil unless @cells

    event = @cells.reads[[irep.label, idx]]
    event ? cell_info(event[0], event[1]) : nil
  end

  def cell_info(tokens, reader)
    roots = cell_roots(tokens)
    return nil if roots.empty?

    mask = 0
    range = nil
    len = CELL_INF
    roots.each do |root|
      return nil if @cells.poisoned.include?(root)

      sum = @cells.summary[root]
      return nil if sum && sum.mask.anybits?(NumericFlow::OTHER)

      mask |= sum ? sum.mask : 0
      range = IntRange.join(range, sum&.range)
      len = [len, sum ? sum.len : CELL_INF].min
    end
    CellRead.new(mask, range, len == CELL_INF ? 0 : len, reader)
  end

  # An object that knows element facts this file cannot derive (a record / LCF schema oracle:
  # `rec[:hp]` is an Integer in [0, 9999]). It answers element_mask(irep, index, insn, state),
  # element_range(query) (an IntRange, nil for "no Integer") and element_in_bounds?(query); nil
  # (NO_OPINION for the range) means it has no opinion and the Array cells decide.
  attr_accessor :element_oracle

  NO_OPINION = :no_opinion

  # Class set of the element `insn` (GETIDX / GETIDX0) reads. OTHER when the read is not a
  # tracked Array's.
  def numeric_element_mask(irep, index, insn, state)
    external = element_oracle&.element_mask(irep, index, insn, state)
    return external unless external.nil?

    info = cell_read_info(irep, index)
    return NumericFlow::OTHER unless info

    key = insn.op == 'GETIDX' ? state[insn.reg.to_i + 1] : NumericFlow::INT
    return NumericFlow::OTHER unless key == NumericFlow::INT

    info.mask | (insn.op == 'GETIDX0' && info.len >= 1 ? 0 : NumericFlow::NIL)
  end

  # `a.first`, `a.max`, `a.fetch(i)` ... on a tracked Array; nil when not modelled.
  def numeric_element_send_mask(irep, index, insn, state)
    info = cell_read_info(irep, index)
    return nil unless info

    name = insn.sym
    argc = insn.op.end_with?('0') ? 0 : insn.argc
    if %w[[] at fetch].include?(name)
      return nil unless argc == 1 && state[insn.reg.to_i + 1] == NumericFlow::INT
    elsif argc != 0
      return nil
    end
    hits = name == 'fetch' || (%w[first last min max sample].include?(name) && info.len >= 1)
    info.mask | (hits ? 0 : NumericFlow::NIL)
  end

  def range_cell_element_range(query)
    external = element_oracle ? element_oracle.element_range(query) : NO_OPINION
    return external unless external.equal?(NO_OPINION)

    info = cell_read_info(query.irep, query.index)
    return IntRange::TOP unless info
    return nil unless info.mask.anybits?(NumericFlow::INT) # no Integer element at all

    info.range
  end

  # The read cannot yield nil: positional on a non-empty class, or an index inside it.
  def range_cell_in_bounds?(query)
    external = element_oracle&.element_in_bounds?(query)
    return external unless external.nil?

    info = cell_read_info(query.irep, query.index)
    return false unless info

    if %w[first last min max sample].include?(query.reader) || query.insn.op == 'GETIDX0'
      info.len >= 1 && !info.mask.anybits?(NumericFlow::NIL)
    elsif query.reader == 'fetch'
      true
    else
      key = query.key_range
      !key.nil? && IntRange.finite?(key) && key[0] >= 0 && key[1] < info.len
    end
  end

  # Element parameters of an iteration block (`ary.each { |x| }`): the elements' class set
  # and range; nil when the block is not an iteration of a tracked Array or the parameter
  # is not a declared one.
  def cell_block_param(irep, reg)
    return nil unless @cells

    event = @cells.iter_by_label[irep.label]
    return nil unless event && event[4][reg.to_i] == :elem
    return nil unless pure_mandatory_arity?(irep) && reg.to_i <= mandatory_arity(irep)

    info = cell_info(event[0], nil)
    return nil if info.nil? || info.mask.anybits?(NumericFlow::OTHER)
    # `each { |a, b| }` over Array elements spreads each element over the parameters.
    return nil if mandatory_arity(irep) > 1 && info.mask.anybits?(NumericFlow::ARR)

    info
  end

  def cell_block_param_mask(irep, reg)
    cell_block_param(irep, reg)&.mask
  end

  def range_cells_report
    return [] unless @cells

    lines = []
    @cells.summary.each do |root, sum|
      next if @cells.poisoned.include?(root)

      key = @cells.keys[root - 2]
      lines << "  RANGECELL #{key.inspect} class=#{numeric_mask_name(sum.mask)} " \
               "elements=#{sum.range ? range_text(sum.range) : 'none'} length>=#{sum.len == CELL_INF ? 0 : sum.len}"
    end
    lines.sort
  end
end
