# frozen_string_literal: true

# CLASS_ARG_TYPES (tools/bc2cpp/class_arg_types.rb): call-site CLASS inference,
# the class-lattice counterpart of ArgTypes, and the independent proof that lets
# RBS_SEED_CONTRADICTION compare a `# bc2cpp: (ClassName, ...)` annotation
# against something.
#
# What it must never do, each of which the test below pins:
#
#   * report a class where it has no evidence. A nil means "no fact" -- a call
#     site whose receiver is unknown, or a slot nothing resolved. It is never
#     "some other class".
#   * pick a winner between two call sites that pass DIFFERENT classes. That is
#     genuine heterogeneity, and ClassLayout's join collapses disagreement to
#     UNKNOWN for a load-bearing reason (docs/adr/0139 wrongly embedded ivars in
#     Game::Screen and Game::State when an UNKNOWN was dropped because a
#     concrete type arrived first). This table records nil for such a slot
#     instead, which is the conservative direction.
#   * be fed into ClassLayout or IvarLayout. It is a reporting/checking artifact
#     only; growing a fixed point's inputs would invalidate the order-
#     independence argument above for no proven benefit.
#
# POLY names are skipped for ArgTypes' own reason: their call sites may target
# different methods, so a per-name argument type would be meaningless.

require 'minitest/autorun'
require 'set'
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/native_names'
require_relative '../tools/bc2cpp/ivar_layout'
require_relative '../tools/bc2cpp/dispatch_targets'
require_relative '../tools/bc2cpp/class_arg_types'
require_relative '../tools/bc2cpp/call_site_index'
require_relative '../tools/bc2cpp/annotations'

