#!/usr/bin/env ruby
# encoding: UTF-8
# Check that a class argument annotation flows through an ivar to a guarded
# TYPED call site.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class Database
      def edition; :database; end
    end
    class OtherDatabase
      def edition; :other; end
    end
    class Party
      # bc2cpp: (Game::Database)
      def initialize(db); @db = db; end
      def edition; @db.edition; end
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
  source = File.join(dir, 'class_arg.rb')
  File.write(source, SRC)
  c_dump, disasm = run_mrbc(source, 'bc2cpp_class_arg', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_class_arg')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  class_layout = ClassLayout.known(ClassLayout.analyze(ireps, registry, class_annotations))
  gen = CodeGen.new(ireps, registry, {}, class_layout, class_annotations, {}, {}, {}, {}, {}, {}, Set.new)

  method = registry.fetch('edition').find { |md| md.owner == 'Game::Party' }
  irep = ireps.fetch(method.irep)
  idx = irep.instructions.index { |insn| insn.op.start_with?('SEND') && insn.args.include?(':edition') }
  raise 'Party#edition: no #edition send found' unless idx

  check.call('annotated initializer argument becomes a class hint for @db',
             class_layout.dig('Game::Party', 'db') == 'Game::Database')
  code = gen.compile_send(irep.instructions[idx].args, self_implicit: false, irep: irep, idx: idx,
                          owner_def: method)
  check.call('call through @db uses a guarded TYPED target and dynamic fallback',
             code.include?('TYPED :edition -> Game::Database#edition') &&
               code.include?('mrb_obj_class(M, r') && code.include?('mrb_funcall(M,'))
end

if failures.empty?
  puts 'bc2cpp class-argument devirtualization check: PASS'
else
  warn "bc2cpp class-argument devirtualization check: #{failures.size} failure(s)"
  exit 1
end
