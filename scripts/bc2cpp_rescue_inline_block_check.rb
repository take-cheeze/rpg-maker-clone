#!/usr/bin/env ruby
# encoding: UTF-8
# Check that an inlined block loop (`ary.each { }`, `n.times { }`, ...) whose
# BLOCK/SENDB sits inside a `rescue`-protected range is never emitted into the
# enclosing method's own function. The protected range is compiled into a
# separate extracted try body (emit_rescue_try_body), and compile_method skips
# every address of it -- except one carrying `glue_at` replacement code. An
# inlined loop registered there is therefore emitted AFTER the rescue glue, on
# the path only an exception reaches: it runs the block a second time, with a
# receiver register that holds the exception (the EXCEPT register is the
# protected body's first temporary, so it is often the loop's own receiver),
# not the Array the recognizer proved from the try body's instructions. Caught
# live: kk1.12's New Game in the RPGMAKER_BC2CPP=1 build died with
# `TypeError: bc2cpp: expected Array receiver for inlined #each` from
# `RPG2k#start_new_game`'s `@scenes.each { ... }` whenever anything in its
# whole-method `rescue StandardError` raised, instead of logging
# `[RPG2k] Failed to start new game: ...` like the interpreter does.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  class Driver
    def whole_method(n)
      xs = [n, n]
      xs.each { |x| x.succ }
      n.fail_here
    rescue StandardError => e
      e.message
    end

    def mid_method(n)
      r = begin
        n.times { |i| i.succ }
        n.fail_here
      rescue StandardError => e
        e.message
      end
      [r, n]
    end

    def unprotected(n)
      xs = [n, n]
      xs.each { |x| x.succ }
      n
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'rescue_inline_block.rb')
  File.write(path, SRC)
  c_dump, disasm = run_mrbc(path, 'bc2cpp_rescue_inline_block', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_rescue_inline_block')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = lambda do |name|
    gen.compile_method(registry.fetch(name).find { |d| d.owner == 'Driver' }.irep).fetch(:code)
  end
  # The method's own function, from its signature to the closing brace at
  # column 0 -- excludes the extracted try body and block cfuncs above it.
  impl_of = ->(c, name) { c[/^mrb_value Driver_#{name}_impl\(.*?\n\}/m].to_s }
  try_of = ->(c, name) { c[/^static mrb_value Driver_#{name}_impl_rescue_try\(.*?\n\}/m].to_s }

  whole = code.call('whole_method')
  check.call('whole-method rescue: the try body is extracted and compiles clean',
             !try_of.call(whole, 'whole_method').empty? && !whole.include?('#error'))
  check.call('whole-method rescue: the try body still calls #each',
             try_of.call(whole, 'whole_method').match?(/"each"|bc2cpp_each_i_/))
  check.call('whole-method rescue: no inlined #each loop on the exception path of the method body',
             !impl_of.call(whole, 'whole_method').empty? &&
             !impl_of.call(whole, 'whole_method').include?('bc2cpp_each_i_') &&
             !impl_of.call(whole, 'whole_method').include?('expected Array receiver'))

  mid = code.call('mid_method')
  check.call('begin/rescue mid-method: the try body still calls #times',
             try_of.call(mid, 'mid_method').match?(/"times"|bc2cpp_times_i_/) && !mid.include?('#error'))
  check.call('begin/rescue mid-method: no inlined #times loop on the exception path of the method body',
             !impl_of.call(mid, 'mid_method').empty? &&
             !impl_of.call(mid, 'mid_method').include?('bc2cpp_times_i_'))

  plain = code.call('unprotected')
  check.call('an #each outside any rescue is still inlined', impl_of.call(plain, 'unprotected').include?('bc2cpp_each_i_'))
end

if failures.empty?
  puts 'bc2cpp rescue inline-block check: PASS'
else
  warn "bc2cpp rescue inline-block check: #{failures.size} failure(s)"
  exit 1
end