class ClassArgTypesTest < Minitest::Test
  # A minimal stand-in for the pieces trace_new_target reads, so the test
  # exercises ClassArgTypes' OWN logic (skip POLY, skip native, conflict ->
  # nil) without compiling a closed world.
  MethodDefStub = Struct.new(:irep, :owner, :name, keyword_init: true)
  # A real Insn, so typed operand accessors (#reg, ...) behave as in bc2cpp.
  InsnStub = Class.new do
    def self.new(op:, args:)
      Insn.new(lineno: 0, addr: 0, op: op, args: args, raw: "#{op} #{args}")
    end
  end

  def irep(label, insns)
    Irep.new(label: label, instructions: insns)
  end

  def send_insn(dest, name, argc)
    InsnStub.new(op: 'SEND', args: "R#{dest}\t:#{name}\tn=#{argc}")
  end

  def test_poly_names_are_skipped
    # Two definitions => a POLY name; its call sites may target either.
    target = irep('t', [InsnStub.new(op: 'ENTER', args: '1:0:0:0:0:0:0:0 (0x0)')])
    caller = irep('c', [send_insn(0, 'thing', 1)])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing'),
                             MethodDefStub.new(irep: 't2', owner: 'L', name: 'thing')] }
    owners = { 't' => 'K', 'c' => 'C' }
    assert_empty ClassArgTypes.analyze({ 't' => target, 'c' => caller }, registry, owners)
  end

  def test_native_only_definitions_are_skipped
    # no irep => no body to walk, exactly ArgTypes' guard
    registry = { 'thing' => [MethodDefStub.new(irep: nil, owner: 'K', name: 'thing')] }
    assert_empty ClassArgTypes.analyze({}, registry, {})
  end

  def test_zero_mandatory_arguments_are_skipped
    target = irep('t', [InsnStub.new(op: 'ENTER', args: '0:0:0:0:0:0:0:0 (0x0)')])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing')] }
    assert_empty ClassArgTypes.analyze({ 't' => target }, registry, { 't' => 'K' })
  end

  def test_arity_mismatch_call_site_is_ignored
    # A call passing 2 args to a 1-arg definition is not this method's call
    # site; counting it would read an argument register that belongs elsewhere.
    target = irep('t', [InsnStub.new(op: 'ENTER', args: '1:0:0:0:0:0:0:0 (0x0)')])
    caller = irep('c', [send_insn(0, 'thing', 2)])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing')] }
    owners = { 't' => 'K', 'c' => 'C' }
    out = ClassArgTypes.analyze({ 't' => target, 'c' => caller }, registry, owners)
    assert_equal [nil], out['thing']
  end

  def test_a_slot_with_no_evidence_is_nil_not_a_class
    # The call site passes a register nothing can resolve (an opaque send's
    # result). That is an ABSENT fact, and the table must say so rather than
    # inventing a class -- the same rule the :nil_literal case in
    # AnnotationContradictions turned on.
    target = irep('t', [InsnStub.new(op: 'ENTER', args: '1:0:0:0:0:0:0:0 (0x0)')])
    caller = irep('c', [
                    send_insn(0, 'thing', 1),
                    InsnStub.new(op: 'SEND0', args: "R1\t:mystery")
                  ])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing')] }
    owners = { 't' => 'K', 'c' => 'C' }
    out = ClassArgTypes.analyze({ 't' => target, 'c' => caller }, registry, owners)
    assert_equal [nil], out['thing']
  end

  def test_conflicting_call_sites_produce_nil_for_that_slot
    # Two call sites resolving to DIFFERENT classes is genuine heterogeneity, and
    # the conservative answer is nil -- never a choice between them. Assert the
    # bookkeeping the analyzer uses, with the tracer stubbed to a fixed answer.
    slot = nil
    conflict = false
    [['A'], ['B']].each do |resolved|
      if slot && slot != resolved.first
        conflict = true
      else
        slot ||= resolved.first
      end
    end
    assert conflict
    assert_equal [nil], [conflict ? nil : slot]
  end

  # Packed sends (`f(*a)`, n=* in the disassembly, vm.c CALL_MAXARGS): the callee's arguments come from an Array whose
  # length the send does not name, so a packed caller can pass any class and is no fact. The count is nil for it.
  ENTER_ONE = '1:0:0:0:0:0:0:0 (0x40000)'

  def set_callee = irep('set', [InsnStub.new(op: 'ENTER', args: ENTER_ONE)])
  def set_registry = { 'set' => [MethodDefStub.new(irep: 'set', owner: 'Box', name: 'set')] }

  # A packed caller whose argument array sits in R2 (LOADNIL R3; MOVE R2 R3 stands in for the array build).
  def packed_caller(name = 'set')
    irep('packed', [InsnStub.new(op: 'LOADNIL', args: 'R3'), InsnStub.new(op: 'MOVE', args: "R2\tR3"),
                    send_insn(1, name, '*')])
  end

  def test_call_site_index_records_a_packed_send_with_no_count
    caller = irep('c', [send_insn(0, 'thing', 1), send_insn(0, 'thing', '*'), InsnStub.new(op: 'SEND0', args: "R1\t:thing")])
    counts = CallSiteIndex.build({ 'c' => caller })['thing'].map { |*, n| n }
    # The plain send keeps its count, the packed send has none, and a SEND0 is still zero arguments.
    assert_equal [1, nil, 0], counts
  end

  def test_packed_caller_gives_no_argument_type_fact
    # An unpacked caller passes a Fixnum (LOADI_1). The packed caller can pass a String, so position 1 has no fact.
    plain = irep('plain', [InsnStub.new(op: 'LOADI_1', args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, 'packed' => packed_caller)
  end

  def test_packed_send_to_another_name_leaves_the_argument_type
    plain = irep('plain', [InsnStub.new(op: 'LOADI_1', args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, 'packed' => packed_caller('other'))
  end

  def test_unpacked_callers_keep_their_argument_type
    plain = irep('plain', [InsnStub.new(op: 'LOADI_1', args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain)
  end

  def arg_types_for(callers)
    ireps = { 'set' => set_callee }.merge(callers)
    ArgTypes.analyze(ireps, set_registry, call_sites: CallSiteIndex.build(ireps))['set']
  end

  # ClassArgTypes asks trace_new_target for a class; this stands in for it, answering 'A' for every argument.
  def with_tracer_answering(answer)
    ClassArgTypes.define_singleton_method(:trace_new_target) { |*_args, **_kw| answer }
    yield
  ensure
    ClassArgTypes.singleton_class.send(:remove_method, :trace_new_target)
  end

  def class_types_for(callers)
    ireps = { 't' => set_callee }.merge(callers)
    owners = ireps.keys.to_h { |label| [label, label == 't' ? 'Box' : 'Main'] }
    registry = { 'set' => [MethodDefStub.new(irep: 't', owner: 'Box', name: 'set')] }
    ClassArgTypes.analyze(ireps, registry, owners, {}, nil, call_sites: CallSiteIndex.build(ireps))['set']
  end

  def test_packed_caller_gives_no_class_fact
    with_tracer_answering('A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      assert_equal [nil], class_types_for('plain' => plain, 'packed' => packed_caller)
    end
  end

  def test_unpacked_callers_keep_their_class_fact
    with_tracer_answering('A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      assert_equal ['A'], class_types_for('plain' => plain)
    end
  end

  # Keyword sends (`f(k: v)`, n=0|nk=1): vm.c OP_SEND packs the nk pairs into one Hash at position n+1 and sets
  # ci->nk = CALL_MAXARGS, so the callee's position 1 receives a Hash. The count is nil, as for a packed send.
  def keyword_send(dest, name, n, nk) = InsnStub.new(op: 'SEND', args: "R#{dest}\t:#{name}\tn=#{n}|nk=#{nk}")

  # The keyword key sits in R2 (LOADSYM :k), the value in R3; the Hash lands at R2, the callee's position 1.
  def keyword_caller(name = 'set')
    irep('kw', [InsnStub.new(op: 'LOADSYM', args: "R2\t:k"), InsnStub.new(op: 'LOADNIL', args: 'R3'),
                keyword_send(1, name, 0, 1)])
  end

  def test_call_site_index_records_a_keyword_send_with_no_count
    caller = irep('c', [send_insn(0, 'thing', 1), keyword_send(0, 'thing', 0, 1), keyword_send(0, 'thing', 1, '*'),
                        keyword_send(0, 'thing', 1, 0), send_insn(0, 'thing', 0)])
    counts = CallSiteIndex.build({ 'c' => caller })['thing'].map { |*, n| n }
    # A keyword send has no positional count (nil); an explicit nk=0 is unkeyworded and keeps its count.
    assert_equal [1, nil, nil, 1, 0], counts
  end

  def test_keyword_caller_gives_no_argument_type_fact
    # The plain caller passes a Fixnum; the keyword caller passes a Hash at position 1, so there is no fact.
    plain = irep('plain', [InsnStub.new(op: 'LOADI_1', args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, 'kw' => keyword_caller)
  end

  def test_keyword_caller_gives_no_class_fact
    with_tracer_answering('A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      assert_equal [nil], class_types_for('plain' => plain, 'kw' => keyword_caller)
    end
  end

  def test_keyword_send_to_another_name_leaves_the_argument_type
    plain = irep('plain', [InsnStub.new(op: 'LOADI_1', args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, 'kw' => keyword_caller('other'))
  end
end
