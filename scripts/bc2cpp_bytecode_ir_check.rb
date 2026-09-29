#!/usr/bin/env ruby
# frozen_string_literal: true

# BytecodeIR's address-level branch queries behind the rescue/ensure
# recognizers: branch edges, branch targets and region boundary breaches.
require 'set'
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
pairs = ->(edges) { edges.map { |e| [e.src, e.target] } }

# Layout: 0 JMPIF->4 (guard entering region at its first address), region
# body [4, 12) with one internal jump, exit JMP at 12, 16 JMPUW, 20 outside.
irep = Irep.new(label: 't', instructions: [
  insn(0, 'JMPIF', "R1\t4"), insn(4, 'JMPNOT', "R1\t9"), insn(8, 'LOADNIL', 'R1 (nil)'),
  insn(9, 'MOVE', "R2\tR1"), insn(12, 'JMP', '20'), insn(16, 'JMPUW', '20'), insn(20, 'RETURN', 'R1')
])
program = BytecodeIR::Program.new(irep)
check.call('branch_edges in instruction order', pairs.call(program.branch_edges) == [[0, 4], [4, 9], [12, 20], [16, 20]])
check.call('branch_edges without JMPUW', pairs.call(program.branch_edges(jmpuw: false)) == [[0, 4], [4, 9], [12, 20]])
check.call('branch_targets', program.branch_targets == Set[4, 9, 20])
check.call('insn_at_addr', program.insn_at_addr(9).op == 'MOVE' && program.insn_at_addr(10).nil?)
check.call('clean region has no breaches', program.region_boundary_breaches(4...12, 12).empty?)

leaky = Irep.new(label: 't2', instructions: [
  insn(0, 'JMP', '8'), insn(4, 'JMPIF', "R1\t20"), insn(8, 'LOADNIL', 'R1 (nil)'), insn(12, 'JMP', '16'),
  insn(16, 'JMP', '8'), insn(20, 'RETURN', 'R1')
])
breaches = BytecodeIR::Program.new(leaky).region_boundary_breaches(4...12, 12)
check.call('inner branch leaving and outer branch entering', pairs.call(breaches) == [[0, 8], [4, 20], [16, 8]])

unresolved = Irep.new(label: 't3', instructions: [insn(0, 'JMP', '77'), insn(4, 'RETURN', 'R1')])
check.call('branch_edges survive unresolved targets', pairs.call(BytecodeIR::Program.new(unresolved).branch_edges) == [[0, 77]])

abort("bc2cpp_bytecode_ir_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_bytecode_ir_check OK'
