#!/usr/bin/env ruby
# encoding: UTF-8
# Check that OP_ADD/OP_SUB/OP_MUL preserve the fixnum fastpath, mirror mruby's
# Float/Integer operand cases, and keep dynamic operator dispatch as fallback.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class MathOps
      def add(left, right); left + right; end
      def sub(left, right); left - right; end
      def mul(left, right); left * right; end
    end
  end
RUBY

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'float_math.rb')
  File.write(source, SRC)
  c_dump, disasm = run_mrbc(source, 'bc2cpp_float_math', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_float_math')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  gen = CodeGen.new(ireps, registry, {}, {}, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  { 'add' => '+', 'sub' => '-', 'mul' => '*' }.each do |method_name, operator|
    method = registry.fetch(method_name).find { |md| md.owner == 'Game::MathOps' }
    irep = ireps.fetch(method.irep)
    opcode = { '+' => 'ADD', '-' => 'SUB', '*' => 'MUL' }.fetch(operator)
    idx = irep.instructions.index { |insn| insn.op == opcode }
    raise "#{method_name}: no #{opcode} instruction found" unless idx

    insn = irep.instructions[idx]
    dest_reg = insn.args[/^R(\d+)/, 1]
    source_reg = insn.args[/\(R(\d+)\)/, 1]
    code = gen.compile_insn(insn, irep, method, idx)
    arithmetic = operator
    check.call("#{opcode} retains the existing fixnum pair guard",
               code.include?("mrb_fixnum_p(r#{dest_reg}) && mrb_fixnum_p(r#{source_reg})") &&
                 code.include?("mrb_fixnum(r#{dest_reg}) #{arithmetic} mrb_fixnum(r#{source_reg})"))
    check.call("#{opcode} handles Float/Integer with Float/Integer unboxing",
               code.include?("mrb_float_p(r#{dest_reg}) && mrb_integer_p(r#{source_reg})") &&
                 code.include?("mrb_float(r#{dest_reg}) #{arithmetic} mrb_integer(r#{source_reg})"))
    check.call("#{opcode} handles Integer/Float with Integer/Float unboxing",
               code.include?("mrb_integer_p(r#{dest_reg}) && mrb_float_p(r#{source_reg})") &&
                 code.include?("mrb_integer(r#{dest_reg}) #{arithmetic} mrb_float(r#{source_reg})"))
    check.call("#{opcode} handles Float/Float with Float/Float unboxing",
               code.include?("mrb_float_p(r#{dest_reg}) && mrb_float_p(r#{source_reg})") &&
                 code.include?("mrb_float(r#{dest_reg}) #{arithmetic} mrb_float(r#{source_reg})"))
    check.call("#{opcode} boxes Float results and preserves dynamic fallback",
               code.include?('mrb_float_value(M,') && code.include?('mrb_funcall(M,') &&
                 code.include?("\"#{operator}\", 1"))
  end
end

if failures.empty?
  puts 'bc2cpp Float arithmetic fastpath check: PASS'
else
  warn "bc2cpp Float arithmetic fastpath check: #{failures.size} failure(s)"
  exit 1
end
