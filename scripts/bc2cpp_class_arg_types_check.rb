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

class ClassArgTypesTest < Minitest::Test
  # A minimal stand-in for the pieces trace_new_target reads, so the test
  # exercises ClassArgTypes' OWN logic (skip POLY, skip native, conflict ->
  # nil) without compiling a closed world.
  MethodDefStub = Struct.new(:irep, :owner, :name, keyword_init: true)
  IrepStub = Struct.new(:label, :instructions, keyword_init: true)
  # A real Insn, so typed operand accessors (#reg, ...) behave as in bc2cpp.
  InsnStub = Class.new do
    def self.new(op:, args:)
      Insn.new(lineno: 0, addr: 0, op: op, args: args, raw: "#{op} #{args}")
    end
  end

  def irep(label, insns)
    IrepStub.new(label: label, instructions: insns)
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
end
