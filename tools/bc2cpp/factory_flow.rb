# frozen_string_literal: true

require_relative 'ir_symbol_flow'

# Uses of a factory constant, including MOVE aliases, over normal and handler edges.
module FactoryFlow
  module_function

  # The work stack is flat: each entry pushes its origin and register
  # separately, and visited states are tracked per origin, so no per-state
  # pair Array is built for traversal or duplicate suppression. LIFO order,
  # duplicate suppression, result insertion order and the alias-budget refusal
  # match the pair-based walk. Returned use pairs keep their representation.
  def uses(irep, index, reg, max_aliases: BytecodeIR::DATAFLOW_MAX_STATES)
    program = BytecodeIR.for(irep)
    work = [index, reg]
    seen = {}
    seen_count = 0
    uses = Set.new
    until work.empty?
      register = work.pop
      origin = work.pop
      by_origin = seen[origin] ||= {}
      next if by_origin.key?(register)

      by_origin[register] = true
      seen_count += 1
      return nil if seen_count > max_aliases

      reads = IrSymbolFlow.value_reads(irep, origin, register) or return nil
      reads.each do |use|
        instruction = program.source_at(use)
        if instruction.op == :MOVE
          work.push(use, instruction.reg)
        else
          uses << [use, register]
        end
      end
    end
    uses
  end
end
