#!/usr/bin/env ruby
# frozen_string_literal: true

# Proves mruby-lcf's CP932 lookups (src/cp932_lookup.hxx over the tables
# cp932_to_unicode.rb generates, ADR 0217) return exactly what ADR 0111's two
# sorted pair tables returned, for all 65,536 inputs in both directions:
# decode (CP932 code -> Unicode) and encode (Unicode -> CP932 code). Both
# encode paths are checked: the reverse table desktop keeps, and the
# decode-table scan wio uses (CP932_NO_REVERSE_TABLE). Also prints the host
# timing of each path.
#
# The reference is ADR 0111's generator and lookups, reproduced below. With
# --reference-generator FILE it instead runs that historical generator (e.g.
# `git show 7ed1848e:mruby-lcf/cp932_to_unicode.rb > old.rb`) as the reference.
#
# Needs $cp932_table (bestfit932.txt, as the build does) and a C++17 compiler
# ($CXX, default c++).
#
#   ruby scripts/cp932_tables_check.rb [--reference-generator FILE]

require 'fileutils'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
GENERATOR = File.join(ROOT, 'mruby-lcf/cp932_to_unicode.rb')
LOOKUP_DIR = File.join(ROOT, 'mruby-lcf/src')
CXX = ENV.fetch('CXX', 'c++')

reference_generator = nil
OptionParser.new do |o|
  o.on('--reference-generator FILE') { |f| reference_generator = File.expand_path(f) }
end.parse!

abort 'cp932 tables check: $cp932_table must point at bestfit932.txt' unless ENV['cp932_table'] && File.file?(ENV['cp932_table'])

# ADR 0111's cp932_to_unicode.rb, minus the decorative comments: the forward
# table sorted by CP932 code and the reverse table by (unicode, cp932), both
# as the original's string sort ordered them.
def write_reference_tables(dir)
  wctable_count = nil
  table = []
  IO.readlines(ENV['cp932_table'], encoding: Encoding::CP932).each do |l|
    if l =~ /^WCTABLE /
      wctable_count = l.split[1].to_i
      next
    end
    next unless wctable_count

    e = l.strip.split($;, 3)
    next if e.size < 2

    table << e
  end
  raise unless table.size == wctable_count

  forward = table.sort { |l, r| l[1] <=> r[1] }
  reverse = table.sort { |l, r| l[0] == r[0] ? (l[1] <=> r[1]) : (l[0] <=> r[0]) }
  File.write(File.join(dir, 'cp932.h'), <<~EOS)
    #pragma once
    #include <utility>
    #include <cstdint>
    #include <cstddef>
    extern size_t cp932_table_len;
    extern const std::pair<uint16_t, uint16_t> cp932_table[];
    extern size_t cp932_reverse_table_len;
    extern const std::pair<uint16_t, uint16_t> cp932_reverse_table[];
  EOS
  File.open(File.join(dir, 'cp932.cc'), 'w') do |f|
    f.puts '#include "cp932.h"', "size_t cp932_table_len = #{wctable_count};",
           'const std::pair<uint16_t, uint16_t> cp932_table[] = {'
    forward.each { |i| f.puts "  { #{i[1]}, #{i[0]} }," }
    f.puts '};', "size_t cp932_reverse_table_len = #{wctable_count};",
           'const std::pair<uint16_t, uint16_t> cp932_reverse_table[] = {'
    reverse.each { |i| f.puts "  { #{i[0]}, #{i[1]} }," }
    f.puts '};'
  end
end

# The reference TU's symbols, renamed so they link next to the new tables.
REF_RENAMES = %w[cp932_table cp932_table_len cp932_reverse_table cp932_reverse_table_len]
              .map { |s| "-D#{s}=ref_#{s}" }.freeze

