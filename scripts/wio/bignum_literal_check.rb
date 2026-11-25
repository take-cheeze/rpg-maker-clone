#!/usr/bin/env ruby
# frozen_string_literal: true

# The Wio build links no mruby-bigint (build_config.rb, WIO_BIGINT), so an Integer pool literal in its bytecode --
# one past 32 bits, `-2147483648`, or a constant mrbc folds past 32 bits (`1 << 32`) -- fails to load or raises there.
# This compiles every Ruby file of the wio world with the host mrbc and fails on any LOADL of an Integer pool entry.
#
#   ruby scripts/wio/bignum_literal_check.rb MRBC [BUILD_DIR]
#   ruby scripts/wio/bignum_literal_check.rb MRBC --self-test
#
# The world is the closed world's mrblib (tools/bc2cpp/compiled_gems.rb) plus, with BUILD_DIR, the .rb files the wio
# build generated or rewrote under BUILD_DIR/wio.

require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/world_root'
require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)
mrbc = ARGV.shift or abort "usage: #{$PROGRAM_NAME} MRBC [BUILD_DIR | --self-test]"

# A LOADL's pool comment is the value of an Integer or Float entry ("; 42", "; 1.500000"); a bignum entry has none.
LOADL = /^\s*(\d+)\s+\d+\s+LOADL\s+R\d+\s+L\[\d+\](?:\t; ([^;\t]*))?/.freeze

def integer_loads(mrbc, path)
  out, status = Open3.capture2e(mrbc, '-v', '-o', File::NULL, path)
  raise "#{mrbc} failed on #{path}:\n#{out}" unless status.success?

  out.each_line.filter_map do |line|
    m = LOADL.match(line) or next
    value = m[2]&.strip
    next if value && value.match?(/\A[-+]?(\d+\.\d+(e[-+]?\d+)?|inf|nan)\z/i)

    [m[1].to_i, value || 'bignum']
  end
end

if ARGV.first == '--self-test'
  Dir.mktmpdir do |dir|
    cases = { 'a = 0x1_0000_0000' => 1, 'b = 1 << 40' => 1, 'c = -2147483648' => 1, 'd = 2147483647' => 0,
              'e = -2147483647' => 0, 'f = 1.5' => 0, 'g = 1 << 30' => 0 }
    bad = cases.reject do |src, want|
      path = File.join(dir, 'case.rb')
      File.write(path, "#{src}\n")
      integer_loads(mrbc, path).size == want
    end
    abort "bignum_literal_check self-test failed: #{bad.keys.join(', ')}" unless bad.empty?
    puts "bignum_literal_check self-test: #{cases.size} cases ok"
  end
  exit
end

build_dir = ARGV.shift
files = closed_world_mrblib_srcs(ROOT)
files += Dir[File.join(build_dir, 'wio', '**', '*.rb')].sort if build_dir
hits = files.flat_map do |path|
  integer_loads(mrbc, path).map { |line, value| "#{path.delete_prefix("#{ROOT}/")}:#{line}: Integer pool literal (#{value})" }
end
if hits.empty?
  puts "bignum_literal_check: #{files.size} files, no Integer pool literal"
else
  warn hits
  warn "bignum_literal_check: #{hits.size} Integer pool literal(s); spell the value inside 32 bits or compute it natively"
  exit 1
end
