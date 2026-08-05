#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test the RPG Maker MZ *data and asset layer* against a test-bed project.
#
# MZ's game logic is the game's own JavaScript (the fetched `rmmz_*` corescript
# on PIXI v5), so there is no Ruby schema to load the way the LCF/RGSS checks do.
# What can be validated cheaply and deterministically — under plain CRuby, with
# no native build, no JS engine and no GPU — is what the engine needs in order to
# boot: a database that parses and holds together, and the handful of system
# images MZ hard-requires.
#
# The MZ boot is fussier than MV's in two ways this check exists to pin down:
#
#   * `img/system/ButtonSet.png` must be at least 11 blocks (11 * 48 = 528px)
#     wide, because `Sprite_Button.checkBitmap` *throws* ("ButtonSet image is
#     too small") on a smaller sheet — and MZ's touch UI puts those buttons in
#     every scrollable window, so the first map frame aborts without it.
#   * The tileset's flag for tile id 0 must carry 0x10 ("no effect on passage").
#     `Game_Map.checkPassage` walks the four tile layers top-down and the first
#     tile not marked "no effect" decides, so a plain 0 there makes the empty
#     upper layers answer "passable" everywhere and no wall ever blocks.
#
# Both are invisible to a JSON-shape check and fatal (or silently wrong) at run
# time, which is what makes this worth running. It is the blocking guard for the
# committed `data/mz-sample` (authored by scripts/gen-mz-sample.py) ahead of the
# non-blocking native MZ smoke, and it is equally useful pointed at a real,
# user-supplied MZ project.
#
# Usage:
#   ruby scripts/mz_testbed_check.rb [PROJECT_DIR ...]
# With no arguments it scans ./data for subdirectories that look like an MZ
# project (js/rmmz_core.js + data/System.json). Exits non-zero if any file fails
# to parse or a boot invariant is violated.

require "json"

# MZ stores each of Actors/Classes/Items/... as a 1-based array whose element 0
# is null. Map cell data is width*height*Z int tiles, Z = 6 z-layers (four tile
# layers plus the shadow-pen and region-id planes). A tileset carries 9 image
# names (A1-A5, B, C, D, E) and a 0x2000-entry passage-flag table.
MZ_MAP_LAYERS = 6
MZ_TILESET_NAMES = 9
MZ_TILESET_FLAGS = 8192
# Sprite_Button.blockWidth/blockHeight and the 11 button blocks of the sheet.
MZ_BUTTON_BLOCK = 48
MZ_BUTTON_BLOCKS = 11
# The flag bit meaning "no effect on passage" (Game_Map.checkPassage).
MZ_FLAG_NO_PASSAGE_EFFECT = 0x10
# TextManager indexes terms.commands up to 25 (Sell); 23 covers everything the
# title and menu scenes read (18 New Game, 19 Continue, 21 To Title, 22 Cancel).
MZ_MIN_COMMAND_TERMS = 23

# Read a PNG's pixel size straight out of its IHDR chunk, so the asset checks
# need no image library. Returns [width, height], or nil if the file is missing
# or is not a PNG.
def png_size(path)
  return nil unless File.file?(path)
  head = File.binread(path, 24)
  return nil unless head && head.bytesize == 24
  return nil unless head[0, 8] == "\x89PNG\r\n\x1a\n".b
  return nil unless head[12, 4] == "IHDR".b
  head[16, 8].unpack("N2")
