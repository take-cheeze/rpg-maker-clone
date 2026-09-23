#!/usr/bin/env ruby
# encoding: UTF-8
# Check that an extracted `rescue` try body (emit_rescue_try_body) starts from
# the registers' real values at the protected region's begin_addr, not from the
# method's raw C++ parameters. A region reached only after other code ran -- an
# optional argument's default, or an `if ...; return; end` guard -- must capture
# the register file by value (rescue_entry_saved_fields). Caught live:
# `RPG2k::Scene::Map#drive_battle(it = @interpreter)` called with no argument
# ran its whole `begin` body with `it == nil` ("undefined method
# 'battle_request' for NilClass"), because the try body read the raw nil
# parameter instead of the defaulted r1.

require 'tmpdir'
require_relative '../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SRC = <<~'RUBY'
  class Driver
    def initialize
      @it = 1
    end

    def defaulted(it = @it)
      begin
        it.succ
      rescue StandardError
        nil
      end
    end

    def guarded(x)
      y = x.to_s
      return nil if y.empty?

      begin
        y.size
      rescue StandardError
        nil
      end
    end

    def plain(x)
      begin
        x.succ
      rescue StandardError
        nil
      end
    end
  end
RUBY

Dir.mktmpdir do |dir|
  path = File.join(dir, 'rescue_live_in.rb')
  File.write(path, SRC)
  c_dump, disasm = run_mrbc(path, 'bc2cpp_rescue_live_in', dir)
  ireps, root_label = parse_c_dump(c_dump, 'bc2cpp_rescue_live_in')
  order = dfs_order(ireps, root_label)
  blocks, block_files, block_catches = parse_disasm_blocks(disasm)
  merge!(ireps, order, blocks, block_files, block_catches)
  registry = build_registry(ireps, root_label)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = lambda do |name|
    gen.compile_method(registry.fetch(name).find { |d| d.owner == 'Driver' }.irep).fetch(:code)
  end

  defaulted = code.call('defaulted')
  check.call('an optional-argument method compiles its rescue region at all', defaulted.include?('_rescue_try_Ctx'))
  check.call('the try body takes r1 from the defaulted register, not the raw parameter',
             defaulted.include?('mrb_value r1 = bc2cpp_saved_r1;') && !defaulted.include?('mrb_value r1 = ctx->'))
  check.call('the glue passes the live register r1 into the ctx', defaulted.match?(/_Ctx ctx\{self, \w+, r1[,}]/))

  guarded = code.call('guarded')
  guarded = code.call('guarded')
  try_body = guarded[/static mrb_value Driver_guarded_impl_rescue_try\(.*?\n\}/m].to_s
  check.call('a region after an early-return guard starts every register from the capture (the local `y` included)',
             try_body.include?('bc2cpp_saved_r') && !try_body.match?(/mrb_value r\d+ = mrb_nil_value\(\);/))

  plain = code.call('plain')
  check.call('a region right after ENTER keeps the lean self+arguments ctx',
             plain.include?('_rescue_try_Ctx') && !plain.include?('bc2cpp_saved_r'))
end

if failures.empty?
  puts 'bc2cpp rescue live-in check: PASS'
else
  warn "bc2cpp rescue live-in check: #{failures.size} failure(s)"
  exit 1
end
