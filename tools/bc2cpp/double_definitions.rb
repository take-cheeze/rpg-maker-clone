# frozen_string_literal: true

require 'set'

# DOUBLE_DEFINITIONS (docs/adr/0319): an owner that defines one name twice runs the LAST definition; the
# registry used to keep every one, so each consumer picked its own (a `find` took the first, a C++ symbol was
# emitted twice, an attr_reader's synthesized accessor was registered over a later `define_method`).
#
# settle leaves at most one definition per (owner, name): the last, when it is unconditional, since every
# earlier body is then dead once the class bodies have run (the compiled entries are registered after the
# mrblib load, so a call made between two definitions still runs the interpreter's earlier body). Where the
# last definition cannot be proven to run (a conditional def, or a loop-installed accessor whose position the
# registry does not know) the whole group becomes one body-less marker: the name stays POLY and nothing is
# compiled or registered for it.
module DoubleDefinitions
  Report = Struct.new(:dropped, :withdrawn, keyword_init: true)

  module_function

  # A forward jump over +addr+ makes an instruction there conditional (as CoreDefs.conditional_def_labels).
  def conditional_at?(irep, addr)
    spans = (@spans ||= {}.compare_by_identity)[irep] ||= irep.instructions.filter_map do |insn|
      next unless %w[JMPIF JMPNOT JMPNIL JMP].include?(insn.op)

      target = insn.branch_target
      [insn.addr, target] if target && target > insn.addr
    end
    spans.any? { |from, to| from < addr && addr < to }
  end

  # The body-less stand-in for a name whose definitions cannot be ordered: not an accessor (kind nil), so it
  # also blocks embedding of the ivar of the same name.
  def marker(name, owner, visibility, conditional: false)
    MethodDef.new(name: name, owner: owner, irep: nil, visibility: visibility, conditional: conditional)
  end

  def settle(registry)
    report = Report.new(dropped: [], withdrawn: [])
    gone = Set.new.compare_by_identity
    replaced = {}.compare_by_identity
    registry.each_value do |defs|
      next if defs.size < 2

      defs.group_by(&:owner).each do |owner, group|
        next if group.size < 2 || owner == '<native>' || group.any?(&:core)

        last = group.last
        group[0...-1].each { |d| gone << d }
        if group.any?(&:site) || last.conditional
          replaced[last] = marker(last.name, owner, last.visibility)
          report.withdrawn << "#{owner}##{last.name}"
        else
          report.dropped << "#{owner}##{last.name} (#{group.size - 1} earlier)"
        end
      end
    end
    return report if gone.empty?

    dead = gone.filter_map(&:irep).to_set
    dead.merge(replaced.keys.filter_map(&:irep))
    registry.each_value do |defs|
      defs.map! do |d|
        next replaced[d] if replaced.key?(d)

        # A module_function copy of a body that no longer is the module's method has nothing to compile.
        d.kind == :module_function && d.copy_irep && dead.include?(d.copy_irep) ? marker(d.name, d.owner, d.visibility) : d
      end
      defs.reject! { |d| gone.include?(d) }
    end
    registry.delete_if { |_, defs| defs.empty? }
    report
  end

  # [owner, name] => "$n" for the compiled definitions whose C++ spelling another one already has
  # (`Widget.singleton#make` and `Widget#singleton_make` are both Widget_singleton_make). The first in
  # sorted order keeps the plain spelling, so a program without a clash is unchanged.
  def symbol_suffixes(defs, spell)
    by_symbol = Hash.new { |h, k| h[k] = [] }
    defs.each do |d|
      next unless d.irep || (d.kind == :ivar_accessor && !d.owner.end_with?('.singleton'))

      by_symbol[spell.call(d.owner, d.name)] << [d.owner, d.name]
    end
    by_symbol.each_value.with_object({}) do |pairs, out|
      pairs = pairs.uniq.sort
      pairs.drop(1).each_with_index { |pair, i| out[pair] = "$#{i + 2}" }
    end
  end
end
