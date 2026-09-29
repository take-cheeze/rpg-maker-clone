#!/usr/bin/env ruby
# frozen_string_literal: true

# Insn operand decoding must ignore mrbc's trailing `; R5:name` comment, and
# BytecodeIR must keep the branch edge of a commented jump.
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }

commented = insn(7, 'JMPIF', "R5\t016\t; R5:quit_on_close")
check.call('commented jump target', commented.jump_target == 16)
check.call('operands strip comment', commented.operands == "R5\t016")
check.call('plain jump target', insn(0, 'JMP', '019').jump_target == 19)
check.call('non-jump has no target', insn(0, 'MOVE', "R1\tR2\t; R2:x").jump_target.nil?)
check.call('non-numeric target', insn(0, 'JMP', 'R5').jump_target.nil?)

irep = Irep.new(label: 't', instructions: [commented, insn(11, 'LOADI_1', 'R5'), insn(16, 'RETURN', 'R5')])
edges = BytecodeIR::Program.new(irep).instruction_at(0).successors
check.call('BytecodeIR keeps commented edge', edges.sort == [1, 2])

abort("bc2cpp_insn_operands_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_insn_operands_check OK'