end

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
    check_advanced(system, dir)
    check_terms(system)
    check_actors(dir, actors, classes, system)
    check_system_images(dir)
    start_id = system["startMapId"]
    check_start_map(dir, start_id, tilesets, mapinfos, system) if start_id.is_a?(Integer)
  rescue => e # a truly unexpected failure should surface, not abort the sweep
    fail("#{dir}: #{e.class}: #{e.message}")
  end

  def check_system(system, actors)
    expect(system["gameTitle"].is_a?(String), "System.gameTitle must be a String")

    start = system["startMapId"]
    # Scene_Boot.checkPlayerLocation throws outright when this is 0.
    expect(start.is_a?(Integer) && start >= 1,
           "System.startMapId must be a positive Integer (got #{start.inspect}) " \
           "— Scene_Boot throws \"Player's starting position is not set\" otherwise")
    %w[startX startY].each do |k|
      v = system[k]
      expect(v.is_a?(Integer) && v >= 0,
             "System.#{k} must be a non-negative Integer (got #{v.inspect})")
    end

    party = system["partyMembers"]
    if party.is_a?(Array) && !party.empty?
      party.each do |aid|
        expect(entry_at(actors, aid),
               "System.partyMembers references actor #{aid.inspect}, " \
               "which is missing from Actors.json")
      end
    else
      fail("System.partyMembers must be a non-empty Array (got #{party.inspect})")
    end

    size = system["tileSize"]
    expect(size.is_a?(Integer) && size > 0,
           "System.tileSize must be a positive Integer (got #{size.inspect})")

    puts "  system: title=#{system['gameTitle'].inspect} " \
         "start=(#{start},#{system['startX']},#{system['startY']}) " \
         "party=#{party.inspect} tile=#{size.inspect}"
  end

  # MZ's `advanced` block is read during the boot itself: Scene_Boot.resizeScreen
  # takes the screen/UI sizes from it and Scene_Boot.loadGameFonts the font
  # filenames — a missing block throws before the title is ever reached.
  def check_advanced(system, dir)
    adv = system["advanced"]
    unless adv.is_a?(Hash)
      fail("System.advanced must be a Hash (Scene_Boot reads the screen size " \
           "and font names from it)")
      return
    end
    %w[screenWidth screenHeight uiAreaWidth uiAreaHeight].each do |k|
      v = adv[k]
      expect(v.is_a?(Integer) && v > 0,
             "System.advanced.#{k} must be a positive Integer (got #{v.inspect})")
    end
    %w[mainFontFilename numberFontFilename].each do |k|
      expect(adv[k].is_a?(String),
             "System.advanced.#{k} must be a String (\"\" for none)")
      # A named font must be on disk: MZ's FontManager loads it during
      # Scene_Boot and the native text path rasterises it from fonts/, so a
      # dangling name means either a stalled boot or blank text everywhere.
      next unless adv[k].is_a?(String) && !adv[k].empty?
      expect(File.file?(File.join(dir, "fonts", adv[k])),
             "System.advanced.#{k} names #{adv[k].inspect} but " \
             "fonts/#{adv[k]} is missing")
    end
    puts "  advanced: #{adv['screenWidth']}x#{adv['screenHeight']} " \
         "ui=#{adv['uiAreaWidth']}x#{adv['uiAreaHeight']} " \
         "font=#{adv['mainFontFilename'].inspect}"
  end

  # TextManager reads terms.commands by index, so a short table silently blanks
  # the title menu ("New Game" is index 18) rather than failing loudly.
  def check_terms(system)
    terms = system["terms"]
    unless terms.is_a?(Hash)
      fail("System.terms must be a Hash")
      return
    end
    commands = terms["commands"]
    if commands.is_a?(Array)
      expect(commands.length >= MZ_MIN_COMMAND_TERMS,
             "System.terms.commands has #{commands.length} entries, expected at " \
             "least #{MZ_MIN_COMMAND_TERMS} (TextManager indexes 18 New Game, " \
             "19 Continue, 21 To Title, 22 Cancel)")
      expect(commands[18].is_a?(String) && !commands[18].empty?,
             "System.terms.commands[18] (New Game) must be a non-empty String")
    else
      fail("System.terms.commands must be an Array")
    end
    expect(terms["messages"].is_a?(Hash), "System.terms.messages must be a Hash")
    %w[basic params].each do |k|
      expect(terms[k].is_a?(Array), "System.terms.#{k} must be an Array")
    end
  end

  def check_actors(dir, actors, classes, system)
    unless actors.is_a?(Array)
      fail("Actors.json must be an Array")
      return
    end
    expect(actors[0].nil?, "Actors[0] should be null (1-based table)")
    actors.compact.each do |a|
      cid = a["classId"]
      c = entry_at(classes, cid)
      expect(c, "actor #{a['id']} has classId #{cid.inspect}, " \
                "which is missing from Classes.json")
      check_class_params(c) if c
    end

    # The party's sprites are loaded the moment the map scene builds, so a
    # referenced sheet that is not on disk shows an invisible player.
    party = system["partyMembers"]
    Array(party).each do |aid|
      a = entry_at(actors, aid)
      next unless a
      name = a["characterName"]
      next unless name.is_a?(String) && !name.empty?
      path = File.join(dir, "img", "characters", "#{name}.png")
      expect(File.file?(path),
             "actor #{aid} characterName #{name.inspect} has no " \
             "img/characters/#{name}.png")
    end

    puts "  actors: #{actors.compact.size} " \
         "(e.g. #{actors.compact.first&.dig('name').inspect})"
  end

  # An MZ class's params are an 8xN grid: the eight base parameters (MHP, MMP,
  # ATK, DEF, MAT, MDF, AGI, LUK) tabulated per level, indexed [paramId][level].
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

  # The system art the MZ boot and its scenes hard-require. Scene_Boot preloads
  # the windowskin and the icon sheet; every window with a scrollbar or a cancel
  # button builds a Sprite_Button off ButtonSet, whose size it *asserts*.
  def check_system_images(dir)
    window = File.join(dir, "img", "system", "Window.png")
    expect(png_size(window),
           "img/system/Window.png is missing or not a PNG (ColorManager reads " \
           "the text colours out of it and every window draws its frame from it)")

    buttons = File.join(dir, "img", "system", "ButtonSet.png")
    size = png_size(buttons)
    if size
      want_w = MZ_BUTTON_BLOCK * MZ_BUTTON_BLOCKS
      want_h = MZ_BUTTON_BLOCK * 2
      expect(size[0] >= want_w,
             "img/system/ButtonSet.png is #{size[0]}px wide, need >= #{want_w} " \
             "— Sprite_Button.checkBitmap throws \"ButtonSet image is too " \
             "small\" and aborts the frame")
      expect(size[1] >= want_h,
             "img/system/ButtonSet.png is #{size[1]}px tall, need >= #{want_h} " \
             "(a cold and a hot row of #{MZ_BUTTON_BLOCK}px blocks)")
    else
      fail("img/system/ButtonSet.png is missing or not a PNG — MZ's touch UI " \
           "builds buttons from it in every scrollable window")
    end
    puts "  system images: Window#{png_size(window)&.join('x')} " \
         "ButtonSet#{size&.join('x')}"
  end

  def check_start_map(dir, start_id, tilesets, mapinfos, system)
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
      want = w * h * MZ_MAP_LAYERS
      expect(data.length == want,
             "#{name}.data has #{data.length} tiles, expected " \
             "#{want} (#{w}x#{h}x#{MZ_MAP_LAYERS})")
      sx = system["startX"]
      sy = system["startY"]
      if sx.is_a?(Integer) && sy.is_a?(Integer)
        expect(sx < w && sy < h,
               "System start position (#{sx},#{sy}) is outside #{name} " \
               "(#{w}x#{h})")
      end
    else
      fail("#{name}.data must be an Array")
    end

    tid = map["tilesetId"]
    tileset = entry_at(tilesets, tid)
    expect(tileset, "#{name}.tilesetId #{tid.inspect} is missing from Tilesets.json")
    check_tileset(dir, tileset, tid) if tileset

    puts "  start map #{name}: #{w}x#{h} tileset=#{tid}"
  end

  def check_tileset(dir, tileset, tid)
    names = tileset["tilesetNames"]
    if names.is_a?(Array)
      expect(names.length == MZ_TILESET_NAMES,
             "tileset #{tid} tilesetNames must have #{MZ_TILESET_NAMES} entries " \
             "(got #{names.length})")
      names.each do |n|
        next unless n.is_a?(String) && !n.empty?
        expect(File.file?(File.join(dir, "img", "tilesets", "#{n}.png")),
               "tileset #{tid} names #{n.inspect} but img/tilesets/#{n}.png " \
               "is missing")
      end
    else
      fail("tileset #{tid} tilesetNames must be an Array (got #{names.class})")
    end

    flags = tileset["flags"]
    if flags.is_a?(Array)
      expect(flags.length == MZ_TILESET_FLAGS,
             "tileset #{tid} flags must have #{MZ_TILESET_FLAGS} entries " \
             "(got #{flags.length})")
      # See the header: without 0x10 on the empty tile every cell reads as
      # passable, whatever the ground layer says.
      empty = flags[0]
      expect(empty.is_a?(Integer) &&
             (empty & MZ_FLAG_NO_PASSAGE_EFFECT) == MZ_FLAG_NO_PASSAGE_EFFECT,
             "tileset #{tid} flags[0] is #{empty.inspect}; the empty tile must " \
             "carry 0x10 (\"no effect on passage\") or the empty upper layers " \
             "make every cell passable and no wall blocks")
    else
      fail("tileset #{tid} flags must be an Array (got #{flags.class})")
    end
  end

  # 1-based-array accessor: element 0 is null, so a valid id yields a non-null
  # entry. Guards against a non-Integer id or an out-of-range index.
  def entry_at(arr, id)
    return nil unless arr.is_a?(Array) && id.is_a?(Integer) && id >= 1 && id < arr.length
    arr[id]
  end

  def summary
    puts
    puts "MZ test-bed check: #{@projects} project(s), #{@maps} start map(s), " \
         "#{@errors} error(s)"
  end
