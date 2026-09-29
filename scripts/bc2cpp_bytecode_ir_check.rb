#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit checks for the instruction-level queries the block-region recognizers
# build on (tools/bc2cpp/bytecode_ir_regions.rb), over hand-built ireps so the
# expected answers are fixed independent of any compiled gem.
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir_regions'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = ->(list) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list)) }

# A block-carrying call `R2.each { }` with a MOVE chain feeding the receiver.
call = [
  insn(0, 'MOVE', "R3\tR1"),
  insn(3, 'MOVE', "R2\tR3"),
  insn(6, 'BLOCK', "R3\tI[0]"),
  insn(9, 'SENDB', "R2\t:each\tn=0"),
  insn(12, 'SSENDB', "R4\t:map\tn=0"),
  insn(16, 'RETURN', 'R2')
]
p = program.call(call)

pairs = p.adjacent_pairs('BLOCK', %w[SENDB SSENDB]).to_a
check.call('adjacent pair is BLOCK + SENDB', pairs.map { |a, b, i| [a.op, b.op, i] } == [['BLOCK', 'SENDB', 3]])
check.call('SSENDB after a SENDB is not paired', p.adjacent_pairs('BLOCK', %w[SSENDB]).to_a.empty?)
check.call('op? finds present op', p.op?('SENDB', 'BREAK'))
check.call('op? rejects absent ops', !p.op?('BREAK', 'RETURN_BLK'))
check.call('instructions_with_op keeps program order',
           p.instructions_with_op('SSENDB', 'MOVE').map(&:addr) == [0, 3, 12])
seen = []
p.each_with_op('BLOCK', 'RETURN') { |source, index| seen << [source.addr, index] }
check.call('each_with_op yields source and index', seen == [[6, 2], [16, 5]])
check.call('previous of entry is nil', p.previous(0).nil?)
check.call('previous is the linear predecessor', p.previous(3).op == 'BLOCK')

root = p.copy_root(2, '2')
check.call('copy_root follows MOVE chain to the parameter register', root.reg == '1' && root.writer.nil?)
written = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')])
root = written.copy_root(1, '2')
check.call('copy_root reports a non-MOVE writer', root.reg == '1' && root.writer.op == 'LOADI_1')
check.call('copy_root of an unwritten register is itself',
           written.copy_root(1, '7').then { |r| r.reg == '7' && r.writer.nil? })
check.call('copy_root ignores writes after the start index', written.copy_root(0, '2').writer.nil?)
check.call('copy_root of nil is nil', written.copy_root(1, nil).nil?)
check.call('copy_root before the entry is the register itself', written.copy_root(-1, '1').writer.nil?)
no_src = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETNIL', '')])
check.call('copy_root past the end clamps', no_src.copy_root(99, '1').writer.op == 'LOADI_1')

jumps = program.call([
  insn(0, 'JMPNOT', "R1\t9"), insn(4, 'JMP', '9'), insn(6, 'JMPUW', '9'), insn(9, 'RETURN', 'R1')
])
check.call('branch_target_addrs covers every jump op', jumps.branch_target_addrs == Set[9])
dangling = program.call([insn(0, 'JMP', '77'), insn(4, 'RETURN', 'R1')])
check.call('branch_target_addrs keeps a target that is not an instruction', dangling.branch_target_addrs == Set[77])
check.call('dangling target leaves the graph unresolved', !dangling.resolved?)
check.call('branch_target_addrs of straight-line code is empty', p.branch_target_addrs.empty?)

abort("bc2cpp_bytecode_ir_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_bytecode_ir_check OK'
