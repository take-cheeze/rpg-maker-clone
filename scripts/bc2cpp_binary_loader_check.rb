#!/usr/bin/env ruby
# frozen_string_literal: true

# The RITE-binary loader (RiteBinary + InsnDecoder) must yield exactly the
# Insn stream the `mrbc -v` text loader parses: addr, op, typed operands,
# args, raw, lineno, file and catch handlers of every irep, for the real
# closed-world gems and for a synthetic source covering EXT widening, catch
# tables, pool literals and odd symbol names. Usage:
# MRBC=path/to/mrbc ruby scripts/bc2cpp_binary_loader_check.rb
require 'tmpdir'
require_relative '../tools/bc2cpp/irep'
require_relative '../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('..', __dir__)

# 200 locals and 300 distinct symbols/strings push operands past one byte, so
# mrbc emits EXT1/EXT2/EXT3 prefixes.
def synthetic_source
  locals = (0...200).map { |i| "v#{i} = #{i}" }.join("\n")
  calls = (0...300).map { |i| "self.m#{i}(#{i % 200 == 0 ? (0...120).map { |k| "v#{k}" }.join(",") : "v#{i % 200}"}, \"s#{i}\", :y#{i}, #{i}.5)" }.join("\n")
  <<~RUBY
    class Wide
      def wide
        #{locals}
        #{calls}
        v199 + v0
      end

      def flow(a, b = 2, *r, k: 1, **o, &blk)
        begin
          yield a
        rescue ArgumentError, TypeError => e
          p e
        ensure
          a = "multi
    line ; string"
        end
        [:"a-b", :+, :[]=, :foo?, :bar!, :baz=, :@iv, :$gv, :"\\u3042"].each { |s| s.to_s }
        x = -1; y = 70000; z = 3_000_000_000; w = -3_000_000_000; f = 1.5e300
        @a, @@c, $g = x, y, z
        [*r, 1].map { |i| i * 2 }
        {a: 1, **o}
        a.b&.c
        case a when 1..2 then 1 else 2 end
        ObjectSpace.each_object { |q| q }
        return a unless b
        super
      end

      def self.cls; class << self; self; end; end
      alias_method :old_flow, :flow
      alias other wide
      undef_method :other
    end
    Wide.new.wide
  RUBY
end

def compare(label, dir, srcs)
  # The text loader stays available as the reference (BC2CPP_TEXT_LOADER=1).
  _c, text = run_mrbc_text_reference(srcs, dir, label)
  _c2, image = run_mrbc(srcs, "#{label}_bin", dir)
  abort 'bc2cpp binary loader check: run_mrbc returned text; unset BC2CPP_TEXT_LOADER' unless image.is_a?(RiteImage)

  want_blocks, want_files, want_catches = parse_disasm_blocks(text)
  got_blocks, got_files, got_catches = parse_disasm_blocks(image)
  failures = []
  failures << "irep count #{got_blocks.length} != #{want_blocks.length}" unless got_blocks.length == want_blocks.length
  got_blocks.zip(want_blocks, got_files, want_files, got_catches, want_catches).each_with_index do |row, index|
    got, want, got_file, want_file, got_catch, want_catch = row
    failures << "irep #{index}: file #{got_file.inspect} != #{want_file.inspect}" unless got_file == want_file
    failures << "irep #{index}: catch handlers differ" unless got_catch == want_catch
    unless got.length == want.length
      failures << "irep #{index}: #{got.length} insns != #{want.length}"
      next
    end
    got.zip(want).each do |g, w|
      fields = { addr: [g.addr, w.addr], op: [g.op, w.op], lineno: [g.lineno, w.lineno], args: [g.args, w.args],
                 raw: [g.raw, w.raw], typed: [g.typed, w.typed] }
      fields.each do |field, (gv, wv)|
        failures << "irep #{index} @#{w.addr} #{w.op} #{field}: #{gv.inspect} != #{wv.inspect}" unless gv == wv
      end
      break if failures.length > 20
    end
    break if failures.length > 20
  end
  total = want_blocks.sum(&:length)
  abort "bc2cpp binary loader check: FAIL #{label}\n  #{failures.first(20).join("\n  ")}" unless failures.empty?
  [want_blocks.length, total]
end

def run_mrbc_text_reference(srcs, dir, label)
  c_dump = File.join(dir, "#{label}_text.c")
  system(MRBC, '-B', "#{label}_text", '-S', '-o', c_dump, *srcs, exception: true)
  [File.read(c_dump, encoding: 'UTF-8'),
   run_mrbc_text(srcs, File.join(dir, "#{label}_disasm.txt"), File.join(dir, "#{label}_text.mrb"))]
end

# InsnDecoder::FORMATS must match mruby/ops.h opcode-for-opcode.
def check_formats
  core = ENV['BC2CPP_MRUBY_CORE'] || File.join(ROOT, '3rd/mruby')
  header = File.join(core, 'include/mruby/ops.h')
  return puts('bc2cpp binary loader check: ops.h not found, opcode table unchecked') unless File.exist?(header)

  want = File.read(header).scan(/^OPCODE\((\w+),\s*(\w+)\)/).map { |name, fmt| [name, fmt] }
  abort 'bc2cpp binary loader check: FAIL InsnDecoder::FORMATS differs from ops.h' unless want == InsnDecoder::FORMATS
  # The extension-prefix opcodes are decoded by name, so their numbers matter.
  puts "bc2cpp binary loader check: #{want.length} opcode formats match ops.h"
end

check_formats
results = Dir.mktmpdir do |dir|
  synthetic = File.join(dir, 'synthetic.rb')
  File.write(synthetic, synthetic_source)
  { 'synthetic' => compare('synthetic', dir, [synthetic]),
    'closed world' => compare('closed_world', dir, closed_world_mrblib_srcs(ROOT)) }
end
results.each { |label, (ireps, insns)| puts "bc2cpp binary loader check: #{label} PASS (#{ireps} ireps, #{insns} instructions)" }
