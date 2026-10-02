#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation test for EXACT_NATIVE_WRAPPER (docs/adr/0307). Each mutant is a copy of tools/bc2cpp with one
# condition broken; scripts/bc2cpp_exact_native_wrappers_check.rb, run against the mutant through
# BC2CPP_TOOL, must FAIL on the check that guards that condition. A mutant that passes means the condition
# has no negative case.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp_exact_native_wrappers_mutation_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
abort 'SKIP: set MRBC' unless ENV['MRBC']

# [name, file, pattern, replacement, check label that must FAIL, needs the run half]
MUTANTS = [
  ['a nil receiver is taken as exact without the nil test', 'codegen_exact_native_wrappers.rb',
   'klass = exact_flow_user_class(irep, idx, reg)',
   'klass = return_class_of_mask(exact_flow_mask(irep, idx, reg)&.then { |m| m & ~NumericFlow::NIL })',
   /nil-or-Bitmap takes one nil test|raises where the interpreter does|every method answers/, false],
  ['an argument receiver counts as exact (the hint, not the flow)', 'codegen_exact_native_wrappers.rb',
   'klass = exact_flow_user_class(irep, idx, reg)', "klass = 'RGSS::Bitmap'",
   /argument receiver keeps the class test|keeps the guard/, false],
  ['blt reports the opacity as given when it is not', 'codegen_exact_native_wrappers.rb',
   "argv.size == 5 ? 'TRUE' : 'FALSE'", "'TRUE'", /the unguarded call is the guarded arm's call \(rgss::bitmap_blt_direct\)/, false],
  ['stretch_blt reports the opacity as not given when it is', 'codegen_exact_native_wrappers.rb',
   "argv.size == 4 ? 'TRUE' : 'FALSE'", "'FALSE'", /the unguarded call is the guarded arm's call \(rgss::bitmap_stretch_blt_direct\)/, false],
  ['draw_text packs one argument too many', 'codegen_exact_native_wrappers.rb',
   'rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size},', 'rgss::bitmap_draw_text_direct(M, #{recv}, #{argv.size + 1},',
   /the unguarded call is the guarded arm's call \(rgss::bitmap_draw_text_direct\)/, false],
  ['any arity is taken (a fill_rect of two arguments gets the five-argument body)', 'codegen_exact_native_wrappers.rb',
   'return [:call, builder] if arities.include?(argc)', 'return [:call, builder]',
   /bad_arity: a call of another arity/, false],
  ['the kill switch is ignored', 'codegen_exact_native_wrappers.rb',
   "ENV.fetch('BC2CPP_EXACT_NATIVE_WRAPPERS', '1') != '0'", 'true', /the kill switch/, false],
  ['the nil test is not worth it for an unguarded call (EXACT_NATIVE_WRAPPER leaves NILABLE_RECEIVER\'s exact marks)',
   'codegen_nilable_receiver.rb', 'NATIVE_EXACT_DIRECT|EXACT_NATIVE_WRAPPER|', 'NATIVE_EXACT_DIRECT|', /NILABLE_RECEIVER's exact marks name the unguarded wrapper call/, false]
].freeze

failures = []
MUTANTS.each do |name, file, pattern, replacement, expected, needs_run|
  Dir.mktmpdir do |dir|
    FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
    path = File.join(dir, 'bc2cpp', file)
    text = File.read(path)
    unless text.include?(pattern)
      puts "  FAIL #{name}: the mutation site is gone from #{file}"
      failures << name
      next
    end
    File.write(path, text.sub(pattern) { replacement })
    env = { 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb') }
    env['EW_GENERATED_ONLY'] = '1' unless needs_run
    out, status = Open3.capture2e(env, RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp_exact_native_wrappers_check.rb'))
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
  puts 'bc2cpp exact native wrappers mutation check: PASS'
else
  warn "bc2cpp exact native wrappers mutation check: #{failures.size} surviving mutant(s)"
  exit 1
end
