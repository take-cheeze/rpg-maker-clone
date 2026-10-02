#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for LOOP_INSTALLERS (docs/adr/0304). Each mutant is a copy of tools/bc2cpp with one
# soundness condition of tools/bc2cpp/loop_installers.rb (or of its closed-world hook) broken;
# scripts/bc2cpp_loop_installers_check.rb, run against the mutant, must FAIL on the negative world
# that guards that condition. A mutant that passes means the condition has no negative case. An unmutated control runs
# first, in the same repository-layout tree, and must pass; a mutant that only crashes is not a kill
# (Bc2cppMutationSupport).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp_loop_installers_mutation_check.rb

require 'rbconfig'
require_relative 'bc2cpp_mutation_support'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL]
MUTANTS = [
  ['a call no longer taints the constants it could reach by name', 'loop_installers.rb',
   '@consts.each_value { |v| LoopInstallers.poison(v) }', 'nil', /a call between the build and the loop/],
  ['a call no longer poisons the operands it was handed', 'loop_installers.rb',
   '(base..(base + span)).each { |r| LoopInstallers.poison(get(r)) }', 'nil', /a mutated local container/],
  ['a constant read no longer taints the constants', 'loop_installers.rb',
   "      else\n        poison_consts\n        @regs[insn.reg.to_i] = OPAQUE\n      end",
   "      else\n        @regs[insn.reg.to_i] = OPAQUE\n      end", /a constant read between the build and the loop/],
  ['a branch no longer ends the straight-line walk', 'loop_installers.rb',
   'limit = i if insn.op.match?(FLOW_OPS) && i < limit', 'nil', /a loop built and run under a branch/],
  ['a back edge no longer ends the straight-line walk', 'loop_installers.rb',
   "        limit = [limit, landing].min if landing\n      end\n      (@irep.catch_handlers || []).each do |h|",
   "      end\n      [].each do |h|", /a loop retried by a rescue/],
  ['a user definition of an iterator or installer is ignored', 'loop_installers.rb',
   '(MODELED_METHODS + ATTR_SENDS).all? do |name|', '[].all? do |name|', /redefined/],
  ['a private default visibility is ignored', 'loop_installers.rb',
   "unless visibility == :public\n", "unless true\n", /a private default visibility/],
  ['a write into the iterated container is allowed', 'loop_installers.rb',
   "refuse('a write into the container being iterated') if @protected.key?(hash)", 'nil',
   /a write into the iterated Hash inside the loop/],
  ['the attribute name is not checked', 'loop_installers.rb',
   'unless arg.name.match?(ATTR_NAME)', 'unless true', /a name that is not an attribute name/],
  ['the block parameter count is not checked', 'loop_installers.rb',
   'first.enter_fields[0] == args.size &&', '', /a one-parameter block over Hash#each|a two-parameter block over an Array/],
  ['a branch on an unknown value takes a side', 'loop_installers.rb',
   "refuse('a branch on a value the interpreter does not know') if value.equal?(OPAQUE)", 'nil',
   /a branch on a value the walk does not know/],
  ['a branch is taken the wrong way', 'loop_installers.rb',
   "when 'JMPNOT' then return truthy(get.call(insn.reg)) ? pc + 1 : jump(irep, insn)",
   "when 'JMPNOT' then return truthy(get.call(insn.reg)) ? jump(irep, insn) : pc + 1", /as CRuby/],
  ['a reader also registers a writer', 'loop_installers.rb',
   'names << "#{name}=" if %i[writer accessor].include?(kind)', 'names << "#{name}=" if true', /as CRuby/],
  ['the closed world trusts a send the registry does not account for', 'closed_world.rb',
   'return if loop_installer_sites.include?([irep.label, idx])', 'return if true',
   /a computed name: the closed world keeps/]
].freeze

failures = Bc2cppMutationSupport.run_harness(
  MUTANTS.map do |name, file, pattern, replacement, expected|
    Bc2cppMutationSupport::Mutant.new(name: name, edits: [[file, pattern, replacement]], expected: expected)
  end
) do |tree, mutant, _run_half|
  env = { 'LP_REGISTRY_ONLY' => '1', 'BC2CPP_TOOLS_DIR' => tree.tool, 'BC2CPP_TOOL' => File.join(tree.tool, 'bc2cpp.rb') }
  Bc2cppMutationSupport.run_check(env, [RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_loop_installers_check.rb')], stop_on: mutant&.stop_on)
end

if failures.empty?
  puts 'bc2cpp loop installers mutation check: PASS'
else
  warn "bc2cpp loop installers mutation check: #{failures.size} failure(s)"
  exit 1
end