HARNESS = <<~'CPP'
  #include "cp932_lookup.hxx"

  #include <algorithm>
  #include <chrono>
  #include <cstdio>
  #include <optional>
  #include <utility>
  #include <vector>

  extern size_t ref_cp932_table_len;
  extern const std::pair<uint16_t, uint16_t> ref_cp932_table[];
  extern size_t ref_cp932_reverse_table_len;
  extern const std::pair<uint16_t, uint16_t> ref_cp932_reverse_table[];

  // ADR 0111's lcf.cxx lookups (find_utf8 / find_cp932), verbatim.
  static std::optional<uint16_t> ref_decode(const uint16_t v) {
    const auto cmp = [](const std::pair<uint16_t, uint16_t>& l,
                        const uint16_t& r) -> bool { return l.first < r; };
    const auto* e = ref_cp932_table + ref_cp932_table_len;
    const auto* i = std::lower_bound(ref_cp932_table, e, v, cmp);
    if (i < e and i->first == v)
      return i->second;
    else
      return std::nullopt;
  }
  static std::optional<uint16_t> ref_encode(const uint16_t v) {
    const auto cmp = [](const std::pair<uint16_t, uint16_t>& l,
                        const uint16_t& r) -> bool { return l.first < r; };
    const auto* b = ref_cp932_reverse_table;
    const auto* e = b + ref_cp932_reverse_table_len;
    const auto* i = std::lower_bound(b, e, v, cmp);
    if (i < e and i->first == v)
      return i->second;
    else
      return std::nullopt;
  }

  static int compare(const char* what, std::optional<uint16_t> (*ref)(uint16_t),
                     std::optional<uint16_t> (*got)(uint16_t), unsigned* mapped) {
    int bad = 0;
    *mapped = 0;
    for (unsigned k = 0; k <= 0xffff; ++k) {
      const auto r = ref(k), g = got(k);
      if (r) ++*mapped;
      if (r != g) {
        if (bad++ < 10)
          std::printf("  MISMATCH %s 0x%04x: reference %s0x%04x, new %s0x%04x\n",
                      what, k, r ? "" : "none/", r.value_or(0), g ? "" : "none/",
                      g.value_or(0));
      }
    }
    return bad;
  }

  // Mean ns per lookup over `inputs`, best of 5 runs.
  static double time_ns(std::optional<uint16_t> (*f)(uint16_t),
                        const std::vector<uint16_t>& inputs) {
    double best = 1e30;
    volatile unsigned sink = 0;
    for (int run = 0; run < 5; ++run) {
      const auto t0 = std::chrono::steady_clock::now();
      unsigned acc = 0;
      for (const uint16_t k : inputs) acc += f(k).value_or(0);
      const auto t1 = std::chrono::steady_clock::now();
      sink = sink + acc;
      best = std::min(best, std::chrono::duration<double, std::nano>(t1 - t0).count() /
                                inputs.size());
    }
    return best;
  }

  int main() {
    unsigned dec_mapped = 0, enc_mapped = 0;
    int bad = compare("decode", ref_decode, cp932_decode, &dec_mapped);
    bad += compare("encode", ref_encode, cp932_encode, &enc_mapped);
    std::printf("  %s: 65536 decode inputs (%u mapped), 65536 encode inputs (%u mapped), %d mismatches\n",
                CONFIG_NAME, dec_mapped, enc_mapped, bad);
    // Encode timing over the non-ASCII code points a save can actually carry.
    std::vector<uint16_t> text;
    for (unsigned u = 0x80; u <= 0xffff; ++u)
      if (ref_encode(u)) text.push_back(u);
    std::printf("  %s: encode %.1f ns/char (ADR 0111 reverse table %.1f ns/char) over %zu mapped non-ASCII code points\n",
                CONFIG_NAME, time_ns(cp932_encode, text), time_ns(ref_encode, text), text.size());
    std::vector<uint16_t> codes;
    for (unsigned k = 0; k <= 0xffff; ++k)
      if (ref_decode(k)) codes.push_back(k);
    std::printf("  %s: decode %.1f ns/code (ADR 0111 forward table %.1f ns/code) over %zu mapped codes\n",
                CONFIG_NAME, time_ns(cp932_decode, codes), time_ns(ref_decode, codes), codes.size());
    return bad == 0 ? 0 : 1;
  }
CPP

def run!(*cmd, chdir: nil)
  out, status = Open3.capture2e(*cmd, **(chdir ? { chdir: chdir } : {}))
  abort "cp932 tables check: `#{cmd.join(' ')}` failed:\n#{out}" unless status.success?
  out
end

CONFIGS = {
  'desktop (reverse table)' => [],
  'wio (decode-table scan)' => ['-DCP932_NO_REVERSE_TABLE']
}.freeze

ok = true
Dir.mktmpdir('cp932-check') do |tmp|
  new_dir = File.join(tmp, 'new')
  ref_dir = File.join(tmp, 'ref')
  FileUtils.mkdir_p([new_dir, ref_dir])
  run!(RbConfig.ruby, GENERATOR, new_dir)
  if reference_generator
    run!(RbConfig.ruby, reference_generator, chdir: ref_dir)
  else
    write_reference_tables(ref_dir)
  end
  File.write(File.join(tmp, 'harness.cc'), HARNESS)
  ref_obj = File.join(tmp, 'ref.o')
  run!(CXX, '-std=c++17', '-O2', '-w', *REF_RENAMES, '-c', File.join(ref_dir, 'cp932.cc'), '-o', ref_obj)
  puts "cp932 tables check (reference: #{reference_generator || "ADR 0111's generator, reproduced"})"
  CONFIGS.each_with_index do |(name, defs), i|
    exe = File.join(tmp, "harness#{i}")
    run!(CXX, '-std=c++17', '-O2', *defs, %(-DCONFIG_NAME="#{name}"), '-I', new_dir, '-I', LOOKUP_DIR,
         File.join(tmp, 'harness.cc'), File.join(new_dir, 'cp932.cc'), ref_obj, '-o', exe)
    out, status = Open3.capture2e(exe)
    puts out
    ok &&= status.success?
  end
end

if ok
  puts 'cp932 tables check: PASS'
else
  warn 'cp932 tables check: FAIL'
  exit 1
end
