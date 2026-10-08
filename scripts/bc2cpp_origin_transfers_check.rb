#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin-only transfers (BytecodeIR::Program#origin_effect, used by the
# SiteOriginTable walk with origin_transfers: true; see
# docs/bc2cpp-dynamic-site-census.md). Each transfer has a positive case
# (the walk answers through the op) and a negative case (the answer stays a
# refusal). Codegen never passes origin_transfers:, so the default walk must
# still refuse at these ops.
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = ->(list, handlers = []) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list, catch_handlers: handlers)) }
defs_of = lambda do |prog, index, reg, **opts|
  found = prog.reaching_definitions(index, reg, **opts)
  found && found.map { |d| d.entry? ? :entry : d.index }
end

# JMPUW: a write before an unconditional unwinding jump still reaches the join.
#   0: LOADI_1 R1   1: JMPNOT R9 -> 8   2: JMPUW -> 10   3: LOADI_2 R2 (@8)   4: RETURN R1 (@10)
jmpuw = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'JMPUW', '10'),
  insn(8, 'LOADI_2', 'R2 (2)'), insn(10, 'RETURN', 'R1')
])
check.call('JMPUW: the write before it reaches the join (origin walk)',
           defs_of.call(jmpuw, 4, '1', origin_transfers: true) == [0])
check.call('JMPUW: the default walk still refuses at it', jmpuw.reaching_definitions(4, '1').nil?)

# JMPUW inside a protected range: its ensure unwinding is not modelled, so the origin walk still refuses.
jmpuw_guarded = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'JMPUW', '10'),
  insn(8, 'LOADI_2', 'R2 (2)'), insn(10, 'RETURN', 'R1'), insn(12, 'RETURN', 'R2')
], [CatchHandler.new(type: :ensure, begin_addr: 4, end_addr: 6, target: 12)])
check.call('JMPUW inside a protected range refuses under the origin walk',
           jmpuw_guarded.reaching_definitions(4, '1', origin_transfers: true).nil?)

# RESCUE a b: writes only R[b] (the match result). A query on R[b] is answered by the RESCUE.
#   0: LOADNIL R2   1: LOADNIL R3   2: RESCUE R2 R3   3: JMPNOT R3 -> 10   4: RETURN R1 (@8)   5: RETURN R3 (@10)
rescue_ = program.call([
  insn(0, 'LOADNIL', 'R2 (nil)'), insn(2, 'LOADNIL', 'R3 (nil)'), insn(4, 'RESCUE', "R2\tR3"),
  insn(6, 'JMPNOT', "R3\t10"), insn(8, 'RETURN', 'R1'), insn(10, 'RETURN', 'R3')
])
check.call('RESCUE: the query on its written register is defined by the RESCUE (origin walk)',
           defs_of.call(rescue_, 5, '3', origin_transfers: true) == [2])
check.call('RESCUE: a query on its read-only register passes through to the earlier write',
           defs_of.call(rescue_, 5, '2', origin_transfers: true) == [0])
check.call('RESCUE: the default walk still refuses at it', rescue_.reaching_definitions(5, '3').nil?)

# RESCUE inside a protected range: the walk still refuses at the protected predecessor.
rescue_guarded = program.call([
  insn(0, 'LOADNIL', 'R2 (nil)'), insn(2, 'LOADNIL', 'R3 (nil)'), insn(4, 'RESCUE', "R2\tR3"),
  insn(6, 'JMPNOT', "R3\t10"), insn(8, 'RETURN', 'R1'), insn(10, 'RETURN', 'R3')
], [CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 6, target: 8)])
check.call('RESCUE inside a protected range refuses under the origin walk',
           rescue_guarded.reaching_definitions(5, '3', origin_transfers: true).nil?)

# EXCEPT a: a handler target (guarded) that stores the exception or nil into R[a] on every entry. The walk
# reaches it only from the query, so a use of R[a] right after it is defined by the EXCEPT.
#   0: LOADNIL R1   1: SEND0 R2 (@2, protected [2,3))   2: EXCEPT R3 (@8, handler target)   3: RETURN R3 (@10)
except = program.call([
  insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SEND0', "R2\t:f"), insn(8, 'EXCEPT', 'R3'), insn(10, 'RETURN', 'R3')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 3, target: 8)])
check.call('EXCEPT: a use of its own register is defined by the EXCEPT (origin walk)',
           defs_of.call(except, 3, '3', origin_transfers: true) == [2])
check.call('EXCEPT: the default walk still refuses at the handler target', except.reaching_definitions(3, '3').nil?)
check.call('EXCEPT: a register it does not write is refused (its entry value is unmodelled)',
           except.reaching_definitions(3, '1', origin_transfers: true).nil?)

# Ops outside the origin transfers keep their default answer: an unmodelled op still refuses.
unmodelled = program.call([insn(0, 'EXCEPT', 'R3'), insn(2, 'RETURN', 'R1')])
check.call('an op without an origin transfer still refuses under the origin walk',
           unmodelled.reaching_definitions(1, '1', origin_transfers: true).nil?)

abort("bc2cpp_origin_transfers_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_transfers_check OK'
