class Object
  include RGSS
end

module RGSS
  # RPG Maker 2000 style window. The visual is assembled from a "windowskin"
  # System graphic laid out in the classic 160x80 arrangement:
  #
  #   (0, 0, 32, 32)   background fill (stretched over the interior)
  #   (32, 0, 32, 32)  8px-thick frame border, split into 4 corners and 4 edges
  #
  # The window is a Viewport that clips its contents to the window rectangle.
  # Rather than compositing everything into one Bitmap, three separate Sprites
  # are layered inside the viewport by their `z`: the windowskin (background +
  # frame), the selection cursor, and the contents (text and other graphics
  # drawn by callers). Keeping them apart means updating the cursor or the text
  # no longer forces the skin to be re-blitted.
  class Window
    # Windows are drawn above ordinary background sprites (which default to
    # z == 0), so give the backing viewport a high z by default.
    DEFAULT_Z = 100

    # Thickness of the RPG2k frame border, in pixels.
    BORDER = 8

    # z of each layer within the window's viewport (skin at the back, text on
    # top, cursor highlight sandwiched between them).
    SKIN_Z = 0
    CURSOR_Z = 1
    CONTENTS_Z = 2

    def initialize(x = 0, y = 0, width = 0, height = 0)
      @x = x
      @y = y
      @width = width
      @height = height
      @contents = nil
      @windowskin = nil
      @cursor_rect = Rect.new(0, 0, 0, 0)
      @active = true
      @visible = true

      # The viewport groups and clips the three layers to the window rect.
      @viewport = Viewport.new(x, y, [width, 1].max, [height, 1].max)
      @viewport.z = DEFAULT_Z

      @skin_sprite = Sprite.new(@viewport)
      @skin_sprite.z = SKIN_Z
      @cursor_sprite = Sprite.new(@viewport)
      @cursor_sprite.z = CURSOR_Z
      # Contents are drawn inside the frame, so offset the sprite by the border.
      @contents_sprite = Sprite.new(@viewport)
      @contents_sprite.z = CONTENTS_Z
      @contents_sprite.x = BORDER
      @contents_sprite.y = BORDER
      @contents_sprite.visible = false

      allocate_skin
    end

    attr_reader :x, :y, :width, :height, :contents, :windowskin, :cursor_rect
    attr_reader :active, :visible

    def x=(v)
      @x = v
      update_rect
    end

    def y=(v)
      @y = v
      update_rect
    end

    def z=(v)
      @viewport.z = v
    end

    def width=(v)
      @width = v
      allocate_skin
      update_rect
    end

    def height=(v)
      @height = v
      allocate_skin
      update_rect
    end

    def windowskin=(bmp)
      @windowskin = bmp
      draw_skin
      bmp
    end

    # Draw the window with no frame or background (RPG2000's transparent message
    # window): only the contents layer shows. Setting it redraws the skin layer.
    def transparent=(v)
      @transparent = v ? true : false
      draw_skin
      v
    end

    def contents=(bmp)
      @contents = bmp
      @contents_sprite.visible = !bmp.nil?
      @contents_sprite.bitmap = bmp if bmp
      bmp
    end

    def cursor_rect=(rect)
      @cursor_rect = rect
      draw_cursor
      rect
    end

    def active=(v)
      @active = v
      draw_cursor
    end

    def visible=(v)
      @visible = v
      @viewport.visible = v
    end

    # Present so the game loop can drive per-frame behaviour (cursor blinking,
    # etc.). The cursor is drawn steadily for now, so this is a no-op.
    def update; end

    def dispose
      # Dispose the layers before the viewport so each Sprite tears its own
      # LVGL object down; disposing the viewport then only frees the frame.
      [@skin_sprite, @cursor_sprite, @contents_sprite].each(&:dispose)
      @viewport.dispose
    end

    private

    # Move/resize the viewport to track the window rectangle.
    def update_rect
      @viewport.rect = Rect.new(@x, @y, [@width, 1].max, [@height, 1].max)
    end

    # (Re)create the skin and cursor bitmaps whenever the window is resized,
    # then redraw both layers.
    def allocate_skin
      @skin_bmp = Bitmap.new([@width, 1].max, [@height, 1].max)
      @skin_sprite.bitmap = @skin_bmp
      @cursor_bmp = Bitmap.new([@width, 1].max, [@height, 1].max)
      @cursor_sprite.bitmap = @cursor_bmp
      draw_skin
      draw_cursor
    end

    # Redraw the windowskin layer (background + frame, or the fallback panel).
    def draw_skin
      @skin_bmp.clear
      return if @transparent # transparent message window: no frame/background
      if @windowskin
        draw_background
        draw_frame
      else
        draw_fallback
      end
    end

    # Stretch the 32x32 background tile over the whole window; the frame border
    # is drawn on top of its outer edge afterwards.
    def draw_background
      @skin_bmp.stretch_blt Rect.new(0, 0, @width, @height), @windowskin,
                            Rect.new(0, 0, 32, 32)
    end

    def draw_frame
      w = @width
      h = @height
      b = BORDER
      sk = @windowskin

      # Corners (8x8, drawn 1:1).
      @skin_bmp.blt 0, 0, sk, Rect.new(32, 0, b, b)
      @skin_bmp.blt w - b, 0, sk, Rect.new(56, 0, b, b)
      @skin_bmp.blt 0, h - b, sk, Rect.new(32, 24, b, b)
      @skin_bmp.blt w - b, h - b, sk, Rect.new(56, 24, b, b)

      # Edges (stretched along the free axis).
      @skin_bmp.stretch_blt Rect.new(b, 0, w - 2 * b, b), sk,
                            Rect.new(40, 0, 16, b)
      @skin_bmp.stretch_blt Rect.new(b, h - b, w - 2 * b, b), sk,
                            Rect.new(40, 24, 16, b)
      @skin_bmp.stretch_blt Rect.new(0, b, b, h - 2 * b), sk,
                            Rect.new(32, 8, b, 16)
      @skin_bmp.stretch_blt Rect.new(w - b, b, b, h - 2 * b), sk,
                            Rect.new(56, 8, b, 16)
    end

    # Used when no windowskin could be loaded: a plain dark panel with a light
    # border so the window is still visible.
    def draw_fallback
      @skin_bmp.fill_rect 0, 0, @width, @height, Color.new(8, 8, 40, 224)
      edge = Color.new(200, 200, 216, 255)
      @skin_bmp.fill_rect 0, 0, @width, 1, edge
      @skin_bmp.fill_rect 0, @height - 1, @width, 1, edge
      @skin_bmp.fill_rect 0, 0, 1, @height, edge
      @skin_bmp.fill_rect @width - 1, 0, 1, @height, edge
    end

    # Highlight box behind the selected item, on its own layer. cursor_rect is
    # expressed in contents coordinates, so it is offset by the border
    # thickness (the contents layer carries the same offset).
    def draw_cursor
      @cursor_bmp.clear
      return unless @active
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0

      # fill_rect overwrites (it does not alpha-blend onto the window
      # background), so use an opaque highlight: a solid blue bar with a
      # brighter border, matching the reference title screen's selection box.
      x = BORDER + r.x
      y = BORDER + r.y
      @cursor_bmp.fill_rect x, y, r.width, r.height, Color.new(24, 40, 176, 255)
      border = Color.new(180, 200, 255, 255)
      @cursor_bmp.fill_rect x, y, r.width, 1, border
      @cursor_bmp.fill_rect x, y + r.height - 1, r.width, 1, border
      @cursor_bmp.fill_rect x, y, 1, r.height, border
      @cursor_bmp.fill_rect x + r.width - 1, y, 1, r.height, border
    end
  end
end

