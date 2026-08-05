#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test the RPG Maker XP data layer against a real test-bed project.
#
# The schema (mruby-rpgxp/mrblib/rgss_data.rb) is written in the mruby/CRuby
# common subset, so this harness loads that exact file under CRuby and drives
# RPGXP::RGSSData over a downloaded game's Data/*.rxdata. In the real build the
# `.rxdata` streams are read by mruby-marshal and the RGSS value types
# (Table/Color/Tone/Rect) are the native C classes; here CRuby's own Marshal does
# the reading and the value types are provided by the small shims below (only
# their structure is asserted, so the shims never change the result).
#
# It exercises the loaders against genuine editor output — where format
# surprises (an object whose class we forgot to declare, a table whose size does
# not match its map) actually show up — the way scripts/lcf_testbed_check.rb does
# for the RPG2000 side.
#
# Usage:
#   ruby scripts/rpgxp_testbed_check.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories that contain Data/System.rxdata.
# Exits non-zero if any file fails to parse or an invariant is violated.

# --- RGSS value-type shims (native classes in the real build) --------------

# RGSS Table: an N-dimensional grid of int16s. Marshal payload is five int32
# little-endian header words (dim, xsize, ysize, zsize, item count) followed by
# that many int16s. Matches src/lib.cxx table_load exactly.
class Table
  attr_reader :dim, :xsize, :ysize, :zsize, :data

  def self._load(s)
    dim, x, y, z, count = s[0, 20].unpack("l<5")
    t = allocate
    t.instance_variable_set(:@dim, dim)
    t.instance_variable_set(:@xsize, x)
    t.instance_variable_set(:@ysize, y)
    t.instance_variable_set(:@zsize, z)
    t.instance_variable_set(:@data, s[20, count * 2].unpack("s<#{count}"))
    t
  end

  def [](x, y = 0, z = 0)
    @data[x + @xsize * (y + @ysize * z)]
  end
end

# Color / Tone: four doubles (r,g,b,a|grey). Rect: four int32s. Only presence is
# needed for the check, so keep the payload verbatim.
class Color; def self._load(s); c = allocate; c.instance_variable_set(:@v, s.unpack("E4")); c; end; end
class Tone;  def self._load(s); c = allocate; c.instance_variable_set(:@v, s.unpack("E4")); c; end; end
class Rect;  def self._load(s); r = allocate; r.instance_variable_set(:@v, s.unpack("l<4")); r; end; end

# --- Load the real schema --------------------------------------------------

mrblib = File.expand_path("../mruby-rpgxp/mrblib", __dir__)
load File.join(mrblib, "rgss_data.rb")

# The event interpreter is host-runnable too; load it (with tiny stand-ins for
# the native Audio/RPGXP shell) so the data layer can be loaded and walked
# without a display.
module Audio
  def self.bgm_play(*); end
  def self.bgs_play(*); end
  def self.me_play(*); end
  def self.se_play(*); end
end
class RPGXP; end
load File.join(mrblib, "rgssad.rb")
require "tmpdir"

