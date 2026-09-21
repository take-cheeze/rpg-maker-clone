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
  class Hash
    def bc2cpp_test_hash_owner; end
  end
  module Game
    class Actor
      def name; :actor; end
    end
    class Picture
      def picture_only; :picture; end
    end
    class OtherPicture
      def picture_only; :other_picture; end
    end
    class Other
      def name; :other; end
      def alive?; true; end
      def drop_id; 0; end
      def drop_prob; 0; end
    end
    class OtherActors
      def [](id); nil; end
    end
    class Enemy
      def drop_id; 1; end
      def drop_prob; 100; end
    end
    class Troop
      # bc2cpp: (Array<Game::Enemy>)
      def initialize(members); @members = members; end
      # bc2cpp: () -> Array<Game::Enemy>
      def live_members; @members; end
      def drops(rng)
        live_members.each_with_object([]) do |enemy, out|
          next unless enemy.drop_id && enemy.drop_id > 0
          out << enemy.drop_id if rng.random(100) < enemy.drop_prob
        end
      end
    end
    class Actors
      # bc2cpp: (fixnum) -> Game::Actor
      def [](id); nil; end
      # bc2cpp: (fixnum) -> Game::Actor
      def existing(id); nil; end
    end
    class Battle
      Combatant = Struct.new(:hp) do
        def alive?; hp > 0; end
      end
    end
    class EmptyRoute
      def empty?; false; end
    end
    class EmptyRouteCaller
      def fresh_route_empty?; Game::EmptyRoute.new.empty?; end
      def unknown_empty?(value); value.empty?; end
    end
    class HashValueOwner
      def initialize
        @sprites = {}
        @sprites[1] = Game::Actor.new
        @unknown = {}
      end
      def sprite_names_fallback
        @sprites.each_value do |sprite|
          sprite.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
      def unknown_names_fallback
        @unknown.each_value do |sprite|
          sprite.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
    end
    class HashPictureOwner
      # bc2cpp: (Hash<Game::Picture>, fixnum, fixnum)
      def picture_name(pictures, id, unused); pictures[id].picture_only; end
      # An untyped hash must retain dynamic result dispatch.
      def unknown_picture_name(pictures, id); pictures[id].picture_only; end
    end
    class Party
      # bc2cpp: (Array<Game::Battle::Combatant>)
      def initialize(combatants); @combatants = combatants; end
      def fetch(id); @roster[id].name; end
      def first; @roster[0].name; end
      # bc2cpp: () -> Array<Game::Actor>
      def targets; @actors; end
      def target_names_each; targets.each { |actor| actor.name }; end
      def target_names_any; targets.any? { |actor| actor.name }; end
      def target_names_fallback
        targets.each do |actor|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
      def target_names_each_with_object_fallback
        targets.each_with_object([]) do |actor, out|
          actor.name
          out.size
          begin
            1 / 0
          rescue ZeroDivisionError
            out
          end
        end
      end
      def untyped_names_fallback
        @untyped.each do |actor|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            nil
          end
        end
      end
      def target_names_each_with_index_fallback
        targets.each_with_index do |actor, index|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            index
          end
        end
      end
      def untyped_names_each_with_index_fallback
        @untyped.each_with_index do |actor, index|
          actor.name
          begin
            1 / 0
          rescue ZeroDivisionError
            index
          end
        end
      end
      def untyped_each_with_object_fallback
        @untyped.each_with_object([]) do |actor, out|
          actor.name
          out.size
          begin
            1 / 0
          rescue ZeroDivisionError
            out
          end
        end
      end
      def existing_name; @roster.existing(1).name; end
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
  class_layout = { 'Game::Party' => { 'roster' => 'Actors', 'actors' => 'Array', 'untyped' => 'Array',
                                     'combatants' => 'Array' },
                  'Game::HashValueOwner' => { 'sprites' => 'Hash', 'unknown' => 'Hash' } }
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  party_init = registry['initialize'].find { |md| md.owner == 'Game::Party' }
  check.call('Array<Klass> argument keeps the Array receiver type',
             class_annotations.fetch(party_init.irep).args.first == 'Array', true)
  check.call('Array<Klass> argument records its element class',
             annotations.fetch(party_init.irep).arg_elements.first == 'Game::Battle::Combatant', true)
  picture_method = registry['picture_name'].find { |md| md.owner == 'Game::HashPictureOwner' }
  check.call('Hash<Klass> argument records exact Hash/value types',
             class_annotations.fetch(picture_method.irep).args.first == 'Hash' &&
             annotations.fetch(picture_method.irep).arg_elements.first == 'Game::Picture' &&
               annotations.fetch(picture_method.irep).arg_containers.first == 'Hash', true)
  element_layout = ArrayElementLayout.known(
    ArrayElementLayout.analyze(ireps, registry, class_layout, class_annotations, annotations)
  )
  hash_element_layout = HashElementLayout.known(
    HashElementLayout.analyze(ireps, registry, class_layout, class_annotations, annotations, element_layout)
  )
  gen = CodeGen.new(ireps, registry, {}, class_layout, class_annotations, {}, {}, element_layout, annotations, {},
                    hash_element_layout, Set.new)

  picture_irep = ireps.fetch(picture_method.irep)
  picture_send_idx = picture_irep.instructions.index { |insn| insn.op == 'SEND0' && insn.args.include?(':picture_only') }
  picture_code = gen.compile_send(picture_irep.instructions[picture_send_idx].args, self_implicit: false,
                                  irep: picture_irep, idx: picture_send_idx, owner_def: picture_method)
  check.call('Hash<Klass> indexed value calls use guarded typed accessor dispatch',
             picture_code.include?('TYPED :picture_only -> Game::Picture') &&
               picture_code.include?('mrb_obj_class(M, r') && picture_code.include?('mrb_funcall(M,'), true)

  unknown_method = registry['unknown_picture_name'].find { |md| md.owner == 'Game::HashPictureOwner' }
  unknown_irep = ireps.fetch(unknown_method.irep)
  unknown_send_idx = unknown_irep.instructions.index { |insn| insn.op == 'SEND0' && insn.args.include?(':picture_only') }
  unknown_code = gen.compile_send(unknown_irep.instructions[unknown_send_idx].args, self_implicit: false,
                                  irep: unknown_irep, idx: unknown_send_idx, owner_def: unknown_method)
  check.call('untyped Hash indexed values retain ordinary dispatch',
             !unknown_code.include?('TYPED :picture_only -> Game::Picture#picture_only') &&
               unknown_code.include?('mrb_funcall(M,'), true)

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
  %w[target_names_each target_names_any].each do |method_name|
    method = registry[method_name].find { |md| md.owner == 'Game::Party' }
    irep = ireps.fetch(method.irep)
    code = gen.compile_method(method.irep).fetch(:code)
    check.call("#{method_name}: typed array return devirtualizes block element with guard/fallback",
               code.include?('ELEMENT :name -> Game::Actor#name') &&
                 code.include?('mrb_obj_class(M, r') && code.include?('mrb_funcall(M,'), true)
  end

  fallback = registry['target_names_fallback'].find { |md| md.owner == 'Game::Party' }
  fallback_code = gen.compile_method(fallback.irep).fetch(:code)
  check.call('fallback Array#each devirtualizes typed elements with guard/fallback',
             fallback_code.include?('BLOCK_FALLBACK :each') &&
               fallback_code.include?('ELEMENT :name -> Game::Actor#name') &&
               fallback_code.include?('mrb_obj_class(M, r') && fallback_code.include?('mrb_funcall(M,'), true)

  untyped = registry['untyped_names_fallback'].find { |md| md.owner == 'Game::Party' }
  untyped_code = gen.compile_method(untyped.irep).fetch(:code)
  check.call('fallback Array#each leaves unknown elements dynamic',
             untyped_code.include?('BLOCK_FALLBACK :each') &&
               !untyped_code.include?('ELEMENT :name -> Game::Actor#name'), true)

  indexed_fallback = registry['target_names_each_with_index_fallback'].find { |md| md.owner == 'Game::Party' }
  indexed_fallback_code = gen.compile_method(indexed_fallback.irep).fetch(:code)
  check.call('fallback Array#each_with_index devirtualizes typed elements with guard/fallback',
             indexed_fallback_code.include?('BLOCK_FALLBACK :each_with_index') &&
               indexed_fallback_code.include?('ELEMENT :name -> Game::Actor#name') &&
               indexed_fallback_code.include?('mrb_obj_class(M, r') &&
               indexed_fallback_code.include?('mrb_funcall(M,'), true)

  untyped_indexed_fallback = registry['untyped_names_each_with_index_fallback'].find do |md|
    md.owner == 'Game::Party'
  end
  untyped_indexed_fallback_code = gen.compile_method(untyped_indexed_fallback.irep).fetch(:code)
  check.call('fallback Array#each_with_index leaves unknown elements dynamic',
             untyped_indexed_fallback_code.include?('BLOCK_FALLBACK :each_with_index') &&
             !untyped_indexed_fallback_code.include?('ELEMENT :name -> Game::Actor#name'), true)

  each_with_object = registry['target_names_each_with_object_fallback'].find { |md| md.owner == 'Game::Party' }
  each_with_object_code = gen.compile_method(each_with_object.irep).fetch(:code)
  check.call('fallback Array#each_with_object devirtualizes typed elements only',
             each_with_object_code.include?('BLOCK_FALLBACK :each_with_object') &&
               each_with_object_code.include?('ELEMENT :name -> Game::Actor#name') &&
               each_with_object_code.include?('mrb_obj_class(M, r') &&
               each_with_object_code.include?('mrb_funcall(M,'), true)

  drops = registry['drops'].find { |md| md.owner == 'Game::Troop' }
  drops_code = gen.compile_method(drops.irep).fetch(:code)
  check.call('fallback each_with_object resolves a bare annotated Array return',
             drops_code.include?('BLOCK_FALLBACK :each_with_object') &&
               drops_code.include?('ELEMENT :drop_id -> Game::Enemy#drop_id') &&
               drops_code.include?('ELEMENT :drop_prob -> Game::Enemy#drop_prob') &&
               drops_code.include?('mrb_obj_class(M, r') && drops_code.include?('mrb_funcall(M,'), true)

  untyped_each_with_object = registry['untyped_each_with_object_fallback'].find { |md| md.owner == 'Game::Party' }
  untyped_each_with_object_code = gen.compile_method(untyped_each_with_object.irep).fetch(:code)
  check.call('fallback Array#each_with_object leaves unknown elements dynamic',
             untyped_each_with_object_code.include?('BLOCK_FALLBACK :each_with_object') &&
             !untyped_each_with_object_code.include?('ELEMENT :name -> Game::Actor#name'), true)
  # The real build's mruby core registry contributes this native marker.
  # Keep it local to these checks so the known receiver exercises the same
  # empty? intrinsic ordering as a shipped build.
  empty_registry = registry.transform_values(&:dup)
  (empty_registry['empty?'] ||= []) << MethodDef.new(name: 'empty?', owner: '<native>', irep: nil,
                                                      visibility: :public)
  empty_gen = CodeGen.new(ireps, empty_registry, {}, class_layout, class_annotations, {}, {}, element_layout,
                          annotations, {}, {}, Set.new)
  fresh_empty = empty_registry['fresh_route_empty?'].find { |md| md.owner == 'Game::EmptyRouteCaller' }
  fresh_empty_code = empty_gen.compile_method(fresh_empty.irep).fetch(:code)
  check.call('typed Ruby empty? target takes priority over built-in container intrinsic',
             fresh_empty_code.include?('TYPED :empty? -> Game::EmptyRoute#empty?') &&
               fresh_empty_code.include?('mrb_obj_class(M, r') && fresh_empty_code.include?('mrb_funcall(M,'), true)

  unknown_empty = empty_registry['unknown_empty?'].find { |md| md.owner == 'Game::EmptyRouteCaller' }
  unknown_empty_code = empty_gen.compile_method(unknown_empty.irep).fetch(:code)
  check.call('unknown empty? receiver retains built-in container intrinsic and fallback',
             unknown_empty_code.include?('empty? -- exact built-in containers only') &&
               unknown_empty_code.include?('mrb_funcall(M,'), true)
  hash_values = registry['sprite_names_fallback'].find { |md| md.owner == 'Game::HashValueOwner' }
  hash_values_code = gen.compile_method(hash_values.irep).fetch(:code)
  check.call('fallback Hash#each_value devirtualizes proven values with guard/fallback',
             hash_values_code.include?('BLOCK_FALLBACK :each_value') &&
               hash_values_code.include?('ELEMENT :name -> Game::Actor#name') &&
               hash_values_code.include?('mrb_obj_class(M, r') &&
               hash_values_code.include?('mrb_funcall(M,'), true)

  unknown_hash_values = registry['unknown_names_fallback'].find { |md| md.owner == 'Game::HashValueOwner' }
  unknown_hash_values_code = gen.compile_method(unknown_hash_values.irep).fetch(:code)
  check.call('fallback Hash#each_value leaves unknown values dynamic',
             unknown_hash_values_code.include?('BLOCK_FALLBACK :each_value') &&
               !unknown_hash_values_code.include?('ELEMENT :name -> Game::Actor#name'), true)

  method = registry['existing_name'].find { |md| md.owner == 'Game::Party' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('annotated cached lookup devirtualizes subsequent Actor dispatch',
             code.include?('TYPED :name -> Game::Actor#name') &&
               code.include?('mrb_obj_class(M, r') && code.include?('mrb_funcall(M,'), true)

  method = registry['combatant_alive'].find { |md| md.owner == 'Game::Party' }
  code = gen.compile_method(method.irep).fetch(:code)
  check.call('typed array argument devirtualizes a Struct element with guard/fallback',
             code.include?('ELEMENT :alive? -> Game::Battle::Combatant#alive?') &&
               code.include?('mrb_obj_class(M, r') && code.include?('mrb_funcall(M,'), true)
end

if failures.empty?
  puts 'bc2cpp annotated return/container-argument devirtualization check: PASS'
else
  warn "bc2cpp annotated return/container-argument devirtualization check: #{failures.size} failure(s)"
  exit 1
end
