# RPG Maker XP scenes: the title screen and the first walkable map scene, plus a
# small XP-styled window helper. The title reproduces the default RMXP flow
# (title graphic + New Game / Continue / Shutdown) directly against the database;
# the map scene renders the three tile layers as placeholder colour blocks (real
# tileset/autotile blitting is future work, mirroring the RPG2000 side) and lets
# the party leader walk with tileset collision and a follow camera.

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

    def dispose
      [@skin_sprite, @cursor_sprite, @contents_sprite].each { |s| s.dispose if s }
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
        [@tilemap, @player_sprite].each { |s| s.dispose if s }
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
          end
        else
          @interpreter.update
          apply_move_requests(@interpreter)
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
          apply_erase_request(it, p[:id])
        else
          it.start(p[:list], @state.map_id, p[:id]) # loop the process
          it.update
          apply_move_requests(it)
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
        h = lines.length * MSG_LINE_H + Panel::BORDER * 2
        win = Panel.new(0, SCREEN_H - h - 8, SCREEN_W, h, load_windowskin)
        win.z = 300
        contents = Bitmap.new(win.inner_width, win.inner_height)
        contents.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          contents.draw_text 8, i * MSG_LINE_H + 2, contents.width - 16, MSG_LINE_H, line
        end
        win.contents = contents
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
        setup_tilemap

        @player_sprite = Sprite.new
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
        @tilemap = Tilemap.new
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
        sprite = Sprite.new
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
        cam_x = Game.camera_offset(px + TILE / 2, SCREEN_W, @map.width * TILE)
        cam_y = Game.camera_offset(py + TILE / 2, SCREEN_H, @map.height * TILE)

        scroll_tilemap cam_x, cam_y
        draw_event_sprites cam_x, cam_y

        pw = @player_bmp.width
        ph = @player_bmp.height
        sy = py - cam_y
        @player_sprite.x = px - cam_x - (pw - TILE) / 2
        @player_sprite.y = sy - (ph - TILE)
        @player_sprite.z = character_z(sy, false)
        draw_player_frame
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
