# Array#include? without mruby's own Enumerable#include? block allocation.
#
# mruby's Array class has no native #include? of its own -- there is no
# MRB_SYM(include?) entry in 3rd/mruby/src/array.c or mruby-array-ext -- so it
# falls through to Enumerable#include? (3rd/mruby/mrblib/enum.rb):
#
#     def include?(obj)
#       self.each {|*val|
#         return true if val.__svalue == obj
#       }
#       false
#     end
#
# Every single call allocates a Proc plus its closure env for that block, no
# matter how small the array or how early it returns. Confirmed the single
# largest remaining source of interpreter-side Proc/env churn in a real
# playthrough by a per-condition-type RGSS::Profiler.stats[:object_types]
# pass: it traced straight to Game::Actor#state?'s `@states.include?`, one of
# dozens of .include? call sites across the engine (Game::Actor#knows_skill?/
# #equipped? alongside it, Game::Party, the RPG2000 interpreter's own command
# handlers, ...) that all pay the identical tax on every call.
#
# A plain index loop calling #== directly gives the identical ISO-15.3.2.2.10
# semantics -- Enumerable#include? also compares with == -- with no block and
# so no allocation.
#
# Engine-wide rather than RGSS-only, like array_sort.rb's Array#sort/#sort!
# fix beside this file: this is mruby's own gap, not this game's.
class Array
  def include?(obj)
    i = 0
    n = length
    while i < n
      return true if self[i] == obj
      i += 1
    end
    false
  end
end
