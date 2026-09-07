#!/usr/bin/env ruby
# encoding: UTF-8
#
# Cross-validates Wolf::Crypt's v3.5 Pro-protected decryption
# (mruby-wolf/mrblib/wolf_crypt_pro.rb) against a real project, the way
# scripts/wolf_data_wolf_check.rb does for Wolf::DataWolf: no genuine
# Pro-protected release is available to test against (protected games are
# not freely redistributable, and none ship with the editor package), so
# this builds a synthetic fixture instead, using this reader's own
# `Wolf::Crypt.encrypt_v35` (the inverse of `decrypt_v35`, itself
# cross-validated against a compiled C++ WolfTL reference -- see
# docs/adr/0094-wolf-rpg-editor-pro-protected.md).
#
# Concretely: copies a real, loose, *unprotected* WOLF RPG Editor project's
# Data/BasicData tree, Pro-protects (v3.5) Game.dat, TileSetData.dat,
# CommonEvent.dat and all three DataBase.dat-shaped files in the copy (a
# real Pro-protected release always leaves the `.project` schema files and
# `Data/MapData/*.mps` plain -- `WolfDataDecrypt.hpp`'s own `PRO_MAGIC` table
# has no entry for either, matching `data.rb`'s own per-file wiring), points
# a second Wolf::Project at the copy, and asserts every field
# scripts/wolf_data_wolf_check.rb's own Checker checks comes back identical
# to the unprotected original.
#
# This is a round-trip check (this reader's own `encrypt_v35` builds the
# fixture, this reader's own `decrypt_v35` reads it back) -- it proves the
# `Crypt.decrypt_protected` seam is wired correctly into every `data.rb`
# caller and that `encrypt_v35`/`decrypt_v35` agree on every byte of a real
# project's Game.dat/TileSetData.dat/CommonEvent.dat/3x DataBase.dat, not
# that this reader is byte-compatible with genuine editor-produced
# protected output (which the compiled-C++-harness cross-validation in the
# ADR is the actual evidence for).
#
# Usage:
#   ruby scripts/wolf_pro_protected_check.rb [PROJECT_DIR]
# With no argument it uses data/wolfrpg-sample-3.724/WOLF_RPG_Editor3, the
# default download-wolfrpg-sample.bash target. Exits non-zero on any
# mismatch.

require 'stringio'
require 'fileutils'
require 'tmpdir'

module LCF
  def self.cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
end

module Wolf
  module LZ4
    def self.decompress(src, dst_size)
      out = +''
      n = src.bytesize
      i = 0
      while i < n
        token = src.getbyte(i)
        i += 1
        lit = token >> 4
        if lit == 15
          loop do
            raise Wolf::Error, 'LZ4: truncated literal length' if i >= n
            b = src.getbyte(i)
            i += 1
            lit += b
            break if b != 255
          end
        end
        if lit > 0
          raise Wolf::Error, 'LZ4: truncated literals' if i + lit > n
          out << src.byteslice(i, lit)
          i += lit
        end
        break if i >= n
        raise Wolf::Error, 'LZ4: truncated match offset' if i + 2 > n
        offset = src.getbyte(i) | (src.getbyte(i + 1) << 8)
        i += 2
        raise Wolf::Error, 'LZ4: zero match offset' if offset == 0
        raise Wolf::Error, 'LZ4: match offset before start of output' if offset > out.bytesize
        mlen = token & 0xf
        if mlen == 15
          loop do
            raise Wolf::Error, 'LZ4: truncated match length' if i >= n
            b = src.getbyte(i)
            i += 1
            mlen += b
            break if b != 255
          end
        end
        mlen += Wolf::LZ4::MIN_MATCH
        start = out.bytesize - offset
        if offset >= mlen
          out << out.byteslice(start, mlen)
        else
          old_size = out.bytesize
          out << ("\0" * mlen)
          mlen.times { |k| out.setbyte(old_size + k, out.getbyte(start + k)) }
        end
      end
      if out.bytesize != dst_size
        raise Wolf::Error, "LZ4: decoded #{out.bytesize} bytes, expected #{dst_size}"
      end
      out
    end
  end
end

mrblib = File.expand_path('../mruby-wolf/mrblib', __dir__)
load File.join(mrblib, 'wolf.rb')
load File.join(mrblib, 'wolf_crypt_pro.rb')
load File.join(mrblib, 'data_wolf.rb')
load File.join(mrblib, 'data.rb')

loose_dir = ARGV[0] || File.expand_path('../data/wolfrpg-sample-3.724/WOLF_RPG_Editor3', __dir__)
unless Wolf::Project.project?(loose_dir)
  puts "No loose WOLF RPG Editor project at #{loose_dir}; nothing to check."
  exit 0
end

