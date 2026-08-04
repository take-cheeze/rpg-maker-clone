#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test the RPG Maker MV *data layer* against a test-bed project.
#
# Unlike the LCF (RPG2000/2003) and RGSS (XP/VX) makers, MV's game logic is the
# game's own JavaScript — we do not reimplement it in Ruby, so there is no Ruby
# schema to load the way scripts/lcf_testbed_check.rb / rpgxp_testbed_check.rb
# do. What we *can* validate cheaply and deterministically, with no native build
# and no JS engine, is the `data/*.json` database the engine reads to boot: that
# it parses, and that the boot-critical invariants hold (a start map that
# exists and is the right size, a tileset and party actors whose ids resolve).
#
# This matters because the native MV smoke steps in CI (`--mv_new_game`,
# `--mv_move_test`, ...) are all `continue-on-error` — a corrupted sample
# database would render garbage or fail to reach the map without failing the
# build. This check is the blocking guard: run under CRuby, it fails the build
# the moment the committed `data/mv-sample` database (authored by
# scripts/gen-mv-sample.py) regresses, before the non-blocking native smokes
# ever run. It also validates a downloaded MV test bed (data/Lunatic-Core) when
# present.
#
# Usage:
#   ruby scripts/mv_testbed_check.rb [PROJECT_DIR ...]
# With no arguments it scans ./data for subdirectories that contain
# data/System.json (an MV project's database). The committed data/mv-sample is
# always found; downloaded beds (data/Lunatic-Core) are picked up when present.
# Exits non-zero if any file fails to parse or a boot invariant is violated.

require "json"

# MV stores each of Actors/Classes/Items/... as a 1-based array whose element 0
# is null. Map cell data is width*height*Z int tiles, Z = 6 z-layers (the four
# tile layers plus shadow-pen and region-id planes). A tileset carries 9 image
# names (A1-A5, B, C, D, E) and a 0x2000-entry passage-flag table.
MV_MAP_LAYERS = 6
MV_TILESET_NAMES = 9
MV_TILESET_FLAGS = 8192

