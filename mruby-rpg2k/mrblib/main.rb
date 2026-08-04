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
        [@lower_sprite, @upper_sprite, @player_sprite].each do |s|
          s.dispose if s
        end
        @chipset_bmp.dispose if @chipset_bmp
      end

      def update
        @state.tick_timer # the timer keeps counting during events too
        @state.screen.update # screen tint progresses every frame, even in events
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
        Game::ChipSet.new(@db, @map.chipset_id)
      rescue StandardError => e
        $stderr.puts "[RPG2k] chipset load failed, tiles treated as passable: #{e.message}"
        nil
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
          # Rendering state: the page's static graphic fields plus a live walk
          # animation phase / counter and a "stepping" flag (see step_event).
          layer: page_layer(page), translucent: page_translucent(page),
          anim_type: page_anim_type(page), base_dir: dir,
          base_pattern: page_pattern(page), anim_phase: 0, anim_count: 0,
          moving: false }
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
        apply_erase_request(it, p[:event])
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

      # Advance each event's walk-animation phase once per frame. An event
      # "moves" for animation purposes when it has autonomous movement (a
      # non-stationary move type) or a forced route in progress; such events —
      # and any continuous/spin animation type — cycle their walk frames on the
      # ANIM_FRAME_PERIOD cadence, while a stationary, non-continuous event rests
      # on its page pose. Game::EventGraphic.frame reads @moving / @anim_phase to
      # pick the drawn column.
      def animate_events
        @events.each { |e| animate_event(e) }
      end

      def animate_event(e)
        type = e[:anim_type]
        walking = event_walking?(e)
        e[:moving] = walking
        return unless Game::EventGraphic.animated?(type)
        return unless walking || Game::EventGraphic.continuous?(type)
        e[:anim_count] += 1
        return if e[:anim_count] < ANIM_FRAME_PERIOD
        e[:anim_count] = 0
        e[:anim_phase] = (e[:anim_phase] + 1) % Game::EventGraphic::WALK_COLUMNS.size
      end

      # Whether an event is currently in motion (so it shows its walk cycle
      # rather than a standing pose): it has a forced route, or its page gives it
      # an autonomous, non-stationary move type.
      def event_walking?(e)
        return true if e[:forced_route]
        mt = e[:move_type]
        !mt.nil? && mt != Game::MoveType::STATIONARY
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
      def reoccupy(e, ox, oy)
        @event_tiles.delete([ox, oy]) if @event_tiles[[ox, oy]].equal?(e)
        @event_tiles[[e[:char].x, e[:char].y]] = e
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
        leader = @state.party.leader
        @player_sprite.visible = !(leader && leader.transparent)
        @player_bmp.clear unless @charset
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
          when :wait then drive_wait
          when :teleport then perform_teleport(@interpreter.teleport)
          when :movement then @interpreter.resume if step_forced_movement
          when :screen then @interpreter.resume unless @state.screen.busy?
          end
        else
          @interpreter.update
          apply_move_requests(@interpreter, @active_event)
          apply_erase_request(@interpreter, @active_event)
          apply_halt_request(@interpreter)
          apply_graphic_change(@interpreter)
        end
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
            c.font.color = message_color(seg[:color])
            c.draw_text x, y, right - x, MSG_LINE_H, seg[:text]
            x += c.text_size(seg[:text]).width
          end
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
        cam_x = Game.camera_offset(px + TILE / 2, SCREEN_W, @map.width * TILE)
        cam_y = Game.camera_offset(py + TILE / 2, SCREEN_H, @map.height * TILE)
        # Screen shake slides the whole view horizontally (the player moves with
        # the map, so the entire screen shakes); the map edge may show a sliver
        # of void during the shake, which is fine.
        cam_x -= @state.screen.shake_offset

        draw_layers cam_x, cam_y

        @player_sprite.x = px - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        @player_sprite.y = py - cam_y - (Game::CharSet::HEIGHT - TILE)
        draw_player_frame
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
        dx = e[:char].x * TILE - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        dy = e[:char].y * TILE - cam_y - (Game::CharSet::HEIGHT - TILE)
        bmp.blt dx, dy, charset, Rect.new(sx, sy, sw, sh), opacity
      end

      # Blit an event whose graphic is a chipset tile (16x16), aligned to its
      # tile. Needs the chipset image; with none loaded (colour-block fallback)
      # the tile event is skipped.
      def draw_event_tile(e, bmp, cam_x, cam_y, opacity)
        return unless @chipset_bmp
        sx, sy, sw, sh = Game::ChipsetLayout.event_tile_rect(e[:char].graphic_index)
        dx = e[:char].x * TILE - cam_x
        dy = e[:char].y * TILE - cam_y
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

  # Persist the running game state to a slot.
  def save_game state, slot = 1
    data = Marshal.dump state.to_h
    File.open(save_path(slot), "wb") { |f| f.write data }
    true
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to save: #{e.message}"
    false
  end

  # Continue: resume a saved game and switch to its map. A genuine editor
  # Save<N>.lsd is loaded through the LCF save schema when present (so a real
  # save dropped into the game dir resumes correctly); otherwise our own Marshal
  # save is used. Warns and stays on the title when there is nothing to load.
  def continue_game
    lsd = existing_lsd
    if lsd
      state = Game::State.from_lsd(@db, LCF::SaveData.new(File.open(lsd, "rb")))
    elsif File.exist?(save_path)
      data = File.open(save_path, "rb") { |f| f.read }
      state = Game::State.load(@db, Marshal.load(data))
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
