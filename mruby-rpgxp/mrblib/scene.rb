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
                            Rect.new(0, 0, 128, 128)
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

    def draw_cursor
      @cursor_bmp.clear
      return unless @active && @cursor_rect
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0
      x = BORDER + r.x
      y = BORDER + r.y
      @cursor_bmp.fill_rect x, y, r.width, r.height, Color.new(40, 72, 200, 160)
      border = Color.new(200, 216, 255, 255)
      @cursor_bmp.fill_rect x, y, r.width, 2, border
      @cursor_bmp.fill_rect x, y + r.height - 2, r.width, 2, border
      @cursor_bmp.fill_rect x, y, 2, r.height, border
      @cursor_bmp.fill_rect x + r.width - 2, y, 2, r.height, border
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

    # First walkable map slice: renders the three tile layers as placeholder
    # colour blocks (real chipset/autotile blitting is future work), draws the
    # party leader from its Character graphic and moves it on the grid with pixel
    # interpolation, tileset collision and an edge-clamped follow camera. Map
    # events are drawn as markers for now; running their command lists is the
    # next milestone.
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
      MSG_LINE_H = 32

      # Frames between autonomous event steps, keyed by RMXP move frequency
      # (1 slowest .. 6 fastest). Placeholder pacing while events draw as markers.
      EVENT_MOVE_DELAY = { 1 => 120, 2 => 60, 3 => 30, 4 => 15, 5 => 8, 6 => 4 }.freeze

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
        @tile_colors = {}

        @moving = false
        @move_count = 0
        @dest_x = @state.x
        @dest_y = @state.y
        @last_frame = nil

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
        @player_route_timer = 0
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
        [@lower_sprite, @upper_sprite, @player_sprite].each { |s| s.dispose if s }
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
        Bitmap.new "Graphics/Characters/#{name}"
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
          g = page.graphic
          ch.set_graphic(g.character_name, g.character_hue, g.direction, g.pattern) if g
          move_type = page.move_type || 0
          route = Game::MoveRoute.from_page(page.move_route) if move_type == Game::MoveType::CUSTOM
        end
        { id: id, ev: ev, page: page, char: ch, trigger: page && page.trigger,
          move_type: move_type, route: route,
          move_timer: EVENT_MOVE_DELAY[ch.move_frequency] || 30 }
      rescue StandardError => e
        $stderr.puts "[RGSS] event ##{id} setup failed: #{e.message}"
        { id: id, ev: ev, page: nil, char: (@characters[id] ||= Game::Character.new(ev.x, ev.y)),
          trigger: nil, move_type: 0, route: nil, move_timer: 30 }
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

      # Advance each event's autonomous / custom-route movement one frame, paced
      # by move frequency. Skipped once any event process is running this frame,
      # so the map holds still during messages.
      def step_events
        @events.each { |_id, e| step_event(e) }
      end

      def step_event(e)
        return if event_busy?
        ch = e[:char]
        return unless ch
        # A forced route (Set Move Route) overrides page movement until it is done.
        forced = @forced_routes[e[:id]]
        return step_forced_event(e, ch, forced) if forced
        return unless e[:page]
        e[:move_timer] -= 1
        return if e[:move_timer] > 0
        e[:move_timer] = EVENT_MOVE_DELAY[ch.move_frequency] || 30
        ox = ch.x
        oy = ch.y
        if e[:route]
          e[:route].step(ch, @world) unless e[:route].done?
        else
          dir = Game::MoveType.next_direction(e[:move_type], ch, @world)
          move_autonomous(e, dir) if dir
        end
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy
      rescue StandardError => ex
        $stderr.puts "[RGSS] event ##{e[:id]} movement failed: #{ex.message}"
      end

      # Advance an event's forced route one paced step, updating its occupied
      # tile, and drop the route once a non-repeating one is exhausted.
      def step_forced_event(e, ch, forced)
        forced[:timer] -= 1
        return if forced[:timer] > 0
        forced[:timer] = EVENT_MOVE_DELAY[ch.move_frequency] || 30
        ox = ch.x
        oy = ch.y
        forced[:route].step(ch, @world) unless forced[:route].done?
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
        @player_route_timer = 0
      end

      def step_player_route
        return unless @player_route
        @player_route_timer -= 1
        return if @player_route_timer > 0
        @player_route_timer = EVENT_MOVE_DELAY[@player_char.move_frequency] || 30
        @player_route.step(@player_char, @world) unless @player_route.done?
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
          start_event(e) if e[:trigger] == TRIGGER_EVENT_TOUCH && list_nonempty?(page_list(e))
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
        @lower_sprite = Sprite.new
        @lower_sprite.z = 0
        @lower_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @lower_sprite.bitmap = @lower_bmp

        @upper_sprite = Sprite.new
        @upper_sprite.z = 200
        @upper_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @upper_sprite.bitmap = @upper_bmp

        @player_sprite = Sprite.new
        @player_sprite.z = 100
        pw = @charset ? Game::CharSet.cell_width(@charset) : TILE
        ph = @charset ? Game::CharSet.cell_height(@charset) : TILE
        @player_bmp = Bitmap.new(pw, ph)
        @player_sprite.bitmap = @player_bmp
        unless @charset
          @player_bmp.fill_rect 4, 0, TILE - 8, ph, Color.new(240, 240, 80, 255)
        end
      end

      def step_movement
        if @moving
          @move_count += SPEED
          if @move_count >= TILE
            @state.x = @dest_x
            @state.y = @dest_y
            @moving = false
            @move_count = 0
          end
          return
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

        draw_layers cam_x, cam_y

        pw = @player_bmp.width
        ph = @player_bmp.height
        @player_sprite.x = px - cam_x - (pw - TILE) / 2
        @player_sprite.y = py - cam_y - (ph - TILE)
        draw_player_frame
      end

      def draw_layers(cam_x, cam_y)
        @lower_bmp.clear
        @upper_bmp.clear
        first_tx = cam_x / TILE
        first_ty = cam_y / TILE
        ox = cam_x % TILE
        oy = cam_y % TILE

        (0...ROWS).each do |ry|
          (0...COLS).each do |rx|
            tx = first_tx + rx
            ty = first_ty + ry
            next unless in_bounds?(tx, ty)
            dx = rx * TILE - ox
            dy = ry * TILE - oy

            # Layers 0/1 to the lower sprite, layer 2 to the upper (drawn above
            # the player), matching RMXP's three-layer stack.
            b0 = @map.data[tx, ty, 0]
            b1 = @map.data[tx, ty, 1]
            @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(b0)
            @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(b1) if b1 && b1 != 0

            top = @map.data[tx, ty, 2]
            @upper_bmp.fill_rect dx, dy, TILE, TILE, tile_color(top) if top && top != 0

            if @event_tiles[[tx, ty]]
              @lower_bmp.fill_rect dx + 4, dy + 4, TILE - 8, TILE - 8,
                                   Color.new(230, 90, 90, 255)
            end
          end
        end
      end

      def draw_player_frame
        return unless @charset
        pat = @moving ? Game::CharSet::PATTERNS[(@move_count / 8) % 4] : 0
        frame = [@state.direction, pat]
        return if frame == @last_frame
        @last_frame = frame
        rect = Game::CharSet.frame_rect(@charset, @state.direction, pat)
        @player_bmp.clear
        @player_bmp.blt 0, 0, @charset, rect
      end

      # Deterministic placeholder colour per tile id (empty tiles are a dark
      # void), the same navigable stand-in the RPG2000 map scene uses.
      def tile_color(id)
        return (@void ||= Color.new(16, 16, 28, 255)) if id.nil? || id == 0
        @tile_colors[id] ||= Color.new(40 + (id * 37) % 180,
                                       40 + (id * 71) % 180,
                                       60 + (id * 143) % 160, 255)
      end
    end
  end
end
