# RPG Maker XP scenes: the title screen and the walkable map scene, plus a small
# XP-styled window helper. The title reproduces the default RMXP flow (title
# graphic + New Game / Continue / Shutdown) directly against the database; the
# map scene draws the three tile layers through the native RGSS::Tilemap (the
# project's real tileset and autotiles), the party leader and the events, its
# pictures and its screen tone, and lets the leader walk with tileset collision
# and a follow camera.

class RPGXP
  # A compact RMXP-style window: a Viewport that clips a skin layer, a selection
  # cursor and a contents bitmap. The windowskin is the 192x128 RMXP layout — a
  # 128x128 stretched background with a 64x64 nine-slice border at (128,0). When
  # no skin is available (e.g. the RTP graphics are absent) it falls back to a
  # plain translucent panel so the UI is still legible.
  class Panel
    BORDER = 16

    def initialize(x, y, width, height, skin = nil)
      @x = x
      @y = y
      @width = width
      @height = height
      @skin = skin
      @active = true
      @cursor_rect = nil
      # RGSS draws a window's background at `back_opacity` and leaves the frame
      # opaque. 255 is the class default; the scenes that want to see through a
      # window (RMXP's Scene_Title uses 160) set it themselves.
      @back_opacity = 255

      @viewport = Viewport.new(x, y, [width, 1].max, [height, 1].max)
      @viewport.z = 100

      @skin_sprite = Sprite.new(@viewport)
      @skin_sprite.z = 0
      @cursor_sprite = Sprite.new(@viewport)
      @cursor_sprite.z = 1
      @contents_sprite = Sprite.new(@viewport)
      @contents_sprite.z = 2
      @contents_sprite.x = BORDER
      @contents_sprite.y = BORDER

      @skin_bmp = Bitmap.new([width, 1].max, [height, 1].max)
      @skin_sprite.bitmap = @skin_bmp
      @cursor_bmp = Bitmap.new([width, 1].max, [height, 1].max)
      @cursor_sprite.bitmap = @cursor_bmp
      @pause = false
      @pause_count = 0
      @pause_sprite = Sprite.new(@viewport)
      @pause_sprite.z = 3
      @pause_bmp = Bitmap.new([width, 1].max, [height, 1].max)
      @pause_sprite.bitmap = @pause_bmp

      draw_skin
    end

    # The usable interior size (inside the border) for a contents bitmap.
    def inner_width;  @width - BORDER * 2;  end
    def inner_height; @height - BORDER * 2; end

    def z=(v)
      @viewport.z = v
    end

    def contents=(bmp)
      @contents = bmp
      @contents_sprite.bitmap = bmp if bmp
    end

    def active=(v)
      @active = v
      draw_cursor
    end

    attr_reader :back_opacity

    def back_opacity=(v)
      @back_opacity = v
      draw_skin
    end

    # Selection highlight, in contents coordinates (offset by the border).
    def cursor_rect=(rect)
      @cursor_rect = rect
      draw_cursor
    end

    # Show or hide the pause arrow. Animating it is #update's job.
    def pause=(v)
      return if @pause == !!v
      @pause = !!v
      @pause_count = 0
      draw_pause
    end

    # Advance the pause arrow's animation; call once a frame while it is shown.
    def update
      return unless @pause
      @pause_count = (@pause_count + 1) % (PAUSE_FRAMES * PAUSE_FRAME_TICKS)
      draw_pause if (@pause_count % PAUSE_FRAME_TICKS).zero?
    end

    def dispose
      [@skin_sprite, @cursor_sprite, @contents_sprite, @pause_sprite].each { |s| s.dispose if s }
      @viewport.dispose
    end

    private

    def draw_skin
      @skin_bmp.clear
      if @skin
        draw_skin_background
        draw_skin_border
      else
        draw_fallback
      end
    end

    def draw_skin_background
      @skin_bmp.stretch_blt Rect.new(2, 2, @width - 4, @height - 4), @skin,
                            Rect.new(0, 0, 128, 128), @back_opacity
    rescue StandardError
      draw_fallback
    end

    # Nine-slice the 64x64 border block at (128,0): 16x16 corners with stretched
    # edges between them.
    def draw_skin_border
      w = @width
      h = @height
      b = BORDER
      s = @skin
      sx = 128
      # Corners.
      @skin_bmp.blt 0, 0, s, Rect.new(sx, 0, b, b)
      @skin_bmp.blt w - b, 0, s, Rect.new(sx + 48, 0, b, b)
      @skin_bmp.blt 0, h - b, s, Rect.new(sx, 48, b, b)
      @skin_bmp.blt w - b, h - b, s, Rect.new(sx + 48, 48, b, b)
      # Edges.
      @skin_bmp.stretch_blt Rect.new(b, 0, w - 2 * b, b), s, Rect.new(sx + b, 0, b, b)
      @skin_bmp.stretch_blt Rect.new(b, h - b, w - 2 * b, b), s, Rect.new(sx + b, 48, b, b)
      @skin_bmp.stretch_blt Rect.new(0, b, b, h - 2 * b), s, Rect.new(sx, b, b, b)
      @skin_bmp.stretch_blt Rect.new(w - b, b, b, h - 2 * b), s, Rect.new(sx + 48, b, b, b)
    rescue StandardError
      draw_fallback
    end

    def draw_fallback
      @skin_bmp.fill_rect 0, 0, @width, @height, Color.new(8, 16, 56, 224)
      edge = Color.new(200, 208, 232, 255)
      @skin_bmp.fill_rect 0, 0, @width, 2, edge
      @skin_bmp.fill_rect 0, @height - 2, @width, 2, edge
      @skin_bmp.fill_rect 0, 0, 2, @height, edge
      @skin_bmp.fill_rect @width - 2, 0, 2, @height, edge
    end

    # The selection highlight comes out of the windowskin, like everything else
    # about a window: RGSS keeps a 32x32 cursor block at (128, 64) and
    # nine-slices it over the cursor rect (CURSOR_EDGE-wide corners and edges,
    # the middle stretched). Drawing a flat blue bar instead was the single
    # biggest difference left on the title screen against the genuine runtime --
    # its cursor is a thin outline over a nearly clear interior, ours was a solid
    # slab. Falls back to the old hand-drawn bar when the project has no skin.
    CURSOR_SRC_X = 128
    CURSOR_SRC_Y = 64
    CURSOR_SRC_SIZE = 32
    CURSOR_EDGE = 4

    # The "waiting for a key" arrow RGSS draws at the bottom of a window whose
    # `pause` is set -- a message box holding its text until the player presses
    # on. It comes out of the windowskin like everything else: four 16x16
    # animation frames in a 32x32 block at (160, 64), cycled every eight frames,
    # centred on the window's bottom edge. The genuine runtime draws it on every
    # held message, so leaving it out was a visible difference in every message
    # frame of scripts/compare-rpgxp-wine.bash.
    PAUSE_SRC_X = 160
    PAUSE_SRC_Y = 64
    PAUSE_SIZE = 16
    PAUSE_FRAMES = 4
    PAUSE_FRAME_TICKS = 8

    def draw_cursor
      @cursor_bmp.clear
      return unless @active && @cursor_rect
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0
      x = BORDER + r.x
      y = BORDER + r.y
      if @skin
        draw_skin_cursor x, y, r.width, r.height
      else
        draw_fallback_cursor x, y, r.width, r.height
      end
    end

    def draw_skin_cursor(x, y, w, h)
      e = CURSOR_EDGE
      sx = CURSOR_SRC_X
      sy = CURSOR_SRC_Y
      # The source block's middle span, between its corners.
      m = CURSOR_SRC_SIZE - e * 2
      iw = w - e * 2
      ih = h - e * 2
      s = @skin
      # Corners.
      @cursor_bmp.blt x, y, s, Rect.new(sx, sy, e, e)
      @cursor_bmp.blt x + w - e, y, s, Rect.new(sx + e + m, sy, e, e)
      @cursor_bmp.blt x, y + h - e, s, Rect.new(sx, sy + e + m, e, e)
      @cursor_bmp.blt x + w - e, y + h - e, s,
                      Rect.new(sx + e + m, sy + e + m, e, e)
      return if iw <= 0 || ih <= 0
      # Edges and the stretched middle.
      @cursor_bmp.stretch_blt Rect.new(x + e, y, iw, e), s,
                              Rect.new(sx + e, sy, m, e)
      @cursor_bmp.stretch_blt Rect.new(x + e, y + h - e, iw, e), s,
                              Rect.new(sx + e, sy + e + m, m, e)
      @cursor_bmp.stretch_blt Rect.new(x, y + e, e, ih), s,
                              Rect.new(sx, sy + e, e, m)
      @cursor_bmp.stretch_blt Rect.new(x + w - e, y + e, e, ih), s,
                              Rect.new(sx + e + m, sy + e, e, m)
      @cursor_bmp.stretch_blt Rect.new(x + e, y + e, iw, ih), s,
                              Rect.new(sx + e, sy + e, m, m)
    rescue StandardError => e
      $stderr.puts "[RGSS] windowskin cursor failed, using a plain bar: #{e.message}"
      draw_fallback_cursor x, y, w, h
    end

    # Blit the current animation frame centred on the bottom edge, inside the
    # border. A project with no windowskin gets nothing rather than an invented
    # arrow -- the fallback panel is already not what RGSS draws.
    def draw_pause
      @pause_bmp.clear
      return unless @pause && @skin
      frame = @pause_count / PAUSE_FRAME_TICKS
      sx = PAUSE_SRC_X + (frame % 2) * PAUSE_SIZE
      sy = PAUSE_SRC_Y + (frame / 2) * PAUSE_SIZE
      @pause_bmp.blt (@width - PAUSE_SIZE) / 2, @height - PAUSE_SIZE, @skin,
                     Rect.new(sx, sy, PAUSE_SIZE, PAUSE_SIZE)
    rescue StandardError => e
      $stderr.puts "[RGSS] windowskin pause arrow failed: #{e.message}"
    end

    def draw_fallback_cursor(x, y, w, h)
      @cursor_bmp.fill_rect x, y, w, h, Color.new(40, 72, 200, 160)
      border = Color.new(200, 216, 255, 255)
      @cursor_bmp.fill_rect x, y, w, 2, border
      @cursor_bmp.fill_rect x, y + h - 2, w, 2, border
      @cursor_bmp.fill_rect x, y, 2, h, border
      @cursor_bmp.fill_rect x + w - 2, y, 2, h, border
    end
  end

  module Scene
    class Base
      def initialize(parent)
        @parent = parent
        @db = parent.db
      end

      attr_reader :parent, :db

      def update; end
      def dispose; end

      # Load the System windowskin (Graphics/Windowskins/) declared in the
      # database, or nil so Panel falls back to a plain panel.
      def load_windowskin
        name = @db.system.windowskin_name
        return nil if name.nil? || name.empty?
        Bitmap.new "Graphics/Windowskins/#{name}"
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      # Play a System sound effect (RPG::AudioFile), best effort.
      def play_se(audio)
        return unless audio && audio.name && !audio.name.empty?
        Audio.se_play(audio.name, audio.volume || 100, audio.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RGSS] SE playback failed: #{e.message}"
      end
    end

    # Title screen: the title graphic behind a command window offering New Game,
    # Continue and Shutdown. These command labels live in the game's Ruby scripts
    # (not the database), so the default English set is used.
    class Title < Base
      WIDTH = RPGXP::WIDTH
      HEIGHT = RPGXP::HEIGHT
      LINE_H = 32
      COMMANDS = ["New Game", "Continue", "Shutdown"].freeze

      def initialize(parent)
        super parent
        @index = 0
        @skin = load_windowskin
        build_background
        build_command_window
        start_title_bgm
      end

      def dispose
        @bg.dispose if @bg
        @command.dispose if @command
      end

      def update
        if Input.trigger?(Input::DOWN) && @index < COMMANDS.size - 1
          @index += 1
          play_se(@db.system.cursor_se)
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @index > 0
          @index -= 1
          play_se(@db.system.cursor_se)
          refresh_cursor
        elsif Input.trigger?(Input::C) || auto_select?
          play_se(@db.system.decision_se)
          select_command
        end
      end

      private

      # `--rpgxp_new_game`: pick New Game once, without input, so a headless run
      # reaches the map scene instead of sitting on the title screen. One-shot;
      # a no-op during normal play.
      #
      # The constant is read through its own `begin`/`rescue` rather than a
      # helper taking its name: `Module#const_get` is not something this
      # runtime's mruby build is known to carry, and the whole point of the flag
      # is catching mruby/CRuby divergence, not adding more (ADR 0021).
      def auto_select?
        return false if @auto_started
        return false unless auto_new_game?
        @auto_started = true
        @index = 0
        $stderr.puts "[RGSS] --rpgxp_new_game: selecting New Game"
        true
      end

      def auto_new_game?
        RPGXP_NEW_GAME
      rescue StandardError
        false
      end

      def build_background
        @bg = Sprite.new
        @bg.z = 0
        name = @db.system.title_name
        @bg.bitmap =
          if name && !name.empty?
            Bitmap.new "Graphics/Titles/#{name}"
          else
            fallback_background
          end
      rescue StandardError => e
        $stderr.puts "[RGSS] title graphic load failed, using plain background: #{e.message}"
        @bg.bitmap = fallback_background
      end

      def fallback_background
        bmp = Bitmap.new(WIDTH, HEIGHT)
        bmp.fill_rect 0, 0, WIDTH, HEIGHT, Color.new(12, 20, 48, 255)
        bmp.font.color = Color.new(240, 240, 248, 255)
        bmp.draw_text 0, HEIGHT / 3, WIDTH, 40, @parent.title.to_s, 1
        bmp
      end

      def build_command_window
        # RMXP's Scene_Title builds `Window_Command.new(192, commands)` and
        # places it centred at y = 288; the height falls out of the same
        # 32-pixel rows plus the skin's 16-pixel border. Matching its width is
        # what puts our window on the genuine runtime's pixels -- 240 left it
        # 48 too wide and 24 too far left (measured with
        # scripts/compare-rpgxp-wine.bash).
        w = 192
        h = COMMANDS.size * LINE_H + Panel::BORDER * 2
        @command = Panel.new((WIDTH - w) / 2, HEIGHT - h - 64, w, h, @skin)
        @command.z = 200
        # RMXP's Scene_Title: `@command_window.back_opacity = 160`, so the title
        # graphic shows through the menu.
        @command.back_opacity = 160
        contents = Bitmap.new(@command.inner_width, @command.inner_height)
        contents.font.color = Color.new(255, 255, 255, 255)
        COMMANDS.each_with_index do |c, i|
          contents.draw_text 4, i * LINE_H + 4, contents.width - 8, LINE_H - 4, c
        end
        @command.contents = contents
        refresh_cursor
      end

      def refresh_cursor
        @command.cursor_rect = Rect.new(0, @index * LINE_H, @command.inner_width, LINE_H)
      end

      def select_command
        case @index
        when 0 then @parent.start_new_game
        when 1 then @parent.continue_game
        when 2 then exit
        end
      end

      def start_title_bgm
        bgm = @db.system.title_bgm
        return unless bgm && bgm.name && !bgm.name.empty?
        Audio.bgm_play(bgm.name, bgm.volume || 100, bgm.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RGSS] title BGM playback failed: #{e.message}"
      end
    end

    # The walkable map: the three tile layers render through the native
    # RGSS::Tilemap (the real tileset graphic, autotiles assembled from their
    # quads and animated, priority tiles sorted above the characters), the party
    # leader and every event draw from their Character graphics, and movement is
    # grid-based with pixel interpolation, tileset collision and an edge-clamped
    # follow camera.
    # Resolves the command list a Call Common Event refers to (common events are
    # 1-based in the database array).
    class EventResolver
      def initialize(common_events)
        @common = common_events || []
      end

      def common_event_list(id)
        ce = @common[id]
        ce && ce.list
      end
    end

    # Adapter exposing the running map to the movement engine (Game::MoveRoute /
    # Game::MoveType): it bridges their `world` protocol — passability, hero
    # position, switch and sound side effects, randomness — onto the Scene::Map.
    class MapWorld
      def initialize(scene, rng)
        @scene = scene
        @rng = rng
      end

      def passable?(character, dir)
        @scene.char_passable?(character, dir)
      end

      def hero_position
        [@scene.state.x, @scene.state.y]
      end

      def set_switch(id, on)
        @scene.state.switches[id] = on
      end

      def play_sound(audio)
        return if audio.nil? || !audio.respond_to?(:name) || audio.name.nil?
        Audio.se_play(audio.name, audio.volume || 100, audio.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RGSS] event move SE failed: #{e.message}"
      end

      def random(n)
        @rng.random(n)
      end
    end

    class Map < Base
      TILE = RPGXP::TILE
      SCREEN_W = RPGXP::WIDTH
      SCREEN_H = RPGXP::HEIGHT
      COLS = SCREEN_W / TILE + 1
      ROWS = SCREEN_H / TILE + 1
      SPEED = 4 # pixels/frame while stepping (must divide TILE)
      # RMXP tile ids: 0 empty, 48..383 the seven autotiles, TILE_ID_BASE and up
      # the tileset graphic in reading order.
      TILE_ID_BASE = 384
      MSG_LINE_H = 32
      # The message box, laid out as RMXP's Window_Message does it:
      # `super(80, 304, 480, 160)` on a 640x480 screen — an inset 480x160 box
      # sixteen pixels off the bottom, four 32px lines inside its 16px border,
      # with the text at x=4 of the contents. Ours used to span the whole screen
      # width at the very bottom (the RPG2000 layout), which the wine comparison
      # against the genuine RGSS runtime showed as a differently sized and
      # placed box on every message. Derived from the screen size so the
      # constants hold if it ever changes.
      MSG_W = 480
      MSG_H = MSG_LINE_H * 4 + Panel::BORDER * 2
      MSG_X = (SCREEN_W - MSG_W) / 2
      MSG_MARGIN = 16 # gap between the box's bottom edge and the screen's
      MSG_TEXT_X = 4

      # Event-page start triggers (RPG::Event::Page#trigger).
      TRIGGER_ACTION       = 0 # player presses the action button facing it
      TRIGGER_PLAYER_TOUCH = 1 # player walks into it
      TRIGGER_EVENT_TOUCH  = 2 # it walks into the player (not modelled yet)
      TRIGGER_AUTORUN      = 3 # runs automatically while its page is active
      TRIGGER_PARALLEL     = 4 # runs continuously in the background

      def initialize(parent, state)
        super parent
        @state = state
        @map = state.map
        @tileset = Game::TileSet.new(@db, @map.tileset_id)
        @charset = load_charset

        @moving = false
        @move_count = 0
        @dest_x = @state.x
        @dest_y = @state.y
        @last_frame = nil
        @player_pattern = 0
        @player_anime = 0

        # RMXP's $game_screen.pictures, keyed by the number the commands use.
        # They live on the scene, not the map, so they survive a Transfer Player
        # the way they do in RMXP (Spriteset_Map is rebuilt; the picture list is
        # not).
        @pictures = {}
        @picture_sprites = {}
        # RMXP's $game_screen flash / shake, applied to the screen viewport that
        # holds the map (see setup_sprites) -- the flash as its colour overlay,
        # the shake as its scroll origin, exactly where Spriteset_Map puts them.
        @screen = Game::Screen.new
        # Scroll Map (203) pushes the camera off the leader; the offset rides on
        # top of the follow camera and persists until another scroll moves it.
        @scroll = Game::Scroll.new
        # Show Animation (207) playbacks, keyed by target (:player or an event
        # id). RMXP keeps one animation slot per character; so does this.
        @animations = {}

        @resolver = EventResolver.new(@db.common_events)
        @interpreter = Game::Interpreter.new(@state)
        @interpreter.resolver = @resolver
        @message = nil
        @wait_timer = nil
        @choice_index = 0
        @running_event_id = nil

        # Deterministic RNG for autonomous movement, and the adapter the movement
        # engine queries. Characters persist across page re-selection (keyed by
        # event id) so a roamed event does not snap back to its spawn tile.
        @rng = Game::Rng.new(0x52584250)
        @world = MapWorld.new(self, @rng)
        @characters = {}
        # Forced routes from a Set Move Route (209) command, keyed by event id
        # (kept out of the per-rebuild event entry so they survive page
        # re-selection); plus the player's forced route mirror.
        @forced_routes = {}
        @player_route = nil
        @player_char = nil
        # Event ids erased by an Erase Event (116) command: skipped when the event
        # list is rebuilt so they stay gone until the map is (re)loaded.
        @erased = {}
        build_events
        build_parallels
        setup_sprites
        render
      end

      attr_reader :state

      def dispose
        close_message
        close_number_input
        @event_sprites.each_value { |s| s[:sprite].dispose } if @event_sprites
        dispose_frozen
        dispose_animations
        @picture_sprites.each_value { |e| e[:sprite].dispose } if @picture_sprites
        [@tilemap, @player_sprite, @screen_viewport,
         @picture_viewport].each { |s| s.dispose if s }
      end

      def update
        if @message
          drive_message
        elsif @number_input
          drive_number_input
        elsif @interpreter.running? || @interpreter.waiting?
          drive_interpreter
        else
          unless start_autorun
            step_parallels
            step_player_route
            step_events
            unless event_busy? # an event-touch may have started a process
              step_movement
              try_action
            end
          end
        end
        animate_player
        step_tone_change
        step_screen_effects
        update_pictures
        render
      end

      def event_busy?
        @message || @number_input || @interpreter.running? || @interpreter.waiting?
      end

      private

      def load_charset
        actor = @state.leader
        return nil unless actor
        name = actor.character_name
        return nil if name.nil? || name.empty?
        bmp = Bitmap.new "Graphics/Characters/#{name}"
        hue_shift bmp, actor.character_hue
        bmp
      rescue StandardError => e
        $stderr.puts "[RGSS] leader charset load failed, using marker: #{e.message}"
        nil
      end

      # (Re)build the runtime event list for the current map: pick each event's
      # active page (per switch / variable / self-switch conditions) and index
      # the tiles they occupy for collision and drawing. Called on entry and
      # whenever an event finishes, since it may have flipped a switch.
      def build_events
        @events = {}
        @event_tiles = {}
        (@map.events || {}).each do |id, ev|
          next if @erased[id] # erased for the rest of this map visit
          entry = build_event(id, ev)
          @events[id] = entry
          @event_tiles[[entry[:char].x, entry[:char].y]] = entry if entry[:page]
        end
        # A rebuild can have swapped which page (and so which graphic) is active.
        refresh_event_sprites
      rescue StandardError => e
        $stderr.puts "[RGSS] event setup failed, map runs with no events: #{e.message}"
        @events = {}
        @event_tiles = {}
      end

      # Build one event's runtime entry: its active page, a persistent
      # Game::Character (reused across rebuilds so a roamed event keeps its
      # position) refreshed with the page's movement properties, and the page's
      # autonomous move type or custom move route.
      def build_event(id, ev)
        page = Game::EventPage.select(ev.pages, @state.switches, @state.variables,
                                      ->(ch) { @state.self_switch(@state.map_id, id, ch) })
        ch = (@characters[id] ||= Game::Character.new(ev.x, ev.y, ev_direction(page)))
        move_type = 0
        route = nil
        if page
          ch.move_speed = page.move_speed || 3
          ch.move_frequency = page.move_frequency || 3
          ch.through = page.through ? true : false
          ch.direction_fix = page.direction_fix ? true : false
          ch.always_on_top = page.always_on_top ? true : false
          # RMXP's page defaults are walk_anime on, step_anime off; an absent
          # field means the page never said, not "off".
          ch.walk_anime = page.walk_anime.nil? ? true : (page.walk_anime ? true : false)
          ch.step_anime = page.step_anime ? true : false
          g = page.graphic
          if g
            ch.set_graphic(g.character_name, g.character_hue, g.direction, g.pattern)
            # RMXP's Game_Event#refresh takes these off the page's graphic too;
            # a move route's Change Opacity / Change Blending then overrides them.
            ch.opacity = g.opacity || 255
            ch.blend_type = g.blend_type || 0
          end
          move_type = page.move_type || 0
          route = Game::MoveRoute.from_page(page.move_route) if move_type == Game::MoveType::CUSTOM
        end
        { id: id, ev: ev, page: page, char: ch, trigger: page && page.trigger,
          move_type: move_type, route: route }
      rescue StandardError => e
        $stderr.puts "[RGSS] event ##{id} setup failed: #{e.message}"
        { id: id, ev: ev, page: nil, char: (@characters[id] ||= Game::Character.new(ev.x, ev.y)),
          trigger: nil, move_type: 0, route: nil }
      end

      def ev_direction(page)
        return 2 unless page && page.graphic
        d = page.graphic.direction
        d && d > 0 ? d : 2
      end

      # Background (parallel-process) interpreters: one per event whose active
      # page has the parallel trigger. Each loops its own list.
      def build_parallels
        @parallels = []
        @events.each do |id, e|
          next unless e[:trigger] == TRIGGER_PARALLEL && e[:page] && page_list(e)
          it = Game::Interpreter.new(@state)
          it.resolver = @resolver
          it.start(page_list(e), @state.map_id, id)
          @parallels << { interp: it, id: id, list: page_list(e), wait: nil }
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] parallel setup failed: #{e.message}"
        @parallels = []
      end

      def page_list(entry)
        p = entry[:page]
        p && p.list
      end

      # -- event execution ----------------------------------------------------

      # Start the first autorun event's page (if any). Returns true when one was
      # started, so the caller skips movement this frame.
      def start_autorun
        e = @events.values.find do |ev|
          ev[:trigger] == TRIGGER_AUTORUN && ev[:page] && list_nonempty?(page_list(ev))
        end
        return false unless e
        @running_event_id = e[:id]
        @interpreter.start(page_list(e), @state.map_id, e[:id])
        drive_interpreter
        true
      end

      def try_action
        return unless Input.trigger?(Input::C)
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        e = @event_tiles[[fx, fy]]
        return unless e && e[:trigger] == TRIGGER_ACTION && list_nonempty?(page_list(e))
        e[:char].face(e[:char].direction_toward(@state.x, @state.y))
        start_event(e)
      end

      # Run an event's command list (faced toward the player by the caller).
      def start_event(e)
        @running_event_id = e[:id]
        @interpreter.start(page_list(e), @state.map_id, e[:id])
        drive_interpreter
      end

      # Advance each event one frame: its walk animation and the glide toward
      # the tile it stepped onto, then -- once it has stood still long enough --
      # its next autonomous or custom-route step. Skipped once any event process
      # is running this frame, so the map holds still during messages.
      def step_events
        @events.each do |_id, e|
          ch = e[:char]
          ch.update if ch
          step_event(e)
        end
      end

      def step_event(e)
        return if event_busy?
        ch = e[:char]
        return unless ch
        # Still crossing a tile: nothing new starts until it arrives.
        return if ch.moving?
        # A forced route (Set Move Route) overrides page movement until it is done.
        forced = @forced_routes[e[:id]]
        return step_forced_event(e, ch, forced) if forced
        return unless e[:page]
        return if ch.stop_count <= move_wait(ch)
        ox = ch.x
        oy = ch.y
        if e[:route]
          run_route(e[:route], ch)
        else
          dir = Game::MoveType.next_direction(e[:move_type], ch, @world)
          move_autonomous(e, dir) if dir
        end
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy
      rescue StandardError => ex
        $stderr.puts "[RGSS] event ##{e[:id]} movement failed: #{ex.message}"
      end

      # Frames an event stands still between steps, as RMXP paces autonomous
      # movement: `(40 - frequency * 2) * (6 - frequency)`, so frequency 1 waits
      # 190 frames and frequency 6 never waits at all. The glide itself is timed
      # separately, by move speed.
      def move_wait(ch)
        f = ch.move_frequency || 3
        (40 - f * 2) * (6 - f)
      end

      # One turn of a move route. A movement command ends the turn (the walk
      # takes time); the commands that only have an effect -- turns, switches,
      # a graphic change -- run straight away and the route carries on, as
      # RMXP's move_type_custom does, so a route of them does not spend a whole
      # wait period per command. Bounded so a route made only of effects cannot
      # spin.
      ROUTE_EFFECTS_PER_TURN = 64

      def run_route(route, ch)
        ROUTE_EFFECTS_PER_TURN.times do
          break if route.done?
          break unless route.step(ch, @world) == :effect
        end
      end

      # Advance an event's forced route one paced step, updating its occupied
      # tile, and drop the route once a non-repeating one is exhausted.
      def step_forced_event(e, ch, forced)
        return if ch.stop_count <= move_wait(ch)
        ox = ch.x
        oy = ch.y
        run_route(forced[:route], ch)
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy
        @forced_routes.delete(e[:id]) if forced[:route].done?
      rescue StandardError => ex
        $stderr.puts "[RGSS] event ##{e[:id]} forced move failed: #{ex.message}"
        @forced_routes.delete(e[:id])
      end

      # Apply the Set Move Route requests an interpreter queued this frame. The
      # interpreter has already resolved each target to :player or an event id.
      def apply_move_requests(interp)
        reqs = interp.take_move_route_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_move_request(r) }
      rescue StandardError => e
        $stderr.puts "[RGSS] Set Move Route apply failed: #{e.message}"
      end

      # Apply the Screen Flash (224) / Screen Shake (225) requests an interpreter
      # queued this frame.
      def apply_screen_requests(interp)
        reqs = interp.take_screen_requests
        return if reqs.nil? || reqs.empty?
        reqs.each do |r|
          if r[:op] == :flash
            @screen.start_flash(color_values(r[:color]), r[:duration])
          else
            @screen.start_shake(r[:power], r[:speed], r[:duration])
          end
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] screen effect failed: #{e.message}"
      end

      # One frame of the flash decay and the shake spring, handed to the screen
      # viewport. Only written when something is actually running, and only when
      # the value changed: each write re-composites the viewport natively.
      def step_screen_effects
        return unless @screen && @screen_viewport
        return unless @screen.flashing? || @screen.shaking? || @screen_dirty
        @screen.update
        c = @screen.flash_color
        if @flash_shown != c[3]
          @flash_shown = c[3]
          @screen_viewport.color = Color.new(c[0], c[1], c[2], c[3])
        end
        shake = @screen.shake.to_i
        if @shake_shown != shake
          @shake_shown = shake
          @screen_viewport.ox = shake
        end
        @screen_viewport.update
        # Keep stepping for one more frame after everything stopped, so the last
        # write (back to no tint, no offset) actually lands.
        @screen_dirty = @screen.flashing? || @screen.shaking?
      rescue StandardError => e
        $stderr.puts "[RGSS] screen effect step failed: #{e.message}"
        @screen_dirty = false
      end

      # Apply the Show Animation (207) requests an interpreter queued this frame.
      # A second animation on the same character replaces the first, as RMXP's
      # single `animation_id` slot does.
      def apply_animation_requests(interp)
        reqs = interp.take_animation_requests
        return if reqs.nil? || reqs.empty?
        reqs.each do |r|
          record = @db.animations[r[:animation_id]]
          unless record
            $stderr.puts "[RGSS] Show Animation: no animation ##{r[:animation_id]}"
            next
          end
          dispose_animation(r[:target])
          @animations[r[:target]] =
            { anim: Game::Animation.new(record), sprites: [], sheet: nil }
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] Show Animation failed: #{e.message}"
      end

      # Draw one tick of every running animation and drop the finished ones.
      # Called from render, after the characters have been positioned, because a
      # non-screen animation is anchored on its target's sprite.
      def update_animations
        return if @animations.nil? || @animations.empty?
        done = []
        @animations.each do |target, entry|
          if entry[:anim].playing?
            draw_animation(target, entry)
            entry[:anim].update
          else
            done << target
          end
        end
        done.each { |t| dispose_animation(t) }
      rescue StandardError => e
        $stderr.puts "[RGSS] animation update failed: #{e.message}"
      end

      def draw_animation(target, entry)
        anim = entry[:anim]
        index = anim.frame_index
        sheet = animation_sheet(entry, anim)
        return unless sheet
        ax, ay = animation_anchor(target, anim.position)
        return if ax.nil?
        cells = anim.cells(index)
        cells.each_with_index { |cell, i| draw_animation_cell(entry, i, cell, ax, ay, sheet) }
        # Sprites the frame no longer uses stay allocated but stop drawing.
        i = cells.size
        while i < entry[:sprites].size
          entry[:sprites][i].visible = false
          i += 1
        end
        run_animation_timings(target, anim, index)
      end

      # The sheet for an animation, loaded once per playback and hue-rotated the
      # way RPG::Cache.animation does.
      def animation_sheet(entry, anim)
        return entry[:sheet] if entry[:sheet]
        bmp = load_map_graphic("Animations", anim.sheet_name)
        return nil unless bmp
        hue_shift bmp, anim.sheet_hue
        entry[:sheet] = bmp
      end

      # Where an animation's cells are centred: on the target character's sprite
      # (nudged a quarter of its height up or down for the "top" / "bottom"
      # positions), or fixed to the screen. nil when the target is not on the map
      # any more.
      def animation_anchor(target, position)
        if position == Game::Animation::POSITION_SCREEN
          return [SCREEN_W / 2, SCREEN_H - 160]
        end
        if target == :player
          return [nil, nil] unless @player_sprite
          w = @player_bmp.width
          h = @player_bmp.height
          x = @player_sprite.x + w / 2
          y = @player_sprite.y + h / 2
        else
          s = @event_sprites && @event_sprites[target]
          return [nil, nil] unless s
          w = s[:w]
          h = s[:h]
          x = s[:sprite].x + w / 2
          y = s[:sprite].y + h / 2
        end
        y -= h / 4 if position == Game::Animation::POSITION_TOP
        y += h / 4 if position == Game::Animation::POSITION_BOTTOM
        [x, y]
      end

      ANIMATION_Z = 2000

      def draw_animation_cell(entry, i, cell, ax, ay, sheet)
        sprite = entry[:sprites][i]
        unless sprite
          sprite = Sprite.new(@screen_viewport)
          sprite.bitmap = sheet
          sprite.z = ANIMATION_Z
          entry[:sprites][i] = sprite
        end
        pattern, cx, cy, zoom, angle, mirror, opacity, blend = cell
        rect = Game::Animation.cell_rect(pattern)
        sprite.src_rect = Rect.new(rect[0], rect[1], rect[2], rect[3])
        scale = zoom.to_f / 100.0
        # RGSS centres a cell with ox/oy = 96; those are not wired to where a
        # sprite draws here (as for a centred picture origin), so the half-cell
        # is taken off the position instead, scaled with the zoom.
        half = (Game::Animation::CELL_SIZE * scale / 2).to_i
        sprite.x = ax + cx.to_i - half
        sprite.y = ay + cy.to_i - half
        sprite.zoom_x = scale
        sprite.zoom_y = scale
        sprite.angle = angle.to_i
        sprite.mirror = mirror.to_i == 1
        sprite.opacity = opacity.to_i
        sprite.blend_type = blend.to_i
        sprite.visible = true
      end

      # An animation frame's sound effect and flash. RMXP flashes either the
      # target itself or the whole screen; both already exist here (the sprite's
      # native decaying flash, and Game::Screen's).
      def run_animation_timings(target, anim, index)
        anim.timings_at(index).each do |t|
          play_animation_se(t.se)
          case t.flash_scope
          when Game::Animation::FLASH_SCREEN
            c = t.flash_color
            @screen.start_flash(color_values(c), t.flash_duration.to_i) if c
          when Game::Animation::FLASH_TARGET
            flash_character(target, t.flash_color, t.flash_duration.to_i)
          end
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] animation timing failed: #{e.message}"
      end

      def play_animation_se(se)
        return if se.nil? || se.name.nil? || se.name.empty?
        Audio.se_play(se.name, se.volume || 100, se.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RGSS] animation SE '#{se.name}' failed: #{e.message}"
      end

      def flash_character(target, color, duration)
        return unless color
        sprite = if target == :player
                   @player_sprite
                 else
                   s = @event_sprites && @event_sprites[target]
                   s && s[:sprite]
                 end
        return unless sprite
        sprite.flash(Color.new(color.red, color.green, color.blue, color.alpha),
                     duration)
      rescue StandardError => e
        $stderr.puts "[RGSS] animation flash failed: #{e.message}"
      end

      def dispose_animation(target)
        entry = @animations[target]
        return unless entry
        entry[:sprites].each { |s| s.dispose if s }
        entry[:sheet].dispose if entry[:sheet]
        @animations.delete(target)
      end

      def dispose_animations
        return unless @animations
        @animations.keys.each { |t| dispose_animation(t) }
      end

      # Scroll Map (203): start the commanded scroll and carry straight on. RMXP
      # holds the command while an earlier scroll is still running, so this keeps
      # the interpreter suspended until there is nothing to collide with.
      def drive_scroll
        return if @scroll.scrolling?
        r = @interpreter.scroll_request
        @scroll.start(r[:direction], r[:distance], r[:speed], TILE) if r
        @interpreter.resume
      rescue StandardError => e
        $stderr.puts "[RGSS] Scroll Map failed: #{e.message}"
        @interpreter.resume
      end

      # Only the foreground interpreter freezes the screen. A background (parallel)
      # process is never suspended on a UI request -- step_parallel resumes those
      # at once so the loop keeps running -- so its Execute Transition would
      # never dissolve the still, leaving the screen stuck on a snapshot for
      # good. Its 221 is simply not applied.
      #
      # Prepare for Transition (221): hold the screen exactly as it is now, on a
      # sprite above everything, so the teleport / tint / map change that follows
      # happens behind it unseen. RGSS's own Graphics.freeze snapshot, kept as
      # scene state instead of inside Graphics because the dissolve below has to
      # run one frame per update rather than in a blocking loop.
      def apply_freeze_request(interp)
        return unless interp.take_freeze_request
        dispose_frozen
        bmp = RGSS::Graphics.snap_to_bitmap
        unless bmp
          # A backend that cannot snapshot says so itself, once; the transition
          # then degrades to a plain wait, which is what Graphics.transition does.
          return
        end
        @frozen = { bitmap: bmp, sprite: Sprite.new }
        @frozen[:sprite].bitmap = bmp
        @frozen[:sprite].z = RGSS::Graphics::TRANSITION_Z
      rescue StandardError => e
        $stderr.puts "[RGSS] Prepare for Transition failed: #{e.message}"
        @frozen = nil
      end

      # Execute Transition (222): dissolve the frozen still away over
      # Interpreter::TRANSITION_FRAMES frames, resuming the interpreter when it
      # is gone. RMXP reaches the same ordering by *blocking* in
      # Graphics.transition(20) — the scene simply is not updated during it — but
      # a 20-frame loop inside one frame callback is what the browser build
      # cannot afford, so the wait is spread over real frames instead.
      def drive_transition
        unless @frozen
          @interpreter.resume # nothing frozen: 222 without a 221, or no snapshot
          return
        end
        total = Game::Interpreter::TRANSITION_FRAMES
        @transition_step = (@transition_step || 0) + 1
        if @transition_step >= total
          dispose_frozen
          @transition_step = nil
          @interpreter.resume
          return
        end
        @frozen[:sprite].opacity = 255 - (255 * @transition_step / total)
      rescue StandardError => e
        $stderr.puts "[RGSS] Execute Transition failed: #{e.message}"
        dispose_frozen
        @transition_step = nil
        @interpreter.resume
      end

      def dispose_frozen
        return unless @frozen
        @frozen[:sprite].dispose
        @frozen[:bitmap].dispose
        @frozen = nil
      end

      # Apply the picture (231..235) requests an interpreter queued this frame,
      # against the picture list this scene owns.
      def apply_picture_requests(interp)
        reqs = interp.take_picture_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_picture_request(r) }
      rescue StandardError => e
        $stderr.puts "[RGSS] picture command failed: #{e.message}"
      end

      def apply_picture_request(r)
        n = r[:number]
        return if n.nil? || n <= 0
        pic = (@pictures[n] ||= Game::Picture.new(n))
        case r[:op]
        when :show
          pic.show(r[:name], r[:origin], r[:x], r[:y], r[:zoom_x], r[:zoom_y],
                   r[:opacity], r[:blend_type])
        when :move
          pic.move(r[:duration], r[:origin], r[:x], r[:y], r[:zoom_x],
                   r[:zoom_y], r[:opacity], r[:blend_type])
        when :rotate then pic.rotate(r[:speed])
        when :tone   then pic.start_tone_change(tone_values(r[:tone]), r[:duration])
        when :erase  then pic.erase
        end
      end

      # An RPG::Color from the data as the four numbers Game::Screen keeps.
      def color_values(color)
        [color.red, color.green, color.blue, color.alpha]
      end

      # An RPG::Tone from the data as the four numbers Game::Picture keeps.
      def tone_values(tone)
        [tone.red, tone.green, tone.blue, tone.gray]
      end

      # Advance every picture's move / tone / rotation ease and mirror the list
      # into sprites. RMXP puts pictures in Spriteset_Map's @viewport2, above the
      # map and below the windows; ours sit in their own viewport between the map
      # (z 0) and the Panels (z 100) for the same ordering.
      PICTURE_Z = 50

      def update_pictures
        return if @pictures.nil? || @pictures.empty?
        @pictures.each_value do |pic|
          pic.update
          draw_picture(pic)
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] picture update failed: #{e.message}"
      end

      def draw_picture(pic)
        entry = @picture_sprites[pic.number]
        unless pic.shown?
          entry[:sprite].visible = false if entry
          return
        end
        entry = load_picture_sprite(pic, entry)
        return unless entry
        s = entry[:sprite]
        s.visible = true
        # RGSS's ox/oy are not wired to where a sprite draws here, so a centred
        # origin (1) is applied to the position instead -- scaled, because the
        # centre of a zoomed picture moves with the zoom.
        if pic.origin == 0
          s.x = pic.x.to_i
          s.y = pic.y.to_i
        else
          s.x = (pic.x - entry[:w] * pic.zoom_x / 200.0).to_i
          s.y = (pic.y - entry[:h] * pic.zoom_y / 200.0).to_i
        end
        s.zoom_x = pic.zoom_x / 100.0
        s.zoom_y = pic.zoom_y / 100.0
        s.angle = pic.angle
        s.opacity = pic.opacity.to_i
        s.blend_type = pic.blend_type
        t = pic.tone
        # Only write the tone when it changed: each write re-composites the
        # sprite natively.
        if entry[:tone] != t
          entry[:tone] = [t[0], t[1], t[2], t[3]]
          s.tone = Tone.new(t[0], t[1], t[2], t[3])
        end
      end

      # The sprite for a picture, (re)built when the slot's graphic changed. A
      # missing file leaves the slot blank rather than taking the map down.
      def load_picture_sprite(pic, entry)
        return entry if entry && entry[:name] == pic.name
        entry[:sprite].dispose if entry
        @picture_sprites.delete(pic.number)
        bmp = load_map_graphic("Pictures", pic.name)
        return nil unless bmp
        @picture_viewport ||= begin
          vp = Viewport.new(0, 0, SCREEN_W, SCREEN_H)
          vp.z = PICTURE_Z
          vp
        end
        sprite = Sprite.new(@picture_viewport)
        sprite.bitmap = bmp
        entry = { sprite: sprite, bitmap: bmp, name: pic.name,
                  w: bmp.width, h: bmp.height, tone: nil }
        @picture_sprites[pic.number] = entry
        entry
      end

      # Apply the Set Event Location (202) requests an interpreter queued this
      # frame. A character is *snapped* to its tile, as RMXP's
      # `Game_Character#moveto` does: no walking, no passability test.
      def apply_location_requests(interp)
        reqs = interp.take_location_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_location_request(r) }
      rescue StandardError => e
        $stderr.puts "[RGSS] Set Event Location apply failed: #{e.message}"
      end

      def apply_location_request(r)
        unless r[:swap_with]
          place_character(r[:target], r[:x], r[:y], r[:direction])
          return
        end
        # "Exchange with another event": each ends up where the other was.
        here = character_tile(r[:target])
        there = character_tile(r[:swap_with])
        return if here.nil? || there.nil?
        place_character(r[:target], there[0], there[1], r[:direction])
        place_character(r[:swap_with], here[0], here[1], 0)
      end

      # The tile a Set Event Location target stands on, or nil when it is not on
      # this map.
      def character_tile(target)
        return [@state.x, @state.y] if target == :player
        e = @events[target]
        e && e[:char] ? [e[:char].x, e[:char].y] : nil
      end

      def place_character(target, x, y, direction)
        return if x.nil? || y.nil?
        if target == :player
          @state.x = x
          @state.y = y
          @state.direction = direction if direction && direction > 0
          # Mid-step bookkeeping has to go with it, or the leader glides back to
          # where it was walking.
          @moving = false
          @move_count = 0
          @dest_x = x
          @dest_y = y
          @player_route = nil
          @player_char = nil
          @last_frame = nil
        else
          e = @events[target]
          return unless e && e[:char]
          ox = e[:char].x
          oy = e[:char].y
          e[:char].x = x
          e[:char].y = y
          e[:char].direction = direction if direction && direction > 0
          reoccupy(e, ox, oy)
        end
      end

      # Apply the Change Screen Color Tone (223) requests an interpreter queued
      # this frame. Like a Set Move Route it does not suspend the interpreter, so
      # it is polled the same way.
      def apply_tint_requests(interp)
        reqs = interp.take_tint_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| start_tone_change(r[:tone], r[:duration]) }
      rescue StandardError => e
        $stderr.puts "[RGSS] screen tone apply failed: #{e.message}"
      end

      # Begin easing the screen viewport's tone toward `tone` over `duration`
      # frames, as RMXP's Game_Screen#start_tone_change does. A zero duration
      # snaps. The tone lives on the viewport that holds the map (see
      # setup_sprites), so windows drawn above it keep their own colours.
      def start_tone_change(tone, duration)
        return unless @screen_viewport && tone
        target = [tone.red, tone.green, tone.blue, tone.gray]
        frames = duration.to_i
        if frames <= 0
          @tone_change = nil
          set_screen_tone(target)
          return
        end
        cur = @screen_viewport.tone
        @tone_change = { from: [cur.red, cur.green, cur.blue, cur.gray],
                         to: target, frames: frames, step: 0 }
      end

      # One frame of the running tone ease (no-op when none is running).
      def step_tone_change
        c = @tone_change
        return unless c
        c[:step] += 1
        if c[:step] >= c[:frames]
          set_screen_tone(c[:to])
          @tone_change = nil
          return
        end
        t = c[:step]
        n = c[:frames]
        set_screen_tone((0..3).map { |i| c[:from][i] + (c[:to][i] - c[:from][i]) * t / n })
      rescue StandardError => e
        $stderr.puts "[RGSS] screen tone step failed: #{e.message}"
        @tone_change = nil
      end

      def set_screen_tone(v)
        return unless @screen_viewport
        @screen_viewport.tone = Tone.new(v[0], v[1], v[2], v[3])
        @screen_viewport.update
      end

      def apply_move_request(r)
        route = Game::MoveRoute.from_page(r[:route])
        return unless route
        if r[:target] == :player
          start_player_route(route)
        else
          force_event_route(r[:target], route)
        end
      end

      # Give a map event a forced route, overriding its page movement until the
      # route finishes (a repeating route runs until replaced). It steps on the
      # next frame, paced by the event's own move frequency.
      def force_event_route(id, route)
        return unless @characters[id]
        @forced_routes[id] = { route: route, timer: 0 }
      end

      # Drive the player along a forced route: the player has no Game::Character,
      # so mirror one, step it against the map world and write the tile back to
      # the state. Forced player steps snap tile-to-tile (no pixel interpolation)
      # and suppress input movement while active.
      def start_player_route(route)
        @player_char = Game::Character.new(@state.x, @state.y, @state.direction)
        @player_route = route
      end

      def step_player_route
        return unless @player_route
        @player_char.update
        return if @player_char.moving? || @player_char.stop_count <= move_wait(@player_char)
        run_route(@player_route, @player_char)
        @state.x = @player_char.x
        @state.y = @player_char.y
        @state.direction = @player_char.direction
        @dest_x = @state.x
        @dest_y = @state.y
        @moving = false
        @move_count = 0
        @player_route = nil if @player_route.done?
      rescue StandardError => e
        $stderr.puts "[RGSS] player forced move failed: #{e.message}"
        @player_route = nil
      end

      # Move an autonomous event one step in `dir`. Walking into the player fires
      # an event-touch (trigger 2) event instead of moving; any other obstacle
      # just turns the event to face it.
      def move_autonomous(e, dir)
        ch = e[:char]
        nx, ny = Game::Character.step_tile(ch.x, ch.y, dir)
        if nx == @state.x && ny == @state.y
          ch.face(dir)
          if e[:trigger] == TRIGGER_EVENT_TOUCH && list_nonempty?(page_list(e))
            # Bumping into the player runs the event; wait a full move period
            # before bumping again rather than re-running it every frame.
            ch.hold_still
            start_event(e)
          end
        elsif @world.passable?(ch, dir)
          ch.move(dir)
        else
          ch.face(dir)
        end
      end

      # Update the occupied-tile cache after event `e` moved off (ox, oy). Done
      # eagerly so an event that already moved this frame blocks the next one.
      def reoccupy(e, ox, oy)
        @event_tiles.delete([ox, oy]) if @event_tiles[[ox, oy]].equal?(e)
        @event_tiles[[e[:char].x, e[:char].y]] = e
      end

      # Collision test for an event stepping one tile in `dir`: in bounds, not
      # onto the player or another event, and passable per the tileset. A
      # "through" character ignores all of it. Public: called by MapWorld.
      def char_passable?(character, dir)
        return true if character.through
        nx, ny = Game::Character.step_tile(character.x, character.y, dir)
        return false unless in_bounds?(nx, ny)
        return false if nx == @state.x && ny == @state.y
        return false if @event_tiles[[nx, ny]]
        @tileset.passable?(@map, nx, ny, dir)
      end
      public :char_passable?

      def drive_interpreter
        if @interpreter.waiting?
          case @interpreter.wait_kind
          when :message  then open_message(@interpreter.message_lines, false)
          when :choice   then open_message(@interpreter.choice_labels, true)
          when :number   then open_number_input(@interpreter.input_digits)
          when :wait     then drive_wait
          when :teleport then perform_teleport(@interpreter.teleport)
          when :move_completion then drive_move_completion
          when :transition then drive_transition
          when :scroll then drive_scroll
          end
        else
          @interpreter.update
          apply_move_requests(@interpreter)
          apply_tint_requests(@interpreter)
          apply_location_requests(@interpreter)
          apply_picture_requests(@interpreter)
          apply_freeze_request(@interpreter)
          apply_screen_requests(@interpreter)
          apply_animation_requests(@interpreter)
          apply_erase_request(@interpreter, @running_event_id)
          finish_event unless @interpreter.running? || @interpreter.waiting?
        end
      end

      # Remove the running event from the map when its interpreter raised an Erase
      # Event this step. Keyed by id so the removal survives the build_events
      # rebuild that finish_event triggers.
      def apply_erase_request(interp, event_id)
        erase_event(event_id) if interp.take_erase_request && event_id
      rescue StandardError => e
        $stderr.puts "[RGSS] Erase Event failed: #{e.message}"
      end

      # Drop an event from the runtime list, the occupied-tile cache (so it no
      # longer draws / moves / blocks), any forced route and any parallel process
      # it was driving, and mark it erased so a rebuild keeps it gone.
      def erase_event(id)
        @erased[id] = true
        e = @events[id]
        if e && e[:char]
          tile = [e[:char].x, e[:char].y]
          @event_tiles.delete(tile) if @event_tiles[tile].equal?(e)
        end
        @events.delete(id)
        @forced_routes.delete(id)
        @parallels.reject! { |p| p[:id] == id } if @parallels
      end

      # An event finished: re-select pages (a self switch / switch it set may
      # change which page is active) and rebuild parallels.
      def finish_event
        @running_event_id = nil
        build_events
        build_parallels
      end

      def drive_wait
        @wait_timer = @interpreter.wait_frames if @wait_timer.nil?
        if @wait_timer <= 0
          @wait_timer = nil
          @interpreter.resume
        else
          @wait_timer -= 1
        end
      end

      # Wait for Move's Completion (210): hold the interpreter until no forced
      # route is walking any more. `step_events` refuses to move anything while
      # an event process is running (that is what keeps the map still during a
      # message), so the routes have to be driven here -- the interpreter is
      # suspended *on* them, which is the one case RMXP keeps forcing characters
      # along for too.
      #
      # A *repeating* forced route never completes, so a game that waits on one
      # would hang here (it hangs in RMXP too). Rather than freeze -- headlessly,
      # with no way to tell -- the wait is bounded and says why it gave up.
      MOVE_COMPLETION_TIMEOUT = 600 # frames

      def drive_move_completion
        step_forced_routes
        if forced_routes_running?
          @move_wait_frames = (@move_wait_frames || 0) + 1
          return if @move_wait_frames <= MOVE_COMPLETION_TIMEOUT
          $stderr.puts "[RGSS] Wait for Move's Completion gave up after " \
                       "#{MOVE_COMPLETION_TIMEOUT} frames; a forced route is " \
                       "still running (a repeating route never completes)"
        end
        @move_wait_frames = nil
        @interpreter.resume
      end

      def forced_routes_running?
        return true if @player_route
        !(@forced_routes.nil? || @forced_routes.empty?)
      end

      # Advance only the forced routes, past the "an event is running" hold.
      def step_forced_routes
        step_player_route
        @events.each do |_id, e|
          ch = e[:char]
          next unless ch
          ch.update
          forced = @forced_routes[e[:id]]
          next if forced.nil? || ch.moving?
          step_forced_event(e, ch, forced)
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] forced route step failed: #{e.message}"
      end

      # Advance every background parallel process one frame. They honour Wait but
      # do not drive the message/choice/teleport UI (those requests are resumed
      # so the loop keeps running). Only stepped while the foreground is idle.
      def step_parallels
        @parallels.each { |p| step_parallel(p) }
      end

      def step_parallel(p)
        it = p[:interp]
        if it.waiting?
          if it.wait_kind == :wait
            p[:wait] = it.wait_frames if p[:wait].nil?
            if p[:wait] <= 0
              p[:wait] = nil
              it.resume
            else
              p[:wait] -= 1
            end
          else
            it.resume # ignore UI requests in the background
          end
        elsif it.running?
          it.update
          apply_move_requests(it)
          apply_tint_requests(it)
          apply_location_requests(it)
          apply_picture_requests(it)
          apply_screen_requests(it)
          apply_animation_requests(it)
          apply_erase_request(it, p[:id])
        else
          it.start(p[:list], @state.map_id, p[:id]) # loop the process
          it.update
          apply_move_requests(it)
          apply_tint_requests(it)
          apply_location_requests(it)
          apply_picture_requests(it)
          apply_screen_requests(it)
          apply_animation_requests(it)
          apply_erase_request(it, p[:id])
        end
      rescue StandardError
        nil
      end

      def perform_teleport(t)
        map_id, x, y, dir = t
        @interpreter.stop
        @map = @db.load_map(map_id)
        @state.map = @map
        @state.map_id = map_id
        @state.x = x
        @state.y = y
        @state.direction = dir if dir && dir > 0
        @tileset = Game::TileSet.new(@db, @map.tileset_id)
        # The ground is a Tilemap built from the *map's* data/priorities and its
        # tileset's graphics, so a map change has to build a new one -- RMXP
        # disposes the whole Spriteset_Map and makes another in
        # Scene_Map#transfer_player. Keeping the old one left the new map drawn
        # with the previous map's tiles (black, when the previous map was the
        # empty opening map Pray for You starts on) while its events and the
        # party walked on top.
        @tilemap.dispose if @tilemap
        @tilemap = nil
        setup_tilemap
        @moving = false
        @move_count = 0
        @dest_x = x
        @dest_y = y
        @last_frame = nil
        @player_pattern = 0
        @player_anime = 0
        @characters = {} # new map: events start at their spawn tiles
        @forced_routes = {} # forced routes do not survive a map change
        @erased = {} # erased events reappear on a fresh map
        @player_route = nil
        @player_char = nil
        @move_wait_frames = nil
        build_events
        build_parallels
      rescue StandardError => e
        $stderr.puts "[RGSS] Teleport failed: #{e.message}"
        @interpreter.stop
      end

      # -- message / choice window --------------------------------------------

      # Look up an actor name by id for the \N[] message control code.
      def actor_name(id)
        a = @db.actors[id]
        a ? a.name.to_s : ""
      rescue StandardError
        ""
      end

      def open_message(lines, choice)
        return if @message
        names = ->(id) { actor_name(id) }
        lines = (lines || []).map do |l|
          # Choice labels are expanded too, so \V[n]/\N[n] work in menu options.
          Game::Message.expand(l.to_s, @state.variables, names)
        end
        lines = [""] if lines.empty?
        # RMXP's box is a fixed four-line 480x160; a longer list (a Show Choices
        # appended under the text) grows it upward from the same bottom edge
        # rather than clipping.
        h = [lines.length * MSG_LINE_H + Panel::BORDER * 2, MSG_H].max
        win = Panel.new(MSG_X, SCREEN_H - MSG_MARGIN - h, MSG_W, h,
                        load_windowskin)
        win.z = 300
        contents = Bitmap.new(win.inner_width, win.inner_height)
        contents.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          contents.draw_text MSG_TEXT_X, i * MSG_LINE_H,
                             contents.width - MSG_TEXT_X, MSG_LINE_H, line
        end
        win.contents = contents
        # RMXP sets Window_Message#pause while it holds a text box waiting for
        # the player, and clears it for a choice (the cursor is the prompt
        # there).
        win.pause = !choice
        @message = { window: win, choice: choice, count: lines.length }
        @choice_index = 0
        set_choice_cursor if choice
      end

      def set_choice_cursor
        return unless @message
        @message[:window].cursor_rect =
          Rect.new(0, @choice_index * MSG_LINE_H, @message[:window].inner_width, MSG_LINE_H)
      end

      def drive_message
        @message[:window].update
        if @message[:choice]
          if Input.trigger?(Input::DOWN) && @choice_index < @message[:count] - 1
            @choice_index += 1
            set_choice_cursor
          elsif Input.trigger?(Input::UP) && @choice_index > 0
            @choice_index -= 1
            set_choice_cursor
          elsif Input.trigger?(Input::C)
            index = @choice_index
            close_message
            @interpreter.choose(index)
            drive_after_message
          end
        elsif Input.trigger?(Input::C) || Input.trigger?(Input::B)
          close_message
          @interpreter.resume
          drive_after_message
        end
      end

      # After a message closes and the interpreter advances, immediately pump the
      # next request (another message, a wait, or completion) so a run of text
      # boxes flows without a blank frame between them.
      def drive_after_message
        return if @message
        if @interpreter.running? || @interpreter.waiting?
          drive_interpreter
        else
          finish_event
        end
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end

      # -- number input (Input Number command) --------------------------------

      # Open a digit-entry window for the Input Number (103) command. A compact
      # centred panel shows `digits` boxes with a cursor the player edits.
      def open_number_input(digits)
        return if @number_input
        model = Game::NumberInput.new(digits || 1)
        cell = 28
        w = model.digits * cell + Panel::BORDER * 2 + 8
        h = MSG_LINE_H + Panel::BORDER * 2
        win = Panel.new((SCREEN_W - w) / 2, SCREEN_H - h - 80, w, h, load_windowskin)
        win.z = 320
        contents = Bitmap.new(win.inner_width, win.inner_height)
        @number_input = { window: win, contents: contents, model: model, cell: cell }
        draw_number_input
      end

      def draw_number_input
        ni = @number_input
        return unless ni
        model = ni[:model]
        c = ni[:contents]
        c.clear
        c.font.color = Color.new(255, 255, 255, 255)
        cell = ni[:cell]
        (0...model.digits).each do |i|
          x = 4 + i * cell
          if i == model.cursor
            c.fill_rect x, 2, cell - 4, MSG_LINE_H - 2, Color.new(40, 72, 200, 160)
          end
          c.draw_text x, 2, cell - 4, MSG_LINE_H - 4, model.digit(i).to_s, 1
        end
        ni[:window].contents = c
      end

      def drive_number_input
        ni = @number_input
        model = ni[:model]
        if Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          model.inc
          draw_number_input
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          model.dec
          draw_number_input
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          model.left
          draw_number_input
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          model.right
          draw_number_input
        elsif Input.trigger?(Input::C)
          value = model.value
          close_number_input
          @interpreter.resume_number(value)
          drive_after_message
        end
      end

      def close_number_input
        return unless @number_input
        @number_input[:window].dispose
        @number_input = nil
      end

      def list_nonempty?(list)
        list && list.any? { |c| c.code != 0 }
      end

      def setup_sprites
        # RMXP's Spriteset_Map puts the ground, the characters and the weather
        # into one screen-sized viewport (its @viewport1) and leaves the windows
        # outside it -- which is exactly what makes Change Screen Color Tone
        # (223) tint the map and not the message box. Ours is built the same
        # way, so the tone has one place to live. Panels sit at z 100, above
        # this.
        @screen_viewport = Viewport.new(0, 0, SCREEN_W, SCREEN_H)
        @screen_viewport.z = 0
        setup_tilemap

        @player_sprite = Sprite.new(@screen_viewport)
        # z is set per frame from the screen row the leader stands on, so
        # characters overlap in the right order (see character_z).
        pw = @charset ? Game::CharSet.cell_width(@charset) : TILE
        ph = @charset ? Game::CharSet.cell_height(@charset) : TILE
        @player_bmp = Bitmap.new(pw, ph)
        @player_sprite.bitmap = @player_bmp
        unless @charset
          @player_bmp.fill_rect 4, 0, TILE - 8, ph, Color.new(240, 240, 80, 255)
        end

        setup_event_sprites
      end

      # The map ground: an RGSS::Tilemap fed the tileset graphic, the seven
      # autotiles and the map's own data/priority Tables, which is exactly what
      # RMXP's Spriteset_Map builds. The renderer is native (mruby-rgss): it
      # blits regular tiles from the tileset, assembles autotiles from their four
      # quads, animates them, and routes priority tiles to a layer above the
      # characters. Until now this scene painted a colour block per tile id --
      # navigable, but nothing like the real map (the wine comparison in
      # docs/adr/0025-rpgxp-cross-runtime-testing.md measured every map pixel as
      # differing from the genuine runtime because of it).
      #
      # A missing tileset graphic must not take the map down: the Tilemap simply
      # draws nothing, and the scene stays walkable.
      def setup_tilemap
        @tilemap = Tilemap.new(@screen_viewport)
        @tilemap.map_data = @map.data
        ts = @db.tilesets[@map.tileset_id]
        unless ts
          $stderr.puts "[RGSS] map #{@state.map_id} has no tileset " \
                       "##{@map.tileset_id}; drawing no ground"
          return
        end
        @tilemap.priorities = ts.priorities
        @tilemap.tileset = load_map_graphic("Tilesets", ts.tileset_name)
        (ts.autotile_names || []).each_with_index do |name, i|
          break if i >= 7 # RGSS has exactly seven autotile slots
          bmp = load_map_graphic("Autotiles", name)
          @tilemap.autotiles[i] = bmp if bmp
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] tilemap setup failed, map draws empty: #{e.message}"
      end

      # One Graphics/<dir>/<name> bitmap, or nil when the name is blank or the
      # file is missing. Reported rather than swallowed, as the rest of the
      # runtime does: a missing tile graphic is why a map would render bare.
      def load_map_graphic(dir, name)
        return nil if name.nil? || name.empty?
        Bitmap.new "Graphics/#{dir}/#{name}"
      rescue StandardError => e
        $stderr.puts "[RGSS] #{dir}/#{name} load failed: #{e.message}"
        nil
      end

      # Event sprites. RMXP draws an event from its active page's graphic: a
      # Graphics/Characters sheet (four directions x four patterns), or the tile
      # itself when the page picked a tile id instead. An event whose graphic is
      # empty draws *nothing* -- which is why the red marker this scene used to
      # paint into the ground layer is gone: it marked every invisible event, on
      # pixels the genuine runtime leaves as plain map.
      def setup_event_sprites
        @event_sprites = {}
        refresh_event_sprites
      end

      # Rebuild the sprites from the current pages. Page re-selection can swap an
      # event's graphic (or remove it), so this runs whenever the event list is
      # rebuilt, not only on entry.
      def refresh_event_sprites
        return unless @event_sprites
        @event_sprites.each_value { |s| s[:sprite].dispose }
        @event_sprites = {}
        @events.each do |id, e|
          s = build_event_sprite(e)
          @event_sprites[id] = s if s
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] event sprite setup failed: #{e.message}"
        @event_sprites ||= {}
      end

      def build_event_sprite(entry)
        page = entry[:page]
        g = page && page.graphic
        return nil unless g
        name = g.character_name
        if name && !name.empty?
          charset = load_map_graphic("Characters", name)
          return nil unless charset
          # RMXP caches character graphics per (name, hue); each event sprite
          # owns its bitmap here, so rotate that copy in place.
          hue_shift charset, g.character_hue
          w = Game::CharSet.cell_width(charset)
          h = Game::CharSet.cell_height(charset)
          new_event_sprite(Bitmap.new(w, h), charset, w, h)
        elsif g.tile_id && g.tile_id >= TILE_ID_BASE
          bmp = tile_graphic(g.tile_id)
          bmp && new_event_sprite(bmp, nil, TILE, TILE)
        end
      end

      def new_event_sprite(bitmap, charset, w, h)
        sprite = Sprite.new(@screen_viewport)
        sprite.bitmap = bitmap
        { sprite: sprite, bitmap: bitmap, charset: charset, w: w, h: h,
          frame: nil, opacity: nil, blend_type: nil }
      end

      # Rotate a character graphic's hue in place, as RPG::Cache.character does
      # for a page (or an actor) that asked for a hue. A zero hue is a no-op,
      # and a runtime without the operation must not cost us the sprite.
      def hue_shift(bitmap, hue)
        hue = hue.to_i
        return if bitmap.nil? || hue % 360 == 0
        bitmap.hue_change hue
      rescue StandardError => e
        $stderr.puts "[RGSS] hue #{hue} not applied: #{e.message}"
      end

      # Character stacking, as RMXP's Sprite_Character#update does it: a
      # character's z follows the screen y of the tile it stands on, so whoever
      # is further down the screen draws in front. An "always on top" event
      # (RMXP's `always_on_top` page flag) jumps above the tilemap's priority
      # layer instead. Everything stays under the fog/weather planes.
      ALWAYS_ON_TOP_Z = 950

      def character_z(screen_y, always_on_top)
        return ALWAYS_ON_TOP_Z if always_on_top
        # Feet-line y, clamped under the priority layer so a character near the
        # bottom edge cannot outrank it.
        z = screen_y + TILE
        z < 0 ? 0 : (z > 890 ? 890 : z)
      end

      # A single map tile cut out of the tileset graphic, for an event whose page
      # uses a tile id as its graphic (doors, chests laid into the map). Tile ids
      # from TILE_ID_BASE up index the tileset in reading order.
      def tile_graphic(tile_id)
        ts = @tilemap && @tilemap.tileset
        return nil unless ts
        cols = ts.width / TILE
        cols = 1 if cols < 1
        idx = tile_id - TILE_ID_BASE
        bmp = Bitmap.new(TILE, TILE)
        bmp.blt 0, 0, ts, Rect.new((idx % cols) * TILE, (idx / cols) * TILE,
                                   TILE, TILE)
        bmp
      rescue StandardError => e
        $stderr.puts "[RGSS] event tile graphic #{tile_id} failed: #{e.message}"
        nil
      end

      def step_movement
        if @moving
          @move_count += SPEED
          if @move_count >= TILE
            @state.x = @dest_x
            @state.y = @dest_y
            @moving = false
            @move_count = 0
          else
            return # still crossing the tile: nothing new starts
          end
        end

        return if @player_route # a forced route controls the player
        dir = Input.dir4
        return if dir == 0

        @state.direction = dir
        nx, ny = target_tile(@state.x, @state.y, dir)

        # Walking into a player-touch (trigger 1) event runs it instead of moving.
        e = @event_tiles[[nx, ny]]
        if e && e[:trigger] == TRIGGER_PLAYER_TOUCH && list_nonempty?(page_list(e))
          @running_event_id = e[:id]
          @interpreter.start(page_list(e), @state.map_id, e[:id])
          drive_interpreter
          return
        end

        return unless passable?(nx, ny, dir)

        @dest_x = nx
        @dest_y = ny
        @moving = true
        @move_count = 0
      end

      def target_tile(x, y, dir)
        case dir
        when 2 then [x, y + 1]
        when 4 then [x - 1, y]
        when 6 then [x + 1, y]
        when 8 then [x, y - 1]
        else [x, y]
        end
      end

      def passable?(x, y, dir)
        return false unless in_bounds?(x, y)
        return false if @event_tiles[[x, y]]
        @tileset.passable?(@map, x, y, dir)
      end

      def in_bounds?(x, y)
        x >= 0 && y >= 0 && x < @map.width && y < @map.height
      end

      def player_pixel
        if @moving
          [@state.x * TILE + (@dest_x - @state.x) * @move_count,
           @state.y * TILE + (@dest_y - @state.y) * @move_count]
        else
          [@state.x * TILE, @state.y * TILE]
        end
      end

      def render
        px, py = player_pixel
        @scroll.update
        cam_x = camera_axis(px + TILE / 2, SCREEN_W, @map.width * TILE, @scroll.x)
        cam_y = camera_axis(py + TILE / 2, SCREEN_H, @map.height * TILE, @scroll.y)

        scroll_tilemap cam_x, cam_y
        draw_event_sprites cam_x, cam_y

        pw = @player_bmp.width
        ph = @player_bmp.height
        sy = py - cam_y
        @player_sprite.x = px - cam_x - (pw - TILE) / 2
        @player_sprite.y = sy - (ph - TILE)
        @player_sprite.z = character_z(sy, false)
        # Change Transparent Flag (208) simply stops the leader being drawn.
        @player_sprite.visible = !@state.player_transparent
        draw_player_frame
        # Animations anchor on the sprites just positioned, so they come last.
        update_animations
      end

      # The follow camera plus any Scroll Map offset, clamped to the map — RMXP
      # clamps `display_x`/`display_y` the same way, so a scroll can never show
      # past the edge.
      def camera_axis(focus, screen, world, offset)
        cam = Game.camera_offset(focus, screen, world) + offset
        return 0 if world <= screen
        return 0 if cam < 0
        max = world - screen
        cam > max ? max : cam
      end

      # Scroll the ground to the camera and let it animate. Each ox/oy write
      # re-tiles the whole visible area natively, so only write them when the
      # camera actually moved; #update then costs nothing on a map with no
      # animated autotile.
      def scroll_tilemap(cam_x, cam_y)
        return unless @tilemap
        if cam_x != @cam_x || cam_y != @cam_y
          @cam_x = cam_x
          @cam_y = cam_y
          @tilemap.ox = cam_x
          @tilemap.oy = cam_y
        end
        @tilemap.update
      end

      def draw_event_sprites(cam_x, cam_y)
        return unless @event_sprites
        @event_sprites.each do |id, s|
          e = @events[id]
          # Erased, or its page went away between rebuilds: keep the sprite (the
          # page may come back) but stop drawing it.
          if e.nil? || e[:page].nil?
            s[:sprite].visible = false
            next
          end
          ch = e[:char]
          s[:sprite].visible = true
          # Character sheets are wider/taller than a tile: RMXP centres them on
          # the tile and stands them on its bottom edge, as the player is drawn.
          sy = ch.pixel_y(TILE) - cam_y
          s[:sprite].x = ch.pixel_x(TILE) - cam_x - (s[:w] - TILE) / 2
          s[:sprite].y = sy - (s[:h] - TILE)
          s[:sprite].z = character_z(sy, ch.always_on_top)
          # Page graphic (or move-route) opacity and blending. Written only when
          # they change: each one reaches into the native sprite.
          if s[:opacity] != ch.opacity
            s[:opacity] = ch.opacity
            s[:sprite].opacity = ch.opacity
          end
          if s[:blend_type] != ch.blend_type
            s[:blend_type] = ch.blend_type
            s[:sprite].blend_type = ch.blend_type
          end
          next unless s[:charset]
          frame = [ch.direction, ch.pattern]
          next if frame == s[:frame]
          s[:frame] = frame
          rect = Game::CharSet.frame_rect(s[:charset], ch.direction, ch.pattern)
          s[:bitmap].clear
          s[:bitmap].blt 0, 0, s[:charset], rect
        end
      end

      # The player walks at SPEED pixels a frame, which is RMXP's move speed 4
      # (2 ** 4 of the 128 units it counts a tile in), and its walk cycle runs
      # off the same animation counter every other character uses: 1.5 ticks a
      # frame, a new frame every 18 - move_speed * 2 ticks, back to the standing
      # frame once it has stopped. Keying the frame off the distance walked
      # instead -- (@move_count / 8) % 4 -- cycled all four frames within a
      # single tile, about three times the real runtime's rate.
      PLAYER_MOVE_SPEED = 4
      PLAYER_ANIME_TICKS = 18 - PLAYER_MOVE_SPEED * 2

      def animate_player
        @player_anime += 1.5 if @moving || @player_pattern != 0
        return if @player_anime <= PLAYER_ANIME_TICKS
        @player_anime = 0
        @player_pattern = @moving ? (@player_pattern + 1) % 4 : 0
      end

      def draw_player_frame
        return unless @charset
        pat = Game::CharSet::PATTERNS[@player_pattern]
        frame = [@state.direction, pat]
        return if frame == @last_frame
        @last_frame = frame
        rect = Game::CharSet.frame_rect(@charset, @state.direction, pat)
        @player_bmp.clear
        @player_bmp.blt 0, 0, @charset, rect
      end

    end
  end
end
