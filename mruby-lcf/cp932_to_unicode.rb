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

table = table.sort {|l, r| l[1] <=> r[1] }

raise unless table.size == wctable_count

File.open("cp932.h", "w") do |f|
  f.write <<EOS
#pragma once

#include <utility>
#include <cstdint>

extern size_t cp932_table_len;
extern const std::pair<uint16_t, uint16_t> cp932_table[];
EOS
end

File.open("cp932.cc", "w") do |f|
  f.write <<EOS
#include "cp932.h"

size_t cp932_table_len = #{wctable_count};
const std::pair<uint16_t, uint16_t> cp932_table[] = {
EOS
  table.each do |i|
    c = i[2]&.sub(/^;/, '')
    f.write "  { #{i[1]}, #{i[0]} }, // #{c}\n";
  end
f.write <<EOS
};
EOS
end
