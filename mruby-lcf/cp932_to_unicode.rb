#!/usr/bin/env ruby
# Generates cp932.cc / cp932.h, the CP932 <-> Unicode tables behind
# LCF.cp932_to_utf8 / LCF.utf8_to_cp932, from the WCTABLE (Unicode -> CP932
# best fit) section of Microsoft's bestfit932.txt ($cp932_table). The layout
# and the lookups that read it (src/cp932_lookup.hxx) are ADR 0217;
# scripts/cp932_tables_check.rb proves them equal to ADR 0111's pair tables.
#
# Usage: cp932_to_unicode.rb [OUT_DIR]   (default: the current directory)

out_dir = ARGV[0] || '.'

wctable_count = nil
table = []

IO.readlines(ENV.fetch('cp932_table'), encoding: Encoding::CP932).each do |l|
  if l =~ /^WCTABLE /
    wctable_count = l.split[1].to_i
    next
  end

  next unless wctable_count

  e = l.strip.split($;, 3)
  next if e.size < 2

  table << [e[0].hex, e[1].hex]
end

raise "WCTABLE: expected #{wctable_count} entries, read #{table.size}" unless table.size == wctable_count

UNMAPPED = 0xffff
LEAD_FIRST = 0x81
LEAD_LAST = 0xfc
EUDC_LEADS = (0xf0..0xf9).freeze
EUDC_UNICODE_FIRST = 0xe000
TRAIL_FIRST = 0x40
TRAIL_LAST = 0xfc
TRAIL_GAP = 0x7f
EUDC_ROW = TRAIL_LAST - TRAIL_FIRST # 188: 0x40..0xfc minus 0x7f

# The lookups rely on each of these; a table that breaks one must fail the
# build, not decode differently.
unicodes = table.map(&:first)
raise 'WCTABLE maps a Unicode code point twice' unless unicodes.uniq.size == unicodes.size
raise 'WCTABLE maps U+FFFF, the unmapped-slot sentinel' if unicodes.include?(UNMAPPED)

# Best fit is many-to-one (U+00C0..U+00C5 all encode to 'A'); decoding picks
# the smallest code point, which is what ADR 0111's forward table held first.
decode = {}
table.each { |u, c| decode[c] = u if !decode.key?(c) || u < decode[c] }

# Every other (unicode, cp932) pair can only be found when encoding.
encode_extra = table.reject { |u, c| decode[c] == u }.sort

def eudc_unicode(code)
  trail = code & 0xff
  EUDC_UNICODE_FIRST + ((code >> 8) - EUDC_LEADS.first) * EUDC_ROW +
    trail - (trail < TRAIL_GAP ? TRAIL_FIRST : TRAIL_FIRST + 1)
end

# The user-defined area maps linearly onto the Private Use Area, so the
# lookups compute it instead of storing 1,880 entries.
eudc_codes = EUDC_LEADS.flat_map do |lead|
  (TRAIL_FIRST..TRAIL_LAST).reject { |t| t == TRAIL_GAP }.map { |t| lead << 8 | t }
end
unless decode.keys.select { |c| EUDC_LEADS.cover?(c >> 8) }.sort == eudc_codes &&
       eudc_codes.all? { |c| decode[c] == eudc_unicode(c) }
  raise 'CP932 user-defined area (lead 0xf0-0xf9) is no longer a linear run from U+E000'
end

bad = decode.keys.find { |c| c > 0xff && !(LEAD_FIRST..LEAD_LAST).cover?(c >> 8) }
raise format('double-byte code 0x%04x outside lead bytes 0x81-0xfc', bad) if bad

single = Array.new(256) { |c| decode.fetch(c, UNMAPPED) }

# One row per lead byte, trimmed to its first..last mapped trail byte.
rows = []
double = []
(LEAD_FIRST..LEAD_LAST).each do |lead|
  trails = EUDC_LEADS.cover?(lead) ? [] : decode.keys.select { |c| c >> 8 == lead }.map { |c| c & 0xff }
  if trails.empty?
    rows << [1, 0, 0]
    next
  end
  first, last = trails.minmax
  rows << [first, last, double.size]
  (first..last).each { |t| double << decode.fetch(lead << 8 | t, UNMAPPED) }
end
raise 'cp932_double outgrew its 16-bit row offsets' if double.size > 0xffff

