#!/usr/bin/env ruby
# encoding: UTF-8
# Verify generated IO#puts calls use explicit argv and retain dispatch fallback.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

source_text = <<~'RUBY'
  class PutsCaller
    def one(value); $stdout.puts(value); end
    def none; $stdout.puts; end
  end
RUBY

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    warn "  FAIL #{what}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'puts.rb')
  File.write(source, source_text)
  c_dump, disasm = run_mrbc(source, 'bc2cpp_puts_model', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_puts_model')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  gen = CodeGen.new(ireps, registry, {}, {}, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  %w[one none].each do |method_name|
    method = registry.fetch(method_name).find { |md| md.owner == 'PutsCaller' }
    irep = ireps.fetch(method.irep)
    send_insn = irep.instructions.find { |insn| insn.op.start_with?('SEND') && insn.args.include?(':puts') }
    raise "#{method_name}: no puts SEND" unless send_insn

    code = gen.compile_insn(send_insn, irep, method, irep.instructions.index(send_insn))
    check.call("#{method_name} uses the explicit-argv IO#puts model", code.include?('mrb_io_puts_direct(M,'))
    check.call("#{method_name} retains ordinary Ruby dispatch when the target differs",
               code.include?('mrb_funcall(M,') && code.include?('"puts"'))
  end
end

if failures.empty?
  puts 'bc2cpp IO#puts model check: PASS'
else
  warn "bc2cpp IO#puts model check: #{failures.size} failure(s)"
  exit 1
end
