#!/usr/bin/env ruby
# encoding: UTF-8
# Exercise annotated return-class tracing through mrbc's dedicated GETIDX
# and GETIDX0 opcodes. Assert the index operation and a following call both
# use guarded TYPED codegen, with the indexed fallback retaining builtin
# container fast paths.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  class Array
    def bc2cpp_test_array_owner; end
  end
  module Game
    class Actor
      def name; :actor; end
    end
    class Other
      def name; :other; end
      def alive?; true; end
    end
    class OtherActors
      def [](id); nil; end
    end
    class Actors
      # bc2cpp: (fixnum) -> Game::Actor
      def [](id); nil; end
    end
    class Battle
      Combatant = Struct.new(:hp) do
        def alive?; hp > 0; end
      end
    end
    class Party
      # bc2cpp: (Array<Game::Battle::Combatant>)
      def initialize(combatants); @combatants = combatants; end
      def fetch(id); @roster[id].name; end
      def first; @roster[0].name; end
      def combatant_alive; @combatants.each { |combatant| combatant.alive? }; end
    end
  end
RUBY

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'retclass.rb')
  File.write(source, SRC)
  c_dump, disasm = run_mrbc(source, 'bc2cpp_retclass', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_retclass')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_layout = { 'Game::Party' => { 'roster' => 'Actors', 'combatants' => 'Array' } }
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  party_init = registry['initialize'].find { |md| md.owner == 'Game::Party' }
  check.call('Array<Klass> argument keeps the Array receiver type',
             class_annotations.fetch(party_init.irep).args.first == 'Array', true)
  check.call('Array<Klass> argument records its element class',
             annotations.fetch(party_init.irep).arg_elements.first == 'Game::Battle::Combatant', true)
  element_layout = ArrayElementLayout.known(
    ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations, annotations)
  )
  gen = CodeGen.new(ireps, registry, {}, class_layout, class_annotations, {}, {}, element_layout, annotations, {},
                    {}, Set.new)

  %w[fetch first].each do |method_name|
    method = registry[method_name].find { |md| md.owner == 'Game::Party' }
    irep = ireps.fetch(method.irep)
    getidx_idx = irep.instructions.index { |insn| insn.op == 'GETIDX' }
    raise "#{method_name}: no GETIDX instruction found" unless getidx_idx

    index_insn = if method_name == 'first'
                   receiver = irep.instructions[getidx_idx].args[/^R(\d+)/, 1]
                   Insn.new(lineno: 1, addr: 0, op: 'GETIDX0', args: "R4 R#{receiver}[0]", raw: '')
                 else
                   irep.instructions[getidx_idx]
                 end
    index_op = index_insn.op
    index_code = gen.compile_insn(index_insn, irep, method, getidx_idx)
    check.call("#{method_name}: #{index_op} devirtualizes annotated [] with guard/fallback",
               index_code.include?('TYPED :[] -> Game::Actors#[]') &&
                 index_code.include?('mrb_obj_class(M, r') && index_code.include?('mrb_array_p(r') &&
                 index_code.include?('mrb_funcall(M,'), true)

    idx = irep.instructions.index { |insn| insn.op == 'SEND0' && insn.args.include?(':name') }
    raise "#{method_name}: no #name send found" unless idx

    code = gen.compile_send(irep.instructions[idx].args, self_implicit: false, irep: irep, idx: idx,
                            owner_def: method)
    check.call("#{method_name}: annotated indexed result devirtualizes with guard/fallback",
               code.include?('TYPED :name -> Game::Actor#name') &&
                 code.include?('mrb_obj_class(M, r') && code.include?('mrb_funcall(M,'), true)
  end

  method = registry['combatant_alive'].find { |md| md.owner == 'Game::Party' }
  code = gen.compile_method(method.irep)
  code = code.fetch(:code)
  check.call('typed array argument devirtualizes a Struct element with guard/fallback',
             code.include?('ELEMENT :alive? -> Game::Battle::Combatant#alive?') &&
               code.include?('mrb_obj_class(M, r') && code.include?('mrb_funcall(M,'), true)
end

if failures.empty?
  puts 'bc2cpp annotated return/array-argument devirtualization check: PASS'
else
  warn "bc2cpp annotated return/array-argument devirtualization check: #{failures.size} failure(s)"
  exit 1
end
