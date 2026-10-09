#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin walk over ops that write above their leading register (vm.c, pinned mruby 67a569ed):
# the fallback send of GETIDX0, SETIDX and the operator ops (L_SEND_SYM writes nil into R(a+2)),
# BLKCALL (clears every register above its arguments) and ENTER (rest, keyword and block slots, which ENTER
# stores: typed definitions in the origin walk; post and locals refuse). Each one has a positive case (the origin
# walk refuses where the write is possible, or types the ENTER's own write) and a negative case (the answer stays
# exact where vm.c writes nothing else). Codegen's default walk is not changed: it still answers as the audited
# model did, and this check pins that too.
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
check.call('GETIDX0 fallback: the default walk refuses too (codegen, ORIGIN_FRAME_OPS)', defs_of.call(getidx0, 2, '2').nil?)
check.call('GETIDX0: a read of its leading register is defined by it (negative)',
           defs_of.call(getidx0, 2, '1', origin_transfers: true) == [1])

# ADD R0 (R1): the fallback sends with nil in R(a+2), so R2 has the LOADI and the ADD as writers.
add = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'ADD', "R0\t(R1)"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('ADD fallback writes R[a+2]: origin walk refuses a read of it', add.reaching_definitions(2, '2', origin_transfers: true).nil?)
check.call('ADD fallback: the default walk refuses too (codegen, ORIGIN_FRAME_OPS)', defs_of.call(add, 2, '2').nil?)
check.call('ADD: its leading register is still defined by it (negative)',
           defs_of.call(program.call([insn(0, 'LOADI_5', 'R0 (5)'), insn(2, 'ADD', "R0\t(R1)"), insn(4, 'MOVE', "R3\tR0"), insn(6, 'RETURN', 'R3')]), 2, '0', origin_transfers: true) == [1])

# BLKCALL R1 0: the block frame starts at R1 and clears R2.. above its argument, so a read of R5 may be nil.
blk = program.call([insn(0, 'LOADI_5', 'R5 (5)'), insn(2, 'BLKCALL', "R1\t0"), insn(4, 'MOVE', "R6\tR5"), insn(6, 'RETURN', 'R6')])
check.call('BLKCALL clears registers above its arguments: origin walk refuses a read above it',
           blk.reaching_definitions(2, '5', origin_transfers: true).nil?)
check.call('BLKCALL: the default walk refuses too (codegen, since BLKCALL joined CALLEE_FRAME_OPS)', defs_of.call(blk, 2, '5').nil?)
check.call('BLKCALL: a register below its frame is untouched (negative)',
           defs_of.call(program.call([insn(0, 'LOADI_5', 'R0 (5)'), insn(2, 'BLKCALL', "R1\t0"), insn(4, 'MOVE', "R6\tR0"), insn(6, 'RETURN', 'R6')]), 2, '0', origin_transfers: true) == [0])

# ENTER stores its rest, keyword-hash and block slots (vm.c OP_ENTER, 3rd/mruby/src/vm.c:2710-2741). The origin walk
# answers each of them with the ENTER as the writer, typed by what it stores (Definition#built). Codegen's default walk
# does not change: it still passes ENTER and answers the entry value, and write_dominates? keeps its answers.
built_of = lambda do |prog, index, reg|
  found = prog.reaching_definitions(index, reg, origin_transfers: true)
  found && found.map(&:built)
end