class Checker
  def initialize
    @errors = 0
    @maps = 0
    @events = 0
    @commands = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def expect(cond, msg)
    fail(msg) unless cond
  end

  def check_game(dir)
    puts "== #{dir} =="
    db = RPGXP::RGSSData.new(dir)
    @db = db

    check_system(db.system)
    check_actors(db.actors)
    check_tilesets(db.tilesets)
    check_maps(db)
    check_archive(dir, db)
  rescue => ex
    fail "#{dir}: #{ex.class}: #{ex.message}"
  end

  def check_system(sys)
    expect(sys.is_a?(RPG::System), "System is #{sys.class}, not RPG::System")
    expect(sys.start_map_id.to_i > 0, "System.start_map_id must be positive")
    expect(sys.title_name.is_a?(String), "System.title_name must be a String")
    expect(sys.words.is_a?(RPG::System::Words), "System.words missing")
    expect(sys.title_bgm.is_a?(RPG::AudioFile), "System.title_bgm must be an AudioFile")
    # An *empty* starting party is legal and real games use it: Pray for You
    # starts on an empty opening map and adds its members from that map's
    # autorun event, so RMXP's editor field is left blank. What must hold is
    # that every id it does list resolves to a database actor, which is what a
    # mis-decoded field would break.
    expect(sys.party_members.is_a?(Array), "System.party_members must be an Array")
    (sys.party_members || []).each do |id|
      expect(@db.actors[id].is_a?(RPG::Actor),
             "System.party_members lists actor #{id.inspect}, which is not in Actors")
    end
    puts "  system: title=#{sys.title_name.inspect} start=(#{sys.start_map_id},#{sys.start_x},#{sys.start_y}) party=#{sys.party_members.inspect}"
  end

  def check_actors(actors)
    expect(actors.is_a?(Array), "Actors must be an Array")
    expect(actors[0].nil?, "Actors[0] should be nil (1-based table)")
    actors.compact.each do |a|
      expect(a.is_a?(RPG::Actor), "actor #{a.inspect} is not an RPG::Actor")
      expect(a.name.is_a?(String), "actor #{a.id} has no name")
      expect(a.parameters.is_a?(Table), "actor #{a.id} parameters must be a Table")
    end
    puts "  actors: #{actors.compact.size} (e.g. #{actors.compact.first&.name.inspect})"
  end

  def check_tilesets(tilesets)
    tilesets.compact.each do |t|
      expect(t.passages.is_a?(Table), "tileset #{t.id} passages must be a Table")
      expect(t.priorities.is_a?(Table), "tileset #{t.id} priorities must be a Table")
      expect(t.autotile_names.is_a?(Array), "tileset #{t.id} autotile_names must be an Array")
    end
    puts "  tilesets: #{tilesets.compact.size}"
  end

  def check_maps(db)
    db.map_infos.each do |id, info|
      expect(info.is_a?(RPG::MapInfo), "MapInfos[#{id}] is not an RPG::MapInfo")
      map = db.load_map(id)
      expect(map.is_a?(RPG::Map), "Map#{id} is not an RPG::Map")
      w = map.width.to_i
      h = map.height.to_i
      expect(w > 0 && h > 0, "Map#{id}: non-positive dimensions #{w}x#{h}")

      tbl = map.data
      expect(tbl.is_a?(Table), "Map#{id}: data is not a Table")
      if tbl.is_a?(Table)
        expect(tbl.xsize == w && tbl.ysize == h,
               "Map#{id}: data #{tbl.xsize}x#{tbl.ysize} != map #{w}x#{h}")
        expect(tbl.data.size == tbl.xsize * tbl.ysize * tbl.zsize,
               "Map#{id}: data payload #{tbl.data.size} != #{tbl.xsize}x#{tbl.ysize}x#{tbl.zsize}")
      end

      check_events(id, map)
      @maps += 1
    end
  end

  def check_events(map_id, map)
    (map.events || {}).each do |eid, ev|
      expect(ev.is_a?(RPG::Event), "Map#{map_id} event #{eid} is not an RPG::Event")
      expect(ev.pages.is_a?(Array) && !ev.pages.empty?,
             "Map#{map_id} event #{eid} has no pages")
      @events += ev.pages.size
      ev.pages.each do |page|
        expect(page.condition.is_a?(RPG::Event::Page::Condition),
               "Map#{map_id} event #{eid}: page condition missing")
        expect(page.graphic.is_a?(RPG::Event::Page::Graphic),
               "Map#{map_id} event #{eid}: page graphic missing")
        (page.list || []).each do |cmd|
          expect(cmd.is_a?(RPG::EventCommand),
                 "Map#{map_id} event #{eid}: command #{cmd.inspect} is not an RPG::EventCommand")
          @commands += 1
        end
      end
    end
  end

  # Pack the real Data/*.rxdata into an encrypted archive, then load the whole
  # database back through it and confirm it is identical to the on-disk load —
  # exercising the RGSSAD reader against real file sizes/contents and the
  # RGSSData archive fallback end to end. Both the v1 (`.rgssad`, XP/VX) and v3
  # (`.rgss3a`, VX Ace) formats are checked against the same real data.
  # A 3x2 XYZ picture (palette 0 = (10,20,30), 1 red, 2 green), packed alongside
  # the data so the asset half of the archive is covered too. Decoding it is
  # native and is tested in mruby-rgss; what matters here is that the name a
  # game actually uses resolves.
  GRAPHIC_XYZ = ("\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb" \
                 "\xcf\xc0\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4" \
                 "\xc8\x00\x00\xb4\x8b\x02\x41").b

  def check_archive(dir, disk)
    files = archive_source_data(dir, disk)
    if files.empty?
      fail "#{dir}: no Data/*.rxdata to pack, loose or archived"
      return
    end
    # A released game packs Graphics/ into the same archive as Data/, with no
    # loose copy on disk — so this is the only route to the game's art.
    files += [["Graphics\\Titles\\Castle.xyz", GRAPHIC_XYZ]]
    check_archive_format(disk, files, 1, "Game.rgssad",
                         RPGXP::RGSSAD.pack_v1(files))
    check_archive_format(disk, files, 3, "Game.rgss3a",
                         RPGXP::RGSSAD.pack_v3(files))
  rescue => ex
    fail "#{dir}: archive check raised: #{ex.class}: #{ex.message}"
  end

  # The Data/ entries to re-pack, as [archive name, bytes]. An editor project
  # has them loose on disk; a *released* game — the shape most XP games ship in,
  # and the one this check most wants to cover — has none, only the entries
  # inside its own Game.rgssad. Reading those back out and re-packing them keeps
  # the round-trip meaningful there instead of failing on an empty Data/.
  def archive_source_data(dir, disk)
    loose = Dir[File.join(dir, "Data", "*.rxdata")].sort.map do |f|
      ["Data\\#{File.basename(f)}", File.binread(f)]
    end
    return loose unless loose.empty?
    return [] unless disk.archived?
    disk.archive.names.sort.select { |n| n =~ /\AData[\\\/].*\.rxdata\z/i }
        .map { |n| [n, disk.archive.read(n)] }
  end

  def check_archive_format(disk, files, version, filename, archive)
    # Reading one entry back must reproduce the original bytes exactly.
    reader = RPGXP::RGSSAD.new(archive)
    expect(reader.version == version, "#{filename}: version is #{reader.version}, not #{version}")
    files.each do |name, bytes|
      got = reader.read(name)
      expect(got == bytes, "#{filename} entry #{name} did not round-trip byte-for-byte")
    end

    Dir.mktmpdir do |tmp|
      File.binwrite(File.join(tmp, filename), archive)
      File.write(File.join(tmp, "Game.ini"), "[Game]\nTitle=Packed\n")
      packed = RPGXP::RGSSData.new(tmp) # no loose Data/ -> uses the archive
      expect(packed.archived?, "#{filename}: packed project should report archived?")
      expect(packed.system.start_map_id == disk.system.start_map_id,
             "#{filename}: System.start_map_id differs from on-disk")
      expect(packed.system.title_name == disk.system.title_name,
             "#{filename}: System.title_name differs from on-disk")
      expect(packed.actors.compact.size == disk.actors.compact.size,
             "#{filename}: Actors count differs from on-disk")
      disk.map_infos.each_key do |id|
        pm = packed.load_map(id)
        dm = disk.load_map(id)
        expect(pm.width == dm.width && pm.height == dm.height,
               "#{filename}: Map#{id} dimensions differ from on-disk")
      end
      # The asset half: a game asks by the bare, '/'-spelled name
      # (`Bitmap.new("Graphics/Titles/Castle")`), so the archive has to answer
      # that spelling, and the boot shell hands this same object to
      # RGSS.asset_archive for the native loaders to read through.
      expect(!packed.archive.nil?, "#{filename}: packed project exposes no archive")
      expect(packed.archive.read("Graphics/Titles/Castle.xyz") == GRAPHIC_XYZ,
             "#{filename}: a packed graphic did not read back by its " \
             "'/'-spelled name")
    end
    puts "  archive: packed #{files.size} entries (Data/ + a graphic); DB and " \
         "assets both load through #{filename}"
  end

  def report
    puts "checked #{@maps} maps, #{@events} event pages, #{@commands} event commands"
    if @errors.zero?
      puts "OK: all XP test-bed data parsed cleanly"
    else
      warn "#{@errors} error(s)"
    end
  end
end

# Every XP project under `root`: an editor project (a loose Data/System.rxdata)
# or a *released* one, whose whole tree — Data/ included — is inside an
# encrypted Game.rgssad and which therefore has no loose Data/ to glob for.
def discover_games(root)
  return [] unless Dir.exist?(root)
  loose = Dir.glob(File.join(root, "**", "Data", "System.rxdata"))
             .map { |f| File.dirname(File.dirname(f)) }
  packed = Dir.glob(File.join(root, "**", "Game.rgssad"))
              .map { |f| File.dirname(f) }
  (loose + packed).sort.uniq
end

games = ARGV.dup
games = discover_games(File.expand_path("../data", __dir__)) if games.empty?

if games.empty?
  warn "no XP test-bed game found (pass a GAME_DIR or run scripts/download-opengame-xp.bash first)"
  exit 0
end

checker = Checker.new
games.each { |g| checker.check_game(g) }
checker.report
exit(checker.errors.zero? ? 0 : 1)
