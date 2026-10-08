#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin walk over ops that write above their leading register (vm.c, pinned mruby 67a569ed):
# the fallback send of GETIDX0, SETIDX and the operator ops (L_SEND_SYM writes nil into R(a+2)),
# BLKCALL (clears every register above its arguments) and ENTER (rest, post, keyword and block slots).
# Each one has a positive case (the origin walk refuses where the write is possible) and a negative case
# (the answer stays exact where vm.c writes nothing else). Codegen's default walk is not changed: it still
# answers as the audited model did, and this check pins that too.
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = ->(list) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list, catch_handlers: [])) }
defs_of = lambda do |prog, index, reg, **opts|
  found = prog.reaching_definitions(index, reg, **opts)
  found && found.map { |d| d.entry? ? :entry : d.index }
end

# GETIDX0 R1 = R0[0]: its fallback also writes R2 (= 0) before the send. The read of R2 has two writers
# on two paths: the LOADI (fast path) and the GETIDX0 (fallback). The origin walk must refuse.
getidx0 = program.call([
  insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'GETIDX0', "R1\tR0[0]"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')
])
check.call('GETIDX0 fallback writes R[a+1]: origin walk refuses a read of it', getidx0.reaching_definitions(2, '2', origin_transfers: true).nil?)
check.call('GETIDX0 fallback: the default walk is unchanged (codegen)', defs_of.call(getidx0, 2, '2') == [0])
check.call('GETIDX0: a read of its leading register is defined by it (negative)',
           defs_of.call(getidx0, 2, '1', origin_transfers: true) == [1])

# ADD R0 (R1): the fallback sends with nil in R(a+2), so R2 has the LOADI and the ADD as writers.
add = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'ADD', "R0\t(R1)"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('ADD fallback writes R[a+2]: origin walk refuses a read of it', add.reaching_definitions(2, '2', origin_transfers: true).nil?)
check.call('ADD fallback: the default walk is unchanged (codegen)', defs_of.call(add, 2, '2') == [0])
check.call('ADD: its leading register is still defined by it (negative)',
           defs_of.call(program.call([insn(0, 'LOADI_5', 'R0 (5)'), insn(2, 'ADD', "R0\t(R1)"), insn(4, 'MOVE', "R3\tR0"), insn(6, 'RETURN', 'R3')]), 2, '0', origin_transfers: true) == [1])

# BLKCALL R1 0: the block frame starts at R1 and clears R2.. above its argument, so a read of R5 may be nil.
blk = program.call([insn(0, 'LOADI_5', 'R5 (5)'), insn(2, 'BLKCALL', "R1\t0"), insn(4, 'MOVE', "R6\tR5"), insn(6, 'RETURN', 'R6')])
check.call('BLKCALL clears registers above its arguments: origin walk refuses a read above it',
           blk.reaching_definitions(2, '5', origin_transfers: true).nil?)
check.call('BLKCALL: the default walk is unchanged (codegen)', defs_of.call(blk, 2, '5') == [0])
check.call('BLKCALL: a register below its frame is untouched (negative)',
           defs_of.call(program.call([insn(0, 'LOADI_5', 'R0 (5)'), insn(2, 'BLKCALL', "R1\t0"), insn(4, 'MOVE', "R6\tR0"), insn(6, 'RETURN', 'R6')]), 2, '0', origin_transfers: true) == [0])

# ENTER 0:0:1 (a rest parameter): R1 holds the array ENTER builds, not the entered value.
rest = program.call([insn(0, 'ENTER', "0:0:1:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')])
check.call('ENTER rest slot: origin walk refuses (the array is not the entered value)',
           rest.reaching_definitions(1, '1', origin_transfers: true).nil?)

# Negative: required parameters (1 and 2) are their entered values; ENTER keeps them exact.
req = program.call([insn(0, 'ENTER', "2:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER required parameter stays the entry value (negative)',
           defs_of.call(req, 1, '2', origin_transfers: true) == [:entry])
check.call('ENTER keeps self as the entry value (negative)',
           defs_of.call(req, 1, '0', origin_transfers: true) == [:entry])

# Negative: with keywords (kw 1) R1 is still a positional parameter, not packed.
kw = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR1"), insn(4, 'RETURN', 'R3')])
check.call('ENTER with keywords keeps R1 as the entry value (negative)',
           defs_of.call(kw, 1, '1', origin_transfers: true) == [:entry])

# APOST and ARGARY write a range (R[a..a+c], R[a..a+1+kd]). Neither is on the write list, so both refuse
# under either walk; the origin walk must not guess their write set.
apost = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'APOST', "R1\t0\t1"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('APOST writes R[a..a+post]: both walks refuse a read of R2', apost.reaching_definitions(2, '2', origin_transfers: true).nil? &&
  apost.reaching_definitions(2, '2').nil?)
argary = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'ARGARY', "R1\t0:0:0:0\t(0x0)"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('ARGARY writes R[a..a+1+kd]: both walks refuse a read of R2', argary.reaching_definitions(2, '2', origin_transfers: true).nil? &&
  argary.reaching_definitions(2, '2').nil?)

abort("bc2cpp_origin_multiwrite_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_multiwrite_check OK'