class RPG2k
  WIDTH = 320
  HEIGHT = 240

  module Scene
    class Base
      def initialize parent
        @parent = parent
        @db = parent.db
        @map_tree = parent.map_tree
      end
      def update ; end
      def dispose ; end

      attr_reader :parent, :db, :map_tree

      # Load the System/ windowskin declared in the database (nil when missing,
      # so Window falls back to a plain panel).
      def make_windowskin
        name = @db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}"
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end
    end

    # Adapter that exposes the running map to the movement engine
    # (Game::MoveRoute / Game::MoveType). It bridges their small `world` protocol
    # — passability, hero position, switch and sound side effects, randomness —
    # onto the owning Scene::Map and its Game::State.
    class MapWorld
      def initialize(scene, rng)
        @scene = scene
        @rng = rng
      end

      def passable?(character, dir)
        @scene.char_passable?(character, dir)
      end

      def hero_position
        s = @scene.state
        [s.x, s.y]
      end

      def set_switch(id, on)
        @scene.state.switches[id] = on
      end

      def play_sound(name, volume, tempo, _balance)
        return if name.nil? || name.empty?
        RGSS::Audio.se_play(name, volume, tempo)
      rescue StandardError => e
        $stderr.puts "[RPG2k] event SE '#{name}' playback failed: #{e.message}"
        nil
      end

      def random(n)
        @rng.random(n)
      end
    end

    # Resolves the command list a Call Event refers to. Common events are looked
    # up by id; a map event's page is fetched from the loaded map unit (best
    # effort — the page index follows the LCF page numbering).
    class EventResolver
      def initialize(common_by_id, map_events)
        @common = common_by_id || {}
        @map_events = map_events || {}
      end

      def common_event_commands(id)
        @common[id]
      end

      def map_event_commands(id, page_index)
        ev = @map_events[id]
        return nil unless ev
        pages = ev.pages
        return nil unless pages
        page = pages[page_index]
        page && page.event_commands
      rescue StandardError
        nil
      end
    end

    # Play scene: renders the loaded map and lets the party leader walk around
    # it. Tiles are blitted from the map's real ChipSet graphic via
    # Game::ChipsetLayout (lower/upper chips, water/terrain autotile assembly and
    # tile animation); if the chipset image is missing they fall back to solid
    # colour blocks derived from the tile id. The player is drawn from its real
    # CharSet graphic. Movement is grid based with
    # smooth pixel interpolation, walk animation, tile/edge/event collision and
    # a camera that follows the player and clamps to the map edges. Events roam
    # the map per their page's movement type (random / vertical / horizontal /
    # toward or away from the hero) or run a custom move route.
    class Map < Base
      TILE = Game::TILE
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      # Visible tiles plus a one-tile margin so partially scrolled edges show.
      COLS = SCREEN_W / TILE + 1
      ROWS = SCREEN_H / TILE + 1
      # Pixels moved per frame while stepping between tiles (must divide TILE).
      SPEED = 2

      # Frames waited between autonomous event steps, keyed by RPG2000 move
      # frequency (1 slowest .. 8 fastest). Placeholder pacing while events are
      # drawn as markers (no per-step pixel interpolation yet).
      EVENT_MOVE_DELAY = { 1 => 96, 2 => 64, 3 => 40, 4 => 24,
                           5 => 12, 6 => 6, 7 => 3, 8 => 1 }.freeze

      # Rendered frames between walk-animation phase advances for an animating
      # event (a moving event or a continuous/spin animation type).
      ANIM_FRAME_PERIOD = 6

      # Event-page start conditions (the page `trigger` field): how the event's
      # command list is set off.
      TRIGGER_ACTION       = 0 # player presses the action button facing it
      TRIGGER_PLAYER_TOUCH = 1 # player walks into it
      TRIGGER_EVENT_TOUCH  = 2 # it walks into the player
      TRIGGER_AUTO_START   = 3 # runs automatically once on the map
      TRIGGER_PARALLEL     = 4 # runs continuously in the background

      # Move Event (Set Move Route) target ids: the player, the three vehicles
      # and "this event" (the event running the command). Any other id is a map
      # event id. Vehicles are not modelled yet, so those targets are ignored.
      MOVE_TARGET_PLAYER  = 10001
      MOVE_TARGET_BOAT    = 10002
      MOVE_TARGET_SHIP    = 10003
      MOVE_TARGET_AIRSHIP = 10004
      MOVE_TARGET_THIS    = 10005

      def initialize parent, state
        super parent
        @state = state
        @map = state.map
        @chipset = build_chipset
        @chipset_bmp = load_chipset_graphic
        @charset = load_charset
        @windowskin = load_windowskin
        @interpreter = Game::Interpreter.new(@state)
        @started_auto = {}
        @started_common = {}
        @common = Game::CommonEvent.load(@db)
        # Deterministic RNG (mruby has no Kernel#rand here) and the adapter that
        # lets move routes / autonomous movement query the map.
        @rng = Game::Rng.new(0x2000)
        @world = MapWorld.new(self, @rng)
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        @message = nil
        @inn_window = nil
        @shop = nil
        @wait_timer = nil
        @choice_index = 0
        # The map event whose commands the foreground interpreter is running, so
        # a Move Event targeting "this event" can be resolved. nil for common
        # events (which have no map character).
        @active_event = nil
        # A forced move route applied to the player by a Move Event, with its own
        # character mirror and step timer; nil when the player moves by input.
        @player_route = nil
        @player_char = nil
        @player_route_timer = 0

        # Player pixel position and step state.
        @moving = false
        @move_count = 0
        @dest_x = @state.x
        @dest_y = @state.y
        @tile_colors = {}
        @last_frame = nil
        # Frame counter driving the chipset's water/animated-tile animation.
        @anim_frame = 0

        setup_sprites
        render
      end

      attr_reader :state

      def dispose
        close_message
        close_inn_window
        close_shop
        [@lower_sprite, @upper_sprite, @player_sprite, @parallax_sprite,
         @picture_sprite].each do |s|
          s.dispose if s
        end
        @chipset_bmp.dispose if @chipset_bmp
        @parallax_img.dispose if @parallax_img
      end

      def update
        @state.tick_timer # the timer keeps counting during events too
        @state.screen.update # screen tint progresses every frame, even in events
        @state.update_pictures # picture moves progress every frame too
        @anim_frame += 1 # water / animated tiles cycle even during events
        if event_busy?
          drive_event
        else
          start_autostart
          if event_busy?
            drive_event
          else
            step_parallels
            step_player_route
            step_events
            step_movement
            try_action_trigger
            try_open_menu
          end
        end
        animate_events
        render
      end

      private

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
        @player_bmp = Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
        @player_sprite.bitmap = @player_bmp
        # Fallback marker when the CharSet graphic is unavailable.
        unless @charset
          @player_bmp.fill_rect 4, 0, TILE, Game::CharSet::HEIGHT,
                                Color.new(240, 240, 80, 255)
        end
        # CharSet graphics for events, loaded on demand and cached by name (a
        # cached nil marks a name that failed to load, so we log it once).
        @event_charsets = {}

        setup_parallax
        setup_pictures
      end

      # Create the buffer that carries the Show Picture layer. Pictures composite
      # into one screen-sized sprite above the map and characters (z = 250) but
      # below the message window (z = 300); source images are cached by
      # [name, transparent-colour] as they are shown.
      def setup_pictures
        @picture_sprite = Sprite.new
        @picture_sprite.z = 250
        @picture_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @picture_sprite.bitmap = @picture_bmp
        @picture_srcs = {}
      end

      # Load (and cache) a picture's source image (Picture/<name>). `transparent`
      # loads it with the colour-key so palette index 0 shows through. A cached
      # nil marks a missing file so a broken picture simply draws nothing.
      def picture_src(name, transparent)
        return nil if name.nil? || name.empty?
        key = [name, transparent]
        return @picture_srcs[key] if @picture_srcs.key?(key)
        @picture_srcs[key] =
          begin
            Bitmap.new "Picture/#{name}", transparent
          rescue StandardError => e
            $stderr.puts "[RPG2k] picture '#{name}' load failed, not drawn: #{e.message}"
            nil
          end
      end

      # Load the map's parallax background (Panorama/<name>) and its scroll
      # settings, and create the sprite that carries it behind the tile layers
      # (z = -1, below the lower tiles at z = 0). Skipped — leaving the map's
      # backdrop the plain void — when the map has no parallax or the image is
      # missing.
      def setup_parallax
        u = @map.unit
        return unless (u.parallax_flag rescue false)
        name = (u.parallax_name rescue '').to_s
        return if name.empty?
        @parallax_img = Bitmap.new "Panorama/#{name}"
        @par_loop_x = (u.parallax_loop_x rescue false) ? true : false
        @par_loop_y = (u.parallax_loop_y rescue false) ? true : false
        @par_auto_x = (u.parallax_autoloop_x rescue false) ? true : false
        @par_auto_y = (u.parallax_autoloop_y rescue false) ? true : false
        @par_sx = (u.parallax_sx rescue 0) || 0
        @par_sy = (u.parallax_sy rescue 0) || 0
        @parallax_sprite = Sprite.new
        @parallax_sprite.z = -1
        @parallax_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @parallax_sprite.bitmap = @parallax_bmp
      rescue StandardError => e
        $stderr.puts "[RPG2k] parallax load failed, no backdrop drawn: #{e.message}"
        @parallax_img = nil
      end

      # The CharSet bitmap for an event graphic `name`, cached (including a
      # cached nil for a missing file so the event simply draws nothing rather
      # than a placeholder). Empty names have no graphic.
      def event_charset(name)
        return nil if name.nil? || name.empty?
        return @event_charsets[name] if @event_charsets.key?(name)
        @event_charsets[name] =
          begin
            Bitmap.new "CharSet/#{name}"
          rescue StandardError => e
            $stderr.puts "[RPG2k] event charset '#{name}' load failed, " \
                         "event drawn empty: #{e.message}"
            nil
          end
      end

      def build_chipset
        Game::ChipSet.new(@db, @tileset_id || @map.chipset_id)
      rescue StandardError => e
        $stderr.puts "[RPG2k] chipset load failed, tiles treated as passable: #{e.message}"
        nil
      end

      # Rebuild the chipset model and its tile graphic (after a Change Map Tileset
      # swaps the tileset id), disposing the old graphic bitmap. Passability,
      # terrain and rendering all read the refreshed chipset from here on.
      def rebuild_chipset
        @chipset = build_chipset
        old = @chipset_bmp
        @chipset_bmp = load_chipset_graphic
        old.dispose if old && !old.equal?(@chipset_bmp)
      end

      # Load the chipset tile graphic (ChipSet/<name>). Chipsets are indexed
      # PNGs whose palette index 0 is the transparent colour, so load with the
      # colour-key flag (like the windowskin). Returns nil — falling back to the
      # solid-colour tile blocks — when there is no chipset or the file is
      # missing.
      def load_chipset_graphic
        name = @chipset && @chipset.graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "ChipSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] chipset graphic load failed, using colour blocks: #{e.message}"
        nil
      end

      # Load the leader's CharSet graphic. Returns nil (falling back to a marker)
      # when there is no party or the file is missing.
      def load_charset
        leader = @state.party.leader
        return nil if leader.nil?
        name = leader.charset_name
        @charset_index = leader.charset_index || 0
        return nil if name.nil? || name.empty?
        Bitmap.new "CharSet/#{name}"
      rescue StandardError => e
        $stderr.puts "[RPG2k] party charset load failed, using marker: #{e.message}"
        nil
      end

      # Load the System/ windowskin for message windows (nil -> plain panel).
      def load_windowskin
        name = @db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      # Build the runtime event list for the current map: the active page of
      # each event (per switch/variable/party conditions) becomes a movable
      # Game::Character, tagged with its trigger, command list and how it moves
      # (autonomous move type, or a custom Game::MoveRoute). @event_tiles caches
      # the tiles events occupy, for collision and markers.
      def build_events
        @events = []
        @event_tiles = {}
        evs = @map.unit.events
        return unless evs
        evs.each do |id, ev|
          selected = Game::EventPage.select(ev.pages, @state.switches,
                                            @state.variables, @state.party)
          next unless selected
          page = selected[1]
          @events.push(build_event(id, ev, page))
        end
        rebuild_event_tiles
      rescue StandardError => e
        $stderr.puts "[RPG2k] event setup failed, map runs with no events: #{e.message}"
        @events = []
        @event_tiles = {}
      end

      def build_event(id, ev, page)
        dir = Game::EventGraphic.numpad_direction(page_direction(page))
        ch = Game::Character.new(ev.x, ev.y, dir)
        ch.move_speed = page_move_speed(page)
        ch.move_frequency = page_move_frequency(page)
        ch.set_graphic(page_charset_name(page), page_charset_index(page))
        move_type = page_move_type(page)
        route = move_type == Game::MoveType::CUSTOM ?
                Game::MoveRoute.from_page(page_move_route(page)) : nil
        { id: id, char: ch, trigger: page_trigger(page),
          commands: page_commands(page), move_type: move_type, route: route,
          move_timer: EVENT_MOVE_DELAY[ch.move_frequency] || 40,
          # Rendering state: the page's static graphic fields, a live walk
          # animation phase / counter, a mid-step "moving" flag, and the pixel
          # slide (display origin disp_x/disp_y + move_count 0..TILE) that eases
          # the sprite between tiles. move_count == TILE means "at rest".
          layer: page_layer(page), translucent: page_translucent(page),
          anim_type: page_anim_type(page), base_dir: dir,
          base_pattern: page_pattern(page), anim_phase: 0, anim_count: 0,
          moving: false, disp_x: ev.x, disp_y: ev.y, move_count: TILE }
      end

      # Build the Call Event resolver for the current map: common events keyed by
      # id (they are global) plus this map's raw events for map-event page calls.
      def build_resolver
        common = {}
        @common.each { |c| common[c[:id]] = c[:commands] }
        map_events = (@map.unit.events rescue nil)
        EventResolver.new(common, map_events)
      rescue StandardError
        EventResolver.new({}, nil)
      end

      # Recompute the occupied-tile set from the events' current positions.
      def rebuild_event_tiles
        @event_tiles = {}
        @events.each { |e| @event_tiles[[e[:char].x, e[:char].y]] = e }
      end

      # Read an optional event-page field through a guard that logs (rather than
      # silently swallowing) any access error before falling back to `default`.
      # A malformed page then degrades a single field instead of taking out the
      # whole event list, and the failure still surfaces in the log.
      def page_field(name, default)
        yield
      rescue StandardError => e
        $stderr.puts "[RPG2k] event page field '#{name}' unavailable " \
                     "(#{e.message}), using #{default.inspect}"
        default
      end

      def page_trigger(page); page_field(:trigger, 0) { page.trigger }; end
      def page_commands(page); page_field(:commands, nil) { page.event_commands }; end
      # The page's stored facing (0..3: up/right/down/left), default down (2).
      # Converted to the runtime numpad convention by build_event.
      def page_direction(page); page_field(:direction, 2) { d = page.direction; (0..3).include?(d) ? d : 2 }; end
      def page_move_type(page); page_field(:move_type, 0) { page.move_type || 0 }; end
      def page_move_speed(page); page_field(:move_speed, 3) { page.move_speed || 3 }; end
      def page_move_frequency(page); page_field(:move_frequency, 3) { page.move_frequency || 3 }; end
      def page_move_route(page); page_field(:move_route, nil) { page.move_route }; end
      def page_charset_name(page); page_field(:charset_name, nil) { page.charset_name }; end
      def page_charset_index(page); page_field(:charset_index, 0) { page.charset_index || 0 }; end
      def page_layer(page); page_field(:layer, 0) { page.layer || 0 }; end
      def page_pattern(page); page_field(:pattern, 1) { p = page.pattern; (0..2).include?(p) ? p : 1 }; end
      def page_anim_type(page); page_field(:anim_type, 0) { page.animation_type || 0 }; end
      def page_translucent(page); page_field(:translucent, false) { page.translucent ? true : false }; end

      # -- event execution ----------------------------------------------------

      def event_busy?
        @message || @number_input || @interpreter.running? || @interpreter.waiting?
      end

      # Start the first not-yet-run auto-start process in the foreground: map
      # events with an auto-start trigger, then auto-start common events (whose
      # switch gate, if any, is on). Each runs at most once per visit so an
      # ungated process cannot hard-loop. Parallel processes are driven
      # separately by #step_parallels.
      def start_autostart
        ev = @events.find do |e|
          e[:trigger] == TRIGGER_AUTO_START && e[:commands] && !@started_auto[e[:id]]
        end
        if ev
          @started_auto[ev[:id]] = true
          @active_event = ev
          @interpreter.start(ev[:commands])
          return
        end

        ce = @common.find do |c|
          c[:trigger] == Game::CommonEvent::AUTO_START && c[:commands] &&
            common_gate_open?(c) && !@started_common[c[:id]]
        end
        return unless ce
        @started_common[ce[:id]] = true
        @active_event = nil # a common event has no "this event" map character
        @interpreter.start(ce[:commands])
      end

      # A common event's switch gate: open unless it needs a flag that is off.
      def common_gate_open?(c)
        return true unless c[:need_flag]
        @state.switches[c[:switch_id]]
      end

      # Build the background (parallel-process) interpreters: map events with a
      # parallel trigger plus parallel common events. Each gets its own
      # Game::Interpreter, looped by #step_parallels; a common event that needs a
      # flag carries its gate switch so it only runs while that switch is on.
      def build_parallels
        @parallels = []
        @events.each do |e|
          next unless e[:trigger] == TRIGGER_PARALLEL && e[:commands]
          @parallels.push new_parallel(e[:commands], nil, e)
        end
        @common.each do |c|
          next unless c[:trigger] == Game::CommonEvent::PARALLEL && c[:commands]
          @parallels.push new_parallel(c[:commands],
                                       c[:need_flag] ? c[:switch_id] : nil, nil)
        end
      rescue StandardError
        @parallels = []
      end

      # Build one background process. `event` is the owning map event (so a Move
      # Event targeting "this event" resolves) or nil for a common event.
      def new_parallel(commands, gate_switch, event)
        it = Game::Interpreter.new(@state)
        it.resolver = @interpreter.resolver
        it.map_info = self
        it.start(commands)
        { interp: it, commands: commands, gate_switch: gate_switch,
          wait_timer: nil, event: event }
      end

      # Advance every background parallel process one frame. They loop their
      # command list and honour Wait; as background processes they do not drive
      # the message/choice/teleport UI (those requests are simply resumed so the
      # process keeps running). Called only while the foreground is idle, so
      # parallels pause during messages and foreground events.
      def step_parallels
        # Iterate a copy: an Erase Event in a parallel process removes it from
        # @parallels mid-loop (see erase_event).
        @parallels.dup.each { |p| step_parallel(p) }
      end

      def step_parallel(p)
        return if p[:gate_switch] && !@state.switches[p[:gate_switch]]
        it = p[:interp]
        if it.waiting?
          drive_parallel_wait(p, it)
        elsif it.running?
          it.update
        else
          it.start(p[:commands]) # loop the process
          it.update
        end
        apply_move_requests(it, p[:event])
        apply_location_requests(it, p[:event])
        apply_erase_request(it, p[:event])
        apply_tileset_request(it)
      rescue StandardError
        nil
      end

      def drive_parallel_wait(p, it)
        if it.wait_kind == :wait
          p[:wait_timer] = frames_from_tenths(it.wait_frames) if p[:wait_timer].nil?
          if p[:wait_timer] <= 0
            p[:wait_timer] = nil
            it.resume
          else
            p[:wait_timer] -= 1
          end
        elsif it.wait_kind == :key_input
          # Parallel processes commonly poll a key each frame into a variable.
          resolve_key_input(it)
        else
          it.resume # background: ignore message/choice/teleport requests
        end
      end

      # The event currently standing on tile (x, y), or nil.
      def event_at(x, y)
        @event_tiles[[x, y]]
      end

      # Turn `ev` to face the player and run its command list.
      def start_event(ev)
        ev[:char].face(ev[:char].direction_toward(@state.x, @state.y))
        @active_event = ev
        @interpreter.start(ev[:commands])
      end

      # On the action button, run the trigger-0 event the player is facing. The
      # faced event turns toward the player before its commands run.
      def try_action_trigger
        return if event_busy?
        return unless Input.trigger?(Input::C)
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        ev = event_at(fx, fy)
        start_event(ev) if ev && ev[:trigger] == TRIGGER_ACTION && ev[:commands]
      end

      # Advance autonomous / custom-route event movement one frame. Skipped
      # while an event process is running so the map holds still during messages.
      def step_events
        @events.each { |e| step_event(e) }
      end

      def step_event(e)
        return if event_busy? # an event fired earlier this frame; hold the rest
        ch = e[:char]
        e[:move_timer] -= 1
        return if e[:move_timer] > 0
        forced = e[:forced_route]
        # A forced route (from a Move Event) is paced by its own frequency when
        # one was given, otherwise by the page's; it overrides page movement.
        freq = forced && e[:forced_freq] ? e[:forced_freq] : ch.move_frequency
        e[:move_timer] = EVENT_MOVE_DELAY[freq] || 40
        ox = ch.x
        oy = ch.y
        if forced
          forced.step(ch, @world) unless forced.done?
          e[:forced_route] = nil if forced.done? # revert to page movement
        elsif e[:route]
          e[:route].step(ch, @world) unless e[:route].done?
        else
          dir = Game::MoveType.next_direction(e[:move_type], ch, @world)
          move_autonomous(e, dir) if dir
        end
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy
      rescue StandardError => ex
        $stderr.puts "[RPG2k] event ##{e[:id]} movement failed: #{ex.message}"
        nil
      end

      # Advance each event's pixel slide and walk-animation phase once per frame.
      # An event "moves" for animation purposes while it is sliding between two
      # tiles (see reoccupy / event_sliding?); such events — and any
      # continuous/spin animation type — cycle their walk frames on the
      # ANIM_FRAME_PERIOD cadence, while an event resting on a tile shows its
      # page pose. Game::EventGraphic.frame reads @moving / @anim_phase to pick
      # the drawn column, and event_pixel reads the slide for the draw position.
      def animate_events
        @events.each { |e| animate_event(e) }
      end

      def animate_event(e)
        # Advance the slide first so a fixed-graphic event still glides smoothly.
        e[:move_count] += SPEED if e[:move_count] < TILE
        sliding = event_sliding?(e)
        e[:moving] = sliding
        type = e[:anim_type]
        return unless Game::EventGraphic.animated?(type)
        return unless sliding || Game::EventGraphic.continuous?(type)
        e[:anim_count] += 1
        return if e[:anim_count] < ANIM_FRAME_PERIOD
        e[:anim_count] = 0
        e[:anim_phase] = (e[:anim_phase] + 1) % Game::EventGraphic::WALK_COLUMNS.size
      end

      # Whether an event is mid-step: its display origin has not yet caught up to
      # its logical tile (the slide started by reoccupy is still in progress).
      def event_sliding?(e)
        e[:move_count] < TILE &&
          (e[:disp_x] != e[:char].x || e[:disp_y] != e[:char].y)
      end

      # Move an autonomous event one step in `dir`. Walking into the player fires
      # an event-touch (trigger 2) event instead of moving; any other obstacle
      # just turns the event to face it.
      def move_autonomous(e, dir)
        ch = e[:char]
        nx, ny = Game::Character.step_tile(ch.x, ch.y, dir)
        if nx == @state.x && ny == @state.y
          ch.face(dir)
          start_event(e) if e[:trigger] == TRIGGER_EVENT_TOUCH && e[:commands]
        elsif @world.passable?(ch, dir)
          ch.move(dir)
        else
          ch.face(dir)
        end
      end

      # Update the occupied-tile cache after event `e` moved off (ox, oy). Done
      # eagerly (rather than a single end-of-frame rebuild) so an event that has
      # already moved this frame blocks the next event from stepping onto it.
      # Also begins the pixel slide from the old tile toward the new one so the
      # sprite glides instead of teleporting (see event_pixel).
      def reoccupy(e, ox, oy)
        @event_tiles.delete([ox, oy]) if @event_tiles[[ox, oy]].equal?(e)
        @event_tiles[[e[:char].x, e[:char].y]] = e
        start_event_slide(e, ox, oy)
      end

      # Begin a render slide for event `e` that just stepped off (ox, oy): the
      # sprite eases from that tile to its new one over TILE/SPEED frames. Only
      # single-tile cardinal steps slide; a longer hop (a jump, or a diagonal of
      # more than one tile) snaps so the sprite never streaks across the map.
      def start_event_slide(e, ox, oy)
        if (e[:char].x - ox).abs + (e[:char].y - oy).abs == 1
          e[:disp_x] = ox
          e[:disp_y] = oy
          e[:move_count] = 0
        else
          e[:disp_x] = e[:char].x
          e[:disp_y] = e[:char].y
          e[:move_count] = TILE
        end
      end

      # Current position of event `e` in map pixels, interpolated from its
      # display origin toward its logical tile while a slide is in progress.
      def event_pixel(e)
        cx = e[:char].x
        cy = e[:char].y
        if event_sliding?(e)
          t = e[:move_count]
          [e[:disp_x] * TILE + (cx - e[:disp_x]) * t,
           e[:disp_y] * TILE + (cy - e[:disp_y]) * t]
        else
          [cx * TILE, cy * TILE]
        end
      end

      # -- Erase Event --------------------------------------------------------

      # If the interpreter ran an Erase Event this step, remove the event that
      # was running it (`this_event`) from the map. A common event has no such
      # map event, so nothing happens.
      def apply_erase_request(interp, this_event)
        erase_event(this_event) if interp.take_erase_request && this_event
      rescue StandardError => e
        $stderr.puts "[RPG2k] Erase Event failed: #{e.message}"
        nil
      end

      # Remove an event from the map for the rest of the visit: drop it from the
      # runtime list, the occupied-tile cache (so it no longer draws, moves or
      # blocks) and any background process it was driving. It reappears only on
      # the next map (re)load, matching RPG2000's Erase Event.
      def erase_event(ev)
        @events.delete(ev)
        tile = [ev[:char].x, ev[:char].y]
        @event_tiles.delete(tile) if @event_tiles[tile].equal?(ev)
        @parallels.reject! { |p| p[:event].equal?(ev) } if @parallels
      end

      # -- Halt All Movement --------------------------------------------------

      # If the interpreter ran a Halt All Movement this step, cancel every forced
      # move route in progress — the player's and each event's — so a route set by
      # an earlier Move Event stops where it is. Events fall back to their page's
      # autonomous movement; the player returns to input control.
      def apply_halt_request(interp)
        return unless interp.take_halt_movement_request
        @player_route = nil
        @player_char = nil
        @events.each { |e| e[:forced_route] = nil } if @events
      rescue StandardError => e
        $stderr.puts "[RPG2k] Halt All Movement failed: #{e.message}"
        nil
      end

      # -- Change Sprite Association (Change Actor Graphic) --------------------

      # If the interpreter changed an actor's sprite this step, reload the party
      # leader's on-screen graphic so the change shows immediately (a change to a
      # non-leader actor is held in the model until that actor leads the party).
      def apply_graphic_change(interp)
        refresh_player_graphic if interp.take_actor_graphic_changed
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Actor Graphic failed: #{e.message}"
        nil
      end

      # Reload the party leader's CharSet graphic and apply its transparency to
      # the player sprite, forcing a redraw on the next frame. The transparency
      # flag hides the sprite outright (the renderer has no partial-opacity path).
      def refresh_player_graphic
        @charset = load_charset
        @last_frame = nil
        @player_sprite.visible = !player_hidden?
        @player_bmp.clear unless @charset
      end

      # Whether the party leader's map sprite should be hidden this frame: either
      # the Set Transparent Flag command hid the player, or the leader's own
      # actor graphic carries the (rarely used) semi-transparent flag.
      def player_hidden?
        leader = @state.party.leader
        @state.player_transparent || (leader && leader.transparent) ? true : false
      end

      # -- Change Map Tileset -------------------------------------------------

      # If the interpreter ran a Change Map Tileset this step, swap the map's
      # chipset to the requested id and rebuild its tile graphic. The override
      # lasts until the next map load (see perform_teleport).
      def apply_tileset_request(interp)
        id = interp.take_tileset_request
        return if id.nil?
        @tileset_id = id
        rebuild_chipset
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Map Tileset failed: #{e.message}"
        nil
      end

      # -- Move Event (Set Move Route) ----------------------------------------

      # Apply the Move Event requests an interpreter queued this step. `this_event`
      # is the map event running that process (or nil for a common event), so a
      # route targeting "this event" reaches the right character.
      def apply_move_requests(interp, this_event)
        reqs = interp.take_move_route_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_move_request(r, this_event) }
      rescue StandardError => e
        $stderr.puts "[RPG2k] Move Event apply failed: #{e.message}"
        nil
      end

      def apply_move_request(r, this_event)
        route = Game::MoveRoute.new(r[:commands], repeat: r[:repeat],
                                    skippable: r[:skippable])
        return if route.empty?
        case r[:target]
        when MOVE_TARGET_PLAYER
          start_player_route(route, r[:frequency])
        when 0, MOVE_TARGET_THIS
          force_event_route(this_event, route, r[:frequency]) if this_event
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          nil # vehicles are not modelled yet
        else
          ev = @events.find { |e| e[:id] == r[:target] }
          force_event_route(ev, route, r[:frequency]) if ev
        end
      end

      # -- Change / Trade Event Location --------------------------------------

      # Apply the instant-reposition requests an interpreter queued this step
      # (Change Event Location / Trade Event Locations). `this_event` is the map
      # event running the process (or nil), so a request targeting "this event"
      # reaches the right character.
      def apply_location_requests(interp, this_event)
        reqs = interp.take_location_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_location_request(r, this_event) }
      rescue StandardError => e
        $stderr.puts "[RPG2k] Event location change failed: #{e.message}"
        nil
      end

      def apply_location_request(r, this_event)
        if r[:op] == :swap
          a = char_location(r[:a], this_event)
          b = char_location(r[:b], this_event)
          return unless a && b
          set_char_location(r[:a], this_event, b[0], b[1])
          set_char_location(r[:b], this_event, a[0], a[1])
        else
          set_char_location(r[:target], this_event, r[:x], r[:y])
        end
      end

      # The current tile of a target character (the same target ids as Move
      # Event), or nil for the player-less vehicle slots / a missing event.
      def char_location(target, this_event)
        case target
        when MOVE_TARGET_PLAYER
          [@state.x, @state.y]
        when 0, MOVE_TARGET_THIS
          this_event ? [this_event[:char].x, this_event[:char].y] : nil
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          nil # vehicles are not modelled yet
        else
          ev = @events.find { |e| e[:id] == target }
          ev ? [ev[:char].x, ev[:char].y] : nil
        end
      end

      # Instantly move a target character to a tile.
      def set_char_location(target, this_event, x, y)
        case target
        when MOVE_TARGET_PLAYER
          move_player_to(x, y)
        when 0, MOVE_TARGET_THIS
          move_event_to(this_event, x, y) if this_event
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          nil # vehicles are not modelled yet
        else
          ev = @events.find { |e| e[:id] == target }
          move_event_to(ev, x, y) if ev
        end
      end

      # Snap the player to a tile: cancel any in-progress step and keep a forced
      # route's mirror character (if one is running) in sync so it steps on from
      # the new tile.
      def move_player_to(x, y)
        @state.x = x
        @state.y = y
        @dest_x = x
        @dest_y = y
        @moving = false
        @move_count = 0
        if @player_char
          @player_char.x = x
          @player_char.y = y
        end
      end

      # Snap an event to a tile and refresh the occupied-tile cache so collision
      # and the marker follow it.
      def move_event_to(ev, x, y)
        return unless ev
        ox = ev[:char].x
        oy = ev[:char].y
        ev[:char].x = x
        ev[:char].y = y
        reoccupy(ev, ox, oy)
      end

      # Give a map event a forced route, overriding its page movement until the
      # route finishes (a repeating route runs until replaced). It steps on the
      # next frame, paced by the requested frequency when one was given.
      def force_event_route(ev, route, freq)
        ev[:forced_route] = route
        ev[:forced_freq] = valid_move_freq(freq)
        ev[:move_timer] = 0
      end

      # Drive the player along a forced route: the player has no Game::Character,
      # so mirror one, step it against the map world and write the tile back to
      # the state. Forced player steps snap tile-to-tile (no pixel interpolation)
      # and suppress input movement while active.
      def start_player_route(route, freq)
        @player_char = Game::Character.new(@state.x, @state.y, @state.direction)
        @player_char.move_frequency = valid_move_freq(freq) ||
                                      @player_char.move_frequency
        @player_route = route
        @player_route_timer = 0
      end

      def step_player_route
        return unless @player_route
        @player_route_timer -= 1
        return if @player_route_timer > 0
        @player_route_timer = EVENT_MOVE_DELAY[@player_char.move_frequency] || 40
        @player_route.step(@player_char, @world) unless @player_route.done?
        @state.x = @player_char.x
        @state.y = @player_char.y
        @state.direction = @player_char.direction
        @dest_x = @state.x
        @dest_y = @state.y
        @moving = false
        @move_count = 0
        @player_route = nil if @player_route.done?
      end

      # Advance every forced move route in progress one frame — the player's and
      # each event's — while the interpreter is paused on Proceed With Movement
      # (the normal per-frame movement is skipped because an event is running).
      # Returns true once no forced route remains, so the caller can resume the
      # interpreter. A repeating forced route never reports done, matching RPG_RT.
      def step_forced_movement
        step_player_route
        @events.each { |e| step_forced_event(e) if e[:forced_route] }
        forced_movement_done?
      end

      # Pace and advance one event's forced route, mirroring step_event's forced
      # branch (used only while waiting on Proceed With Movement).
      def step_forced_event(e)
        ch = e[:char]
        e[:move_timer] -= 1
        return if e[:move_timer] > 0
        e[:move_timer] = EVENT_MOVE_DELAY[e[:forced_freq] || ch.move_frequency] || 40
        ox = ch.x
        oy = ch.y
        e[:forced_route].step(ch, @world) unless e[:forced_route].done?
        e[:forced_route] = nil if e[:forced_route].done?
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy
      rescue StandardError => ex
        $stderr.puts "[RPG2k] forced movement failed: #{ex.message}"
        e[:forced_route] = nil # drop a broken route so Proceed does not hang
      end

      # Whether no forced move route is still running (player or any event).
      def forced_movement_done?
        return false if @player_route
        @events.none? { |e| e[:forced_route] }
      end

      # A move frequency the request may override the target's pace with (1..8),
      # or nil to keep the target's own frequency.
      def valid_move_freq(f)
        (f && f >= 1 && f <= 8) ? f : nil
      end

      # Collision test for an event stepping one tile in `dir`: in bounds, not
      # onto the player or another event, and passable per the chipset. A
      # "through" character ignores all of this. Only the destination tile is
      # tested, so a character never blocks itself (it stands on its own tile,
      # not the one ahead).
      def char_passable?(character, dir)
        return true if character.through
        nx, ny = Game::Character.step_tile(character.x, character.y, dir)
        return false unless @map.in_bounds?(nx, ny)
        return false if nx == @state.x && ny == @state.y
        return false if @event_tiles[[nx, ny]]
        return true if @chipset.nil?
        @chipset.passable?(@map.lower(nx, ny), dir)
      end
      # Called by MapWorld (an external collaborator) with an explicit receiver.
      public :char_passable?

      # Terrain id of the lower-layer tile at (x, y), for the Store Terrain ID
      # command (0 when out of bounds or no chipset). Queried by the interpreter
      # via its map_info hook.
      def terrain_id(x, y)
        return 0 if @chipset.nil? || !@map.in_bounds?(x, y)
        @chipset.terrain(@map.lower(x, y))
      end
      public :terrain_id

      # Id of the event standing on tile (x, y), for the Store Event ID command
      # (0 when no event is there). Queried by the interpreter via map_info.
      def event_id_at(x, y)
        ev = @event_tiles[[x, y]]
        ev ? ev[:id] : 0
      end
      public :event_id_at

      # The cancel button opens the main menu over the map, unless a Change Main
      # Menu Access command has forbidden it.
      def try_open_menu
        return if event_busy?
        return unless @state.menu_access
        return unless Input.trigger?(Input::B)
        @parent.push Scene::Menu.new(@parent, @state)
      end

      def drive_event
        if @message
          drive_message
          return
        end

        if @number_input
          drive_number_input
          return
        end

        if @interpreter.waiting?
          case @interpreter.wait_kind
          when :message then open_message(@interpreter.message_lines, false)
          when :choice then open_message(@interpreter.choice_labels, true)
          when :number then open_number_input(@interpreter.input_digits)
          when :key_input then drive_key_input
          when :inn then drive_inn
          when :shop then drive_shop
          when :battle then drive_battle
          when :wait then drive_wait
          when :teleport then perform_teleport(@interpreter.teleport)
          when :movement then @interpreter.resume if step_forced_movement
          when :screen then @interpreter.resume unless @state.screen.busy?
          when :picture then @interpreter.resume unless @state.pictures_moving?
          when :return_title then perform_return_to_title
          end
        else
          @interpreter.update
          apply_move_requests(@interpreter, @active_event)
          apply_location_requests(@interpreter, @active_event)
          apply_erase_request(@interpreter, @active_event)
          apply_halt_request(@interpreter)
          apply_graphic_change(@interpreter)
          apply_tileset_request(@interpreter)
        end
      end

      # Maps the interpreter's accepted-key symbols onto RGSS input buttons.
      # Decision (OK) is the confirm button C, Cancel is B — the same mapping the
      # message and menu widgets use.
      KEY_INPUT_BUTTONS = {
        down: Input::DOWN, left: Input::LEFT, right: Input::RIGHT,
        up: Input::UP, decision: Input::C, cancel: Input::B, shift: Input::SHIFT
      }.freeze

      def drive_key_input
        resolve_key_input(@interpreter)
      end

      # Drive a Key Input Processing wait for interpreter `it` (the foreground
      # event or a parallel process): sample the accepted buttons and hand back
      # the resulting RPG2000 key code. A waiting proc uses triggered edges and
      # only resumes once a key is actually pressed; a no-wait proc reads the
      # held state and resumes immediately (storing 0 when nothing is down),
      # matching RPG_RT.
      def resolve_key_input(it)
        req = it.key_input_request
        return it.resume_key_input(0) unless req
        accepted = req[:accepted]
        active = []
        KEY_INPUT_BUTTONS.each do |sym, btn|
          next unless accepted[sym]
          hit = req[:wait] ? Input.trigger?(btn) : Input.press?(btn)
          active << sym if hit
        end
        code = it.key_input_result(active)
        if req[:wait]
          it.resume_key_input(code) if code != 0
        else
          it.resume_key_input(code)
        end
      end

      # -- Show Inn (Stay at Inn) ---------------------------------------------

      INN_LINE_H = 14

      # Drive a Show Inn wait: a free stay (price 0) resumes at once; otherwise a
      # greeting window with Accept / Cancel choices and a gold window is shown,
      # Accept selectable only when the party can afford the price. The
      # interpreter charges gold and heals the party in resume_inn.
      def drive_inn
        req = @interpreter.inn_request
        return @interpreter.resume_inn(false) unless req
        return @interpreter.resume_inn(true) unless req[:prompt]

        if @inn_window.nil?
          open_inn_window(req) # opened this frame; take input from the next one
          return
        end
        if Input.trigger?(Input::DOWN) && @inn_choice < 1
          @inn_choice += 1
          set_inn_cursor
        elsif Input.trigger?(Input::UP) && @inn_choice > 0
          @inn_choice -= 1
          set_inn_cursor
        elsif Input.trigger?(Input::C)
          if @inn_choice.zero?
            # Accept: only honoured when the party can pay; otherwise ignored.
            if req[:can_afford]
              close_inn_window
              @interpreter.resume_inn(true)
            end
          else
            close_inn_window
            @interpreter.resume_inn(false)
          end
        elsif Input.trigger?(Input::B)
          close_inn_window
          @interpreter.resume_inn(false)
        end
      end

      # RPG2000 inn term set (A or B) selected by the command's type parameter.
      # Blank database terms (e.g. a bare test project) fall back to plain
      # English so the window is never empty.
      def inn_terms(type)
        t = db.term
        a = type.zero?
        {
          greet1: nonblank(a ? t.inn_a_greeting_1 : t.inn_b_greeting_1, 'Stay the night for'),
          greet2: nonblank(a ? t.inn_a_greeting_2 : t.inn_b_greeting_2, '?'),
          greet3: nonblank(a ? t.inn_a_greeting_3 : t.inn_b_greeting_3, 'Will you stay?'),
          accept: nonblank(a ? t.inn_a_accept : t.inn_b_accept, 'Yes'),
          cancel: nonblank(a ? t.inn_a_cancel : t.inn_b_cancel, 'No')
        }
      end

      def nonblank(s, fallback)
        s = s.to_s
        s.empty? ? fallback : s
      end

      def open_inn_window(req)
        terms = inn_terms(req[:type])
        gold_term = nonblank(db.term.gold, 'G')
        lines = ["#{terms[:greet1]} #{req[:price]}#{gold_term} #{terms[:greet2]}".strip,
                 terms[:greet3], terms[:accept], terms[:cancel]]
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = lines.length * INN_LINE_H
        win = Window.new(10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        contents = Bitmap.new(inner_w, inner_h)
        contents.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          contents.draw_text 0, i * INN_LINE_H, inner_w, INN_LINE_H, line
        end
        win.contents = contents

        gwin = build_inn_gold_window(gold_term)
        @inn_window = { window: win, gold: gwin }
        # Start on Accept when affordable, else on Cancel.
        @inn_choice = req[:can_afford] ? 0 : 1
        set_inn_cursor
      end

      # A small window showing the party's current gold, mirroring the RPG2000
      # inn's gold display.
      def build_inn_gold_window(gold_term)
        gw = 88
        gh = INN_LINE_H + Window::BORDER * 2
        win = Window.new(SCREEN_W - gw - 6, 6, gw, gh)
        win.z = 300
        win.windowskin = @windowskin
        c = Bitmap.new(gw - Window::BORDER * 2, INN_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, INN_LINE_H, "#{@state.party.gold}#{gold_term}"
        win.contents = c
        win
      end

      # The Accept / Cancel lines sit below the two greeting lines, so the cursor
      # row is offset by 2.
      def set_inn_cursor
        return unless @inn_window
        win = @inn_window[:window]
        row = 2 + @inn_choice
        win.cursor_rect = Rect.new(0, row * INN_LINE_H, win.contents.width, INN_LINE_H)
      end

      def close_inn_window
        return unless @inn_window
        @inn_window[:window].dispose
        @inn_window[:gold].dispose if @inn_window[:gold]
        @inn_window = nil
      end

      # -- Open Shop (buy / sell) ---------------------------------------------

      SHOP_LINE_H = 14

      # Drive an Open Shop wait. On the first frame the shop opens (a command
      # menu for a buy+sell shop, or straight to the buy / sell list for a
      # single-mode shop). Buying and selling happen one unit per confirm on
      # Game::Shop; leaving resumes the interpreter with whether anything was
      # traded (which picks the [Transaction] / [No Transaction] branch).
      def drive_shop
        req = @interpreter.shop_request
        return @interpreter.resume_shop(false) unless req
        if @shop.nil?
          open_shop(req) # opened this frame; take input from the next one
          return
        end
        @shop[:screen] == :command ? drive_shop_command : drive_shop_list
      end

      def open_shop(req)
        model = Game::Shop.new(db, @state.party, req[:goods],
                               req[:allow_buy], req[:allow_sell])
        has_menu = req[:allow_buy] && req[:allow_sell]
        screen = has_menu ? :command : (req[:allow_buy] ? :buy : :sell)
        @shop = { model: model, has_menu: has_menu, screen: screen, index: 0,
                  window: nil, gold: build_shop_gold_window }
        draw_shop
      end

      def shop_gold_term; nonblank(db.term.gold, 'G'); end

      def build_shop_gold_window
        gw = 88
        win = Window.new(SCREEN_W - gw - 6, 6, gw, SHOP_LINE_H + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        win
      end

      # The [label, target] rows for the current shop screen: the command menu's
      # actions, the goods on the buy list, or the party's sellable items.
      def shop_lines
        m = @shop[:model]
        case @shop[:screen]
        when :command
          rows = []
          rows << ['Buy', :buy] if m.allow_buy?
          rows << ['Sell', :sell] if m.allow_sell?
          rows << ['Leave', :leave]
          rows
        when :buy
          m.goods.map { |id| ["#{m.name(id)}  #{m.price(id)}#{shop_gold_term}", id] }
        else # :sell
          m.sellable_items.map do |id|
            ["#{m.name(id)} x#{@state.party.item_count(id)}  " \
             "#{m.sell_price(id)}#{shop_gold_term}", id]
          end
        end
      end

      def draw_shop
        lines = shop_lines
        @shop[:index] = Game.clamp(@shop[:index], 0, [lines.length - 1, 0].max)
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = [lines.length, 1].max * SHOP_LINE_H
        @shop[:window].dispose if @shop[:window]
        win = Window.new(10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |(label, _), i|
          c.draw_text 0, i * SHOP_LINE_H, inner_w, SHOP_LINE_H, label
        end
        win.contents = c
        unless lines.empty?
          win.cursor_rect =
            Rect.new(0, @shop[:index] * SHOP_LINE_H, inner_w, SHOP_LINE_H)
        end
        @shop[:window] = win
        draw_shop_gold
      end

      def draw_shop_gold
        gw = 88
        c = Bitmap.new(gw - Window::BORDER * 2, SHOP_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, SHOP_LINE_H,
                    "#{@state.party.gold}#{shop_gold_term}"
        @shop[:gold].contents = c
      end

      def drive_shop_command
        lines = shop_lines
        if shop_move_cursor(lines)
          # cursor moved
        elsif Input.trigger?(Input::C)
          case lines[@shop[:index]][1]
          when :buy  then shop_switch(:buy)
          when :sell then shop_switch(:sell)
          when :leave then leave_shop
          end
        elsif Input.trigger?(Input::B)
          leave_shop
        end
      end

      def drive_shop_list
        lines = shop_lines
        if shop_move_cursor(lines)
          # cursor moved
        elsif Input.trigger?(Input::C) && !lines.empty?
          id = lines[@shop[:index]][1]
          @shop[:screen] == :buy ? @shop[:model].buy(id) : @shop[:model].sell(id)
          draw_shop # refresh gold and, after a sale, the (shrunk) list
        elsif Input.trigger?(Input::B)
          @shop[:has_menu] ? shop_switch(:command) : leave_shop
        end
      end

      # Move the shop cursor with Up / Down; returns true if it moved.
      def shop_move_cursor(lines)
        if Input.trigger?(Input::DOWN) && @shop[:index] < lines.length - 1
          @shop[:index] += 1
          draw_shop
          true
        elsif Input.trigger?(Input::UP) && @shop[:index] > 0
          @shop[:index] -= 1
          draw_shop
          true
        else
          false
        end
      end

      def shop_switch(screen)
        @shop[:screen] = screen
        @shop[:index] = 0
        draw_shop
      end

      def leave_shop
        transacted = @shop[:model].did_transaction
        close_shop
        @interpreter.resume_shop(transacted)
      end

      def close_shop
        return unless @shop
        @shop[:window].dispose if @shop[:window]
        @shop[:gold].dispose if @shop[:gold]
        @shop = nil
      end

      # -- Enemy Encounter (headless battle) ----------------------------------

      # Resolve an Enemy Encounter by running a headless auto-battle (Game::Battle)
      # of the party against the troop. On victory the troop's EXP is granted to
      # every party member and its gold to the party, then the [Victory] handler
      # runs; a defeat routes the [Defeat] handler. The battle works on snapshots,
      # so the party's real HP is left untouched for now — the on-screen
      # turn-based battle (that would show and persist HP) and game over on defeat
      # are still to come.
      def drive_battle
        req = @interpreter.battle_request
        return @interpreter.resume_battle(:victory) unless req
        troop = Game::Troop.new(db, req[:troop_id])
        allies = @state.party.actors.map { |a| Game::Battle.from_actor(a) }
        foes = troop.members.map { |e| Game::Battle.from_enemy(e) }
        result = Game::Battle.new(allies, foes, Game::Rng.new(0x2000)).run
        if result == :victory
          exp = troop.total_exp
          @state.party.actors.each { |a| a.gain_exp(exp) }
          @state.party.gain_gold(troop.total_gold)
        end
        @interpreter.resume_battle(result)
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle resolution failed: #{e.message}"
        @interpreter.resume_battle(:victory)
      end

      def drive_wait
        @wait_timer = frames_from_tenths(@interpreter.wait_frames) if @wait_timer.nil?
        if @wait_timer <= 0
          @wait_timer = nil
          @interpreter.resume
        else
          @wait_timer -= 1
        end
      end

      # Convert an RPG2000 wait duration (tenths of a second) to a frame count at
      # the current frame rate (defaulting to 60 fps).
      def frames_from_tenths(tenths)
        fr = Graphics.frame_rate
        fr = 60 if fr.nil? || fr <= 0
        tenths * fr / 10
      end

      def perform_teleport(t)
        map_id, x, y, dir = t
        @map = @parent.load_map(map_id)
        @state.map = @map
        @state.map_id = map_id
        @state.x = x
        @state.y = y
        @state.direction = dir if dir && dir > 0
        @tileset_id = nil # a Change Map Tileset override does not survive a teleport
        @chipset = build_chipset
        @started_auto = {}
        @started_common = {}
        @active_event = nil
        @player_route = nil # a forced player route does not survive a teleport
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        @moving = false
        @move_count = 0
        @last_frame = nil
        @interpreter.stop
      rescue StandardError => e
        $stderr.puts "[RPG2k] Teleport failed: #{e.message}"
        @interpreter.stop
      end

      # Return to Title Screen: stop the running event and hand control back to
      # the app, which tears the play scenes down and shows a fresh title. There
      # is nothing to resume afterwards — this scene is being disposed.
      def perform_return_to_title
        @interpreter.stop
        @parent.return_to_title
      rescue StandardError => e
        $stderr.puts "[RPG2k] Return to Title failed: #{e.message}"
        @interpreter.stop
      end

      # -- message / choice window --------------------------------------------

      MSG_LINE_H = 14
      # Characters revealed per frame for the message typewriter effect.
      MSG_REVEAL_SPEED = 2
      # RPG2000 FaceSet geometry: a 4x4 grid of 48x48 face cells, drawn beside
      # the message text with a small gap.
      FACE_SIZE = 48
      FACE_MARGIN = 4

      # Look up an actor name by id for the \n[] message control code.
      def actor_name(id)
        a = @db.player[id]
        a ? a.name.to_s : ''
      rescue StandardError => e
        $stderr.puts "[RPG2k] actor name ##{id} lookup failed: #{e.message}"
        ''
      end

      def open_message(lines, choice)
        return if @message
        names = ->(id) { actor_name(id) }
        raw = (lines || [])
        raw = [''] if raw.empty?
        # Parse each line into colour runs; the plain text (segments joined)
        # drives the reveal counter so it counts visible characters only.
        seg_lines = raw.map do |l|
          Game::Message.parse(l.to_s, @state.variables, names)
        end
        plain = seg_lines.map { |segs| segs.map { |s| s[:text] }.join }

        # Message Options / Change Face Graphic settings in effect for this
        # window (position, transparency and an optional FaceSet graphic).
        cfg = @state.message_config
        face = load_face(cfg)
        face_left = face && !cfg.face_right
        face_right = face && cfg.face_right
        text_x = face_left ? FACE_SIZE + FACE_MARGIN : 0

        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        text_w = inner_w - text_x - (face_right ? FACE_SIZE + FACE_MARGIN : 0)
        inner_h = plain.length * MSG_LINE_H
        inner_h = FACE_SIZE if face && inner_h < FACE_SIZE # keep room for the face
        win_h = inner_h + Window::BORDER * 2
        win = Window.new(10, message_window_y(win_h, cfg), SCREEN_W - 20, win_h)
        win.z = 300
        win.windowskin = @windowskin
        win.transparent = cfg.transparent

        contents = Bitmap.new(inner_w, inner_h)

        # Plain messages type out gradually; choice lists appear at once.
        reveal = Game::TextReveal.new(plain)
        reveal.reveal_all if choice
        @message = { window: win, choice: choice, count: plain.length,
                     reveal: reveal, contents: contents, inner_w: inner_w,
                     seg_lines: seg_lines, face: face,
                     face_index: cfg.face_index,
                     face_x: face_right ? inner_w - FACE_SIZE : 0,
                     text_x: text_x, text_w: text_w }
        draw_message_contents
        win.contents = contents
        @choice_index = 0
        set_choice_cursor if choice
      end

      # Vertical position of a `win_h`-tall message window for the configured
      # display position (top / middle / bottom). Auto-positioning away from the
      # hero (when `position_fixed` is off) is a later refinement; the window is
      # placed at the requested position for now.
      def message_window_y(win_h, cfg)
        case cfg.position
        when Game::MessageConfig::POS_TOP    then 6
        when Game::MessageConfig::POS_MIDDLE then (SCREEN_H - win_h) / 2
        else SCREEN_H - win_h - 6
        end
      end

      # Load the FaceSet graphic named by the message config, or nil when no face
      # is selected or the file is missing (the message then shows text only).
      def load_face(cfg)
        return nil unless cfg.face?
        Bitmap.new "FaceSet/#{cfg.face_name}"
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{cfg.face_name}' load failed: #{e.message}"
        nil
      end

      # (Re)draw the message body showing the currently revealed characters,
      # each colour run in its own colour, laid out left to right per line. The
      # face graphic (when present) is drawn first, and text is inset past it.
      def draw_message_contents
        return unless @message
        c = @message[:contents]
        c.clear
        draw_message_face
        vis = Game::Message.visible_segments(@message[:seg_lines],
                                             @message[:reveal].revealed)
        right = @message[:text_x] + @message[:text_w]
        vis.each_with_index do |segs, i|
          x = @message[:text_x]
          y = i * MSG_LINE_H
          segs.each do |seg|
            draw_message_run(c, x, y, right - x, seg)
            x += c.text_size(seg[:text]).width
          end
        end
      end

      # Draw one coloured message run. When the System windowskin is present and
      # the colour index is one of its 20 text swatches, blend the glyphs with
      # that swatch (`Bitmap#blend_text`), so the text takes the windowskin's own
      # colour and shading the way RPG2000 draws it. Otherwise fall back to a
      # flat font colour (the approximation, or an out-of-range `\c[n]`).
      def draw_message_run(c, x, y, w, seg)
        idx = seg[:color]
        if @windowskin && Game::MessagePalette.valid?(idx)
          sx, sy = Game::MessagePalette.cell_origin(idx)
          cell = Game::MessagePalette::CELL
          c.blend_text x, y, w, MSG_LINE_H, seg[:text], @windowskin,
                       sx, sy, cell, cell
        else
          c.font.color = message_color(idx)
          c.draw_text x, y, w, MSG_LINE_H, seg[:text]
        end
      end

      # Blit the selected face cell (a 48x48 tile of the 4x4 FaceSet grid) into
      # the message contents at its configured side.
      def draw_message_face
        face = @message[:face]
        return unless face
        idx = @message[:face_index]
        src = Rect.new((idx % 4) * FACE_SIZE, (idx / 4) * FACE_SIZE,
                       FACE_SIZE, FACE_SIZE)
        @message[:contents].blt @message[:face_x], 0, face, src
      end

      # RPG2000 message text palette (`\c[n]`). A small built-in approximation
      # until the real 20-colour row is read from the System windowskin; unknown
      # indices fall back to the default (white).
      MSG_COLORS = {
        0 => [255, 255, 255], 1 => [128, 176, 255], 2 => [255, 128, 128],
        3 => [128, 255, 128], 4 => [255, 255, 128], 5 => [128, 240, 240],
        6 => [255, 160, 255], 7 => [200, 200, 200], 8 => [255, 192, 128],
        9 => [160, 160, 255]
      }.freeze

      # The flat fallback colour for a `\c[n]` run — used only when there is no
      # System windowskin to blend the glyphs with (see draw_message_run), or for
      # an out-of-range colour index. Always opaque.
      def message_color(idx)
        rgb = MSG_COLORS[idx] || MSG_COLORS[0]
        Color.new(rgb[0], rgb[1], rgb[2], 255)
      end

      def set_choice_cursor
        return unless @message
        @message[:window].cursor_rect =
          Rect.new(0, @choice_index * MSG_LINE_H,
                   @message[:window].contents.width, MSG_LINE_H)
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
          end
        else
          drive_text_message
        end
      end

      # A plain (non-choice) message: type the text out, and let a button press
      # first complete the reveal, then (once fully shown) dismiss and resume.
      def drive_text_message
        reveal = @message[:reveal]
        pressed = Input.trigger?(Input::C) || Input.trigger?(Input::B)
        unless reveal.done?
          pressed ? reveal.reveal_all : reveal.advance(MSG_REVEAL_SPEED)
          draw_message_contents
          return
        end
        if pressed
          close_message
          @interpreter.resume
        end
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end

      # -- number input (Input Number command) --------------------------------

      # Pixels per digit cell in the Input Number widget.
      NUM_CELL = 16

      # Open a digit-entry window for the Input Number command. A compact panel
      # near the bottom of the screen shows `digits` cells with an editable
      # cursor; the interpreter is resumed with the entered value on confirm.
      def open_number_input(digits)
        return if @number_input
        model = Game::NumberInput.new(digits || 1)
        inner_w = model.digits * NUM_CELL
        inner_h = MSG_LINE_H
        win_w = inner_w + Window::BORDER * 2
        win_h = inner_h + Window::BORDER * 2
        win = Window.new((SCREEN_W - win_w) / 2, SCREEN_H - win_h - 6, win_w, win_h)
        win.z = 320
        win.windowskin = @windowskin
        contents = Bitmap.new(inner_w, inner_h)
        @number_input = { window: win, contents: contents, model: model }
        draw_number_input
        win.contents = contents
      end

      def draw_number_input
        ni = @number_input
        return unless ni
        model = ni[:model]
        c = ni[:contents]
        c.clear
        (0...model.digits).each do |i|
          x = i * NUM_CELL
          if i == model.cursor
            c.fill_rect x, 1, NUM_CELL, MSG_LINE_H - 2, Color.new(40, 72, 200, 160)
          end
          c.font.color = Color.new(255, 255, 255, 255)
          c.draw_text x, 0, NUM_CELL, MSG_LINE_H, model.digit(i).to_s, 1
        end
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
        end
      end

      def close_number_input
        return unless @number_input
        @number_input[:window].dispose
        @number_input = nil
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

        return if event_busy? # don't start a new move while an event runs
        return if @player_route # a forced route controls the player
        dir = Input.dir4
        return if dir == 0

        @state.direction = dir
        nx, ny = target_tile(@state.x, @state.y, dir)

        # Walking into a player-touch (trigger 1) event runs it instead of moving.
        touched = event_at(nx, ny)
        if touched && touched[:trigger] == TRIGGER_PLAYER_TOUCH && touched[:commands]
          start_event(touched)
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
        return false unless @map.in_bounds?(x, y)
        return false if @event_tiles[[x, y]]
        return true if @chipset.nil?
        @chipset.passable?(@map.lower(x, y), dir)
      end

      # Current player position in map pixels, interpolated during a step.
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
        screen = @state.screen
        hero_cx = Game.camera_offset(px + TILE / 2, SCREEN_W, @map.width * TILE)
        hero_cy = Game.camera_offset(py + TILE / 2, SCREEN_H, @map.height * TILE)
        # Pan Screen: while the camera is locked it holds where locking began
        # (captured once) instead of following the hero; the pan offset then
        # scrolls that view. Unlocked, it tracks the hero as usual.
        if screen.pan_locked?
          @locked_cam ||= [hero_cx, hero_cy]
          base_x, base_y = @locked_cam
        else
          @locked_cam = nil
          base_x = hero_cx
          base_y = hero_cy
        end
        ox, oy = screen.pan_offset
        # Screen shake slides the whole view horizontally (the player moves with
        # the map, so the entire screen shakes); the map edge may show a sliver
        # of void during the shake/pan, which is fine.
        cam_x = base_x + ox - screen.shake_offset
        cam_y = base_y + oy

        draw_parallax cam_x, cam_y
        draw_layers cam_x, cam_y

        @player_sprite.x = px - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        @player_sprite.y = py - cam_y - (Game::CharSet::HEIGHT - TILE)
        # Reflect the Set Transparent Flag command (and any leader graphic flag)
        # every frame so the hero hides/shows as events toggle it.
        @player_sprite.visible = !player_hidden?
        draw_player_frame

        draw_pictures cam_x, cam_y
      end

      # Composite the Show Picture layer into its buffer, drawing lowest-id first
      # so higher-numbered pictures sit on top. Each picture is scaled by its zoom
      # about its centre and blitted at its opacity; a picture pinned to the map
      # scrolls with the camera, otherwise it holds its screen position. (Tone is
      # carried on the picture but not yet applied — that needs native tone
      # support, like the screen tint.)
      def draw_pictures(cam_x, cam_y)
        @picture_bmp.clear
        pics = @state.pictures
        return if pics.empty?
        pics.keys.sort.each { |id| draw_picture pics[id], cam_x, cam_y }
      end

      def draw_picture(pic, cam_x, cam_y)
        src = picture_src(pic.name, pic.use_transparent_color)
        return unless src
        zw = src.width * pic.zoom / 100
        zh = src.height * pic.zoom / 100
        return if zw <= 0 || zh <= 0
        # RPG2000 positions a picture by its centre.
        dx = pic.x - zw / 2
        dy = pic.y - zh / 2
        if pic.fixed_to_map
          dx -= cam_x
          dy -= cam_y
        end
        @picture_bmp.stretch_blt Rect.new(dx, dy, zw, zh), src,
                                 Rect.new(0, 0, src.width, src.height),
                                 pic.opacity
      rescue StandardError => e
        $stderr.puts "[RPG2k] picture ##{pic.id} draw failed: #{e.message}"
      end

      # Composite the parallax background into its screen-sized buffer, tiling
      # the image along any looping axis so it fills the view. The per-axis
      # start offset (and, for a looping axis, the scroll/autoscroll) comes from
      # Game::Parallax; @anim_frame drives the autoscroll. A non-looping axis
      # draws a single copy at its anchored offset.
      def draw_parallax cam_x, cam_y
        return unless @parallax_img
        iw = @parallax_img.width
        ih = @parallax_img.height
        ox = Game::Parallax.axis_offset(@par_loop_x, @par_auto_x, @par_sx,
                                        @anim_frame, cam_x, SCREEN_W,
                                        @map.width * TILE, iw)
        oy = Game::Parallax.axis_offset(@par_loop_y, @par_auto_y, @par_sy,
                                        @anim_frame, cam_y, SCREEN_H,
                                        @map.height * TILE, ih)
        @parallax_bmp.clear
        src = Rect.new(0, 0, iw, ih)
        parallax_tiles(oy, ih, SCREEN_H, @par_loop_y).each do |dy|
          parallax_tiles(ox, iw, SCREEN_W, @par_loop_x).each do |dx|
            @parallax_bmp.blt dx, dy, @parallax_img, src
          end
        end
      end

      # Draw positions along one axis so the image (size `size`, starting at
      # `off` <= 0) covers `screen`: repeated every `size` when the axis loops,
      # a single copy at `off` otherwise.
      def parallax_tiles(off, size, screen, loop)
        return [off] unless loop && size > 0
        d = off
        d -= size while d > 0        # begin at or left of the origin
        d += size while d + size <= 0 # but not entirely off-screen
        out = []
        while d < screen
          out << d
          d += size
        end
        out
      end

      def draw_layers cam_x, cam_y
        @lower_bmp.clear
        @upper_bmp.clear
        first_tx = cam_x / TILE
        first_ty = cam_y / TILE
        ox = cam_x % TILE
        oy = cam_y % TILE

        # Animation columns/frames for this render, shared by every tile so the
        # whole map animates in lock-step. Only needed on the real-chipset path.
        if @chipset_bmp
          abf = Game::ChipsetLayout.anim_ab(@anim_frame, @chipset.animation_type,
                                            @chipset.animation_speed)
          cf = Game::ChipsetLayout.anim_c(@anim_frame)
        end

        (0...ROWS).each do |ry|
          (0...COLS).each do |rx|
            tx = first_tx + rx
            ty = first_ty + ry
            dx = rx * TILE - ox
            dy = ry * TILE - oy

            lower = @map.lower(tx, ty)
            upper = @map.upper(tx, ty)

            if @chipset_bmp
              draw_tile @lower_bmp, lower, dx, dy, abf, cf
              draw_tile @upper_bmp, upper, dx, dy, abf, cf
            else
              # Fallback: solid colour blocks keyed by tile id (no chipset image).
              @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(lower)
              @upper_bmp.fill_rect dx, dy, TILE, TILE, tile_color(upper) if upper && upper != 0
            end
          end
        end

        draw_events cam_x, cam_y
      end

      # Draw every event's graphic into the tile buffers, layered so it composits
      # correctly with the player sprite (z=100, between the lower buffer at z=0
      # and the upper buffer at z=200):
      #   * below-hero events (page layer 0) go in the lower buffer, under the
      #     player;
      #   * above-hero events (layer 2) go in the upper buffer, over the player;
      #   * same-layer events (layer 1) go under the player when they stand
      #     behind him (smaller y) and over him when in front (larger-or-equal
      #     y), the y-sort RPG2000 applies within the character layer.
      # A translucent page is blitted at half opacity. Events with no graphic
      # (empty CharSet name and no tile substitution) draw nothing.
      def draw_events(cam_x, cam_y)
        @events.each { |e| draw_event e, cam_x, cam_y }
      end

      def draw_event(e, cam_x, cam_y)
        bmp = event_target_buffer(e)
        return unless bmp
        opacity = e[:translucent] ? 128 : 255
        ch = e[:char]
        name = ch.graphic_name
        if name && !name.empty?
          draw_event_charset(e, bmp, cam_x, cam_y, opacity)
        elsif ch.graphic_index && ch.graphic_index > 0
          draw_event_tile(e, bmp, cam_x, cam_y, opacity)
        end
      rescue StandardError => ex
        $stderr.puts "[RPG2k] event ##{e[:id]} draw failed: #{ex.message}"
      end

      # Which tile buffer an event composits into, per its page layer and (for
      # the same-as-hero layer) its y relative to the player.
      def event_target_buffer(e)
        case e[:layer]
        when 2 then @upper_bmp                                   # above hero
        when 1 then e[:char].y >= @state.y ? @upper_bmp : @lower_bmp
        else @lower_bmp                                          # below hero
        end
      end

      # Blit an event's CharSet frame (24x32), feet-on-tile like the player.
      def draw_event_charset(e, bmp, cam_x, cam_y, opacity)
        charset = event_charset(e[:char].graphic_name)
        return unless charset
        dir, col = Game::EventGraphic.frame(e[:anim_type], e[:base_dir],
                                            e[:base_pattern],
                                            e[:char].direction, e[:anim_phase],
                                            e[:moving])
        sx, sy, sw, sh = Game::CharSet.frame_rect(e[:char].graphic_index, dir, col)
        epx, epy = event_pixel(e)
        dx = epx - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        dy = epy - cam_y - (Game::CharSet::HEIGHT - TILE)
        bmp.blt dx, dy, charset, Rect.new(sx, sy, sw, sh), opacity
      end

      # Blit an event whose graphic is a chipset tile (16x16), aligned to its
      # tile. Needs the chipset image; with none loaded (colour-block fallback)
      # the tile event is skipped.
      def draw_event_tile(e, bmp, cam_x, cam_y, opacity)
        return unless @chipset_bmp
        sx, sy, sw, sh = Game::ChipsetLayout.event_tile_rect(e[:char].graphic_index)
        epx, epy = event_pixel(e)
        dx = epx - cam_x
        dy = epy - cam_y
        bmp.blt dx, dy, @chipset_bmp, Rect.new(sx, sy, sw, sh), opacity
      end

      # Blit one map tile from the chipset image into `bmp` at (dx, dy). A plain
      # chip is a single 16x16 copy; an autotile is assembled from four 8x8
      # quarters. Empty/out-of-range ids draw nothing (id 0 is transparent).
      def draw_tile bmp, id, dx, dy, abf, cf
        Game::ChipsetLayout.quads(id, abf, cf).each do |qdx, qdy, sx, sy, w, h|
          bmp.blt dx + qdx, dy + qdy, @chipset_bmp, Rect.new(sx, sy, w, h)
        end
      end

      def draw_player_frame
        return unless @charset
        pat = @moving ? Game::CharSet::WALK_PATTERNS[(@move_count / 4) % 4] : 1
        frame = [@state.direction, pat]
        return if frame == @last_frame
        @last_frame = frame

        rx, ry, rw, rh = Game::CharSet.frame_rect(@charset_index, @state.direction, pat)
        @player_bmp.clear
        @player_bmp.blt 0, 0, @charset, Rect.new(rx, ry, rw, rh)
      end

      # Deterministic, memoised colour for a tile id so distinct tiles read as
      # distinct blocks. Empty (0/nil) tiles are a dark "void".
      def tile_color id
        return (@void ||= Color.new(16, 16, 28, 255)) if id.nil? || id == 0
        @tile_colors[id] ||= Color.new(40 + (id * 37) % 180,
                                       40 + (id * 71) % 180,
                                       60 + (id * 143) % 160, 255)
      end
    end

    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Save and End Game are wired up; the item/skill/equip/
    # status screens are placeholders that report they are not implemented.
    class Menu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      COMMANDS = ["Item", "Skill", "Equip", "Status", "Save", "End Game"].freeze

      def initialize parent, state
        super parent
        @state = state
        @index = 0
        @message = nil
        @skin = make_windowskin
        build_windows
      end

      def dispose
        close_message
        @command.dispose if @command
        @status.dispose if @status
      end

      def update
        return drive_message if @message

        if Input.trigger?(Input::DOWN) && @index < COMMANDS.size - 1
          @index += 1
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @index > 0
          @index -= 1
          refresh_cursor
        elsif Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::C)
          select_command
        end
      end

      private

      def build_windows
        cw = 108
        @command = Window.new(0, 0, cw, COMMANDS.size * LINE_H + Window::BORDER * 2)
        @command.z = 400
        @command.windowskin = @skin
        cc = Bitmap.new(cw - Window::BORDER * 2, COMMANDS.size * LINE_H)
        cc.font.color = Color.new(255, 255, 255, 255)
        COMMANDS.each_with_index do |c, i|
          cc.draw_text 0, i * LINE_H + 2, cc.width, LINE_H, c
        end
        @command.contents = cc
        refresh_cursor

        @status = Window.new(cw, 0, SCREEN_W - cw, SCREEN_H)
        @status.z = 400
        @status.windowskin = @skin
        sc = Bitmap.new(SCREEN_W - cw - Window::BORDER * 2, SCREEN_H - Window::BORDER * 2)
        sc.font.color = Color.new(255, 255, 255, 255)
        @state.party.actors.each_with_index do |a, i|
          y = i * 40
          sc.draw_text 0, y, sc.width, 14, a.name.to_s
          sc.draw_text 0, y + 16, sc.width, 14,
                       "Lv #{a.level}  HP #{a.hp}/#{a.max_hp}  MP #{a.mp}/#{a.max_mp}"
        end
        @status.contents = sc
      end

      def refresh_cursor
        @command.cursor_rect =
          Rect.new(0, @index * LINE_H, @command.contents.width, LINE_H)
      end

      def select_command
        case COMMANDS[@index]
        when "Item"
          @parent.push Scene::ItemMenu.new(@parent, @state)
        when "Equip"
          @parent.push Scene::EquipMenu.new(@parent, @state)
        when "Status"
          @parent.push Scene::StatusMenu.new(@parent, @state)
        when "Save"
          if @state.save_access
            show_message(@parent.save_game(@state) ? "Game saved." : "Save failed.")
          else
            show_message("You cannot save right now.")
          end
        when "End Game"
          show_message("Returning to title...", :end_game)
        else
          show_message("#{COMMANDS[@index]} is not implemented yet.")
        end
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        done = @message[:done]
        close_message
        @parent.return_to_title if done == :end_game
      end

      def show_message(text, done = nil)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win, done: done }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end

    # The field item screen (main menu -> Item). Lists the party's usable
    # medicines with their held counts; picking one either applies it to the
    # whole party (an all-ally item) or asks which ally to use it on (a
    # single-target item). Using an item consumes one and refreshes the list; an
    # item that would have no effect (everyone already full) is reported and not
    # consumed. All decision logic lives in Game::Party (field_items / use_item /
    # item_effective?), which the host harnesses test; this class is the RGSS UI
    # over it, mirroring Scene::Menu's window/cursor/message helpers.
    class ItemMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @mode = :items          # :items list, or :target selection
        @item_index = 0
        @target_index = 0
        @pending_item = nil
        @message = nil
        build_item_window
      end

      def dispose
        close_message
        @item_window.dispose if @item_window
        @target_window.dispose if @target_window
      end

      def update
        return drive_message if @message
        @mode == :target ? update_target : update_items
      end

      private

      # Cached list of [id, count] pairs; invalidated after a use changes counts.
      def items
        @items ||= @state.party.field_items
      end

      def invalidate_items
        @items = nil
      end

      def update_items
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) && @item_index < items.size - 1
          @item_index += 1
          refresh_item_cursor
        elsif Input.trigger?(Input::UP) && @item_index > 0
          @item_index -= 1
          refresh_item_cursor
        elsif Input.trigger?(Input::C)
          choose_item
        end
      end

      def choose_item
        return if items.empty?
        id, = items[@item_index]
        it = @state.party.db_item(id)
        # Only an all-ally medicine skips the target prompt; single-target
        # medicines and skill books (always one actor) ask who to use it on.
        if it && it.scope == 1 && it.type == Game::Party::ITEM_MEDICINE
          apply_item(id, nil)
        else
          @pending_item = id
          @mode = :target
          @target_index = 0
          build_target_window
        end
      end

      def update_target
        party = @state.party.actors
        if Input.trigger?(Input::B)
          leave_target_mode
        elsif Input.trigger?(Input::DOWN) && @target_index < party.size - 1
          @target_index += 1
          refresh_target_cursor
        elsif Input.trigger?(Input::UP) && @target_index > 0
          @target_index -= 1
          refresh_target_cursor
        elsif Input.trigger?(Input::C)
          apply_item(@pending_item, party[@target_index])
        end
      end

      def apply_item(id, actor)
        affected = @state.party.use_item(id, actor)
        if affected.empty?
          show_message("It had no effect.")
        else
          names = affected.map { |a| a.name.to_s }.join(", ")
          show_message("Used on #{names}.", :used)
        end
      end

      def leave_target_mode
        @pending_item = nil
        @mode = :items
        if @target_window
          @target_window.dispose
          @target_window = nil
        end
      end

      # After a successful use, drop back to the item list and rebuild it (the
      # count fell, and a depleted item leaves the list). Keeps the cursor in
      # range when the last item is used up.
      def refresh_after_use
        leave_target_mode
        invalidate_items
        @item_index = items.size - 1 if @item_index >= items.size
        @item_index = 0 if @item_index < 0
        build_item_window
      end

      def build_item_window
        @item_window.dispose if @item_window
        rows = items
        inner_w = SCREEN_W - Window::BORDER * 2
        h = [rows.size, 1].max * LINE_H
        @item_window = Window.new(0, 0, SCREEN_W, h + Window::BORDER * 2)
        @item_window.z = 400
        @item_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        if rows.empty?
          c.draw_text 0, 2, inner_w, LINE_H, "No items"
        else
          rows.each_with_index do |(id, count), i|
            it = @state.party.db_item(id)
            name = (it && it.name.to_s)
            name = "Item #{id}" if name.nil? || name.empty?
            c.draw_text 0, i * LINE_H + 2, inner_w - 40, LINE_H, name
            c.draw_text inner_w - 40, i * LINE_H + 2, 40, LINE_H, ":#{count}"
          end
        end
        @item_window.contents = c
        refresh_item_cursor
      end

      def refresh_item_cursor
        return unless @item_window
        h = items.empty? ? 0 : LINE_H
        @item_window.cursor_rect =
          Rect.new(0, @item_index * LINE_H, @item_window.contents.width, h)
      end

      def build_target_window
        @target_window.dispose if @target_window
        party = @state.party.actors
        inner_w = SCREEN_W - Window::BORDER * 2
        h = party.size * (LINE_H * 2)
        @target_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                    SCREEN_W, h + Window::BORDER * 2)
        @target_window.z = 450
        @target_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        party.each_with_index do |a, i|
          y = i * LINE_H * 2
          c.draw_text 0, y, inner_w, LINE_H, a.name.to_s
          c.draw_text 0, y + LINE_H, inner_w, LINE_H,
                      "HP #{a.hp}/#{a.max_hp}  MP #{a.mp}/#{a.max_mp}"
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      def refresh_target_cursor
        return unless @target_window
        @target_window.cursor_rect =
          Rect.new(0, @target_index * LINE_H * 2, @target_window.contents.width,
                   LINE_H * 2)
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        done = @message[:done]
        close_message
        # A successful use drops back to the (rebuilt) item list; a no-effect use
        # stays in the current mode so the player can pick another target/item.
        refresh_after_use if done == :used
      end

      def show_message(text, done = nil)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win, done: done }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end

    # The field equip screen (main menu -> Equip). Shows one party member's five
    # equipment slots and current stats; LEFT/RIGHT cycle the member. Choosing a
    # slot lists the bag's items that fit it (plus Remove); choosing one equips it
    # -- swapping the previously-worn item back into the bag -- or empties the
    # slot. The bag-aware equip logic is Game::Party#equip_candidates /
    # equip_from_bag / unequip_to_bag (host-tested); this is the RGSS UI over it,
    # mirroring Scene::ItemMenu's helpers. Actor-cycling covers the party; two-
    # handed weapons and dual-wield are later refinements.
    class EquipMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      SLOTS = ["Weapon", "Shield", "Armor", "Helmet", "Accessory"].freeze

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = 0
        @slot_index = 0
        @cand_index = 0
        @mode = :slots          # :slots list, or :items candidate pick
        build_stats_window
        build_slot_window
      end

      def dispose
        @stats_window.dispose if @stats_window
        @slot_window.dispose if @slot_window
        @cand_window.dispose if @cand_window
      end

      def update
        @mode == :items ? update_items : update_slots
      end

      private

      def actor
        @state.party.actors[@actor_index]
      end

      def item_name(id)
        return "-" if id.nil? || id == 0
        it = @state.party.db_item(id)
        n = it && it.name.to_s
        n.nil? || n.empty? ? "Item #{id}" : n
      end

      def update_slots
        party = @state.party.actors
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) && @slot_index < SLOTS.size - 1
          @slot_index += 1
          refresh_slot_cursor
        elsif Input.trigger?(Input::UP) && @slot_index > 0
          @slot_index -= 1
          refresh_slot_cursor
        elsif Input.trigger?(Input::RIGHT) && @actor_index < party.size - 1
          @actor_index += 1
          rebuild_for_actor
        elsif Input.trigger?(Input::LEFT) && @actor_index > 0
          @actor_index -= 1
          rebuild_for_actor
        elsif Input.trigger?(Input::C)
          @cand_index = 0
          @mode = :items
          build_cand_window
        end
      end

      def candidates
        # The slot's fitting bag items, with a leading Remove entry (id 0).
        @candidates ||= [[0, 0]] + @state.party.equip_candidates(@slot_index)
      end

      def update_items
        if Input.trigger?(Input::B)
          leave_items
        elsif Input.trigger?(Input::DOWN) && @cand_index < candidates.size - 1
          @cand_index += 1
          refresh_cand_cursor
        elsif Input.trigger?(Input::UP) && @cand_index > 0
          @cand_index -= 1
          refresh_cand_cursor
        elsif Input.trigger?(Input::C)
          apply_choice
        end
      end

      def apply_choice
        id, = candidates[@cand_index]
        if id == 0
          @state.party.unequip_to_bag(actor, @slot_index)
        else
          @state.party.equip_from_bag(actor, id)
        end
        leave_items
        rebuild_for_actor
      end

      def leave_items
        @candidates = nil
        @mode = :slots
        if @cand_window
          @cand_window.dispose
          @cand_window = nil
        end
      end

      def rebuild_for_actor
        @slot_index = SLOTS.size - 1 if @slot_index >= SLOTS.size
        build_stats_window
        build_slot_window
      end

      def build_stats_window
        @stats_window.dispose if @stats_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = LINE_H * 3
        @stats_window = Window.new(0, 0, SCREEN_W, h + Window::BORDER * 2)
        @stats_window.z = 400
        @stats_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = actor
        c.draw_text 0, 0, inner_w, LINE_H, "#{a.name}  Lv #{a.level}"
        c.draw_text 0, LINE_H, inner_w, LINE_H,
                    "HP #{a.hp}/#{a.max_hp}  MP #{a.mp}/#{a.max_mp}"
        c.draw_text 0, LINE_H * 2, inner_w, LINE_H,
                    "Atk #{a.atk}  Def #{a.def}  Int #{a.int}  Agi #{a.agi}"
        @stats_window.contents = c
      end

      def build_slot_window
        @slot_window.dispose if @slot_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = SLOTS.size * LINE_H
        y = LINE_H * 3 + Window::BORDER * 2
        @slot_window = Window.new(0, y, SCREEN_W, h + Window::BORDER * 2)
        @slot_window.z = 400
        @slot_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        eq = actor.equipment
        SLOTS.each_with_index do |label, i|
          c.draw_text 0, i * LINE_H, 80, LINE_H, label
          c.draw_text 80, i * LINE_H, inner_w - 80, LINE_H, item_name(eq[i])
        end
        @slot_window.contents = c
        refresh_slot_cursor
      end

      def refresh_slot_cursor
        return unless @slot_window
        @slot_window.cursor_rect =
          Rect.new(0, @slot_index * LINE_H, @slot_window.contents.width, LINE_H)
      end

      def build_cand_window
        @cand_window.dispose if @cand_window
        rows = candidates
        inner_w = SCREEN_W - Window::BORDER * 2
        h = rows.size * LINE_H
        @cand_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                  SCREEN_W, h + Window::BORDER * 2)
        @cand_window.z = 450
        @cand_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        rows.each_with_index do |(id, count), i|
          if id == 0
            c.draw_text 0, i * LINE_H, inner_w, LINE_H, "(Remove)"
          else
            c.draw_text 0, i * LINE_H, inner_w - 40, LINE_H, item_name(id)
            c.draw_text inner_w - 40, i * LINE_H, 40, LINE_H, ":#{count}"
          end
        end
        @cand_window.contents = c
        refresh_cand_cursor
      end

      def refresh_cand_cursor
        return unless @cand_window
        @cand_window.cursor_rect =
          Rect.new(0, @cand_index * LINE_H, @cand_window.contents.width, LINE_H)
      end
    end

    # The field status screen (main menu -> Status). Shows one party member's full
    # detail -- name/title, level, EXP and EXP-to-next, HP/MP, the six stats and
    # the five equipment slots; LEFT/RIGHT cycle the member. Read-only, so there
    # is no sub-mode. The EXP-to-next figure is Game::Actor#exp_to_next
    # (host-tested); the rest reads existing accessors.
    class StatusMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      SLOTS = ["Weapon", "Shield", "Armor", "Helmet", "Accessory"].freeze

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = 0
        build_window
      end

      def dispose
        @window.dispose if @window
      end

      def update
        party = @state.party.actors
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::RIGHT) && @actor_index < party.size - 1
          @actor_index += 1
          build_window
        elsif Input.trigger?(Input::LEFT) && @actor_index > 0
          @actor_index -= 1
          build_window
        end
      end

      private

      def item_name(id)
        return "-" if id.nil? || id == 0
        it = @state.party.db_item(id)
        n = it && it.name.to_s
        n.nil? || n.empty? ? "Item #{id}" : n
      end

      def build_window
        @window.dispose if @window
        inner_w = SCREEN_W - Window::BORDER * 2
        @window = Window.new(0, 0, SCREEN_W, SCREEN_H)
        @window.z = 400
        @window.windowskin = @skin
        c = Bitmap.new(inner_w, SCREEN_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        a = @state.party.actors[@actor_index]
        title = a.title.to_s
        header = title.empty? ? a.name.to_s : "#{a.name}  #{title}"
        nxt = a.exp_to_next
        lines = [
          header,
          "Lv #{a.level}    EXP #{a.exp}    Next #{nxt.nil? ? '---' : nxt}",
          "HP #{a.hp}/#{a.max_hp}    MP #{a.mp}/#{a.max_mp}",
          "Atk #{a.atk}   Def #{a.def}   Int #{a.int}   Agi #{a.agi}",
          "",
        ]
        eqp = a.equipment
        SLOTS.each_with_index { |label, i| lines.push("#{label}: #{item_name(eqp[i])}") }
        lines.each_with_index do |line, i|
          c.draw_text 0, i * LINE_H, inner_w, LINE_H, line
        end
        @window.contents = c
      end
    end

    class Title < Base
      # Height of one selectable line. The shinonome font is 12px tall; the
      # extra space gives a little breathing room between entries.
      LINE_HEIGHT = 16
      # draw_text is top-aligned, so nudge the 12px glyphs down to sit centred
      # within the line (and the selection cursor).
      TEXT_PAD_Y = (LINE_HEIGHT - 12) / 2

      def initialize parent
        super parent

        @title = Sprite.new
        @title.bitmap = Bitmap.new "Title/#{db.system.title}"

        @menu_items =
          [db.term.new_game, db.term.continue, db.term.shutdown].map(&:to_s)
        @selected_index = 0

        # Size the contents to the widest menu label (plus a small right pad).
        measure = Bitmap.new 1, 1
        text_w = @menu_items.map { |t| measure.text_size(t).width }.max
        content_w = text_w + 8
        content_h = @menu_items.length * LINE_HEIGHT

        window_width = content_w + Window::BORDER * 2
        window_height = content_h + Window::BORDER * 2

        # Centre the window horizontally, sitting in the lower third of the
        # screen like the reference title layout.
        window_x = (WIDTH - window_width) / 2
        window_y = 160

        @window = Window.new window_x, window_y, window_width, window_height
        @window.windowskin = load_windowskin

        # Render the (unchanging) menu labels once. White text reads clearly on
        # the dark window background.
        contents = Bitmap.new content_w, content_h
        contents.font.color = Color.new(255, 255, 255, 255)
        @menu_items.each_with_index do |item, index|
          contents.draw_text 0, index * LINE_HEIGHT + TEXT_PAD_Y, content_w,
                             LINE_HEIGHT, item
        end
        @window.contents = contents

        refresh_cursor
      end

      def update
        if Input.trigger?(Input::DOWN) && @selected_index < @menu_items.length - 1
          @selected_index += 1
          play_cursor_se
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @selected_index > 0
          @selected_index -= 1
          play_cursor_se
          refresh_cursor
        end

        if Input.trigger?(Input::C)  # C is usually the confirm button (Enter/Z)
          case @selected_index
          when 0  # New Game
            parent.start_new_game
          when 1  # Continue
            parent.continue_game
          when 2  # Shutdown
            exit
          end
        end

        @window.update
      end

      def dispose
        @title.dispose
        @window.dispose
      end

      private

      # Load the System/ windowskin declared in the database. Returns nil when
      # it is missing so the Window falls back to a plain panel instead of
      # crashing.
      def load_windowskin
        name = db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      def refresh_cursor
        @window.cursor_rect =
          Rect.new(0, @selected_index * LINE_HEIGHT, @window.contents.width,
                   LINE_HEIGHT)
      end

      # Play the database's "cursor move" sound effect (System > cursor SE) when
      # the menu selection changes. A no-op when the game defines no cursor SE,
      # the file is missing, or no audio backend is installed.
      def play_cursor_se
        se = db.system.cursor_se
        return unless se
        name = se.file
        return if name.nil? || name.empty?
        Audio.se_play name, se.volume, se.pitch
      rescue StandardError => e
        $stderr.puts "[RGSS] cursor SE playback failed: #{e.message}"
      end
    end
  end

  attr_reader :db, :map_tree

  def initialize args
    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    @map_tree = LCF::MapTree.new File.open "#{GAME_DIR}/RPG_RT.lmt"
    @scenes = []
    push Scene::Title.new self
  end

  def push scene
    @scenes.push scene
  end

  # Pop the top scene (e.g. closing the menu), disposing it. The base scene is
  # never popped so the loop always has something to update.
  def pop
    return if @scenes.size <= 1
    scene = @scenes.pop
    scene.dispose if scene.respond_to?(:dispose)
  end

  # Tear down all scenes and return to a fresh title screen.
  def return_to_title
    @scenes.each { |s| s.dispose if s.respond_to?(:dispose) }
    @scenes = [Scene::Title.new(self)]
  end

  # Load one map (.lmu) by id. Map files are named Map0001.lmu, Map0002.lmu, ...
  def load_map id
    num = id.to_s
    num = "0#{num}" while num.size < 4
    path = "#{GAME_DIR}/Map#{num}.lmu"
    Game::Map.new id, LCF::MapUnit.new(File.open(path))
  end

  # New Game: build the initial party from the database, read the start
  # position from the map tree, load the starting map and enter the map scene.
  # The map/player renderer is not wired up yet, so this establishes the running
  # game state and transitions scenes without drawing the map.
  def start_new_game
    init = map_tree.initial
    state = Game::State.new Game::Party.new(@db), init.initial_map_id,
                            init.initial_x, init.initial_y
    state.map = load_map state.map_id
    # Build the play scene first; only tear down the title once it succeeds so a
    # data problem leaves the title intact instead of a blank screen.
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
  rescue StandardError => e
    # Never let a data problem crash the title screen; report and stay put.
    $stderr.puts "[RPG2k] Failed to start new game: #{e.message}"
  end

  # Save file path for a slot. Saving still uses our own portable Marshal
  # format, but Continue can also load a genuine editor Save<N>.lsd (see
  # continue_game) via the now-modelled LCF save schema.
  def save_path slot = 1
    "#{GAME_DIR}/save#{slot}.mrb"
  end

  # Path of an editor save slot, e.g. Save01.lsd. mruby here bundles no sprintf,
  # so the two-digit slot is zero-padded by hand.
  def lsd_path slot = 1
    n = slot < 10 ? "0#{slot}" : "#{slot}"
    "#{GAME_DIR}/Save#{n}.lsd"
  end

  # The lowest-numbered editor save that exists (RPG2000 uses slots 1..15), or
  # nil when there is none.
  def existing_lsd
    (1..15).each do |slot|
      p = lsd_path(slot)
      return p if File.exist?(p)
    end
    nil
  end

  def save_exists? slot = 1
    File.exist?(save_path(slot)) || !existing_lsd.nil?
  rescue StandardError => e
    $stderr.puts "[RPG2k] save-slot check failed for slot #{slot}: #{e.message}"
    false
  end

  # Persist the running game state to a slot. Our own portable Marshal dump is
  # the authoritative save (it still carries the two fields the .lsd export does
  # not model -- the game timer and per-actor name/title overrides for non-leader
  # members). Alongside it we also export a near-parity editor Save<slot>.lsd via
  # State#to_lsd, so the slot is readable by real RPG_RT/EasyRPG tooling. The
  # export is best-effort: a failure there is logged but never fails the save.
  def save_game state, slot = 1
    data = Marshal.dump state.to_h
    File.open(save_path(slot), "wb") { |f| f.write data }
    export_lsd(state, slot)
    true
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to save: #{e.message}"
    false
  end

  # Write a real Save<slot>.lsd next to the Marshal save. Best-effort: any error
  # is logged and swallowed so it cannot break the primary save.
  def export_lsd state, slot = 1
    state.to_lsd.save_to(lsd_path(slot))
  rescue StandardError => e
    $stderr.puts "[RPG2k] .lsd export failed for slot #{slot}: #{e.message}"
  end

  # Continue: resume a saved game and switch to its map. Our own Marshal save is
  # preferred when present -- it is the full-fidelity record we wrote (save_game
  # also exports a near-parity Save<slot>.lsd beside it, which would still drop
  # the timer and non-leader actor name/title overrides if loaded instead). A
  # genuine editor Save<N>.lsd is the fallback, so a real save dropped into the
  # game dir (with no Marshal save) still resumes through the LCF save schema.
  # Warns and stays on the title when there is nothing to load.
  def continue_game
    if File.exist?(save_path)
      data = File.open(save_path, "rb") { |f| f.read }
      state = Game::State.load(@db, Marshal.load(data))
    elsif (lsd = existing_lsd)
      state = Game::State.from_lsd(@db, LCF::SaveData.new(File.open(lsd, "rb")))
    else
      RGSS.warn_stub "Continue (no save data found)"
      return
    end
    state.map = load_map state.map_id
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to continue: #{e.message}"
  end

  def main_loop
    RGSS::Profiler.frame do
      RGSS::Profiler.section("scene.update") { @scenes.last.update }
      RGSS::Profiler.section("input.update") { Input.update }
      Graphics.update
    end
  end

  def start
    loop do
      main_loop
    end
  rescue RGSS::Timeout
  end
end