reverse = table.sort

def hex_rows(values, per_line = 12)
  values.each_slice(per_line).map { |s| '  ' + s.map { |v| format('0x%04x,', v) }.join(' ') }.join("\n")
end

def pair_rows(pairs, per_line = 6)
  pairs.each_slice(per_line).map { |s| '  ' + s.map { |a, b| format('{0x%04x, 0x%04x},', a, b) }.join(' ') }.join("\n")
end

File.write(File.join(out_dir, 'cp932.h'), <<~EOS)
  #pragma once

  #include <cstddef>
  #include <cstdint>
  #include <utility>

  // ADR 0217: wio encodes by scanning the decode tables below instead of
  // carrying a 38 KB reverse table in flash.
  #if defined(WIO_TERMINAL) && !defined(CP932_NO_REVERSE_TABLE)
  #define CP932_NO_REVERSE_TABLE 1
  #endif

  constexpr uint16_t CP932_UNMAPPED = 0x#{UNMAPPED.to_s(16)};
  constexpr unsigned CP932_LEAD_FIRST = 0x#{LEAD_FIRST.to_s(16)};
  constexpr unsigned CP932_LEAD_LAST = 0x#{LEAD_LAST.to_s(16)};
  constexpr unsigned CP932_EUDC_LEAD_FIRST = 0x#{EUDC_LEADS.first.to_s(16)};
  constexpr unsigned CP932_EUDC_LEAD_LAST = 0x#{EUDC_LEADS.last.to_s(16)};
  constexpr unsigned CP932_EUDC_UNICODE_FIRST = 0x#{EUDC_UNICODE_FIRST.to_s(16)};
  constexpr unsigned CP932_TRAIL_FIRST = 0x#{TRAIL_FIRST.to_s(16)};
  constexpr unsigned CP932_TRAIL_LAST = 0x#{TRAIL_LAST.to_s(16)};
  constexpr unsigned CP932_TRAIL_GAP = 0x#{TRAIL_GAP.to_s(16)};
  constexpr unsigned CP932_EUDC_ROW = #{EUDC_ROW};

  // Trail bytes first_trail..last_trail of one lead byte, starting at
  // cp932_double[offset]. An empty row has first_trail > last_trail.
  struct Cp932Row {
    uint8_t first_trail;
    uint8_t last_trail;
    uint16_t offset;
  };

  extern const uint16_t cp932_single[256];
  extern const Cp932Row cp932_rows[CP932_LEAD_LAST - CP932_LEAD_FIRST + 1];
  constexpr size_t cp932_double_len = #{double.size};
  extern const uint16_t cp932_double[cp932_double_len];

  // {unicode, cp932}, sorted: the best-fit pairs decoding does not return.
  constexpr size_t cp932_encode_extra_len = #{encode_extra.size};
  extern const std::pair<uint16_t, uint16_t> cp932_encode_extra[cp932_encode_extra_len];

  #ifndef CP932_NO_REVERSE_TABLE
  // {unicode, cp932}, sorted by unicode (ADR 0111).
  constexpr size_t cp932_reverse_table_len = #{reverse.size};
  extern const std::pair<uint16_t, uint16_t> cp932_reverse_table[cp932_reverse_table_len];
  #endif
EOS

File.write(File.join(out_dir, 'cp932.cc'), <<~EOS)
  #include "cp932.h"

  const uint16_t cp932_single[256] = {
  #{hex_rows(single, 16)}
  };

  const Cp932Row cp932_rows[CP932_LEAD_LAST - CP932_LEAD_FIRST + 1] = {
  #{rows.each_slice(4).map { |s| '  ' + s.map { |f, l, o| format('{0x%02x, 0x%02x, %d},', f, l, o) }.join(' ') }.join("\n")}
  };

  const uint16_t cp932_double[cp932_double_len] = {
  #{hex_rows(double)}
  };

  const std::pair<uint16_t, uint16_t> cp932_encode_extra[cp932_encode_extra_len] = {
  #{pair_rows(encode_extra)}
  };

  #ifndef CP932_NO_REVERSE_TABLE
  const std::pair<uint16_t, uint16_t> cp932_reverse_table[cp932_reverse_table_len] = {
  #{pair_rows(reverse)}
  };
  #endif
EOS
