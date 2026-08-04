#!/usr/bin/env ruby
# encoding: UTF-8
#
# Prove the LCF save-data *writer* against real Save<N>.lsd files.
#
# scripts/lcf_save_check.rb established that the read path (ADR 0009, the
# `SAVE_DATA` schema) decodes a genuine RPG Maker 2000/2003 save. This harness
# exercises the inverse -- LCF.write_ber / Array1D#to_lcf / Array2D#to_lcf /
# File#to_lcf (ADR 0018) -- in two ways:
#
#   1. Byte-exact round-trip: parse a real .lsd and re-serialise it; the bytes
#      must equal the original file exactly. Because the reader keeps every
#      chunk's raw payload (documented or not -- e.g. the still-undocumented
#      chunks 102, 112, 200), a faithful copy needs no field-level re-encoding,
#      so this proves the framing (BER lengths, ascending chunk order, the
#      trailing terminator) is reproduced bit for bit.
#
#   2. Semantic edit: change scalar fields through the schema (hero position and
#      the system save counter), write the save, read it back, and confirm the
#      new values survive while an untouched chunk is unchanged. This proves the
#      value encoders (LCF.encode) and #[]= produce a genuinely re-loadable save.
#
# The only native dependency is cp932 transcoding (uni-algo in the real build);
# here Ruby's Windows-31J codec stands in, in both directions.
#
# Usage:
#   ruby scripts/lcf_save_roundtrip.rb [SAVE.lsd ...]
# With no arguments it scans ./data for Save*.lsd files. Exits non-zero on any
# byte mismatch, failed edit, or parse error.

require 'stringio'

module LCF
  # uni-algo stand-ins: transcode between Shift_JIS (Windows-31J) and UTF-8,
  # degrading unmappable input rather than aborting, mirroring the native codec.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end

  def utf8_to_cp932(s)
    s.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

mrblib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(mrblib, 'lcf.rb')
load File.join(mrblib, 'schema.rb')

class RoundTripper
  attr_reader :errors

  # Save-file chunk / field ids used by the semantic-edit test.
  SYSTEM       = 101   # SAVE_DATA -> system (SAVE_SYSTEM)
  HERO         = 104   # SAVE_DATA -> hero (SAVE_MOVABLE)
  SAVE_COUNT   = 131   # SAVE_SYSTEM -> save_count (:int)
  HERO_X       = 12    # SAVE_MOVABLE -> x (:int)

  def initialize
    @errors = 0
    @files = 0
  end

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def first_diff(a, b)
    len = [a.bytesize, b.bytesize].min
    i = 0
    i += 1 while i < len && a.getbyte(i) == b.getbyte(i)
    i
  end

  def check(path)
    puts "== #{path} =="
    original = File.binread(path)

    # 1. Byte-exact round-trip.
    save = LCF::SaveData.new(StringIO.new(original))
    rebuilt = save.to_lcf
    if rebuilt == original
      puts "  round-trip: byte-exact (#{original.bytesize} bytes)"
    else
      off = first_diff(original, rebuilt)
      fail "round-trip differs at byte #{off}: " \
           "orig=#{original.bytesize}B (#{fmt_byte(original, off)}) " \
           "rebuilt=#{rebuilt.bytesize}B (#{fmt_byte(rebuilt, off)})"
    end

    # 2. Semantic edit: bump hero X and the save counter, then reload.
    edit = LCF::SaveData.new(StringIO.new(original))
    hero = edit[HERO]
    sys  = edit[SYSTEM]
    old_x     = hero.x.to_i
    old_count = sys.save_count.to_i

    hero[HERO_X]      = old_x + 1
    sys[SAVE_COUNT]   = old_count + 1
    edit[HERO]        = hero
    edit[SYSTEM]      = sys

    reread = LCF::SaveData.new(StringIO.new(edit.to_lcf))
    new_x     = reread.hero.x.to_i
    new_count = reread[SYSTEM].save_count.to_i
    if new_x == old_x + 1 && new_count == old_count + 1
      puts "  edit: hero.x #{old_x} -> #{new_x}, save_count #{old_count} -> #{new_count} (reloaded OK)"
    else
      fail "edit did not survive reload: hero.x #{old_x}->#{new_x} " \
           "(want #{old_x + 1}), save_count #{old_count}->#{new_count} (want #{old_count + 1})"
    end

    # An untouched chunk (the title block) must be byte-identical after the edit.
    orig_title = LCF::SaveData.new(StringIO.new(original))
                             .instance_variable_get(:@root)
                             .instance_variable_get(:@data)[100]
    edit_title = reread.instance_variable_get(:@root)
                       .instance_variable_get(:@data)[100]
    if orig_title == edit_title
      puts "  edit: untouched title chunk unchanged"
    else
      fail 'editing hero/system perturbed the untouched title chunk'
    end

    @files += 1
  rescue => ex
    fail "#{path}: #{ex.class}: #{ex.message}\n    #{ex.backtrace.first}"
  end

  def fmt_byte(s, off)
    off < s.bytesize ? format('0x%02x', s.getbyte(off)) : 'EOF'
  end

  def report
    puts "round-tripped #{@files} save file(s)"
    if @errors.zero?
      puts 'OK: LCF save writer reproduces and edits real .lsd files'
    else
      warn "#{@errors} error(s)"
    end
  end
end

def discover_saves(root)
  return [] unless Dir.exist?(root)
  Dir.glob(File.join(root, '**', 'Save*.lsd')).sort.uniq
end

saves = ARGV.dup
saves = discover_saves(File.expand_path('../data', __dir__)) if saves.empty?

if saves.empty?
  warn 'no Save*.lsd found (pass a path, or generate one with ' \
       'scripts/gen-lcf-save-wine.bash -- see AGENTS.md)'
  exit 0
end

rt = RoundTripper.new
saves.each { |s| rt.check(s) }
rt.report
exit(rt.errors.zero? ? 0 : 1)
