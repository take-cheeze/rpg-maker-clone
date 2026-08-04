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
# the native Audio/RPGXP shell) so the check can drive real event command lists
# and catch any parameter-shape surprise the synthetic unit tests can't.
module Audio
  def self.bgm_play(*); end
  def self.bgs_play(*); end
  def self.me_play(*); end
  def self.se_play(*); end
end
class RPGXP; end
load File.join(mrblib, "game.rb")
load File.join(mrblib, "interpreter.rb")
load File.join(mrblib, "rgssad.rb")
require "tmpdir"

# Resolver over the database's common events for Call Common Event.
class CommonResolver
  def initialize(commons)
    @commons = commons || []
  end

  def common_event_list(id)
    ce = @commons[id]
    ce && ce.list
  end
end

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

    check_system(db.system)
    check_actors(db.actors)
    @db = db
    check_game_actors(db)
    check_tilesets(db.tilesets)
    @resolver = CommonResolver.new(db.common_events)
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
    expect(sys.party_members.is_a?(Array) && !sys.party_members.empty?,
           "System.party_members must be a non-empty Array")
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

  # Build the live RPGXP::Game::Actor for every database actor and assert its
  # derived state resolves: stats read from the parameters table at the actor's
  # level (so a mis-sized table or bad level surfaces here), HP/SP start full, and
  # the skills / equipment lists are well-formed. This exercises the actor model
  # the Change-Actor commands and actor conditionals build on, over real data.
  def check_game_actors(db)
    built = 0
    db.actors.compact.each do |a|
      ga = RPGXP::Game::Actor.new(db, a.id)
      expect(ga.max_hp.to_i > 0, "actor #{a.id} Game::Actor max_hp must be positive (got #{ga.max_hp.inspect})")
      expect(ga.max_sp.to_i >= 0, "actor #{a.id} Game::Actor max_sp must be non-negative")
      expect(ga.hp == ga.max_hp && ga.sp == ga.max_sp, "actor #{a.id} must start at full HP/SP")
      expect(ga.skills.is_a?(Array), "actor #{a.id} skills must be an Array")
      expect([true, false].include?(ga.weapon_equipped?(a.weapon_id.to_i)),
             "actor #{a.id} weapon_equipped? must be boolean")
      built += 1
    end
    first = db.actors.compact.first
    sample = first && RPGXP::Game::Actor.new(db, first.id)
    puts "  game-actors: #{built} built" +
         (sample ? " (e.g. #{sample.name.inspect} Lv#{sample.level} HP#{sample.max_hp} skills=#{sample.skills.size})" : "")
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
      drive_events(id, map)
      @maps += 1
    end
  end

  # Drive each event's active page through the real interpreter, auto-answering
  # messages/choices, so the genuine command lists decode and run end to end
  # without raising (a battle/other unsupported command is skipped, not fatal).
  def drive_events(map_id, map)
    (map.events || {}).each do |eid, ev|
      page = RPGXP::Game::EventPage.select(ev.pages, Hash.new(false),
                                           Hash.new(0), ->(_ch) { false })
      next unless page && page.list && page.list.any? { |c| c.code != 0 }
      state = RPGXP::Game::State.new(@db, @db.system.party_members, map_id, ev.x, ev.y)
      it = RPGXP::Game::Interpreter.new(state)
      it.resolver = @resolver
      it.start(page.list, map_id, eid)
      pump(it)
    end
  rescue => ex
    fail "Map#{map_id}: interpreter raised: #{ex.class}: #{ex.message}"
  end

  def pump(it, limit = 5000)
    steps = 0
    while (it.running? || it.waiting?) && steps < limit
      if it.waiting?
        case it.wait_kind
        when :choice then it.choose(0)
        when :number then it.resume_number(0)
        when :teleport then break
        else it.resume
        end
      else
        it.update
      end
      steps += 1
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
  def check_archive(dir, disk)
    files = Dir[File.join(dir, "Data", "*.rxdata")].sort.map do |f|
      ["Data\\#{File.basename(f)}", File.binread(f)]
    end
    check_archive_format(disk, files, 1, "Game.rgssad",
                         RPGXP::RGSSAD.pack_v1(files))
    check_archive_format(disk, files, 3, "Game.rgss3a",
                         RPGXP::RGSSAD.pack_v3(files))
  rescue => ex
    fail "#{dir}: archive check raised: #{ex.class}: #{ex.message}"
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
    end
    puts "  archive: packed #{files.size} entries; DB loads identically through #{filename}"
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

def discover_games(root)
  return [] unless Dir.exist?(root)
  Dir.glob(File.join(root, "**", "Data", "System.rxdata"))
     .map { |f| File.dirname(File.dirname(f)) }.sort.uniq
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
