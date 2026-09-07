# The WOLF RPG Editor runtime shell: boots a project (mruby-wolf's Wolf::
# data layer, wolf.rb / data.rb) into a walkable map, the same role
# mruby-rpg2k's `class RPG2k` and mruby-rpgxp's `class RPGXP` play for their
# makers. See docs/adr/0064-wolf-rpg-editor-data-layer.md.
#
# WOLF RPG Editor has no scripting language to host (unlike RGSS/RPG Maker
# MV/MZ): a game's logic is entirely the fixed, numbered event-command set
# mruby-wolf's `Wolf::Command` decodes, run by the game's own Common Events
# (the "RPG Basic System" that ships with the editor and that every real game
# customises). `Wolf::Interpreter` (interpreter.rb) runs every auto-start and
# parallel-process Common Event each frame against a `Wolf::VarStore`
# (vars.rb), drives map events (trigger/page-selection, and their own
# movement -- Page#move_type/SetMoveRoute(201)), and dispatches Choices(102)
# by waiting on real player input. Several commands (StringCondition,
# messages beyond a log line, real 9-slice window-skin pictures, sound,
# teleport, ...) are explicitly unimplemented rather than guessed at -- see
# docs/TODO.md and interpreter.rb's own header for which command semantics
# are cross-confirmed versus best-effort. Interpreter has no rendering or
# input code of its own -- it calls into this file's own
# `WolfRPG::MapScene#show_string_picture`/`#show_file_picture`/
# `#show_shape_picture`/`#move_picture`/`#erase_picture` (Picture(150)'s own
# text pictures, real image files, and the manual's documented procedural
# shapes -- `<SQUARE>`/`<GRADX-...>`/`<GRADY-...>`/`<LINE>`),
# `#passable?`/`#hero_pos`/`#hero_at?` (event movement's own collision and
# hero-relative queries), and `#choice_input` (Choices(102)'s own up/down/
# confirm/cancel poll -- no native choice window is drawn, mirroring
# Message(101)'s own "stderr line, no real window" scope) for every real
# effect any of that has. What exists here besides that is the map-rendering
# and movement foundation
# every later piece sits on: it loads the project's database, tile data and
# start position, and lets the hero walk around the starting map with the
# real per-tile passability flags, the same incremental order mruby-rpg2k's
# own history followed (map exploration before the event interpreter, before
# battle).
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
    @var_store = Wolf::VarStore.new(@project)
    @interpreter = Wolf::Interpreter.new(@project, @var_store)
    @scene = nil
    # A real TrueType face, so Picture(150)'s text pictures (and the sample
    # game's own Japanese message text, once real message windows exist)
    # have real glyphs to draw -- the same opt-in mruby-rpgxp/mruby-rpgvx
    # already make, rather than RPG2000's fixed shinonome bitmap font.
    RGSS::Font.default_path ||= RGSS.default_font_path
    build_start_scene
  end

  def start
    loop do
      main_loop
      break unless @scene
    end
  rescue RGSS::Timeout
  end

  # One frame: the interpreter advances every live Common Event first (so a
  # command that changes state this frame is visible to the scene right
  # after), then RPG2k/RPGXP's own shape (Input.update after the scene acts
  # on the previous frame's state, then Graphics.update flips the screen), so
  # the web build's per-frame callback (src/main.cxx) can drive this the same
  # way it drives every other maker.
  def main_loop
    @interpreter.update
    if (req = @interpreter.pending_teleport)
      @interpreter.pending_teleport = nil
      teleport_to(*req)
    end
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
    $stderr.puts "[Wolf-MAP] map=#{map_id} x=#{x} y=#{y}" if load_scene(map_id, x, y)
  end

  # Teleport(130)'s own hero-target case (Wolf::Interpreter#pending_teleport's
  # own comment): replaces the running scene with a freshly-built one for
  # `map_id`, disposing the *old* scene's own native sprites/bitmaps/
  # viewports only once the new one has actually loaded (mirrors mruby-
  # rpgxp's own established #dispose-before-replace pattern for its
  # weather/animation sprites) -- never disposing @scene itself, since a
  # failed #load_scene leaves it as the still-active running scene.
  def teleport_to(map_id, x, y)
    old_scene = @scene
    return unless load_scene(map_id, x, y)
    old_scene&.dispose
  end

  def load_scene(map_id, x, y)
    map = @project.map(map_id)
    @interpreter.current_map = map
    @scene = MapScene.new(@project, map, @tile, x, y, @interpreter)
    @interpreter.current_scene = @scene
    true
  rescue Wolf::Error => e
    $stderr.puts "[Wolf] failed to open map #{map_id}: #{e.class}: #{e.message}"
    false
  end

  # A minimal walkable view of one map: tile layers as colour blocks (see the
  # file header), a hero rectangle, arrow-key movement blocked by the
  # tileset's own passability flags, and now map events -- rendered as
  # colour-block markers (real ChipSet-image rendering is still docs/TODO.md's
  # own follow-up, tracked separately from events), running their active
  # page's commands on a Confirm-key press or a walk-into bump the same way
  # Wolf::Interpreter already drives Common Events, and blocking hero
  # movement while a non-Parallel page (or an auto-run Common Event) is
  # still executing (Wolf::Interpreter#blocking?). No scrolling camera zoom,
  # no message/menu system, no event movement (move routes) yet -- see
  # docs/TODO.md's WOLF RPG Editor section for what is still to build on top
  # of this.
  class MapScene
    # Colours are chosen for legibility, not fidelity: they mark passability,
    # not the counter/star/tag distinctions TileFlags also carries.
    PASSABLE = RGSS::Color.new(96, 160, 96, 255)
    BLOCKED = RGSS::Color.new(128, 48, 48, 255)
    ABOVE = RGSS::Color.new(160, 160, 96, 255)
    AUTOTILE = RGSS::Color.new(80, 96, 144, 255)
    GRID = RGSS::Color.new(0, 0, 0, 40)
    HERO = RGSS::Color.new(240, 220, 120, 255)
    EVENT_MARKER = RGSS::Color.new(160, 96, 200, 255)
    SHAPE_COLOR = RGSS::Color.new(255, 255, 255, 255)
    SHAPE_SQUARE_FRAME_THICKNESS = 2

    # (dx, dy) for each facing direction, used both to compute the tile a
    # Confirm-key press should check and (were it ever drawn) which way the
    # hero rectangle would point.
    FACING_DELTA = { down: [0, 1], up: [0, -1], left: [-1, 0], right: [1, 0] }.freeze

    def initialize(project, map, tile, x, y, interpreter)
      @project = project
      @map = map
      @tile = tile
      @x = x
      @y = y
      @facing = :down
      @interpreter = interpreter
      @event_sprites = {}
      @pictures = {}
      @tileset = project.tilesets[map.tileset_id]
      @viewport = RGSS::Viewport.new(0, 0, RGSS::Graphics.width, RGSS::Graphics.height)
      # Pictures are screen-space, not map-space: a message window or menu
      # must not scroll off with the camera the way #update_camera pans
      # @viewport for the map/hero/events, so they get their own viewport
      # that is never panned (Wolf::Interpreter#exec_picture does not yet
      # model the "linked to scroll" bit that would ask for the opposite).
      @picture_viewport = RGSS::Viewport.new(0, 0, RGSS::Graphics.width, RGSS::Graphics.height)
      @map_bitmap = RGSS::Bitmap.new([map.width * tile, 1].max, [map.height * tile, 1].max)
      draw_tiles
      @map_sprite = RGSS::Sprite.new(@viewport)
      @map_sprite.bitmap = @map_bitmap
      @hero_bitmap = RGSS::Bitmap.new(tile, tile)
      @hero_bitmap.fill_rect(0, 0, tile, tile, HERO)
      @hero_sprite = RGSS::Sprite.new(@viewport)
      @hero_sprite.bitmap = @hero_bitmap
      @hero_sprite.z = 1
      # ChangeColor(151)'s own in-flight animated tone transition (nil when
      # none is active) -- see #change_color/#update_tone.
      @tone_transition = nil
      # Effect(290)'s own Character-target Shake, keyed by #character_sprite's
      # own sprite_key (:hero, or an event's own id) -- see #shake_character/
      # #update_character_effects, the character-target counterpart to
      # @pictures[number][:shake].
      @character_shakes = {}
      update_camera
    end

    # Event pages run through the interpreter every frame regardless of
    # #blocking? (so a Parallel page never stalls just because an unrelated
    # Auto page is mid-run elsewhere), but the hero's own input is frozen
    # while any blocking page is active -- standing still is what "an event
    # is happening" should look like even before a real message window
    # exists to make that obvious.
    def update
      update_events
      unless @interpreter.blocking?
        move_hero
        check_confirm
      end
      update_camera
      update_tone
      # ChangeColor(151)'s own "flash" case (#change_color) sets
      # @viewport's native flash state once; decaying it every frame after
      # -- and re-syncing whatever #update_tone just wrote to @viewport.tone
      # -- is native RGSS::Viewport#update's own job, found missing here
      # while wiring up the same "a sprite's own flash needs a periodic
      # native #update call to decay" fact for #flash_picture below: without
      # it, a real flash call would freeze at full intensity forever rather
      # than fading, since nothing else ever re-ran its own decay tick.
      @viewport.update
      update_picture_effects
      update_character_effects
    end

    # The hero's own runtime position/facing, so Wolf::Interpreter can move
    # events toward/away from it (Page#move_type's own TowardHero, and the
    # RouteCommand ids of the same name) and let SetMoveRoute(201) target the
    # hero (help/04ev_movesettingB.html's own "-2 = 主人公" target
    # convention) through the same #step_event_pos/#run_route_commands code
    # path a map event's own runtime position already uses.
    attr_reader :x, :y

    def hero_pos
      { x: @x, y: @y, direction: @facing }
    end

    def hero_pos=(pos)
      @x = pos[:x]
      @y = pos[:y]
      @facing = pos[:direction]
    end

    def hero_at?(x, y)
      x == @x && y == @y
    end

    # Wolf::Interpreter::Run#exec_choices' own input seam -- Interpreter has
    # no rendering/input code of its own (this file's own header comment),
    # so it asks #current_scene rather than touching RGSS::Input directly,
    # the same separation every other rendering hook here already keeps.
    # One event per call (whichever of the four is currently triggered, in
    # this fixed priority order -- WOLF's own choice window is never
    # diagonal, so only one of up/down/confirm/cancel can matter at once in
    # practice); nil while nothing relevant was just pressed.
    def choice_input
      return :up if RGSS::Input.trigger?(RGSS::Input::UP)
      return :down if RGSS::Input.trigger?(RGSS::Input::DOWN)
      return :confirm if RGSS::Input.trigger?(RGSS::Input::C)
      return :cancel if RGSS::Input.trigger?(RGSS::Input::B)
      nil
    end

    # Wolf::Interpreter::Run#exec_input_key's own seam for InputKey(123)'s
    # "Basic" mode -- current press state (not edge-triggered, unlike
    # #choice_input's own `trigger?`: help/04ev_keyinput.html's own
    # "通常の押し状態を取得"/"押されるまで待つ" descriptions both read as a
    # plain "is it down right now" check, run once or every frame). Default
    # key bindings match the manual's own documented defaults for
    # confirm/cancel/sub (Enter or Space / Esc, Backspace or Delete /
    # Shift) -- the "システム変数52～57" customisation the manual also
    # documents is not modeled.
    def input_key_pressed?(kind)
      case kind
      when :up then RGSS::Input.press?(RGSS::Input::UP)
      when :down then RGSS::Input.press?(RGSS::Input::DOWN)
      when :left then RGSS::Input.press?(RGSS::Input::LEFT)
      when :right then RGSS::Input.press?(RGSS::Input::RIGHT)
      when :confirm then RGSS::Input.press?(RGSS::Input::C)
      when :cancel then RGSS::Input.press?(RGSS::Input::B)
      when :subkey then RGSS::Input.press?(RGSS::Input::SHIFT)
      else false
      end
    end

    # Wolf::Interpreter#exec_sound's own rendering-adjacent seam for
    # Sound(140)'s "play an SE by filename" case. `path` is already
    # `Data/`-relative the same way a Picture(150) file argument is (real
    # command dumps confirm the same convention: "SE/System_Get2_wolf.ogg",
    # "SystemFile/SE_Get.ogg"), but unlike `RGSS::Bitmap.new`,
    # `RGSS::Audio.se_play` does its own `GAME_DIR`-relative search rather
    # than taking an absolute path, so this only has to add the `Data/`
    # prefix `GAME_DIR` itself does not know about.
    def play_se(path, volume, pitch)
      RGSS::Audio.se_play(File.join("Data", path), volume, pitch)
    end

    # Wolf::Interpreter#exec_sound_track_db_entry's own seam for Sound(140)'s
    # BGM/BGS "direct system-database selection" case. `operation` is
    # Wolf::Interpreter::SOUND_OP_BGM/SOUND_OP_BGS, the same value the
    # command's own header decodes to.
    def play_track(operation, path, volume, pitch)
      full_path = File.join("Data", path)
      if operation == Wolf::Interpreter::SOUND_OP_BGM
        RGSS::Audio.bgm_play(full_path, volume, pitch)
      else
        RGSS::Audio.bgs_play(full_path, volume, pitch)
      end
    end

    def stop_track(operation)
      if operation == Wolf::Interpreter::SOUND_OP_BGM
        RGSS::Audio.bgm_stop
      else
        RGSS::Audio.bgs_stop
      end
    end

    # Public (not just #move_hero's own concern any more): Wolf::Interpreter's
    # own event-movement code (#step_event_pos) checks the same tile
    # passability before letting a moving event step onto it.
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

    # Anchor codes Wolf::Interpreter#exec_picture passes through unchanged
    # from Picture(150)'s own bitmask (help/04ev_picture.html); top-center/
    # bottom-center are in the manual but not modeled (see interpreter.rb's
    # own comment), so #picture_origin below only handles these five.
    ANCHOR_TOP_LEFT = 0
    ANCHOR_CENTER = 1
    ANCHOR_BOTTOM_LEFT = 2
    ANCHOR_TOP_RIGHT = 3
    ANCHOR_BOTTOM_RIGHT = 4

    # Shows or moves (both snap immediately -- see interpreter.rb's own
    # comment on Picture(150)) a text picture: `text` rendered onto its own
    # Bitmap/Sprite pair, one per picture `number`, kept until #erase_picture.
    # `zoom`/`blend` nil means "leave the existing sprite's value alone"
    # (Picture(150)'s own "same as current" encoding).
    def show_string_picture(number, text, x, y, opacity, zoom, angle, anchor, blend)
      entry = (@pictures[number] ||= build_picture)
      measured = RGSS::Bitmap.new(1, 1).text_size(text)
      width = [measured.width, 1].max
      height = [measured.height, 1].max
      bitmap = RGSS::Bitmap.new(width, height)
      bitmap.draw_text(0, 0, width, height, text)
      entry[:sprite].bitmap = bitmap
      entry[:sprite].src_rect = RGSS::Rect.new(0, 0, width, height)
      place_picture(entry, anchor, x, y, width, height)
      apply_picture_transform(entry[:sprite], opacity, zoom, angle, blend)
    end

    # Loads `path` (relative to the project's own `Data/` folder -- real
    # command dumps confirm the stored filename already carries its own
    # subfolder, e.g. "SystemFile/TitleGraphic.png"/"CharaChip/Foo.png", so
    # no separate "Picture folder" prefix is needed) and shows it, cropping
    # to one `pattern`-th cell of a `div_w`x`div_h` sprite-sheet grid when
    # either is more than 1 (a character/animation sheet), the whole image
    # otherwise. Silently does nothing if the file can't be loaded (logged
    # once) -- a missing asset should not crash event execution.
    def show_file_picture(number, path, div_w, div_h, pattern, x, y, opacity, zoom, angle, anchor, blend)
      entry = (@pictures[number] ||= build_picture)
      bitmap = load_picture_bitmap(path)
      return unless bitmap
      entry[:sprite].bitmap = bitmap
      cell_w = div_w > 1 ? [bitmap.width / div_w, 1].max : bitmap.width
      cell_h = div_h > 1 ? [bitmap.height / div_h, 1].max : bitmap.height
      col = div_w > 1 ? pattern % div_w : 0
      row = div_w > 1 ? pattern / div_w : 0
      entry[:sprite].src_rect = RGSS::Rect.new(col * cell_w, row * cell_h, cell_w, cell_h)
      place_picture(entry, anchor, x, y, cell_w, cell_h)
      apply_picture_transform(entry[:sprite], opacity, zoom, angle, blend)
    end

    # Draws one of Picture(150)'s documented procedural shapes (see
    # interpreter.rb's own SHAPE_* comment) into a `width`x`height` box at
    # `x, y` -- always top-left anchored and never rotated, per the manual
    # ("角度" has no effect on these). `width`/`height` may be negative
    # (`<LINE>`'s own documented direction convention); the box is built
    # from their magnitude and shifted back so it still spans from the
    # original (x, y) to (x + width, y + height) either way.
    def show_shape_picture(number, shape, width, height, x, y, opacity, zoom, blend)
      entry = (@pictures[number] ||= build_picture)
      box_w = [width.abs, 1].max
      box_h = [height.abs, 1].max
      bitmap = RGSS::Bitmap.new(box_w, box_h)
      draw_shape(bitmap, shape, box_w, box_h)
      entry[:sprite].bitmap = bitmap
      entry[:sprite].src_rect = RGSS::Rect.new(0, 0, box_w, box_h)
      entry[:sprite].x = width < 0 ? x - box_w : x
      entry[:sprite].y = height < 0 ? y - box_h : y
      apply_picture_transform(entry[:sprite], opacity, zoom, 0, blend)
    end

    # A Move never respecifies the picture's content (interpreter.rb's own
    # comment); it only updates transform on whatever #show_string_picture/
    # #show_file_picture/#show_shape_picture last drew, reusing that call's
    # own anchor and size (#place_picture's own doc) so the picture does
    # not jump if it was anchored anywhere but the top-left.
    def move_picture(number, x, y, opacity, zoom, angle, blend)
      entry = @pictures[number]
      unless entry
        $stderr.puts "[Wolf] Picture(150): Move on picture ##{number}, which has never been shown; ignoring"
        return
      end
      place_picture(entry, entry[:anchor], x, y, entry[:width], entry[:height])
      apply_picture_transform(entry[:sprite], opacity, zoom, angle, blend)
    end

    def erase_picture(number)
      entry = @pictures.delete(number)
      entry[:sprite].dispose if entry
    end

    # Releases every native sprite/bitmap/viewport this scene owns --
    # called by `WolfRPG#teleport_to` (Teleport(130)'s own hero-target
    # case) before dropping this scene for a freshly-built one on the
    # destination map, so a teleport does not leak native graphics
    # resources.
    def dispose
      @event_sprites.each_value(&:dispose)
      @pictures.each_value { |entry| entry[:sprite].dispose }
      @hero_sprite.dispose
      @hero_bitmap.dispose
      @map_sprite.dispose
      @map_bitmap.dispose
      @viewport.dispose
      @picture_viewport.dispose
    end

    # Effect(290)'s own Picture-target "描画座標シフト[最終値]"
    # (DrawPositionShift): an instant, one-time nudge added directly to
    # whatever #show_string_picture/#show_file_picture/#show_shape_picture/
    # #move_picture last set -- see interpreter.rb's own #exec_effect
    # comment for why this is not tracked as state a later #move_picture
    # would need to reapply. A silent no-op for a picture number with no
    # active sprite, the same tolerance #move_picture logs about instead
    # (Effect(290)'s own real calls apply across a range of numbers, some
    # of which may never have been shown).
    def shift_picture(number, dx, dy)
      entry = @pictures[number]
      return unless entry
      entry[:sprite].x += dx
      entry[:sprite].y += dy
    end

    # Effect(290)'s own Picture-target "カラー補正" (ColorCorrect): adds
    # (r, g, b) to the picture's own RGSS Sprite#color (native, already an
    # additive overlay over the sprite's own contents -- "ピクチャの「カラ
    # ー」に加算します" per help/04ev_effect.html). A fresh Color rather
    # than mutating the one #color returns, since native and Ruby-side
    # accessors are not guaranteed to share the same backing object; its
    # own `red=`/`green=`/`blue=` setters clamp to 0-255 natively, covering
    # the manual's own documented "±200" input range legitimately
    # overshooting a channel already near a limit.
    def tint_picture(number, r, g, b)
      entry = @pictures[number]
      return unless entry
      old = entry[:sprite].color
      fresh = RGSS::Color.new(0, 0, 0, 255)
      fresh.red = old.red + r
      fresh.green = old.green + g
      fresh.blue = old.blue + b
      entry[:sprite].color = fresh
    end

    # Effect(290)'s own Picture-target "フラッシュ" (Flash): a one-shot
    # additive colour pulse ("指定した...値をピクチャの「カラー」に加算し
    # て1回だけフラッシュします"), reusing native RGSS `Sprite#flash`
    # directly rather than tracking any state here -- unlike #tint_picture
    # (a *persistent* addition to the sprite's own base colour) this is
    # ephemeral, composited as its own overlay that fades over `duration`
    # frames and clears itself, exactly the semantics `Sprite#flash`
    # already implements for every other sprite in this codebase. Needs no
    # `old` colour to add onto (unlike #tint_picture): the native flash
    # overlay is independent of the sprite's own persistent colour, so a
    # picture with an active ColorCorrect tint is untouched by this.
    def flash_picture(number, r, g, b, duration)
      entry = @pictures[number]
      return unless entry
      color = RGSS::Color.new(0, 0, 0, 255)
      color.red = r
      color.green = g
      color.blue = b
      entry[:sprite].flash(color, duration)
    end

    # Effect(290)'s own Picture-target "点滅A[明滅]" (SwitchFlicker):
    # starts, redirects, or stops a persistent per-picture toggle between
    # the picture's own base color and base+(r,g,b), alternating every
    # `interval` frames (interpreter.rb's own comment on why this reuses
    # the "duration" field as an interval rather than a delay). Ticked once
    # per frame by #update_picture_effects, the same shape ChangeColor's
    # own #update_tone already established for a persistent screen-wide
    # animation, just keyed per picture number here instead of singular.
    #
    # Reuses #tint_picture's own additive `Sprite#color` semantics rather
    # than tracking an absolute base color: toggling "on" adds the delta,
    # toggling "off" subtracts the exact same delta back out, so a picture
    # that also has its own persistent ColorCorrect tint is never
    # clobbered, only ever nudged by this effect's own contribution.
    #
    # Stops (help/04ev_effect.html's own "RGB全て0" or "フレーム数0"
    # wording) on a non-positive interval or an all-zero delta, undoing
    # first if the picture was mid-"on" -- otherwise starting a *new*
    # flicker while a different one is already "on" would leave its own
    # delta stuck applied forever.
    def set_picture_flicker(number, interval, r, g, b)
      entry = @pictures[number]
      return unless entry
      active = entry[:flicker]
      tint_picture(number, -active[:r], -active[:g], -active[:b]) if active && active[:on]
      if interval <= 0 || (r == 0 && g == 0 && b == 0)
        entry[:flicker] = nil
        return
      end
      entry[:flicker] = { interval: interval, r: r, g: g, b: b, counter: interval, on: false }
    end

    # Effect(290)'s own Picture-target "シェイク" (Shake): starts,
    # redirects, or stops a persistent per-picture back-and-forth nudge by
    # (dx, dy), toggling every `interval` frames, `count` displacements
    # total (interpreter.rb's own comment on the "one displacement away
    # from center is one shake" assumption this picks, unconfirmed against
    # real data one way or the other). Undoes any in-flight displacement
    # first, the same reason #set_picture_flicker does, and always settles
    # back to center before stopping -- #update_picture_effects only clears
    # the state once `count` reaches 0 *and* the picture is back at center,
    # never mid-displacement, so a picture is never left stuck offset.
    def set_picture_shake(number, interval, dx, dy, count)
      entry = @pictures[number]
      return unless entry
      active = entry[:shake]
      if active && active[:on]
        entry[:sprite].x -= active[:dx]
        entry[:sprite].y -= active[:dy]
      end
      if interval <= 0 || count <= 0 || (dx == 0 && dy == 0)
        entry[:shake] = nil
        return
      end
      entry[:shake] = { interval: interval, dx: dx, dy: dy, count: count, counter: interval, on: false }
    end

    # Effect(290)'s own Character-target Flash/Shake seam: resolves
    # interpreter.rb's own `sprite_key` (`:hero`, or an event's own id, per
    # `#resolve_character_pos`) to the live sprite that key already owns --
    # @hero_sprite directly, or whatever #update_events has (lazily) built
    # for that event id in @event_sprites. `nil` for an event id nothing
    # has ever drawn yet (its very first frame, before #update_events --
    # which runs after Wolf::Interpreter#update finishes -- has had a
    # chance to build its sprite), the same "nothing to touch yet"
    # tolerance #shift_picture/#tint_picture already extend to a picture
    # number with no active sprite.
    def character_sprite(sprite_key)
      return @hero_sprite if sprite_key == :hero
      @event_sprites[sprite_key]
    end

    # Effect(290)'s own Character-target "フラッシュ": the exact same
    # native `Sprite#flash` #flash_picture already uses, just resolved to
    # a character's own sprite instead of a picture's.
    def flash_character(sprite_key, r, g, b, duration)
      sprite = character_sprite(sprite_key)
      return unless sprite
      color = RGSS::Color.new(0, 0, 0, 255)
      color.red = r
      color.green = g
      color.blue = b
      sprite.flash(color, duration)
    end

    # Effect(290)'s own Character-target "シェイク": the same persistent
    # nudge-and-settle state #set_picture_shake already establishes for
    # Picture, keyed by sprite_key in @character_shakes instead (a
    # character has no @pictures-style entry hash of its own to hang state
    # off of).
    def shake_character(sprite_key, interval, dx, dy, count)
      sprite = character_sprite(sprite_key)
      return unless sprite
      active = @character_shakes[sprite_key]
      if active && active[:on]
        sprite.x -= active[:dx]
        sprite.y -= active[:dy]
      end
      if interval <= 0 || count <= 0 || (dx == 0 && dy == 0)
        @character_shakes.delete(sprite_key)
        return
      end
      @character_shakes[sprite_key] = { interval: interval, dx: dx, dy: dy, count: count, counter: interval, on: false }
    end

    # ChangeColor(151) ("色調変更", help/04ev_effect.html): `flash` is a
    # one-shot overlay using native RGSS `Viewport#flash` (its own timed
    # decay needs no state kept here), scaling WOLF's own [0, 200] range
    # onto `Color`'s own 0-255 channels (0 contributes nothing, 200 full
    # intensity). Otherwise this starts (or redirects an already in-flight
    # one, always from @viewport's own *current* tone -- the manual's own
    # wording always describes the visible, current screen state, never a
    # queue of pending changes) an animated transition of @viewport's own
    # tone toward the new RGB, linear over `duration` frames, ticked once
    # per frame by #update_tone; 0 (or fewer) frames snaps instantly.
    def change_color(r, g, b, flash, duration)
      if flash
        scale = ->(v) { [[v * 255 / 200, 0].max, 255].min }
        @viewport.flash(RGSS::Color.new(scale.call(r), scale.call(g), scale.call(b), 255), duration)
        @tone_transition = nil
        return
      end

      target = RGSS::Tone.new(wolf_tone_component(r), wolf_tone_component(g), wolf_tone_component(b), 0)
      if duration <= 0
        @viewport.tone = target
        @tone_transition = nil
        return
      end

      current = @viewport.tone
      @tone_transition = {
        start_red: current.red, start_green: current.green, start_blue: current.blue,
        target: target, total: duration, remaining: duration
      }
    end

    private

    # WOLF's own ChangeColor scale (0 darkest, 100 normal, 200 brightest)
    # onto RGSS Tone's own signed -255..255 delta-from-neutral channel,
    # exact at both endpoints and the neutral midpoint.
    def wolf_tone_component(v)
      (v - 100) * 255 / 100
    end

    def update_tone
      t = @tone_transition
      return unless t
      t[:remaining] -= 1
      if t[:remaining] <= 0
        @viewport.tone = t[:target]
        @tone_transition = nil
        return
      end
      progress = (t[:total] - t[:remaining]).to_f / t[:total]
      @viewport.tone = RGSS::Tone.new(
        wolf_lerp(t[:start_red], t[:target].red, progress),
        wolf_lerp(t[:start_green], t[:target].green, progress),
        wolf_lerp(t[:start_blue], t[:target].blue, progress),
        0
      )
    end

    def wolf_lerp(from, to, progress)
      (from + (to - from) * progress).to_i
    end

    def update_picture_effects
      @pictures.each do |number, entry|
        # #flash_picture's own native Sprite#flash decays only when
        # Sprite#update is actually called, the same per-sprite-instance
        # requirement #update's own @viewport.update call satisfies for
        # @viewport -- nothing else in this reader calls it per picture
        # sprite, so it happens here alongside Flicker/Shake's own tick
        # rather than needing a separate pass.
        entry[:sprite].update

        flicker = entry[:flicker]
        if flicker
          flicker[:counter] -= 1
          if flicker[:counter] <= 0
            flicker[:counter] = flicker[:interval]
            flicker[:on] = !flicker[:on]
            sign = flicker[:on] ? 1 : -1
            tint_picture(number, sign * flicker[:r], sign * flicker[:g], sign * flicker[:b])
          end
        end

        shake = entry[:shake]
        next unless shake
        shake[:counter] -= 1
        next unless shake[:counter] <= 0
        shake[:counter] = shake[:interval]
        if shake[:on]
          entry[:sprite].x -= shake[:dx]
          entry[:sprite].y -= shake[:dy]
          shake[:on] = false
          entry[:shake] = nil if shake[:count] <= 0
        else
          shake[:count] -= 1
          entry[:sprite].x += shake[:dx]
          entry[:sprite].y += shake[:dy]
          shake[:on] = true
        end
      end
    end

    # The Character-target counterpart to #update_picture_effects: native
    # `Sprite#flash` needs the same periodic `#update` tick for the hero
    # and every live event sprite that pictures already get, and any
    # active #shake_character state needs the same toggle-and-settle tick
    # #update_picture_effects's own Picture Shake already gets. A plain
    # `@character_shakes.keys` snapshot rather than iterating the Hash
    # directly, since a settled shake deletes its own entry mid-loop.
    def update_character_effects
      @hero_sprite.update
      @event_sprites.each_value(&:update)

      @character_shakes.keys.each do |sprite_key|
        shake = @character_shakes[sprite_key]
        shake[:counter] -= 1
        next unless shake[:counter] <= 0
        shake[:counter] = shake[:interval]
        sprite = character_sprite(sprite_key)
        unless sprite
          @character_shakes.delete(sprite_key)
          next
        end
        if shake[:on]
          sprite.x -= shake[:dx]
          sprite.y -= shake[:dy]
          shake[:on] = false
          @character_shakes.delete(sprite_key) if shake[:count] <= 0
        else
          shake[:count] -= 1
          sprite.x += shake[:dx]
          sprite.y += shake[:dy]
          shake[:on] = true
        end
      end
    end

    # Positions `entry`'s sprite so that (x, y) is the point `anchor` names
    # on a `width`x`height` box (help/04ev_picture.html's own five
    # positions this reader models -- interpreter.rb's own comment on the
    # two it does not), and records the anchor/size so a later #move_picture
    # call can reuse them without knowing either.
    def place_picture(entry, anchor, x, y, width, height)
      entry[:anchor] = anchor
      entry[:width] = width
      entry[:height] = height
      ox, oy = picture_origin(anchor, width, height)
      entry[:sprite].x = x - ox
      entry[:sprite].y = y - oy
    end

    def apply_picture_transform(sprite, opacity, zoom, angle, blend)
      sprite.opacity = opacity
      unless zoom.nil?
        sprite.zoom_x = zoom
        sprite.zoom_y = zoom
      end
      sprite.angle = angle unless angle.nil?
      sprite.blend_type = blend unless blend.nil?
      sprite.visible = true
    end

    def picture_origin(anchor, width, height)
      case anchor
      when ANCHOR_CENTER then [width / 2, height / 2]
      when ANCHOR_BOTTOM_LEFT then [0, height]
      when ANCHOR_TOP_RIGHT then [width, 0]
      when ANCHOR_BOTTOM_RIGHT then [width, height]
      else [0, 0] # ANCHOR_TOP_LEFT, and any unmodeled anchor code
      end
    end

    def load_picture_bitmap(path)
      RGSS::Bitmap.new(File.join(@project.dir, "Data", path))
    rescue RGSS::Bitmap::LoadError => e
      $stderr.puts "[Wolf] Picture(150): failed to load #{path.inspect}: #{e.message}"
      nil
    end

    def draw_shape(bitmap, shape, width, height)
      case shape[:kind]
      when :square
        if shape[:frame]
          t = [SHAPE_SQUARE_FRAME_THICKNESS, width, height].min
          bitmap.fill_rect(0, 0, width, t, SHAPE_COLOR)
          bitmap.fill_rect(0, [height - t, 0].max, width, t, SHAPE_COLOR)
          bitmap.fill_rect(0, 0, t, height, SHAPE_COLOR)
          bitmap.fill_rect([width - t, 0].max, 0, t, height, SHAPE_COLOR)
        else
          bitmap.fill_rect(0, 0, width, height, SHAPE_COLOR)
        end
      when :gradient
        c1 = RGSS::Color.new(*shape[:color1], 255)
        c2 = RGSS::Color.new(*shape[:color2], 255)
        bitmap.gradient_fill_rect(0, 0, width, height, c1, c2, shape[:axis] == :y)
      when :line
        t = [shape[:thickness], width, height].min
        if height <= t
          bitmap.fill_rect(0, 0, width, t, SHAPE_COLOR)
        elsif width <= t
          bitmap.fill_rect(0, 0, t, height, SHAPE_COLOR)
        else
          # A genuinely diagonal <LINE> (neither dimension collapses to the
          # thickness) is not modeled -- not seen in the sample game's own
          # usage, which is always a plain horizontal/vertical divider.
        end
      end
    end

    def build_picture
      sprite = RGSS::Sprite.new(@picture_viewport)
      sprite.bitmap = RGSS::Bitmap.new(1, 1)
      { sprite: sprite, anchor: ANCHOR_TOP_LEFT, width: 1, height: 1 }
    end

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

    # Pressing a direction always turns the hero to face it, whether or not
    # the step itself succeeds -- the same convention #check_confirm's own
    # "facing tile" relies on, and standard across every RPG Maker-shaped
    # engine this repo already supports.
    def move_hero
      dx = 0
      dy = 0
      if RGSS::Input.press?(RGSS::Input::DOWN)
        @facing = :down
        dy = 1
      elsif RGSS::Input.press?(RGSS::Input::UP)
        @facing = :up
        dy = -1
      elsif RGSS::Input.press?(RGSS::Input::LEFT)
        @facing = :left
        dx = -1
      elsif RGSS::Input.press?(RGSS::Input::RIGHT)
        @facing = :right
        dx = 1
      end
      return if dx == 0 && dy == 0
      nx = @x + dx
      ny = @y + dy
      return unless passable?(nx, ny)
      event, page = @interpreter.event_at(nx, ny)
      if event
        # A Player-Touch/Event-Touch page fires on the bump attempt itself,
        # matching mruby-rpg2k's own #touch_trigger?/#event_at/#start_event
        # precedent for RPG2000/2003's identical trigger pair -- whether or
        # not the step below actually happens depends only on
        # Wolf::Page#slip_through?, same as any other event tile.
        @interpreter.trigger_touch(event)
        return unless page.slip_through?
      end
      @x = nx
      @y = ny
    end

    # Confirm-trigger pages: fire on standing on a walk-through event (per
    # help/04eventwindowB.html, "決定キーで実行" answers both to a
    # slip-through event under the hero and to one directly ahead), checked
    # in that order so a signpost you can walk over does not additionally
    # require facing it.
    def check_confirm
      return unless RGSS::Input.trigger?(RGSS::Input::C)
      event, page = @interpreter.event_at(@x, @y)
      if event && page.slip_through?
        return if @interpreter.trigger_confirm(event)
      end
      dx, dy = FACING_DELTA[@facing]
      event, = @interpreter.event_at(@x + dx, @y + dy)
      @interpreter.trigger_confirm(event) if event
    end

    # Colour-block markers (see the file header) for every map event with a
    # currently-active page; a page's own conditions can change every frame
    # (they read ordinary variables/switches), so this recomputes visibility
    # and position from scratch each time rather than caching it.
    def update_events
      @map.events.each do |event|
        _idx, page = @interpreter.active_page(event)
        sprite = (@event_sprites[event.id] ||= build_event_sprite)
        next sprite.visible = false unless page
        # Its own runtime position (Wolf::Interpreter#event_position), not
        # the event's parsed *start* position -- Interpreter#update_map_events
        # may have moved it this frame (Page#move_type/SetMoveRoute(201)).
        pos = @interpreter.event_position(event)
        sprite.x = pos[:x] * @tile
        sprite.y = pos[:y] * @tile
        sprite.z = page.above_hero? ? 2 : 1
        sprite.visible = true
      end
    end

    def build_event_sprite
      bitmap = RGSS::Bitmap.new(@tile, @tile)
      bitmap.fill_rect(2, 2, [@tile - 4, 1].max, [@tile - 4, 1].max, EVENT_MARKER)
      sprite = RGSS::Sprite.new(@viewport)
      sprite.bitmap = bitmap
      sprite
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
