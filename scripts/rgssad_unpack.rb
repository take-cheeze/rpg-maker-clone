#!/usr/bin/env ruby
# encoding: UTF-8
#
# Unpack an RPG Maker XP/VX/VX Ace packed archive (Game.rgssad / .rgss2a /
# .rgss3a) into a loose file tree.
#
# Why this exists: RGSSData#read_object and Bitmap#init_from_archive already
# prefer a loose file over the packed archive ("loose shadows packed, as in
# RGSS" -- mruby-rgss/mrblib/lib.rb) -- but RGSSData#open_archive still
# unconditionally reads the *whole* packed archive into memory the moment it
# finds one on disk, whether or not anything inside it ends up used. On a
# RAM-constrained target like the PSP (~24 MB usable, see
# docs/adr/0047-psp-memory-budget.md) that whole-archive read can exceed the
# entire budget by itself for a real released game. Unpacking once, offline,
# and excluding the packed archive from that deployment avoids the read
# entirely -- no interpreter or gem changes needed, since the loose-file path
# already exists and is already preferred.
#
# The reader (mruby-rpgxp/mrblib/rgssad.rb) is written in the mruby/CRuby
# common subset specifically so it runs under plain CRuby too (see its own
# comment, and scripts/rpgxp_testbed_check.rb, which loads it the same way);
# this script does the same rather than reimplementing the format.
#
# Usage:
#   ruby scripts/rgssad_unpack.rb GAME_DIR [DEST_DIR]
# DEST_DIR defaults to GAME_DIR itself (unpack in place, beside the archive,
# which is what a PSP deployment wants: the loose tree lands exactly where
# the loose-file-first loaders already look). Never touches the packed
# archive itself -- removing it from a given deployment (so it is never
# eagerly opened) is a separate, deliberate step; see the ADR.

require "fileutils"

mrblib = File.expand_path("../mruby-rpgxp/mrblib", __dir__)
class RPGXP; end
load File.join(mrblib, "rgssad.rb")

# Unpack every entry of the archive found under +game_dir+ into +dest_dir+,
# preserving the archive's relative paths ('\' separators normalised to '/').
# Returns [archive_path, unpacked entry count]. Raises if no archive is found.
def rgssad_unpack(game_dir, dest_dir)
  path = RPGXP::RGSSAD.find(game_dir)
  raise "no Game.rgssad/.rgss2a/.rgss3a found under #{game_dir}" unless path

  archive = RPGXP::RGSSAD.open(path)
  archive.names.each do |name|
    out_path = File.join(dest_dir, name.tr("\\", "/"))
    FileUtils.mkdir_p(File.dirname(out_path))
    File.binwrite(out_path, archive.read(name))
  end
  [path, archive.names.size]
end

if $PROGRAM_NAME == __FILE__
  game_dir = ARGV[0] or abort "usage: ruby scripts/rgssad_unpack.rb GAME_DIR [DEST_DIR]"
  dest_dir = ARGV[1] || game_dir

  begin
    archive_path, count = rgssad_unpack(game_dir, dest_dir)
  rescue => e
    abort e.message
  end
  puts "unpacked #{count} files from #{archive_path} into #{dest_dir}"
end