class Checker
  def initialize
    @errors = 0
    @projects = 0
    @maps = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def expect(cond, msg)
    fail(msg) unless cond
  end

  # Read and parse a data/<name> JSON file, failing (and returning nil) if it is
  # missing or malformed. `required` distinguishes a boot-critical file (missing
  # is a failure) from an optional one (missing is fine, e.g. a game with no
  # common events).
  def load_json(dir, name, required: true)
    path = File.join(dir, "data", name)
    unless File.exist?(path)
      fail("#{name}: missing") if required
      return nil
    end
    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    fail("#{name}: invalid JSON — #{e.message}")
    nil
  end

  def check_project(dir)
    puts "== #{dir} =="
    @projects += 1

    system = load_json(dir, "System.json")
    return unless system

    actors = load_json(dir, "Actors.json")
    classes = load_json(dir, "Classes.json")
    tilesets = load_json(dir, "Tilesets.json")
    mapinfos = load_json(dir, "MapInfos.json")

    check_system(system, actors)
    check_actors(actors, classes)
    start_id = system["startMapId"]
    check_start_map(dir, start_id, tilesets, mapinfos) if start_id.is_a?(Integer)
  rescue => e # a truly unexpected failure should surface, not abort the sweep
    fail("#{dir}: #{e.class}: #{e.message}")
  end

  def check_system(system, actors)
    expect(system["gameTitle"].is_a?(String), "System.gameTitle must be a String")

    start = system["startMapId"]
    expect(start.is_a?(Integer) && start >= 1,
           "System.startMapId must be a positive Integer (got #{start.inspect})")
    %w[startX startY].each do |k|
      v = system[k]
      expect(v.is_a?(Integer) && v >= 0,
             "System.#{k} must be a non-negative Integer (got #{v.inspect})")
    end

    party = system["partyMembers"]
    if party.is_a?(Array) && !party.empty?
      party.each do |aid|
        expect(actor_at(actors, aid),
               "System.partyMembers references actor #{aid.inspect}, " \
               "which is missing from Actors.json")
      end
    else
      fail("System.partyMembers must be a non-empty Array (got #{party.inspect})")
    end

    puts "  system: title=#{system['gameTitle'].inspect} " \
         "start=(#{start},#{system['startX']},#{system['startY']}) " \
         "party=#{party.inspect}"
  end

  def check_actors(actors, classes)
    unless actors.is_a?(Array)
      fail("Actors.json must be an Array")
      return
    end
    expect(actors[0].nil?, "Actors[0] should be null (1-based table)")
    actors.compact.each do |a|
      cid = a["classId"]
      expect(class_at(classes, cid),
             "actor #{a['id']} has classId #{cid.inspect}, " \
             "which is missing from Classes.json")
      c = class_at(classes, cid)
      check_class_params(c) if c
    end
    puts "  actors: #{actors.compact.size} " \
         "(e.g. #{actors.compact.first&.dig('name').inspect})"
  end

  # An MV class's params are an 8xN grid: the eight base parameters (MHP, MMP,
  # ATK, DEF, MAT, MDF, AGI, LUK) tabulated per level. The engine indexes it by
  # [paramId][level], so a wrong shape breaks Game_Actor.paramBase on the map.
  def check_class_params(c)
    params = c["params"]
    unless params.is_a?(Array) && params.length == 8
      fail("class #{c['id']} params must be an 8-row Array (got #{params.class})")
      return
    end
    len = params.first.is_a?(Array) ? params.first.length : -1
    expect(len >= 2, "class #{c['id']} params rows too short (#{len})")
    params.each_with_index do |row, i|
      expect(row.is_a?(Array) && row.length == len,
             "class #{c['id']} params row #{i} has a ragged length")
    end
  end

  def check_start_map(dir, start_id, tilesets, mapinfos)
    if mapinfos.is_a?(Array)
      expect(mapinfos.compact.any? { |m| m["id"] == start_id },
             "MapInfos.json has no entry for startMapId #{start_id}")
    else
      fail("MapInfos.json must be an Array")
    end

    name = format("Map%03d.json", start_id)
    map = load_json(dir, name)
    return unless map

    @maps += 1
    w = map["width"]
    h = map["height"]
    expect(w.is_a?(Integer) && w > 0, "#{name}.width must be a positive Integer")
    expect(h.is_a?(Integer) && h > 0, "#{name}.height must be a positive Integer")

    data = map["data"]
    if w.is_a?(Integer) && h.is_a?(Integer) && data.is_a?(Array)
      want = w * h * MV_MAP_LAYERS
      expect(data.length == want,
             "#{name}.data has #{data.length} tiles, expected " \
             "#{want} (#{w}x#{h}x#{MV_MAP_LAYERS})")
    else
      fail("#{name}.data must be an Array")
    end

    tid = map["tilesetId"]
    tileset = tileset_at(tilesets, tid)
    expect(tileset, "#{name}.tilesetId #{tid.inspect} is missing from Tilesets.json")
    check_tileset(tileset, tid) if tileset

    puts "  start map #{name}: #{w}x#{h} tileset=#{tid}"
  end

  def check_tileset(tileset, tid)
    names = tileset["tilesetNames"]
    expect(names.is_a?(Array) && names.length == MV_TILESET_NAMES,
           "tileset #{tid} tilesetNames must have #{MV_TILESET_NAMES} entries " \
           "(got #{names.is_a?(Array) ? names.length : names.class})")
    flags = tileset["flags"]
    expect(flags.is_a?(Array) && flags.length == MV_TILESET_FLAGS,
           "tileset #{tid} flags must have #{MV_TILESET_FLAGS} entries " \
           "(got #{flags.is_a?(Array) ? flags.length : flags.class})")
  end

  # 1-based-array accessors: element 0 is null in MV, so a valid id yields a
  # non-null entry. Guards against a non-Integer id or an out-of-range index.
  def actor_at(actors, id)
    entry_at(actors, id)
  end

  def class_at(classes, id)
    entry_at(classes, id)
  end

  def tileset_at(tilesets, id)
    entry_at(tilesets, id)
  end

  def entry_at(arr, id)
    return nil unless arr.is_a?(Array) && id.is_a?(Integer) && id >= 1 && id < arr.length
    arr[id]
  end

  def summary
    puts
    puts "MV test-bed check: #{@projects} project(s), #{@maps} start map(s), " \
         "#{@errors} error(s)"
  end
end

# --- Discover projects and run ---------------------------------------------

def mv_project?(dir)
  File.exist?(File.join(dir, "data", "System.json"))
end

def discover(root)
  return [] unless File.directory?(root)
  Dir.children(root).sort.map { |c| File.join(root, c) }.select do |p|
    File.directory?(p) && mv_project?(p)
  end
end

args = ARGV.dup
projects =
  if args.empty?
    discover(File.expand_path("../data", __dir__))
  else
    args.map { |a| File.expand_path(a) }
  end

if projects.empty?
  warn "No MV projects found (looked for <dir>/data/System.json). " \
       "Nothing to check."
  # Not an error: on a fresh checkout without downloaded beds, the committed
  # data/mv-sample is still present, so an empty result usually means the script
  # was pointed at the wrong place. Exit 0 so it never spuriously blocks CI.
  exit 0
end

checker = Checker.new
projects.each do |dir|
  unless mv_project?(dir)
    checker.fail("#{dir}: not an MV project (no data/System.json)")
    next
  end
  checker.check_project(dir)
end
checker.summary

exit(checker.errors.zero? ? 0 : 1)
