#!/usr/bin/env ruby
# encoding: UTF-8
# Check guarded `[]=` codegen through an exact annotated receiver while
# preserving SETIDX's Array/Hash fast paths and dynamic fallback semantics.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class Cells
      def []=(key, value); :stored; end
    end
    class OtherCells
      def []=(key, value); :other; end
    end
    class World
      def put(key, value); @cells[key] = value; end
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
  source = File.join(dir, 'setidx.rb')
  File.write(source, SRC)
  c_dump, disasm = run_mrbc(source, 'bc2cpp_setidx', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_setidx')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_layout = { 'Game::World' => { 'cells' => 'Cells' } }
  gen = CodeGen.new(ireps, registry, {}, class_layout, {}, {}, {}, {}, annotations, {}, {}, Set.new)

  method = registry.fetch('put').find { |md| md.owner == 'Game::World' }
  irep = ireps.fetch(method.irep)
  idx = irep.instructions.index { |insn| insn.op == 'SETIDX' }
  raise 'put: no SETIDX instruction found' unless idx

  code = gen.compile_insn(irep.instructions[idx], irep, method, idx)
  check.call('SETIDX devirtualizes compiled []= behind an exact-class guard',
             code.include?('TYPED :[]= -> Game::Cells#[]=') && code.include?('mrb_obj_class(M, r'))
  check.call('guard fallback preserves Array/Hash built-in assignment and dynamic []=',
             code.include?('mrb_ary_set(M,') && code.include?('mrb_hash_set(M,') &&
               code.include?('mrb_funcall(M,') && code.include?('"[]=", 2'))
  check.call('typed branch retains compiled []= method result semantics',
             code.include?('TYPED :[]= -> Game::Cells#[]=') && code.match?(/r\d+ = Game__Cells_+impl\(M,/))
end

if failures.empty?
  puts 'bc2cpp SETIDX devirtualization check: PASS'
else
  warn "bc2cpp SETIDX devirtualization check: #{failures.size} failure(s)"
  exit 1
end
