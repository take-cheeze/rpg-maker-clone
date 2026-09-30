# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'numeric_flow'

# ARRAY_CELLS (ADR 0286): where can an Array go? A forward dataflow over one irep whose value per
# register is a set of TOKENS (an Integer bitmask): UNK (anything untracked), CLASS_ARRAY (the
# constant ::Array), one token per allocation site, and one per admitted ivar / constant cell.
#
# What the flow decides is where a token may NOT go. A register holding tokens is copied, stored
# into an admitted cell, used as the receiver of a whitelisted core Array method on an exactly-Array
# receiver, or used as the container of an Integer-indexed `[]` / `[]=`. Any other use ESCAPES the
# tokens (the driver then gives their classes no element facts): an argument or receiver of any
# other call, a returned or yielded value, an element of another container, a captured register,
# and every op the flow does not model (the whole irep is then unmodelled). Events go to a sink;
# the flow never looks at element values.
module ArrayCells
  UNK = 1
  CLASS_ARRAY = 2
  SPECIAL = UNK | CLASS_ARRAY

  # name => allowed argument counts. Read-only: the receiver is not aliased by the
  # result and the arguments are not stored.
  READERS = {
    'size' => [0], 'length' => [0], 'empty?' => [0], 'nil?' => [0], 'frozen?' => [0], 'first' => [0], 'last' => [0],
    '[]' => [1], 'at' => [1], 'fetch' => [1], 'min' => [0], 'max' => [0], 'sum' => [0], 'count' => [0, 1],
    'include?' => [1], 'index' => [1], 'find_index' => [1], 'rindex' => [1], 'join' => [0, 1], 'inspect' => [0],
    'to_s' => [0], 'hash' => [0], 'is_a?' => [1], 'kind_of?' => [1], 'instance_of?' => [1], 'class' => [0],
    'object_id' => [0], 'sample' => [0], '!' => [0], 'any?' => [0], 'all?' => [0], 'none?' => [0]
  }.freeze
  # Readers that return one ELEMENT (or nil): a `read` event, so the element fact is asked for.
  ELEMENT_READERS = %w[first last [] at fetch min max sample].freeze
  # Readers that need an Integer index (a Range or other index selects a slice).
  INDEXED_READERS = %w[[] at fetch].freeze

  # name => [argument counts, result, block parameters]. result: :self (the receiver
  # comes back), :fresh_unknown, :fresh_subset (elements are a subset of the receiver's),
  # :fresh_same (same elements and length), :value (an element or a scalar).
  ITERATORS = {
    'each' => [[0], :self, { 1 => :elem }], 'each_with_index' => [[0], :self, { 1 => :elem, 2 => :index }],
    'each_index' => [[0], :self, { 1 => :index }], 'reverse_each' => [[0], :self, { 1 => :elem }],
    'map' => [[0], :fresh_unknown, { 1 => :elem }], 'collect' => [[0], :fresh_unknown, { 1 => :elem }],
    'select' => [[0], :fresh_subset, { 1 => :elem }], 'filter' => [[0], :fresh_subset, { 1 => :elem }],
    'find_all' => [[0], :fresh_subset, { 1 => :elem }], 'reject' => [[0], :fresh_subset, { 1 => :elem }],
    'take_while' => [[0], :fresh_subset, { 1 => :elem }], 'drop_while' => [[0], :fresh_subset, { 1 => :elem }],
    'sort_by' => [[0], :fresh_same, { 1 => :elem }],
    'find' => [[0], :value, { 1 => :elem }], 'detect' => [[0], :value, { 1 => :elem }],
    'any?' => [[0], :value, { 1 => :elem }], 'all?' => [[0], :value, { 1 => :elem }],
    'none?' => [[0], :value, { 1 => :elem }], 'one?' => [[0], :value, { 1 => :elem }],
    'count' => [[0], :value, { 1 => :elem }], 'sum' => [[0], :value, { 1 => :elem }],
    'min_by' => [[0], :value, { 1 => :elem }], 'max_by' => [[0], :value, { 1 => :elem }],
    'group_by' => [[0], :value, { 1 => :elem }], 'partition' => [[0], :value, { 1 => :elem }],
    'flat_map' => [[0], :value, { 1 => :elem }], 'find_index' => [[0], :value, { 1 => :elem }],
    'index' => [[0], :value, { 1 => :elem }], 'inject' => [[0], :value, { 2 => :elem }],
    'reduce' => [[0], :value, { 2 => :elem }]
  }.freeze

  # name => kind. Writers: their arguments become elements.
  WRITERS = { 'push' => :append, '<<' => :append, 'append' => :append, 'unshift' => :append, 'prepend' => :append,
              'insert' => :insert, 'concat' => :concat }.freeze

  # name => [argument counts, result]. Fresh arrays whose elements come from the receiver.
  FRESH = { 'dup' => [[0], :fresh_same], 'clone' => [[0], :fresh_same], 'reverse' => [[0], :fresh_same],
            'sort' => [[0], :fresh_same], 'rotate' => [[0, 1], :fresh_same], 'shuffle' => [[0], :fresh_same],
            'uniq' => [[0], :fresh_subset], 'compact' => [[0], :fresh_subset], 'take' => [[1], :fresh_subset],
            'drop' => [[1], :fresh_subset], '-' => [[1], :fresh_subset], '&' => [[1], :fresh_subset],
            '+' => [[1], :fresh_plus], 'to_a' => [[0], :self], 'entries' => [[0], :self],
            'freeze' => [[0], :self] }.freeze
  # first(n) / last(n) take a count and return a fresh array; the no-argument forms are readers.
  FRESH_WITH_COUNT = %w[first last].freeze

  # Ops the flow models. Anything else makes the irep unmodelled.
  MODELLED = Set[
    'NOP', 'MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE', 'GETGV', 'SETGV', 'GETSV', 'SETSV',
    'GETIV', 'SETIV', 'GETCV', 'SETCV', 'GETCONST', 'SETCONST', 'GETMCNST', 'SETMCNST', 'GETUPVAR', 'SETUPVAR',
    'GETIDX', 'GETIDX0', 'SETIDX', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL', 'SSEND', 'SSEND0', 'SSENDB', 'SEND', 'SEND0',
    'SENDB', 'SUPER', 'BLKCALL', 'BLKPUSH', 'ENTER', 'KEY_P', 'KEYEND', 'KARG', 'RETURN', 'RETURN_BLK', 'RETSELF',
    'RETNIL', 'RETTRUE', 'RETFALSE', 'BREAK', 'ADD', 'ADDI', 'SUB', 'SUBI', 'ADDILV', 'SUBILV', 'MUL', 'DIV', 'EQ', 'LT',
    'LE', 'GT', 'GE', 'ARRAY', 'ARYCAT', 'ARYPUSH', 'ARYSPLAT', 'AREF', 'INTERN', 'SYMBOL', 'STRING', 'STRCAT',
    'HASH', 'HASHADD', 'HASHCAT', 'LAMBDA', 'BLOCK', 'METHOD', 'RANGE_INC', 'RANGE_EXC', 'OCLASS', 'CLASS', 'MODULE',
    'EXEC', 'DEF', 'TDEF', 'SDEF', 'ALIAS', 'UNDEF', 'SCLASS', 'TCLASS', 'DEBUG', 'STOP', 'RAISEIF', 'MATCHERR'
  ].freeze
  LOADS = %w[LOADL LOADSYM LOADNIL LOADTRUE LOADFALSE STRING SYMBOL INTERN LAMBDA BLOCK METHOD OCLASS CLASS MODULE SCLASS
             TCLASS DEF TDEF SDEF EXEC].freeze

  # What the flow tells its driver. The base class ignores everything.
  class Sink
    def at(_irep, _index, _insn); end
    def escape(_tokens); end
    def store(_tokens, _cell, _irep, _index); end
    def alloc(_token, _irep, _index, _len); end
    def alloc_length(_token, _irep, _index, _reg); end
    def write(_tokens, _irep, _index, _value_reg, _gap); end
    def write_const(_tokens, _mask); end
    def write_unknown(_tokens); end
    def poison(_tokens); end
    def edge(_src, _dst, _kind); end
    def concat(_dst_tokens, _src_tokens); end
    def read(_tokens, _irep, _index, _reader); end
    def iterate(_tokens, _irep, _index, _block_label, _params); end
    def cell_read(_cell, _irep); end
  end

  module_function

  # The Environment the flow asks (all answers are about ONE irep at a time):
  #   token(key)                 the bit INDEX (>= 2) for a token key, allocated on first use
  #   mask(irep, idx, reg)       NumericFlow class set of a register (nil: unknown)
  #   ivar_cell(irep, name)      the cell key of an admitted ivar, or nil
  #   const_cell(insn)           the cell key of an admitted constant, or nil
  #   array_class_const?(insn)   GETCONST/GETMCNST of ::Array itself
  #   array_method_safe?(name)   no Ruby override of the core Array method
  #   array_new_safe?            Array.new / Array#initialize are the core ones
  #   discards_return?(irep)     irep is a method body whose result no caller ever uses
  #   captured(irep)             registers a nested block reads or writes
  #   opaque(irep)               registers a nested block writes (SETUPVAR)
  # Returns index -> Array of token masks before the instruction (nil if unreached), or
  # nil when the irep is not modelled.
  def states(irep, env, sink = nil)
    program = BytecodeIR.for(irep)
    return nil unless program.resolved?
    return nil if program.handlers?

    insns = irep.instructions
    return nil if insns.empty? || !insns.all? { |i| MODELLED.include?(i.op) || i.op.start_with?('LOADI') }

    nregs = [irep.nregs.to_i, 1].max
    ctx = { irep: irep, env: env, nregs: nregs, captured: env.captured(irep), opaque: env.opaque(irep) }
    extra = NumericFlow.enter_edges(irep)
    entry = Array.new(nregs, UNK)
    ins = Array.new(insns.length)
    ins[0] = entry
    work = [0]
    queued = Set[0]
    until work.empty?
      i = work.shift
      queued.delete(i)
      out = transfer(i, insns[i], ins[i], ctx, nil)
      NumericFlow.successors(program, extra, i).each do |s|
        merged = ins[s] ? ins[s].each_with_index.map { |m, r| m | out[r] } : out.dup
        next if merged == ins[s]

        ins[s] = merged
        work << s if queued.add?(s)
      end
    end
    if sink
      ins.each_with_index { |st, i| transfer(i, insns[i], st, ctx, sink) if st }
    end
    ins
  end

  def tracked(mask) = mask & ~SPECIAL

  def transfer(index, insn, state, ctx, sink)
    op = insn.op
    env = ctx[:env]
    irep = ctx[:irep]
    nregs = ctx[:nregs]
    sink&.at(irep, index, insn)
    esc = ->(mask) { sink&.escape(tracked(mask)) if tracked(mask).nonzero? }
    reg_of = ->(r) { r.to_i < nregs ? state[r.to_i] : UNK }
    out = state.dup
    dest = lambda do |a, mask|
      mask = UNK if ctx[:opaque].include?(a.to_s)
      out[a] = mask
      esc.call(mask) if ctx[:captured].include?(a)
    end
    a = insn.reg&.to_i

    case op
    when 'NOP', 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL', 'ENTER', 'DEBUG', 'STOP', 'KEYEND', 'RETSELF', 'RETNIL', 'RETTRUE',
         'RETFALSE', 'ALIAS', 'UNDEF'
      nil
    when 'RETURN'
      # A method whose every caller discards the result hands the Array to nobody.
      esc.call(reg_of.call(a)) unless env.discards_return?(irep)
    when 'RETURN_BLK', 'BREAK', 'RAISEIF', 'MATCHERR' then esc.call(reg_of.call(a))
    when 'MOVE' then dest.call(a, reg_of.call(insn.regs[1]))
    when /\ALOADI/, *LOADS then dest.call(a, 0)
    when 'LOADSELF', 'GETGV', 'GETSV', 'GETCV', 'GETUPVAR', 'BLKPUSH', 'KARG', 'KEY_P' then dest.call(a, UNK)
    when 'SETGV', 'SETSV', 'SETCV', 'SETUPVAR', 'SETMCNST' then insn.regs.each { |r| esc.call(reg_of.call(r)) }
    when 'GETIV'
      cell = env.ivar_cell(irep, insn.ivar)
      sink&.cell_read(cell, irep) if cell
      dest.call(a, cell ? 1 << env.token(cell) : UNK)
    when 'SETIV'
      value = reg_of.call(insn.regs.first)
      cell = env.ivar_cell(irep, insn.ivar)
      cell ? sink&.store(value, cell, irep, index) : esc.call(value)
    when 'GETCONST', 'GETMCNST'
      cell = env.const_cell(insn)
      sink&.cell_read(cell, irep) if cell
      dest.call(a, if env.array_class_const?(insn) then CLASS_ARRAY
                   elsif cell then 1 << env.token(cell)
                   else UNK
                   end)
    when 'SETCONST'
      value = reg_of.call(insn.regs.first)
      cell = env.const_cell_named(insn)
      cell ? sink&.store(value, cell, irep, index) : esc.call(value)
    when 'ARRAY' then array_literal(index, insn, state, ctx, sink, out, dest, esc)
    when 'ARYPUSH'
      count = insn.uint_operand.to_i
      (1..count).each do |k|
        push_write(index, state, ctx, sink, a, a + k)
        esc.call(reg_of.call(a + k))
      end
    when 'ARYCAT'
      sink&.write_unknown(tracked(reg_of.call(a)))
      esc.call(reg_of.call(a + 1))
    when 'ARYSPLAT'
      esc.call(reg_of.call(a))
      dest.call(a, UNK)
    when 'AREF'
      esc.call(reg_of.call(insn.regs[1]))
      dest.call(a, UNK)
    when 'HASH'
      (0...(2 * insn.uint_operand.to_i)).each { |k| esc.call(reg_of.call(a + k)) }
      dest.call(a, 0)
    when 'HASHADD'
      (1..(2 * insn.uint_operand.to_i)).each { |k| esc.call(reg_of.call(a + k)) }
    when 'HASHCAT', 'STRCAT'
      esc.call(reg_of.call(a + 1))
    when 'RANGE_INC', 'RANGE_EXC'
      esc.call(reg_of.call(a))
      esc.call(reg_of.call(a + 1))
      dest.call(a, 0)
    when 'ADD'
      binary_operator(index, insn, state, ctx, sink, out, dest, esc, '+')
    when 'SUB', 'MUL', 'DIV', 'EQ', 'LT', 'LE', 'GT', 'GE'
      esc.call(reg_of.call(a))
      esc.call(reg_of.call(insn.paren_reg))
      dest.call(a, UNK)
    when 'ADDI', 'SUBI', 'ADDILV', 'SUBILV'
      esc.call(reg_of.call(a))
      dest.call(a, UNK)
    when 'GETIDX'
      sink&.read(tracked(reg_of.call(a)), irep, index, '[]') if env.exact_array?(irep, index, a) && (reg_of.call(a) & UNK).zero?
      esc.call(reg_of.call(a + 1))
      dest.call(a, UNK)
    when 'GETIDX0'
      recv = insn.regs[1].to_i
      sink&.read(tracked(reg_of.call(recv)), irep, index, '[]') if env.exact_array?(irep, index, recv) && (reg_of.call(recv) & UNK).zero?
      dest.call(a, UNK)
    when 'SETIDX'
      set_index(index, insn, state, ctx, sink, a)
    when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB' then call(index, insn, state, ctx, sink, out, dest, esc)
    when 'SUPER', 'BLKCALL', 'EXEC_NEVER'
      call_window(insn, ctx).each { |r| esc.call(reg_of.call(r)) }
      dest.call(a, UNK)
    else
      raise "ArrayCells: unmodelled op #{op}"
    end
    out
  end

  def array_literal(index, insn, state, ctx, sink, out, dest, esc)
    env = ctx[:env]
    a = insn.reg.to_i
    two = insn.typed.length == 3
    base = two ? insn.regs[1].to_i : a
    count = two ? insn.typed[2].value : insn.uint_operand.to_i
    token = env.token([:alloc, ctx[:irep].label, index])
    sink&.alloc(token, ctx[:irep], index, count)
    (0...count).each do |k|
      r = base + k
      mask = r < ctx[:nregs] ? state[r] : UNK
      sink&.write(1 << token, ctx[:irep], index, r, false)
      sink&.escape(tracked(mask)) if tracked(mask).nonzero?
    end
    dest.call(a, 1 << token)
  end

  def push_write(index, state, ctx, sink, recv_reg, value_reg)
    return unless sink

    mask = state[recv_reg]
    sink.write(tracked(mask), ctx[:irep], index, value_reg, false) if tracked(mask).nonzero?
  end

  # `a + b`: Array#+ makes a fresh Array; any other operand class is not ours.
  def binary_operator(index, insn, state, ctx, sink, out, dest, esc, name)
    a = insn.reg.to_i
    b = insn.paren_reg.to_i
    env = ctx[:env]
    recv = state[a]
    if tracked(recv).nonzero? && (recv & UNK).zero? && env.exact_array?(ctx[:irep], index, a) && env.array_method_safe?(name) &&
       env.mask(ctx[:irep], index, b) == NumericFlow::ARR && (state[b] & UNK).zero?
      token = env.token([:alloc, ctx[:irep].label, index])
      sink&.alloc(token, ctx[:irep], index, :derived)
      sink&.edge(tracked(recv), token, :subset)
      sink&.edge(tracked(state[b]), token, :subset)
      dest.call(a, 1 << token)
    else
      esc.call(recv)
      esc.call(state[b])
      dest.call(a, UNK)
    end
  end

  # SETIDX: R[a][R[a+1]] = R[a+2].
  def set_index(index, insn, state, ctx, sink, a)
    env = ctx[:env]
    irep = ctx[:irep]
    recv = state[a]
    key = state[a + 1]
    value = state[a + 2]
    sink&.escape(tracked(value)) if tracked(value).nonzero? # stored into a container
    sink&.escape(tracked(key)) if tracked(key).nonzero?
    return unless tracked(recv).nonzero?

    if (recv & UNK).zero? && env.exact_array?(irep, index, a) && env.array_method_safe?('[]=') &&
       env.mask(irep, index, a + 1) == NumericFlow::INT
      sink&.write(tracked(recv), irep, index, a + 2, :indexed)
    elsif sink
      # A Range or other index can splice and shrink; a receiver that is not surely an Array is unknown.
      sink.poison(tracked(recv))
    end
  end

  # The registers a call reads: receiver, positional arguments, keyword pairs, block.
  def call_window(insn, _ctx)
    a = insn.reg.to_i
    n = insn.op.end_with?('0') && insn.op.start_with?('S') && insn.op != 'SUPER' ? 0 : nil
    if insn.op == 'SUPER'
      count = insn.n_spec == '*' ? 1 : insn.n_spec.to_i
      nk = insn.nk_spec.nil? ? 0 : (insn.nk_spec == '*' ? 1 : insn.nk_spec.to_i)
      return (a..(a + count + 2 * nk + 1)).to_a
    end
    if insn.op == 'BLKCALL'
      return (a..(a + insn.uint_operand.to_i + 1)).to_a
    end
    n ||= (insn.n_spec == '*' ? 1 : insn.n_spec.to_i)
    n = 0 if insn.op.end_with?('0') && !insn.op.end_with?('B')
    nk = insn.nk_spec.nil? ? 0 : (insn.nk_spec == '*' ? 1 : insn.nk_spec.to_i)
    (a..(a + n + 2 * nk + (insn.op.end_with?('B') ? 1 : 0))).to_a
  end

  def call(index, insn, state, ctx, sink, out, dest, esc)
    env = ctx[:env]
    irep = ctx[:irep]
    nregs = ctx[:nregs]
    a = insn.reg.to_i
    name = insn.sym
    self_call = insn.op.start_with?('SS')
    argc = insn.op.end_with?('0') ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
    window = call_window(insn, ctx)
    recv = a < nregs ? state[a] : UNK
    tracked_recv = tracked(recv)
    handled = false

    if !self_call && argc && insn.nk_spec.nil? || (!self_call && argc && insn.nk_spec == '0')
      if recv == CLASS_ARRAY && name == 'new' && env.array_new_safe?
        handled = array_new(index, insn, state, ctx, sink, out, dest, esc, argc)
      elsif tracked_recv.nonzero? && (recv & UNK).zero? && env.exact_array?(irep, index, a) && env.array_method_safe?(name)
        handled = array_call(index, insn, state, ctx, sink, out, dest, esc, name, argc)
      end
    end
    return if handled

    window.each { |r| esc.call(r < nregs ? state[r] : UNK) }
    ((a + 1)...nregs).each { |r| out[r] = 0 }
    dest.call(a, UNK)
  end

  def fresh_token(index, ctx, sink, len)
    token = ctx[:env].token([:alloc, ctx[:irep].label, index])
    sink&.alloc(token, ctx[:irep], index, len)
    token
  end

  # `Array.new`, `Array.new(n)`, `Array.new(n, v)`, `Array.new(n) { }`, `Array.new(array)`.
  def array_new(index, insn, state, ctx, sink, out, dest, esc, argc)
    env = ctx[:env]
    irep = ctx[:irep]
    a = insn.reg.to_i
    block = insn.op.end_with?('B')
    return false if argc > 2

    args = (1..argc).map { |k| a + k }
    token = fresh_token(index, ctx, sink, nil)
    bit = 1 << token
    if argc.zero?
      # empty
    elsif env.mask(irep, index, args[0]) == NumericFlow::INT
      sink&.alloc_length(token, irep, index, args[0])
      if block then sink&.write_unknown(bit)
      elsif argc == 1 then sink&.write_const(bit, NumericFlow::NIL)
      else
        sink&.write(bit, irep, index, args[1], false)
        esc.call(state[args[1]])
      end
    elsif argc == 1 && env.mask(irep, index, args[0]) == NumericFlow::ARR && (state[args[0]] & UNK).zero? &&
          tracked(state[args[0]]).nonzero? && !block
      sink&.edge(tracked(state[args[0]]), token, :subset)
    else
      sink&.write_unknown(bit)
      args.each { |r| esc.call(state[r]) }
    end
    ((a + 1)...ctx[:nregs]).each { |r| out[r] = 0 }
    dest.call(a, bit)
    true
  end

  def array_call(index, insn, state, ctx, sink, out, dest, esc, name, argc)
    irep = ctx[:irep]
    env = ctx[:env]
    a = insn.reg.to_i
    nregs = ctx[:nregs]
    block = insn.op.end_with?('B')
    recv = tracked(state[a])
    args = (1..argc).map { |k| a + k }
    finish = lambda do |mask|
      ((a + 1)...nregs).each { |r| out[r] = 0 }
      dest.call(a, mask)
      true
    end

    if !block && READERS.key?(name) && READERS[name].include?(argc)
      return false if INDEXED_READERS.include?(name) && env.mask(irep, index, args[0]) != NumericFlow::INT

      args.each { |r| esc.call(state[r]) }
      sink&.read(recv, irep, index, name) if ELEMENT_READERS.include?(name)
      finish.call(UNK)
    elsif ITERATORS.key?(name) && ITERATORS[name][0].include?(argc)
      _argcs, result, params = ITERATORS[name]
      args.each { |r| esc.call(state[r]) }
      if block
        label = block_label(irep, index, insn)
        sink&.iterate(recv, irep, index, label, params) if label
      end
      iterator_result(index, ctx, sink, recv, result, finish)
    elsif WRITERS.key?(name) && !block
      writer(index, insn, state, ctx, sink, recv, name, args, esc)
      finish.call(recv)
    elsif FRESH.key?(name) && FRESH[name][0].include?(argc) && !block
      _argcs, result = FRESH[name]
      if result == :fresh_plus
        return false unless env.mask(irep, index, args[0]) == NumericFlow::ARR && (state[args[0]] & UNK).zero? &&
                            tracked(state[args[0]]).nonzero?

        token = fresh_token(index, ctx, sink, :derived)
        sink&.edge(recv, token, :subset)
        sink&.edge(tracked(state[args[0]]), token, :subset)
        return finish.call(1 << token)
      end
      args.each { |r| esc.call(state[r]) }
      iterator_result(index, ctx, sink, recv, result, finish)
    elsif FRESH_WITH_COUNT.include?(name) && argc == 1 && !block && env.mask(irep, index, args[0]) == NumericFlow::INT
      token = fresh_token(index, ctx, sink, :derived)
      sink&.edge(recv, token, :subset)
      finish.call(1 << token)
    else
      false
    end
  end

  def iterator_result(index, ctx, sink, recv, result, finish)
    case result
    when :self then finish.call(recv)
    when :value then finish.call(UNK)
    when :fresh_unknown
      token = fresh_token(index, ctx, sink, :derived)
      sink&.write_unknown(1 << token)
      sink&.edge(recv, token, :same_length)
      finish.call(1 << token)
    else
      token = fresh_token(index, ctx, sink, :derived)
      sink&.edge(recv, token, result == :fresh_same ? :same : :subset)
      finish.call(1 << token)
    end
  end

  # push / << / unshift ... : every argument becomes an element. insert(i, *v): the index is
  # an argument that must be an Integer, and a large one pads the array with nil.
  def writer(index, insn, state, ctx, sink, recv, name, args, esc)
    irep = ctx[:irep]
    env = ctx[:env]
    values = args
    gap = false
    if WRITERS.fetch(name) == :insert
      values = args.drop(1)
      gap = true
      if args.empty? || env.mask(irep, index, args[0]) != NumericFlow::INT
        sink&.poison(recv)
        return
      end
    elsif WRITERS.fetch(name) == :concat
      args.each do |r|
        if env.mask(irep, index, r) == NumericFlow::ARR && (state[r] & UNK).zero? && tracked(state[r]).nonzero?
          sink&.concat(recv, tracked(state[r]))
        else
          sink&.write_unknown(recv)
          esc.call(state[r])
        end
      end
      return
    end
    values.each do |r|
      sink&.write(recv, irep, index, r, gap ? :gap : false)
      esc.call(state[r])
    end
  end

  # The literal block of a SENDB (the BLOCK right before it), or nil.
  def block_label(irep, index, insn)
    prev = index.positive? ? irep.instructions[index - 1] : nil
    return nil unless prev&.op == 'BLOCK' && insn.plain_fixed_argc? && prev.reg == (insn.reg.to_i + insn.argc + 1).to_s

    idx = prev.block_index
    idx && irep.reps[idx.to_i]
  end
end