# Rest slot R1 of "0:0:1" (req 0, rest 1): the Array ENTER builds.
rest = program.call([insn(0, 'ENTER', "0:0:1:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')])
check.call('ENTER rest slot: origin walk types it as the ENTER-built Array',
           built_of.call(rest, 1, '1') == [:rest] && defs_of.call(rest, 1, '1', origin_transfers: true) == [0])
check.call('ENTER rest slot: the MOVE chain reaches the same typed definition (origin)', built_of.call(rest, 2, '2') == [:rest])
check.call('ENTER rest slot: codegen default walk still answers the entry value', defs_of.call(rest, 1, '1') == [:entry])
check.call('ENTER rest slot: write_dominates? keeps the codegen answer (entry dominates)',
           rest.write_dominates?(BytecodeIR::ENTRY, 1, '1') && !rest.write_dominates?(0, 1, '1'))

# Keyword hash R2 of "1:0:0:0:1:0:0:0" (req 1, keywords): the Hash ENTER builds (kd, vm.c:2741).
kwhash = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR2"), insn(4, 'RETURN', 'R4')])
check.call('ENTER keyword hash slot: origin walk types it as the ENTER-built Hash', built_of.call(kwhash, 1, '2') == [:hash])
check.call('ENTER keyword hash slot: codegen default walk still answers the entry value', defs_of.call(kwhash, 1, '2') == [:entry])

# Block slot R2 of "1:0:0:0:0:0:1:0" (req 1, block, no keywords): the block ENTER stores (vm.c:2736).
block = program.call([insn(0, 'ENTER', "1:0:0:0:0:0:1:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER block slot without keywords: origin walk types it as the block', built_of.call(block, 1, '2') == [:block])
check.call('ENTER block slot: codegen default walk still answers the entry value', defs_of.call(block, 1, '2') == [:entry])

# Block slot R3 after the keyword hash R2 of "1:0:0:0:1:0:1:0" (kd 1: the block is at len+kd+1 = 3).
blockslot = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:1:0\t(0x0)"), insn(2, 'MOVE', "R4\tR3"), insn(4, 'RETURN', 'R4')])
check.call('ENTER block slot after the keyword hash: origin walk types R3 as the block', built_of.call(blockslot, 1, '3') == [:block])
check.call('ENTER keyword hash is R2, not the block: origin walk types R2 as the hash', built_of.call(blockslot, 1, '2') == [:hash])
check.call('ENTER block slot: codegen default walk still answers the entry value', defs_of.call(blockslot, 1, '3') == [:entry])

# Post argument R3 of "1:0:1:1:0:0:0:0" (req 1, rest, post 1): the entered argument, or nil when none was passed.
# That is neither a required value nor an Array, Hash or block, so the origin walk refuses it; the rest slot R2 is typed.
post = program.call([insn(0, 'ENTER', "1:0:1:1:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR3"), insn(4, 'RETURN', 'R4')])
check.call('ENTER post slot: origin walk refuses (not an ENTER-built value)', post.reaching_definitions(1, '3', origin_transfers: true).nil?)
check.call('ENTER post slot: codegen default walk still answers the entry value', defs_of.call(post, 1, '3') == [:entry])
check.call('ENTER post: the rest slot is R2 and stays typed as the Array (origin)', built_of.call(post, 1, '2') == [:rest])

# Local R3 of the block method above: no argument and no ENTER-built value, so the origin walk refuses it.
check.call('ENTER local slot: origin walk refuses (ENTER does not store it)', block.reaching_definitions(1, '3', origin_transfers: true).nil?)

# Negative: required parameters (1 and 2), self and an optional parameter are their entered values; ENTER keeps them exact.
req = program.call([insn(0, 'ENTER', "2:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER required parameter stays the entry value (negative)',
           defs_of.call(req, 1, '2', origin_transfers: true) == [:entry] && built_of.call(req, 1, '2') == [nil])
check.call('ENTER keeps self as the entry value (negative)',
           defs_of.call(req, 1, '0', origin_transfers: true) == [:entry])
optional = program.call([insn(0, 'ENTER', "1:1:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER optional parameter stays the entry value (negative)',
           defs_of.call(optional, 1, '2', origin_transfers: true) == [:entry])

# Negative: with keywords (kw 1) R1 is still a positional parameter, not packed.
kw = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR1"), insn(4, 'RETURN', 'R3')])
check.call('ENTER with keywords keeps R1 as the entry value (negative)',
           defs_of.call(kw, 1, '1', origin_transfers: true) == [:entry])
# Without keywords R1 may hold the packed argument Array (vm.c:2640-2650, argc == 14 with a kdict): the origin walk refuses.
check.call('ENTER without keywords: R1 is refused by the origin walk (possibly packed)',
           req.reaching_definitions(1, '1', origin_transfers: true).nil?)

# APOST and ARGARY write a run (R[a..a+post], R[a..a+1+kd]; BytecodeIR.written_run, vm.c OP_APOST / OP_ARGARY).
# Both walks answer the run exactly: the read of R2 is the write at index 1, which kills LOADI_5 (index 0).
apost = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'APOST', "R1\t0\t1"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('APOST writes R[a..a+post]: both walks see the APOST as the definition of R2',
           defs_of.call(apost, 2, '2', origin_transfers: true) == [1] && defs_of.call(apost, 2, '2') == [1])
check.call('APOST leaves R[a+post+1] to the entry value (both walks)',
           defs_of.call(apost, 2, '3', origin_transfers: true) == [:entry] && defs_of.call(apost, 2, '3') == [:entry])
argary = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'ARGARY', "R1\t0:0:0:0\t(0x0)"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('ARGARY writes R[a..a+1+kd]: both walks see the ARGARY as the definition of R2',
           defs_of.call(argary, 2, '2', origin_transfers: true) == [1] && defs_of.call(argary, 2, '2') == [1])
check.call('ARGARY without kd leaves R[a+2] to the entry value (both walks)',
           defs_of.call(argary, 2, '3', origin_transfers: true) == [:entry] && defs_of.call(argary, 2, '3') == [:entry])

abort("bc2cpp_origin_multiwrite_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_multiwrite_check OK'
