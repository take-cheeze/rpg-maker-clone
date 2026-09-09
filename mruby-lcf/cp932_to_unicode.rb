#!/usr/bin/env ruby

wctable_count = nil
table = []

IO.readlines(ENV["cp932_table"], encoding: Encoding::CP932).each do |l|
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

# docs/adr/0111: a `//` comment ending in a literal backslash splices onto
# the *next source line* (line continuation happens before comment
# tokenization, in both C++ and C) -- silently swallowing that line's own
# array entry into the comment, deleting it from the table with no
# compiler error or warning beyond "-Wcomment" (`grep -c` on a real
# generated cp932.cc: 74 such lines). The raw WCTABLE comment field is
# CP932 text describing the character (frequently non-ASCII, sometimes
# byte sequences that decode to a trailing backslash) written verbatim
# into a `//` comment -- exactly the shape that triggers this. Comments are
# purely decorative here (nothing parses them back out), so the fix is to
# make them backslash- and control-character-free outright: byte-filtered
# to printable ASCII minus backslash, not re-encoded (the source column can
# contain bytes invalid as CP932 on their own, e.g. a lone byte a decomposed
# multi-byte sequence split across this field's own boundary).
def safe_comment(raw)
  return '' unless raw
  raw.b.each_byte.filter_map { |b| b.chr if (0x20..0x7e).cover?(b) && b != 0x5c }.join
end

# Sorted by CP932 code (element 1 of each WCTABLE line -- see the file
# format comment below): what cp932_to_utf8 (lcf.cxx) binary-searches to
# decode a CP932 byte sequence into Unicode.
forward = table.sort { |l, r| l[1] <=> r[1] }

# docs/adr/0111: sorted by Unicode code point instead (element 0), with
# CP932 as the tiebreak -- reproduces, at build time, the exact sort order
# `std::sort` on `std::pair<uint16_t, uint16_t>{unicode, cp932}` already
# produced at *runtime* in lcf.cxx's own utf8_to_cp932 (a `pair`'s default
# `operator<` compares `.first` then `.second`, i.e. unicode then cp932).
# Necessary, not just a nicety: the best-fit table is many-to-one in this
# direction (more than one CP932 code can map to the same Unicode code
# point), so which entry `std::lower_bound` finds first depends on this
# exact tiebreak order, and getting it wrong would silently change which
# CP932 byte a round-tripped character encodes to.
reverse = table.sort { |l, r| l[0] == r[0] ? (l[1] <=> r[1]) : (l[0] <=> r[0]) }

File.open("cp932.h", "w") do |f|
  f.write <<EOS
#pragma once

#include <utility>
#include <cstdint>
#include <cstddef>

extern size_t cp932_table_len;
extern const std::pair<uint16_t, uint16_t> cp932_table[];

// docs/adr/0111: the exact reverse of cp932_table above (unicode -> cp932,
// sorted by unicode) generated here at build time instead of being built
// into a heap-allocated std::vector the first time anything calls
// utf8_to_cp932 -- that lazy build cost the whole table's size again in RAM
// (~38 KB) on a board with none to spare. See lcf.cxx's own utf8_to_cp932.
extern size_t cp932_reverse_table_len;
extern const std::pair<uint16_t, uint16_t> cp932_reverse_table[];
EOS
end

File.open("cp932.cc", "w") do |f|
  f.write <<EOS
#include "cp932.h"

size_t cp932_table_len = #{wctable_count};
const std::pair<uint16_t, uint16_t> cp932_table[] = {
EOS
  forward.each do |i|
    c = safe_comment(i[2]&.sub(/^;/, ''))
    f.write "  { #{i[1]}, #{i[0]} }, // #{c}\n";
  end
  f.write <<EOS
};

size_t cp932_reverse_table_len = #{wctable_count};
const std::pair<uint16_t, uint16_t> cp932_reverse_table[] = {
EOS
  reverse.each do |i|
    c = safe_comment(i[2]&.sub(/^;/, ''))
    f.write "  { #{i[0]}, #{i[1]} }, // #{c}\n";
  end
  f.write <<EOS
};
EOS
end