end

# --- Discover projects and run ---------------------------------------------

# The same markers MZ::REQUIRED_MARKERS uses, so this and the runtime agree on
# what an MZ project is (and an MV project is never picked up by mistake).
def mz_project?(dir)
  File.exist?(File.join(dir, "js", "rmmz_core.js")) &&
    File.exist?(File.join(dir, "data", "System.json"))
end

# The engine is fetched, not committed, so on a fresh checkout data/mz-sample has
# a database but no js/rmmz_core.js. Recognise it by the database instead: MZ's
# System.json carries `advanced` (screen/font settings) and `tileSize`, neither
# of which an MV System.json has — which is what keeps a downloaded *MV* bed
# (data/Lunatic-Core, whose 288px-wide ButtonSet is legal for MV) from being
# swept up and judged against MZ's rules.
def mz_database?(dir)
  path = File.join(dir, "data", "System.json")
  return false unless File.exist?(path)
  return false if File.exist?(File.join(dir, "js", "rpg_core.js"))
  system = JSON.parse(File.read(path))
  system.is_a?(Hash) && system.key?("advanced") && system.key?("tileSize")
rescue JSON::ParserError
  false
end

def discover(root)
  return [] unless File.directory?(root)
  Dir.children(root).sort.map { |c| File.join(root, c) }.select do |p|
    File.directory?(p) && (mz_project?(p) || mz_database?(p))
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
  warn "No MZ projects found (looked for <dir>/js/rmmz_core.js + " \
       "<dir>/data/System.json). Nothing to check."
  exit 0
end

checker = Checker.new
projects.each do |dir|
  unless File.exist?(File.join(dir, "data", "System.json"))
    checker.fail("#{dir}: not an MZ project (no data/System.json)")
    next
  end
  checker.check_project(dir)
end
checker.summary
exit(checker.errors.zero? ? 0 : 1)
