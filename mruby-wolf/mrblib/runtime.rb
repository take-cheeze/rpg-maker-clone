# The WOLF RPG Editor runtime shell: boots a project (mruby-wolf's Wolf::
# data layer, wolf.rb / data.rb) into a walkable map, the same role
# mruby-rpg2k's `class RPG2k` and mruby-rpgxp's `class RPGXP` play for their
# makers. See docs/adr/0064-wolf-rpg-editor-data-layer.md.
#
# WOLF RPG Editor has no scripting language to host (unlike RGSS/RPG Maker
# MV/MZ): a game's logic is entirely the fixed, numbered event-command set
# mruby-wolf's `Wolf::Command` decodes, run by the game's own Common Events
# (the "RPG Basic System" that ships with the editor and that every real game
# customises). Interpreting those commands is the bulk of a full runtime and
# is not built yet (see the TODO below); what exists here is the map-
# rendering and movement foundation every later piece sits on: it loads the
# project's database, tile data and start position, and lets the hero walk
# around the starting map with the real per-tile passability flags, the same
# incremental order mruby-rpg2k's own history followed (map exploration
# before the event interpreter, before battle).
#
# Tiles are drawn as flat colour blocks keyed by TileSetData's passability
# flags (green passable, dark red blocked, blue counter, grey autotile),
# mirroring the colour-block fallback mruby-rpg2k's chipset renderer already
# uses when a real ChipSet image is unavailable (see README's "Map
# exploration"); real ChipSet-image rendering (base chips read from the
# tileset's PNG, autotile quarter-tile assembly per Map.autotile_slot/shape)
# is the natural next step and is left as a follow-up, tracked in
# docs/TODO.md.
class WolfRPG
  # Every current release (2.2x through 3.3x+) uses 8-directional character
  # sheets in the RPG Basic System even when the project settings say 4; the
  # sheet layout the runtime draws from is a project setting
  # (Game.dat#character_directions), read below.
  DEFAULT_TILE = 32

  def initialize(_args)
    @dir = GAME_DIR
    @project = Wolf::Project.new(@dir)
    @title = @project.game.title
    @title = File.basename(@dir) if @title.strip.empty?
    RGSS::Graphics.resize_screen(@project.game.screen_width, @project.game.screen_height)
    RGSS.window_title = @title
    @tile = @project.game.tile_size
    @tile = DEFAULT_TILE unless [16, 32, 40, 48].include?(@tile)
    @scene = nil
    build_start_scene
  end

  def start
    loop do
      main_loop
      break unless @scene
    end
  rescue RGSS::Timeout
  end

  # One frame: RPG2k/RPGXP's own shape (Input.update after the scene acts on
  # the previous frame's state, then Graphics.update flips the screen), so the
  # web build's per-frame callback (src/main.cxx) can drive this the same way
  # it drives every other maker.
  def main_loop
    @scene.update if @scene
    RGSS::Input.update
    RGSS::Graphics.update
  end

  private

  def build_start_scene
    pos = @project.start_position
    unless pos
      $stderr.puts "[Wolf] #{@dir.inspect}: no start position in the system database " \
                   "(system DB table #{Wolf::Project::SYS_POSITIONS}); nothing to show"
      return
    end
    map_id, x, y = pos
    map = @project.map(map_id)
    @scene = MapScene.new(@project, map, @tile, x, y)
    $stderr.puts "[Wolf-MAP] map=#{map_id} x=#{x} y=#{y}"
  rescue Wolf::Error => e
    $stderr.puts "[Wolf] failed to open the start map: #{e.class}: #{e.message}"
  end

  # A minimal walkable view of one map: tile layers as colour blocks (see the
  # file header), a hero rectangle, arrow-key movement blocked by the
  # tileset's own passability flags. No events, no scrolling camera, no
  # message/menu system yet -- see docs/TODO.md's WOLF RPG Editor section for
  # what is still to build on top of this.
  class MapScene
    # Colours are chosen for legibility, not fidelity: they mark passability,
    # not the counter/star/tag distinctions TileFlags also carries.
    PASSABLE = RGSS::Color.new(96, 160, 96, 255)
    BLOCKED = RGSS::Color.new(128, 48, 48, 255)
    ABOVE = RGSS::Color.new(160, 160, 96, 255)
    AUTOTILE = RGSS::Color.new(80, 96, 144, 255)
    GRID = RGSS::Color.new(0, 0, 0, 40)
    HERO = RGSS::Color.new(240, 220, 120, 255)

    def initialize(project, map, tile, x, y)
      @project = project
      @map = map
      @tile = tile
      @x = x
      @y = y
      @tileset = project.tilesets[map.tileset_id]
      @viewport = RGSS::Viewport.new(0, 0, RGSS::Graphics.width, RGSS::Graphics.height)
      @map_bitmap = RGSS::Bitmap.new([map.width * tile, 1].max, [map.height * tile, 1].max)
      draw_tiles
      @map_sprite = RGSS::Sprite.new(@viewport)
      @map_sprite.bitmap = @map_bitmap
      @hero_bitmap = RGSS::Bitmap.new(tile, tile)
      @hero_bitmap.fill_rect(0, 0, tile, tile, HERO)
      @hero_sprite = RGSS::Sprite.new(@viewport)
      @hero_sprite.bitmap = @hero_bitmap
      @hero_sprite.z = 1
      update_camera
    end

    def update
      move_hero
      update_camera
    end

    private

    def draw_tiles
      w = @map.width
      h = @map.height
      base_layers = @map.layer_count
      (0...h).each do |ty|
        (0...w).each do |tx|
          color = tile_color(0, tx, ty)
          (1...base_layers).each do |li|
            v = @map.tile(li, tx, ty)
            color = tile_color(li, tx, ty) if v != 0
          end
          @map_bitmap.fill_rect(tx * @tile, ty * @tile, @tile, @tile, color)
        end
      end
      # A light grid over the fill, so tile boundaries stay legible without a
      # real chipset image.
      (0..w).each { |gx| @map_bitmap.fill_rect(gx * @tile, 0, 1, h * @tile, GRID) }
      (0..h).each { |gy| @map_bitmap.fill_rect(0, gy * @tile, w * @tile, 1, GRID) }
    end

    def tile_color(layer, x, y)
      value = @map.tile(layer, x, y)
      return PASSABLE if @tileset.nil?
      if Wolf::Map.autotile?(value)
        return AUTOTILE
      end
      flags = @tileset.flags_for(value)
      return PASSABLE if flags.nil?
      return ABOVE if flags.above_characters?
      flags.impassable? ? BLOCKED : PASSABLE
    end

    def passable?(x, y)
      return false if x < 0 || y < 0 || x >= @map.width || y >= @map.height
      (0...@map.layer_count).each do |li|
        v = @map.tile(li, x, y)
        next if v == 0 && li > 0
        next if Wolf::Map.autotile?(v)
        flags = @tileset && @tileset.flags_for(v)
        return false if flags && flags.impassable?
      end
      true
    end

    def move_hero
      dx = 0
      dy = 0
      if RGSS::Input.press?(RGSS::Input::DOWN)
        dy = 1
      elsif RGSS::Input.press?(RGSS::Input::UP)
        dy = -1
      elsif RGSS::Input.press?(RGSS::Input::LEFT)
        dx = -1
      elsif RGSS::Input.press?(RGSS::Input::RIGHT)
        dx = 1
      end
      return if dx == 0 && dy == 0
      nx = @x + dx
      ny = @y + dy
      return unless passable?(nx, ny)
      @x = nx
      @y = ny
    end

    def update_camera
      cx = @x * @tile + @tile / 2 - RGSS::Graphics.width / 2
      cy = @y * @tile + @tile / 2 - RGSS::Graphics.height / 2
      cx = [[cx, 0].max, [@map.width * @tile - RGSS::Graphics.width, 0].max].min
      cy = [[cy, 0].max, [@map.height * @tile - RGSS::Graphics.height, 0].max].min
      @viewport.ox = cx
      @viewport.oy = cy
      @hero_sprite.x = @x * @tile
      @hero_sprite.y = @y * @tile
    end
  end
end
