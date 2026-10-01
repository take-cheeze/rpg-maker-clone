#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for the exact-receiver levers of docs/adr/0301. Each mutant is a copy of tools/bc2cpp
# with one soundness condition broken; scripts/bc2cpp_exact_receiver_flow_check.rb, run against the
# mutant through BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes
# means the condition has no negative case.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_exact_receiver_flow_mutation_check.rb

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['an instance-level freeze definition does not withdraw the freeze proof', 'codegen_return_classes.rb',
   "world.instance_native_dispatch_safe?('freeze')", 'true', /user freeze|overriding freeze/, true],
  ['a const_missing in the world does not withdraw the constant pools', 'codegen_class_pools.rb',
   "!installed.nil? && !installed.include?('const_missing') && ownerless_native_dispatch_safe?('const_missing')", 'true',
   /const_missing/, false],
  ['a constant the numeric proof poisons gets a pool', 'codegen_class_pools.rb',
   '@class_const_pools[name] = 0 unless group.structural', '@class_const_pools[name] = 0',
   /foreign Ruby definition|native definition|assigned a call result|computed const_set/, false],
  ['the registered-expression arm is taken for any exact class', 'codegen_native_send.rb',
   'exact = entries.find { |entry| entry[:owner][:class_name] == site[:klass] }', 'exact = entries.first',
   /every method answers what the interpreter answers/, true],
  ['the exact proof no longer reaches the POLY chain tail', 'codegen_send.rb',
   'poly = with_exact_core_site(exact_site) do', 'poly = with_exact_core_site(nil) do', /ErHolder#lit_join|ErHolder#const_join/, false]
].freeze

failures = []
MUTANTS.each do |name, file, pattern, replacement, expected, needs_run|
  Dir.mktmpdir do |dir|
    # bc2cpp.rb finds the engine's gems relative to itself (../..), so the copy keeps the repository layout.
    Dir.children(ROOT).reject { |entry| %w[.git tools].include?(entry) }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, entry), File.join(dir, entry))
    end
    FileUtils.mkdir_p(File.join(dir, 'tools'))
    Dir.children(File.join(ROOT, 'tools')).reject { |entry| entry == 'bc2cpp' }.each do |entry|
      FileUtils.ln_s(File.join(ROOT, 'tools', entry), File.join(dir, 'tools', entry))
    end
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), File.join(dir, 'tools'))
    path = File.join(dir, 'tools', 'bc2cpp', file)
    text = File.read(path)
    unless text.include?(pattern)
      puts "  FAIL #{name}: the mutation site is gone from #{file}"
      failures << name
      next
    end
    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'tools', 'bc2cpp', 'bc2cpp.rb') }
    env['ERF_GENERATED_ONLY'] = '1' unless needs_run
    out, status = Open3.capture2e(env, RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_exact_receiver_flow_check.rb'))
    failed_lines = out.lines.grep(/^\s+FAIL /)
    killed = !status.success? && failed_lines.any? { |l| l.match?(expected) }
    puts "  #{killed ? 'ok  ' : 'FAIL'} mutant killed: #{name}"
    unless killed
      puts failed_lines.first(5).join
      failures << name
    end
  end
end

if failures.empty?
  puts 'bc2cpp exact receiver flow mutation check: PASS'
else
  warn "bc2cpp exact receiver flow mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