# file -> WolfFileType for every file `Crypt::PRO_MAGIC` has an entry for.
# `.project` schema files and every Data/MapData/*.mps map are left exactly
# as they are -- see this file's header on why (no PRO_MAGIC entry for
# either, matching data.rb's own wiring).
PROTECT = {
  'Game.dat' => Wolf::Crypt::FileType::GAME_DAT,
  'TileSetData.dat' => Wolf::Crypt::FileType::TILE_SET_DATA,
  'CommonEvent.dat' => Wolf::Crypt::FileType::COMMON_EVENT,
  'DataBase.dat' => Wolf::Crypt::FileType::DATA_BASE,
  'CDataBase.dat' => Wolf::Crypt::FileType::DATA_BASE,
  'SysDatabase.dat' => Wolf::Crypt::FileType::DATA_BASE
}.freeze

# Deterministic filler for the discarded (offsets 0..142) region of the
# protected buffer -- any values work (see wolf_crypt_pro.rb's own
# `encrypt_v35` doc comment), a fixed pattern just keeps this script
# reproducible across runs.
def junk(seed, size)
  Array.new(size) { |i| ((i * 0x1F) + seed) & 0xFF }
end

Dir.mktmpdir('wolf-pro-protected-check') do |protected_dir|
  # `Dir.mktmpdir` already created `protected_dir`; `cp_r(src, dst)` with an
  # existing `dst` copies *into* it, so remove it first to get an exact copy
  # of `loose_dir` at `protected_dir` instead of `protected_dir/<basename>`.
  FileUtils.rm_rf(protected_dir)
  FileUtils.cp_r(loose_dir, protected_dir)

  basic_dir = File.join(protected_dir, 'Data', 'BasicData')
  protected_count = 0
  PROTECT.each do |name, file_type|
    path = File.join(basic_dir, name)
    next unless File.exist?(path)

    original = File.binread(path)
    header10 = original.byteslice(0, 10).bytes
    # `plain_body` stays a byte String, never an Array -- a real
    # CommonEvent.dat easily exceeds mruby's Array length cap; see
    # wolf_crypt_pro.rb's own portability note and `encrypt_v35`'s.
    plain_body = original.byteslice(10, original.bytesize - 10)

    unless header10[0] == 0x00
      raise "#{name}: not a plain (indicator 0) file -- fixture assumptions do not hold"
    end

    expected_magic = Wolf::Crypt::PRO_MAGIC[file_type][:magic]
    unless header10 == expected_magic
      raise "#{name}: header #{header10.inspect} != expected plain-file prefix #{expected_magic.inspect}"
    end

    protected_header = header10.dup
    protected_header[1] = 0x50 # Crypt.protected? marker
    protected_header[5] = 0x57 # cryptVersion >= 0x57 selects the v3.5 scheme

    cipher = Wolf::Crypt.encrypt_v35(
      plain_body, file_type,
      header10: protected_header,
      junk1_10: junk(name.bytesize, 10),
      junk2_123: junk(name.bytesize + 1, 123)
    )
    raise "#{name}: encrypt_v35 did not round-trip through Crypt.protected?" unless Wolf::Crypt.protected?(cipher)

    File.binwrite(path, cipher)
    protected_count += 1
  end
  puts "Pro-protected #{protected_count} file(s) under #{basic_dir}"

  loose = Wolf::Project.new(loose_dir)
  protected_project = Wolf::Project.new(protected_dir)

  errors = 0
  check = lambda do |label, a, b|
    if a != b
      errors += 1
      warn "  MISMATCH #{label}: loose=#{a.inspect} protected=#{b.inspect}"
    end
  end

  check.call('game.title', loose.game.title, protected_project.game.title)
  check.call('game.tile_size', loose.game.tile_size, protected_project.game.tile_size)
  check.call('game.utf8', loose.game.utf8, protected_project.game.utf8)
  check.call('map_tree.map_ids', loose.map_tree.map_ids, protected_project.map_tree.map_ids)
  check.call('tilesets.size', loose.tilesets.size, protected_project.tilesets.size)
  loose.databases.each do |key, db|
    pdb = protected_project.databases[key]
    check.call("databases[#{key}].types.size", db.types.size, pdb.types.size)
    db.types.each_with_index do |t, i|
      check.call("databases[#{key}].types[#{i}].name", t.name, pdb.types[i].name)
    end
  end
  check.call('common_events.size', loose.common_events.size, protected_project.common_events.size)

  maps = 0
  loose.map_tree.map_ids.each do |id|
    file = loose.map_file(id)
    next unless file
    lm = loose.map(id)
    pm = protected_project.map(id)
    maps += 1
    check.call("map #{id} (#{file}) width", lm.width, pm.width)
    check.call("map #{id} (#{file}) height", lm.height, pm.height)
    check.call("map #{id} (#{file}) layers", lm.layers, pm.layers)
    check.call("map #{id} (#{file}) events.size", lm.events.size, pm.events.size)
  end
  puts "Compared #{maps} maps (left unprotected, as this reader has no Pro-protection story for Map)."

  if errors > 0
    warn "#{errors} mismatch(es) between the unprotected project and its Pro-protected round-trip"
    exit 1
  end
  puts 'Wolf::Crypt v3.5 Pro-protected round-trip matches the unprotected project exactly.'
end
