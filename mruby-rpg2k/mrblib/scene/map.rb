class RPG2k
  module Scene
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
      # Sub-pixel movement model. RPG2000's Move Speed (1..6) is no longer dead:
      # the per-frame slide advance for a character of internal move_speed `s`
      # (real RPG_RT's own 1-indexed Move Speed minus 1; see #page_move_speed
      # for where that conversion happens) is `1 << s` quarter-tile units (a
      # full tile is SLIDE_UNITS), so frames-per-tile is 64 / (1 << s) = 64,
      # 32, 16, 8, 4, 2 for s = 0..5 -- confirmed by both #walk_slide_step's
      # own check ("Move Speed is no longer dead", scripts/rpg2k_scene_check.rb:
      # eq 1/2/8/32 for s = 0/1/3/5) and, independently, a genuine RPG_RT.exe
      # wine probe (cycle #180: Nepheshel `Map0089.lmu` event 25's own s = 0
      # approach crossed each tile in roughly 50-55 observed captured frames
      # against this 64-frame/tile prediction, not the 32 the old text here
      # claimed -- close enough, given ~57fps sampling of a ~60fps target, to
      # rule out 32 outright). The *hero*'s own default internal move_speed is
      # 3 (real RPG_RT's Game_Player ctor default, Move Speed 4), giving 8
      # frames/tile -- identical to the old hardcoded 2px/frame, so the
      # on-foot baseline is untouched. An ordinary *event*'s default page Move
      # Speed is real 3 ("Normal", internal 2), giving 16 frames/tile -- half
      # the hero's own rate, and deliberately so (see the "converts from
      # RPG_RT's real 1..6 scale, not fed through raw" check) -- so only the
      # previously-ignored non-default speeds (and the SPEED_UP/SPEED_DOWN
      # move-route commands) now take effect for both. See docs/TODO.md "Move
      # Speed is dead code" for the original fix this replaced.
      SLIDE_UNITS = TILE * 4   # quarter-tile units per tile (64)

      # Jump slide advance (quarter-tile units/frame) by move_speed, port 0..5.
      # Ported from a reference implementation's jump-speed table (0-indexed
      # by the port's own real-minus-1 offset), NOT independently confirmed
      # against genuine RPG_RT under wine; ÷4 into quarter-tile units, and the
      # top speed clamps to the last.
      JUMP_SLIDE_STEP = { 0 => 2, 1 => 3, 2 => 4, 3 => 6, 4 => 8, 5 => 16 }.freeze

      # Walk-animation frame cadence by move_speed, port 0..5. Ported from a
      # reference implementation's stationary-animation frame table
      # (0-indexed by the same real-minus-1 offset), NOT independently
      # confirmed against genuine RPG_RT under wine; the default (2) keeps
      # the prior 6-frame period, so existing animation pacing is unchanged.
      # Governs an event while it is actually sliding between tiles.
      ANIM_STATIONARY_FRAMES = { 0 => 12, 1 => 10, 2 => 8, 3 => 6, 4 => 5, 5 => 4 }.freeze

      # A Continuous/Fixed-Continuous event's own idle cadence -- slower than
      # #ANIM_STATIONARY_FRAMES, not the same table reused. Ported from a
      # reference implementation, NOT independently confirmed against genuine
      # RPG_RT under wine: its continuous-animation frame table gives
      # `limits[] = {16,12,10,8,7,6}`, and its animation-update logic blends
      # this with the stationary table while genuinely moving too (advance
      # once the continuous limit is reached, or once the stationary limit is
      # reached while stopped).
      # The dominant, most visible effect -- and the one this fixes -- is
      # that an idle Continuous/Fixed-Continuous event (a torch, a waterwheel,
      # an "always animates" NPC) cycles noticeably slower than one that is
      # actually walking, not on the identical cadence.
      ANIM_CONTINUOUS_FRAMES = { 0 => 16, 1 => 12, 2 => 10, 3 => 8, 4 => 7, 5 => 6 }.freeze

      # A Spin-type event's own facing-rotation cadence, slower again. Ported
      # from a reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its spin-animation frame table gives
      # `limits[] = {24,16,12,8,6,4}` -- the animation-update logic's spinning
      # branch reads this and only this table, unconditionally, whether the
      # event is moving or not.
      ANIM_SPIN_FRAMES = { 0 => 24, 1 => 16, 2 => 12, 3 => 8, 4 => 6, 5 => 4 }.freeze

      # Clamp a (possibly out-of-range) internal move_speed to the port's own
      # 0..5 scale -- the real RPG2000 Move Speed field is 1..6 (see
      # #page_move_speed), one notch above this internal scale. Ported from a
      # reference implementation's own move-speed clamp, NOT independently
      # confirmed against genuine RPG_RT under wine.
      def clamp_speed(s); v = s.to_i; v < 0 ? 0 : v > 5 ? 5 : v; end

      # Quarter-tile units advanced per frame while walking at `s`.
      def walk_slide_step(s); 1 << clamp_speed(s); end

      # Quarter-tile units advanced per frame while jumping at `s`.
      def jump_slide_step(s); JUMP_SLIDE_STEP[clamp_speed(s)] || 6; end

      # Walk-animation period (frames per phase) at `s`, while actually sliding.
      def anim_frame_period(s); ANIM_STATIONARY_FRAMES[clamp_speed(s)] || 6; end

      # Idle-animation period for a Continuous/Fixed-Continuous event standing
      # still at `s`.
      def anim_continuous_period(s); ANIM_CONTINUOUS_FRAMES[clamp_speed(s)] || 8; end

      # Facing-rotation period for a Spin-type event at `s`.
      def anim_spin_period(s); ANIM_SPIN_FRAMES[clamp_speed(s)] || 12; end

      # Advance a slide by `step` quarter-tile units. Folds the whole TILE-units
      # into `move_count` (the integer, display-side progress) and returns the new
      # move_count, the kept sub-pixel remainder, and whether the slide is still
      # in progress (move_count < TILE). Callers store the returned move_count and
      # remainder back into the entity (event hash or instance variable).
      def advance_slide(move_count, frac, step)
        frac = frac + step
        whole = frac >> 2
        if whole > 0
          frac = frac - (whole << 2)
          move_count = [move_count + whole, TILE].min
        end
        [move_count, frac, move_count < TILE]
      end

      # The screen flash a step's slip damage fires: a brief red pulse, so the
      # drain is not silent on a map that shows no HP. Given as the Game::Screen
      # flash arguments (r, g, b, power, frames) on the 0..255 scale, the same
      # one the battle-animation flashes reach by scaling their 0..31 database
      # colours up by 8.
      STEP_DAMAGE_FLASH = [31 * 8, 10 * 8, 10 * 8, 20 * 8, 6].freeze

      # Where the map viewport sits against the sprites drawn outside it. Under
      # the picture layer (250), so pictures, the message window and the
      # weather / flash / fade overlays all draw over a tinted map.
      MAP_VIEWPORT_Z = 100

      # Frames waited between autonomous event steps, keyed by RPG2000 move
      # frequency (1 slowest .. 8 fastest). Placeholder pacing while events are
      # drawn as markers (no per-step pixel interpolation yet).
      EVENT_MOVE_DELAY = { 1 => 96, 2 => 64, 3 => 40, 4 => 24,
                           5 => 12, 6 => 6, 7 => 3, 8 => 1 }.freeze

      # (Walk-animation cadence is move_speed-dependent, and split by whether
      # an event is sliding, idling Continuous, or Spinning; see
      # ANIM_STATIONARY_FRAMES / ANIM_CONTINUOUS_FRAMES / ANIM_SPIN_FRAMES and
      # #anim_frame_period / #anim_continuous_period / #anim_spin_period
      # below.)

      # Event-page start conditions (the page `trigger` field): how the event's
      # command list is set off.
      TRIGGER_ACTION       = 0 # player presses the action button facing it
      TRIGGER_PLAYER_TOUCH = 1 # player walks into it
      TRIGGER_EVENT_TOUCH  = 2 # it walks into the player
      TRIGGER_AUTO_START   = 3 # runs automatically once on the map
      TRIGGER_PARALLEL     = 4 # runs continuously in the background

      # Event-page priority type (the page `layer` field): where the event
      # draws relative to normal characters, and — RPG_RT ties the two together
      # — which of them it collides with. The hero (and a vehicle) only ever
      # collides with a LAYER_SAME event, since the hero's own layer is
      # always effectively LAYER_SAME — a "below"/"above characters" event is
      # a decoration the hero walks straight through (see #passable?). Two
      # *events* collide only when their layers match exactly, whatever that
      # layer is — two below-characters events collide with each other same
      # as two same-characters ones do, but a below/above pair passes
      # through each other (see #char_passable?'s fuller citation).
      LAYER_BELOW = 0
      LAYER_SAME  = 1
      LAYER_ABOVE = 2

      # #blockers_at's answer for a tile with nothing on it -- a single frozen
      # empty array so an empty tile costs no allocation.
      NO_BLOCKERS = [].freeze

      # Move Event (Set Move Route) target ids: the player, the three vehicles
      # and "this event" (the event running the command). Any other id is a map
      # event id.
      MOVE_TARGET_PLAYER  = 10001
      MOVE_TARGET_BOAT    = 10002
      MOVE_TARGET_SHIP    = 10003
      MOVE_TARGET_AIRSHIP = 10004
      MOVE_TARGET_THIS    = 10005

      # `apply_access:` is false only for a Continue resume (see main.rb's
      # continue_game) -- every other caller (a fresh New Game, and every
      # ordinary map load besides) wants the default true. Re-deriving
      # save/teleport/escape access from the map tree here unconditionally
      # was wrong for Continue specifically: verified under wine against a
      # genuine RPG_RT.exe, whose Save command opened the real file-select
      # screen on a map the tree itself flags Save-forbidden, because the
      # save being resumed had that access explicitly granted (chunk 101's
      # save_allowed) by a prior Change Save Access command -- exactly the
      # "an event command override persists for the rest of that map's
      # visit" case #apply_map_access's own comment already describes, which
      # a Continue is still inside the middle of, not a fresh entry to. Every
      # other call site *is* a fresh entry (New Game's first map, and every
      # Transfer Player / Teleport via #perform_teleport's own separate call)
      # and keeps re-deriving as before.
      # A name -> Bitmap cache bounded by estimated decoded pixel bytes rather
      # than entry count (a CharSet and a System2 gauge sheet differ by an
      # order of magnitude in size), evicting least-recently-used entries once
      # over budget. Drop-in for the plain Hash #cached_bitmap used to take:
      # implements the same #key?/#[]/#[]= surface (including tests that poke
      # a cache directly, e.g. `@animation_cache['GhostAnim'] = nil` to
      # simulate a poisoned/missing graphic), so #cached_bitmap itself needed
      # no changes.
      class LRUBitmapCache
        def initialize(capacity_bytes)
          @capacity_bytes = capacity_bytes
          @entries = {} # key => value, oldest (least-recently-used) first
          @bytes = 0
        end

        def key?(key)
          @entries.key?(key)
        end

        # Return a cached value (nil for a poisoned/failed-load entry, same as
        # a plain Hash) and mark it most-recently-used. Callers check #key?
        # first, exactly as they did against the plain Hash, so a genuine miss
        # is never confused with a cached nil here.
        def [] key
          return nil unless @entries.key?(key)
          v = @entries.delete(key)
          @entries[key] = v
          v
        end

        def []= key, value
          @bytes -= bitmap_bytes(@entries.delete(key)) if @entries.key?(key)
          @entries[key] = value
          @bytes += bitmap_bytes(value)
          evict_lru_until_within_budget
          value
        end

        private

        # width * height * 4 -- every Bitmap this build decodes from a file is
        # ARGB8888 (mruby-rgss/src/lib.cxx's file-loading Bitmap.new overload
        # always passes LV_COLOR_FORMAT_ARGB8888), so this is the buffer size
        # the native Bitmap struct actually allocates, not a guess. 0 for a
        # poisoned (nil) or otherwise non-Bitmap entry -- it costs nothing and
        # so creates no eviction pressure on its own.
        def bitmap_bytes(v)
          return 0 unless v.respond_to?(:width) && v.respond_to?(:height)
          v.width * v.height * 4
        end

        # Evict oldest-first until back within budget. Stops at one remaining
        # entry even if that entry alone exceeds the budget: the entry just
        # inserted is always the newest (last) one, so this never evicts what
        # the caller is about to use, and never busy-loops reloading the same
        # single oversized graphic every time it's requested.
        def evict_lru_until_within_budget
          while @bytes > @capacity_bytes && @entries.size > 1
            oldest_key = nil
            @entries.each_key { |k| oldest_key = k; break }
            @bytes -= bitmap_bytes(@entries.delete(oldest_key))
          end
        end
      end

      # Per-category caps for the named-graphic caches below (see #initialize),
      # in estimated decoded bytes (see LRUBitmapCache#bitmap_bytes) -- a
      # conservative first cut, not a measured budget: this build's only
      # native-heap instrumentation (sceKernelTotalFreeMemSize/MaxFreeMemSize,
      # app/psp/main.cxx's `free`/`maxfree` fields) reported the exact same
      # value across every heartbeat of a full psp-smoke-game run regardless
      # of arena_used moving by megabytes, so it cannot currently validate
      # (or rule out) whatever headroom is actually available. Each constant
      # is independent and trivially raised later once real measurement
      # exists; sized for now to comfortably outlast one screen's working set
      # (e.g. a troop's handful of distinct battler graphics) while still
      # bounding a long session's worth of distinct maps/battles from
      # retaining every graphic they ever showed.
      CHARSET_CACHE_BYTES = 1_000_000
      PICTURE_CACHE_BYTES = 1_000_000
      BACKDROP_CACHE_BYTES = 500_000
      MONSTER_CACHE_BYTES = 1_500_000
      ANIMATION_CACHE_BYTES = 1_500_000
      BATTLECHARSET_CACHE_BYTES = 500_000
      SYSTEM2_CACHE_BYTES = 250_000

      # A scaled-down budget never shrinks past base/this, so a cache always
      # keeps some working set (one still-oversized entry, per
      # LRUBitmapCache#evict_lru_until_within_budget, would otherwise never
      # evict anything else at all, and the picture tone cache -- see
      # #toned_picture_src -- would stop caching entirely).
      CONSTRAINED_SCALE_FLOOR_DIVISOR = 8

      # Scale a named-graphic cache's byte budget (or the picture tone
      # cache's entry count, see #toned_picture_src) down when --render_fps
      # (src/main.cxx) signals a constrained device: a target picked for a
      # low real-time render rate -- the PSP/Wio-class ports this flag exists
      # for -- is RAM-constrained too, so it is worth evicting decoded
      # graphics more eagerly (a re-decode-on-next-use cost) to hold a
      # smaller working set. Scaled by the fps ratio rather than a single
      # on/off cut -- --render_fps=30 roughly halves a budget, 10 roughly
      # sixths it -- and floored at CONSTRAINED_SCALE_FLOOR_DIVISOR so a very
      # low setting still leaves a small working set rather than none. An
      # ordinary run (render_fps 60, the default) always returns base
      # unchanged.
      #
      # RGSS::Graphics.render_fps rescued rather than called bare: the
      # host-side scene checks (scripts/rpg2k_scene_check.rb) load this file
      # under plain CRuby against their own minimal Graphics stub, which has
      # no render_fps method -- same "missing means uncapped" fallback
      # RGSS::Graphics.render_fps itself uses for the native constant it
      # reads.
      def constrained_scale(base)
        fps = RGSS::Graphics.render_fps
        return base if fps >= 60
        scaled = base * fps / 60
        floor = base / CONSTRAINED_SCALE_FLOOR_DIVISOR
        scaled > floor ? scaled : floor
      rescue StandardError
        base
      end

      def initialize parent, state, apply_access: true
        super parent
        @state = state
        # Named graphics loaded and memoized on demand -- see #cached_bitmap.
        # One cache per graphic category (rather than a single cache keyed by
        # a [kind, name] tuple) so each material's entries stay a plain
        # name -> Bitmap lookup and one category's keys can never collide
        # with another's. Each is a bounded LRUBitmapCache, not a plain Hash:
        # a long session that visits many maps/battles referencing many
        # uniquely-named graphics used to retain every one of them for the
        # rest of the run (nothing here ever cleared these hashes, including
        # #perform_teleport's otherwise-thorough per-visit reset just below);
        # now only the most-recently-used ones survive past each cache's own
        # byte budget, and anything evicted is simply reloaded (and re-cached)
        # the next time its name comes up.
        @charset_cache = LRUBitmapCache.new(constrained_scale(CHARSET_CACHE_BYTES))
                               # CharSet/<name> -- event graphics and the
                               # party leader's own graphic share this, since
                               # both load the same files.
        @picture_cache = LRUBitmapCache.new(constrained_scale(PICTURE_CACHE_BYTES))
                               # Picture/<name>, keyed by [name, transparent]
        @backdrop_cache = LRUBitmapCache.new(constrained_scale(BACKDROP_CACHE_BYTES))
                               # Backdrop/<name> (battle background)
        @monster_cache = LRUBitmapCache.new(constrained_scale(MONSTER_CACHE_BYTES))
                               # Monster/<name> (battler graphics)
        @animation_cache = LRUBitmapCache.new(constrained_scale(ANIMATION_CACHE_BYTES))
                               # Battle/<name> (battle animation sheets)
        # Toned copies of individual animation cells, keyed by sheet identity
        # + cell id + tone (see #toned_animation_cell_src) -- the same
        # per-content-key cache shape @picture_tone_cache uses below, sized
        # per cell (96x96) rather than per whole picture since only one
        # 96x96 square of a shared sheet is ever toned at a time.
        @animation_tone_cache = {}
        @battlecharset_cache =
          LRUBitmapCache.new(constrained_scale(BATTLECHARSET_CACHE_BYTES))
                               # BattleCharSet/<name> (RPG2003 actor battler sprites)
        @system2_cache = LRUBitmapCache.new(constrained_scale(SYSTEM2_CACHE_BYTES))
                               # System2/<name> (RPG2003 gauge card sprite sheet)
        apply_map_access if apply_access
        # Same Continue-only split as #apply_map_access just above: a fresh
        # map entry (New Game, or any Transfer Player/Teleport, which
        # #perform_teleport already calls #play_map_bgm for separately)
        # recomputes BGM from the map tree, but a Continue resumes a state
        # that already carries its own #current_bgm (restored by
        # Game::State.load/.from_lsd from the save) -- see #resume_saved_bgm.
        if apply_access
          play_map_bgm
        else
          resume_saved_bgm
        end
        @map = state.map
        @chipset = build_chipset
        @chipset_bmp = load_chipset_graphic
        @charset = load_charset
        @windowskin = load_windowskin
        @interpreter = Game::Interpreter.new(@state)
        # Whether the last message window shown on this map visit resolved to
        # the top position -- what #draw_timer's own bottom-edge-avoidance
        # reads, sticky until #open_message next changes it or this map visit
        # ends (see #perform_teleport's identical reset). False on a fresh
        # visit, ported from a reference implementation's own message-window
        # top-position threshold before any message has opened yet -- NOT
        # independently confirmed against genuine RPG_RT under wine.
        @message_window_top = false
        @started_auto = {}
        @started_common = {}
        # Guarded auto-starts (see #page_guarded -- a harness gating its own
        # one-shot process; never a real game page, which gates itself through
        # its page conditions) fire at most once per visit -- tracked here,
        # reset only on a genuine map load, so they do not re-fire every frame
        # the way an ungated auto-start does under Scene::Map#update's per-frame
        # @started_auto clear.
        @auto_once = {}
        @auto_once_common = {}
        @common = Game::CommonEvent.load(@db)
        # Deterministic RNG (Kernel#rand exists but is unseeded, and these runs
        # are diffed against the genuine runtime) and the adapter that lets move
        # routes / autonomous movement query the map.
        @rng = Game::Rng.new(0x2000)
        @world = MapWorld.new(self, @rng)
        # One VehicleWorld per type, wrapping #vehicle_passable? instead of the
        # hero's own on-foot #char_passable? -- see #force_vehicle_route.
        @vehicle_worlds = Game::Vehicle::TYPES.each_with_object({}) do |type, h|
          h[type] = VehicleWorld.new(self, @rng, type)
        end
        # Erased events, and the state revision the active pages were chosen at.
        @erased_events = {}
        # An erased event's tile at the moment it was erased (yado.tk: "Get
        # Event ID at Location" still resolves an id there, unlike collision
        # and drawing, which #erase_event already drops it from). Keyed
        # separately from @erased_events since this needs the position, not
        # just the flag.
        @erased_event_positions = {}
        # Every event's last-known tile this visit, live or not -- unlike
        # @erased_event_positions (frozen once, at erasure) this is kept live
        # for as long as an event has a Game::Character, and seeded from its
        # raw map-data placement the first time #build_events ever sees its
        # id, so an event whose *very first* selected page fails its
        # conditions still has a position to answer from. See #event_id_at.
        @event_last_position = {}
        # Tiles #warn_stale_terrain has already reported this visit -- see
        # #terrain_row_at.
        @warned_stale_terrain = {}
        # Per-event condition ids are per map: event ids repeat across maps,
        # and a memo left from the previous visit would answer for the wrong
        # pages (see #page_condition_ids).
        @page_condition_ids = {}
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        @message = nil
        @inn_window = nil
        @inn_bgm_started = false
        @inn_fading_out = false
        @inn_interp = nil
        @shop = nil
        # The running fight, or nil between encounters -- see Scene::Battle.
        @battle = nil
        @name_ui = nil
        @wait_timer = nil
        @anim_wait = nil
        @map_animation = nil
        # Which interpreter (the foreground event, or a parallel process) is
        # waiting on @map_animation / @anim_wait right now -- see
        # #drive_map_animation, so the right one gets #resume'd, not always
        # the foreground @interpreter.
        @map_animation_interp = nil
        # One digit-cell sprite per timer (RPG2003 has two); built lazily when
        # first shown (see #draw_timer).
        @timer_sprites = [nil, nil]
        @choice_index = 0
        # The map event whose commands the foreground interpreter is running, so
        # a Move Event targeting "this event" can be resolved. nil for common
        # events (which have no map character).
        @active_event = nil
        # Resume whatever event was mid-execution in the shared foreground
        # interpreter at save time, if the state we were built from carries
        # one -- see #restore_foreground_event_exec's own comment. Placed
        # here, after @active_event's own plain-nil init just above (which
        # would otherwise wipe out a restore run any earlier) and after
        # #build_events/#build_resolver already ran, but before anything
        # else in this method or its caller gets a chance to start a
        # *different* event on the one shared interpreter.
        restore_foreground_event_exec
        # A forced move route applied to the player by a Move Event, with its own
        # character mirror and step timer; nil when the player moves by input.
        @player_route = nil
        @player_char = nil
        @player_route_timer = 0
        # Through Mode set on the player by a forced route (Set Move Route's
        # Through Mode: Begin/End), which -- like the genuine runtime -- is a
        # standing property of the hero, not scoped to the route that set it: it
        # keeps affecting ordinary input-driven walking once the route ends,
        # however that happened. Halt All Movement (Cancel All Designated Moves)
        # deliberately does not clear it (see #apply_halt_request) -- RPG_RT
        # aborts an in-progress route without unwinding its side effects, so a
        # route cancelled mid-Through-Mode leaves the hero stuck pass-through.
        @player_through = false
        restore_player_route

        # A forced move route applied to a vehicle by a Move Event, keyed by
        # type (:boat/:ship/:airship). Unlike the player/events, a moving
        # vehicle's position is not pixel-interpolated -- it snaps tile to
        # tile at its route's pace, the same instant feel Set Vehicle
        # Location already has -- so there is no slide/mirror-vs-render split
        # to track here beyond the mirror `Game::Character` itself (see
        # #force_vehicle_route).
        @vehicle_chars = {}
        @vehicle_routes = {}
        @vehicle_route_timers = {}
        @vehicle_orig_freq = {}
        # Move Event targets that resolved to a currently-hidden map event
        # (see #apply_move_request) -- once stuck, permanently so, matching a
        # freeze that never clears on its own.
        @stuck_move_targets = []

        # Player pixel position and step state. `player_jumping` marks the slide
        # as a hop, which is lifted along an arc (see player_jump_offset).
        @moving = false
        @move_count = 0
        @slide_frac = 0
        @player_jumping = false
        @dest_x = @state.x
        @dest_y = @state.y
        # This frame's input-driven move target, snapshotted before
        # #step_events runs -- see #player_intended_target.
        @player_intended_target = nil
        @tile_colors = {}
        @last_frame = nil
        # Frame counter driving the chipset's water/animated-tile animation.
        @anim_frame = 0
        # Whether the slide in progress was started by a forced route (a Move
        # Event on the player, or Proceed With Movement) rather than ordinary
        # player-input walking. #check_random_encounter only rolls on the
        # latter (see the comment there), ported from a reference
        # implementation's encounter-step update, which its movement-action
        # update only calls from the input-driven path -- NOT independently
        # confirmed against genuine RPG_RT under wine.
        @player_forced_step = false
        # The wandering-monster encounter table row #check_random_encounter is
        # on (named after a reference implementation's own last-encounter
        # index, NOT independently confirmed against genuine RPG_RT under
        # wine) -- a
        # plain runtime counter, not part of the save (see
        # Game::State#encounter_total).
        @encounter_idx = 0

        setup_sprites
        render
      end

      attr_reader :state
      # The current map's live event list -- see #build_events for the shape
      # of each entry ({ id:, char:, page:, page_number:, ... }). Read by
      # RPG2k #dump_bug_report (main.rb) to list every event's
      # position/direction/page alongside the hero's.
      attr_reader :events
      # The foreground interpreter -- the one On Touch/On Talk/auto-start
      # triggers and Show Message run on, as opposed to a Parallel Process's
      # own background one (see #parallel_interpreter_for). Read by RPG2k
      # #dump_bug_report to show what it is stuck on, if anything.
      attr_reader :interpreter

      # The background Parallel Process interpreter currently running for map
      # event `id`, or nil when none is (no Parallel Process trigger, or its
      # page/conditions currently pick something else). Diagnostics only --
      # RPG2k#dump_bug_report is the one caller today.
      def parallel_interpreter_for(id)
        p = @parallels.find { |pp| pp[:event] && pp[:event][:id] == id }
        p && p[:interp]
      end

      # Services Scene::Battle calls back into ----------------------------
      #
      # Scene::Battle owns everything the fight itself is made of; what it
      # reaches back into this scene for is the handful of things a running
      # fight shares with the field map: the graphic caches (a monster or
      # backdrop decoded in one encounter stays warm for the next one on the
      # same map visit), the RNG the map's own event/move-route code already
      # shares with the party, the windowskin (a Change System Graphic run
      # from a battle event page reloads this scene's own copy), and the
      # animation player a round's skill/item animation shares with the
      # map's own Show Battle Animation command. Every reader here backs one
      # of those; the methods a few screens down (#play_battle_bgm,
      # #terrain_backdrop, #perform_game_over, ...) are the same kind of
      # service, just too tied to their own surrounding map code to move next
      # to their readers.
      attr_reader :rng, :monster_cache, :backdrop_cache, :battlecharset_cache,
                  :system2_cache, :windowskin
      attr_accessor :map_animation

      def dispose
        close_message(animate: false)
        (@closing_windows || []).each(&:dispose)
        @closing_windows = nil
        close_inn_window
        close_shop
        close_battle
        [@lower_sprite, @upper_sprite, @player_sprite, @parallax_sprite,
         @picture_sprite, @fade_sprite, @flash_sprite,
         @weather_sprite].each do |s|
          s.dispose if s
        end
        (@vehicle_sprites || {}).each_value { |s| s.dispose if s }
        (@timer_sprites || []).each { |s| s.dispose if s }
        @airship_shadow.dispose if @airship_shadow
        @animation_sprite.dispose if @animation_sprite
        # After the sprites they hold, so nothing is orphaned inside them.
        @map_viewport.dispose if @map_viewport
        @upper_viewport.dispose if @upper_viewport
        @flash_buffer.dispose if @flash_buffer
        @flash_out_buffer.dispose if @flash_out_buffer
        @animation_cell_crop_buffer.dispose if @animation_cell_crop_buffer
        # Held by no sprite (see #setup_sprites), so nothing else frees these.
        @lower_tiles.dispose if @lower_tiles
        @upper_tiles.dispose if @upper_tiles
        @chipset_bmp.dispose if @chipset_bmp
        @parallax_img.dispose if @parallax_img
      end

      def update
        # RPG2003's Order screen (party reorder) is driven entirely by
        # Scene::Order, with no interpreter command of its own to carry the
        # leader-graphic-refresh flag #apply_graphic_change already polls for
        # Change Actor Graphic -- so it is polled here instead, the very
        # first thing once this scene is on top again, the same "catch up on
        # whatever the pushed screen did" timing #state.pending_teleport
        # (just below) already uses for a different pushed-screen side
        # effect. See Game::Party#reorder's own citation for the reference
        # implementation this ports (NOT independently confirmed against
        # genuine RPG_RT under wine -- see that method's own disclosure).
        refresh_player_graphic if @state.party.respond_to?(:take_leader_graphic_dirty) &&
                                   @state.party.take_leader_graphic_dirty
        # An Escape / Teleport field skill queues its destination here rather
        # than jumping directly -- it is cast from the skill menu, a scene with
        # none of this one's map-load machinery, and this scene does not even
        # run its #update while that menu sits on top of it. Applied as the
        # very first thing once this scene is on top again and then rendered
        # immediately, the same way the interpreter's own Teleport command
        # renders the destination map on the frame it lands (see the `:teleport`
        # branch below) rather than leaving a stale frame up for one tick. The
        # rest of this frame's simulation (timers, event stepping, movement) is
        # skipped exactly as it already is on that frame -- #event_busy? holds
        # it off there because the interpreter is mid-wait, and there is no
        # interpreter wait to hold it off here, so it is skipped explicitly.
        if @state.pending_teleport
          if @state.boarded? && @state.boarded != :airship
            follow_vehicle
            @state.boarded = nil
            restore_pre_vehicle_bgm
          end
          perform_teleport(@state.pending_teleport, keep_pictures: true)
          @state.pending_teleport = nil
          animate_events
          render
          return
        end
        # The timers keep counting during events too. A fight is running when the
        # battle UI is up, and a timer without the "run in battle" flag pauses
        # (and hides) for its duration rather than being stopped. A timer that
        # *does* carry the flag force-ends the battle outright the instant it
        # reaches 0:00 (yado.tk), regardless of encounter source (default or
        # scripted) -- #tick_timer only ever reports true for one mid-battle
        # (an in_battle-less timer is held frozen instead, never reaching zero
        # then), so any true here is unambiguously that case. Mirrors Terminate
        # Battle's own :abort outcome (#finish_terminated_battle), just reachable
        # from any battle phase rather than only the battle-event one.
        if @state.tick_timer(!@battle.nil?) && @battle
          @battle.finish_battle(:abort)
        end
        @state.screen.update # screen tint progresses every frame, even in events
        @state.update_pictures # picture moves progress every frame too
        update_sprite_flashes # Flash Sprite decays during events too
        update_vehicle_flashes # a vehicle's own map-triggered animation flash decays too
        step_ownerless_map_animation # a fire-and-forget Show Battle Animation plays on, unattended
        update_closing_windows # a closed message keeps shrinking in the background
        watch_bgm_loop # so the "BGM played once" branch can be answered
        @anim_frame += 1 # water / animated tiles cycle even during events
        # An event page's conditions may have just stopped (or started) holding;
        # re-select before anything reads a trigger or a graphic this frame.
        RGSS::Profiler.section("map.refresh_pages") { refresh_event_pages }
        # Parallel processes run every frame on their own schedule, independent
        # of whatever the foreground is doing (yado.tk: a message window or a
        # foreground event parked on a blocking wait is not a pause condition,
        # only a battle or an actively-bursting foreground event is -- see
        # #parallels_paused?). Stepped before the foreground gets a chance to
        # start anything this frame, matching "if both are set to fire the
        # same frame, parallel process goes first". `paused` is captured once
        # and reused for both branches below: whichever one runs owns this
        # frame's only pass over the entry that opened a battle, so the two
        # can never double-step it (#step_battle_owner_parallel is the only
        # thing keeping that entry moving once its own fight has paused the
        # ordinary pass above).
        paused = parallels_paused?
        step_parallels unless paused
        step_battle_owner_parallel if paused
        # Auto-start events re-trigger every frame, not once per visit: reset the
        # per-frame eligibility gate so an eligible auto-start (map or common)
        # that already ran this frame can be picked again next frame. Within a
        # frame the gate still prevents re-picking the *same* event, so distinct
        # auto-starts cascade as before; across frames it lets the same event
        # restart from the top, matching RPG_RT (yado.tk / viprpg: an auto-start
        # with no wait re-fires every frame for as long as its page condition
        # holds). See the "Autorun (auto-start) events run at most once per map
        # visit" bullet in docs/TODO.md.
        @started_auto.clear
        @started_common.clear
        # This real frame's foreground step budget starts fresh here (see
        # Game::Interpreter::MAX_STEPS/#reset_frame_steps) -- every
        # @interpreter.update call below, however many times #drive_event and
        # #drive_autostart_cascade's own cascading call it this frame, shares
        # this one reset rather than each getting its own fresh 10000.
        @interpreter.reset_frame_steps
        if event_busy?
          drive_event
          # Message Options' "move other events during message" toggle: other
          # map events keep their own autonomous movement / forced routes
          # going while this message window sits open (see
          # #events_move_during_message?). `allow_trigger: false` still lets
          # them walk, turn and finish routes, but never lets one start a new
          # event over the player's -- there is only one foreground
          # interpreter, and it is already busy with this message.
          step_events(allow_trigger: false) if events_move_during_message?
        else
          start_autostart
          if event_busy?
            drive_autostart_cascade
          else
            # Snapshot this frame's input-driven move target *before*
            # #step_events runs, so an autonomous/route-driven event's own
            # hero-tile refusal (#move_autonomous, Game::MoveRoute#do_move)
            # can tell a genuine same-frame crossing -- the party and the
            # event trading tiles in one step -- from the party simply
            # walking up to an event that is not, this frame, trying to walk
            # onto the party's own tile. See #player_intended_target.
            @player_intended_target = player_intended_target
            step_player_route
            step_events
            step_vehicle_routes
            step_movement
            # Boarding / disembarking claims the action button when it applies;
            # otherwise it falls through to the usual event trigger.
            try_action_trigger unless try_board_vehicle
            try_open_menu
            try_open_debug_menu
          end
        end
        record_map_event_positions
        record_foreground_event_exec
        record_tile_substitutions
        RGSS::Profiler.section("map.animate_events") { animate_events }
        RGSS::Profiler.section("map.render") { render }
      end

      private

      def setup_sprites
        # Everything the map view is made of lives in one viewport, so RPG2000's
        # Tint Screen can be applied to all of it at once (see #update_map_tone).
        # A viewport is what carries a tone in RGSS, and it reaches the sprites
        # inside it and nothing else -- which is the distinction the screen tone
        # needs: the map is tinted, while the pictures above it (which carry
        # their own tone), the message window and the weather / flash / fade
        # overlays are not.
        @map_viewport = Viewport.new(0, 0, SCREEN_W, SCREEN_H)
        # Below the picture layer, so the z values inside keep their meaning
        # relative to each other while the whole map sits under everything that
        # draws over it.
        @map_viewport.z = MAP_VIEWPORT_Z

        @lower_sprite = Sprite.new(@map_viewport)
        @lower_sprite.z = 0
        @lower_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @lower_sprite.bitmap = @lower_bmp

        # The cached tile grids behind @lower_bmp / @upper_bmp: same size, but
        # holding only the tiles, aligned to whole tiles and with no events on
        # them, so a frame that changed nothing but the scroll remainder can be
        # served by copying rather than by re-blitting the grid. Never attached
        # to a sprite -- #draw_layers copies them into the two buffers above.
        @lower_tiles = Bitmap.new(COLS * TILE, ROWS * TILE)
        @upper_tiles = Bitmap.new(COLS * TILE, ROWS * TILE)
        @tiles_built = false

        # The upper (above-character) chip layer lives in its own viewport
        # rather than @map_viewport, purely so a Show Battle Animation sprite
        # can be sandwiched between the two (see @animation_sprite below)
        # without moving into or out of a toned viewport itself -- it keeps
        # exactly the tone @map_viewport gets, applied in lockstep by
        # #update_map_tone, matching "the map tile+character layer" the
        # yado.tk finding scopes Change Screen Tone to.
        @upper_viewport = Viewport.new(0, 0, SCREEN_W, SCREEN_H)
        @upper_viewport.z = 200 # same top-level slot the sprite held inside @map_viewport
        @upper_sprite = Sprite.new(@upper_viewport)
        @upper_sprite.z = 200 # sole child of @upper_viewport, so this is only for parity
        @upper_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @upper_sprite.bitmap = @upper_bmp

        @player_sprite = Sprite.new(@map_viewport)
        @player_sprite.z = 100
        @player_bmp = Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
        @player_sprite.bitmap = @player_bmp

        # One sprite per vehicle (drawn just under the hero, so a boarded party
        # sits on top). Hidden unless the vehicle is placed on the current map.
        @vehicle_sprites = {}
        @vehicle_bmps = {}
        @vehicle_last_frame = {}
        Game::Vehicle::TYPES.each do |type|
          spr = Sprite.new(@map_viewport)
          spr.z = 99
          spr.visible = false
          bmp = Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
          spr.bitmap = bmp
          @vehicle_sprites[type] = spr
          @vehicle_bmps[type] = bmp
        end
        # The airship floats above the ground; a shadow sprite on the tile below
        # it sells the altitude. A squat translucent dark blob approximates it.
        @airship_shadow = Sprite.new(@map_viewport)
        @airship_shadow.z = 98 # under the vehicles, over the ground / events
        @airship_shadow.visible = false
        shadow = Bitmap.new(TILE, TILE)
        shadow.fill_rect 3, TILE - 8, TILE - 6, 5, Color.new(0, 0, 0, 96)
        @airship_shadow.bitmap = shadow

        # A screen-sized layer the Show Battle Animation renderer composites the
        # current frame's cells into, over the map (above the hero). A
        # top-level sprite, not a child of @map_viewport: yado.tk documents
        # Change Screen Tone as affecting only the map tile+character layer --
        # pictures, screen/character flash, battle animations and message text
        # all stay unaffected even at a maximal dark tone, but this sprite used
        # to live inside the same toned viewport as the tiles and hero, so an
        # active map tone wrongly tinted every Show Battle Animation (11210)
        # play, both the field/parallel-process one and an in-battle attack's
        # own, since both render through this one shared sprite (#step_map_animation).
        # Its z (150) is unchanged, so it still draws in the same slot between
        # @map_viewport (z 100) and the upper layer's own @upper_viewport
        # (z 200) it always has -- top-level z ordering compares a Viewport as
        # one block against its siblings (gfx_update's per-parent z sort), so
        # pulling this one sprite out changes only whether the map's tone
        # reaches it, not where it draws relative to the layers around it.
        # z 150 also settles a previously-open question: it sits below
        # @picture_sprite (z 250), so a Show Battle Animation always draws
        # *under* the picture layer. Ported from a reference implementation,
        # NOT independently confirmed against genuine RPG_RT under wine: its
        # own draw-priority scheme orders the old-style picture priority above
        # the battle-animation priority -- the ordering every standard
        # RPG2000/RPG2003 database uses there, since its picture-sprite
        # constructor seeds every picture at the old-style priority plus the
        # picture id unconditionally, only overridden by a new-style priority
        # (below battle animations) when a version-detection feature flag
        # detects the "RPG2000 Value!" English re-release or a specifically
        # patched RPG2003 English runtime (`ultimate_rt_eb.dll`), neither of
        # which this project has any file/version signal to detect from a
        # plain .ldb/.lmt/.lmu triple. So "pictures always draw over a map
        # animation" is that reference implementation's behavior for every
        # ordinary RPG2000/RPG2003 database, carried over here on the same
        # unconfirmed basis.
        @animation_sprite = Sprite.new
        @animation_sprite.z = 150
        @animation_sprite.visible = false
        @animation_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @animation_sprite.bitmap = @animation_bmp
        # Fallback marker when the CharSet graphic is unavailable -- a debug
        # aid, so it only shows during Test Play; a released game with a
        # missing hero graphic draws nothing, same as RPG_RT.
        unless @charset
          alpha = parent.test_play ? 255 : 0
          @player_bmp.fill_rect 4, 0, TILE, Game::CharSet::HEIGHT,
                                Color.new(240, 240, 80, alpha)
        end
        setup_parallax
        setup_pictures
        setup_screen_overlay
      end

      # The full-screen colour layers Erase/Show Screen (fade) and Flash Screen
      # draw. Both sit above everything, message window included -- RPG2000 fades
      # and flashes the whole screen, not just the map.
      #
      # No native work was needed for this, despite the note in docs/TODO.md that
      # it wanted "alpha-blend / viewport support in C++": RGSS::Sprite#opacity
      # already maps onto LVGL's per-object alpha at blit time, which is exactly
      # the per-sprite opacity RGSS specifies. So a screen-sized sprite of solid
      # colour, shown at the effect's strength, is the whole mechanism.
      #
      # The bitmaps are filled once and only re-filled when the colour changes
      # (never, for the always-black fade): a per-frame fill of the screen would
      # be 76800 pixel writes to produce the same image, where changing the
      # opacity is one property set.
      def setup_screen_overlay
        @fade_sprite = Sprite.new
        @fade_sprite.z = 500
        @fade_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(0, 0, 0, 255)
        @fade_sprite.bitmap = @fade_bmp
        @fade_sprite.opacity = 0
        # Whether the overlay currently holds a transition mask rather than the
        # solid black the opacity-only fade needs (see #draw_transition_mask).
        @fade_masked = false
        # The screen snapshot a captured transition (scroll / combine /
        # division, see Game::Transition::CAPTURED) composites from, and the
        # transition object it was taken for -- so a second frame of the same
        # transition reuses it instead of re-snapshotting every frame.
        @transition_capture = nil
        @captured_transition = nil
        # The random-blocks transition (see Game::Transition::RANDOM_BLOCKS_
        # STYLES) currently painting into the overlay incrementally, or nil --
        # tracked by identity the same way, so #draw_random_blocks_transition
        # knows when to (re)paint the overlay solid black versus just punching
        # this frame's new blocks out of what is already there.
        @random_blocks_transition = nil

        @flash_sprite = Sprite.new
        @flash_sprite.z = 450
        @flash_sprite.opacity = 0
        # Built lazily by #update_screen_overlay on the first real Flash
        # Screen -- most maps never trigger one, so this screen-sized
        # (307,200 B decoded) buffer shouldn't be every map visit's cost.
        # @flash_rgb stays nil until then, which is also what forces that
        # first real flash to allocate it (see the fill_rect branch below).
        @flash_rgb = nil


        # Weather Effects: rain / snow particles drawn on a screen-sized layer
        # (under the flash / fade overlays), animated by @anim_frame. Most
        # maps never turn weather on at all, so its screen-sized (307,200 B
        # decoded) buffer is built lazily by #draw_weather on first actual
        # use rather than paid by every map visit -- unlike @fade_bmp/
        # @flash_bmp just above, whose bitmaps #draw_weather's own siblings
        # need from frame one (a fade is how most map transitions arrive).
        @weather_sprite = Sprite.new
        @weather_sprite.z = 430
        @weather_sprite.visible = false
      end

      # Push this frame's fade and flash levels onto the two overlay sprites.
      # Both are 0..255 already: Game::Screen models the fade as 0 visible ..
      # 255 black, and the flash as a colour plus a 0..255 strength that decays
      # over the command's duration.
      def update_screen_overlay
        screen = @state.screen
        draw_transition_mask screen
        update_map_tone screen.tint

        r, g, b, strength = screen.flash_color
        if strength <= 0
          @flash_sprite.opacity = 0
        else
          rgb = [r, g, b]
          if @flash_rgb != rgb
            unless @flash_bmp
              @flash_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
              @flash_sprite.bitmap = @flash_bmp
            end
            @flash_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(r, g, b, 255)
            @flash_rgb = rgb
          end
          @flash_sprite.opacity = strength
        end

        draw_weather
      end

      # Fully opaque and fully clear black, for painting the erase overlay.
      OPAQUE_BLACK = Color.new(0, 0, 0, 255)
      CLEAR = Color.new(0, 0, 0, 0)

      # Paint the screen-erasure overlay for this frame.
      #
      # A plain fade is just the overlay's opacity, and the bitmap stays the
      # solid black it was built as — the cheap path, which is also every frame
      # on which no transition is running. A *shaped* transition (blinds,
      # stripes, a closing window) instead paints the bitmap: opaque black
      # everywhere, then the regions of the live scene still showing through
      # punched back out to fully transparent. `fill_rect` overwrites alpha, so
      # the holes really are holes. A *captured* transition (scroll, combine /
      # division) paints real pixels instead of holes -- see
      # #draw_captured_transition. Random blocks is a shaped mask too, but an
      # *incremental* one -- see #draw_random_blocks_transition.
      def draw_transition_mask(screen)
        tr = screen.transition
        if tr && tr.captured?
          release_random_blocks_transition
          return draw_captured_transition(tr)
        end
        release_transition_capture
        return draw_random_blocks_transition(tr) if tr && tr.random_blocks?
        release_random_blocks_transition
        if tr.nil? || tr.uniform?
          reset_fade_bitmap if @fade_masked
          @fade_sprite.opacity = screen.fade_level
          return
        end
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK
        tr.visible_rects.each { |x, y, w, h| @fade_bmp.fill_rect x, y, w, h, CLEAR }
        @fade_masked = true
        @fade_sprite.opacity = 255
      rescue StandardError => e
        # A drawing failure must not strand the screen mid-transition: fall back
        # to the plain fade level, which still lands on the right end state.
        $stderr.puts "[RPG2k] screen transition draw failed: #{e.message}"
        @fade_sprite.opacity = screen.fade_level
      end

      # Paint a captured-style transition: the whole overlay is filled black,
      # then each of the transition's #capture_ops pastes a piece of a screen
      # snapshot at its sliding position, so a piece not yet in place just
      # leaves the black behind it. The snapshot is taken once, the first frame
      # this particular Game::Transition instance is drawn (identity, not
      # value, so a same-style transition right after it still re-snapshots).
      #
      # Zoom is the one #capture_ops style that resamples instead of pasting
      # 1:1 (see Game::Transition#zoom?): its single piece is `[dx, dy, dw,
      # dh, sx, sy, sw, sh]` for `Bitmap#stretch_blt`, rather than the `[dx,
      # dy, sx, sy, sw, sh]` every other #capture_ops style hands to
      # `Bitmap#blt`. Mosaic and wave (Game::Transition#mosaic?/#wave?) are
      # native per-pixel resamples of the whole capture instead of a geometry
      # list -- `Bitmap#mosaic_blt`/`#wave_blt`, driven by
      # `#mosaic_block_size`/`#wave_params` rather than `#capture_ops`.
      def draw_captured_transition(tr)
        unless @captured_transition.equal?(tr)
          @transition_capture.dispose if @transition_capture
          @transition_capture = Graphics.snap_to_bitmap
          @captured_transition = tr
        end
        cap = @transition_capture
        unless cap
          # The backend cannot snapshot (Wio/PSP, or a headless test double) --
          # fall back to a plain fade, same as every style this build does not
          # paint for real.
          @fade_sprite.opacity = tr.black_alpha
          return
        end
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK
        if tr.zoom?
          dx, dy, dw, dh, sx, sy, sw, sh = tr.capture_ops.first
          @fade_bmp.stretch_blt Rect.new(dx, dy, dw, dh), cap, Rect.new(sx, sy, sw, sh)
        elsif tr.mosaic?
          @fade_bmp.mosaic_blt cap, tr.mosaic_block_size
        elsif tr.wave?
          depth, phase = tr.wave_params
          @fade_bmp.wave_blt cap, depth, phase
        else
          tr.capture_ops.each do |dx, dy, sx, sy, sw, sh|
            @fade_bmp.blt dx, dy, cap, Rect.new(sx, sy, sw, sh)
          end
        end
        @fade_masked = true
        @fade_sprite.opacity = 255
      rescue StandardError => e
        $stderr.puts "[RPG2k] screen transition capture draw failed: #{e.message}"
        @fade_sprite.opacity = tr.black_alpha
      end

      # Drop the held snapshot once no captured transition needs it -- holding
      # a 320x240 bitmap between transitions would be a pointless leak.
      def release_transition_capture
        return unless @transition_capture
        @transition_capture.dispose
        @transition_capture = nil
        @captured_transition = nil
      end

      # Paint a random-blocks-style transition incrementally: the overlay is
      # filled opaque black once, the first frame this particular
      # Game::Transition instance is drawn (identity, not value, so a
      # same-style transition right after it still restarts from solid
      # black) -- and that first paint punches every block #revealed_
      # block_rects says is due by the current frame, not just this frame's
      # own #new_block_rects delta, since the frame counter can already be
      # past 0 by the time a transition is first drawn (see
      # Game::Transition#revealed_block_rects). Every frame after that only
      # punches the incremental #new_block_rects delta -- never re-filling
      # the whole overlay is the point, see
      # Game::Transition::RANDOM_BLOCKS_STYLES's comment on why the generic
      # #visible_rects path (a full black fill plus the entire cumulative
      # mask, every frame) is the wrong shape for ~4800 blocks.
      def draw_random_blocks_transition(tr)
        if @random_blocks_transition.equal?(tr)
          rects = tr.new_block_rects
        else
          @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK
          @random_blocks_transition = tr
          rects = tr.revealed_block_rects
        end
        rects.each { |x, y, w, h| @fade_bmp.fill_rect x, y, w, h, CLEAR }
        @fade_masked = true
        @fade_sprite.opacity = 255
      rescue StandardError => e
        $stderr.puts "[RPG2k] screen transition block draw failed: #{e.message}"
        @fade_sprite.opacity = tr.black_alpha
      end

      # Drop the identity marker once no random-blocks transition needs it --
      # otherwise a later same-style transition (a new Game::Transition
      # object) would look like a continuation of a finished one and never
      # get the fresh solid-black overlay it needs.
      def release_random_blocks_transition
        @random_blocks_transition = nil
      end

      # Restore the overlay to solid black after a shaped transition, so the
      # opacity-only path draws a full-screen fade again.
      def reset_fade_bitmap
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK
        @fade_masked = false
      end

      WEATHER_RAIN = 1
      WEATHER_SNOW = 2
      # Particle counts by strength (0..2). Ported from a reference
      # implementation's own particle-count table, NOT independently
      # confirmed against genuine RPG_RT under wine: the literal
      # { 20, 60, 100 }, not a fixed multiple of the lightest strength's own
      # count: the step from light to medium (+40) and medium to heavy (+40)
      # is constant, but light itself (20) is under half of what a "* (n+1)"
      # progression from a single base would give.
      WEATHER_PARTICLE_COUNTS = [20, 60, 100].freeze
      RAIN_COLOR = Color.new(200, 210, 255, 200)
      SNOW_COLOR = Color.new(255, 255, 255, 220)

      # Draw the active weather onto its overlay: falling rain streaks or drifting
      # snow flecks, their count scaling with the strength (0..2). Positions are a
      # deterministic hash of the particle index advanced by @anim_frame, so the
      # field falls smoothly without needing a per-frame RNG. Cleared / hidden
      # when there is no weather.
      def draw_weather
        w = @state.weather
        if w.none? || (w.type != WEATHER_RAIN && w.type != WEATHER_SNOW)
          @weather_sprite.visible = false
          return
        end
        unless @weather_bmp
          @weather_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
          @weather_sprite.bitmap = @weather_bmp
        end
        @weather_sprite.visible = true
        @weather_bmp.clear
        n = weather_particle_count(w)
        n.times { |i| draw_weather_particle(w.type, i) }
      end

      def weather_particle_count(w)
        i = Game.clamp(w.strength || 0, 0, WEATHER_PARTICLE_COUNTS.length - 1)
        WEATHER_PARTICLE_COUNTS[i]
      end

      # A single particle's on-screen cell, spread across the screen by a cheap
      # hash of its index and falling as @anim_frame advances (wrapping at the
      # bottom). Rain is a slanted streak; snow a small fleck that also drifts.
      # Per-frame motion ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine: its
      # rain/snow update makes rain fall `p.y += 4; p.x -= 1` every frame
      # it's alive, and snow fall `p.y += Rand(2, 3)` while drifting
      # `p.x -= Rand(0, 1)`, i.e. leftward only, never rightward.
      def draw_weather_particle(type, i)
        x0 = (i * 97) % SCREEN_W
        y0 = (i * 59) % SCREEN_H
        if type == WEATHER_RAIN
          y = (y0 + @anim_frame * 4) % SCREEN_H
          x = (x0 - @anim_frame) % SCREEN_W
          @weather_bmp.fill_rect x, y, 1, 6, RAIN_COLOR
        else
          y = (y0 + @anim_frame * 3) % SCREEN_H
          x = (x0 - weather_drift(i)) % SCREEN_W
          @weather_bmp.fill_rect x, y, 2, 2, SNOW_COLOR
        end
      end

      # A small leftward-only snow drift, approximating RPG_RT's own average
      # rate (`p.x -= Rand::GetRandomNumber(0, 1)` per frame, ~0.5px/frame)
      # without needing a per-frame RNG draw -- monotonically increasing
      # (never wrapping back down) so a flake only ever nudges further left
      # as it falls, the same one-way drift real RPG_RT's snow has, unlike
      # a bouncing side-to-side wave.
      def weather_drift(i)
        (@anim_frame + i * 3) / 2
      end

      # Apply a Tint Screen tone (`[r, g, b, sat]`, each 0..200 with 100 neutral)
      # to the map tile+character layer, by setting it on the two viewports
      # that layer's sprites live in -- @map_viewport (tiles below the upper
      # chip layer, the hero, vehicles) and @upper_viewport (the above-character
      # chip layer, split out so @animation_sprite can sit between the two
      # without itself being a child of either, see its own comment). Both get
      # the identical tone in lockstep, so the split is invisible to anything
      # that only cares about "is the map tinted" -- only @animation_sprite,
      # the picture layer and everything above it are exempt.
      #
      # This used to be approximated by a black overlay whose opacity tracked how
      # far the channels averaged *below* neutral, which meant brightening did
      # nothing at all, a red tint did not read as red, and saturation was
      # ignored -- three of the four things the command can ask for. A viewport
      # carries a real tone, so all four work now.
      #
      # The channel conversion is the one the pictures already use
      # (`Scene::Map.tone_channel`), including RPG2000's saturation running the
      # other way from RGSS's grey: below 100 is *less* saturated, so a value
      # under neutral becomes positive desaturation. Skipped entirely while the
      # tone is neutral, so an untinted map never pays for it.
      # The tone currently on the map layer (or nil before the first
      # #update_map_tone). Exposed so the battle backdrop -- a top-level sprite
      # outside the toned @map_viewport -- can seed its own tone when it is
      # built mid-tint (#build_battle_back) and stay in lockstep with the map
      # layer for the rest of the fight.
      def current_map_tone
        @map_viewport&.tone
      end

      def update_map_tone(tint)
        return unless @map_viewport
        r, g, b, sat = tint
        return if @map_tint == tint
        @map_tint = tint.dup
        tr = Scene::Map.tone_channel(r)
        tg = Scene::Map.tone_channel(g)
        tb = Scene::Map.tone_channel(b)
        tsat = -Scene::Map.tone_channel(sat)
        @map_viewport.tone = Tone.new(tr, tg, tb, tsat)
        @map_viewport.update if @map_viewport.respond_to?(:update)
        if @upper_viewport
          # A separate Tone instance, not the same object shared across both
          # viewports -- Tone has mutable component setters (red=, etc.), so
          # aliasing one between two viewports would risk a later in-place
          # tweak to one silently retuning the other.
          @upper_viewport.tone = Tone.new(tr, tg, tb, tsat)
          @upper_viewport.update if @upper_viewport.respond_to?(:update)
        end
        # The battle backdrop rides none of the toned viewports -- it is a
        # top-level sprite (Scene::Battle#build_battle_back), so a Tint Screen
        # active mid-fight would otherwise only reach the (hidden) map layer
        # and skip the one element actually on screen. Ported from a
        # reference implementation, NOT independently confirmed against
        # genuine RPG_RT under wine: its battle-spriteset update mirrors the
        # screen tone onto the backdrop, so mirror the map tone onto the live
        # backdrop here too. #build_battle_back seeds it on build so
        # a tint already active when the encounter opens is covered too.
        @battle.apply_backdrop_tone(Tone.new(tr, tg, tb, tsat)) if @battle
      rescue StandardError => e
        $stderr.puts "[RPG2k] screen tone failed, map drawn untinted: #{e.message}"
        nil
      end

      # Create the buffer that carries the Show Picture layer. Pictures composite
      # into one screen-sized sprite above the map and characters (z = 250) but
      # below the message window (z = 300); source images are cached by
      # [name, transparent-colour] as they are shown.
      def setup_pictures
        @picture_sprite = Sprite.new
        @picture_sprite.z = 250
        # Built lazily by #draw_pictures on the first frame that actually
        # shows one -- a map that never runs Show Picture (or a Parallel
        # Process that only ever shows one on some maps, not this one)
        # shouldn't pay for this screen-sized (307,200 B decoded) buffer.
        # Toned copies of picture sources, keyed by image + tone (see
        # #toned_picture_src). Picture sources themselves are cached in
        # @picture_cache (see #picture_src).
        @picture_tone_cache = {}
      end

      # Load-and-memoize helper backing every named graphic loader below
      # (event and party CharSets, pictures, the battle backdrop, battlers
      # and animation sheets): each is requested by name repeatedly -- an
      # animation replayed, a monster shared across troop slots, a picture
      # redrawn every frame -- and without this they would hit the decoder
      # again on every request. `cache` is the material's own hash (one of
      # @charset_cache, @picture_cache, @backdrop_cache, @monster_cache,
      # @animation_cache, @battlecharset_cache, @system2_cache), so a name is
      # only ever looked up among graphics of its own kind. The block's
      # result is cached as-is, including a
      # nil/fallback for a failed load, so the caller's own rescue logs the
      # error once and every later call reuses that outcome instead of
      # retrying the disk.
      def cached_bitmap(cache, key)
        return cache[key] if cache.key?(key)
        cache[key] = yield
      end

      # Load (and cache) a picture's source image (Picture/<name>). `transparent`
      # loads it with the colour-key so palette index 0 shows through. A cached
      # nil marks a missing file so a broken picture simply draws nothing.
      def picture_src(name, transparent)
        return nil if name.nil? || name.empty?
        cached_bitmap(@picture_cache, [name, transparent]) do
          begin
            Bitmap.new "Picture/#{name}", transparent
          rescue StandardError => e
            $stderr.puts "[RPG2k] picture '#{name}' load failed, not drawn: #{e.message}"
            nil
          end
        end
      end

      # Load the map's parallax background (Panorama/<name>) and its scroll
      # settings, and create the sprite that carries it behind the tile layers
      # (z = -1, below the lower tiles at z = 0). Skipped — leaving the map's
      # backdrop the plain void — when the map has no parallax or the image is
      # missing.
      def setup_parallax
        cfg = parallax_config
        return unless cfg
        name = cfg[:name].to_s
        return if name.empty?
        @parallax_img = Bitmap.new "Panorama/#{name}"
        @par_loop_x = cfg[:loop_x] ? true : false
        @par_loop_y = cfg[:loop_y] ? true : false
        @par_auto_x = cfg[:auto_x] ? true : false
        @par_auto_y = cfg[:auto_y] ? true : false
        @par_sx = cfg[:sx] || 0
        @par_sy = cfg[:sy] || 0
        @parallax_sprite = Sprite.new(@map_viewport)
        @parallax_sprite.z = -1
        @parallax_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @parallax_sprite.bitmap = @parallax_bmp
      rescue StandardError => e
        $stderr.puts "[RPG2k] parallax load failed, no backdrop drawn: #{e.message}"
        @parallax_img = nil
      end

      # The parallax settings to draw: a Change Parallax Background override
      # (Game::State#parallax) when one is active, otherwise the map's own
      # panorama fields. nil when the map declares no parallax and none was set.
      def parallax_config
        ov = @state.parallax
        return ov if ov
        u = @map.unit
        return nil unless (u.parallax_flag rescue false)
        { name: (u.parallax_name rescue '').to_s,
          loop_x: (u.parallax_loop_x rescue false),
          loop_y: (u.parallax_loop_y rescue false),
          auto_x: (u.parallax_autoloop_x rescue false),
          auto_y: (u.parallax_autoloop_y rescue false),
          sx: (u.parallax_sx rescue 0), sy: (u.parallax_sy rescue 0) }
      end

      # The CharSet bitmap for an event graphic `name`, cached (including a
      # cached nil for a missing file so the event simply draws nothing rather
      # than a placeholder). Empty names have no graphic.
      #
      # Loaded colour-keyed, like the chipset: a CharSet is an indexed PNG whose
      # palette entry 0 is the background, and without the key that background is
      # blitted opaque -- a solid rectangle over the map instead of a sprite.
      # Caught by the wine comparison, where Nepheshel's `door` event drew as a
      # solid pink block (door.png's palette entry 0 is #FF678B) on a wall the
      # genuine RPG_RT left alone.
      def event_charset(name)
        return nil if name.nil? || name.empty?
        cached_bitmap(@charset_cache, name) do
          begin
            Bitmap.new "CharSet/#{name}", true
          rescue StandardError => e
            $stderr.puts "[RPG2k] event charset '#{name}' load failed, " \
                         "event drawn empty: #{e.message}"
            nil
          end
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
      # when there is no party or the file is missing. Colour-keyed for the same
      # reason event graphics are (see event_charset).
      def load_charset
        leader = @state.party.leader
        return nil if leader.nil?
        name = leader.charset_name
        @charset_index = leader.charset_index || 0
        return nil if name.nil? || name.empty?
        cached_bitmap(@charset_cache, name) do
          begin
            Bitmap.new "CharSet/#{name}", true
          rescue StandardError => e
            $stderr.puts "[RPG2k] party charset load failed, using marker: #{e.message}"
            nil
          end
        end
      end

      # Load the System/ windowskin for message windows (nil -> plain panel).
      def load_windowskin
        # A Change System Graphics override (persisted in the save) wins over the
        # database's own windowskin.
        name = @state.system_graphic
        name = @db.system.system_graphic if name.nil?
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
      # `restore_route_index:` gates whether a fresh page-CUSTOM route's cursor
      # consults Game::State#map_event_route_index at all (see #build_event) --
      # true only for the very first build for this scene (a brand new
      # Scene::Map, i.e. genuinely resuming a save rather than continuing live
      # play), matching #new_parallel's identical "only the first build" scoping
      # for a Common Event's own saved progress. #rebuild_events_preserving_positions
      # passes false: its own follow-up copy loop already restores a bystander's
      # *unchanged* route with full live fidelity (the actual running object,
      # not a saved index), and a route that legitimately changed this rebuild
      # must restart at 0, not seek into an unrelated saved index left over from
      # whatever this same event id's route was doing before the rebuild.
      def build_events(restore_route_index: true)
        @events = []
        @event_tiles = {}
        @event_tiles_by_pos = {}
        evs = @map.unit.events
        return unless evs
        evs.each do |id, ev|
          # First sighting of this id this visit: record its raw placement as
          # the fallback #event_id_at falls back to while it has no active
          # page (never touched again from here -- only #record_map_event_positions
          # keeps it current once the event actually goes live).
          @event_last_position[id] ||= [ev.x, ev.y, nil]
          next if @erased_events[id] # an Erase Event lasts the whole visit
          selected = Game::EventPage.select(ev.pages, @state.switches,
                                            @state.variables, @state.party,
                                            @state.timer_seconds, @state.timer2_seconds)
          next unless selected
          page_number, page = selected
          @events.push(build_event(id, ev, page, page_number,
                                    restore_route_index: restore_route_index))
        end
        rebuild_event_tiles
      rescue StandardError => e
        $stderr.puts "[RPG2k] event setup failed, map runs with no events: #{e.message}"
        @events = []
        @event_tiles = {}
        @event_tiles_by_pos = {}
      end

      def build_event(id, ev, page, page_number, restore_route_index: true)
        dir = Game::EventGraphic.numpad_direction(page_direction(page))
        x, y = ev.x, ev.y
        # A saved wandered position (see #record_map_event_positions) wins over
        # the map's own default placement -- restoring a Save/Continue taken on
        # this same map to wherever the NPC actually stood, not back to its
        # editor spawn tile. Empty for a brand-new visit (perform_teleport
        # clears it before a genuine map change) and for a fresh game, so those
        # cases fall through to ev.x/ev.y exactly as before.
        if (saved = @state.map_event_positions[id])
          x, y = saved[0], saved[1]
          dir = saved[2] if saved[2]
        end
        ch = Game::Character.new(x, y, dir)
        ch.event_id = id # #char_passable?/#char_can_land?'s "is this the hero" test
        ch.move_speed = page_move_speed(page)
        ch.move_frequency = page_move_frequency(page)
        ch.set_graphic(page_charset_name(page), page_charset_index(page))
        anim_type = page_anim_type(page)
        # A fixed-direction Animation Type (plain/continuous "fixed", or a
        # never-animating fixed graphic) pins the *drawn* facing the same way
        # Direction Fix ON does -- see Character#fixed_facing/#face's doc --
        # so ordinary movement never turns the sprite, only an explicit move-
        # route Face Direction / Turn sub-command (#face!) still can.
        ch.fixed_facing = Game::EventGraphic.fixed_direction?(anim_type)
        layer = page_layer(page)
        ch.layer = layer # collision (see #char_passable?) follows priority type too
        # The page's "doesn't overlap" flag (LCF field 35) is a second,
        # independent collision axis on top of priority type: it forces
        # collision against a mover/blocker of *any* layer, not just a
        # matching one (see #char_passable?/#char_can_land?/#passable?).
        overlap_forbidden = page_overlap_forbidden(page)
        ch.overlap_forbidden = overlap_forbidden
        move_type = page_move_type(page)
        route = move_type == Game::MoveType::CUSTOM ?
                Game::MoveRoute.from_page(page_move_route(page)) : nil
        # A saved mid-route cursor (see #record_map_event_positions) resumes a
        # page's own custom route at the exact command it was on rather than
        # restarting from the top -- the "move-route index" half of the saved-
        # position restore just above, previously left unmodelled (see Game::
        # State#map_event_route_index). Harmless when this page has no custom
        # route of its own (route is nil) or nothing was ever saved for this
        # id; `restore_route_index` is false only for
        # #rebuild_events_preserving_positions' in-place, live rebuild, where
        # applying a saved index here would be wrong twice over -- a bystander
        # whose route didn't change gets the actual running object back
        # wholesale a few lines below in that method (full fidelity, not a
        # coarser index), and one whose route genuinely did change must
        # restart at 0, not seek into an index that belonged to a different
        # route entirely.
        if restore_route_index && route && (saved_index = @state.map_event_route_index[id])
          route.resume_at(saved_index)
        end
        # `page` is kept so a refresh can tell whether the conditions still pick
        # the same one (see #pages_changed?); `page_number` is the same page's
        # 1-based slot in the event's own page list (Game::EventPage.select's
        # first return value) -- diagnostics-only (RPG2k#bug_report_text),
        # nothing here reads it back.
        { id: id, char: ch, page: page, page_number: page_number,
          trigger: page_trigger(page),
          commands: page_commands(page), guarded: page_guarded(page),
          move_type: move_type, route: route,
          move_timer: EVENT_MOVE_DELAY[ch.move_frequency] || 40,
          # Rendering state: the page's static graphic fields, a live walk
          # animation phase / counter, a mid-step "moving" flag, and the pixel
          # slide (display origin disp_x/disp_y + move_count 0..TILE) that eases
          # the sprite between tiles. move_count == TILE means "at rest".
          # `jumping` marks that slide as a hop, which is lifted along an arc
          # and is the one kind that slides across more than a single tile.
          layer: layer, overlap_forbidden: overlap_forbidden,
          translucent: page_translucent(page),
          anim_type: anim_type, base_dir: dir,
          base_pattern: page_pattern(page), anim_phase: 0, anim_count: 0,
          moving: false, disp_x: x, disp_y: y, move_count: TILE, slide_frac: 0,
          jumping: false }
      end

      # Snapshot every live map event's current tile position and facing onto
      # Game::State, once per real frame -- so a fresh Scene::Map built later
      # from this state (a genuine save/load, see #build_event's saved-position
      # override) restores a wandered NPC to wherever it actually stood rather
      # than resetting it to the map's own default placement. Scoped to the
      # current map's own event ids, which #perform_teleport clears before a
      # genuine map change (see there) -- an ordinary map re-visit (leave and
      # return, no save involved) still resets every event, matching the
      # "Save / Load persistence" list in docs/TODO.md. Also snapshots a
      # currently-running page-custom move route's own cursor (e[:route], only
      # ever non-nil for a page whose move_type is CUSTOM -- see #build_event)
      # into Game::State#map_event_route_index, so the same restore resumes an
      # in-progress custom route at its exact command rather than the top.
      def record_map_event_positions
        # A plain while loop instead of #each avoids allocating a Proc+env for
        # the block on every single frame.
        i = 0
        size = @events.size
        while i < size
          e = @events[i]
          ch = e[:char]
          id = e[:id]
          # A stationary event's tuple reads the same every frame -- reuse the
          # Array already sitting in @state.map_event_positions instead of
          # allocating an identical replacement each time; #event_last_position
          # (below) shares that same object rather than a second copy of it.
          # Neither hash's own entries are ever mutated in place elsewhere
          # (only reassigned wholesale, e.g. #set_char_location's own hidden-
          # target @event_last_position write), so sharing the reference is
          # safe.
          cur = @state.map_event_positions[id]
          if cur && cur[0] == ch.x && cur[1] == ch.y && cur[2] == ch.direction
            pos = cur
          else
            pos = [ch.x, ch.y, ch.direction]
            @state.map_event_positions[id] = pos
          end
          @state.map_event_route_index[id] = e[:route].index if e[:route]
          # Also keeps @event_last_position current for #event_id_at's hidden-
          # event fallback -- see #build_events' seeding comment.
          @event_last_position[id] = pos
          i += 1
        end
      end

      # Snapshot the shared foreground @interpreter's own live call stack onto
      # Game::State every frame -- see Game::State#foreground_event_exec's
      # own comment for exactly when this is non-nil (in practice: only
      # while an event's own Open Save Menu command has it parked on a
      # :save_menu wait, since the ordinary player-driven Save menu can only
      # ever open between events). Cleared back to nil the instant nothing is
      # mid-execution there, so a save taken between events -- the
      # overwhelming majority of the time -- carries no stale chunk 113 at
      # all when #to_lsd runs, matching genuine RPG_RT.
      def record_foreground_event_exec
        frames = @interpreter.call_stack_snapshot
        @state.foreground_event_exec =
          frames && { event_id: @active_event ? @active_event[:id] : 0, frames: frames }
      end

      # Resume whatever event was mid-execution in the shared foreground
      # interpreter at save time (Game::State#foreground_event_exec, decoded
      # from a real .lsd's chunk 113 by Game::State.from_lsd, or carried over
      # from #record_foreground_event_exec's own last snapshot when this
      # Scene::Map was instead built straight from a live State without going
      # through .lsd at all). A no-op the overwhelming majority of the time
      # (see #record_foreground_event_exec's own comment on when this is ever
      # non-nil). Called once, from #initialize, before anything else gets a
      # chance to start a *different* event on the one shared interpreter.
      #
      # A saved event id that no longer resolves to a live map event here
      # (its page's own conditions changed since, e.g. a switch flipped
      # elsewhere, or it belonged to a common event Auto-Start, id 0) still
      # resumes the raw command list -- each frame carries its own full
      # commands, not just a reference to a page -- it just has no map
      # character to answer a "this event" reference with, same as an
      # ordinary Auto-Start common event running on this same shared
      # interpreter today (#start_autostart's own `@active_event = nil`).
      def restore_foreground_event_exec
        saved = @state.foreground_event_exec
        frames = saved && saved[:frames]
        return unless frames && !frames.empty?
        @interpreter.restore_call_stack(frames)
        return unless @interpreter.running?
        ev_id = saved[:event_id]
        @active_event = (ev_id && ev_id != 0) ? @events.find { |e| e[:id] == ev_id } : nil
      end

      # Snapshot the current map's live Tile Substitution table onto
      # Game::State every frame, the same "survives a Save/Continue on this
      # map, resets on an ordinary re-visit" pattern #record_map_event_positions
      # keeps for event positions -- see Game::State#tile_substitutions and
      # Game::Map#substitution_snapshot.
      def record_tile_substitutions
        @state.tile_substitutions = @map.substitution_snapshot
      end

      # Build the Call Event resolver for the current map: common events keyed by
      # id (they are global) plus this map's raw events for map-event page calls.
      def build_resolver
        common = {}
        @common.each { |c| common[c[:id]] = c }
        map_events = (@map.unit.events rescue nil)
        EventResolver.new(common, map_events)
      rescue StandardError
        EventResolver.new({}, nil)
      end

      # Recompute the occupied-tile set from the events' current positions.
      def rebuild_event_tiles
        @event_tiles = {}
        @event_tiles_by_pos = {}
        @events.each { |e| index_event_tile(e, e[:char].x, e[:char].y) }
      end

      # Record event `e` as occupying (x, y) in both occupied-tile caches:
      # `@event_tiles`, which keeps a single event per tile (last write wins,
      # i.e. highest id -- see #event_id_at) for the "pick one event here"
      # queries (#event_at, action/touch triggers, encounter suppression), and
      # `@event_tiles_by_pos`, which keeps *every* live event on the tile for
      # #blockers_at. Two events legitimately share a tile in RPG2000 whenever
      # their priority types differ (a below-characters decal under a
      # same-as-characters NPC, say) -- collision has to see all of them, or a
      # blocking event can go unnoticed just because another one sharing its
      # tile was indexed after it.
      def index_event_tile(e, x, y)
        @event_tiles[[x, y]] = e
        (@event_tiles_by_pos[[x, y]] ||= []) << e
      end

      # Undo #index_event_tile for event `e` at (x, y): drops it from the
      # single-event cache only if it is still the one recorded there (a
      # same-tile companion may have since taken over that slot), and always
      # drops it from the multi-event list, pruning the list entirely once
      # empty so #blockers_at's `@event_tiles_by_pos[[x, y]]` miss stays a
      # plain nil rather than accumulating empty arrays.
      def deindex_event_tile(e, x, y)
        @event_tiles.delete([x, y]) if @event_tiles[[x, y]].equal?(e)
        list = @event_tiles_by_pos[[x, y]]
        return unless list
        list.delete_if { |o| o.equal?(e) }
        @event_tiles_by_pos.delete([x, y]) if list.empty?
      end

      # Every live event occupying (x, y), for collision -- unlike
      # `@event_tiles[[x, y]]` (a single, last-write-wins event meant for
      # "which one event is here" queries), this answers "is *anything* here
      # that would block", so two events sharing a tile on different priority
      # types both get a say instead of one silently shadowing the other.
      def blockers_at(x, y)
        @event_tiles_by_pos[[x, y]] || NO_BLOCKERS
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
      # The page's stored Move Speed is real RPG_RT's own 1..6 scale (liblcf
      # default 3, "Normal"); converted to this engine's internal 0..5 scale
      # (real minus 1, see the SLIDE_UNITS comment above) so it lines up with
      # #walk_slide_step/#jump_slide_step/#anim_frame_period, which otherwise
      # treated a raw event's Move Speed as one full notch faster than real
      # RPG_RT -- e.g. the default "Normal" (3) walked at the player's own
      # default rate (real 4) instead of the correct half-speed.
      def page_move_speed(page); page_field(:move_speed, 2) { (page.move_speed || 3) - 1 }; end
      def page_move_frequency(page); page_field(:move_frequency, 3) { page.move_frequency || 3 }; end
      def page_move_route(page); page_field(:move_route, nil) { page.move_route }; end
      def page_charset_name(page); page_field(:charset_name, nil) { page.charset_name }; end
      def page_charset_index(page); page_field(:charset_index, 0) { page.charset_index || 0 }; end
      def page_layer(page); page_field(:layer, 0) { page.layer || 0 }; end
      def page_overlap_forbidden(page); page_field(:overlap_forbidden, false) { page.overlap_forbidden ? true : false }; end
      def page_pattern(page); page_field(:pattern, 1) { p = page.pattern; (0..2).include?(p) ? p : 1 }; end
      def page_anim_type(page); page_field(:anim_type, 0) { page.animation_type || 0 }; end
      def page_translucent(page); page_field(:translucent, false) { page.translucent ? true : false }; end
      # Whether this page gates its own auto-start to one run per map visit (see
      # #start_autostart). No RPG2000/2003 page carries such a field -- a real
      # auto-start gates itself through its page *conditions*, and turning its
      # own switch off deactivates the page via #refresh_event_pages -- so this
      # is false on game data and only a check harness driving a one-shot
      # process without a condition gate sets it. `respond_to?` rather than a
      # bare read because an LCF record answers an unknown field by raising, and
      # this is read once per event per page rebuild.
      def page_guarded(page)
        page_field(:guarded, false) do
          page.respond_to?(:guarded) && page.guarded ? true : false
        end
      end

      # -- event execution ----------------------------------------------------

      # Cycle #193 investigation (docs/TODO.md, following up on cycle #191's
      # own "restoring a mid-wait UI request is out of scope" note): every
      # entry here except `@interpreter.waiting?` is either the single shared
      # FOREGROUND interpreter or genuinely scene-wide state
      # (@message/@number_input, set identically whichever interpreter --
      # foreground or any @parallels entry -- raised the Show Message/Show
      # Choices/Input Number that opened them, see #message_window_open?'s
      # own comment; @battle, similarly shared regardless of which
      # interpreter opened it, just above). Confirmed by tracing
      # #drive_parallel_wait's own :message/:choice/:number cases
      # (mruby-rpg2k/mrblib/scene/map.rb): a Parallel Process's own Show
      # Message/Choices/Input Number opens the exact same @message/
      # @number_input #open_message/#open_number_input already write for the
      # foreground, not a per-interpreter mechanism of its own -- so a
      # genuine Save is unreachable while ANY interpreter sits on one of
      # those three specific waits, not merely the foreground's own.
      #
      # This method never inspects any @parallels entry's own #waiting?/
      # #wait_kind directly, though -- so a wait kind that neither sets
      # @message/@number_input nor opens @battle is NOT covered when it is a
      # *parallel* process (not the foreground) sitting on it. The one such
      # wait kind reachable without a message window already blocking it
      # first: a waiting Key Input Proc (Cmd::KEY_INPUT_PROC, 11610, wait
      # flag set) issued from a Common Event's or a Map Event's own Parallel
      # Process -- see scripts/rpg2k_scene_check.rb's own check proving this
      # reachable (a Parallel Process genuinely parked on Key Input, no
      # message window up anywhere, still lets #try_open_menu's ordinary
      # Cancel-key shortcut open the menu). Judged out of scope to restore
      # this cycle (a documented follow-up, not silently dropped) --
      # #call_stack_snapshot's own "does not restore a mid-wait UI request"
      # scope limit already covers what actually happens: the save still
      # resumes at the right command, just past the Wait For Key Input
      # entirely, with the requested variable left holding 0 rather than a
      # genuine key code.
      def event_busy?
        @message || @number_input || @interpreter.running? || @interpreter.waiting? ||
          # A battle a Parallel Process opened (#drive_parallel_wait's :battle
          # case) is exactly as busy as one the foreground itself opened --
          # before that fix existed only @interpreter could ever hold
          # @battle, so @interpreter.waiting? alone already covered this; now
          # that a Common Event's or a map event's own Parallel Process can own
          # the single battle slot too, its mere presence has to gate ordinary
          # player movement/menu/Auto-Start here on its own, the same way
          # #parallels_paused? already gates every *other* parallel process on
          # it.
          !@battle.nil?
      end

      # Whether a message window or choice list (Show Message / Show Choices /
      # an Input Number embedded in one) is currently on screen -- queried by
      # the interpreter via map_info (see #event_position, #character_screen_
      # position for the same pattern) so Show/Move/Erase Picture can suppress
      # themselves per yado.tk: picture commands are fully suppressed while any
      # message window or choice list is open, anywhere in the scene, *including*
      # a still-running parallel process (#step_parallels keeps parallel
      # processes advancing during a message window; see #parallels_paused?,
      # which does *not* treat a message window as a pause condition -- this is
      # the separate, narrower rule that does).
      def message_window_open?
        !!(@message || @number_input)
      end
      public :message_window_open?

      # Whether bystander map events should keep stepping their own autonomous
      # movement / forced routes while a message window sits open -- RPG2000's
      # Message Options command has a dedicated "move other events during
      # message" toggle (LCF field 44, `message_continue_events` /
      # `Game::MessageConfig#continue_events`) for exactly this, defaulting off
      # (RPG_RT's own default is "other events hold still"). Scoped to a message
      # window specifically, not #event_busy? in general -- an Autorun grinding
      # through non-blocking commands with no message up still freezes the rest
      # of the map either way, matching yado.tk ("Autorun ... blocks other
      # events too, unless 'move other events during message wait' is on").
      def events_move_during_message?
        message_window_open? && @state.message_config.continue_events
      end

      # Whether #step_parallels should sit this frame out. Per yado.tk, real
      # RPG_RT only pauses background parallel processes for the Menu screen
      # (already structural here -- Scene::Map#update simply is not called
      # while Scene::Menu sits on top) and the Battle screen; a message window
      # or a foreground event parked on a blocking wait (Show Text, Wait, ...)
      # is *not* a pause condition, only a foreground event actively grinding
      # through non-blocking commands is ("parallel processes keep running
      # during an Autorun's blocking waits ... but are blocked while the
      # Autorun executes non-blocking commands"). `@interpreter.running?`
      # stays true for a foreground event's whole lifetime, including while
      # it is parked waiting, so `!waiting?` is what actually isolates the
      # still-bursting case (in practice: a command list heavy enough to spill
      # past a single frame's MAX_STEPS budget without hitting a wait).
      def parallels_paused?
        !@battle.nil? || (@interpreter.running? && !@interpreter.waiting?)
      end

      # Drive the just-started foreground Auto-Start process, then -- yado.tk
      # "Autorun cascading within one frame" -- keep looking for a *different*,
      # not-yet-run Auto-Start map/common event to start the instant this one's
      # own command list fully drains with no Wait/Show Text left pending, all
      # within this same real frame, rather than waiting for the next one.
      # Ported from a reference implementation, NOT independently confirmed
      # against genuine RPG_RT under wine: its foreground-event update drives
      # the single shared foreground interpreter inside a loop that keeps
      # going while the interpreter is not running and has not hit its own
      # loop limit -- the instant a pushed event's own command list empties
      # out, that same call immediately rescans every event still waiting on
      # foreground execution and pushes another one too, all sharing one
      # loop-count/loop-limit (10000) budget rather than ending the frame the
      # first time the interpreter goes idle. `Scene::Map#update`'s own
      # foreground dispatch
      # used to call `#start_autostart` exactly once per real frame, so a
      # second, distinct not-yet-run Auto-Start event on the same map had to
      # wait for the *next* real frame even when the first one's own script
      # ended with no Wait at all. Each distinct id can still only ever be
      # picked up once per visit (`@started_auto`/`@started_common` are
      # untouched by this), so the loop is naturally bounded by the finite
      # number of map/common Auto-Start events on the map and stops the
      # instant nothing new starts, or the interpreter is left running/
      # waiting (mid-script, or genuinely parked on a Wait/Show Text/etc.) for
      # a future frame to continue.
      #
      # The other half of this same finding -- whether the very *same* event,
      # once its own script hits its natural end with no Wait, immediately
      # restarts from the top and keeps consuming this frame's budget (a
      # documented worked example: a one-line Auto-Start common event
      # advancing a variable 5000 times within a single frame, 10000 steps / 2
      # per lap) -- is a separate, much larger question left open, see the
      # "Autorun (auto-start) events run at most once per map visit, not once
      # per frame" bullet in docs/TODO.md: changing that would also require
      # every existing Auto-Start test in this suite to arrange for its own
      # event to fall out of eligibility once done, which this narrower,
      # cascade-only fix does not.
      def drive_autostart_cascade
        loop do
          drive_event
          break if event_busy?
          start_autostart
          break unless event_busy?
        end
      end

      # Start the first not-yet-run auto-start process in the foreground: map
      # events with an auto-start trigger, then auto-start common events (whose
      # switch gate, if any, is on). A guarded auto-start (`guarded:`, read off
      # the page by #page_guarded for a harness that gates its own one-shot
      # process) runs at most once per visit (@auto_once), so it does not re-fire
      # every frame; an ungated one -- which is every auto-start on real game
      # data, where a page gates itself through its own conditions instead --
      # may re-fire on later frames (Scene::Map#update clears @started_auto each
      # frame) but is still skipped within a frame so distinct auto-starts
      # cascade. Parallel processes are driven separately by #step_parallels.
      def start_autostart
        ev = @events.find do |e|
          e[:trigger] == TRIGGER_AUTO_START && e[:commands] &&
            !@started_auto[e[:id]] &&
            !(e[:guarded] && @auto_once[e[:id]])
        end
        if ev
          @started_auto[ev[:id]] = true
          @auto_once[ev[:id]] = true if ev[:guarded]
          @active_event = ev
          @interpreter.start(ev[:commands])
          @interpreter.event_id = ev[:id]
          return
        end

        ce = @common.find do |c|
          c[:trigger] == Game::CommonEvent::AUTO_START && c[:commands] &&
            common_gate_open?(c) && !@started_common[c[:id]] &&
            !(c[:guarded] && @auto_once_common[c[:id]])
        end
        return unless ce
        @started_common[ce[:id]] = true
        @auto_once_common[ce[:id]] = true if ce[:guarded]
        @active_event = nil # a common event has no "this event" map character
        @interpreter.start(ce[:commands])
      end

      # A common event's switch gate: open unless it needs a flag that is off.
      def common_gate_open?(c)
        return true unless c[:need_flag]
        @state.switches[c[:switch_id]]
      end

      # Build the background (parallel-process) interpreters: parallel common
      # events plus map events with a parallel trigger, in that order (see the
      # order comment inside, below). Each gets its own Game::Interpreter,
      # looped by #step_parallels; a common event that needs a flag carries
      # its gate switch so it only runs while that switch is on.
      #
      # A Common Event's own parallel process, unlike a Map Event's, keeps its
      # interpreter position across a Transfer Player: called again by
      # #perform_teleport on this same live Scene::Map, this reuses the
      # still-running Game::Interpreter for any common event id it already had
      # one for -- full fidelity (call stack, in-flight wait timer, everything,
      # since it is the very same object), not a reconstruction -- instead of
      # building a fresh one. Map events are always rebuilt fresh from the
      # destination map's own event table on a genuine map change (Transfer
      # Player, or the very first build for this scene), matching the existing
      # per-visit-reset behaviour: a real "visit" gives a map event's own
      # parallel process no id that means anything on the map being left, so
      # there is nothing sound to reuse. This still holds after cycle #193:
      # #new_parallel now *can* resume a map event's own Parallel Process
      # from a captured call stack (Game::State#map_event_exec), but only
      # across a genuine Save/Continue on the SAME map -- #perform_teleport
      # deliberately clears #map_event_exec on every map change for the
      # identical reason it already clears #map_event_positions (a map
      # event's own id is per-map, not global, so a stale entry would
      # misapply to an unrelated same-numbered event on the destination map)
      # -- so an ordinary Transfer Player still finds nothing there to
      # resume from and rebuilds fresh, exactly as before.
      #
      # `preserve_map_events:` is the one exception, passed only by
      # #rebuild_events_preserving_positions: that call does not change maps at
      # all, it just re-selects pages after a Control Switch/Variable/item/party
      # write, and #pages_changed? triggering it is a map-wide check -- any
      # *other* event's page flipping runs this same rebuild, discarding and
      # rebuilding every event's Game::Character (see #build_events), this
      # event's included, even though this event's own page selection never
      # moved. Without this, a Map Event's Parallel Process would restart from
      # the top (losing its call stack and any in-flight Wait countdown, the
      # same fidelity #resumable_index cannot capture) every time some
      # unrelated event on the map reselected its page -- not on this event's
      # own re-trigger, which does still restart it fresh, matching yado.tk's
      # "always restarts from the top on every re-trigger". A map event whose
      # own page selection *did* just change (a different `page`, so a
      # different `commands` array -- #build_event always builds a fresh
      # Game::Character/command list from the freshly-selected page) still gets
      # a brand new interpreter either way, exactly as before.
      #
      # On the very first build for this scene (a brand new game, or the fresh
      # Scene::Map Continue/#initialize builds from a loaded save), there is no
      # previous @parallels to reuse from, so #new_parallel instead consults
      # whatever Game::State carries from the save it was built from: for a
      # common event, #common_event_exec's own full call-stack snapshot first,
      # falling back to the coarser, index-only #common_event_progress cursor
      # only when that has nothing; for a map event (cycle #193), the
      # identically-shaped #map_event_exec -- there is no older coarse-cursor
      # fallback to fall back to here, since none ever existed for a map
      # event's own Parallel Process before this.
      #
      def build_parallels(preserve_map_events: false)
        previous_common = {}
        previous_map = {}
        (@parallels || []).each do |p|
          if p[:common_event_id]
            previous_common[p[:common_event_id]] = p
          elsif preserve_map_events && p[:event]
            previous_map[p[:event][:id]] = p
          end
        end
        @parallels = []
        # Common events are pushed before map events, matching a reference
        # implementation's fixed frame order (NOT independently confirmed
        # against genuine RPG_RT under wine): its per-frame map update always
        # updates common events before map events, with no interleaving by id
        # across the two groups -- its common-event handling only ever builds
        # an interpreter for a Parallel-trigger common event, so that call is
        # this engine's exact
        # counterpart to #step_parallels' common-event half. A common event's
        # write this same real frame (e.g. a gate switch, or a value another
        # process reads) is therefore visible to a map event's own parallel
        # process reading it later in the same #step_parallels sweep, never
        # the other way around -- #step_parallels/#step_parallel walk
        # @parallels in array order, so the order they are pushed in here is
        # the order they run in.
        @common.each do |c|
          next unless c[:trigger] == Game::CommonEvent::PARALLEL && c[:commands]
          gate = c[:need_flag] ? c[:switch_id] : nil
          @parallels.push(previous_common[c[:id]] ||
                           new_parallel(c[:commands], gate, nil, c[:id]))
        end
        live_map_ids = {}
        @events.each do |e|
          next unless e[:trigger] == TRIGGER_PARALLEL && e[:commands]
          live_map_ids[e[:id]] = true
          prior = previous_map[e[:id]]
          if prior && prior[:commands].equal?(e[:commands])
            # Same page, same command list -- only the surrounding
            # Game::Character objects were rebuilt (see #build_events), so keep
            # the still-running interpreter and just re-point its bookkeeping
            # at this rebuild's fresh event hash.
            prior[:event] = e
            @parallels.push prior
          else
            @parallels.push new_parallel(e[:commands], nil, e, nil)
          end
        end
        # yado.tk, multiply corroborated: a Parallel Process whose own event's
        # appearance condition goes false *mid-run* keeps executing in the
        # background rather than being aborted -- it just has nothing left to
        # draw or collide with. #build_events already drops such an event from
        # @events/@event_tiles entirely (no page satisfied its conditions), so
        # without this it would silently vanish from @parallels too, on the
        # very next in-place page-reselection sweep this same event's own
        # write triggers. Carried forward under its stale event/character
        # reference -- unreachable from @events/@event_tiles, so harmless --
        # for as long as it keeps running; only while `preserve_map_events` is
        # set (an in-place, same-map reselection), matching every other
        # bystander-preservation rule in this method. If its conditions later
        # pick the very same page again, the ordinary reuse above already
        # reattaches this same interpreter instead of starting a fresh one.
        if preserve_map_events
          previous_map.each do |id, prior|
            @parallels.push(prior) unless live_map_ids[id]
          end
        end
      rescue StandardError
        @parallels = []
      end

      # Build one background process. `event` is the owning map event (so a Move
      # Event targeting "this event" resolves) or nil for a common event;
      # `common_event_id` is that common event's own id, nil for a map event --
      # it keys both the teleport-time reuse in #build_parallels above and the
      # save-file continuation this seeds from below.
      #
      # Genuine full-fidelity continuation is tried first: Game::State
      # #common_event_exec (driven from a real .lsd's chunk 114) for a common
      # event, or -- cycle #193 -- Game::State#map_event_exec (chunk 111
      # field 108) for a map event's own Parallel Process, keyed by `event`'s
      # own id rather than `common_event_id` since a map event has none.
      # Unlike the older #common_event_progress cursor, either one also
      # covers a process saved mid a nested Call Event. #common_event_progress
      # only ever gets a look-in when this has nothing for the id (an older
      # save, or one written before cycle #191); there is no equivalent
      # fallback for a map event, since no such cursor ever existed for one.
      def new_parallel(commands, gate_switch, event, common_event_id)
        it = Game::Interpreter.new(@state)
        it.resolver = @interpreter.resolver
        it.map_info = self
        saved_frames = if common_event_id
                         @state.common_event_exec[common_event_id]
                       elsif event
                         @state.map_event_exec[event[:id]]
                       end
        if saved_frames && !saved_frames.empty?
          it.restore_call_stack(saved_frames)
        else
          resume_at = common_event_id && @state.common_event_progress[common_event_id]
          if resume_at
            it.start_at(commands, resume_at)
          else
            it.start(commands)
          end
        end
        it.event_id = event && event[:id]
        { interp: it, commands: commands, gate_switch: gate_switch,
          wait_timer: nil, event: event, common_event_id: common_event_id }
      end

      # Advance every background parallel process one frame. They loop their
      # command list and honour Wait; as background processes they do not drive
      # the message/choice/teleport UI (those requests are simply resumed so the
      # process keeps running). Called every frame regardless of a message
      # window or a parked foreground event -- see #parallels_paused? for the
      # (narrower) actual pause conditions.
      def step_parallels
        # Iterate a copy: an Erase Event in a parallel process removes it from
        # @parallels mid-loop (see erase_event). A plain while loop instead of
        # #each avoids allocating a Proc+env for the block on every single
        # frame -- mruby's `for` is sugar for the identical #each call (see
        # its NODE_FOR codegen), so it would not save anything here; only a
        # loop with no block at all does.
        snapshot = @parallels.dup
        i = 0
        size = snapshot.size
        while i < size
          step_parallel(snapshot[i])
          i += 1
        end
      end

      # Keep a Parallel Process's own battle advancing once it has opened one
      # (#drive_parallel_wait's :battle case). @battle's mere presence pauses
      # #step_parallels for every *other* parallel process for the fight's
      # duration (#parallels_paused?, "Common events never run during
      # battle") -- but the one that opened it is not a bystander: it still
      # needs exactly the same per-frame #drive_battle service #drive_event's
      # own :battle case already gives a foreground-opened fight, or the
      # fight it opened would never advance past the single frame it opened
      # on. Called from #update only when #parallels_paused? already skipped
      # the ordinary #step_parallels pass this same frame (see there), so
      # this never double-steps the owner's own entry. A no-op once the
      # battle belongs to the foreground (nothing here to step) or there is
      # no battle open at all.
      def step_battle_owner_parallel
        return unless @battle
        owner = @battle.owner
        return if owner.nil? || owner.equal?(@interpreter)
        i = 0
        size = @parallels.size
        while i < size
          pp = @parallels[i]
          if pp[:interp].equal?(owner)
            step_parallel(pp)
            return
          end
          i += 1
        end
      end

      def step_parallel(p)
        return if p[:gate_switch] && !@state.switches[p[:gate_switch]]
        it = p[:interp]
        # Ported from a reference implementation's model, NOT independently
        # confirmed against genuine RPG_RT under wine: each Parallel Process
        # is its own interpreter there, so it gets its own frame-shared step
        # budget, independent of the foreground's -- see
        # Game::Interpreter::MAX_STEPS.
        # #step_parallel is
        # called at most once per real frame per process (#step_parallels'
        # own once-a-frame loop, or #step_battle_owner_parallel's mutually
        # exclusive stand-in for the one this fight belongs to), so resetting
        # here is exactly the once-per-frame reset MAX_STEPS' own comment
        # requires, however many times `it.update` below ends up called this
        # same frame (a same-frame Wait/Animation resume can call it twice).
        it.reset_frame_steps
        if it.waiting?
          wait_kind = it.wait_kind
          drive_parallel_wait(p, it)
          # A plain Wait resolves the instant its timer elapses; keep spending
          # this same frame's step budget instead of losing a frame to the
          # resume, matching drive_event's foreground handling (see there for
          # why: Wait 0.0 sec must cost exactly one frame). A Show Battle
          # Animation's own :animation wait gets the identical same-frame
          # treatment now too, for the identical reason (see #drive_event's
          # own :animation case): when *this* process's own animation
          # finishes naturally inside #drive_map_animation (not cut off by a
          # different process -- that resumes the *other* interpreter, from
          # its own step_parallel turn, and is unaffected by this check), it
          # used to sit merely unparked until the next real frame's
          # step_parallel call before its own next command ever ran, one
          # frame later than real RPG_RT -- yado.tk's "chaining two Show
          # Battle Animation calls back-to-back produces a visible one-frame
          # stutter", the parallel-process half. The rest of this same-frame
          # list is ported from a reference implementation's model, NOT
          # independently confirmed against genuine RPG_RT under wine:
          # Tint/Flash Screen, Move Picture and Flash Sprite's own wait flags
          # are the identical wait-time countdown its plain Wait command uses
          # there, not a "poll until still animating" mechanism, so
          # :screen/:picture/:sprite_flash get the same same-frame treatment
          # here too -- the identical fix #drive_event's foreground
          # dispatcher just received for those three wait kinds. :movement's
          # own wait-movement check in its update loop is not an
          # unconditional `break` either, and each of the four `_blocked`
          # kinds' underlying command (Show/Move/Erase Picture, Teleport/
          # Recall To Location, Enemy Encounter, Change Exp/Change Level)
          # just returns false with the command index untouched while
          # blocked -- its own loop re-executes that identical command the
          # instant the block clears, in that same frame, the same as any
          # other retried command -- so all five join the same-frame list
          # too, matching #drive_event's foreground dispatcher exactly. A
          # waiting Key Input Processing command's own block has the
          # identical `return false` shape, so it joins the list too, and so
          # does Message Options / Change Face Graphic's own block, and so
          # does Erase/Show Screen's own block. Other wait kinds keep their
          # old one-frame-per-call pacing.
          unless (wait_kind == :wait || wait_kind == :animation ||
                  wait_kind == :screen || wait_kind == :picture ||
                  wait_kind == :sprite_flash || wait_kind == :movement ||
                  wait_kind == :picture_blocked || wait_kind == :teleport_blocked ||
                  wait_kind == :battle_blocked || wait_kind == :exp_level_blocked ||
                  wait_kind == :key_input_blocked || wait_kind == :message_config_blocked ||
                  wait_kind == :screen_blocked) &&
                 !it.waiting?
            apply_interpreter_requests(it, p[:event])
            return record_parallel_progress(p)
          end
        end
        if it.running?
          it.update
        else
          it.start(p[:commands]) # loop the process
          # #start clears the "this event" id, so re-attach it on every lap or
          # the second pass would answer the process's own position queries with
          # nothing.
          it.event_id = p[:event] && p[:event][:id]
          it.update
        end
        # Same "starts on the same real frame the command runs" fix as
        # #drive_event's own mirrored spot above, for a Parallel Process's own
        # waited-for Show Battle Animation -- #drive_parallel_wait's :animation
        # case (drive_map_animation) used to only ever be reached the *next*
        # time this method found `it` already parked on that wait.
        drive_parallel_wait(p, it) if it.waiting? && it.wait_kind == :animation
        apply_interpreter_requests(it, p[:event])
        record_parallel_progress(p)
      rescue StandardError
        nil
      end

      # Snapshot a Parallel Process's current position onto Game::State, so a
      # fresh Scene::Map built later from this state (a genuine save/load,
      # not a Transfer Player -- see #build_parallels) can resume it instead
      # of restarting at the top. Handles both halves of @parallels:
      #
      #   - A Common Event's own Parallel Process (`p[:common_event_id]`
      #     non-nil) records two things, cycle #191 having added the second
      #     on top of the pre-existing first:
      #       - Game::State#common_event_progress (Game::Interpreter
      #         #resumable_index): only overwrites the stored checkpoint when
      #         the interpreter's position is cleanly capturable right now; a
      #         tick that returns nil (mid a nested Call Event) simply leaves
      #         the last known-good checkpoint in place rather than clearing
      #         it. Still the only mechanism the portable Marshal save
      #         (#to_h/.load) carries.
      #       - Game::State#common_event_exec (Game::Interpreter
      #         #call_stack_snapshot): the fuller call-stack snapshot a real
      #         `.lsd`'s chunk 114 now backs, captured whenever the
      #         interpreter is running at all -- including mid a nested Call
      #         Event, unlike #resumable_index above.
      #   - A Map Event's own Parallel Process (`p[:event]` non-nil,
      #     `p[:common_event_id]` nil -- cycle #193) records only the fuller
      #     snapshot, into Game::State#map_event_exec, keyed by the owning
      #     map event's own id: there is no #common_event_progress-style
      #     coarse cursor to maintain in parallel here, since none ever
      #     existed for a map event's own Parallel Process before this (see
      #     #map_event_exec's own comment). Previously this method returned
      #     immediately for this case (`return unless p[:common_event_id]`)
      #     -- a map event's own Parallel Process got no checkpoint
      #     whatsoever and always restarted fresh; see this method's own
      #     history in docs/TODO.md for why.
      def record_parallel_progress(p)
        if p[:common_event_id]
          idx = p[:interp].resumable_index
          @state.common_event_progress[p[:common_event_id]] = idx if idx
          frames = p[:interp].call_stack_snapshot
          @state.common_event_exec[p[:common_event_id]] = frames if frames
        elsif p[:event]
          frames = p[:interp].call_stack_snapshot
          @state.map_event_exec[p[:event][:id]] = frames if frames
        end
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
        elsif it.wait_kind == :wait_key_enter
          # RPG2003's Wait-for-Decision-key mode, reached from a parallel
          # process's own command list -- see #drive_wait_key_enter, the
          # foreground's equivalent; #message_window_open? already blocks a
          # parallel process for other reasons only when it does not (see
          # #parallels_paused?), so this needs the same explicit guard here.
          it.resume if !message_window_open? && Input.trigger?(Input::C)
        elsif it.wait_kind == :animation
          # A Show Battle Animation with its wait flag set, issued from a
          # parallel process rather than the foreground event -- shares the
          # same single on-screen animation slot #drive_map_animation already
          # drives for the foreground, see there.
          drive_map_animation(it)
        elsif it.wait_kind == :game_over
          # A wipe-triggering command (Change HP, Change Condition, ...) run
          # from a Parallel Process's own interpreter raises the same
          # :game_over wait #check_game_over uses for the foreground -- ending
          # the game does not depend on which interpreter noticed the wipe.
          # Before this branch existed this fell into the generic "background:
          # ignore message/choice/teleport requests" #resume below, which
          # silently cleared the wait and let the process carry on with a
          # fully-dead party never reaching the Game Over screen.
          perform_game_over(it)
        elsif it.wait_kind == :battle
          # Battle Processing (Enemy Encounter) issued from a Parallel
          # Process -- a Common Event's or a map event's own -- opens and
          # drives the same single global battle screen a foreground-issued
          # one does, the same shared-slot shape already fixed above for
          # Show Battle Animation's :animation wait (#drive_map_animation /
          # @map_animation_interp). Before this branch existed this fell
          # into the generic "background: ignore message/choice/teleport
          # requests" #resume below: the request sat on `it.battle_request`
          # unread (#drive_battle used to only ever consult the foreground
          # @interpreter's own copy), and `it` was resumed unconditionally
          # the very next frame as though the command had been a no-op --
          # no battle screen ever appeared, and any [Victory]/[Escape]/
          # [Defeat] handler right after the command in `it`'s own list
          # never ran either. #drive_battle itself now takes the interpreter
          # to drive explicitly (`it` here), and keeps being called back
          # into on every later frame by #step_battle_owner_parallel, since
          # @battle's own presence pauses the ordinary #step_parallels
          # pass this entry would otherwise need for that (#parallels_paused?).
          drive_battle(it)
        elsif it.wait_kind == :movement
          # Proceed With Movement / Force Complete Move issued from a
          # Parallel Process: block that process until every targeted
          # character's forced route has actually finished, the same as
          # #drive_event's own :movement branch does for the foreground --
          # docs/TODO.md ("Move All / Force Complete Move ... blocks Event
          # Content at that command until every targeted character's route
          # finishes"), which used to apply to a foreground Autorun only.
          # Before this branch existed this fell into the generic #resume
          # below too, so the command never actually blocked anything issued
          # from a parallel process -- it read as a fire-and-forget request
          # regardless of "wait for completion", and a target stuck forever
          # (e.g. hidden map event, see the sibling foreground check) never
          # froze the process the way real RPG_RT does.
          #
          # Deliberately calls #forced_movement_done? rather than
          # #step_forced_movement: the routes themselves are already stepped
          # exactly once this frame elsewhere -- by the ordinary #step_events
          # pass in #update's not-busy branch when the foreground is idle, or
          # by the foreground's own #step_forced_movement call when it is
          # itself parked on :message/:wait/:movement -- so stepping them
          # again here would double-advance every forced route on any frame
          # both a parallel process and the foreground happen to be waiting
          # on movement at once.
          it.resume if forced_movement_done?
        elsif it.wait_kind == :teleport
          # Transfer Player / Recall to Location issued from a Parallel
          # Process (yado.tk: "a Transfer Player command inside one [a
          # Parallel Process] lets subsequent commands run while the new map
          # is still loading"). Before this branch existed this fell into the
          # generic "background: ignore ... teleport requests" #resume below,
          # so a Parallel Process's own warp silently never happened at all --
          # not merely mistimed. #perform_teleport itself resumes the
          # *foreground* @interpreter at its end (mirroring #drive_event's own
          # :teleport dispatch above), so `it` -- this parallel interpreter,
          # always a distinct object from @interpreter -- still needs its own
          # explicit #resume once the map has actually changed.
          # #build_parallels (run inside #perform_teleport) already keys a
          # Common Event's own parallel process off its common_event_id and
          # reuses the very same interpreter object across the rebuild
          # (`previous_common`, unconditionally -- unlike a map event's own
          # parallel process, which is only carried over under
          # `preserve_map_events:`, a keyword #perform_teleport never passes),
          # so `p`/`it` themselves are unaffected by the rebuild here and can
          # simply resume afterward, continuing the rest of the process's own
          # command list on the new map. A *map* event's own Parallel Process
          # has no such reuse for a genuine map change, so it naturally drops
          # out of the rebuilt @parallels and this #resume call is its last --
          # matching the separately-documented "for a map event specifically,
          # its context is gone post-transfer".
          perform_teleport(it.teleport)
          it.resume
        elsif it.wait_kind == :message
          # Show Text issued from a Parallel Process: real RPG_RT has exactly
          # one global message window, so this one shares @message with the
          # foreground rather than getting a background mechanism of its own
          # (docs/TODO.md "Two message windows can never be shown
          # simultaneously -- a hard engine limit"). Before this branch
          # existed this fell into the generic "background: ignore message/
          # choice requests" #resume below, so a Parallel Process's own Show
          # Text silently never displayed at all -- the interpreter sailed
          # straight past it as if the command had not run. #open_message's
          # own pre-existing "already open" guard (see there) is what
          # enforces the one-window-at-a-time rule here: this call only opens
          # a window when @message is nil, and simply leaves `it` parked on
          # its own :message wait otherwise, to retry next frame once
          # whichever window is currently up (the foreground's or another
          # Parallel Process's) closes -- the same block-and-retry shape
          # already used for :screen/:picture/:sprite_flash just below.
          # #drive_event's own @message dispatch (unconditional on
          # #event_busy?, which @message alone already forces true) then
          # drives it to completion and resumes the tracked `interp:` owner,
          # not always @interpreter, matching the generalisation that already
          # threads a Common Event Parallel Process's own Show Battle
          # Animation through a tracked owner (@map_animation_interp) rather
          # than hardcoding the foreground.
          #
          # Gated on #forced_movement_done? rather than #step_forced_movement
          # for the same reason the :movement branch above is: the pending
          # routes are already stepped once a frame elsewhere, and stepping
          # them again here would double-advance one on any frame both the
          # foreground and a Parallel Process happen to reach their own
          # Show Text on at once.
          if @message.nil? && forced_movement_done?
            open_message(it.message_lines, false, interp: it)
          end
        elsif it.wait_kind == :choice
          # Show Choices issued from a Parallel Process: the same shared
          # single window as :message just above, with no implicit-auto-run
          # gate of its own -- matching #drive_event's own ungated :choice
          # dispatch, since only Wait/Show Text are documented auto-run
          # trigger points, not Show Choices. `@message[:interp].equal?(it)`
          # covers the *merged* shape too -- a Show Choices immediately
          # following this same process's own Show Text in the same window
          # (#drive_text_message's `awaiting_followup`, resumed once typing
          # finishes but not yet reached this command): @message is not nil
          # there (it is this process's own still-open window), so the plain
          # `@message.nil?` guard alone would leave it parked forever, never
          # reaching #open_message's existing "append instead of opening
          # fresh" branch. A genuinely new, unrelated request still waits its
          # turn until whichever window is currently up closes.
          if @message.nil? || @message[:interp].equal?(it)
            open_message(it.choice_labels, true, interp: it)
          end
        elsif it.wait_kind == :number
          # Input Number issued from a Parallel Process: the same shared
          # window as :message/:choice above, standalone panel and the
          # merged-onto-a-preceding-Show-Text shape alike (#open_number_input
          # already tells the two apart via @message[:awaiting_followup], the
          # same way #open_message does for :choice, just above). Before this
          # branch existed this wait kind fell into the generic #resume
          # below, so an Input Number issued from a Parallel Process was
          # silently dropped outright -- docs/TODO.md "Left open: Input
          # Number (:number) issued from a Parallel Process is still
          # silently dropped."
          if @message.nil? || @message[:interp].equal?(it)
            open_number_input(it.input_digits, interp: it)
          end
        elsif it.wait_kind == :screen
          # Erase/Show/Tint/Flash/Pan/Shake Screen issued with its own wait
          # flag from a Parallel Process: block that process until the effect
          # settles, the same as #drive_event's own :screen branch does for
          # the foreground. Before this branch existed this fell into the
          # generic #resume below, so a background screen-effect wait was a
          # fire-and-forget no-op regardless of "wait for completion" set on
          # the command -- the effect itself already ran (#apply_interpreter_
          # requests runs for a parallel process's own requests too), only
          # the wait never actually held anything up.
          it.resume unless @state.screen.busy?
        elsif it.wait_kind == :picture
          # Move Picture's own wait flag, the parallel-process equivalent of
          # the :screen case just above.
          it.resume unless @state.pictures_moving?
        elsif it.wait_kind == :picture_blocked
          # A Show/Move/Erase Picture command issued from a Parallel Process
          # while a message window or choice list is open -- the parallel-
          # process equivalent of #drive_event's own :picture_blocked case
          # just above, see #block_pending_picture_command for the citation.
          it.resume unless message_window_open?
        elsif it.wait_kind == :teleport_blocked
          # A Transfer Player / Recall to Location command issued from a
          # Parallel Process while a message window or choice list is open --
          # the parallel-process equivalent of #drive_event's own
          # :teleport_blocked case, see #block_pending_teleport_command for
          # the citation. Before this branch existed a blocked teleport
          # simply never reached :teleport_blocked at all (the guard is what
          # raises it in the first place); this and the interpreter-side fix
          # land together.
          it.resume unless message_window_open?
        elsif it.wait_kind == :battle_blocked
          # A Battle Processing / Enemy Encounter command issued from a
          # Parallel Process while a message window or choice list is open --
          # the parallel-process equivalent of #drive_event's own
          # :battle_blocked case, see #block_pending_battle_command for the
          # citation.
          it.resume unless message_window_open?
        elsif it.wait_kind == :exp_level_blocked
          # A "show message"-flagged Change EXP / Change Level command
          # issued from a Parallel Process while a message window or choice
          # list is open -- the parallel-process equivalent of #drive_event's
          # own :exp_level_blocked case, see
          # Interpreter#block_pending_exp_level_command for the citation.
          it.resume unless message_window_open?
        elsif it.wait_kind == :key_input_blocked
          # A waiting Key Input Processing command issued from a Parallel
          # Process while a message window or choice list is open -- the
          # parallel-process equivalent of #drive_event's own
          # :key_input_blocked case, see
          # Interpreter#block_pending_key_input_command for the citation.
          it.resume unless message_window_open?
        elsif it.wait_kind == :message_config_blocked
          # A Message Options / Change Face Graphic command issued from a
          # Parallel Process while a *different* message window or choice
          # list is open -- the parallel-process equivalent of #drive_event's
          # own :message_config_blocked case, see
          # Interpreter#block_pending_message_config_command for the citation.
          it.resume unless message_window_open?
        elsif it.wait_kind == :screen_blocked
          # An Erase Screen / Show Screen command issued from a Parallel
          # Process while a message window or choice list is open -- the
          # parallel-process equivalent of #drive_event's own :screen_blocked
          # case, see Interpreter#block_pending_screen_command for the
          # citation.
          it.resume unless message_window_open?
        elsif it.wait_kind == :sprite_flash
          # Flash Sprite's own wait flag, the parallel-process equivalent of
          # the :screen/:picture cases just above.
          it.resume unless sprite_flashing?
        elsif it.wait_kind == :name_input
          # Enter Hero Name issued from a Parallel Process. Ported from a
          # reference implementation, NOT independently confirmed against
          # genuine RPG_RT under wine: its Enter Hero Name handling is the
          # very same method for the foreground and every parallel process's
          # own interpreter, gated only on whether a message is currently
          # active -- there is no "foreground only" restriction. Before this branch existed this
          # fell into the generic #resume below, so a Parallel Process's own
          # Enter Hero Name silently never opened the screen at all -- the
          # command read as a no-op. The single name-entry widget is shared
          # the same way the message window is (`@name_ui[:interp]` mirrors
          # `@message[:interp]`, see #drive_name_input): block until
          # whichever message window or name-entry screen is currently up
          # closes, then drive this one.
          if (@name_ui.nil? || @name_ui[:interp].equal?(it)) && @message.nil?
            drive_name_input(it)
          end
        elsif it.wait_kind == :shop
          # Open Shop issued from a Parallel Process. Ported from a
          # reference implementation, NOT independently confirmed against
          # genuine RPG_RT under wine: its Open Shop handling is the very
          # same method for the foreground and every parallel process's own
          # interpreter, gated only on whether a message is currently active
          # -- there is no "foreground only" restriction. Before this branch existed this
          # fell into the generic #resume below, so a Parallel Process's own
          # Open Shop silently never opened the screen at all -- the command
          # read as a no-op. The single shop screen is shared the same way
          # the message window and name-entry widget are (`@shop[:interp]`
          # mirrors `@name_ui[:interp]` / `@message[:interp]`, see
          # #drive_shop / #leave_shop): block until whichever message
          # window, name-entry screen, or shop screen is currently up
          # closes, then drive this one.
          if (@shop.nil? || @shop[:interp].equal?(it)) && @message.nil? && @name_ui.nil?
            drive_shop(it)
          end
        elsif it.wait_kind == :inn
          # Show Inn issued from a Parallel Process. Ported from a reference
          # implementation, NOT independently confirmed against genuine
          # RPG_RT under wine: its Show Inn handling is the very same method
          # for the foreground and every Parallel Process's own interpreter
          # -- but unlike Open Shop/Enter Hero Name just above, it carries
          # one extra nuance of its own, called out in that implementation's
          # own comment ("Emulates RPG_RT behavior (Bug?)" -- its own guess
          # at RPG_RT's behavior, not this project's independent finding): a
          # *priced* stay
          # (`inn_price > 0`, this codebase's `req[:prompt]`) is gated on the
          # foreground flag together with whether a message can currently be
          # shown -- that foreground flag is false for every non-foreground
          # interpreter, so that whole condition is always false for a
          # Parallel Process, skipping the message-active check entirely and
          # opening the inn prompt immediately, barging over whatever
          # message window happens to be up right now. A *free* stay
          # (`inn_price == 0`) keeps the ordinary message-active gate for
          # every caller alike, foreground or not (its own separate branch
          # for the free case checks only whether a message is active, with
          # no foreground flag mentioned at all). Before this
          # branch existed this fell into the generic #resume below, so a
          # Parallel Process's own Show Inn silently never opened the inn
          # screen at all -- the command read as a no-op, and any
          # [Stay]/[No Stay] handler right after it in `it`'s own list
          # never ran. The single inn screen is shared the same way the
          # shop/name-input screens are (`@inn_interp` mirrors
          # `@shop[:interp]`, see #drive_inn/#finish_inn): a second,
          # distinct interpreter's own Show Inn waits for this one's flow
          # to finish before starting its own.
          if @inn_interp.nil? || @inn_interp.equal?(it)
            req = it.inn_request
            drive_inn(it) if (req && req[:prompt]) || @message.nil?
          end
        elsif it.wait_kind == :return_title
          # Return to Title Screen issued from a Parallel Process. Ported
          # from a reference implementation, NOT independently confirmed
          # against genuine RPG_RT under wine: its Return to Title Screen
          # handling is a plain interpreter method with no foreground gate
          # at all -- unlike Open Shop/Enter Hero
          # Name, there is no foreground-vs-parallel distinction whatsoever
          # here. Before this branch existed this fell into the generic
          # #resume below, so a Parallel Process's own Return to Title
          # silently never happened -- a "reset the game" trap event, or an
          # alternate Game-Over-to-title flow, was a permanent no-op instead
          # of ending the play session. No shared-resource gate is needed
          # (unlike :shop/:name_input): the whole scene tears down the
          # instant this runs, so there is nothing left to race.
          perform_return_to_title(it)
        elsif it.wait_kind == :exit_game
          # Exit Game issued from a Parallel Process: same reasoning as
          # :return_title just above -- ported from a reference
          # implementation, NOT independently confirmed against genuine
          # RPG_RT under wine: its Exit Game handling has no foreground gate
          # either. Before this branch existed a Parallel Process's own
          # Exit Game silently never quit the game at all -- the classic
          # "auto-quit once switch X is on" idiom was a permanent no-op.
          perform_exit_game(it)
        elsif it.wait_kind == :save_menu
          # Open Save Menu issued from a Parallel Process. Ported from a
          # reference implementation, NOT independently confirmed against
          # genuine RPG_RT under wine: its Open Save Menu handling is gated
          # only on whether a message is currently active, no foreground
          # restriction -- same reasoning as :shop/:name_input above. Before this branch
          # existed this fell into the generic #resume below, so an
          # "auto-save trap" idiom built entirely inside a Parallel Process
          # silently never opened the save picker at all. No shared-resource
          # cross-guard is needed the way :shop/:name_input need one: a
          # pushed Scene::SaveLoad/Scene::Menu fully suspends this scene's
          # own #update -- and so #drive_parallel_wait itself -- until it
          # pops, so nothing else can race it open.
          perform_event_save(it) if @message.nil?
        elsif it.wait_kind == :menu
          # Open Main Menu issued from a Parallel Process: same reasoning as
          # :save_menu just above -- ported from a reference implementation,
          # NOT independently confirmed against genuine RPG_RT under wine:
          # its Open Main Menu handling has no foreground gate either.
          perform_event_menu(it) if @message.nil?
        elsif it.wait_kind == :load_menu
          # Open Load Menu (5001, RPG2003) issued from a Parallel Process:
          # same reasoning as :save_menu/:menu above -- ported from a
          # reference implementation, NOT independently confirmed against
          # genuine RPG_RT under wine: its Open Load Menu handling has no
          # foreground gate either.
          perform_event_load(it) if @message.nil?
        else
          # :message, :choice and :number are all handled above now.
          it.resume
        end
      end

      # The event currently standing on tile (x, y), or nil.
      def event_at(x, y)
        @event_tiles[[x, y]]
      end

      # Turn `ev` to face the player and run its command list. `by_decision_key`
      # records that the action button (not a touch or auto-start) launched it,
      # which the "the decision key started this event" conditional branch reads.
      def start_event(ev, by_decision_key = false)
        ev[:char].face(ev[:char].direction_toward(@state.x, @state.y))
        @active_event = ev
        @interpreter.start(ev[:commands])
        @interpreter.triggered_by_decision_key = by_decision_key
        @interpreter.event_id = ev[:id]
      end

      # On the action button, run the trigger-0 event the player is facing. The
      # faced event turns toward the player before its commands run. Ported
      # from a reference implementation's action-event check, NOT
      # independently confirmed against genuine RPG_RT under wine: it looks
      # through at most three counter tiles in a row before giving up.
      MAX_COUNTER_REACH = 3

      def try_action_trigger
        return if event_busy?
        return unless Input.trigger?(Input::C)
        # An action event **under the player** fires too: RPG_RT checks the tile
        # the party is standing on before the one it faces, which is how a
        # trigger-0 event on a doorway tile answers the action button. ~~Overlap
        # answers the button regardless of priority type~~ -- corrected against
        # a reference implementation's source (NOT independently confirmed
        # against genuine RPG_RT under wine): its own event-trigger-here
        # check, which this overlap check and
        # `#try_action_trigger`'s own faced-tile check below both port,
        # excludes a same-layer event explicitly -- the overlap check is
        # LAYER_SAME-excluded, the exact opposite of "regardless of priority
        # type". A below/above-characters action event (typically one whose
        # graphic is an upper-layer chip, which defaults to LAYER_BELOW) is
        # what this check is actually for; a LAYER_SAME event blocks the
        # party from ever standing on it in the first place (see
        # #char_passable?'s own LAYER_SAME collision), so it can never
        # legitimately reach this branch at all -- the missing exclusion only
        # mattered for the one way a same-layer event *can* end up
        # co-located with the player anyway: its page re-selects to a
        # blocking, action-triggered LAYER_SAME page while the player already
        # happens to be standing on that exact tile (e.g. a switch flips
        # elsewhere, with no movement in between).
        here = event_at(@state.x, @state.y)
        return start_event(here, true) if actionable?(here) && here[:layer] != LAYER_SAME

        # The faced tile only answers the button for a LAYER_SAME event: RPG_RT
        # ties this to priority type the same way it ties collision to it
        # (yado.tk's 決定キーを押してもマップイベントが実行しない) — a
        # below/above-characters action event (typically one whose graphic is
        # an upper-layer chip, which defaults to LAYER_BELOW) does not answer
        # the button from an adjacent facing tile, only from standing on it via
        # the overlap check above. A same-layer event never has that option
        # (it blocks the party from ever standing on it), so facing it is its
        # only way in.
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        ev = event_at(fx, fy)
        return start_event(ev, true) if actionable?(ev) && ev[:layer] == LAYER_SAME
        # A same-layer Player Touch / Event Touch event on the faced tile
        # answers the action button too, not just an action-triggered one --
        # ported from a reference implementation, NOT independently
        # confirmed against genuine RPG_RT under wine: its own action-event
        # check checks the Player Touch / Event Touch triggers on the front
        # tile unconditionally, before it ever looks for an action-triggered
        # event there (a single, unconditional check, no version gating).
        # Unlike #touch_trigger?
        # (which also answers hero *contact*, walking onto the tile),
        # Parallel Process is not in this set -- it never answers the
        # action button, only the two touch triggers do. This check is
        # local to the immediate front tile only, not extended through the
        # counter-tile chain below (which stays action-only, matching the
        # reference's own separate `got_action` loop).
        return start_event(ev, true) if action_touch_trigger?(ev)

        # Nothing on the faced tile: if it is a **counter** — a shop or inn
        # counter, marked in the chipset's upper-layer passage table — look
        # across it for whoever is standing behind, up to three counters deep.
        MAX_COUNTER_REACH.times do
          break unless counter_tile?(fx, fy)
          fx, fy = target_tile(fx, fy, @state.direction)
          ev = event_at(fx, fy)
          return start_event(ev, true) if actionable?(ev) && ev[:layer] == LAYER_SAME
        end
        nil
      end

      # Whether an event can answer the action button.
      def actionable?(ev)
        ev && ev[:trigger] == TRIGGER_ACTION && ev[:commands] ? true : false
      end

      # Whether a same-layer Player Touch / Event Touch event on the faced
      # tile can also answer the action button -- see #try_action_trigger's
      # own citation (ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine).
      # Deliberately narrower
      # than #touch_trigger? (which also covers Parallel Process, for
      # hero-*contact* purposes): Parallel is not in that
      # `{Trigger_touched, Trigger_collision}` set here.
      def action_touch_trigger?(ev)
        ev && ev[:layer] == LAYER_SAME && ev[:commands] &&
          (ev[:trigger] == TRIGGER_PLAYER_TOUCH || ev[:trigger] == TRIGGER_EVENT_TOUCH) ? true : false
      end

      # Whether a trigger is one the party can set off by walking into the event
      # (see the note in #step_movement). yado.tk: a Parallel Process page
      # answers hero contact too, on top of the background loop #step_parallel
      # already drives it through -- the two are independent, so a below/above-
      # characters Parallel event fires the instant the party overlaps its
      # tile and a same-as-characters one fires again on every repeat into it,
      # exactly like the two dedicated touch triggers already do.
      def touch_trigger?(trigger)
        trigger == TRIGGER_PLAYER_TOUCH || trigger == TRIGGER_EVENT_TOUCH ||
          trigger == TRIGGER_PARALLEL
      end

      # Whether (x, y) carries an upper-layer counter tile.
      def counter_tile?(x, y)
        return false if @chipset.nil? || !@map.in_bounds?(x, y)
        @chipset.counter?(@map.upper(x, y))
      end

      # On the action button, board a placed vehicle the party is standing on
      # (airship) or facing (boat / ship), or — when already aboard — step off
      # onto the tile ahead. Returns true when it claimed the button, so the
      # ordinary event-action check is skipped that frame.
      def try_board_vehicle
        return false if event_busy?
        return false unless Input.trigger?(Input::C)
        if @state.boarded?
          airship = @state.boarded == :airship
          disembarked = disembark_vehicle
          # Ported from a reference implementation's action-trigger check,
          # NOT independently confirmed against genuine RPG_RT under wine: it
          # opens with an unconditional flying-check
          # bail, so an airship rider's Decision press never falls through
          # to it regardless of whether landing actually succeeded -- the
          # button is consumed either way. A boat/ship rider gets no such
          # blanket suppression: its own per-frame update only skips the
          # action-trigger check when getting on/off the vehicle (in turn,
          # disembarking / whether the ship can land) actually
          # succeeds; a failed disembark -- a blocked landing tile, or an
          # active same-layer event standing right on the shore -- falls
          # through to the ordinary action-trigger check on that same
          # tile, letting a shore NPC be talked to directly from the boat.
          airship || disembarked
        else
          board_vehicle
        end
      end

      # Board a vehicle placed on the current map at the party's tile (airship) or
      # the tile it faces (boat / ship, boarded from the shore). Steps onto the
      # vehicle's tile and returns whether a vehicle was boarded.
      #
      # Each vehicle type has exactly one trigger, never both -- ported from
      # a reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own vehicle-boarding check checks the
      # airship only against the player's own tile, in an `if` whose `else`
      # branch is the only place the faced tile's coordinates are computed at
      # all -- the airship is never considered there, and Ship/Boat (checked
      # in that order) are never considered against the player's own tile.
      # This used
      # to run one generic per-type loop applying *both* checks to *every*
      # type, which let the airship be boarded merely by facing it from an
      # adjacent tile (real RPG_RT does nothing there -- the action falls
      # through to whatever ordinary event sits on that tile instead) and,
      # symmetrically, would have let a boat/ship be boarded by standing on
      # its tile rather than facing it from the shore.
      def board_vehicle
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        airship = @state.vehicle(:airship)
        if airship.placed? && airship.map_id == @state.map_id &&
           airship.x == @state.x && airship.y == @state.y
          board_as(:airship)
          return true
        end
        [:ship, :boat].each do |type|
          v = @state.vehicle(type)
          next unless v.placed? && v.map_id == @state.map_id && v.x == fx && v.y == fy
          @state.x = fx
          @state.y = fy
          board_as(type)
          return true
        end
        false
      end

      # Mark the party aboard `type` and switch to the vehicle's BGM. Boarding
      # the airship also snaps the hero to face left -- ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own vehicle-boarding logic's airship
      # branch sets the facing to left unconditionally the instant boarding
      # begins, with its own comment claiming this bypasses Direction Fix
      # ("RPG_RT ignores the lock_facing flag here!" -- that implementation's
      # own comment, not this project's independent finding) -- the boat/ship
      # branch has no equivalent call at all, so this is airship-specific.
      def board_as(type)
        @state.boarded = type
        @state.direction = 4 if type == :airship
        play_vehicle_bgm(type)
      end

      # Step off the ridden vehicle. A boat / ship disembarks onto the tile
      # ahead when it is walkable on foot, leaving the vehicle on the tile the
      # party vacates; the airship instead lands in place — RPG_RT tests the
      # terrain directly under it, not the tile ahead, since it has no "shore"
      # to step onto. Either way a no-op when the landing spot is blocked (the
      # party stays aboard). Disembarking the airship also snaps the hero to
      # face left, mirroring a reference implementation's own vehicle-
      # disembark logic, which sets facing left unconditionally right before
      # starting its descent
      # (NOT independently confirmed against genuine RPG_RT under wine) --
      # see #board_as.
      # Returns whether the boat/ship actually got off (the airship branch's
      # own return is never read -- see #try_board_vehicle's own comment on
      # why the airship needs no such signal).
      def disembark_vehicle
        if @state.boarded == :airship
          return unless airship_landable?(@state.x, @state.y)
          @state.direction = 4
          follow_vehicle # the airship is left where it touched down
          @state.boarded = nil
          restore_pre_vehicle_bgm # the map BGM resumes
          return
        end
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        return false unless ship_disembark_passable?(fx, fy, @state.direction)
        follow_vehicle # the vehicle is left where the party is getting off
        @state.x = fx
        @state.y = fy
        @state.boarded = nil
        restore_pre_vehicle_bgm # the map BGM resumes
        true
      end

      # Whether the landing tile (x, y) admits a disembarking boat/ship,
      # heading `dir`. A dedicated, one-sided test -- NOT #passable? -- since
      # its ported disembark check is narrower than an ordinary step.
      # Ported from a reference implementation, NOT independently confirmed
      # against genuine RPG_RT under wine: its own vehicle-disembark logic
      # calls a landing-passability check, which (1) only tests the
      # *landing* tile's own entry passability (deriving just the one
      # direction bit at `(x, y)`; the water tile the
      # party is standing on is never passed to the passability check at
      # all, unlike an ordinary step's own two-sided `#passable?` check),
      # (2) checks that bit with no mover -- no
      # `boat_pass`/`ship_pass` terrain gate applies to *landing*, only to
      # sailing there in the first place -- and (3) has no equivalent of
      # `#vehicle_blocks?` at all (unlike the airship-landing check, a few
      # lines above it in the same file, which does loop over Boat and Ship
      # explicitly): a boat/ship parked on the landing tile never blocks
      # disembarking here. Only a same-layer, non-Through event still does.
      def ship_disembark_passable?(x, y, dir)
        return false unless @map.in_bounds?(x, y)
        return false if blockers_at(x, y).any? { |b| b[:layer] == LAYER_SAME && !b[:char].through }
        return true if @chipset.nil?
        @chipset.passable_tile?(@map.lower(x, y), @map.upper(x, y),
                                 Game::Character::TURN_180[dir] || dir)
      end

      # Whether the airship may land on tile (x, y): the database terrain's
      # airship_land flag (default true), with no map event occupying the
      # ground underneath at all — yado.tk: an airship can never land on a
      # tile a map event occupies, regardless of terrain. Flying itself
      # ignores events entirely (#vehicle_passable?'s airship branch never
      # reads @event_tiles, so the airship can cruise directly over a
      # below-characters event a walking hero would just as happily overlap),
      # so this is the one place events reach it at all. Ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own airship-landing check
      # is a standalone loop -- any event in position, active, with a
      # currently-selected page blocks a landing
      # -- entirely separate from the movement-collision check (the
      # function `#vehicle_passable?`'s own boat/ship rule legitimately
      # reads Through Mode from). The airship-landing check never reads
      # Through Mode at all: any event with a currently-active page blocks a
      # landing, Through Mode or not -- unlike a boat/ship's own movement
      # collision, an airship landing is not itself a "pass through" move,
      # it is occupying the ground tile outright. `blockers_at` already only
      # ever indexes an event with a currently active page (the same
      # active-page test), so any blocker it
      # returns here blocks unconditionally. A tile with no terrain data (a
      # bare fixture) is landable.
      def airship_landable?(x, y)
        return false unless @map.in_bounds?(x, y)
        return false if blockers_at(x, y).any?
        # A Boat/Ship parked on the ground blocks a landing too, matching
        # a reference implementation's own airship-landing check, which
        # loops over Boat and Ship there (NOT
        # independently confirmed against genuine RPG_RT under wine) -- see
        # `#vehicle_blocks?`.
        return false if vehicle_blocks?(x, y, block_airship: false)
        row = terrain_row_at(x, y)
        return true if row.nil?
        row.airship_land ? true : false
      end

      # Play `music` ({ name:, volume:, tempo: }) as the current BGM, the one
      # choke point every BGM-switching helper below (vehicle/battle/victory/
      # inn, play and restore alike) funnels through. Ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its BGM is modelled as a single channel
      # with one real entry point on the native side, and it
      # special-cases re-selecting the file already playing: "Same music:
      # Only adjust volume and speed" rather than stopping and restarting it,
      # for *every* caller, not just the Play BGM event command (battle entry
      # itself calls that identical entry point to play the system battle
      # BGM). This
      # codebase already ported that for the event-command path
      # (`Game::Interpreter#play_audio`'s `:bgm` branch, same
      # `same_file_already_playing` idiom, volume-in-place included) but every
      # helper here still called `RGSS::Audio.bgm_play` unconditionally, so a
      # battle/vehicle/inn BGM configured to the exact same file as whatever
      # was already playing broke and restarted it from the top instead of
      # continuing seamlessly across the transition — including the
      # asymmetric case of restoring a field track this scene itself never
      # actually stopped. Tempo is still not adjusted in place on a same-file
      # call: SDL_mixer has no live pitch control for a playing stream.
      #
      # `music[:balance]` (cycle #219): the same gap cycle #203 found and
      # fixed here for `fade_in`, but for BGM-struct field 5 (`balance`,
      # mruby-lcf/mrblib/schema.rb) instead -- Play BGM and Play Memorized
      # BGM (`Game::Interpreter#play_audio`'s `:bgm` branch and
      # `#do_play_memorized_bgm`) both already re-apply their own balance to
      # `RGSS::Audio.bgm_pan` unconditionally, same-file-or-not, since
      # panning has no per-track state to restart -- but every caller
      # through this shared choke point (battle/inn/vehicle/restore, and
      # `#play_map_bgm`'s own Autoplay BGM) never called `bgm_pan` at all,
      # so a database or Change System BGM balance configured on any of
      # those slots was silently dropped and playback kept whatever pan a
      # prior Play BGM (or the SDL default) had last set instead.
      def play_bgm(music)
        same_file_already_playing = @state.current_bgm && @state.current_bgm[:name] == music[:name]
        if same_file_already_playing
          # No restart happens here, so there is nothing for a fade-in to
          # ramp into -- the same same-file shortcut #play_audio's own :bgm
          # branch (mruby-rpg2k/mrblib/interpreter.rb) already documents for
          # every other Play BGM parameter, cycle #202.
          RGSS::Audio.bgm_volume(music[:volume] || 100)
        else
          # `music[:fadein]` (cycle #203): battle/inn/vehicle BGM now carries
          # a real fade-in through here the same way Play BGM and Play
          # Memorized BGM already do (see those two's own doc comments) --
          # both a Change System BGM (10660) override (`do_change_system_bgm`
          # in interpreter.rb) and the database's own battle_music/inn_music/
          # boat_music/ship_music/airship_music (all liblcf `BGM`-struct
          # fields, schema.rb, field 2 `fade_in`) genuinely carry a fade-in
          # value that this helper used to read the struct for and then drop
          # before reaching RGSS::Audio.bgm_play's 5th argument.
          RGSS::Audio.bgm_play(music[:name], music[:volume] || 100, music[:tempo] || 100,
                               0, music[:fadein] || 0)
        end
        # Balance/pan re-applied unconditionally, same-file-or-not, matching
        # #play_audio's own :bgm branch and #do_play_memorized_bgm (cycle
        # #219) -- see this method's own doc comment above.
        RGSS::Audio.bgm_pan(music[:balance] || 50)
        @state.current_bgm = music
      end

      # Ported from a reference implementation, NOT independently confirmed
      # against genuine RPG_RT under wine: its BGM-play entry point
      # is unconditional wherever it is called -- a
      # blank/"(OFF)" track still hits its own
      # stop branch ("(OFF) means play nothing"), silencing
      # whatever was already playing, rather than leaving the call a no-op.
      # #play_vehicle_bgm and #restore_pre_vehicle_bgm both port one such
      # unconditional call (boarding's own vehicle-BGM play,
      # disembarking's own pre-vehicle-music play), so both route through
      # this shared stop-or-play
      # helper instead of silently no-op'ing when the target track is
      # nil/blank -- a vehicle with no configured BGM used to leave whatever
      # was already playing running right through the ride, and disembarking
      # back into a map that itself had no BGM used to leave the vehicle's own
      # track still playing, neither of which this ported model does.
      def play_bgm_or_stop(music)
        # The doc comment above already cites "(OFF) means play nothing" from
        # `BgmPlay`'s own source, but this condition itself only ever checked
        # for a blank name -- never the literal "(OFF)" text `BgmPlay`
        # actually compares against (liblcf's own Music-struct schema
        # default). A vehicle/pre-battle/pre-inn BGM explicitly set to
        # "(OFF)" in the editor fell through to `#play_bgm` and tried to
        # play a file literally named "(OFF)" instead of stopping.
        name = music && music[:name] ? music[:name].to_s : ''
        if !name.empty? && name != '(OFF)'
          play_bgm(music)
        else
          RGSS::Audio.bgm_stop
          @state.current_bgm = nil
        end
      end

      # Play the vehicle's own BGM — a Change System BGM (10660) override for
      # its slot when one is set, else the database System boat / ship /
      # airship music — remembering the BGM that was playing so
      # #restore_pre_vehicle_bgm can bring it back on disembark.
      def play_vehicle_bgm(type)
        @state.pre_vehicle_bgm = @state.current_bgm
        play_bgm_or_stop(vehicle_bgm(type))
      rescue StandardError => e
        $stderr.puts "[RPG2k] vehicle BGM failed: #{e.message}"
      end

      # Restore the BGM that was playing before the party boarded (the map BGM).
      def restore_pre_vehicle_bgm
        bgm = @state.pre_vehicle_bgm
        @state.pre_vehicle_bgm = nil
        play_bgm_or_stop(bgm)
      rescue StandardError => e
        $stderr.puts "[RPG2k] restoring BGM failed: #{e.message}"
      end

      # System BGM slot indices, as used by Change System BGM (10660) --
      # matches the slot 0 = battle / 1 = victory reading already documented
      # on the rpg2k_logic_check.rb coverage for that command.
      SYSTEM_BGM_BATTLE = 0
      SYSTEM_BGM_VICTORY = 1

      # Play the battle BGM when a fight opens, remembering the field/vehicle
      # BGM that was playing so #restore_pre_battle_bgm can bring it back once
      # the fight ends -- the same memorize/restore idiom #play_vehicle_bgm
      # already uses for boarding. A game with no battle BGM configured (or an
      # unnamed file) leaves whatever music was already playing alone,
      # matching a reference implementation's own no-op on an empty Music
      # struct (its BGM-play entry point does nothing for a blank filename),
      # NOT independently confirmed against genuine RPG_RT under wine.
      def play_battle_bgm
        music = battle_bgm
        return unless music
        @state.pre_battle_bgm = @state.current_bgm
        play_bgm(music)
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle BGM failed: #{e.message}"
      end

      # The battle BGM to play as { name:, volume:, tempo:, fadein:, balance: },
      # or nil when neither source names a file. Prefers a Change System BGM
      # override for the battle slot over the database's own System
      # battle_music -- the same override-then-default idiom #system_se
      # already uses for Change System SFX overrides, extended to BGM now
      # that a battle actually plays music to override. `fadein` (cycle
      # #203): both sources genuinely carry one -- the override from Change
      # System BGM's own fade-in parameter (`do_change_system_bgm`,
      # mruby-rpg2k/mrblib/interpreter.rb), the database value from
      # battle_music's own liblcf `BGM`-struct field 2 (`fade_in`,
      # mruby-lcf/mrblib/schema.rb) -- previously read off neither and
      # dropped before reaching #play_bgm. `balance` (cycle #219): the same
      # gap, for field 5 (`balance`) instead -- see #play_bgm's own doc
      # comment.
      def battle_bgm
        ov = @state.system_bgm[SYSTEM_BGM_BATTLE]
        if ov && ov[:name] && !ov[:name].empty?
          return { name: ov[:name], volume: ov[:volume] || 100,
                    tempo: ov[:tempo] || 100, fadein: ov[:fadein] || 0,
                    balance: ov[:balance] || 50 }
        end
        name = music_name(db.system.battle_music)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(db.system.battle_music),
          tempo: music_tempo(db.system.battle_music),
          fadein: music_fadein(db.system.battle_music),
          balance: music_balance(db.system.battle_music) }
      end

      # Play the victory fanfare over the result window on a win, the same way
      # #play_battle_bgm swaps in the battle track when the fight opens. RPG_RT
      # stops the battle BGM the instant the last enemy falls and plays the
      # System's battle_end_music (Change System BGM slot 1) for the "Victory! /
      # EXP gained" screen -- a genuine one-shot "ME" (music effect), not an
      # ordinary looping track, so RGSS::Audio.me_play is what plays it rather
      # than #play_bgm: SDL_mixer's ME channel plays it exactly once and, left
      # alone, auto-resumes whatever BGM it interrupted once it ends.
      # #restore_pre_battle_bgm already brings the pre-battle field/vehicle
      # track back once that screen is dismissed (#finish_battle), so nothing
      # here needs to remember or restore anything of its own. A game with no
      # victory BGM configured leaves whatever was playing (the battle track)
      # alone, the same blank-Music no-op #battle_bgm documents.
      #
      # Forwards a fade-in (cycle #204 follow-up to the cycle #203 audit
      # above): the override and battle_end_music both carry a genuine
      # fade-in value the same way battle_music/inn_music/vehicle music do
      # (Change System BGM's own fade-in parameter; liblcf's `BGM`-struct
      # field 2), and RGSS::Audio.me_play now has a fadein parameter of its
      # own -- the native ME playback path (`me_play`/`me_play_mem`,
      # src/sdl_audio.cxx) was extended to accept one the same way
      # RGSS::Audio.bgm_play's was (cycle #202), since SDL_mixer's
      # Mix_FadeInMusic works identically for the one-shot ME channel as it
      # does for the looping BGM channel underneath -- both are the same
      # Mix_Music stream, just started with a different loop count.
      #
      # `balance` (cycle #220): the same `BGM`-struct field 5 gap cycle #219
      # closed for #battle_bgm/#inn_bgm/#vehicle_bgm/#play_map_bgm and
      # Scene::GameOver, but left this one call site alone -- its own TODO
      # entry assumed closing it would need a new, unverified native
      # signature change to RGSS::Audio.me_play the way #fadein needed
      # (cycle #204), the same real work #204 actually did. That assumption
      # does not hold for panning: unlike a fade-in (which has to reach
      # Mix_FadeInMusic at the moment a track *starts*), `RGSS::Audio.
      # bgm_pan` is a live, already-established call with no dependency on
      # which helper started the track -- its own doc comment (`#play_bgm`,
      # above) already documents that it re-applies unconditionally,
      # same-file-or-not, and every other BGM entry point (Play BGM, Play
      # Memorized BGM, #play_bgm itself) already calls it as its own last
      # step after playback starts, ME included: `#me_play`'s own doc
      # comment already establishes the fanfare shares the ordinary BGM
      # channel's one underlying `Mix_Music` stream, which is exactly what
      # `bgm_pan`'s `Mix_SetPanning(MIX_CHANNEL_POST, ...)` re-pans (see
      # `include/rgss_audio.hxx`'s own doc comment: "pans the whole final
      # mixed output"). So the fanfare's own configured balance was simply
      # never read into the hash below and never handed to the
      # already-existing `bgm_pan` call every sibling BGM entry point
      # already makes -- no native change needed at all, just the same
      # mechanical plumbing cycle #219 did for its own five call sites.
      # Without this, the victory fanfare played back panned to whatever
      # `bgm_pan` value the *battle* track last set (stale, since nothing
      # re-applied one of its own), not its own database/override balance.
      def play_victory_bgm
        music = victory_bgm
        return unless music
        RGSS::Audio.me_play(music[:name], music[:volume] || 100,
                            music[:tempo] || 100, music[:fadein] || 0)
        RGSS::Audio.bgm_pan(music[:balance] || 50)
      rescue StandardError => e
        $stderr.puts "[RPG2k] victory BGM failed: #{e.message}"
      end

      # The victory BGM to play as { name:, volume:, tempo:, fadein:,
      # balance: }, or nil when neither source names a file. Prefers a
      # Change System BGM override for the victory slot over the database's
      # own System battle_end_music -- the same override-then-default idiom
      # #battle_bgm uses for the battle slot, `fadein` included (cycle #204)
      # the same way #battle_bgm / #inn_bgm already carry theirs, `balance`
      # now included too (cycle #220) -- see #play_victory_bgm's own doc
      # comment.
      def victory_bgm
        ov = @state.system_bgm[SYSTEM_BGM_VICTORY]
        if ov && ov[:name] && !ov[:name].to_s.empty?
          return { name: ov[:name], volume: ov[:volume] || 100,
                    tempo: ov[:tempo] || 100, fadein: ov[:fadein] || 0,
                    balance: ov[:balance] || 50 }
        end
        name = music_name(db.system.battle_end_music)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(db.system.battle_end_music),
          tempo: music_tempo(db.system.battle_end_music),
          fadein: music_fadein(db.system.battle_end_music),
          balance: music_balance(db.system.battle_end_music) }
      end

      # Restore the BGM that was playing before the fight started. A no-op
      # when the fight never touched the music (no battle_music configured),
      # so the field/vehicle track was never interrupted and there is nothing
      # to bring back -- and when the party is headed to the Game Over screen
      # instead, which plays its own music and never returns to this map.
      #
      # A victory's fanfare (#play_victory_bgm's RGSS::Audio.me_play) is still
      # a one-shot "ME" playing over the (silent, since the battle BGM stopped
      # when the last enemy fell) music channel at this point if the player
      # dismissed the result screen before it finished on its own --
      # RGSS::Audio.me_stop ends it cleanly through the ME's own stop path
      # (a no-op if it had already finished) rather than leaving #play_bgm's
      # RGSS::Audio.bgm_play to yank the shared music stream out from under
      # it. Harmless to call for an escape or a defeat too: there is no ME
      # active then, so it is a no-op.
      def restore_pre_battle_bgm
        bgm = @state.pre_battle_bgm
        @state.pre_battle_bgm = nil
        return unless bgm && bgm[:name] && !bgm[:name].empty?
        RGSS::Audio.me_stop
        play_bgm(bgm)
      rescue StandardError => e
        $stderr.puts "[RPG2k] restoring BGM after battle failed: #{e.message}"
      end

      # System BGM slot index for Change System BGM (10660)'s inn override.
      # Slot numbering matches liblcf's own System struct field order
      # (mruby-lcf/mrblib/schema.rb: battle_music 32, battle_end_music 33,
      # inn_music 34, boat_music 35, ship_music 36, airship_music 37,
      # gameover_music 38) once title_music (31, which this command has no
      # slot for) is dropped from the front -- Battle 0, Victory 1, Inn 2,
      # Boat 3, Ship 4, Airship 5, GameOver 6 -- the same numbering
      # VEHICLE_SYSTEM_BGM_SLOT below resolves its own slots against.
      SYSTEM_BGM_INN = 2

      # Play the inn's own BGM when a Show Inn command opens its stay -- a
      # Change System BGM override for the inn slot when one is set, else the
      # database System inn_music -- remembering the BGM that was playing so
      # #restore_pre_inn_bgm can bring it back once the stay is resolved. The
      # same memorize/restore idiom #play_battle_bgm / #play_vehicle_bgm
      # already use. A game with no inn BGM configured (override or
      # database) leaves whatever was already playing alone.
      def play_inn_bgm
        music = inn_bgm
        return unless music
        @pre_inn_bgm = @state.current_bgm
        play_bgm(music)
      rescue StandardError => e
        $stderr.puts "[RPG2k] inn BGM failed: #{e.message}"
      end

      # The inn BGM to play as { name:, volume:, tempo:, fadein:, balance: },
      # or nil when neither source names a file. Prefers a Change System BGM
      # override for the inn slot over the database's own System inn_music --
      # the same override-then-default idiom #battle_bgm / #vehicle_bgm
      # already use, `fadein` included (cycle #203) -- see #battle_bgm's own
      # doc comment for why both sources genuinely carry one. `balance`
      # (cycle #219): the same gap, for field 5 -- see #play_bgm's own doc
      # comment.
      def inn_bgm
        ov = @state.system_bgm[SYSTEM_BGM_INN]
        if ov && ov[:name] && !ov[:name].to_s.empty?
          return { name: ov[:name], volume: ov[:volume] || 100, tempo: ov[:tempo] || 100,
                    fadein: ov[:fadein] || 0, balance: ov[:balance] || 50 }
        end
        name = music_name(db.system.inn_music)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(db.system.inn_music),
          tempo: music_tempo(db.system.inn_music), fadein: music_fadein(db.system.inn_music),
          balance: music_balance(db.system.inn_music) }
      end

      # Restore the BGM that was playing before the inn stay began. A no-op
      # when the inn never touched the music (no inn BGM configured), so the
      # field/vehicle track was never interrupted and there is nothing to
      # bring back.
      def restore_pre_inn_bgm
        bgm = @pre_inn_bgm
        @pre_inn_bgm = nil
        return unless bgm && bgm[:name] && !bgm[:name].empty?
        play_bgm(bgm)
      rescue StandardError => e
        $stderr.puts "[RPG2k] restoring BGM after inn failed: #{e.message}"
      end

      # System BGM slot indices for Change System BGM (10660). Slot numbering
      # matches liblcf's own System struct field order (mruby-lcf/mrblib/
      # schema.rb: battle_music 32, battle_end_music 33, inn_music 34,
      # boat_music 35, ship_music 36, airship_music 37, gameover_music 38)
      # once title_music (31, which this command has no slot for) is dropped
      # from the front -- Battle 0, Victory 1, Inn 2, Boat 3, Ship 4,
      # Airship 5, GameOver 6 -- the boat/ship/airship slots sit between the
      # ones the battle and game-over BGM already resolve (SYSTEM_BGM_BATTLE/
      # SYSTEM_BGM_VICTORY above, SYSTEM_BGM_INN just above).
      VEHICLE_SYSTEM_BGM_SLOT = { boat: 3, ship: 4, airship: 5 }.freeze

      # The BGM to play for vehicle `type` as
      # { name:, volume:, tempo:, fadein:, balance: }, or nil when neither
      # source names a file. Prefers a Change System BGM override for the
      # vehicle's slot over the database's own boat / ship / airship music —
      # the same override-then-default idiom #system_se already uses for
      # Change System SFX, `fadein` included (cycle #203) -- see #battle_bgm's
      # own doc comment for why both sources genuinely carry one. `balance`
      # (cycle #219): the same gap, for field 5 -- see #play_bgm's own doc
      # comment.
      def vehicle_bgm(type)
        slot = VEHICLE_SYSTEM_BGM_SLOT[type]
        ov = slot && @state.system_bgm[slot]
        if ov && ov[:name] && !ov[:name].to_s.empty?
          return { name: ov[:name], volume: ov[:volume] || 100, tempo: ov[:tempo] || 100,
                    fadein: ov[:fadein] || 0, balance: ov[:balance] || 50 }
        end
        field = "#{type}_music"
        return nil unless @db.system.respond_to?(field)
        bgm = @db.system.send(field)
        name = music_name(bgm)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(bgm), tempo: music_tempo(bgm), fadein: music_fadein(bgm),
          balance: music_balance(bgm) }
      end

      # A parsed BGM chunk exposes file / fade_in / volume / pitch / balance;
      # read them defensively so a bare fixture that omits a field still
      # works.
      def music_name(m); m.file rescue nil; end
      def music_volume(m); (m.volume rescue nil) || 100; end
      def music_tempo(m); (m.pitch rescue nil) || 100; end
      # `fade_in` (cycle #203): liblcf's `BGM` struct field 2
      # (mruby-lcf/mrblib/schema.rb), present on every System Music slot this
      # scene reads (battle_music, inn_music, boat/ship/airship_music) --
      # previously never read here at all, so a database-configured fade-in
      # on any of those slots was silently dropped rather than reaching
      # #play_bgm.
      def music_fadein(m); (m.fade_in rescue nil) || 0; end
      # `balance` (cycle #219): the same `BGM`-struct's field 5 (schema.rb),
      # present on the exact same slots as `fade_in` above -- previously
      # never read here either, so a database-configured pan on any of those
      # slots was silently dropped rather than reaching #play_bgm's own
      # `RGSS::Audio.bgm_pan` call (see that method's own doc comment).
      def music_balance(m); (m.balance rescue nil) || 50; end

      # Keep the ridden vehicle on the party's tile / facing.
      def follow_vehicle
        v = @state.vehicle(@state.boarded)
        return unless v
        v.map_id = @state.map_id
        v.x = @state.x
        v.y = @state.y
        v.direction = @state.direction
      end

      # Whether vehicle `type` may enter tile (x, y) heading `dir`: the airship
      # flies over any in-bounds tile whose terrain allows it (the database
      # terrain's airship_pass flag, default true, so it clears everything
      # blocked on foot unless a map explicitly grounds it); a boat / ship needs
      # the tile's terrain to allow it (boat_pass / ship_pass) with no event in
      # the way, falling back to on-foot passability when the map has no terrain
      # data.
      #
      # A moving boat / ship's event-blocking rule is layer-gated, exactly like
      # the hero's own (see `passable?` / `char_passable?`, which key off
      # `blocker[:layer]`) -- ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine:
      # its own movement-collision check routes a
      # moving boat/ship's collision through the exact same generic
      # collision test every other mover uses, whose own layer test compares
      # the two characters' layers directly; its vehicle construction sets
      # every vehicle to the same-as-characters layer unconditionally,
      # for every vehicle type, never overridden elsewhere. So a below/above-
      # characters event a boat/ship's own layer never matches is a decoration
      # it glides straight through, the same as the hero does -- Through Mode
      # (`blocker[:char].through`, the same accessor `char_passable?` and
      # `passable?` check) is a *separate*, additional exemption on top of the
      # layer gate, not the only one.
      def vehicle_passable?(x, y, dir, type)
        return false unless @map.in_bounds?(x, y)
        row = terrain_row_at(x, y)
        if type == :airship
          return true if row.nil?
          return row.airship_pass ? true : false
        end
        return false if blockers_at(x, y).any? { |b| !b[:char].through && b[:layer] == LAYER_SAME }
        # A moving Boat/Ship also collides with a *different* parked
        # Boat/Ship, and with a grounded Airship -- ported from a reference
        # implementation's own movement-collision check (NOT independently
        # confirmed against genuine RPG_RT under wine), which loops over
        # Boat and Ship for
        # any non-Airship mover, then also checks the Airship whenever the
        # mover is not the on-foot player (true for a ridden Boat/Ship,
        # which moves as its own `Vehicle`-typed character, not `Player`).
        # See `#vehicle_blocks?`, already used for the opposite direction (a
        # non-vehicle character walking onto a *parked* vehicle's tile).
        return false if vehicle_blocks?(x, y, block_airship: true)
        return passable?(x, y, dir) unless row
        type == :boat ? (row.boat_pass ? true : false) : (row.ship_pass ? true : false)
      end

      # #vehicle_passable? wired to the move-route `world` protocol
      # (VehicleWorld, scene/base.rb): a step ahead of `character` in `dir`,
      # honouring the mirror's own Through Mode first exactly as
      # #char_passable? does for the hero/events (a route's Through Mode
      # Begin/End sub-commands work the same way on a vehicle mirror).
      def vehicle_char_passable?(character, dir, type)
        return true if character.through
        nx, ny = Game::Character.step_tile(character.x, character.y, dir)
        vehicle_passable?(nx, ny, dir, type)
      end
      # Called by VehicleWorld (an external collaborator) with an explicit receiver.
      public :vehicle_char_passable?

      # #vehicle_passable? for a jump landing on (x, y), mirroring
      # #char_can_land?: an in-place hop always lands (the tile is already
      # occupied by the mover itself), and Through Mode bypasses the check
      # entirely, same as stepping.
      def vehicle_char_can_land?(character, x, y, type)
        return true if character.through
        return true if x == character.x && y == character.y
        vehicle_passable?(x, y, character.direction, type)
      end
      public :vehicle_char_can_land?

      # The database terrain row under tile (x, y), or nil when the chipset / map
      # carry no terrain data (e.g. the colour-block fallback or a bare fixture)
      # -- or when the chipset cell at (x, y) points at a terrain id a database
      # shrink has since removed. Real RPG_RT only surfaces that second case
      # once the player actually steps onto the specific stale tile rather than
      # proactively at load time (docs/TODO.md's runtime error catalog), which
      # this already matches for free: every caller only ever asks about a tile
      # someone (the party, an event, a vehicle) currently occupies. See
      # #warn_stale_terrain for the "log once, not once per frame" diagnostic.
      def terrain_row_at(x, y)
        return nil if @chipset.nil? || !@db.respond_to?(:terrain) || @db.terrain.nil?
        tid = @chipset.terrain(@map.lower(x, y))
        row = @db.terrain[tid]
        warn_stale_terrain(x, y, tid) if row.nil?
        row
      rescue StandardError => e
        $stderr.puts "[RPG2k] Terrain: lookup failed at (#{x}, #{y}): #{e.message}"
        nil
      end

      # #terrain_row_at's diagnostic for a chipset cell whose terrain id has no
      # database row -- a database shrink leaving a dangling reference behind,
      # not the ordinary "no terrain table at all" case #terrain_row_at already
      # returns nil for silently. Deduped per stale tile (`@warned_stale_terrain`,
      # reset per map visit alongside @erased_event_positions /
      # @event_last_position above) rather than per lookup: several callers
      # (encounter rate, bush depth, vehicle passability) ask about the tile the
      # party is standing on every single frame, and logging each of those would
      # spam the console solid for a party that simply stands still on it.
      def warn_stale_terrain(x, y, tid)
        return if @warned_stale_terrain[[x, y]]
        @warned_stale_terrain[[x, y]] = true
        $stderr.puts "[RPG2k] Terrain: tile (#{x}, #{y}) references terrain " \
                     "##{tid}, which no longer exists in the database"
      end

      # Advance autonomous / custom-route event movement one frame. Skipped
      # while an event process is running so the map holds still during messages
      # -- unless a Message Options command turned `continue_events` on, in which
      # case #update calls this a second way (allow_trigger: false) while a
      # message window is open; see #events_move_during_message?.
      def step_events(allow_trigger: true)
        # A plain while loop instead of #each avoids allocating a Proc+env for
        # the block on every single frame. Safe without a defensive #dup
        # (unlike #step_parallels' own loop): #step_event only sets up the
        # interpreter via #start_event, it never drives it, so no command --
        # Erase Event included -- can run synchronously here to shrink
        # @events mid-loop.
        i = 0
        size = @events.size
        while i < size
          step_event(@events[i], allow_trigger: allow_trigger)
          i += 1
        end
      end

      # Run `route`'s sub-commands until one actually costs a frame of pacing
      # delay (a Move/Turn/Wait/Jump, `Game::MoveRoute#step`'s own :moved/
      # :blocked/:turned/:waited statuses) or the route finishes -- an
      # effect-only sub-command (Switch On/Off, Speed/Frequency Up/Down,
      # Change Graphic, Play Sound, Through Mode, Stop/Start Animation,
      # Transparency Up/Down) runs free in the same frame as whatever
      # follows it, never spending a pacing tick of its own. Ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own move-route update only sets a
      # pacing delay for those four command kinds; every other sub-command
      # falls straight through to the next command within the same frame,
      # guarded only against an infinite same-frame loop on a
      # repeating route made entirely of effect commands (the same index
      # wrapping back to where it started, mirrored here via `route.index`
      # wrapping back to where this burst started). Every #step call site
      # below used to charge one full pacing delay per sub-command
      # regardless of kind, so a route mixing effect commands with moves
      # (a common "reskin then step" authoring pattern) crawled at
      # #EVENT_MOVE_DELAY's pace through commands RPG_RT spends no time on
      # at all.
      def run_route_step(route, character, world)
        start = route.index
        status = route.step(character, world)
        while status == :effect && !route.done? && route.index != start
          status = route.step(character, world)
        end
        status
      end

      def step_event(e, allow_trigger: true)
        # Cleared unconditionally, before any early return, so a crossing
        # recognised on some earlier frame (see #move_autonomous /
        # #player_intended_target) never lingers into a later frame where
        # this event does not even attempt a move -- #step_movement must
        # only ever see this true for a refusal decided *this* frame.
        e[:crossed_hero_this_frame] = false
        # An event fired earlier this frame; hold the rest -- except when this
        # is the "keep moving during the message" pass, which is *always*
        # called while busy (that is the point) and must not immediately bail.
        return if allow_trigger && event_busy?
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
        status = nil
        if forced
          status = run_route_step(forced, ch, @world) unless forced.done?
          if forced.done? # revert to page movement
            e[:forced_route] = nil
            # The page's own Move Frequency reasserts itself once the forced
            # route finishes -- a Frequency Up/Down sub-command inside that
            # route must not go on pacing the event after control reverts to
            # its page, only for the duration of the route that issued it.
            ch.move_frequency = page_move_frequency(e[:page])
          end
        elsif e[:route]
          status = run_route_step(e[:route], ch, @world) unless e[:route].done?
        else
          dir = Game::MoveType.next_direction(e[:move_type], ch, @world)
          move_autonomous(e, dir, allow_trigger: allow_trigger) if dir
        end
        # A Set Move Route (forced) or page-authored custom route stepping
        # into the hero's own tile fires this event's own Event Touch (2)
        # trigger too, the same as #move_autonomous's dedicated hero check
        # already does for a Random/Approach/Away-type move -- see
        # Game::MoveRoute#do_move's `:touched_hero` status.
        #
        # `:touched_hero` means the route's target this step was the hero's
        # own (pre-move) tile -- exactly half of a same-frame crossing (see
        # #move_autonomous for the other half and the full writeup). The
        # event is still sitting at (ox, oy), unmoved, so it is that
        # unchanged position #step_movement's own #event_at check will find
        # the party walking into if the party's already-known target this
        # frame is this same tile. Gated on `allow_trigger` for the same
        # reason #move_autonomous gates its own crossing check on it -- see
        # that comment.
        if status == :touched_hero
          e[:crossed_hero_this_frame] = allow_trigger && @player_intended_target == [ox, oy]
        end
        if allow_trigger && status == :touched_hero && !e[:crossed_hero_this_frame] &&
           e[:trigger] == TRIGGER_EVENT_TOUCH && e[:commands]
          start_event(e)
        end
        # A jump that lands where it started still needs the render slide, so
        # the hop is visible; an ordinary step only when the tile changed.
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy || ch.jumped
      rescue StandardError => ex
        $stderr.puts "[RPG2k] event ##{e[:id]} movement failed: #{ex.message}"
        nil
      end

      # Advance each event's pixel slide and walk-animation phase once per frame.
      # An event "moves" for animation purposes while it is sliding between two
      # tiles (see reoccupy / event_sliding?); such events cycle their walk
      # frames on the (fastest) #anim_frame_period cadence, while a Continuous/
      # Fixed-Continuous or Spin type standing still instead cycles on its own,
      # slower #anim_continuous_period / #anim_spin_period -- ported from a
      # reference implementation's own animation-update logic, NOT
      # independently confirmed against genuine RPG_RT under wine: it reads
      # a distinct table per case rather than one shared cadence.
      # An event resting on a tile with neither type shows its page pose.
      # Game::EventGraphic.frame reads @moving / @anim_phase to pick the drawn
      # column, and event_pixel reads the slide for the draw position.
      def animate_events
        # A plain while loop instead of #each avoids allocating a Proc+env for
        # the block on every single frame. Safe without a defensive #dup:
        # #animate_event only advances an event's own slide/animation
        # counters, it never touches @events itself.
        i = 0
        size = @events.size
        while i < size
          animate_event(@events[i])
          i += 1
        end
      end

      def animate_event(e)
        ch = e[:char]
        # Advance the slide first so a fixed-graphic event still glides smoothly.
        # The per-frame advance now follows the event's move_speed (a jump uses
        # the separate jump table) instead of a hardcoded constant, so the
        # previously-dead speed axis actually takes effect.
        if e[:move_count] < TILE
          step = e[:jumping] ? jump_slide_step(ch.move_speed)
                             : walk_slide_step(ch.move_speed)
          e[:move_count], e[:slide_frac] = advance_slide(e[:move_count], e[:slide_frac] || 0, step)
        end
        sliding = event_sliding?(e)
        e[:moving] = sliding
        type = e[:anim_type]
        return unless Game::EventGraphic.animated?(type)
        return unless sliding || Game::EventGraphic.continuous?(type)
        e[:anim_count] += 1
        # Sliding always uses the (fastest) stationary-per-frame table; an
        # event merely idling in place -- Spin rotating its facing, or a
        # Continuous/Fixed-Continuous type cycling its walk frame with nobody
        # pushing it -- uses its own slower table instead of reusing this one
        # (see #ANIM_CONTINUOUS_FRAMES / #ANIM_SPIN_FRAMES above).
        period = if sliding then anim_frame_period(ch.move_speed)
                 elsif type == Game::EventGraphic::SPIN then anim_spin_period(ch.move_speed)
                 else anim_continuous_period(ch.move_speed)
                 end
        return if e[:anim_count] < period
        e[:anim_count] = 0
        e[:anim_phase] = (e[:anim_phase] + 1) % Game::EventGraphic::WALK_COLUMNS.size
      end

      # Whether an event is mid-step: its display origin has not yet caught up to
      # its logical tile (the slide started by reoccupy is still in progress).
      def event_sliding?(e)
        return false unless e[:move_count] < TILE
        # A jump that lands on its own tile moves the sprite nowhere but is
        # still in progress, so it cannot be recognised by the displacement.
        e[:jumping] ||
          e[:disp_x] != e[:char].x || e[:disp_y] != e[:char].y
      end

      # Move an autonomous event one step in `dir`. Walking into the player fires
      # an event-touch (trigger 2) event instead of moving. ~~Any other
      # obstacle just turns the event to face it~~ -- corrected against
      # a reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own movement logic does turn to face
      # `dir` immediately, before ever
      # checking passability -- but every autonomous-movement caller sharing
      # the identical shape (random/cycle/toward-or-away-from-player movement)
      # immediately reverts that on a blocked move: once stopped, if waiting
      # on foreground execution or past the max stop count plus 60 more
      # frames, the stop count resets; otherwise the direction and (unless
      # facing is locked) the facing both revert to what they were before.
      # Since a movement decision only comes up
      # once every max-stop-count frames (64 at the default frequency 3)
      # and the extra threshold is `+ 60` *more* frames on top of that, the
      # sprite's visible facing does not change on the overwhelmingly common
      # blocked attempt -- only once genuinely stuck for a sustained stretch
      # does RPG_RT finally let it settle facing the obstruction, which this
      # method does not attempt to reproduce (a bounded blocked-streak
      # counter would need its own follow-up). `allow_trigger: false` (the
      # "keep moving during an open message" pass, see #step_events) still
      # turns the event to face the player but never starts one -- there is
      # only one foreground @interpreter, already mid-message, and RPG2000
      # never shows two message windows at once, so a second event's
      # commands have nowhere safe to run until the first message closes.
      def move_autonomous(e, dir, allow_trigger: true)
        ch = e[:char]
        nx, ny = Game::Character.step_tile(ch.x, ch.y, dir)
        if nx == @state.x && ny == @state.y
          ch.face(dir)
          # A genuine same-frame crossing (docs/TODO.md "Map Event" case (c)):
          # this event's target is the party's current tile *and* the
          # party's own already-known target this frame (see
          # #player_intended_target, snapshotted before #step_events ran) is
          # this event's current tile -- the two are trading tiles in one
          # step. Real RPG_RT invalidates the hit-test for that
          # configuration, so neither this Event Touch (2) nor the Hero
          # Touch (1) #step_movement's own #event_at check would otherwise
          # find here fires -- #step_movement consults
          # e[:crossed_hero_this_frame] for its own half.
          #
          # `allow_trigger` gates this the same way it gates the Event Touch
          # start below: the "keep moving during an open message" pass
          # (allow_trigger: false) never actually reaches #step_movement
          # this frame (the message keeps #update in its @event_busy?
          # branch), so @player_intended_target was not refreshed for this
          # frame and cannot be trusted -- treat that pass as never
          # crossing, same as it never fires the trigger either.
          crossing = allow_trigger && @player_intended_target == [ch.x, ch.y]
          e[:crossed_hero_this_frame] = crossing
          start_event(e) if allow_trigger && !crossing &&
                             e[:trigger] == TRIGGER_EVENT_TOUCH && e[:commands]
        elsif @world.passable?(ch, dir)
          ch.move(dir)
        end
      end

      # Update the occupied-tile cache after event `e` moved off (ox, oy). Done
      # eagerly (rather than a single end-of-frame rebuild) so an event that has
      # already moved this frame blocks the next event from stepping onto it.
      # Also begins the pixel slide from the old tile toward the new one so the
      # sprite glides instead of teleporting (see event_pixel).
      def reoccupy(e, ox, oy)
        deindex_event_tile(e, ox, oy)
        index_event_tile(e, e[:char].x, e[:char].y)
        start_event_slide(e, ox, oy)
      end

      # Begin a render slide for event `e` that just stepped off (ox, oy): the
      # sprite eases from that tile to its new one over a move_speed-dependent
      # number of frames (see #walk_slide_step / #jump_slide_step).
      #
      # A single-tile cardinal step slides, and so does a **jump**, however far
      # it goes -- RPG_RT carries the sprite across the whole hop and lifts it
      # along the way (see event_jump_offset), which is the point of a jump
      # clearing the tiles between. Anything else -- a multi-tile displacement
      # that is not a jump -- snaps, so a sprite never streaks across the map.
      def start_event_slide(e, ox, oy)
        jumped = e[:char].jumped
        if jumped || (e[:char].x - ox).abs + (e[:char].y - oy).abs == 1
          e[:disp_x] = ox
          e[:disp_y] = oy
          e[:move_count] = 0
          e[:slide_frac] = 0
          e[:jumping] = jumped
        else
          e[:disp_x] = e[:char].x
          e[:disp_y] = e[:char].y
          e[:move_count] = TILE
          e[:slide_frac] = 0
          e[:jumping] = false
        end
      end

      # How far event `e`'s sprite is lifted off the ground this frame, in
      # pixels: 0 unless a jump is in progress, otherwise this ported arc.
      #
      # A port of a reference implementation's own jump-height calculation,
      # NOT independently confirmed against genuine RPG_RT under wine, kept in
      # its own 256-per-tile units so the formula reads as it does there: the
      # height rises and falls linearly with the remaining step, peaking at the
      # midpoint, and is then stretched -- doubled while small (h < 5), offset
      # by 4 through h < 13, and capped at a flat 16 beyond that -- which is
      # what makes the hop leave the ground sharply, hang near the top, and
      # never rise past a full tile. The peak is exactly 16px on a 16px tile,
      # so a jumping sprite clearly leaves its row without overshooting it.
      # (This offset/cap shape was previously mis-ported as an uncapped `h +
      # 5`, peaking at 21px -- 5px, ~31%, past this arc's own ceiling --
      # now corrected to match that reference implementation's actual source
      # exactly, still not independently confirmed against genuine RPG_RT
      # under wine.)
      #
      # The lift is applied where the sprite is blitted, not inside #event_pixel:
      # matching a reference implementation's own model, the drawn character
      # is raised without moving it, so its logical position -- what the
      # camera follows and what the draw order sorts on -- stays on the ground.
      JUMP_STEP_UNITS = 256              # a reference implementation's own screen-tile-size unit
      def event_jump_offset(e)
        return 0 unless e[:jumping] && e[:move_count] < TILE
        jump_offset_for(e[:move_count])
      end

      # The arc itself, given how far through the hop the slide is (0..TILE).
      # Shared by the event sprites and the hero, so a jumping party member and
      # a jumping NPC rise by the same amount at the same point of the hop.
      def jump_offset_for(move_count)
        remaining = (TILE - move_count) * (JUMP_STEP_UNITS / TILE)
        half = JUMP_STEP_UNITS / 2
        h = (remaining > half ? JUMP_STEP_UNITS - remaining : remaining) / 8
        return h * 2 if h < 5
        h < 13 ? h + 4 : 16
      end

      # Current position of event `e` in map pixels, interpolated from its
      # display origin toward its logical tile while a slide is in progress.
      def event_pixel(e)
        [event_pixel_x(e), event_pixel_y(e)]
      end

      # The two axes of #event_pixel split out so a caller that only needs one
      # coordinate at a time (the per-event redraw signature, checked every
      # event every frame) can skip building and immediately discarding the
      # two-element array.
      def event_pixel_x(e)
        cx = e[:char].x
        return cx * TILE unless event_sliding?(e)
        e[:disp_x] * TILE + (cx - e[:disp_x]) * e[:move_count]
      end

      def event_pixel_y(e)
        cy = e[:char].y
        return cy * TILE unless event_sliding?(e)
        e[:disp_y] * TILE + (cy - e[:disp_y]) * e[:move_count]
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
        # Remembered so a page refresh cannot resurrect it: an Erase Event lasts
        # for the rest of the visit to the map, whatever its conditions do next.
        @erased_events[ev[:id]] = true
        tile = [ev[:char].x, ev[:char].y]
        deindex_event_tile(ev, tile[0], tile[1])
        # Starts frozen at the tile it occupied right before erasure --
        # #event_id_at still needs it (see there) even though the event no
        # longer blocks or draws. Not immutable, though: Change Event
        # Location / Trade Event Locations can still reposition an erased
        # event's single backing object (see #set_char_location), and keep
        # this table in sync when they do, the same way ordinary movement
        # keeps @event_last_position current for a merely-hidden one.
        @erased_event_positions[ev[:id]] = tile
        @parallels.reject! { |p| p[:event].equal?(ev) } if @parallels
      end

      # -- page refresh -------------------------------------------------------

      # An event's active page is chosen by its conditions, and those read the
      # switches, the variables, the party roster and its items, and Timer1's
      # remaining seconds. Change one and the choice can change with it — the
      # "talk to me once and I turn into my page 2" idiom every RPG2000 game is
      # built on. The pages were only ever selected when the map loaded, so an
      # event kept whichever page it started the visit with until the player
      # left and came back.
      #
      # Ported from a reference implementation, NOT independently confirmed
      # against genuine RPG_RT under wine: it re-selects them whenever those
      # change (its own need-refresh flag, set by Control Switches /
      # Variables, Change Items and
      # Change Party Member -- plus, for a Timer condition, every tick of the
      # countdown). Rather than flagging each command — which silently misses
      # any path that is not an event command, like using an item from the menu
      # — this watches the revision counters those carry, so every writer is
      # covered by construction, and the switches/variables also record *which*
      # ids were written, so a frame where a parallel process ticks an
      # unrelated counter re-selects only the events reading it (see
      # #pages_changed?). Timer1/Timer2 have no revision counter of their own,
      # but they only ever change once a second (they are already whole
      # seconds -- #timer_seconds), so comparing the swept second catches
      # exactly the frame a Timer condition's threshold is crossed without
      # sweeping every frame in between.

      # A collaborator's revision counter, or 0 for one that keeps none (the
      # party stand-ins some harnesses pass in). A source that cannot report a
      # change simply never asks for a refresh.
      def rev(o)
        o.respond_to?(:revision) && o.revision ? o.revision : 0
      end

      # Re-select every event's page if anything a condition reads has changed.
      # The sweep is cheap (a few comparisons per event) and does nothing at all
      # unless a page actually flipped, so a parallel process writing a variable
      # every frame costs a sweep, not a rebuild.
      def refresh_event_pages
        return unless pages_changed?
        rebuild_events_preserving_positions
      rescue StandardError => e
        $stderr.puts "[RPG2k] event page refresh failed: #{e.message}"
      end

      # Whether any event's conditions now pick a different page than the one it
      # is running. Walks the *map's* events rather than the live list, so it
      # also catches an event that has no active page at all right now and has
      # just gained one — those are absent from @events entirely.
      #
      # The walk is not over every event every time. Switches and Variables
      # record *which* ids were written since the last sweep (a parallel
      # process ticking a frame counter would otherwise drag the whole map
      # through re-selection every frame), and #page_condition_ids knows which
      # ids each event's pages read, so an event whose conditions reference
      # nothing that moved is skipped outright. Party and timer movement still
      # re-select everything they can affect: the party has no per-id record
      # (an item or a member appeared), and a timer-conditioned event flips on
      # the timer's own schedule.
      def pages_changed?
        evs = @map.unit.events
        return false unless evs
        sw = @state.switches
        va = @state.variables
        sw_dirty = sw.dirty
        var_dirty = va.dirty
        party_moved = rev(@state.party) != @swept_party_revision
        timer_moved = @state.timer_seconds != @swept_timer_seconds ||
                      @state.timer2_seconds != @swept_timer2_seconds
        if sw_dirty.nil? && var_dirty.nil? && !party_moved && !timer_moved
          return false
        end
        live = {}
        @events.each { |e| live[e[:id]] = e }
        changed = false
        evs.each do |id, src|
          next if changed || @erased_events[id]
          ids = page_condition_ids(id, src)
          unless party_moved ||
                 (timer_moved && ids[:timer]) ||
                 ids_touch?(ids[:switches], sw_dirty) ||
                 ids_touch?(ids[:variables], var_dirty)
            next
          end
          selected = Game::EventPage.select(src.pages, sw, va, @state.party,
                                            @state.timer_seconds, @state.timer2_seconds)
          page = selected && selected[1]
          e = live[id]
          changed = true unless page.equal?(e && e[:page])
        end
        sw.clear_dirty
        va.clear_dirty
        @swept_party_revision = rev(@state.party)
        @swept_timer_seconds = @state.timer_seconds
        @swept_timer2_seconds = @state.timer2_seconds
        changed
      end

      # Which condition inputs one map event's pages read, memoised per event
      # source: `{switches:[id..], variables:[id..], timer:bool}`. Item and
      # actor conditions are deliberately absent — they read the party, whose
      # revision gates them wholesale. Extracted from the raw page conditions
      # (the same fields #active? tests), so the skip can never disagree with
      # the selection it guards.
      def page_condition_ids(id, src)
        (@page_condition_ids ||= {})[id] ||= begin
          sw = []; var = []; timer = false
          (src.pages || []).each do |_pid, page|
            cond = page && page.condition
            next unless cond
            flags = cond.flags || 0
            sw << cond.switch_a_id if flags & Game::EventPage::SWITCH_A != 0
            sw << cond.switch_b_id if flags & Game::EventPage::SWITCH_B != 0
            var << cond.variable_id if flags & Game::EventPage::VARIABLE != 0
            timer = true if flags & (Game::EventPage::TIMER | Game::EventPage::TIMER2) != 0
          end
          { switches: sw, variables: var, timer: timer }
        end
      end

      # Whether any of `ids` appears in the sweep's dirty set (nil dirty set =
      # a bulk write, relevant to everything; nil/empty ids = this event does
      # not read this input at all).
      def ids_touch?(ids, dirty)
        return true if dirty.nil?
        return false if ids.nil? || ids.empty? || dirty.empty?
        ids.any? { |i| dirty.key?(i) }
      end

      # Rebuild the runtime events for the newly-selected pages, carrying each
      # event's **position and facing** across — RPG_RT changes an event's page,
      # not where it stands, so an NPC that flips to page 2 stays where it was
      # rather than snapping back to its spawn tile. Erased events stay erased,
      # and the parallel processes are rebuilt because a page change can add or
      # remove one.
      #
      # A custom move route in progress also carries its **execution state**
      # across, but only when the old and new page describe the byte-identical
      # route (`Game::MoveRoute.same_route?`) — RPG_RT restarts the route from
      # the top on any other page switch, custom-route or not.
      #
      # This sweep runs whenever *any* event's page selection changes
      # (#pages_changed? is a map-wide check, not per-event — see
      # #refresh_event_pages), so `build_events` above just replaced every
      # event's `Game::Character` with a brand-new one, including events whose
      # own page never changed. A fresh `Game::Character` always starts with
      # Through Mode off, facing unlocked, animation running and full opacity
      # (`Game::Character#initialize`) — none of which a page ever sets (see
      # `#build_event`, which never touches these four); they only ever change
      # via a Move Route's Through Mode / Direction Fix / Stop Animation /
      # Transparency sub-commands. Carrying x/y/direction across but not these
      # would silently wipe an unrelated event's Through Mode the instant some
      # other event's Control Switch/Variable/item write flips a page anywhere
      # on the map — the same "must be explicitly ended or it never turns back
      # off" state yado.tk documents for Through Mode specifically.
      #
      # A Move Route **Change Graphic** override is carried across the same
      # way, but only for a bystander whose own page selection did not move
      # (`old[:page].equal?(e[:page])`, the same page-identity test
      # #pages_changed? and the move-route-continuation check just below both
      # use) — unlike the four flags above, `#build_event` *does* set
      # `graphic_name`/`graphic_index` from the page every time
      # (`page_charset_name`/`page_charset_index`), so a genuine page switch
      # for *this* event (a different page with its own different base
      # sprite) must still win outright rather than have a stale override
      # painted back over it. yado.tk documents the override as reverting on
      # a real map transfer/save-load (unlike the dedicated Change Graphic
      # event command) but says nothing about it surviving *this* event's own
      # page reselecting — while an untouched bystander event, whose page
      # never moved at all, has no such excuse to lose it either, the same
      # reasoning already applied to Through Mode above.
      def rebuild_events_preserving_positions
        placed = {}
        @events.each { |e| placed[e[:id]] = e }
        # false: this is a live, in-place page reselection, not a save/load
        # restore -- see #build_event's own comment on `restore_route_index`.
        build_events(restore_route_index: false)
        @events.each do |e|
          old = placed[e[:id]]
          next unless old
          e[:char].x = old[:char].x
          e[:char].y = old[:char].y
          e[:char].direction = old[:char].direction
          e[:char].through = old[:char].through
          e[:char].facing_locked = old[:char].facing_locked
          e[:char].animation_stopped = old[:char].animation_stopped
          e[:char].transparency = old[:char].transparency
          if old[:page].equal?(e[:page])
            e[:char].set_graphic(old[:char].graphic_name, old[:char].graphic_index)
          end
          next unless e[:move_type] == Game::MoveType::CUSTOM &&
                      old[:move_type] == Game::MoveType::CUSTOM
          if Game::MoveRoute.same_route?(page_move_route(old[:page]), page_move_route(e[:page]))
            e[:route] = old[:route]
          end
        end
        rebuild_event_tiles
        # This is an in-place page reselection, not a map change -- a map
        # event's own Parallel Process id still means the same thing before
        # and after, so a still-running one whose own page did not change
        # keeps its interpreter (see #build_parallels).
        build_parallels(preserve_map_events: true)
        # The event the foreground interpreter is running may have just been
        # rebuilt; re-point it so "this event" still reaches the live character.
        @active_event = @events.find { |e| e[:id] == @active_event[:id] } if @active_event
      end

      # -- Halt All Movement --------------------------------------------------

      # If the interpreter ran a Halt All Movement this step, cancel every forced
      # move route in progress — the player's and each event's — so a route set by
      # an earlier Move Event stops where it is. Events fall back to their page's
      # autonomous movement; the player returns to input control.
      #
      # This is an abort, not an undo: RPG_RT's Cancel All Designated Moves does
      # not unwind the side effects a route already applied, so a route
      # cancelled mid-Through-Mode leaves the character stuck pass-through
      # (yado.tk) rather than reverting it. That is why @player_through is left
      # exactly as it stands here -- an event's own Through Mode already gets
      # this for free (it lives on e[:char], never touched below), and clearing
      # @player_through here would make the player the one case that quietly
      # cleans up after itself.
      def apply_halt_request(interp)
        return unless interp.take_halt_movement_request
        @player_route = nil
        @player_char = nil
        sync_player_route_to_state
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
        reload_windowskin if interp.take_system_graphic_changed
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Actor Graphic failed: #{e.message}"
        nil
      end

      # Rebuild the windowskin after a Change System Graphics override. Windows
      # created from here on (messages, menus, battle) pick up the new skin;
      # windows already open keep theirs until they are next recreated.
      def reload_windowskin
        old = @windowskin
        @windowskin = load_windowskin
        old.dispose if old && !old.equal?(@windowskin)
      end

      # Reload the party leader's CharSet graphic and apply its transparency to
      # the player sprite, forcing a redraw on the next frame.
      def refresh_player_graphic
        @charset = load_charset
        @last_frame = nil
        apply_player_visibility
        @player_bmp.clear unless @charset
      end

      # Whether the party leader's map sprite is genuinely hidden this frame --
      # the Set Transparent Flag command (11310), which RPG_RT itself calls
      # "Change Player Visibility" and implements as a real hide (param0 zero
      # hides, non-zero shows -- confirmed against genuine RPG_RT.exe under
      # wine, cycle #169; correcting a prior comment here
      # that mislabelled a reference implementation's own source as
      # "RPG_RT's own live source" -- see `Interpreter#do_player_visibility`'s
      # own comment in interpreter.rb for the full evidence). A wholly
      # separate mechanism from #player_translucent? below (a real hide vs. a
      # translucency tint, independently gating whether the sprite draws at
      # all).
      def player_hidden?
        @state.player_transparent ? true : false
      end

      # Whether the leader's *actor graphic* carries RPG2000's "Transparent"
      # ghost flag (the Change Actor Graphic (10630) dialog's own checkbox,
      # param2, or the database Actor's "Transparent" checkbox, field 5
      # `semi_transparent`) -- this does not hide the sprite, it makes it
      # translucent. Confirmed against genuine RPG_RT.exe under wine, cycle
      # #171: a from-scratch autostart page ran a real Change Sprite
      # Association on actor 15 to a real graphic ("mainchr"/4) on Map0371
      # (the genuine New Game start map), once with the command's own
      # transparent param 0 (control) and once with it 1, and the two runs
      # were screenshotted at the identical frame with no further commands
      # run. The "transparent" run's sprite pixels were consistently ~61-63%
      # of the control run's own values (1298 sampled colour channels across
      # the whole sprite, mean ratio 0.616, matching this codebase's own
      # already-implemented TRANSLUCENT_OPACITY below almost exactly) --
      # genuinely alpha-blended with the background, not hidden (0%) and not
      # left unaffected (100%). This corrects a prior version of this comment
      # that mislabelled a reference implementation's own source as
      # "RPG_RT's own live source" -- the 159/255
      # constant below happens to already match genuine RPG_RT.exe, but that
      # was never actually confirmed against real RPG_RT.exe until this
      # cycle. This codebase used to fold this flag into #player_hidden? and
      # hide the sprite outright instead.
      def player_translucent?
        leader = @state.party.leader
        leader && leader.transparent ? true : false
      end

      # The "Transparent" ghost flag's own opacity -- confirmed against
      # genuine RPG_RT.exe (see #player_translucent?'s own citation above) to
      # land around 159-160/255 (~62%); kept at 159, the exact value a
      # reference implementation independently derives via `(8 - 3) * 32 - 1`, since
      # wine's own screenshot pixels (taken through a 16bpp X11 framebuffer)
      # can't distinguish 159 from 160 to the last unit.
      TRANSLUCENT_OPACITY = 159

      # Apply both independent visibility signals to the player sprite: a
      # real Set Transparent Flag hide, and the leader graphic's own
      # translucent-ghost opacity, every frame so the hero hides/shows and
      # fades as events toggle either one.
      def apply_player_visibility
        @player_sprite.visible = !player_hidden?
        @player_sprite.opacity = player_translucent? ? TRANSLUCENT_OPACITY : 255
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

      # -- Change Parallax Background -----------------------------------------

      # If the interpreter ran a Change Parallax Background this step, tear down
      # the old panorama sprite and rebuild it from the new override
      # (Game::State#parallax). The override lasts until the next map load (see
      # perform_teleport, which clears it), when the map's own panorama returns.
      def apply_parallax_request(interp)
        return unless interp.take_parallax_request
        dispose_parallax
        setup_parallax
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Parallax Background failed: #{e.message}"
        nil
      end

      # Release the current parallax sprite / buffers before a rebuild, so a
      # mid-map panorama swap does not leak the old bitmaps.
      def dispose_parallax
        @parallax_sprite.dispose if @parallax_sprite
        @parallax_bmp.dispose if @parallax_bmp
        @parallax_img.dispose if @parallax_img
        @parallax_sprite = nil
        @parallax_bmp = nil
        @parallax_img = nil
      end

      # -- "BGM played once" ---------------------------------------------------

      # Watch the music's playback position so the conditional branch that asks
      # whether the BGM has played through at least once (12010 type 9) can be
      # answered. SDL_mixer loops a track by seeking back to its start, so a
      # position that jumped backwards is a loop; the flag is cleared whenever a
      # new BGM starts (see Game::Interpreter#play_audio). A backend that cannot
      # report a position always returns 0, which never counts as a loop.
      def watch_bgm_loop
        return if @bgm_pos_unavailable
        return unless RGSS::Audio.respond_to?(:bgm_pos)
        pos = RGSS::Audio.bgm_pos.to_i
        prev = @bgm_pos || 0
        @bgm_pos = pos
        @state.bgm_looped = true if pos < prev && @state.current_bgm
      rescue StandardError => e
        # Report once and stop polling, rather than repeating the same failure
        # sixty times a second; the branch then never reports a loop.
        @bgm_pos_unavailable = true
        $stderr.puts "[RPG2k] BGM position unavailable, 'BGM played once' " \
                     "branches will not fire: #{e.message}"
      end

      # -- Tile Substitution ---------------------------------------------------

      # A Tile Substitution rewrote a tile id on the current map (11750). The map
      # itself already answers every lookup with the substituted tile
      # (Game::Map#substitute_tile), and that same call bumps Game::Map#revision,
      # which is one of the things #tile_cache_valid? watches -- so the next
      # render rebuilds the cached tile buffers and the swap is on screen, with
      # nothing to invalidate by hand here. Draining the flag is what keeps the
      # request from being reported again next step.
      def apply_tile_substitution(interp)
        interp.take_tiles_changed
        nil
      end

      # -- Enter/Exit Vehicle --------------------------------------------------

      # Board or leave a vehicle on the event's behalf (10840) — the same toggle
      # the action button performs, so an event can put the party on the ship it
      # just placed, or set them ashore.
      def apply_vehicle_toggle(interp)
        return unless interp.take_vehicle_toggle_request
        if @state.boarded?
          disembark_vehicle
        else
          board_vehicle
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Enter/Exit Vehicle failed: #{e.message}"
        nil
      end

      # -- Play Movie ----------------------------------------------------------

      # Report a Play Movie request (11560). No video decoder is linked in, so
      # the movie cannot be shown; the request is logged rather than dropped in
      # silence, so a game that plays a cut-scene here is visible in the trace.
      def apply_movie_request(interp)
        req = interp.take_movie_request
        return if req.nil?
        $stderr.puts "[RPG2k] Play Movie '#{req[:name]}' at (#{req[:x]}, #{req[:y]}) " \
                     "#{req[:width]}x#{req[:height]}: video playback is not supported"
      end

      # -- Show Battle Animation (fire-and-forget) ------------------------------

      # Start a Show Battle Animation (11210) that was issued with its "wait
      # until it finishes" flag off. Ported from a reference implementation,
      # NOT independently confirmed against genuine RPG_RT under wine: its
      # own Show Battle Animation handling always starts the animation
      # regardless of that flag — it only gates whether the
      # interpreter's own wait_time is then set — so a fire-and-forget play is
      # still expected to render, not merely skip blocking. This codebase used to
      # only ever start one from the :animation wait dispatch
      # (#drive_map_animation), which a non-waiting call never reaches at all —
      # #do_show_battle_animation records the request either way but nothing
      # then picked it up, so it silently never played. Polled here instead,
      # right alongside every other request this interpreter queued this step
      # (Move Event, Flash Sprite, ...), for both the foreground interpreter and
      # every parallel process (#apply_interpreter_requests runs for both).
      #
      # No owner: unlike #init_map_animation's waited-for play, nothing is
      # parked on this one to #resume once it finishes (#step_map_animation
      # already treats a nil #@map_animation_interp as "no one to resume").
      #
      # When the shared on-screen slot is already busy, this play now cuts the
      # running one off instead of being dropped — the missing half of
      # #drive_map_animation's own "a second Show Battle Animation forcibly
      # cuts the first off" fix, settled the same way against a reference
      # implementation (NOT independently confirmed against genuine RPG_RT
      # under wine): its own Show Battle Animation handling
      # is a bare unconditional replacement of whatever animation is playing,
      # with no check on whether the *new* request itself carries a wait flag —
      # only the *issuing* interpreter's own resulting wait is conditional on
      # that (only set when the flag is set), the
      # cut-off of whatever was already playing is not. `#drive_map_animation`
      # only ever claims the slot this unconditional way for a *waited-for* new
      # request (reachable only through the `:animation` wait dispatch); a
      # fire-and-forget one — routed here instead, since it never waits on
      # anything — used to just check whether the slot was free and silently
      # drop itself otherwise, leaving whichever request already held it (owned
      # by a waiting interpreter, or itself ownerless) running untouched. A
      # cut-off interpreter's animation no longer exists, so — exactly like
      # #drive_map_animation's own cut-off branch — it has nothing left to wait
      # on and resumes immediately rather than being left to hang on a slot
      # that no longer holds its request.
      def apply_battle_animation_request(interp)
        req = interp.take_battle_animation_request
        return if req.nil?
        if @map_animation || @anim_wait
          cut_off = @map_animation_interp
          @map_animation = nil
          @anim_wait = nil
          cut_off.resume if cut_off
        end
        @map_animation_interp = nil
        begin_map_animation(req)
      end

      # -- Flash Sprite --------------------------------------------------------

      # Start the character flashes an interpreter queued this step (11320). The
      # hero and map events both keep their flash as a decaying colour the
      # renderer tones their CharSet frame with; a Boat/Ship/Airship target
      # instead pulses the native RGSS `Sprite#flash` primitive
      # #fire_map_target_flash already uses for the same vehicle-target case
      # under Show Battle Animation's flash_scope -- ported from a reference
      # implementation, NOT independently confirmed against genuine RPG_RT
      # under wine: its own character-lookup resolves a Boat/Ship/Airship
      # target (10002-10004) to the live vehicle object exactly like the
      # player or the current event, so its own Flash Sprite handling
      # reaches a vehicle just
      # as it reaches the player or a map event -- nothing in this ported
      # model exempts it. ~~a target that cannot be resolved (a vehicle, or an
      # unknown event id) simply flashes nothing~~ was true only for the
      # unknown-event-id half; a vehicle target is not actually unresolvable.
      # An unknown event id is still a silent no-op.
      def apply_sprite_flash_requests(interp, this_event)
        reqs = interp.take_sprite_flash_requests
        return if reqs.nil? || reqs.empty?
        started = nil
        reqs.each { |r| started = apply_sprite_flash(r, this_event) || started }
        # A Flash Sprite that carried its wait flag paused the interpreter on a
        # :sprite_flash wait; remember the flash it started so the wait releases
        # on *that* character, not on some other one still flashing.
        @flash_wait = started if interp.wait_kind == :sprite_flash
      rescue StandardError => e
        $stderr.puts "[RPG2k] Flash Sprite failed: #{e.message}"
        nil
      end

      # Start one queued flash, returning the flash it attached to a character
      # (nil when the target could not be resolved, so nothing flashes).
      def apply_sprite_flash(r, this_event)
        flash = { red: r[:red], green: r[:green], blue: r[:blue],
                  power: r[:power], frames: r[:frames], total: r[:frames] }
        return nil if flash[:frames] <= 0
        case r[:target]
        when MOVE_TARGET_PLAYER
          @state.player_flash = flash
          @last_frame = nil # force the hero's cached frame to be re-toned
          flash
        when 0, MOVE_TARGET_THIS
          this_event ? (this_event[:flash] = flash) : nil
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          type = Game::Vehicle::TYPES[r[:target] - MOVE_TARGET_BOAT]
          spr = @vehicle_sprites && @vehicle_sprites[type]
          return nil unless spr
          spr.flash(Color.new(flash[:red], flash[:green], flash[:blue], flash[:power]), flash[:frames])
          flash[:vehicle] = true
          flash
        else
          ev = @events.find { |e| e[:id] == r[:target] }
          ev ? (ev[:flash] = flash) : nil
        end
      end

      # Whether the flash a waiting Flash Sprite started is still running. The
      # flash hash is decayed in place by update_sprite_flashes, so holding the
      # reference is enough to see it run out even after the character has
      # dropped it.
      def sprite_flashing?
        @flash_wait && @flash_wait[:frames] > 0 ? true : false
      end

      # Advance every running character flash one frame, dropping the ones that
      # have decayed away. Called once per frame from #update, so a flash fades
      # during messages and forced movement too, as RPG_RT's does.
      def update_sprite_flashes
        # Invalidate the hero's cached frame whenever a flash was running this
        # tick — including the tick it ends on, so the last toned frame is
        # replaced by the plain one instead of staying baked in.
        @last_frame = nil if @state.player_flash
        @state.player_flash = tick_flash(@state.player_flash)
        # A plain while loop instead of #each avoids allocating a Proc+env for
        # the block on every single frame. Safe without a defensive #dup:
        # #tick_flash only mutates the flash hash it is handed, it never
        # touches @events itself.
        i = 0
        size = @events.size
        while i < size
          e = @events[i]
          e[:flash] = tick_flash(e[:flash]) if e[:flash]
          i += 1
        end
        # A vehicle-target Flash Sprite has no CharSet-tone hash of its own to
        # decay here (its visuals are the native sprite #update_vehicle_flashes
        # already drives) -- @flash_wait's `:vehicle` marker is only ever set
        # by #apply_sprite_flash's own vehicle branch, so this can never
        # double-decay the identical object the @state.player_flash/event
        # lines above already tick.
        @flash_wait = tick_flash(@flash_wait) if @flash_wait && @flash_wait[:vehicle]
      end

      def tick_flash(flash)
        return nil if flash.nil?
        flash[:frames] -= 1
        flash[:frames] > 0 ? flash : nil
      end

      # Decay any in-flight #fire_map_target_flash pulse on a vehicle sprite by
      # one frame -- the same "native Sprite#flash only decays when driven by an
      # explicit #update each frame" contract #update_enemy_flashes already
      # drives for the battle-only enemy sprites (mruby-rgss/src/lib.cxx's
      # spr_flash/spr_update). Called unconditionally every real frame from
      # #update, not gated on @battle, since a vehicle can be flashed by a
      # map-triggered Show Battle Animation with no fight running at all. A
      # sprite with no flash in flight costs nothing here (native #update
      # no-ops).
      def update_vehicle_flashes
        (@vehicle_sprites || {}).each_value { |s| s.update if s }
      end

      # The RGSS tone that paints `flash` over a CharSet frame: the flash colour
      # scaled by how much of the flash is left, added to every pixel (alpha is
      # untouched, so the sprite keeps its shape).
      def flash_tone(flash)
        strength = flash[:power] * flash[:frames] / flash[:total]
        Tone.new(flash[:red] * strength / 255, flash[:green] * strength / 255,
                 flash[:blue] * strength / 255, 0)
      end

      # Scratch CharSet-sized buffers the flash pass uses: the frame is blitted
      # into the first and toned into the second (tone_blt needs a same-size
      # source and writes to a separate destination).
      def flash_buffer
        @flash_buffer ||= Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
      end

      def flash_out_buffer
        @flash_out_buffer ||= Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
      end

      # -- Open Save Menu / Open Load Menu / Open Main Menu --------------------

      # Open Save Menu (11910): open the same file-select screen
      # (Scene::SaveLoad, in :save mode) Scene::Menu's own Save command opens,
      # then resume the event once the player closes it again -- whether they
      # actually saved or backed out with no picker of its own to distinguish,
      # the event just continues either way, matching RPG_RT. `@event_save_load`
      # marks that this scene is waiting on its own picker, the same one-visit
      # guard #perform_event_menu uses for Open Main Menu, so the event stays
      # paused for exactly one visit instead of reopening the picker every
      # frame.
      #
      # Unlike Scene::Menu's own Save command, this ignores `@state.save_access`
      # -- the same way Open Main Menu ignores Change Main Menu Access (see its
      # own doc comment below): the event is the designer's explicit save point,
      # and a map that forbids Save at the tree level is exactly what a
      # "save only works at this one designated event" design (Nepheshel's
      # own gate/crystal event, `db.map_tree.map_properties[12].save ==
      # Game::MapAccess::TRISTATE_FORBID`) relies on this command to bypass --
      # confirmed against Nepheshel's real data, which forbids Save on that
      # very map and puts its "SAVE" choice behind Open Save Menu regardless.
      # `it` defaults to the foreground @interpreter, but #drive_parallel_wait
      # passes its own parallel interpreter here too. Ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own Open Save Menu handling
      # is gated only on whether a message is currently active, no
      # foreground restriction, so a Common Event's or a map event's own Parallel Process
      # can trigger it exactly like the foreground can. `@event_save_load` now
      # holds the *owning interpreter* (nil when the picker is closed) rather
      # than a bare boolean, so the second visit resumes whichever interpreter
      # actually opened it -- mirroring `@shop[:interp]`/`@name_ui[:interp]`'s
      # own "who asked for this shared, singleton screen" tracking, just kept
      # as a bare ivar since there is no extra per-open state to carry here
      # (unlike the shop/name-entry widgets, a pushed Scene::SaveLoad/
      # Scene::Menu fully suspends this scene's own #update -- and so
      # #drive_parallel_wait itself -- until it pops, so there is no way for a
      # second Open Save/Load/Main Menu to race the one already open).
      def perform_event_save(it = @interpreter)
        if @event_save_load
          owner = @event_save_load
          @event_save_load = nil
          owner.resume
        else
          @event_save_load = it
          @parent.push Scene::SaveLoad.new(@parent, @state, :save)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Save Menu failed: #{e.message}"
        @event_save_load = nil
        it.resume
      end

      # Open Load Menu (5001, RPG2003): open Scene::SaveLoad in :load mode, the
      # same one-visit-guarded shape as Open Save Menu above. Confirming an
      # occupied slot calls RPG2k#continue_game, which tears down the whole
      # scene stack -- this Scene::Map instance included -- and enters the
      # loaded map; that means the "second visit" branch below only ever runs
      # after a *cancel* (a successful load simply stops this instance from
      # ever receiving another #update, picker included), which is exactly
      # when resuming the interpreter is right: nothing loaded, so the event
      # that opened the screen carries on from the next command, rather than
      # being abandoned the way the old single-slot version's unconditional
      # #stop did.
      # `it` defaults to the foreground @interpreter, but #drive_parallel_wait
      # passes its own parallel interpreter here too, for the same reason and
      # the same `@event_save_load`-holds-the-owner shape as #perform_event_save
      # just above (they deliberately share the one flag -- see its own doc
      # comment). Ported from a reference implementation, NOT independently
      # confirmed against genuine RPG_RT under wine: its own Open Load Menu
      # handling is gated only on whether a message is currently active
      # (plus its own RPG2003-English-release
      # check), same as Open Save/Main Menu.
      def perform_event_load(it = @interpreter)
        if @event_save_load
          owner = @event_save_load
          @event_save_load = nil
          owner.resume
        else
          @event_save_load = it
          @parent.push Scene::SaveLoad.new(@parent, nil, :load)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Load Menu failed: #{e.message}"
        @event_save_load = nil
        it.resume
      end

      # Exit Game (5002, RPG2003): quit, the way the title screen's Shutdown
      # entry does. `it` defaults to the foreground @interpreter but
      # #drive_parallel_wait passes its own parallel interpreter here too.
      # Ported from a reference implementation, NOT independently confirmed
      # against genuine RPG_RT under wine: its own Exit Game handling
      # is a plain interpreter method with no foreground gate, unlike
      # Open Shop/Enter Hero Name's own foreground-vs-parallel distinction, so
      # every interpreter reaches it identically. Which interpreter's own
      # #stop runs barely matters here -- #exit tears down the whole process
      # immediately after -- but it is threaded through for consistency with
      # #perform_return_to_title just below.
      def perform_exit_game(it = @interpreter)
        it.stop
        exit
      end

      # Open Main Menu (11950): push the field menu over the map, then resume the
      # event once the player closes it again. `@event_menu` marks that this
      # scene is waiting on its own menu, so the event stays paused for exactly
      # one visit instead of re-opening it every frame.
      # `it` defaults to the foreground @interpreter, but #drive_parallel_wait
      # passes its own parallel interpreter here too. Ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: its own Open Main Menu handling
      # is gated only on whether a message is currently active, no
      # foreground restriction. `@event_menu` now holds the owning interpreter (nil when
      # closed) rather than a bare boolean, the same shape (and the same
      # "a pushed Scene fully suspends #update, so nothing can race it"
      # reasoning) as `@event_save_load` above.
      def perform_event_menu(it = @interpreter)
        if @event_menu
          owner = @event_menu
          @event_menu = nil
          owner.resume
        else
          @event_menu = it
          @parent.push Scene::Menu.new(@parent, @state)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Main Menu failed: #{e.message}"
        @event_menu = nil
        it.resume
      end

      # -- Move Event (Set Move Route) ----------------------------------------

      # Apply the Move Event requests an interpreter queued this step. `this_event`
      # is the map event running that process (or nil for a common event), so a
      # route targeting "this event" reaches the right character.
      def apply_move_requests(interp, this_event)
        # TEMP DEBUG (event-29-direction investigation): identity check --
        # confirm this is literally the same interpreter object do_move_event
        # just pushed onto, and what its queue holds right before draining it.
        if (interp.event_id rescue nil) == 29
          $stderr.puts "[RPG2k][debug] apply_move_requests(event29) pre-drain " \
                       "interp_oid=#{interp.object_id} " \
                       "queue_oid=#{(interp.instance_variable_get(:@move_route_requests).object_id rescue '?')} " \
                       "queue_contents=#{(interp.instance_variable_get(:@move_route_requests).inspect rescue '?')}"
        end
        reqs = interp.take_move_route_requests
        # TEMP DEBUG (event-29-direction investigation): only log when there is
        # actually something to report -- a prior version logged every single
        # call (including every parallel process's empty poll every frame) and
        # drowned out the one call that matters.
        unless reqs.nil? || reqs.empty?
          $stderr.puts "[RPG2k][debug] apply_move_requests reqs=#{reqs.inspect} " \
                       "this_event_id=#{this_event ? this_event[:id] : 'nil'} " \
                       "interp_event_id=#{interp.event_id rescue '?'}"
        end
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_move_request(r, this_event) }
      rescue StandardError => e
        $stderr.puts "[RPG2k] Move Event apply failed: #{e.message}"
        nil
      end

      def apply_move_request(r, this_event)
        route = Game::MoveRoute.new(r[:commands], repeat: r[:repeat],
                                    skippable: r[:skippable])
        # TEMP DEBUG (event-29-direction investigation): confirm the request
        # reaches here, whether the route parsed non-empty, and what
        # `this_event` resolved to for a "this event" target.
        $stderr.puts "[RPG2k][debug] apply_move_request target=#{r[:target]} " \
                     "route_empty=#{route.empty?} this_event_id=#{this_event ? this_event[:id] : 'nil'}"
        return if route.empty?
        case r[:target]
        when MOVE_TARGET_PLAYER
          start_player_route(route, r[:frequency])
        when 0, MOVE_TARGET_THIS
          $stderr.puts "[RPG2k][debug] apply_move_request: this-event branch, " \
                       "this_event=#{this_event ? 'present' : 'NIL - route dropped'}"
          force_event_route(this_event, route, r[:frequency]) if this_event
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          type = Game::Vehicle::TYPES[r[:target] - MOVE_TARGET_BOAT]
          # Ported from a reference implementation's own Move Event handling
          # (code 11330), NOT independently confirmed
          # against genuine RPG_RT under wine:
          # "If the event is a vehicle in use, push the commands to the
          # player instead" -- a scripted vehicle ride (sail the
          # boat/airship across the map while the party stands on it) works
          # by driving the *player*, which the ridden vehicle already
          # mirrors every frame (#follow_vehicle). This used to fall
          # straight into #force_vehicle_route, which explicitly no-ops
          # while ridden (`return if @state.boarded == type`) -- the whole
          # route was silently dropped instead of redirected.
          if @state.boarded == type
            start_player_route(route, r[:frequency])
          else
            force_vehicle_route(type, route, r[:frequency])
          end
        else
          ev = @events.find { |e| e[:id] == r[:target] }
          if ev
            force_event_route(ev, route, r[:frequency])
          elsif (@map.unit.events || {})[r[:target]]
            # A real event on this map, just currently hidden because no page's
            # conditions are satisfied (#build_events never gave it a
            # Game::Character) -- yado.tk: targeting one with Set Move Route
            # hard-freezes real RPG_RT rather than erroring or silently
            # skipping, the same "control-lock until the obstruction clears"
            # family as an impassable-tile target, except this one has no
            # obstruction that can ever clear. Recorded here (rather than just
            # dropped) so #forced_movement_done? keeps Proceed With Movement
            # -- and the implicit auto-run a Wait/Show Text triggers, see
            # #step_forced_movement -- waiting forever, matching the freeze.
            @stuck_move_targets << r[:target]
          else
            # A genuinely nonexistent event id -- not "this event", not a
            # vehicle, not any id #build_events ever gave a Game::Character
            # to, and not even a real-but-currently-hidden id in the map's
            # own raw event table above. The last of the four "invalid event
            # ID" causes named in the "Concrete runtime error catalog" TODO
            # entry (stale Variable-Op/Move-Route target) -- Call Event, the
            # Variable-Op operand reads and Enemy Encounter already report
            # their own equivalents; this command silently dropped the
            # request with no trace at all. Behaviour is unchanged (still a
            # dropped, non-freezing no-op, matching the "genuinely
            # nonexistent event id does not freeze" check just above), only
            # the gap is now visible.
            $stderr.puts "[RPG2k] Move Event: target event #{r[:target]} " \
                         'not found on this map, dropping the route'
          end
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
          set_char_location(r[:target], this_event, r[:x], r[:y], r[:dir])
        end
      end

      # The current tile of a target character (the same target ids as Move
      # Event), or nil for the player-less vehicle slots / a wholly unknown
      # event id. A hidden (page condition unmet) or temporarily-erased map
      # event still answers here, from @event_last_position -- the same
      # fallback #event_position already uses, for the identical reason (see
      # its own comment). Ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine: its own
      # character-lookup chain is an unconditional
      # lookup by id with no active-state filter, so Change Event Location /
      # Trade Event Locations (both routed through here) genuinely read and
      # reposition such an event's real, single backing object there --
      # they are not restricted to only ever touching a currently-visible one.
      def char_location(target, this_event)
        case target
        when MOVE_TARGET_PLAYER
          [@state.x, @state.y]
        when 0, MOVE_TARGET_THIS
          this_event ? [this_event[:char].x, this_event[:char].y] : nil
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          v = @state.vehicle(Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT])
          [v.x, v.y]
        else
          ev = @events.find { |e| e[:id] == target }
          if ev
            [ev[:char].x, ev[:char].y]
          else
            pos = @event_last_position[target]
            pos && [pos[0], pos[1]]
          end
        end
      end

      # Instantly move a target character to a tile, optionally snapping its
      # facing too (Change Event Location's own RPG2003 facing sub-parameter
      # -- see #do_change_event_location; nil/0 leaves the current facing
      # alone, matching Teleport's own "0 means keep it" convention. Trade
      # Event Locations carries no facing at all, so it always calls this
      # with `dir` left at its default).
      #
      # A hidden or temporarily-erased map event target (no live
      # Game::Character to move) is repositioned in @event_last_position
      # instead -- the same table #char_location's own identical fallback
      # reads -- so a later page refresh that reactivates it, or a Show
      # Hidden Monster-style un-erase this codebase might add, resumes at
      # wherever the command actually sent it rather than a stale pre-move
      # tile. An erased target's frozen @erased_event_positions entry (what
      # #event_id_at reads for it -- see #erase_event) is updated the same
      # way, so a tile-occupancy query at the *old* location stops answering
      # for it and the *new* one starts.
      def set_char_location(target, this_event, x, y, dir = nil)
        case target
        when MOVE_TARGET_PLAYER
          move_player_to(x, y)
          @state.direction = dir if dir && dir > 0
        when 0, MOVE_TARGET_THIS
          if this_event
            move_event_to(this_event, x, y)
            this_event[:char].face!(dir) if dir && dir > 0
          end
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          type = Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT]
          move_vehicle_to(type, x, y)
          @state.vehicle(type).direction = dir if dir && dir > 0
        else
          ev = @events.find { |e| e[:id] == target }
          if ev
            move_event_to(ev, x, y)
            ev[:char].face!(dir) if dir && dir > 0
          elsif @event_last_position[target]
            prior_dir = @event_last_position[target][2]
            @event_last_position[target] = [x, y, (dir && dir > 0) ? dir : prior_dir]
            @erased_event_positions[target] = [x, y] if @erased_events[target]
          end
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
        @slide_frac = 0
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

      # Snap a vehicle to a tile (Change / Trade Event Location targeting a
      # vehicle). A vehicle draws tile-snapped already (#draw_vehicles), so
      # this is the whole of it -- no render slide to kick off. Keeps a
      # forced route's mirror in sync too, the same reason #move_player_to
      # does, so an in-flight route steps on from the new tile rather than
      # immediately correcting the teleport back.
      def move_vehicle_to(type, x, y)
        v = @state.vehicle(type)
        v.map_id = @state.map_id
        v.x = x
        v.y = y
        ch = @vehicle_chars[type]
        if ch
          ch.x = x
          ch.y = y
        end
      end

      # Give a map event a forced route, overriding its page movement until the
      # route finishes (a repeating route runs until replaced). It steps on the
      # next frame, paced by the requested frequency when one was given.
      def force_event_route(ev, route, freq)
        ev[:forced_route] = route
        ev[:forced_freq] = valid_move_freq(freq)
        ev[:move_timer] = 0
        # TEMP DEBUG (event-29-direction investigation): confirm the route was
        # actually armed on the target event's own runtime hash.
        $stderr.puts "[RPG2k][debug] force_event_route armed on event_id=#{ev[:id]} " \
                     "at (#{ev[:char].x},#{ev[:char].y}) dir=#{ev[:char].direction} " \
                     "forced_freq=#{ev[:forced_freq]}"
      end

      # Give vehicle `type` a forced route (Move Event / Set Move Route
      # targeting a boat/ship/airship, and only that -- a ridden vehicle is
      # redirected onto the player before this is ever reached, see
      # #apply_move_request). A no-op when the vehicle is not placed on the
      # current map (nothing here simulates a map that is not loaded); the
      # `@state.boarded == type` guard below is now unreachable through
      # #apply_move_request's own redirect but stays as a defensive no-op
      # for any other caller this method gains -- the party's own
      # #follow_vehicle already claims a ridden vehicle's position every
      # frame, so a route driving the vehicle character directly while
      # boarded would fight that.
      def force_vehicle_route(type, route, freq)
        v = @state.vehicle(type)
        return unless v.placed? && v.map_id == @state.map_id
        return if @state.boarded == type
        ch = (@vehicle_chars[type] ||= Game::Character.new(v.x, v.y, v.direction))
        ch.x = v.x
        ch.y = v.y
        ch.direction = v.direction
        # Snapshot the frequency in effect before this route starts overriding
        # it -- but only if a route is not already running, matching a
        # reference implementation's own force-move-route logic, which only
        # snapshots the frequency when no route is already overwriting it
        # (NOT independently confirmed against genuine
        # RPG_RT under wine) -- so a second Set Move Route issued mid-route
        # does not clobber the *original* pre-route value with whatever the
        # first route's own Frequency Up/Down had already left behind.
        @vehicle_orig_freq[type] = ch.move_frequency unless @vehicle_routes[type]
        ch.move_frequency = valid_move_freq(freq) || ch.move_frequency
        @vehicle_routes[type] = route
        @vehicle_route_timers[type] = 0
      end

      # Advance every vehicle's forced route one frame, each paced by its own
      # timer. Unlike the player/events, a moving vehicle is not
      # pixel-interpolated: it snaps straight onto the mirror's tile the
      # instant a step lands (#draw_vehicles already draws a vehicle
      # tile-snapped, whether parked, ridden, or -- now -- mid-route), so
      # there is no separate slide phase to drive here.
      def step_vehicle_routes
        Game::Vehicle::TYPES.each { |type| step_vehicle_route(type) }
      end

      def step_vehicle_route(type)
        route = @vehicle_routes[type]
        return unless route
        return if @state.boarded == type # frozen while ridden, see #force_vehicle_route
        ch = @vehicle_chars[type]
        @vehicle_route_timers[type] -= 1
        return if @vehicle_route_timers[type] > 0
        @vehicle_route_timers[type] = EVENT_MOVE_DELAY[ch.move_frequency] || 40
        run_route_step(route, ch, @vehicle_worlds[type]) unless route.done?
        v = @state.vehicle(type)
        v.x = ch.x
        v.y = ch.y
        v.direction = ch.direction
        if route.done?
          @vehicle_routes[type] = nil
          # The frequency in effect before this route started reasserts
          # itself the instant a non-repeating route finishes -- ported from
          # a reference implementation's own cancel-move-route logic, which
          # restores the original move frequency there, NOT
          # independently confirmed against genuine RPG_RT under wine, fired
          # the moment the last command of a non-repeating route lands. A
          # Frequency Up/Down sub-command inside that
          # route must not go on pacing the vehicle once control reverts,
          # only for the duration of the route that issued it -- the same
          # rule #step_event already applies to a Move Event's own forced
          # route.
          orig = @vehicle_orig_freq.delete(type)
          ch.move_frequency = orig if orig
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] vehicle move route failed: #{e.message}"
        @vehicle_routes[type] = nil # drop a broken route so Proceed does not hang
      end

      # Mirror the player's own forced route (or its absence) onto
      # Game::State#player_route so a save taken mid-route can resume it --
      # see that accessor's own citation in game.rb. Called at every point
      # this scene's own @player_route/@player_char changes; @player_route's
      # own #index always reflects the *next* command about to run (the one
      # a save resumes at), never one already executed.
      def sync_player_route_to_state
        @state.player_route = if @player_route
                                { commands: @player_route.commands, repeat: @player_route.repeat?,
                                  skippable: @player_route.skippable?, index: @player_route.index,
                                  frequency: @player_char && @player_char.move_frequency }
                              end
      end

      # Reconstruct a forced player route resumed from a genuine Save/
      # Continue (Game::State#player_route, populated by .from_lsd/#load_h)
      # -- the counterpart to #sync_player_route_to_state, called once from
      # #initialize. The route's own step-pacing timer is not part of either
      # save format (see that accessor's own citation), so it always
      # restarts at 0 rather than resuming mid-count.
      def restore_player_route
        # Through Mode outlives the route that set it (see #apply_halt_
        # request's own citation), so it is restored unconditionally, not
        # only alongside an active route.
        @player_through = @state.player_through ? true : false
        pr = @state.player_route
        return unless pr
        @player_char = Game::Character.new(@state.x, @state.y, @state.direction)
        @player_char.event_id = MOVE_TARGET_PLAYER
        @player_char.through = @player_through
        @player_char.move_frequency = pr[:frequency] || @player_char.move_frequency
        @player_route = Game::MoveRoute.new(pr[:commands], repeat: pr[:repeat],
                                            skippable: pr[:skippable])
        @player_route.resume_at(pr[:index]) if pr[:index]
        @player_route_timer = 0
      rescue StandardError => e
        $stderr.puts "[RPG2k] player move route restore failed: #{e.message}"
        @player_route = nil
        @player_char = nil
      end

      # Drive the player along a forced route: the player has no Game::Character,
      # so mirror one, step it against the map world and slide the party after
      # it. Input movement is suppressed while the route is active.
      def start_player_route(route, freq)
        @player_char = Game::Character.new(@state.x, @state.y, @state.direction)
        @player_char.event_id = MOVE_TARGET_PLAYER # #char_passable?/#char_can_land?'s hero test
        # Through Mode carries over from whatever an earlier route (or one
        # halted mid-Through-Mode) left it at -- a fresh mirror's own default
        # (false) would otherwise silently turn it back off.
        @player_char.through = @player_through
        @player_char.move_frequency = valid_move_freq(freq) ||
                                      @player_char.move_frequency
        @player_route = route
        @player_route_timer = 0
        sync_player_route_to_state
      end

      # Take one step of the player's forced route, if its pacing timer is up.
      #
      # A step in progress has to land before the next one begins: the route
      # character runs ahead of the party (it is what the route steps), and the
      # party's own tile only catches up when the slide completes, so stepping
      # again mid-slide would leave the two more than a tile apart and stretch
      # one slide over the gap. That also caps a forced route at the walking
      # pace, which is what it moves at on screen.
      def step_player_route
        return unless @player_route
        return if @moving
        @player_route_timer -= 1
        return if @player_route_timer > 0
        @player_route_timer = EVENT_MOVE_DELAY[@player_char.move_frequency] || 40
        ox = @player_char.x
        oy = @player_char.y
        # A boarded party's own Set Move Route commands (Dash, Jump, plain
        # movement, all alike) must clear the *ridden vehicle's* passability,
        # not on-foot chipset passability -- ported from a reference
        # implementation's own movement-collision logic (NOT independently
        # confirmed against genuine RPG_RT under wine), which unconditionally
        # delegates to the vehicle's own collision check whenever aboard,
        # with no separate branch
        # for move-route-driven movement vs. ordinary input movement, so a
        # boat/ship/airship's own boat_pass/ship_pass/airship_pass clearance
        # (or an airship's own event-blind rule) applies here exactly as it
        # already does for #try_move (the input-driven path, see
        # @state.boarded? above).
        world = @state.boarded? ? @vehicle_worlds[@state.boarded] : @world
        run_route_step(@player_route, @player_char, world) unless @player_route.done?
        # Mirror Through Mode out to the standing flag every step (not just when
        # the route ends), so a Halt All Movement mid-route sees whatever the
        # route had set so far rather than the mirror's now-discarded state.
        @player_through = @player_char.through
        @state.player_through = @player_through
        @state.direction = @player_char.direction
        if @player_char.x != ox || @player_char.y != oy || @player_char.jumped
          start_player_slide
        end
        @player_route = nil if @player_route.done?
        sync_player_route_to_state
      end

      # Begin the party's slide toward wherever the route character now stands.
      # The party stays on its own tile until the slide lands (as it does for
      # ordinary walking), so everything reading @state.x/y sees a character on a
      # tile rather than between two.
      def start_player_slide
        @dest_x = @player_char.x
        @dest_y = @player_char.y
        @moving = true
        @move_count = 0
        @slide_frac = 0
        @player_jumping = @player_char.jumped
        @player_forced_step = true
      end

      # The party's own per-frame slide advance in quarter-tile units: the walk
      # rate for the player's move_speed, doubled while aboard the Airship. The
      # airship speedup is derived straight from `@state.boarded` each frame
      # (this engine has no general per-character move-speed model to save and
      # restore the way a reference implementation's own player model does), reverting for free the
      # instant #disembark_vehicle clears it.
      def player_slide_step
        speed = @player_char&.move_speed || 3
        step = @player_jumping ? jump_slide_step(speed)
                               : walk_slide_step(speed)
        @state.boarded == :airship && !@player_jumping ? step * 2 : step
      end

      # Advance the party's pixel slide by one frame, landing it on the
      # destination tile when the slide completes. Returns true while a slide is
      # still in progress.
      #
      # Shared by ordinary movement and by Proceed With Movement, which drives
      # forced routes while the normal movement step is skipped -- without the
      # slide progressing there, a forced route would start a step and then wait
      # for a landing that never came.
      def advance_player_slide
        return false unless @moving
        @move_count, @slide_frac = advance_slide(@move_count, @slide_frac || 0, player_slide_step)
        if @move_count >= TILE
          @state.x = @dest_x
          @state.y = @dest_y
          @moving = false
          @move_count = 0
          @slide_frac = 0
          @player_jumping = false
          note_party_step
          # Random (wandering-monster) encounters only roll for ordinary
          # player-input steps, never for a forced route -- see
          # #check_random_encounter and the @player_forced_step comment above.
          check_random_encounter unless @player_forced_step
          follow_vehicle if @state.boarded? # the ridden vehicle tracks the party
        end
        # True for the landing frame as well as the ones before it: that frame
        # is spent finishing the step, not starting the next one.
        true
      end

      # How far the party's sprite is lifted off the ground this frame, in
      # pixels. The event arc, applied to the hero: a forced route is the only
      # thing that can make the player jump, and RPG_RT hops it the same way.
      def player_jump_offset
        return 0 unless @player_jumping && @moving
        jump_offset_for(@move_count)
      end

      # Advance every forced move route in progress one frame — the player's and
      # each event's — while the interpreter is paused on Proceed With Movement
      # (the normal per-frame movement is skipped because an event is running).
      # Returns true once no forced route remains, so the caller can resume the
      # interpreter. A repeating forced route never reports done, matching RPG_RT.
      def step_forced_movement
        advance_player_slide
        step_player_route
        @events.each { |e| step_forced_event(e) if e[:forced_route] }
        step_vehicle_routes
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
        unless e[:forced_route].done?
          status = run_route_step(e[:forced_route], ch, @world)
          # TEMP DEBUG (event-29-direction investigation): show each forced
          # route step actually executing, and its effect on position/facing.
          $stderr.puts "[RPG2k][debug] step_forced_event id=#{e[:id]} status=#{status} " \
                       "pos=(#{ch.x},#{ch.y}) dir=#{ch.direction} through=#{ch.through} " \
                       "route_index=#{e[:forced_route].index} route_done=#{e[:forced_route].done?}"
        end
        e[:forced_route] = nil if e[:forced_route].done?
        # A jump that lands where it started still needs the render slide, so
        # the hop is visible; an ordinary step only when the tile changed.
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy || ch.jumped
      rescue StandardError => ex
        $stderr.puts "[RPG2k] forced movement failed: #{ex.message}"
        e[:forced_route] = nil # drop a broken route so Proceed does not hang
      end

      # Whether no forced move route is still running (player or any event).
      # Spelled as !any? rather than none?: Enumerable#none? lives in mruby's
      # optional mruby-enum-ext gem, which this build does not pull in, so it
      # exists under the CRuby host checks but not in the shipped engine.
      def forced_movement_done?
        return false if @player_route
        return false if @events.any? { |e| e[:forced_route] }
        return false unless @stuck_move_targets.empty?
        !@vehicle_routes.values.any? { |route| route }
      end

      # A move frequency the request may override the target's pace with (1..8),
      # or nil to keep the target's own frequency.
      def valid_move_freq(f)
        (f && f >= 1 && f <= 8) ? f : nil
      end

      # Whether an unridden boat/ship (always) or airship (only when
      # `block_airship` is true) is parked on the current map's (x, y) --
      # ported from a reference implementation, NOT independently confirmed
      # against genuine RPG_RT under wine: its own movement-collision check
      # blocks every character type, the player included, on a Boat/Ship's
      # own tile, but only checks the Airship for a non-player mover -- an
      # unridden airship is a walkable, non-blocking tile for
      # the party on foot, but still a solid obstacle for every other
      # character (a map event's autonomous/custom-route movement, or the
      # player's own forced Set Move Route mirror, `@player_char`). A vehicle
      # currently being ridden still counts here: it tracks the party's own
      # tile every frame (`#follow_vehicle`), so checking it against a target
      # tile that is not the party's own current one only ever matches a
      # *different*, genuinely parked vehicle -- never the mover's own tile.
      # Called from both directions: `#char_passable?`/`#passable?` for a
      # non-vehicle character walking onto a parked vehicle's tile, and
      # `#vehicle_passable?`/`#airship_landable?` for the ridden vehicle's own
      # steering colliding with a *different* parked one.
      def vehicle_blocks?(x, y, block_airship:)
        types = block_airship ? Game::Vehicle::TYPES : %i[boat ship]
        types.any? do |type|
          v = @state.vehicle(type)
          v && v.placed? && v.map_id == @state.map_id && v.x == x && v.y == y
        end
      end

      # Collision test for an event stepping one tile in `dir`: in bounds,
      # passable per the chipset, and not onto the hero or another event that
      # shares its collision layer. A "through" character ignores all of this.
      #
      # Layer gates the occupancy half exactly the way a reference
      # implementation's own movement-collision check does, NOT independently
      # confirmed against genuine RPG_RT under wine: two characters only
      # collide over layer when their priority types match *exactly* -- not
      # when either happens to
      # be LAYER_SAME specifically. Two below-characters events collide with
      # each other exactly as two same-characters ones do; a below-layer
      # mover and an above-layer (or same-layer) blocker pass through each
      # other, layers differing either way. The hero's own layer is always
      # effectively LAYER_SAME (the player character never overrides its
      # layer in
      # that reference model, so
      # it keeps the same-as-characters default) -- `character.layer`
      # already reads that way whenever `character` is the party's own
      # forced Set Move Route mirror, so this single check covers the hero
      # correctly with no special-casing.
      #
      # `overlap_forbidden` is different: that reference check only ever
      # consults it when **both** sides are map events -- so it can
      # make two events collide regardless of their (mismatched) layers, but
      # can never be what blocks the hero, on either side: the party's own
      # character type is never a map event, in this ported model. `hero` (via
      # `character.event_id == MOVE_TARGET_PLAYER`) gates it out entirely
      # for the party's forced-route mirror, and it is checked on *both*
      # `character` and the blocker (`character.overlap_forbidden ||
      # b[:overlap_forbidden]`), matching `self.IsOverlapForbidden() ||
      # other.IsOverlapForbidden()` rather than the blocker's flag alone.
      # "Is this the hero" reads `character.event_id`, not
      # `character.equal?(@player_char)`, since the mirror #start_
      # player_route builds is a fresh object every route -- an identity
      # check taken from outside that method is only reliable at the exact
      # moment a caller captured the reference, not in general, while
      # `event_id` is set once, on the object itself, and answers the
      # question no matter who is asking or when.
      #
      # The chipset half asks **both** tiles at the boundary, each from its
      # own side, as RPG2000's per-direction passability does: the tile a
      # character is leaving must allow exit toward `dir`, and the tile it is
      # entering must allow entry from the opposite side (its own passability
      # bit for `TURN_180[dir]`). A wall painted on either tile blocks the
      # crossing — checking only the destination (as this used to) missed a
      # chip whose *own* tile disallowed stepping off it, which is how
      # one-way ledges and railings are authored. The upper layer gets the
      # same two-sided check: an obstacle drawn on top of the ground (a
      # boulder, a shop counter) is exactly as solid as a lower-layer wall.
      def char_passable?(character, dir)
        return true if character.through
        nx, ny = Game::Character.step_tile(character.x, character.y, dir)
        return false unless @map.in_bounds?(nx, ny)
        return false if nx == @state.x && ny == @state.y && character.layer == LAYER_SAME
        hero = character.event_id == MOVE_TARGET_PLAYER
        # A blocker's own Through Mode exempts it from every collision test
        # below, not just the layer one -- `WouldCollide` (`src/
        # game_map.cpp`) checks `self.GetThrough() || other.GetThrough()`
        # first and unconditionally, before either the overlap-forbidden or
        # the layer test, uniformly for the hero, another event, or a
        # vehicle (see `#passable?`'s own citation).
        return false if blockers_at(nx, ny).any? do |b|
          !b[:char].through && (b[:layer] == character.layer ||
            (!hero && (character.overlap_forbidden || b[:overlap_forbidden])))
        end
        return false if vehicle_blocks?(nx, ny, block_airship: !hero)
        return true if @chipset.nil?
        @chipset.passable_tile?(@map.lower(character.x, character.y),
                                 @map.upper(character.x, character.y), dir) &&
          @chipset.passable_tile?(@map.lower(nx, ny), @map.upper(nx, ny),
                                   Game::Character::TURN_180[dir] || dir)
      end
      # Called by MapWorld (an external collaborator) with an explicit receiver.
      public :char_passable?

      # Collision test for a jump landing on (x, y): the same occupancy rules as
      # a step — in bounds, not onto the player or another event — applied to an
      # arbitrary tile rather than the one ahead. The tiles the jump passes over
      # are deliberately not tested, and neither is the tile it leaves: RPG_RT
      # skips the "may I leave" half of its check while jumping, which is what
      # lets a jump clear a wall. Landing itself only fails on a tile blocked in
      # *every* direction — a jump does not arrive "from" a particular side the
      # way a step does, so the landing tile is asked whether it permits passage
      # at all rather than from one specific direction.
      def char_can_land?(character, x, y)
        return true if character.through
        # A hop that lands on the tile it left is always allowed: the character
        # occupies that tile itself, so every occupancy test below would refuse
        # it and RPG2000's hop-in-place could never happen. Found by drawing the
        # arc -- the in-place hop was silently impossible before there was
        # anything on screen to notice it by.
        return true if x == character.x && y == character.y
        return false unless @map.in_bounds?(x, y)
        # Same layer-gated occupancy rule as #char_passable? (see its
        # comment) -- including the same blocker-Through exemption.
        return false if x == @state.x && y == @state.y && character.layer == LAYER_SAME
        hero = character.event_id == MOVE_TARGET_PLAYER
        return false if blockers_at(x, y).any? do |b|
          !b[:char].through && (b[:layer] == character.layer ||
            (!hero && (character.overlap_forbidden || b[:overlap_forbidden])))
        end
        return false if vehicle_blocks?(x, y, block_airship: !hero)
        return true if @chipset.nil?
        @chipset.landable_tile?(@map.lower(x, y), @map.upper(x, y))
      end
      public :char_can_land?

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
      # Ties (several events sharing a tile, live or erased) resolve to the
      # highest id, matching #rebuild_event_tiles' own last-write-wins order.
      # A **temporarily-erased** event still answers here even though it no
      # longer blocks or draws (yado.tk: "Get Event ID at Location... still
      # returns an id for a temporarily-erased event") -- #erase_event freezes
      # its tile in @erased_event_positions instead of dropping it outright.
      # An event whose current page conditions aren't met answers too, from
      # @event_last_position (its raw placement, or wherever it last stood
      # while its own page was still active) -- ported from a reference
      # implementation, NOT independently confirmed against genuine RPG_RT
      # under wine: it keeps
      # one event object per map event for the whole visit regardless of
      # page state (its page-refresh logic clears the
      # active page and sets Through Mode on a no-match but never touches
      # x/y), and its own Store Event ID lookup
      # explicitly requests a non-active match too, so an inactive event is
      # still matched by position. Both fallback tables are checked with the
      # same last-write-wins tie-break as the live table, so several ids
      # sharing a tile -- live, erased and hidden in any mix -- still resolve
      # to the highest of them.
      def event_id_at(x, y)
        best = 0
        ev = @event_tiles[[x, y]]
        best = ev[:id] if ev
        @erased_event_positions.each do |id, tile|
          best = id if tile == [x, y] && id > best
        end
        live_ids = @events.each_with_object({}) { |e, h| h[e[:id]] = true }
        @event_last_position.each do |id, pos|
          next if live_ids[id] || @erased_events[id]
          best = id if pos[0] == x && pos[1] == y && id > best
        end
        best
      end
      public :event_id_at

      # Position of the map event with the given id (its tile x/y and facing), for
      # the Control Variables "character" operand and the Conditional Branch
      # "Character Direction is" test, or nil when the id names no event at all.
      # Queried by the interpreter via map_info.
      #
      # Falls back to @event_last_position -- the same frozen-position table
      # #event_id_at already falls back to, for the identical reason -- for an
      # event whose current page doesn't match any condition, or one Erase
      # Event has removed for the rest of this visit: ported from a
      # reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine.
      # Its own character-lookup chain is an unconditional lookup by
      # id with no active-state filter at all, and its Erase Event handling
      # only flips the event's own active flag --
      # it never removes the event object from the map's own event list -- so
      # both its Control Variables "character" X/Y/Direction cases
      # and Conditional Branch's
      # own "Orientation of char" case keep reading
      # a real, frozen last position/facing off it, not nothing. `@events`
      # (the live/active-page list this method used to search exclusively) is
      # exactly what #event_id_at's own identical fallback already had to
      # solve this same gap for.
      def event_position(id)
        ev = @events.find { |e| e[:id] == id }
        if ev
          c = ev[:char]
          return { x: c.x, y: c.y, direction: c.direction }
        end
        pos = @event_last_position[id]
        pos && { x: pos[0], y: pos[1], direction: pos[2] }
      end
      public :event_position

      # The cancel button opens the main menu over the map, unless a Change Main
      # Menu Access command has forbidden it.
      def try_open_menu
        return if event_busy?
        return unless @state.menu_access
        return unless Input.trigger?(Input::B)
        @parent.push Scene::Menu.new(@parent, @state)
      end

      # RPG_RT's F9 debug menu: a switch/variable viewer-editor, reachable from
      # the field map only (not while an event holds the interpreter) and only
      # during Test Play -- a released game (RPG2k#test_play false) never sees
      # F9 open anything, same as every other test-play-gated tool (see
      # changelog.d/test-play-gated-debug-tooling.added.md). A battle does NOT
      # block it, per community RPG_RT trivia (@2000_battle_bot /
      # デフォ戦bot): "テストプレイ中にＦ９キーを押せば スイッチ・変数の値を
      # 好きに変えられる。これは戦闘中でも行える。" -- so `@battle` alone is
      # excluded from the busy check here (Scene::Battle#update calls this
      # directly, see there), while every other #event_busy? condition (a
      # message window, an interpreter mid-wait) still gates the ordinary
      # field-map case exactly as before.
      def try_open_debug_menu
        return if event_busy? && @battle.nil?
        return unless @parent.test_play
        return unless Input.trigger?(Input::F9)
        @parent.push Scene::DebugMenu.new(@parent, @state)
      end

      def drive_event
        # An Input Number that followed a Show Text draws its digit cells
        # inside the still-open message window (see #open_number_input) --
        # check it first so it takes over from the finished text reveal.
        if @number_input
          drive_number_input
          return
        end

        # A message window with a pending Show Choices / Input Number followup
        # has finished typing and is just waiting on the interpreter to reach
        # that next command (see #drive_text_message) -- fall through to the
        # `waiting?` dispatch below instead of driving it as a live message.
        if @message && !@message[:awaiting_followup]
          drive_message
          return
        end

        # A battle opened by a Parallel Process's own Battle Processing
        # command (#drive_parallel_wait's :battle case) owns the single
        # @battle slot exactly the way the foreground does when it opens
        # one itself. While someone else holds it, the foreground must not
        # keep grinding through its own unrelated commands underneath the
        # fight -- the same freeze every *other* parallel process already
        # gets from #parallels_paused? ("Common events never run during
        # battle"). The message/choice/number dispatch above is left
        # unblocked either way, since a shown window is a shared resource
        # independent of who owns the battle.
        return if @battle && !@battle.owner.equal?(@interpreter)

        if @interpreter.waiting?
          case @interpreter.wait_kind
          when :message
            # yado.tk: a still-pending forced move route (Move Event with no
            # "wait for completion") implicitly auto-runs to completion the
            # instant the event hits a Show Text, the same way an explicit
            # Proceed With Movement would -- driven here exactly like the
            # :movement branch below, before the window is actually opened.
            open_message(@interpreter.message_lines, false) if step_forced_movement
          when :choice then open_message(@interpreter.choice_labels, true)
          when :number then open_number_input(@interpreter.input_digits)
          when :key_input then drive_key_input
          when :inn then drive_inn
          when :shop then drive_shop
          when :battle
            drive_battle
            # yado.tk 09_bug/016_ikinari_end + 017_heiretu_totyu_end/hei_mukou:
            # a Battle "Lose: Branch" handler's own recovery (a Full Heal right
            # after the encounter) races a still-running Parallel Process's own
            # Game Over check -- Scene::Battle#finish_battle already clears
            # @battle (via #close_battle, so #parallels_paused? no longer
            # holds parallel processes back) and calls #resume_battle *before*
            # this frame's own #step_parallels has any more chances to run
            # this frame, but #resume_battle only flips
            # the interpreter off its :battle wait; nothing then drives it any
            # further until #update's *next* frame -- one whole frame during
            # which the party sits at 0 HP, unrevived, for the very next
            # #step_parallels (now unpaused) to observe and fire Game Over from,
            # before the branch's own Full Heal/Change Condition ever runs.
            # Matches the :wait branch's own "Wait 0.0 sec costs one frame, not
            # two" reasoning below: once the interpreter is off the :battle wait,
            # spend the rest of this frame's own step budget on it immediately,
            # so a Lose branch with no Wait/Show Text before its recovery reaches
            # it before this frame's #step_parallels window closes, not after.
            if @interpreter.running? && !@interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :wait
            # Same implicit-Proceed-With-Movement rule as :message above, for a
            # Wait command: the wait timer does not even start counting down
            # until any pending forced route has finished.
            return unless step_forced_movement
            drive_wait
            # RPG_RT resumes a Wait the instant its timer elapses and keeps
            # spending that same frame's step budget -- Wait 0.0 sec is
            # documented as costing exactly one frame (1/60s), not two, so the
            # command right after it must not wait for a second frame here.
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
            return
          when :wait_key_enter
            drive_wait_key_enter
            # Real RPG_RT's own per-frame wait check does not `break` once
            # `wait_key_enter` clears -- it falls through into whatever
            # command comes next in that same Update() call, the same
            # "spend this frame's own step budget immediately" idiom the
            # :wait branch above documents for its own timer running out.
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
            return
          when :teleport then perform_teleport(@interpreter.teleport)
          when :movement
            @interpreter.resume if step_forced_movement
            # Same reasoning as :screen/:picture/:sprite_flash below, ported
            # from a reference implementation and NOT independently
            # confirmed against genuine RPG_RT under wine: its
            # own per-frame update loop does not unconditionally
            # `break` on the wait-movement flag either -- it only breaks
            # while a targeted move is still pending, clearing the flag once
            # it is not -- once every targeted route finishes,
            # that same update call falls straight through into whatever
            # command follows, costing no further frame.
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :screen
            @interpreter.resume unless @state.screen.busy?
            # Same "spend this frame's own step budget immediately" idiom as
            # :wait/:animation above, ported from a reference implementation
            # and NOT independently confirmed against genuine RPG_RT under
            # wine: Tint Screen and one-shot Flash Screen's
            # own wait flag is implemented with the identical wait-time
            # countdown the plain Wait command uses -- not a "poll until
            # still animating"
            # mechanism -- so its own update loop falls straight
            # through into whatever command follows the instant that
            # countdown clears, rather than costing a further frame.
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :picture
            @interpreter.resume unless @state.pictures_moving?
            # Same reasoning as :screen just above (ported from a reference
            # implementation, NOT independently confirmed against genuine
            # RPG_RT under wine): Move Picture's own wait
            # flag uses the identical wait-time field.
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :picture_blocked
            # A Show/Move/Erase Picture command reached while a message
            # window or choice list is open (#block_pending_picture_command)
            # -- ported from a reference implementation, NOT independently
            # confirmed against genuine RPG_RT under wine: it retries the
            # identical command every subsequent
            # frame rather than dropping it, see that method's own citation.
            # The retry itself is not a "wait", though: each of Show/Move/
            # Erase Picture's own command handling
            # just returns false with the
            # command index untouched while a message window blocks them --
            # its own update loop keeps looping and re-executes that
            # same command the instant the block clears, in that same frame,
            # exactly like every other command retry. Since
            # `#block_pending_picture_command` already rewinds `@index` back
            # onto the blocked command, re-invoking `#update` the moment the
            # block clears reproduces that -- it re-attempts the identical
            # command this frame, not the next one, matching this ported
            # model.
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :teleport_blocked
            # A Transfer Player / Recall to Location command reached while a
            # message window or choice list is open
            # (#block_pending_teleport_command) -- the identical
            # block-and-retry shape as :picture_blocked just above, see that
            # method's own citation and :picture_blocked's own same-frame
            # reasoning (Transfer Player / Recall to Location's own command
            # handling, the
            # identical `return false` with the index untouched -- ported
            # from a reference implementation, NOT independently confirmed
            # against genuine RPG_RT under wine).
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :battle_blocked
            # A Battle Processing / Enemy Encounter command reached while a
            # message window or choice list is open
            # (#block_pending_battle_command) -- the identical
            # block-and-retry shape as :picture_blocked/:teleport_blocked
            # above, see that method's own citation and :picture_blocked's
            # own same-frame reasoning (Enemy Encounter's own command
            # handling, the
            # identical `return false` with the index untouched -- ported
            # from a reference implementation, NOT independently confirmed
            # against genuine RPG_RT under wine).
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :exp_level_blocked
            # A "show message"-flagged Change EXP / Change Level command
            # reached while a message window or choice list is open
            # (#block_pending_exp_level_command) -- the identical
            # block-and-retry shape as :picture_blocked/:teleport_blocked/
            # :battle_blocked above, see that method's own citation and
            # :picture_blocked's own same-frame reasoning
            # (Change EXP / Change Level's own command handling, the
            # identical `return false` with
            # the index untouched -- ported from a reference implementation,
            # NOT independently confirmed against genuine RPG_RT under wine).
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :key_input_blocked
            # A waiting Key Input Processing command reached while a message
            # window or choice list is open (#block_pending_key_input_command)
            # -- the identical block-and-retry shape as :picture_blocked/
            # :teleport_blocked/:battle_blocked/:exp_level_blocked above, see
            # that method's own citation and :picture_blocked's own
            # same-frame reasoning (Key Input Processing's own command
            # handling, the identical `return false` with
            # the index untouched -- ported from a reference implementation,
            # NOT independently confirmed against genuine RPG_RT under wine).
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :message_config_blocked
            # A Message Options / Change Face Graphic command reached while a
            # *different* message window or choice list is open
            # (#block_pending_message_config_command) -- the identical
            # block-and-retry shape as :picture_blocked/:teleport_blocked/
            # :battle_blocked/:exp_level_blocked/:key_input_blocked above, see
            # that method's own citation and :picture_blocked's own
            # same-frame reasoning (Message Options / Change Face Graphic's
            # own command handling, the
            # identical `return false` with the index untouched -- ported
            # from a reference implementation, NOT independently confirmed
            # against genuine RPG_RT under wine).
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :screen_blocked
            # An Erase Screen / Show Screen command reached while a message
            # window or choice list is open (#block_pending_screen_command)
            # -- the identical block-and-retry shape as :picture_blocked/
            # :teleport_blocked/:battle_blocked/:exp_level_blocked/
            # :key_input_blocked/:message_config_blocked above, see that
            # method's own citation and :picture_blocked's own same-frame
            # reasoning (Erase Screen / Show Screen's own command handling,
            # the identical
            # `return false` with the index untouched -- ported from a
            # reference implementation, NOT independently confirmed against
            # genuine RPG_RT under wine).
            @interpreter.resume unless message_window_open?
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :return_title then perform_return_to_title
          when :game_over then perform_game_over
          when :name_input then drive_name_input
          when :animation
            drive_map_animation(@interpreter)
            # Same "spend this frame's own step budget immediately" idiom as
            # :wait/:battle above, ported from a reference implementation and
            # NOT independently confirmed against genuine RPG_RT under wine:
            # its own per-frame update loop
            # only breaks early while its wait-time countdown is still
            # above zero -- once a
            # waited-for Show Battle Animation's own countdown reaches exactly
            # 0, that same real frame's Update call falls straight through
            # into whatever command follows instead of costing a further
            # frame. `#drive_map_animation` resuming `@interpreter` here (its
            # own animation just finished naturally) used to leave it merely
            # unparked -- nothing drove it any further until next frame's
            # `#drive_event` -- so a second Show Battle Animation chained
            # right after the first always showed its own frame 0 one real
            # frame later than real RPG_RT: yado.tk's "chaining two Show
            # Battle Animation calls back-to-back produces a visible
            # one-frame stutter".
            if @interpreter.running? && !@interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :sprite_flash
            @interpreter.resume unless sprite_flashing?
            # Same reasoning as :screen/:picture above (ported from a
            # reference implementation, NOT independently confirmed against
            # genuine RPG_RT under wine): Flash Sprite's own
            # wait flag uses the identical wait-time field.
            unless @interpreter.waiting?
              @interpreter.update
              apply_interpreter_requests(@interpreter, @active_event)
            end
          when :save_menu then perform_event_save
          when :menu then perform_event_menu
          when :load_menu then perform_event_load
          when :exit_game then perform_exit_game
          end
        else
          @interpreter.update
          apply_interpreter_requests(@interpreter, @active_event)
          # A Show Battle Animation with its wait flag set builds its animation
          # object synchronously, ported from a reference implementation and
          # NOT independently confirmed against genuine RPG_RT under wine:
          # its own Show Battle Animation handling
          # starts the animation
          # in-line *before* it ever touches its own wait_time -- so the sprite's
          # frame-0 content is visible the very same real frame the command
          # runs, not one frame later. #do_show_battle_animation only arms the
          # :animation wait itself (see its own comment); #drive_map_animation,
          # the one place anything actually builds the animation, used to only
          # ever be reached the *next* time this method found the interpreter
          # already parked on that wait -- so a waited-for play always missed
          # its own frame 0 by a full frame. Fixed by building it immediately
          # once #interpreter.update leaves the interpreter freshly parked here
          # (#init_map_animation_this_frame, not the full #drive_map_animation):
          # only the *build* moves up, not that first frame's own *step* --
          # a reference implementation's own per-frame map update calls its
          # screen update (the only thing
          # that ever advances an animation once built, including the "stomp an
          # unrelated Screen/Character Flash to nothing" side effect riding
          # along with it) before its foreground-events update each real frame, so a
          # foreground command building an animation this frame does not also
          # get an extra, same-frame Update() call on it -- that first advance
          # still waits for this event's own next real-frame :animation
          # dispatch, same as before this fix. Scoped to :animation only,
          # matching this project's own previously "still open" note on this
          # exact gap.
          init_map_animation_this_frame(@interpreter) if @interpreter.waiting? && @interpreter.wait_kind == :animation
        end
      end

      # Drain every non-blocking request the interpreter queued this step and
      # apply it to the map / scene. Shared by the foreground event and each
      # parallel process, so both surfaces honour the same commands.
      def apply_interpreter_requests(interp, this_event)
        # TEMP DEBUG (event-29-direction investigation): only log the specific
        # call chain for event 29 -- this method is shared by every parallel
        # process on the map, called every single frame, so logging it
        # unconditionally drowned out the one call that matters.
        target_id = (this_event && this_event[:id] == 29) || (interp.event_id rescue nil) == 29
        $stderr.puts "[RPG2k][debug] apply_interpreter_requests(event29) called " \
                     "this_event_id=#{this_event ? this_event[:id] : 'nil'} " \
                     "interp_event_id=#{interp.event_id rescue '?'} " \
                     "interp_running=#{interp.running? rescue '?'} " \
                     "interp_waiting=#{interp.waiting? rescue '?'}" if target_id
        apply_move_requests(interp, this_event)
        apply_location_requests(interp, this_event)
        apply_erase_request(interp, this_event)
        apply_halt_request(interp)
        apply_graphic_change(interp)
        apply_tileset_request(interp)
        apply_parallax_request(interp)
        apply_tile_substitution(interp)
        apply_sprite_flash_requests(interp, this_event)
        apply_vehicle_toggle(interp)
        apply_movie_request(interp)
        apply_battle_animation_request(interp)
      end

      # Maps the interpreter's accepted-key symbols onto RGSS input buttons.
      # Decision (OK) is the confirm button C, Cancel is B — the same mapping the
      # message and menu widgets use.
      KEY_INPUT_BUTTONS = {
        down: Input::DOWN, left: Input::LEFT, right: Input::RIGHT,
        up: Input::UP, decision: Input::C, cancel: Input::B, shift: Input::SHIFT
      }.freeze

      # RPG2003's Numbers/Operators flags (see Game::Interpreter#do_key_input)
      # each accept a whole group of keys rather than one button, so unlike
      # KEY_INPUT_BUTTONS these map every digit / operator symbol its own
      # entry — #resolve_key_input samples each individually and hands the
      # interpreter whichever specific symbols (:n3, :period, ...) actually
      # fired; Game::Interpreter::KEY_INPUT_GROUPS maps them back onto the
      # :numbers/:operators accept flag. Real key backing for
      # RGSS::Input::N0..PERIOD: the SDL desktop backend binds every digit and
      # operator (src/sdl_input.cxx); the terminal/sixel backend types them
      # too, a real keyboard being able to produce them (mruby-rgss/src/
      # terminal.cxx); the PSP backend binds only the first five digits
      # (N0-N4) to its spare buttons; the Wio Terminal has no free pin left,
      # so these ids stay unbound there — the same backend split F5-F9/F12
      # follow (bound on SDL and terminal/sixel, unbound on PSP/Wio).
      NUMBER_KEY_BUTTONS = {
        n0: Input::N0, n1: Input::N1, n2: Input::N2, n3: Input::N3, n4: Input::N4,
        n5: Input::N5, n6: Input::N6, n7: Input::N7, n8: Input::N8, n9: Input::N9
      }.freeze
      OPERATOR_KEY_BUTTONS = {
        plus: Input::PLUS, minus: Input::MINUS, multiply: Input::MULTIPLY,
        divide: Input::DIVIDE, period: Input::PERIOD
      }.freeze

      def drive_key_input
        resolve_key_input(@interpreter)
      end

      # True if `btn` is down (no-wait proc) or was just pressed (waiting
      # proc) this frame, per the sampling rule #resolve_key_input applies to
      # every accepted button.
      def key_input_hit?(btn, wait)
        wait ? Input.trigger?(btn) : Input.press?(btn)
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
          active << sym if key_input_hit?(btn, req[:wait])
        end
        if accepted[:numbers]
          NUMBER_KEY_BUTTONS.each do |sym, btn|
            active << sym if key_input_hit?(btn, req[:wait])
          end
        end
        if accepted[:operators]
          OPERATOR_KEY_BUTTONS.each do |sym, btn|
            active << sym if key_input_hit?(btn, req[:wait])
          end
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
      # interpreter charges gold and heals the party in resume_inn. The inn's
      # own BGM (#play_inn_bgm) starts the first frame a request is seen and
      # #restore_pre_inn_bgm brings the prior track back once the stay resolves
      # -- either path, prompted or free. An accepted stay (prompted or free)
      # additionally fades the screen to black before the heal and back in
      # after -- see #start_inn_fade_out; Cancel and the insufficient-funds
      # no-op leave the screen alone -- ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine: its inn
      # fade only
      # runs down the accepted-stay path -- a cancelled
      # prompt never reaches it.
      #
      # `it` defaults to the foreground @interpreter, but #drive_parallel_wait
      # calls this with a Parallel Process's own instead (mirroring
      # #drive_shop/#drive_name_input's own `it` idiom) -- @inn_interp records
      # whichever one currently owns the in-progress inn flow, from here until
      # #finish_inn, so a second, distinct interpreter's own Show Inn request
      # waits its turn instead of colliding with this one's window/fade state
      # (all of it plain scene ivars, not per-interpreter).
      def drive_inn(it = @interpreter)
        req = it.inn_request
        return it.resume_inn(false) unless req
        @inn_interp = it
        if @inn_fading_out
          return if @state.screen.fading?
          @inn_fading_out = false
          finish_inn(true, it)
          return
        end
        unless @inn_bgm_started
          play_inn_bgm
          @inn_bgm_started = true
        end
        return start_inn_fade_out(it) unless req[:prompt]

        if @inn_window.nil?
          open_inn_window(req) # opened this frame; take input from the next one
          return
        end
        # Auto-repeats while held, same as #drive_message's own choice
        # cursor just above -- ported from a reference implementation, not
        # independently confirmed against genuine RPG_RT under wine: it
        # implements this exact Accept/
        # Cancel prompt as an ordinary Show Choices pair, so it inherits
        # the identical selectable-window-backed auto-repeat.
        if Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @inn_choice += 1
          @inn_choice %= 2
          set_inn_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @inn_choice -= 1
          @inn_choice %= 2
          set_inn_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          if @inn_choice.zero?
            # Accept: only honoured when the party can pay -- otherwise the
            # choice is disabled -- ported from a reference implementation,
            # not independently confirmed against genuine RPG_RT under wine,
            # whose disabled choice plays Buzzer rather than Decision.
            if req[:can_afford]
              play_system_se(SFX_DECISION)
              close_inn_window
              start_inn_fade_out(it)
            else
              play_system_se(SFX_BUZZER)
            end
          else
            play_system_se(SFX_DECISION)
            close_inn_window
            finish_inn(false, it)
          end
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_inn_window
          finish_inn(false, it)
        end
      end

      # Begin the accepted-stay fade to black (Erase Screen's own FADE_OUT
      # style, its default 35-frame length) and park in the :inn wait until it
      # settles -- #drive_inn's `@inn_fading_out` branch above resumes it and
      # calls #finish_inn once the screen is fully black. A screen already
      # erased (e.g. an event faded to black right before the Show Inn command)
      # is a no-op transition, per #Game::Screen#erase, so it resolves at once
      # exactly like Erase Screen onto Erase Screen does.
      def start_inn_fade_out(it = @interpreter)
        @state.screen.erase(Game::Transition::FADE_OUT)
        if @state.screen.fading?
          @inn_fading_out = true
        else
          finish_inn(true, it)
        end
      end

      # Restore the pre-inn BGM and resume the interpreter with the player's
      # stay/no-stay decision -- the common tail of every #drive_inn exit path.
      # An accepted stay also starts the fade back in (Show Screen's FADE_IN
      # style) here, the same frame the heal happens in resume_inn -- like real
      # RPG_RT's FinishInn, the fade-in only starts, it does not block: the
      # interpreter resumes immediately below and the screen brightens over the
      # following frames while the game keeps running.
      def finish_inn(stayed, it = @interpreter)
        @inn_bgm_started = false
        @inn_interp = nil
        restore_pre_inn_bgm
        @state.screen.show(Game::Transition::FADE_IN) if stayed
        it.resume_inn(stayed)
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

      def open_inn_window(req)
        terms = inn_terms(req[:type])
        gold_term = nonblank(db.term.gold, 'G')
        lines = ["#{terms[:greet1]} #{req[:price]}#{gold_term} #{terms[:greet2]}".strip,
                 terms[:greet3], terms[:accept], terms[:cancel]]
        # Fixed 320x80 panel flush to the screen's bottom-left corner, the
        # same panel the message window uses (MSG_WIN_W/MSG_WIN_H) -- not a
        # content-sized box inset 10px, the same stale anti-pattern already
        # fixed for the message window (ADR 0021) and the shop list window.
        # Confirmed against genuine RPG_RT.exe under wine: a live Inn
        # prompt's border touches the screen's left, right and bottom edges
        # with no gap, at exactly this size -- this codebase's own
        # content-sized box left a visible strip of map background on both
        # sides and below it.
        inner_w = MSG_WIN_W - Window::BORDER * 2
        inner_h = MSG_WIN_H - Window::BORDER * 2
        win = Window.new(0, SCREEN_H - MSG_WIN_H, MSG_WIN_W, MSG_WIN_H)
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
        # The cursor always starts on Accept, even when unaffordable --
        # confirmed against genuine RPG_RT.exe under wine: a gold-0 and a
        # gold-25 capture against a 50G price (both unaffordable) each
        # showed the cursor on Accept, matching an affordable gold-100
        # capture, never on Cancel. Real RPG_RT implements this prompt as
        # an ordinary Show Choices pair with Accept merely *disabled* when
        # unaffordable (see #drive_inn's own citation just below), and an
        # ordinary Show Choices list starts on its first entry regardless
        # of whether that entry happens to be disabled -- the same
        # listed-but-disabled shape this session's field/battle Item menu
        # fixes already established elsewhere in this codebase.
        @inn_choice = 0
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
      # Game::Shop, followed by a purchased / sold confirmation line before
      # control returns to the list; leaving resumes the interpreter with
      # whether anything was traded (which picks the [Transaction] /
      # [No Transaction] branch).
      #
      # `it` defaults to the foreground @interpreter, but #drive_parallel_wait
      # passes its own parallel interpreter here too -- see its :shop case for
      # why, mirroring #drive_name_input's own `it` idiom (`@shop[:interp]`
      # mirrors `@name_ui[:interp]` / `@message[:interp]`) for the same
      # "which interpreter actually asked for this shared, singleton screen"
      # tracking. `@shop[:interp]` is what #leave_shop resumes once the
      # player leaves.
      def drive_shop(it = @interpreter)
        req = it.shop_request
        return it.resume_shop(false) unless req
        if @shop.nil?
          open_shop(req, it) # opened this frame; take input from the next one
          return
        end
        case @shop[:screen]
        when :command  then drive_shop_command
        when :quantity then drive_shop_quantity
        when :purchased, :sold then drive_shop_confirm
        else drive_shop_list
        end
      end

      def open_shop(req, it = @interpreter)
        model = Game::Shop.new(db, @state.party, req[:goods],
                               req[:allow_buy], req[:allow_sell])
        has_menu = req[:allow_buy] && req[:allow_sell]
        screen = has_menu ? :command : (req[:allow_buy] ? :buy : :sell)
        @shop = { model: model, has_menu: has_menu, screen: screen, index: 0,
                  scroll: 0, cmd_index: 0, window: nil, gold: build_shop_gold_window,
                  status: nil, party: nil, desc: nil, prompt: nil,
                  terms: shop_terms(req[:type]), browsed: false,
                  interp: it }
        draw_shop
      end

      def shop_gold_term; nonblank(db.term.gold, 'G'); end

      # RPG2000 shop term set (1/2/3, one of three shopkeeper "voices") selected
      # by Open Shop's own type parameter, mirroring #inn_terms. Blank database
      # terms fall back to plain English so the window is never empty.
      def shop_terms(type)
        t = db.term
        i = Game.clamp(type || 0, 0, 2)
        {
          greeting: nonblank([t.shop_greeting1, t.shop_greeting2, t.shop_greeting3][i], 'Welcome!'),
          regreeting: nonblank([t.shop_regreeting1, t.shop_regreeting2, t.shop_regreeting3][i],
                               'Is there anything else you need?'),
          buy: nonblank([t.shop_buy1, t.shop_buy2, t.shop_buy3][i], 'Buy'),
          sell: nonblank([t.shop_sell1, t.shop_sell2, t.shop_sell3][i], 'Sell'),
          leave: nonblank([t.shop_leave1, t.shop_leave2, t.shop_leave3][i], 'Leave'),
          buy_select: nonblank([t.shop_buy_select1, t.shop_buy_select2, t.shop_buy_select3][i],
                               'What would you like to buy?'),
          sell_select: nonblank([t.shop_sell_select1, t.shop_sell_select2, t.shop_sell_select3][i],
                                'What would you like to sell?'),
          buy_number: nonblank([t.shop_buy_number1, t.shop_buy_number2, t.shop_buy_number3][i],
                               'How many will you buy?'),
          sell_number: nonblank([t.shop_sell_number1, t.shop_sell_number2, t.shop_sell_number3][i],
                                'How many will you sell?'),
          purchased: nonblank([t.shop_purchased1, t.shop_purchased2, t.shop_purchased3][i],
                              'Thank you!'),
          sold: nonblank([t.shop_sold1, t.shop_sold2, t.shop_sold3][i], 'Thank you!')
        }
      end

      # The shopkeeper's own line: a greeting on first entering the command
      # menu, the same shopkeeper asking "anything else?" on returning to it
      # after browsing (ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine: it
      # switches greetings once the player has entered Buy or Sell mode --
      # a per-visit flag, not a persisted "have I shopped here before"), a
      # prompt on the buy / sell / quantity screens themselves, and the
      # purchased / sold confirmation once a transaction commits. nil for any
      # other screen, which #draw_shop_prompt reads as "hide the prompt bar".
      # Follow-up (cycle #144, 2026-08-25): this used to be merged into the
      # list window's own first row (`offset`/`header` in #draw_shop below,
      # now removed) -- confirmed against genuine RPG_RT.exe under wine that
      # it is its own separate, full-width window at the screen's bottom
      # message slot instead; see #draw_shop_prompt.
      def shop_header
        t = @shop[:terms]
        case @shop[:screen]
        when :command then @shop[:browsed] ? t[:regreeting] : t[:greeting]
        when :buy then t[:buy_select]
        when :sell then t[:sell_select]
        when :quantity
          @shop[:quantity][:mode] == :buy ? t[:buy_number] : t[:sell_number]
        when :purchased then t[:purchased]
        when :sold then t[:sold]
        end
      end

      # Height of the one-line item-description bar at the very top of the
      # screen (#draw_shop_desc) -- the same one-line-plus-border shape every
      # other shop panel already uses (SHOP_LINE_H + BORDER*2), confirmed
      # against genuine RPG_RT.exe under wine (cycle #144, see #draw_shop_desc).
      SHOP_DESC_H = SHOP_LINE_H + Window::BORDER * 2

      # Fixed vertical positions of the right-hand status/gold column,
      # measured directly (border-corner-marker pixel scan, native
      # coordinates) against a genuine RPG_RT.exe capture of Nepheshel's own
      # Map0016 event 4 shop (cycle #144): status at y=80, gold at y=128 --
      # not y=6 / y=50 as this file used to hardcode before the description
      # bar above them existed. The gap above the status panel (y=30..80,
      # `SHOP_PARTY_H`) is real RPG_RT's own third window, blank for a
      # non-equipment good and holding a small icon (not yet reproduced) for
      # an equipment one -- see `#draw_shop_party`'s own doc comment and the
      # "Follow-up (cycle #145" entry in docs/TODO.md.
      SHOP_STATUS_Y = 80
      SHOP_GOLD_Y = 128

      # Docks under the status panel, sharing its own width -- confirmed
      # against genuine RPG_RT.exe under wine: a live shop's right-hand
      # column (border-color pixel scan against a real frame) shows the
      # status box then the gold box directly beneath it, both the same
      # 136px width, not a narrower box pinned to the top like this used to
      # draw. #draw_shop_status's own window uses the identical SHOP_STATUS_W
      # / SHOP_LINE_H*2+BORDER*2 shape this stacks below.
      def build_shop_gold_window
        gw = SHOP_STATUS_W
        win = Window.new(SCREEN_W - gw - 6, SHOP_GOLD_Y,
                         gw, SHOP_LINE_H + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        win
      end

      # The [label, target] rows for the current shop screen: the command menu's
      # actions, the goods on the buy list, or the party's sellable items.
      def shop_lines
        m = @shop[:model]
        t = @shop[:terms]
        case @shop[:screen]
        when :command
          rows = []
          rows << [t[:buy], :buy] if m.allow_buy?
          rows << [t[:sell], :sell] if m.allow_sell?
          rows << [t[:leave], :leave]
          rows
        when :quantity
          # The counter is one row: how many, and what the stack comes to.
          q = @shop[:quantity]
          unit = q[:mode] == :buy ? m.price(q[:id]) : m.sell_price(q[:id])
          verb = q[:mode] == :buy ? t[:buy] : t[:sell]
          [["#{verb} #{m.name(q[:id])} x#{q[:count]}  " \
            "#{unit * q[:count]}#{shop_gold_term}", q[:id]]]
        when :buy
          m.goods.map { |id| ["#{m.name(id)}  #{m.price(id)}#{shop_gold_term}", id] }
        when :purchased, :sold
          [] # the confirmation line is the whole screen -- no selectable rows
        else # :sell
          m.sellable_items.map do |id|
            ["#{m.name(id)} x#{@state.party.item_count(id)}  " \
             "#{m.sell_price(id)}#{shop_gold_term}", id]
          end
        end
      end

      # The list window's own fixed content height -- confirmed against
      # genuine RPG_RT.exe under wine (cycle #144): a 7-good Buy list and a
      # single-good Sell list both left the list window's own bottom border
      # at the identical native y (flush against the prompt bar below it,
      # see #draw_shop_prompt), rather than shrinking to fit either list's
      # actual row count the way this file used to draw it -- direct evidence
      # the box is a fixed size, not content-sized.
      #
      # A method, not a constant, purely because MSG_WIN_H/MSG_WIN_W (the
      # ordinary map message window's own shape, #draw_shop_prompt reuses
      # them too) are declared later in this same file -- a class body
      # evaluates top-level constant expressions immediately at load time, in
      # file order, unlike a method body's own lazily-resolved constant
      # lookups.
      def shop_list_min_inner_h
        SCREEN_H - SHOP_DESC_H - MSG_WIN_H - Window::BORDER * 2
      end

      # How many goods the list shows at once before it scrolls -- confirmed
      # against genuine RPG_RT.exe under wine (cycle #147, closing cycle
      # #144's own last-open shop question): Nepheshel's own weapon shop
      # (`Map0015.lmu` event 2, `武器屋の親父`) stocks 30 real goods, well
      # past the 7-row list cycle #144 measured. Driving its live Buy list
      # from the first good (ダガー/Dagger) down to the 8th (ハンマーヘッド/
      # Hammerhead, one `Down` past the 7th) found RPG_RT still shows exactly
      # 7 rows -- the top row (ダガー) drops off and the new 8th good appears
      # at the bottom -- **not** an 8-row (or taller) window, even though
      # `shop_list_min_inner_h`'s own 114px native height has room for an 8th
      # 14px row with 2px to spare by naive division. A raw-pixel column
      # scan (Python/Pillow) of the list window's own bottom border (native
      # x=50, y=152..162, spanning the row just inside the border and the
      # border itself) came back byte-identical across the
      # first page (index 0..6), the first scrolled page (index 7, i.e. rows
      # 2..8) and the very last good (index 29, `Map0015`'s own 30th and
      # final good, サーキュレット/Circlet) -- the window never moves or
      # resizes at any of the three; only which 7 goods (and which one is
      # highlighted) changes. So real RPG_RT reserves room for 7 rows and
      # leaves the remaining ~16px of the fixed 114px content height
      # unused rather than fitting an 8th row into it -- a fixed row *count*,
      # not a derived one, which is why this is its own named constant
      # instead of `shop_list_min_inner_h / SHOP_LINE_H` (that division
      # rounds down to 8, one row more than RPG_RT actually shows).
      SHOP_LIST_ROWS = 7

      def draw_shop
        lines = shop_lines
        @shop[:index] = Game.clamp(@shop[:index], 0, [lines.length - 1, 0].max)
        # Scroll the fixed SHOP_LIST_ROWS-tall window instead of growing it
        # past that -- confirmed against genuine RPG_RT.exe under wine
        # (cycle #147, see SHOP_LIST_ROWS' own comment for the full
        # evidence). `@shop[:scroll]` is the index of the first *visible*
        # good; nudged by the minimum amount needed to keep the cursor
        # (`@shop[:index]`) inside the visible page, matching every other
        # RPG2000 list window's own "scroll just far enough to reveal the
        # cursor" behaviour rather than snapping to a page boundary.
        @shop[:scroll] ||= 0
        @shop[:scroll] = @shop[:index] if @shop[:index] < @shop[:scroll]
        if @shop[:index] > @shop[:scroll] + SHOP_LIST_ROWS - 1
          @shop[:scroll] = @shop[:index] - SHOP_LIST_ROWS + 1
        end
        @shop[:scroll] = Game.clamp(@shop[:scroll], 0, [lines.length - SHOP_LIST_ROWS, 0].max)
        # The command menu's own Buy/Sell/Leave rows are never drawn into
        # this list window -- confirmed against genuine RPG_RT.exe under
        # wine (cycle #148, a synthetic mode=0 Open Shop command spliced
        # onto Map0012 via a new autostart event): on the native :command
        # has_menu screen this window is a real, bordered window at its
        # usual position/size (same border-pixel geometry as every other
        # screen, confirmed by a column scan) but always empty -- no text,
        # no cursor -- across all three command rows in turn (Buy/Sell/Leave
        # each screenshotted highlighted in turn showed the identical blank
        # window). The actual choice list renders merged into the bottom
        # prompt window instead -- see #draw_shop_command_prompt.
        visible = @shop[:screen] == :command ? [] : (lines[@shop[:scroll], SHOP_LIST_ROWS] || [])
        # Docks flush to the screen's left edge, not inset 10px -- the same
        # stale anti-pattern ADR 0021 already diagnosed and fixed for the
        # message window ("300px wide, inset 10px" -> "fixed 320x80 at
        # x=0"), which this window never picked up. Full screen width on the
        # command menu and the sell list (no side panels); narrowed to leave
        # room for the status/gold column otherwise -- confirmed against
        # genuine RPG_RT.exe under wine: a live shop's list window right
        # edge lands exactly where the panel column starts on Buy/the
        # quantity counter, flush with the panel's own SHOP_STATUS_W+6
        # offset from the screen's right edge.
        win_w = SHOP_PANELS_VISIBLE_ON.include?(@shop[:screen]) ? SCREEN_W - SHOP_STATUS_W - 6 : SCREEN_W
        inner_w = win_w - Window::BORDER * 2
        # Always the same fixed height -- never content-sized, whether the
        # list is short (cycle #144's single-good Sell list) or long enough
        # to scroll (cycle #147's 30-good Buy list): #shop_list_min_inner_h
        # already exceeds SHOP_LIST_ROWS * SHOP_LINE_H, so this is really
        # just `shop_list_min_inner_h` now that the row count rendered can
        # never exceed SHOP_LIST_ROWS -- kept as a `max` for clarity, not
        # because the two branches still differ.
        inner_h = [visible.length, 1].max * SHOP_LINE_H
        inner_h = [inner_h, shop_list_min_inner_h].max
        @shop[:window].dispose if @shop[:window]
        # Top-anchored right below the description bar (#draw_shop_desc), not
        # bottom-anchored above a 6px screen margin -- confirmed against
        # genuine RPG_RT.exe under wine (cycle #144): the shopkeeper's own
        # prompt (formerly this window's own merged first row, now
        # #draw_shop_prompt's separate bottom bar) never appeared inside this
        # window at all.
        win = Window.new(0, SHOP_DESC_H, win_w, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        visible.each_with_index do |(label, _), i|
          c.draw_text 0, i * SHOP_LINE_H, inner_w, SHOP_LINE_H, label
        end
        win.contents = c
        unless visible.empty?
          cursor_row = @shop[:index] - @shop[:scroll]
          win.cursor_rect = Rect.new(0, cursor_row * SHOP_LINE_H, inner_w, SHOP_LINE_H)
        end
        @shop[:window] = win
        draw_shop_gold
        draw_shop_status(lines)
        draw_shop_party(lines)
        draw_shop_desc(lines)
        draw_shop_prompt
      end

      # The full-width, one-line item-description bar above the list --
      # confirmed against genuine RPG_RT.exe under wine (cycle #144, driving
      # Nepheshel's own Map0016 event 4 shop): shows the highlighted good's
      # own database description ("HPを80ポイント程度回復する" for 薬草), at
      # native (0, 0), SCREEN_W wide, SHOP_DESC_H tall -- a real, separate
      # window this codebase drew nothing for before. Broader than the
      # status/gold panels' own SHOP_PANELS_VISIBLE_ON (also shown on Sell,
      # confirmed live -- a single-good Sell list showed the same bar with
      # the sold item's own description, even though Sell gets no status/gold
      # column).
      #
      # Follow-up (cycle #148, 2026-08-25): the command menu is *not* a
      # fourth hidden case after all -- confirmed against genuine RPG_RT.exe
      # under wine (a synthetic mode=0 Open Shop command, allow_buy and
      # allow_sell both set, spliced onto a new autostart event on Map0012):
      # the native :command has_menu screen shows this exact window too, at
      # the identical position, still bordered -- a raw-pixel scan of its
      # interior found nothing but the background gradient (no glyph-colour
      # pixels at all), i.e. present but blank, not disposed. Cycle #144's
      # own guess that it hides on :command was an unverified inference and
      # turned out wrong; #shop_desc_item_id already returned nil there
      # (correctly -- no single good is ever highlighted on the command
      # menu), so the fix is only in #draw_shop_desc no longer treating a nil
      # id as "hide the window" -- it draws blank text instead, extending the
      # same "always shown, blank without an id" reading to the other nil-id
      # case (an empty Buy/Sell list) by inference, since that case is still
      # not directly reachable through any known genuine shop and was never
      # independently verified either way before or after this fix.
      SHOP_DESC_VISIBLE_ON = %i[command buy sell quantity purchased sold].freeze

      def shop_desc_item_id(lines)
        return nil unless SHOP_DESC_VISIBLE_ON.include?(@shop[:screen])
        case @shop[:screen]
        when :buy, :sell
          return nil if lines.nil? || lines.empty?
          lines[@shop[:index]][1]
        when :quantity, :purchased, :sold
          @shop[:quantity] && @shop[:quantity][:id]
        end
      end

      def draw_shop_desc(lines)
        id = shop_desc_item_id(lines)
        win = @shop[:desc]
        unless win
          win = Window.new(0, 0, SCREEN_W, SHOP_DESC_H)
          win.z = 300
          win.windowskin = @windowskin
          @shop[:desc] = win
        end
        inner_w = SCREEN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, SHOP_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, SHOP_LINE_H, id ? @shop[:model].description(id) : ''
        win.contents = c
      end

      # The shopkeeper's own prompt/greeting line (#shop_header), now its own
      # full-width window at the screen's fixed bottom message slot -- reusing
      # the ordinary map message window's own MSG_WIN_W/MSG_WIN_H shape and
      # bottom position (ADR 0021), which the shop screen's own capture
      # (cycle #144) landed on exactly (native y=160, height 80). Replaces the
      # old "merged into the list window's own first row" shape #draw_shop
      # used before.
      #
      # The command menu draws differently in this same window -- see
      # #draw_shop_command_prompt.
      def draw_shop_prompt
        return draw_shop_command_prompt if @shop[:screen] == :command
        text = shop_header
        if text.nil?
          @shop[:prompt].dispose if @shop[:prompt]
          @shop[:prompt] = nil
          return
        end
        win = @shop[:prompt]
        unless win
          win = Window.new(0, SCREEN_H - MSG_WIN_H, MSG_WIN_W, MSG_WIN_H)
          win.z = 300
          win.windowskin = @windowskin
          @shop[:prompt] = win
        end
        inner_w = MSG_WIN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, SHOP_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, SHOP_LINE_H, text
        win.contents = c
      end

      # The native :command has_menu screen's greeting/regreeting line and its
      # Buy/Sell/Leave choices, merged into one window -- confirmed against
      # genuine RPG_RT.exe under wine (cycle #148, see #draw_shop's own
      # citation for the full setup): the three choice rows are *not* drawn
      # into the main list window (#draw_shop leaves it blank on :command)
      # but directly below the greeting text, inside this same
      # MSG_WIN_W x MSG_WIN_H bottom window -- the same "message text with a
      # choice list attached directly beneath it" shape this codebase's own
      # Show Inn prompt already uses for its own Accept/Cancel pair
      # (#open_inn_window / #set_inn_cursor), and the same shape Nepheshel's
      # own choice-scripted shop NPCs use when *they* build a Buy/Sell/Cancel
      # menu by hand via Show Message + Show Choices (docs/TODO.md's own
      # cycle #144 entry) -- real RPG_RT's native has_menu screen turns out to
      # be built from that identical primitive, not a bespoke command window.
      #
      # Row spacing is MSG_LINE_H (16 native), not SHOP_LINE_H/INN_LINE_H (14)
      # -- measured directly off the wine capture (a glyph-row pixel scan of
      # the four text rows landed on a 16px-native pitch, matching this
      # window's own ordinary message-line metric, not the shop list's own
      # compressed one), which makes sense once this is understood to be the
      # message window's own text renderer rather than the shop list's.
      def draw_shop_command_prompt
        rows = shop_lines
        text_lines = [shop_header] + rows.map { |label, _| label }
        win = @shop[:prompt]
        unless win
          win = Window.new(0, SCREEN_H - MSG_WIN_H, MSG_WIN_W, MSG_WIN_H)
          win.z = 300
          win.windowskin = @windowskin
          @shop[:prompt] = win
        end
        inner_w = MSG_WIN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, text_lines.length * MSG_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        text_lines.each_with_index do |line, i|
          c.draw_text 0, i * MSG_LINE_H, inner_w, MSG_LINE_H, line
        end
        win.contents = c
        win.cursor_rect = Rect.new(0, (1 + @shop[:index]) * MSG_LINE_H, inner_w, MSG_LINE_H)
      end

      # The gold and status panels share one visible/hidden set: ported from
      # a reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: its
      # right-hand panels are shown
      # for Buy, BuyHowMany/SellHowMany and Bought/Sold, and hidden for
      # BuySellLeave and Sell -- not "whichever screen highlights one item",
      # the reasoning a prior pass here used, which got the Sell list and the
      # quantity/confirmation screens backwards.
      SHOP_PANELS_VISIBLE_ON = %i[buy quantity purchased sold].freeze

      def draw_shop_gold
        visible = SHOP_PANELS_VISIBLE_ON.include?(@shop[:screen])
        @shop[:gold].visible = visible
        return unless visible
        gw = SHOP_STATUS_W
        c = Bitmap.new(gw - Window::BORDER * 2, SHOP_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, SHOP_LINE_H,
                    "#{@state.party.gold}#{shop_gold_term}"
        @shop[:gold].contents = c
      end

      # 136px wide -- confirmed against genuine RPG_RT.exe under wine (see
      # #build_shop_gold_window's own doc comment for the border-color pixel
      # scan): two rows tall enough for one SHOP_LINE_H label line each, plus
      # the ordinary window border.
      SHOP_STATUS_W = 136

      # The item id the status panel should describe. On the buy list it is
      # whichever row the cursor sits on; on the quantity counter and the
      # purchase/sale confirmation it is the item the counter was opened for
      # (kept alive in `@shop[:quantity]` through the confirmation screen --
      # see #drive_shop_quantity / #drive_shop_confirm). The command menu and
      # the sell list get no status panel at all, matching SHOP_PANELS_VISIBLE_ON.
      def shop_status_item_id(lines)
        case @shop[:screen]
        when :buy
          return nil if lines.nil? || lines.empty?
          lines[@shop[:index]][1]
        when :quantity, :purchased, :sold
          @shop[:quantity] && @shop[:quantity][:id]
        end
      end

      # The status panel beside the buy/sell list: the `possessed_items` /
      # `equipped_items` database terms with their counts for the currently
      # highlighted item right-aligned beside them -- ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: it refreshes the same way, from the
      # list's own cursor. `possessed` is the bag only
      # (Party#item_count, matching the sell list's own x-count suffix);
      # `equipped` sums every slot on every party member holding the item
      # (Party#equipped_item_count) -- a copy currently equipped no longer
      # counts toward the bag, so the two rows can both be nonzero at once.
      def draw_shop_status(lines)
        id = shop_status_item_id(lines)
        if id.nil?
          @shop[:status].dispose if @shop[:status]
          @shop[:status] = nil
          return
        end
        win = @shop[:status]
        unless win
          # Right-aligned, not the screen's left edge -- confirmed against
          # genuine RPG_RT.exe under wine (see #build_shop_gold_window's own
          # doc comment for the capture this and the gold panel's position
          # both come from). Y is SHOP_STATUS_Y, not the screen's own 6px top
          # margin -- see that constant's own doc comment (cycle #144).
          win = Window.new(SCREEN_W - SHOP_STATUS_W - 6, SHOP_STATUS_Y,
                           SHOP_STATUS_W, SHOP_LINE_H * 2 + Window::BORDER * 2)
          win.z = 300
          win.windowskin = @windowskin
          @shop[:status] = win
        end
        inner_w = SHOP_STATUS_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, SHOP_LINE_H * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, SHOP_LINE_H, nonblank(db.term.possessed_items, 'Possessed')
        c.draw_text 0, SHOP_LINE_H, inner_w, SHOP_LINE_H, nonblank(db.term.equipped_items, 'Equipped')
        c.draw_text 0, 0, inner_w, SHOP_LINE_H, @state.party.item_count(id).to_s, 2
        c.draw_text 0, SHOP_LINE_H, inner_w, SHOP_LINE_H,
                    @state.party.equipped_item_count(id).to_s, 2
        win.contents = c
      end

      # The band between the description bar and the status panel (native y
      # SHOP_DESC_H..SHOP_STATUS_Y, 30..80) that cycle #144 found real
      # RPG_RT draws and left entirely undrawn, having only tested a
      # non-equipment good (medicine) -- confirmed blank for that case, but
      # never tried an actual weapon/armour good. Closed this cycle (#145):
      # reached a live Buy list of genuine weapon/armour/shield goods
      # (Nepheshel's own weapon-shop NPC, Map0015 event 2 -- a real, shipped
      # Open Shop mode=1 (buy-only) type=2 command Nepheshel's own database
      # ships, never a synthetic one) and found real RPG_RT draws a bordered
      # window here -- same x/width as the status panel below it
      # (SCREEN_W - SHOP_STATUS_W - 6, SHOP_STATUS_W wide), height
      # SHOP_PARTY_H -- holding one small icon, left-aligned near its own top
      # edge, *only* when the highlighted good is equipment (database type
      # 1..5: weapon/shield/armour/helmet/accessory -- `Game::Shop#equip?`);
      # for a non-equipment good (medicine, confirmed again this cycle) the
      # band is blank, matching cycle #144's own finding exactly.
      #
      # Cycle #145 left the icon itself unreproduced. What it ruled out, each
      # confirmed live against genuine RPG_RT.exe under wine rather than
      # assumed:
      #   - **not a per-item stat comparator**: pixel-identical across a
      #     97x price/stat range (150G ダガー/Dagger through 1400G
      #     バスタードソード/Bastard Sword through 4500G プレートメイル/Plate
      #     Mail), where a comparator (up/down arrow, or coloured delta) would
      #     have to change at least once -- unlike this codebase's own other
      #     equip-comparison UI, `equip_menu.rb`'s `#draw_stat_row`, which
      #     draws a `>` glyph and a coloured new-value *number*, not an icon,
      #     confirming the shop's icon is a different mechanism, not
      #     reusable from there;
      #   - **not a Left/Right party-member preview selector**: Left and
      #     Right, which such a selector would visibly answer to, produced no
      #     change either (tested with the save's own single-member party --
      #     left open whether a multi-member party would show more than one
      #     icon here, since growing the test party risked cycle #135's own
      #     documented party-field crash and was out of scope for this
      #     cycle's time-box).
      #
      # Follow-up (cycle #146, 2026-08-25): identified the icon itself via
      # asset forensics, exactly the "windowskin/system-graphic asset dump
      # and a pixel-for-pixel crop compare" cycle #145 suggested as the next
      # step. Nepheshel's own System graphic (`System/システム.png`) ships a
      # genuinely corrupt IDAT stream -- a strict `Zlib::Inflate` rejects it
      # outright ("invalid distance too far back", 0 bytes decoded even
      # through raw deflate with the zlib header stripped), confirmed by hand
      # against the file's own bytes (every PNG chunk CRC still matches, so
      # this is not transfer corruption -- the deflate stream itself has a
      # back-reference before the start of output, RPG Maker's own
      # historically-known "buggy windowskin PNG" shape). Decoded cleanly
      # instead through this project's *own* tolerant inflater
      # (`RGSS::Bitmap#bmp_decode_into` in `scripts/rgss_cruby_compat.rb`, a
      # pure-Ruby port of `src/lib.cxx`'s `png_tol::inflate_tolerant` --
      # already written for exactly this "RPG Maker windowskins" case per its
      # own doc comment, just never previously exercised on this particular
      # file), which recovered all 160x80 pixels and exposed an 8x8-celled
      # icon grid at System-graphic (128..160, 0..32) this codebase had never
      # read before, including four visually-identical downward "droplet"
      # icons at y=16..24.
      #
      # Drove genuine RPG_RT.exe under wine to the same live weapon-shop Buy
      # list cycle #145 reached (Map0015 event 2, `--map 15 --at 5,9
      # --facing up --clear-scene`) and read the captured screenshot's raw
      # pixels directly (not eyeballed): the mystery band's icon is a
      # byte-for-byte match, modulo the wine capture's own RGB565
      # quantisation (ADR 0021's own noted floor, ±1-3 per channel here), for
      # the System graphic's first droplet cell at (128, 16), 8x8, scaled 2x
      # by the capture pipeline itself -- Xvfb runs the reference at 640x480
      # while RPG2000's native resolution is SCREEN_W x SCREEN_H (320x240);
      # confirmed independently by every other landmark measured in the same
      # capture (the description-bar/status-panel border dividers this cycle
      # re-measured land on the *existing* SHOP_DESC_H=30 / SHOP_STATUS_Y=80
      # / SHOP_GOLD_Y=128 constants once halved, reconfirming those cycle
      # #144 constants rather than contradicting them). Confirmed fixed, not
      # per-item: the identical crop (0 differing pixels) reappeared at the
      # identical position for both the first-highlighted 150G ダガー/Dagger
      # and, after moving the cursor down four rows, the 800G
      # ブロードソード/Broad Sword -- extending cycle #145's own
      # "pixel-identical across every stat tier" finding to *position* too,
      # not just content. Native draw position: interior offset (22, 22)
      # from the party window's own top-left interior corner (the icon's own
      # absolute native pixel position, halved from the capture, measured
      # against the window's already-established origin -- `SCREEN_W -
      # SHOP_STATUS_W - 6 + Window::BORDER`, `SHOP_DESC_H + Window::BORDER`).
      #
      # Fixed: `#draw_shop_party` now blits `SHOP_PARTY_ICON_SRC` (the
      # measured 8x8 System-graphic cell) from `@windowskin` onto the
      # window's own contents at `SHOP_PARTY_ICON_OFFSET`, once at window
      # creation (the icon is static -- confirmed above -- so unlike the
      # status/gold panels' own per-frame text redraw, this needs no repaint
      # while the window stays open). Still open for a future cycle: what
      # this specific icon *represents* semantically (its neighbours in the
      # same 8x8 grid -- the pink triangles at y=0..8 and the glyphs at
      # y=24..32 -- were not identified either, and this project deliberately
      # does not consult EasyRPG source to name them) and whether a
      # multi-member party shows more than one copy of it -- this cycle's
      # save still carried only the same single live party member cycle #145
      # tested with, for the same reason (growing it risks cycle #135's
      # documented party-field crash).
      SHOP_PARTY_H = SHOP_STATUS_Y - SHOP_DESC_H

      # The equipment-good icon's own source cell in the System graphic, and
      # its draw offset inside the party window's interior -- see the cycle
      # #146 doc comment above for the pixel-scan evidence behind both.
      SHOP_PARTY_ICON_SRC = Rect.new(128, 16, 8, 8)
      SHOP_PARTY_ICON_OFFSET = [22, 22].freeze

      def draw_shop_party(lines)
        id = shop_status_item_id(lines)
        visible = id && @shop[:model].equip?(id)
        unless visible
          @shop[:party].dispose if @shop[:party]
          @shop[:party] = nil
          return
        end
        @shop[:party] ||= begin
          win = Window.new(SCREEN_W - SHOP_STATUS_W - 6, SHOP_DESC_H,
                           SHOP_STATUS_W, SHOP_PARTY_H)
          win.z = 300
          win.windowskin = @windowskin
          if @windowskin
            c = Bitmap.new(SHOP_STATUS_W - Window::BORDER * 2,
                           SHOP_PARTY_H - Window::BORDER * 2)
            ox, oy = SHOP_PARTY_ICON_OFFSET
            c.blt ox, oy, @windowskin, SHOP_PARTY_ICON_SRC
            win.contents = c
          end
          win
        end
      end

      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: the Buy/Sell/Leave list plays
      # Decision unconditionally on any confirm (all three commands always
      # succeed, so there is no Buzzer case here) and Cancel on B, matching
      # every other RPG2000 command list.
      def drive_shop_command
        lines = shop_lines
        if shop_move_cursor(lines)
          # cursor moved
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          case lines[@shop[:index]][1]
          when :buy  then shop_switch(:buy)
          when :sell then shop_switch(:sell)
          when :leave then leave_shop
          end
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_shop
        end
      end

      # Ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine: Decision opens the
      # quantity counter for an item the party can actually buy/sell right
      # now, Buzzer instead the instant that check fails --
      # #open_shop_quantity's own `max <
      # 1` guard is that same check -- and Cancel on B either way.
      def drive_shop_list
        lines = shop_lines
        if shop_move_cursor(lines)
          # cursor moved
        elsif Input.trigger?(Input::C) && !lines.empty?
          if open_shop_quantity(lines[@shop[:index]][1])
            play_system_se(SFX_DECISION)
          else
            play_system_se(SFX_BUZZER)
          end
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @shop[:has_menu] ? shop_switch(:command) : leave_shop
        end
      end

      # The purchased / sold confirmation shown right after a transaction
      # commits (Game::Shop#buy / #sell): a single line, auto-dismissed after
      # a flat one-second timer, then back to the list it came from.
      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: its confirmation state
      # decrements a timer each frame and switches back to the list once it
      # reaches zero, arming a fresh one-second (60-frame) timer on
      # entry. Nothing reads input during the Buy/Sell confirmation state,
      # so a button press neither dismisses the confirmation early nor
      # does anything else while it is up.
      def drive_shop_confirm
        @shop[:confirm_timer] -= 1
        return if @shop[:confirm_timer] > 0
        @shop[:screen] = @shop[:screen] == :purchased ? :buy : :sell
        @shop[:quantity] = nil
        draw_shop
      end

      # How far UP / DOWN jump the quantity cursor — ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine: its shop counter
      # moves in tens on the vertical axis, so a stack of 99
      # is a few presses away rather than ninety-nine.
      SHOP_QUANTITY_STEP = 10

      # Picking an item opens the quantity counter rather than transacting one
      # unit: RPG2000 asks how many, bounded by what the party can afford, the
      # 99-item cap, or (selling) what it holds. An item with no room at all —
      # unaffordable, already capped — never opens the counter.
      def open_shop_quantity(id)
        model = @shop[:model]
        max = @shop[:screen] == :buy ? model.max_buy(id) : model.max_sell(id)
        return false if max < 1
        @shop[:quantity] = { id: id, count: 1, max: max, mode: @shop[:screen] }
        @shop[:screen] = :quantity
        draw_shop
        true
      end

      # Drive the quantity counter: RIGHT / LEFT by one, UP / DOWN by ten (both
      # clamped to 1..max), C commits the whole stack in one transaction and B
      # goes back to the list having bought nothing.
      def drive_shop_quantity
        q = @shop[:quantity]
        if shop_quantity_move(q)
          draw_shop
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          model = @shop[:model]
          mode = q[:mode]
          mode == :buy ? model.buy(q[:id], q[:count]) : model.sell(q[:id], q[:count])
          # @shop[:quantity] survives into :purchased/:sold -- the status
          # panel there still needs its item id (see #shop_status_item_id) --
          # and is only cleared once #drive_shop_confirm leaves the screen.
          @shop[:screen] = mode == :buy ? :purchased : :sold
          @shop[:confirm_timer] = 60
          draw_shop
          play_system_se(SFX_DECISION)
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_shop_quantity
        end
      end

      # Apply one frame of quantity input; returns whether the count changed.
      # Every direction auto-repeats while held, not just a single fresh
      # press -- ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine:
      # all four branches gate on repeat-while-held, the same
      # semantics every other in-game list cursor uses (see e.g.
      # Scene::Battle's own `Input.trigger?(...) || Input.repeat?(...)`
      # cursor idiom), not a bare single fresh press.
      def shop_quantity_move(q)
        before = q[:count]
        if Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          q[:count] += 1
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          q[:count] -= 1
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          q[:count] += SHOP_QUANTITY_STEP
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          q[:count] -= SHOP_QUANTITY_STEP
        else
          return false
        end
        q[:count] = Game.clamp(q[:count], 1, q[:max])
        q[:count] != before
      end

      # Leave the counter for the list it was opened from, refreshing the gold
      # and (after a sale) the shrunk list.
      def close_shop_quantity
        @shop[:screen] = @shop[:quantity][:mode]
        @shop[:quantity] = nil
        draw_shop
      end

      # Move the shop cursor with Up / Down; returns true if it moved. Plays
      # Cursor SE on every successful move, the same base selectable-list-
      # cursor behaviour every other RPG2000 list window gets (see the
      # field-menu SFX audit elsewhere in this file/docs/TODO.md) -- shared
      # by the command list and the buy/sell list alike. Both directions
      # also auto-repeat
      # while held, not just a fresh press -- ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine: the command list and the buy/sell item lists both gate
      # their Up/Down entirely on repeat-while-held --
      # every RPG2000 list cursor in this ported model auto-repeats.
      def shop_move_cursor(lines)
        if (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && !lines.empty?
          @shop[:index] += 1
          @shop[:index] %= lines.length
          draw_shop
          play_system_se(SFX_CURSOR)
          true
        elsif (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && !lines.empty?
          @shop[:index] -= 1
          @shop[:index] %= lines.length
          draw_shop
          play_system_se(SFX_CURSOR)
          true
        else
          false
        end
      end

      def shop_switch(screen)
        # Once the player has gone into Buy or Sell at all this visit, the
        # shopkeeper's line on returning to the command menu switches from a
        # first-time greeting to "anything else?" for the rest of it.
        @shop[:browsed] = true if screen == :buy || screen == :sell
        # The command menu's own cursor position persists across a trip into
        # Buy/Sell and back, rather than always snapping to the first row --
        # ported from a reference implementation, not independently
        # confirmed against genuine RPG_RT under wine: the command list's
        # cursor is set to the Buy row exactly once, in its constructor;
        # nothing resets it again on returning from Buy/Sell. So cancelling
        # out of the Sell list, say,
        # returns to the command menu with Sell still highlighted, not Buy.
        # Saved/restored here rather than in a fresh field per screen, since
        # only the command menu has a cursor position worth remembering
        # across a screen change -- Buy/Sell/the quantity counter always
        # start a fresh browse at their own first row.
        @shop[:cmd_index] = @shop[:index] if @shop[:screen] == :command
        @shop[:screen] = screen
        @shop[:index] = screen == :command ? (@shop[:cmd_index] || 0) : 0
        # A fresh browse also starts scrolled to the top -- #draw_shop only
        # ever nudges @shop[:scroll] forward to follow the cursor, so without
        # this a screen re-entered after scrolling deep into a long list
        # (e.g. cancelling out of Buy back to the command menu, then back
        # into Buy) would still open scrolled down instead of showing goods
        # 1..SHOP_LIST_ROWS the way a fresh Buy/Sell always does.
        @shop[:scroll] = 0
        draw_shop
      end

      def leave_shop
        transacted = @shop[:model].did_transaction
        interp = @shop[:interp]
        close_shop
        interp.resume_shop(transacted)
      end

      def close_shop
        return unless @shop
        @shop[:window].dispose if @shop[:window]
        @shop[:gold].dispose if @shop[:gold]
        @shop[:status].dispose if @shop[:status]
        @shop[:party].dispose if @shop[:party]
        @shop[:desc].dispose if @shop[:desc]
        @shop[:prompt].dispose if @shop[:prompt]
        @shop = nil
      end

      # -- Enemy Encounter (turn-based battle) --------------------------------
      #
      # The fight itself -- command menu, round animation, battle-event pages,
      # the result screen -- is Scene::Battle now (mruby-rpg2k/mrblib/scene/
      # battle.rb); this scene only owns the single slot it runs in and the
      # frame-by-frame dance of handing control to it.
      #
      # Drive the turn-based battle screen the map shows during a :battle wait.
      # `it` is whichever interpreter actually raised the wait -- the
      # foreground event by default, or a Parallel Process's own interpreter
      # when #drive_parallel_wait dispatches here (see there and
      # #step_battle_owner_parallel, which keeps calling back in on every
      # later frame since a battle a Parallel Process opened stops the
      # ordinary #step_parallels pass from ever reaching it again). Only one
      # fight can be open at a time: if @battle already belongs to a
      # *different* interpreter (two Battle Processing commands landing the
      # same real frame, one from each of two independent interpreters), this
      # one simply waits its turn and tries again next frame, the same
      # block-and-retry shape already used for :message/:choice/:number above.
      def drive_battle(it = @interpreter)
        req = it.battle_request
        return it.resume_battle(:victory) unless req
        if @battle.nil?
          @battle = RPG2k::Scene.battle_scene_class(db).new(self, req, it)
          @battle.start # opened this frame; take input from the next one
          return
        end
        return unless @battle.owner.equal?(it)
        @battle.update
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle failed: #{e.message}"
        owner = @battle ? @battle.owner : it
        close_battle
        owner.resume_battle(:victory)
      end

      # Tear the running fight down (dispose its windows/sprites) and drop
      # this scene's own reference to it. The counterpart to Scene::Battle
      # being created inline in #drive_battle above -- called from there (a
      # battle that failed mid-update), from Scene::Battle#finish_battle
      # itself (a battle that resolved normally), and from #dispose (scene
      # teardown while a fight happens to be open).
      def close_battle
        return unless @battle
        @battle.dispose
        @battle = nil
      end

      # --rpg2k_battle boot drive (RPG2k#headless_battle_troop, the flag in
      # src/main.cxx): arm a fight against `troop_id` on this scene's own
      # foreground interpreter right after New Game, so the map's next frame
      # drives it through the ordinary :battle wait exactly as a random
      # encounter would (#drive_battle). Marked `headless: true` so the fight
      # logs the [RPG2k-BATTLE] marker the boot check asserts on (see
      # Scene::Battle#start) -- it is the same request shape as a wandering
      # encounter otherwise. Only meant to be called while the interpreter is
      # otherwise idle (the instant after New Game); a failing arm (a troop id
      # the database no longer has, which #start_random_battle itself already
      # reports) logs and leaves the party on the map rather than crashing.
      def headless_battle(troop_id)
        @interpreter.start_random_battle(troop_id, headless: true)
      end
      public :headless_battle

      # The map tree's map_properties table, or nil when this build has no tree
      # (the scene harnesses construct a map directly).
      def map_properties
        return nil unless respond_to?(:map_tree) && map_tree
        map_tree.respond_to?(:map_properties) ? map_tree.map_properties : nil
      rescue StandardError
        nil
      end

      # Re-derive the menu's Save access, and the Escape / Teleport field
      # skill types' access, from the current map's tree settings (see
      # Game::MapAccess). Runs on the initial map load and every Teleport,
      # same as RPG_RT: a Control Save/Teleport/Escape Access event command
      # can still override any of them for the rest of that map's visit, but
      # the next map load recomputes all three from the tree again.
      def apply_map_access
        props = map_properties
        @state.save_access = Game::MapAccess.save_allowed?(@state.map_id, props)
        @state.teleport_access = Game::MapAccess.teleport_allowed?(@state.map_id, props)
        @state.escape_access = Game::MapAccess.escape_allowed?(@state.map_id, props)
      end

      # Auto-play the current map's own configured BGM (Game::MapBgm), on the
      # initial map load and every Transfer Player -- ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: playing the map's BGM runs right after
      # every map setup -- a map with nothing configured, or explicitly set
      # to "none" (type 1), leaves whatever is already playing alone, and
      # #play_bgm's own same-file check keeps a Transfer Player back onto the
      # same map (or between maps sharing a track) from restarting it.
      # Skipped while boarded: the vehicle's own BGM (#play_vehicle_bgm) owns
      # the audio then, and #restore_pre_vehicle_bgm resumes whatever this
      # would have played once the party disembarks.
      #
      # `fadein` (cycle #218): the map-tree node's `bgm` chunk is the same
      # liblcf `BGM` struct (mruby-lcf/mrblib/schema.rb) as battle_music/
      # inn_music/boat_music/ship_music/airship_music, whose own field 2
      # `fade_in` cycle #203 already threaded through #battle_bgm/
      # #restore_pre_inn_bgm's source/#vehicle_bgm into #play_bgm's 5th
      # `RGSS::Audio.bgm_play` argument -- this call site (#music_fadein
      # already exists for exactly this) was the one #203 missed, so a map's
      # own Autoplay BGM fade-in (set on the map-tree node in the editor) was
      # silently dropped and every map entry/Transfer Player restarted the
      # track at full volume instantly instead.
      #
      # `balance` (cycle #219): the same gap, one field over -- the map-tree
      # node's `bgm` chunk carries field 5 (`balance`) too, and #music_balance
      # already exists for exactly this (added alongside #music_fadein in
      # #203) but this call site never called it either, so a map's own
      # Autoplay BGM pan was silently dropped the same way its fade-in was.
      def play_map_bgm
        return if @state.boarded?
        bgm = Game::MapBgm.chunk_for(@state.map_id, map_properties)
        return unless bgm
        name = music_name(bgm)
        return if name.nil? || name.empty?
        play_bgm(name: name, volume: music_volume(bgm), tempo: music_tempo(bgm),
                 fadein: music_fadein(bgm), balance: music_balance(bgm))
      rescue StandardError => e
        $stderr.puts "[RPG2k] map BGM failed: #{e.message}"
      end

      # Continue's counterpart to #play_map_bgm, called instead of it when
      # #initialize's apply_access: is false. Ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine: map entry
      # branches on whether it's a fresh map entry or a resumed save -- a
      # fresh entry replays the map-tree walk (the map-tree walk
      # #play_map_bgm already ports), but resuming a save
      # instead stops and restarts whatever BGM the save itself
      # remembers -- the save's own remembered
      # track, not whatever the destination map's tree says, and always
      # restarted from the top (an explicit stop before the replay) even if
      # it happens to name the same file. @state.current_bgm already holds
      # that exact value here -- Game::State.load/.from_lsd populate it
      # straight from the save before this scene is ever constructed -- so
      # this calls the native backend directly instead of going through
      # #play_bgm, whose same-file check would otherwise compare
      # @state.current_bgm to itself and skip the call outright, leaving
      # nothing audible after a fresh process start.
      def resume_saved_bgm
        bgm = @state.current_bgm
        return if bgm.nil? || bgm[:name].nil? || bgm[:name].empty?
        RGSS::Audio.bgm_play(bgm[:name], bgm[:volume] || 100, bgm[:tempo] || 100)
        @state.bgm_looped = false
      rescue StandardError => e
        $stderr.puts "[RPG2k] saved BGM resume failed: #{e.message}"
      end

      # The backdrop named by the terrain of the tile at (x, y) — the database
      # terrain row's `background_name` (field 4). '' when the tile, the terrain
      # table or the field is missing.
      def terrain_backdrop(x, y)
        backdrop_for_terrain_id(terrain_id(x, y))
      end

      # The backdrop named by terrain id `tid` directly, bypassing tile lookup
      # entirely -- Enemy Encounter's own explicit-terrain override (param2==2,
      # `Interpreter#do_enemy_encounter`'s `terrain_id:` request field) reads a
      # terrain the party may not even be standing on, ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine, which
      # resolves the
      # terrain table directly with no map-tree/tile involvement at all --
      # unlike the ordinary (param2==0) path, which walks the map tree first
      # and only reads a tile's terrain as one fallback among several (see
      # `Game::Backdrop.name_for`). '' when the id, the terrain table or the
      # field is missing.
      def backdrop_for_terrain_id(tid)
        return '' unless tid && tid > 0 && db.respond_to?(:terrain)
        row = db.terrain[tid]
        return '' unless row && row.respond_to?(:background_name)
        row.background_name.to_s
      rescue StandardError => e
        $stderr.puts "[RPG2k] terrain backdrop lookup failed: #{e.message}"
        ''
      end

      # Show or hide the whole map view -- both tile layers, the parallax, the
      # hero, the events and the vehicles, all of which live inside
      # @map_viewport (z 100) or @upper_viewport (z 200).
      #
      # RPG2000's battle screen is a scene of its own in RPG_RT: `Scene_Battle`
      # replaces `Scene_Map` outright, so no part of the map is on screen while
      # a fight runs, and the chosen Backdrop/<name> image is all there is
      # behind the troop. This port instead runs the fight inline on Scene::Map
      # (gated on @battle), and #render kept compositing the map every frame
      # underneath it -- which put the map *over* the battle background, since
      # the backdrop sprite's z 5 (ported from a reference implementation,
      # not independently confirmed against genuine RPG_RT under wine --
      # correct there precisely because no map is ever drawn
      # beside it) is outranked by both map viewports, and the lower tile layer
      # is opaque. The backdrop was resolved correctly (`Game::Backdrop`, the
      # map-tree walk) and then drawn entirely behind the map graphics: every
      # fight was fought over whatever chip layer the party happened to be
      # standing on.
      #
      # Hidden for the fight's whole duration, and #render skips the tile /
      # parallax / character compositing outright rather than leaving a stale
      # frame hidden underneath -- the same treatment the picture layer already
      # gets there. Both un-hide and redraw on the first frame after @battle
      # clears; the hero frame's own @last_frame cache is untouched by the
      # skipped frames, so an unchanged pose is not needlessly rebuilt then.
      def set_map_layers_visible(visible)
        @map_viewport.visible = visible if @map_viewport
        @upper_viewport.visible = visible if @upper_viewport
        # Coming back from a battle hide: the composed buffers still hold the
        # pre-fight pixels -- correct if nothing moved while they were off
        # screen, but the fight may have moved anything, so the first draw
        # after the show recomposes rather than trusting the stale frame.
        @layers_dirty = true if visible && @layers_visible == false
        @layers_visible = visible
      end

      # Game over: the party was wiped in an encounter that ends the game on
      # defeat, or the event command itself named the target directly — either
      # way, RPG2000 shows the Game Over graphic first: Game Over (12420) and a
      # battle defeat the encounter marked "game over" both route here to show
      # the Game Over screen, which returns to the title once dismissed.
      # Nothing resumes, so the event is stopped rather than released.
      #
      # `interp` is whichever interpreter actually raised the :game_over wait --
      # the foreground event by default, or a Parallel Process's own interpreter
      # when #drive_parallel_wait dispatches here (see there). Stopping the
      # right one matters less than it looks: replacing the whole scene stack
      # below orphans every interpreter in this scene regardless, but stopping
      # it too keeps its own state consistent for the rest of this frame, the
      # same as the foreground's already did.
      def perform_game_over(interp = @interpreter)
        $stderr.puts '[RPG2k] game over'
        interp.stop
        @parent.show_game_over(@state)
      rescue StandardError => e
        $stderr.puts "[RPG2k] Game over failed: #{e.message}"
        interp.stop
      end

      # -- Enter Hero Name (name-entry widget) --------------------------------
      #
      # RPG2000's own command only ever has two legitimate values for its
      # "initial character type" parameter: hiragana (0) and katakana (1).
      # There is no genuine "Latin alphabet" charset -- confirmed against
      # genuine RPG_RT.exe under wine (cycle #149): a synthetic autostart
      # Enter Hero Name spliced onto a copy of Nepheshel's map 12 opened the
      # kana grid instantly for charset 0 and 1, but charset 2 -- and charset
      # 3, tested identically -- each threw a genuine
      # `EXCEPTION_ACCESS_VIOLATION` inside RPG_RT.exe itself (`WINEDEBUG=+seh`
      # captured `code=c0000005` at a small, near-null faulting address,
      # `info[1]` around `0xfd`, consistent with indexing a two-entry internal
      # table with an out-of-range value and dereferencing whatever came back)
      # -- caught by the game's own SEH handler chain (the same handler
      # addresses for both 2 and 3) rather than surfacing any visible crash
      # dialog, leaving the process alive but permanently stuck: no widget
      # ever appears, the screen never repaints again (a black client area,
      # confirmed by pixel scan, for 35+ real seconds), and the process goes
      # idle rather than busy-looping (`ps` showed falling %CPU and `S`
      # sleeping state throughout, unlike the `R` running state charset 0/1
      # show while actually drawing). So a genuine RPG2000 game's own editor
      # never legitimately produces anything but 0 or 1 here, and "for
      # English-patched games, the Latin alphabet (2)" (this comment's own
      # prior claim) was never a real RPG_RT feature to begin with -- nothing
      # genuine exists to reproduce for any other value. This build still
      # treats charset 2 specially and opens a flat Latin/digit grid for it
      # anyway (any other out-of-range value falls back to the ordinary
      # hiragana kana grid instead, see #drive_name_input below) purely as
      # this codebase's own usability extension for entering non-Japanese
      # text -- not a reproduction of any genuine RPG_RT.exe behavior, since
      # genuine RPG_RT.exe has none to reproduce here. The hiragana/katakana
      # pages share one gojuuon grid with a face portrait and a name-so-far
      # field above it (#draw_kana_name_input and friends); the letters page
      # keeps the flat Latin/digit grid this widget always had
      # (#draw_name_input and friends) -- RPG_RT never lets the two mix, so
      # neither does this build.

      # -- Letters page (charset 2, this build's own extension -- see above) --

      # The selectable cells: the character set, then two control cells — BS
      # (backspace) and OK (confirm).
      NAME_CHARS = (('A'..'Z').to_a + ('a'..'z').to_a + ('0'..'9').to_a +
                    [' ', '-', "'", '.']).freeze
      NAME_CELLS = (NAME_CHARS + %w[BS OK]).freeze
      NAME_COLS = 13          # cells per row
      NAME_MAX = 12           # longest name the widget accepts
      NAME_CELL_W = 14
      NAME_CELL_H = 14

      # -- Kana pages (charset 0 hiragana / 1 katakana) --------------------

      # RPG2000's fixed gojuuon layout: eight full rows of the plain kana
      # beside their voiced (゛) / semi-voiced (゜) column, small kana and the
      # long-vowel mark, then a symbol row, and a final row of six kana plus
      # the page-toggle and confirm cells (each drawn two columns wide, so the
      # last row fills the same 10 columns as the rows above it).
      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: that ported keyboard
      # table -- the ま/マ row's small kana column order is っゃゅょゎ, not
      # ゃゅょっー (small-tsu had drifted three columns right, and the last
      # column was a stray duplicate of the ー already on the row below,
      # rather than small-wa ゎ/ヮ); the last row's "vu" cell is katakana
      # ヴ on *both* the hiragana and katakana pages in the reference table
      # (hiragana has no glyph of its own there), not hiragana ゔ on the
      # hiragana page; and the や/ヤ row's final cell is the white star ☆
      # (U+2606), not the black star ★ (U+2605).
      NAME_KANA_LAST_HIRAGANA = (%w[ら り る れ ろ ヴ] + %i[toggle confirm]).freeze
      NAME_KANA_LAST_KATAKANA = (%w[ラ リ ル レ ロ ヴ] + %i[toggle confirm]).freeze
      NAME_HIRAGANA_ROWS = [
        %w[あ い う え お が ぎ ぐ げ ご],
        %w[か き く け こ ざ じ ず ぜ ぞ],
        %w[さ し す せ そ だ ぢ づ で ど],
        %w[た ち つ て と ば び ぶ べ ぼ],
        %w[な に ぬ ね の ぱ ぴ ぷ ぺ ぽ],
        %w[は ひ ふ へ ほ ぁ ぃ ぅ ぇ ぉ],
        %w[ま み む め も っ ゃ ゅ ょ ゎ],
        %w[や ゆ よ わ ん ー 〜 ・ ＝ ☆],
        NAME_KANA_LAST_HIRAGANA
      ].freeze
      NAME_KATAKANA_ROWS = [
        %w[ア イ ウ エ オ ガ ギ グ ゲ ゴ],
        %w[カ キ ク ケ コ ザ ジ ズ ゼ ゾ],
        %w[サ シ ス セ ソ ダ ヂ ヅ デ ド],
        %w[タ チ ツ テ ト バ ビ ブ ベ ボ],
        %w[ナ ニ ヌ ネ ノ パ ピ プ ペ ポ],
        %w[ハ ヒ フ ヘ ホ ァ ィ ゥ ェ ォ],
        %w[マ ミ ム メ モ ッ ャ ュ ョ ヮ],
        %w[ヤ ユ ヨ ワ ン ー 〜 ・ ＝ ☆],
        NAME_KANA_LAST_KATAKANA
      ].freeze
      NAME_KANA_COLS = 10
      NAME_KANA_CELL_W = 28
      NAME_KANA_CELL_H = 16
      NAME_KANA_MAX = 6 # RPG2000's default name length, one kana per slot

      # Layout, measured in screen pixels: a face box and a name-so-far box
      # share a top row, a gojuuon grid fills the rest of the screen below
      # them, and the whole group is centred with the same left/right edges
      # top and bottom (296px wide: 10 * NAME_KANA_CELL_W + Window::BORDER*2).
      NAME_TOP_X = 12
      NAME_TOP_Y = 8
      NAME_TOP_GAP = 8
      NAME_FACE_WIN = 64 # FACE_SIZE (48) + Window::BORDER (8) * 2
      NAME_GRID_W = 296  # NAME_KANA_COLS * NAME_KANA_CELL_W (280) + 16
      NAME_GRID_H = 160  # 9 rows * NAME_KANA_CELL_H (144) + 16
      NAME_GRID_Y = 80   # NAME_TOP_Y + NAME_FACE_WIN + NAME_TOP_GAP

      # Drive the name-entry screen shown during a :name_input wait. Charset 2
      # opens this build's own flat letters grid (see the doc comment above --
      # genuine RPG_RT.exe has no working charset 2 to match, it access-
      # violates instead); charsets 0, 1, and anything else open the kana grid,
      # on the katakana page for exactly charset 1 and hiragana otherwise.
      # Either way the widget is seeded with the actor's current name when the
      # command asked for it, and commits to the actor and resumes the event
      # when confirmed.
      #
      # `it` defaults to the foreground @interpreter, but #drive_parallel_wait
      # passes its own parallel interpreter here too -- see its :name_input
      # case for why, mirroring #open_message's own `interp:` idiom
      # (@message[:interp]) for the same "which interpreter actually asked
      # for this shared, singleton widget" tracking. `@name_ui[:interp]` is
      # what #commit_name_input resumes once the actor's name is confirmed.
      def drive_name_input(it = @interpreter)
        req = it.name_input_request
        return it.resume_name_input('') unless req
        if @name_ui.nil?
          background = build_field_background(@windowskin)
          if req[:charset] == 2
            @name_ui = { name: req[:seed] || '', sel: 0, win: nil, kana: false,
                         actor_id: req[:actor_id], background: background, interp: it }
            draw_name_input
          else
            @name_ui = { name: req[:seed] || '', sel: 0, kana: true,
                         page: req[:charset] == 1 ? :katakana : :hiragana,
                         actor_id: req[:actor_id], background: background, interp: it }
            draw_kana_name_input
          end
          return
        end
        @name_ui[:kana] ? handle_kana_name_input : handle_name_input
      end

      # Cell count in `row` (0-indexed): a full NAME_COLS for every row except
      # the last, which is however many cells are left over.
      def name_row_len(row)
        [NAME_COLS, NAME_CELLS.length - row * NAME_COLS].min
      end

      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine:
      # every cursor move plays Cursor SE, and Decision plays
      # unconditionally the instant C is pressed, before dispatching on
      # which cell is highlighted -- the same for OK/DONE, a page toggle or
      # an ordinary character. Cancel is a genuinely separate branch from
      # Decision in that model, not this codebase's on-screen "BS" cell
      # (which that keyboard grid has no equivalent of): it
      # erases one character with its own Cancel SE, or Buzzer with nothing
      # to erase -- see #name_input_cancel.
      # Every direction auto-repeats while held, not just a fresh press --
      # ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: all four grid directions gate
      # on repeat-while-held, which fires both on the very first pressed
      # frame and on the later repeat cadence -- exactly the union this
      # codebase's own split `Input.trigger?` (fresh press only) /
      # `Input.repeat?` (delayed auto-repeat, never frame 1) idiom already
      # covers everywhere else.
      def handle_name_input
        ui = @name_ui
        row = ui[:sel] / NAME_COLS
        col = ui[:sel] % NAME_COLS
        rows = (NAME_CELLS.length + NAME_COLS - 1) / NAME_COLS
        if Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          ui[:sel] = row * NAME_COLS + (col + 1) % name_row_len(row)
          draw_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          ui[:sel] = row * NAME_COLS + (col - 1) % name_row_len(row)
          draw_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          new_row = (row + 1) % rows
          ui[:sel] = new_row * NAME_COLS + col % name_row_len(new_row)
          draw_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          new_row = (row - 1) % rows
          ui[:sel] = new_row * NAME_COLS + col % name_row_len(new_row)
          draw_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          name_input_confirm
        elsif Input.trigger?(Input::B)
          name_input_cancel
        end
      end

      # Act on the highlighted cell: OK commits, BS backspaces (no SE of its
      # own -- the Decision that dispatched here, #handle_name_input, already
      # played one), any other cell types its character (up to NAME_MAX) or,
      # once full, rejects it with Buzzer -- ported from a reference
      # implementation, not independently
      # confirmed against genuine RPG_RT under wine, which plays Buzzer and
      # drops the appended text the instant it would overflow the field.
      def name_input_confirm
        cell = NAME_CELLS[@name_ui[:sel]]
        case cell
        when 'OK' then commit_name_input
        when 'BS' then backspace_name_input
        else
          if @name_ui[:name].length < NAME_MAX
            @name_ui[:name] += cell
          else
            play_system_se(SFX_BUZZER)
          end
          draw_name_input
        end
      end

      # The physical Cancel key (not the on-screen "BS" cell, see
      # #handle_name_input's own doc comment): erase one character with its
      # own Cancel SE, or Buzzer when the name is already empty.
      #
      # Confirmed directly (cycle #125, 2026-08-23) against a genuine
      # RPG_RT.exe under wine -- this whole widget was originally ported
      # from a reference implementation before this project's own methodology
      # started requiring that (see docs/TODO.md's own account of cycle
      # #114). A synthetic autostart Enter Hero Name (10740, actor 1,
      # charset 0/hiragana) map event on a copy of Nepheshel's map 12,
      # resumed from a genuine save positioned there: on a name reading "リ"
      # (one kana typed), a single Cancel press erased exactly that one
      # character down to empty, matching this method's own branch exactly;
      # a further Cancel press on the now-empty field left the field and the
      # whole screen visibly unchanged (buzzer-only, confirmed by the
      # unchanged screenshot, not just inferred from silence).
      def name_input_cancel
        if @name_ui[:name].empty?
          play_system_se(SFX_BUZZER)
        else
          play_system_se(SFX_CANCEL)
          backspace_name_input
        end
      end

      def backspace_name_input
        @name_ui[:name] = @name_ui[:name].chop
        @name_ui[:kana] ? draw_kana_name_input : draw_name_input
      end

      # A blank confirm does not close the widget: it resets the field back
      # to the actor's current name and leaves the screen open, rather than
      # resuming the event with an empty string. This check lives in the
      # single shared handler (gated only on which cell was picked), so it
      # applies identically to every keyboard page -- the kana grid's own
      # :confirm cell routes through this same method. Originally ported
      # from a reference implementation (mislabeled "RPG_RT's own live source"
      # at the time this was written, before this project's own methodology
      # required checking such claims against the genuine binary -- see
      # docs/TODO.md's cycle #114 account).
      #
      # Independently re-verified since (cycle #125, 2026-08-23) directly
      # against a genuine RPG_RT.exe under wine: a synthetic autostart Enter
      # Hero Name (10740, actor 1 "リト", charset 0/hiragana) map event on a
      # copy of Nepheshel's map 12, resumed from a genuine save positioned
      # there. Navigated the cursor straight to the grid's own 決定
      # (Confirm) cell with no character typed (a single Up wraps from the
      # top-left cell to the confirm row, then Right x7 reaches Confirm --
      # both screenshotted to confirm the cursor landed where expected) and
      # pressed Decision: the screen stayed open and the name field filled
      # with the actor's real name ("リト"), matching this method's blank
      # branch exactly -- it did not resume the event or leave the screen.
      def commit_name_input
        ui = @name_ui
        if ui[:name].empty?
          actor = roster_actor(ui[:actor_id])
          ui[:name] = actor ? actor.name.to_s : ''
          ui[:kana] ? draw_kana_name_input : draw_name_input
          return
        end
        name = ui[:name]
        interp = ui[:interp]
        close_name_input
        interp.resume_name_input(name)
      end

      def draw_name_input
        ui = @name_ui
        ui[:win].dispose if ui[:win]
        rows = (NAME_CELLS.length + NAME_COLS - 1) / NAME_COLS
        inner_w = NAME_COLS * NAME_CELL_W
        inner_h = (rows + 1) * NAME_CELL_H # +1 row for the name-so-far
        win = Window.new((SCREEN_W - inner_w - Window::BORDER * 2) / 2, 30,
                         inner_w + Window::BORDER * 2, inner_h + Window::BORDER * 2)
        win.z = 400
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, NAME_CELL_H, "Name: #{ui[:name]}"
        NAME_CELLS.each_with_index do |cell, i|
          cx = (i % NAME_COLS) * NAME_CELL_W
          cy = NAME_CELL_H + (i / NAME_COLS) * NAME_CELL_H
          label = cell == 'BS' ? '<' : cell
          c.draw_text cx, cy, NAME_CELL_W, NAME_CELL_H, label
        end
        win.contents = c
        sel = ui[:sel]
        win.cursor_rect = Rect.new((sel % NAME_COLS) * NAME_CELL_W,
                                   NAME_CELL_H + (sel / NAME_COLS) * NAME_CELL_H,
                                   NAME_CELL_W, NAME_CELL_H)
        ui[:win] = win
      end

      # -- Kana grid driving --------------------------------------------

      def name_kana_rows(page)
        page == :katakana ? NAME_KATAKANA_ROWS : NAME_HIRAGANA_ROWS
      end

      # Auto-repeats while held, exactly like #handle_name_input above --
      # ported from the same reference implementation, not independently
      # confirmed against genuine RPG_RT under wine: one grid widget backs
      # both the ASCII and kana pages there.
      def handle_kana_name_input
        ui = @name_ui
        rows = name_kana_rows(ui[:page])
        row = ui[:sel] / NAME_KANA_COLS
        col = ui[:sel] % NAME_KANA_COLS
        if Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          ui[:sel] = row * NAME_KANA_COLS + (col + 1) % rows[row].length
          draw_kana_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          ui[:sel] = row * NAME_KANA_COLS + (col - 1) % rows[row].length
          draw_kana_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          new_row = (row + 1) % rows.length
          ui[:sel] = new_row * NAME_KANA_COLS + col % rows[new_row].length
          draw_kana_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          new_row = (row - 1) % rows.length
          ui[:sel] = new_row * NAME_KANA_COLS + col % rows[new_row].length
          draw_kana_name_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          kana_name_input_confirm
        elsif Input.trigger?(Input::B)
          name_input_cancel
        end
      end

      # Act on the highlighted cell: :confirm commits, :toggle swaps the
      # hiragana/katakana page, any kana cell types its character (up to
      # NAME_KANA_MAX) or, once full, rejects it with Buzzer -- see
      # #name_input_confirm's identical doc comment, which this mirrors (the
      # kana grid has no on-screen backspace cell of its own, only the
      # physical Cancel key, #name_input_cancel).
      def kana_name_input_confirm
        ui = @name_ui
        rows = name_kana_rows(ui[:page])
        cell = rows[ui[:sel] / NAME_KANA_COLS][ui[:sel] % NAME_KANA_COLS]
        case cell
        when :confirm then commit_name_input
        when :toggle
          ui[:page] = ui[:page] == :hiragana ? :katakana : :hiragana
          draw_kana_name_input
        else
          if ui[:name].length < NAME_KANA_MAX
            ui[:name] += cell
          else
            play_system_se(SFX_BUZZER)
          end
          draw_kana_name_input
        end
      end

      # The label drawn for `cell`: a kana glyph as-is, or the toggle/confirm
      # cell's own text. The toggle names the page it switches *to* — "カナ"
      # (katakana) on the hiragana page, "かな" (hiragana) on the katakana one
      # — matching RPG_RT's own screen.
      def kana_cell_label(cell, page)
        case cell
        when :toggle then page == :hiragana ? 'カナ' : 'かな'
        when :confirm then '決定'
        else cell
        end
      end

      # Pixel geometry of `rows[row][col]` within the grid's content bitmap.
      # Every cell is one column wide except :toggle/:confirm, which are two —
      # the reason this walks the row summing widths rather than a flat
      # `col * NAME_KANA_CELL_W`.
      def kana_cell_rect(rows, row, col)
        x = 0
        rows[row][0...col].each { |c| x += (c.is_a?(Symbol) ? 2 : 1) * NAME_KANA_CELL_W }
        w = (rows[row][col].is_a?(Symbol) ? 2 : 1) * NAME_KANA_CELL_W
        [x, row * NAME_KANA_CELL_H, w, NAME_KANA_CELL_H]
      end

      # (Re)draw all three windows of the kana widget: the actor's face, the
      # name-so-far field (seeded characters, a blinking cursor box on the
      # next empty slot, underscores past that) and the gojuuon grid itself.
      def draw_kana_name_input
        ui = @name_ui
        if ui[:face_win]
          ui[:face_win].dispose
          ui[:name_win].dispose
          ui[:grid_win].dispose
        end

        actor = roster_actor(ui[:actor_id])
        face_name = actor && actor.respond_to?(:face_name) ? actor.face_name : nil
        face_index = actor && actor.respond_to?(:face_index) ? (actor.face_index || 0) : 0

        draw_kana_face(ui, face_name, face_index)
        draw_kana_name_field(ui)
        draw_kana_grid(ui)
      end

      def draw_kana_face(ui, face_name, face_index)
        win = Window.new(NAME_TOP_X, NAME_TOP_Y, NAME_FACE_WIN, NAME_FACE_WIN)
        win.z = 400
        win.windowskin = @windowskin
        c = Bitmap.new(FACE_SIZE, FACE_SIZE)
        face = load_face_bitmap(face_name)
        if face
          src = Rect.new((face_index % 4) * FACE_SIZE, (face_index / 4) * FACE_SIZE,
                         FACE_SIZE, FACE_SIZE)
          c.blt 0, 0, face, src
        end
        win.contents = c
        ui[:face_win] = win
      end

      def draw_kana_name_field(ui)
        win_x = NAME_TOP_X + NAME_FACE_WIN + NAME_TOP_GAP
        win_w = NAME_TOP_X + NAME_GRID_W - win_x
        win = Window.new(win_x, NAME_TOP_Y, win_w, NAME_FACE_WIN)
        win.z = 400
        win.windowskin = @windowskin
        inner_w = win_w - Window::BORDER * 2
        inner_h = NAME_FACE_WIN - Window::BORDER * 2
        slot_y = (inner_h - NAME_KANA_CELL_H) / 2
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        name = ui[:name]
        NAME_KANA_MAX.times do |i|
          c.draw_text i * NAME_KANA_CELL_W, slot_y, NAME_KANA_CELL_W, NAME_KANA_CELL_H,
                     name[i] || '_', 1
        end
        win.contents = c
        if name.length < NAME_KANA_MAX
          win.cursor_rect = Rect.new(name.length * NAME_KANA_CELL_W, slot_y,
                                     NAME_KANA_CELL_W, NAME_KANA_CELL_H)
        end
        ui[:name_win] = win
      end

      def draw_kana_grid(ui)
        win = Window.new(NAME_TOP_X, NAME_GRID_Y, NAME_GRID_W, NAME_GRID_H)
        win.z = 400
        win.windowskin = @windowskin
        inner_w = NAME_GRID_W - Window::BORDER * 2
        inner_h = NAME_GRID_H - Window::BORDER * 2
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        rows = name_kana_rows(ui[:page])
        rows.each_with_index do |row_cells, r|
          row_cells.each_with_index do |cell, ci|
            x, y, w, h = kana_cell_rect(rows, r, ci)
            c.draw_text x, y, w, h, kana_cell_label(cell, ui[:page]), 1
          end
        end
        win.contents = c
        sel_row = ui[:sel] / NAME_KANA_COLS
        sel_col = ui[:sel] % NAME_KANA_COLS
        win.cursor_rect = Rect.new(*kana_cell_rect(rows, sel_row, sel_col))
        ui[:grid_win] = win
      end

      def close_name_input
        return unless @name_ui
        @name_ui[:background].dispose if @name_ui[:background]
        if @name_ui[:kana]
          @name_ui[:face_win].dispose if @name_ui[:face_win]
          @name_ui[:name_win].dispose if @name_ui[:name_win]
          @name_ui[:grid_win].dispose if @name_ui[:grid_win]
        else
          @name_ui[:win].dispose if @name_ui[:win]
        end
        @name_ui = nil
      end

      # Display frames each animation frame is held; the fallback length (frames)
      # when the database has no data for the requested animation; and the flash
      # duration a timing fires.
      #
      # ANIM_CELL_FRAMES is 2, not some other guess. Ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine: its animation driver keeps an internal
      # frame counter that ticks once per logical 60fps update, holding
      # every real (LCF) animation frame for exactly two
      # ticks before the displayed cell advances, independent of whether that
      # frame's own cell list is empty (a "Wait" frame) or not; there is no
      # separate doubling rule for blank frames specifically. 2 ticks at 60fps is
      # 1/30s per frame, matching the "1 frame = 1/30s" fact this codebase already
      # otherwise assumed correctly.
      ANIM_CELL_FRAMES = 2
      # ANIM_FLASH_FRAMES is 11, not some other guess. Ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: it keeps a
      # fired timing's own colour/power alive for a delta of ticks since the
      # timing started, from 0 up to and including 10,
      # before falling back to all-zero --
      # the same raw once-per-update tick counter
      # `ANIM_CELL_FRAMES`'s own derivation above already relies on, so this is
      # 11 raw ticks (0..10 inclusive), not 8. Previously an unverified guess,
      # left untouched by the `ANIM_CELL_FRAMES` fix's own comment ("independent
      # constants").
      ANIM_FLASH_FRAMES = 11
      # A frame's `screen_shaking` timing (LCF field 8: 0 none / 1 target / 2
      # screen) fires a fixed (power, speed, frames) triple regardless of the
      # timing's own data -- ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine:
      # both the screen-shake and target-shake cases share this exact
      # (3, 5, 32) triple, called out there as
      # "not proven accurate" but the only real-RPG_RT numbers documented
      # anywhere. `frames` is already in real (60fps) frames, not tenths of a
      # second -- derived there as "16 animation frames (32 real
      # frames)" -- so it needs no `FRAMES_PER_TENTH` conversion, unlike the
      # Shake Screen event command's own param2 (#do_shake_screen).
      ANIM_SHAKE_POWER = 3
      ANIM_SHAKE_SPEED = 5
      ANIM_SHAKE_FRAMES = 32
      # RPG2000 battle-animation cells: a 96x96 grid, 5 cells across the sheet.
      ANIM_CELL = 96
      ANIM_SHEET_COLS = 5

      # The sprite height #animation_position_offset's Head/Feet split uses
      # for a *map*-drawn target (the player, a map event, a vehicle) --
      # ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine: a
      # hardcoded 24px constant local to that one
      # function, unrelated to `Game::CharSet::HEIGHT` (32, the actual
      # CharSet frame's pixel height) despite reading like it should be the
      # same thing. Previously used `Game::CharSet::HEIGHT` directly, which
      # split Head/Feet by 16px each way instead of this ported model's 12px.
      ANIM_MAP_TARGET_HEIGHT = 24

      # Drive a Show Battle Animation (11210) wait for interpreter `it` -- the
      # foreground event, or a parallel process that issued one of its own (both
      # share this one on-screen animation slot, matching yado.tk: only one
      # battle animation is ever on screen at a time): play the animation over
      # its target, then resume `it`. When the animation's data / sheet is
      # available it advances frame by frame (composited by #draw_map_animation),
      # firing the screen flashes its timings request; otherwise it degrades to a
      # plain timed wait, so a cutscene paces the same as RPG_RT either way.
      #
      # yado.tk: only one battle animation is ever on screen, and a *second*
      # one forcibly cuts the first off rather than queueing behind it --
      # ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: it
      # does an
      # unconditional replace with no check for whether the
      # previous one had finished. If the slot is currently held by a
      # *different* interpreter's animation, that request is torn down here
      # (rather than left to finish naturally) and `it`'s own takes over
      # immediately, same frame. The interpreter that just lost the slot has
      # nothing left on screen to keep waiting on, so it resumes right away --
      # the reference implementation's own interpreter actually arms an
      # independent, precomputed
      # frame-count wait at request time rather than
      # tying resumption to the shared animation object's lifecycle at all, so
      # a cut-off request there keeps counting down its own original duration
      # instead of resuming the instant it is cut off; reproducing that exact
      # timing would need this build to precompute and track each request's
      # duration independently too, which is a larger change than the
      # observable "does the first get cut off" fact this fixes.
      def drive_map_animation(it)
        init_map_animation_this_frame(it)
        @map_animation ? step_map_animation : step_animation_wait
      end

      # Claim the shared animation slot for `it` and build its animation (or
      # arm the timed fallback) if it does not already hold it -- the "only
      # one at a time, a second forcibly cuts off the first" precedence rule
      # (#drive_map_animation's own comment), factored out so a freshly-armed
      # :animation wait can be built the instant it is armed, before its own
      # first per-frame #step_map_animation/#step_animation_wait advance is
      # due (see #drive_event's `else` branch, which calls this directly
      # rather than the full #drive_map_animation -- see its own comment for
      # why only the *build* moves up, not that first advance). A no-op when
      # `it` already owns the slot (mid-play, or already claimed this same
      # frame).
      def init_map_animation_this_frame(it)
        return if @map_animation_interp.equal?(it)
        if @map_animation || @anim_wait
          cut_off = @map_animation_interp
          @map_animation = nil
          @anim_wait = nil
          cut_off.resume if cut_off
        end
        @map_animation_interp = it
        init_map_animation(it)
      end

      # Advance a fire-and-forget Show Battle Animation (#apply_battle_animation_
      # request) once per real frame. A waited-for play (map or battle-round
      # alike) always has *something* re-visiting it every frame on its own --
      # #drive_map_animation for the map :animation wait, #drive_battle_animate's
      # own explicit #step_map_animation call for a battle round -- but a
      # fire-and-forget one has no interpreter parked on it at all, so without
      # this it would show its first frame once and then freeze there forever
      # instead of playing through. Gated on @map_animation_interp being nil (no
      # owner) so an owned map play is left to #drive_map_animation untouched,
      # and on `!@map_animation[:battle]` so a battle-round play -- which also
      # leaves @map_animation_interp nil, since #start_battle_animation never
      # sets an owner either -- is left entirely to #drive_battle_animate's own
      # call instead of being stepped twice a frame.
      def step_ownerless_map_animation
        return unless @map_animation_interp.nil?
        if @map_animation
          step_map_animation unless @map_animation[:battle]
        elsif @anim_wait
          step_animation_wait
        end
      end

      # Begin the animation: build the frame-by-frame player from `it`'s
      # request, or arm the timed-wait fallback when there is no drawable
      # animation.
      def init_map_animation(it)
        begin_map_animation(it.battle_animation)
      end

      # Shared by #init_map_animation (a waited-for play, owned by `it`) and
      # #apply_battle_animation_request (a fire-and-forget one, no owner):
      # build the frame-by-frame player from a raw `battle_animation` request
      # hash, or arm the timed-wait fallback when there is no drawable
      # animation.
      #
      # An unresolved map target (see #animation_target_resolves?) waits
      # exactly 0, not #missing_animation_wait's animation-duration fallback
      # -- ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine: it resolves the
      # target character unconditionally, before it ever looks at
      # the animation id or computes a frame count, and returns outright when that
      # resolution fails -- the wait is simply never armed, so a
      # "wait until finished" request on an unresolved target falls straight
      # through to the next command the same tick rather than stalling for
      # the animation's own real duration (or the invalid-animation-id
      # fallback's timing either). A battle-page request (`req[:battle]`)
      # gets the identical treatment for an out-of-range Ally/Enemy index --
      # see `Scene::Battle#battle_page_target_resolves?`'s own doc comment
      # for the matching battle-side null-target check.
      def begin_map_animation(req)
        unresolved =
          req && (req[:battle] ? @battle && !@battle.battle_page_target_resolves?(req)
                                : !animation_target_resolves?(req[:target]))
        if unresolved
          @map_animation = nil
          @anim_wait = 0
          return
        end
        @map_animation = start_map_animation(req)
        if @map_animation
          fire_animation_flashes(@map_animation) # frame 0 flashes
        else
          @anim_wait = missing_animation_wait(req[:animation])
        end
      end

      # Whether Show Battle Animation's map target id names something real to
      # draw over -- ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine:
      # target resolution returns nothing both for "This Event" (0) when the
      # calling interpreter has no
      # owning map event (a common/parallel event)
      # and for a specific event id the map has no character for; either way
      # the whole command no-ops, including a
      # "Whole screen" one, since that check runs before the animation
      # scope is even
      # read. The player and every vehicle slot always resolve --
      # they are constructed unconditionally,
      # never failing to resolve.
      def animation_target_resolves?(target)
        case target
        when MOVE_TARGET_PLAYER, MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          true
        when 0, MOVE_TARGET_THIS
          !@active_event.nil?
        else
          @events.any? { |e| e[:id] == target }
        end
      end

      # The wait a Show Battle Animation command with nothing drawable still
      # applies -- ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine: there is no fixed
      # fallback duration anywhere in the reference implementation (the
      # `ANIM_FALLBACK_FRAMES` constant this replaced was an unverified
      # guess, never checked against source the way `ANIM_CELL_FRAMES` and
      # `ANIM_FLASH_FRAMES` already were). An invalid animation id, or a
      # database row with no frames at all, waits exactly 0 --
      # a zero wait falls straight through to
      # the next command the same tick, no one-frame floor. A row with real
      # frame data but an unloadable `Battle/<name>` sheet still waits the
      # row's own real duration (`frames.size * ANIM_CELL_FRAMES`) --
      # the reference implementation computes the frame count from the
      # database row before it
      # even attempts the graphic load, so a missing file changes nothing
      # about the timing, only what (nothing) actually draws.
      def missing_animation_wait(id)
        anim = animation_row(id)
        return 0 unless anim
        table_entries(anim.frames).size * ANIM_CELL_FRAMES
      end

      # Advance the drawable animation one frame per ANIM_CELL_FRAMES, firing that
      # frame's flashes; finish (hide, resume) once the last frame has played.
      def step_map_animation
        ma = @map_animation
        if ma[:timer] > 0
          ma[:timer] -= 1
          hold_animation_screen_flash(ma)
          hold_animation_target_flash(ma)
          return
        end
        ma[:frame_i] += 1
        if ma[:frame_i] >= ma[:frames].length
          @animation_sprite.visible = false
          # The sheet is not disposed here: it is a shared @animation_cache
          # entry (see #animation_sheet) that a later replay of this
          # animation reuses, not something this one play owns.
          @map_animation = nil
          owner = @map_animation_interp
          @map_animation_interp = nil
          # A battle-round animation (#start_battle_animation) is driven by the
          # round rather than by an event command, so it never sets
          # @map_animation_interp in the first place -- owner is nil there by
          # construction, not because ma[:battle] itself means "no owner": a
          # battle-*page*'s own Show Battle Animation (13260,
          # #start_battle_page_animation) also carries ma[:battle] true, for
          # its screen-space pixel and enemy-sprite flash target, but very
          # much does have one (the battle-event interpreter waiting on it),
          # so this reads the actual owner rather than special-casing the flag.
          owner.resume if owner
          return
        end
        fire_animation_flashes(ma)
        ma[:timer] = ANIM_CELL_FRAMES
        hold_animation_screen_flash(ma)
        hold_animation_target_flash(ma)
      end

      # yado.tk: Screen Flash / Character Flash are both capped to 1/30s of
      # display while a Battle Animation is playing, because the animation
      # continuously re-asserts its own per-frame flash state for its whole
      # duration -- ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine: the
      # animation driver reasserts the screen flash on *every* real frame
      # the animation is on screen,
      # not just frames with their own flash_scope-2 timing, always
      # ending in an unconditional flash call --
      # with r/g/b/p taken from the most recently fired timing's own
      # decaying value, or all
      # zero when none has fired yet this play. Either way, any *other*
      # in-flight screen flash -- one an unrelated Flash Screen command set
      # ticking before or during this animation -- gets silently overwritten
      # the very next real frame, regardless of its own configured duration.
      # `#fire_animation_flashes`'s own `@state.screen.flash` call (fired only
      # on a frame carrying a flash_scope-2 timing) already reproduces the
      # timing's own decaying flash correctly; what was missing is this
      # continuous per-*real*-frame reassertion for every frame in between --
      # `#step_map_animation` only ever touched the screen flash on the
      # throttled animation-frame ticks that actually carry a timing, so an
      # unrelated flash concurrent with an otherwise-silent stretch of the
      # animation (including its opening frames, before any timing has fired
      # at all) played out its own full duration untouched. `ma[:screen_flash_hold]`
      # tracks how many more real frames the *animation's own* most recent
      # flash_scope-2 fire still owns the screen flash for (set to
      # ANIM_FLASH_FRAMES by #fire_animation_flashes, ticking down here); once
      # it reaches zero the animation forcibly zeroes the screen flash again
      # every real frame, capping any concurrent, unrelated flash to at most
      # the one frame between two calls here.
      def hold_animation_screen_flash(ma)
        hold = ma[:screen_flash_hold]
        if hold && hold > 0
          ma[:screen_flash_hold] = hold - 1
        else
          @state.screen.flash(0, 0, 0, 0, 0)
        end
      end

      # yado.tk's own "Character Flash" half of the same claim, capped the same
      # way and for the same reason -- ported from a reference implementation
      # right alongside #hold_animation_screen_flash's, not independently
      # confirmed against genuine RPG_RT under wine:
      # the animation driver calls its target-flash update unconditionally on
      # *every* real frame, right next to its screen-flash update, and that
      # always ends in an unconditional flash-targets call -- both
      # map/battle-round shapes (the two shapes this
      # codebase's own #fire_map_target_flash/#fire_target_flash mirror) are
      # unconditional the exact same way, with
      # r/g/b/p either the most recently fired flash_scope-1 timing's own
      # decaying value or all zero. So an unrelated Character Flash already
      # running on this animation's own target -- a Flash Sprite (11320)
      # command mid-decay on the player/a map event, or an enemy's own
      # in-flight flash from an earlier battle-round hit -- gets silently
      # overwritten the very next real frame too, regardless of its own
      # configured duration, for as long as the animation is on screen.
      # `ma[:target_flash_hold]` mirrors `ma[:screen_flash_hold]` exactly (set
      # to ANIM_FLASH_FRAMES by #fire_animation_flashes whenever a flash_scope-1
      # timing actually fires, ticking down here); once it lapses, the
      # animation's own target is forcibly cleared again every real frame,
      # capping any concurrent, unrelated flash on that same target to at most
      # the one frame between two calls here. Scoped to just the animation's
      # own target (#clear_target_flash / #clear_map_target_flash), unlike the
      # screen-flash half -- a Character Flash on a *different* character is
      # untouched, matching `FlashTargets`' own target-list scope.
      def hold_animation_target_flash(ma)
        hold = ma[:target_flash_hold]
        if hold && hold > 0
          ma[:target_flash_hold] = hold - 1
        else
          (ma[:targets] || []).each do |tgt|
            if ma[:battle]
              @battle.clear_target_flash(tgt[:index]) if tgt[:index]
            else
              clear_map_target_flash(tgt[:flash_target])
            end
          end
        end
      end

      # The map-triggered half: drop @state.player_flash / an @events entry's
      # own [:flash] back to nil, the same "no flash in flight" state #tick_flash's
      # own decay already leaves behind, mirroring #fire_map_target_flash's own
      # arm call. A vehicle target clears the native RGSS flash
      # #fire_map_target_flash armed on `@vehicle_sprites[type]` directly,
      # mirroring #clear_target_flash's own `spr.flash(nil, 0)` idiom for an
      # enemy sprite. A nil target (an id no live event matches -- see
      # #map_animation_flash_target) is a no-op, since there is nothing to
      # clear.
      def clear_map_target_flash(target)
        return if target.nil?
        if Game::Vehicle::TYPES.include?(target)
          spr = @vehicle_sprites && @vehicle_sprites[target]
          spr.flash(nil, 0) if spr
        elsif target == :player
          @last_frame = nil if @state.player_flash
          @state.player_flash = nil
        else
          target[:flash] = nil
        end
      end

      def step_animation_wait
        if @anim_wait <= 0
          @anim_wait = nil
          owner = @map_animation_interp
          @map_animation_interp = nil
          owner.resume if owner
        else
          @anim_wait -= 1
        end
      end

      # Build the animation player from a raw `battle_animation` request hash
      # (`{ animation:, target:, ... }`), or nil when there is no request, the
      # animation is unknown, or its Battle/<name> sheet is missing (then the
      # timed-wait fallback runs).
      #
      # A request's own `battle` flag (set only by #do_show_battle_animation_b,
      # the battle-*page* form of this command, 13260) picks which target
      # scheme `req[:target]` names: a map target id (the player/"this
      # event"/a map event/a vehicle) for the ordinary map-triggered form
      # (11210), or a troop *member index* for the battle-page one -- the two
      # are not interchangeable, so this dispatches to the matching builder
      # rather than always reading `req[:target]` the map way.
      def start_map_animation(req)
        return nil unless req
        return @battle.start_battle_page_animation(req) if req[:battle]
        return nil unless animation_target_resolves?(req[:target])
        flash_target = map_animation_flash_target(req[:target])
        targets =
          if req[:global]
            global_animation_targets(flash_target)
          else
            tx, ty = animation_target_pixel(req[:target])
            # Every map target -- the player, a map event, a vehicle -- gets
            # the same fixed height for #animation_position_offset's
            # Head/Feet split (see ANIM_MAP_TARGET_HEIGHT's own comment for
            # why this is 24, not the CharSet frame's actual 32px), so the
            # sprite bounding box is known without asking what kind of
            # character this actually is.
            [anim_target(tx, ty, height: ANIM_MAP_TARGET_HEIGHT, index: nil, flash_target: flash_target)]
          end
        build_animation(req[:animation], targets, false)
      end

      # The 3x3 grid of map-pixel target descriptors a **whole-screen** Show
      # Battle Animation (11210 param3, the editor's "Whole screen" target
      # option) tiles itself across, ported from a reference implementation,
      # not independently confirmed against genuine RPG_RT under wine:
      # it draws the animation nine times, offset by
      # a full screen width/height in each direction -- since a single
      # animation
      # cell is smaller than the screen, this is what makes it cover the
      # whole visible area regardless of where the camera happens to sit,
      # rather than appearing only once at a single point on it.
      #
      # Built directly in this scene's own map-pixel/camera-offset space
      # (`#camera_position`, the same one every other draw here already
      # subtracts) rather than screen space, so the ordinary per-target `tx -
      # cam_x + TILE / 2` conversion in #render_map_animation places each
      # tile at exactly `i * SCREEN_W + SCREEN_W / 2` on screen with no
      # special-casing there. `height: nil` -- like the ally-side "middle of
      # the screen" fallback -- since a full-screen tile has no sprite
      # bounding box for #animation_position_offset to split; the reference
      # implementation's whole-screen draw path never goes through the
      # single-target position/character-
      # height logic at all. Every tile shares the same `flash_target`
      # (the original single character
      # always flashes, whole-screen or not) so a flash_scope-1 timing
      # still pulses the right character; the shake-targets path is already a
      # confirmed-empty no-op for this map form regardless.
      def global_animation_targets(flash_target)
        cam_x, cam_y = camera_position
        (-1..1).flat_map do |gy|
          (-1..1).map do |gx|
            tx = cam_x - TILE / 2 + gx * SCREEN_W + SCREEN_W / 2
            ty = cam_y - TILE / 2 + gy * SCREEN_H + SCREEN_H / 2
            anim_target(tx, ty, height: nil, index: nil, flash_target: flash_target)
          end
        end
      end

      # The character a map-triggered flash_scope-1 timing (see
      # #fire_map_target_flash) should pulse: `:player`, a specific `@events`
      # entry (this event / a named map event id), or a `Game::Vehicle::TYPES`
      # symbol (`:boat`/`:ship`/`:airship`) for a vehicle slot. Only ever
      # called once #animation_target_resolves?(target) has already passed
      # (see #start_map_animation), so the "this event, no active event" and
      # "unknown event id" cases it decodes have both already been ruled
      # out -- this ~~falls back to `:player`~~ no longer needs a fallback
      # for either.
      def map_animation_flash_target(target)
        case target
        when MOVE_TARGET_PLAYER then :player
        when 0, MOVE_TARGET_THIS
          @active_event || :player
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT]
        else
          @events.find { |e| e[:id] == target }
        end
      end

      # One target descriptor for #build_animation's `targets` array: `tx`/`ty`
      # the centre pixel the animation is drawn over, `height` the target
      # sprite's own pixel height (for #animation_position_offset -- nil when
      # there is no real sprite to measure, e.g. the ally-side screen-centre
      # fallback), `index` the enemy-sprite index to flash/shake in a fight
      # (nil for an ally / map target, which has no battle-sprite to pulse),
      # and `flash_target` the map-character (player/event/vehicle) a
      # flash_scope-1 timing pulses on the map path.
      def anim_target(tx, ty, height:, index:, flash_target:)
        { tx: tx, ty: ty, height: height, index: index, flash_target: flash_target }
      end

      # The animation player itself, shared by the map's Show Battle Animation
      # command and by a battle round. `battle` says the pixel is already a
      # screen position rather than a map one, and that nothing is waiting on the
      # animation to finish. `targets` is an array of #anim_target descriptors
      # -- usually one (the animation plays over a single character), but a
      # whole-side battle animation (target < 0, ported from a reference
      # implementation, not
      # independently confirmed against genuine RPG_RT under wine) passes every
      # living ally or enemy at once, and the player draws each one in turn.
      # nil when the animation is unknown or its Battle/<name> sheet is missing.
      def build_animation(id, targets, battle = false, position: nil)
        anim = animation_row(id)
        return nil unless anim
        frames = table_entries(anim.frames)
        return nil if frames.empty?
        sheet = animation_sheet(anim.animation_name)
        return nil unless sheet
        { frames: frames, timings: table_entries(anim.timings), sheet: sheet,
          position: (position || anim.position || 1), frame_i: 0,
          timer: ANIM_CELL_FRAMES, battle: battle, targets: targets }
      end

      # The single choke point every battle-animation lookup goes through: a
      # Show Battle Animation command and a skill/item's own animation
      # (#start_battle_animation, #start_map_animation,
      # #start_battle_page_animation, all via #build_animation) all land here.
      # A database shrink can leave one of those naming a deleted battle_anime
      # id -- the "battle animation" case in docs/TODO.md's runtime error
      # catalog -- and until now that just drew nothing with no trace.
      # `respond_to?`/nil-guarded the same way `terrain_row_at`/`db_item` are,
      # so a bare test fixture with no battle_anime table at all stays silent;
      # only a genuine dangling id in a real database is reported.
      def animation_row(id)
        return nil if id.nil? || !@db.respond_to?(:battle_anime) || @db.battle_anime.nil?
        row = @db.battle_anime[id]
        if row.nil? && id.is_a?(Integer) && id > 0
          $stderr.puts "[RPG2k] battle animation ##{id} not found in " \
                       'database, nothing drawn'
        end
        row
      rescue StandardError
        nil
      end

      # Cached by name (see #cached_bitmap): a battle round or a Show Battle
      # Animation command can replay the same animation many times over a
      # visit, and previously this reloaded and redecoded the sheet from disk
      # on every single play.
      #
      # Loaded **colour-keyed** (`Bitmap.new`'s second argument, which maps
      # palette index 0 to transparent -- `mruby-rgss/src/lib.cxx`'s
      # `load_xyz_mem`/`load_png_tolerant_mem` `trans` flag), like every other
      # RPG2000 sprite sheet this runtime loads. `Battle/` was the one sheet
      # directory that asked for an opaque decode, and it is the one directory
      # where that is never right: an animation sheet is a 5-column grid of
      # 96x96 cells whose *entire* background is the transparent colour, so
      # every cell #blit_animation_cell laid down painted an opaque 96x96
      # rectangle of that background over the target -- a solid block sitting
      # on the enemy for the animation's whole duration, not a spell. Ported
      # from a reference implementation, not independently confirmed
      # against genuine RPG_RT under
      # wine: its material table marks transparent loading true for `Battle` (and
      # for CharSet / ChipSet / FaceSet / Monster / Picture / System, matching
      # every other loader here) and false only for the four full-screen
      # backdrops -- `Backdrop`, `Panorama`, `Title`, `GameOver` -- which this
      # runtime already loads opaque.
      def animation_sheet(name)
        return nil if name.nil? || name.empty?
        cached_bitmap(@animation_cache, name) do
          begin
            Bitmap.new "Battle/#{name}", true
          rescue StandardError => e
            $stderr.puts "[RPG2k] battle animation '#{name}' load failed: #{e.message}"
            nil
          end
        end
      end

      # The target character's map-pixel position: the player, the running event
      # ("this event" / 0), a vehicle slot, or a map event by id. Only ever
      # called once #animation_target_resolves?(target) has already passed
      # (see #start_map_animation), so its "this event, no active event" and
      # "unknown event id" ~~fall back to the player~~ branches are dead --
      # both cases are already ruled out by then. yado.tk: a vehicle target
      # reads that vehicle's real, currently-live x/y off `Game::State` (the
      # same source `#event_operand`'s Control Variables "character
      # position" vehicle fix reads) even when the vehicle is not on the map
      # this scene has loaded -- RPG_RT does not check that the two agree
      # before placing the animation, the same blind-read quirk as the
      # Control Variables fix.
      def animation_target_pixel(target)
        case target
        when MOVE_TARGET_PLAYER then player_pixel
        when 0, MOVE_TARGET_THIS
          @active_event ? event_pixel(@active_event) : player_pixel
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          vehicle_pixel(Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT])
        else
          ev = @events.find { |e| e[:id] == target }
          ev ? event_pixel(ev) : player_pixel
        end
      end

      # A vehicle's own map-pixel position, read straight off its live
      # `Game::Vehicle` record -- no interpolation, unlike a walking
      # player/event, since nothing here animates a standing vehicle's slide.
      def vehicle_pixel(type)
        v = @state.vehicle(type)
        return player_pixel unless v
        [v.x * TILE, v.y * TILE]
      end

      # Fire the current frame's timings request: flash_scope 2 (whole screen,
      # already implemented) or flash_scope 1 (the animation's own target --
      # #fire_target_flash in battle, #fire_map_target_flash on the map), plus
      # screen_shaking 2 (whole screen) / 1 (the animation's own target --
      # #fire_target_shake in battle only, see there for why the map path is a
      # genuine no-op rather than a gap), plus (below) the timing's own `se`,
      # played unconditionally in both battle and map context -- a sound has
      # no "screen vs target" split to gate on. RPG2000 stores the flash
      # colour / power as 0..31, scaled up to the 0..255 range every flash
      # path uses.
      def fire_animation_flashes(ma)
        ma[:timings].each do |t|
          next unless (t.frame || 0) == ma[:frame_i]
          case (t.flash_scope || 0)
          when 2
            @state.screen.flash((t.flash_red || 0) * 8, (t.flash_green || 0) * 8,
                                (t.flash_blue || 0) * 8, (t.flash_power || 0) * 8,
                                ANIM_FLASH_FRAMES)
            # #hold_animation_screen_flash keeps re-asserting this fire (and,
            # once it lapses, zeroing the screen flash outright) every real
            # frame for as long as the animation itself owns the slot.
            ma[:screen_flash_hold] = ANIM_FLASH_FRAMES
          when 1
            if ma[:battle]
              (ma[:targets] || []).each do |tgt|
                @battle.fire_target_flash(tgt[:index], t) if tgt[:index]
              end
            else
              (ma[:targets] || []).each do |tgt|
                fire_map_target_flash(tgt[:flash_target], t)
              end
            end
            # #hold_animation_target_flash keeps re-asserting this fire (and,
            # once it lapses, forcibly clearing the target's flash outright)
            # every real frame, the exact same shape as #ma[:screen_flash_hold]
            # just above.
            ma[:target_flash_hold] = ANIM_FLASH_FRAMES
          end
          case (t.screen_shaking || 0)
          when 2
            # The exact mechanism the Shake Screen event command (11050,
            # #do_shake_screen) already drives -- same Game::Screen#shake
            # call, same (power, speed, frames) argument order -- just with
            # a fixed triple ported from a reference implementation, not
            # independently confirmed against genuine RPG_RT under wine,
            # instead of a command's own
            # params.
            # A timed shake decays on its own via Game::Screen#update
            # (already driven every frame), so unlike the flash paths above
            # this needs no per-frame re-assertion hold.
            @state.screen.shake(ANIM_SHAKE_POWER, ANIM_SHAKE_SPEED, ANIM_SHAKE_FRAMES)
          when 1
            # The map-triggered Show Battle
            # Animation path's own shake-targets handling is a genuine empty
            # no-op in the reference implementation, not independently
            # confirmed against genuine RPG_RT
            # under wine, not a dropped feature -- so this only ever fires in
            # battle, matching #fire_target_shake's own battle-only scope.
            if ma[:battle]
              (ma[:targets] || []).each do |tgt|
                @battle.fire_target_shake(tgt[:index]) if tgt[:index]
              end
            end
          end
          # A timing's own `se` (the Timing struct's field 2, mruby-lcf/
          # mrblib/schema.rb) sits in this exact same per-frame struct as
          # flash_scope/screen_shaking just above, decoded the same way, but
          # was never read here at all -- the identical "decoded, never
          # wired up" shape those two fields each already needed fixing for
          # in this very method (see their own comments above). The only
          # place an animation's own sound ever played before this fix was
          # #play_animation_se (Scene::Base) -- a deliberately narrower,
          # single-shot summary (the *first* timing across the *whole*
          # animation with a real sound, played once before the animation
          # itself even starts, for the field item/skill menu's own success
          # cue -- see that method's own citation) -- not a substitute for a
          # genuine battle round or a Show Battle Animation (11210/13260)
          # command actually sounding each frame's own timing as that frame
          # arrives, exactly the way flash_scope/screen_shaking already do a
          # few lines up. NOT independently confirmed against genuine
          # RPG_RT under wine (no EasyRPG source consulted this cycle, per
          # this project's own standing rule against new citations there);
          # the blank/"(OFF)" no-op convention mirrors #play_animation_se's
          # own already-established handling of the identical field.
          se = t.respond_to?(:se) ? t.se : nil
          name = se && se.respond_to?(:file) ? se.file : nil
          next unless name && !name.empty? && name != '(OFF)'
          RGSS::Audio.se_play name, (se.volume || 100), (se.pitch || 100), (se.balance || 50)
        end
      end

      # The map-triggered counterpart to #fire_target_flash: a flash_scope-1
      # timing on a Show Battle Animation (11210) played over a map character
      # now actually pulses that character, instead of being silently dropped
      # (#fire_animation_flashes only ever reached #fire_target_flash's
      # battle-only enemy-sprite mechanism before this). A player/map-event
      # target reuses the Flash Sprite command's (11320) own CharSet-tone
      # mechanism, via the very same decaying
      # {red:, green:, blue:, power:, frames:, total:} hash #apply_sprite_flash
      # builds and #flash_tone/#update_sprite_flashes already drive every frame
      # (see the "Flash Sprite" section above): `target` (from
      # #map_animation_flash_target) is either `:player` (-> @state.player_flash) or
      # an `@events` entry (-> its `[:flash]`). A vehicle target (one of
      # `Game::Vehicle::TYPES`) instead pulses `@vehicle_sprites[type]`
      # directly with the native RGSS `Sprite#flash` primitive #fire_target_flash
      # already uses for an enemy sprite -- unlike the player/event case, a
      # vehicle already draws through a real `Sprite` (#draw_vehicles), so it
      # needs no CharSet-tint mechanism of its own. Ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine, rather than assumed unsupported:
      # vehicle characters resolve straight to the live vehicle
      # object -- itself a map-character subclass -- so the same
      # flash-targets call
      # reaches a vehicle exactly like it reaches the player or a map event;
      # nothing in this ported model exempts it. nil (an unresolved event id) is a
      # silent no-op either way, matching #fire_target_flash's own
      # missing-sprite case.
      def fire_map_target_flash(target, t)
        return if target.nil?
        if Game::Vehicle::TYPES.include?(target)
          spr = @vehicle_sprites && @vehicle_sprites[target]
          if spr
            spr.flash(Color.new((t.flash_red || 0) * 8, (t.flash_green || 0) * 8,
                                 (t.flash_blue || 0) * 8, (t.flash_power || 0) * 8),
                      ANIM_FLASH_FRAMES)
          end
          return
        end
        flash = { red: (t.flash_red || 0) * 8, green: (t.flash_green || 0) * 8,
                  blue: (t.flash_blue || 0) * 8, power: (t.flash_power || 0) * 8,
                  frames: ANIM_FLASH_FRAMES, total: ANIM_FLASH_FRAMES }
        if target == :player
          @state.player_flash = flash
          @last_frame = nil # force the hero's cached frame to be re-toned
        else
          target[:flash] = flash
        end
      end

      # Collect an Array2D (or a plain Hash test double) into a dense array of its
      # entries, in id order — both answer #each with (id, entry).
      def table_entries(table)
        out = []
        table.each { |_id, entry| out << entry } if table
        out
      end

      # Composite the animation's current frame over its target. Runs in the
      # render pass (the camera is known here): each visible cell of the frame is
      # blitted from the sheet's 96x96 grid to the target's screen position plus
      # the cell's offset, at that cell's own transparency
      # (#animation_cell_opacity) and zoom (#animation_cell_zoom) and tone
      # (#toned_animation_cell?).
      def draw_map_animation(cam_x, cam_y)
        return unless @animation_sprite
        ma = @map_animation
        unless ma
          @animation_sprite.visible = false
          return
        end
        @animation_sprite.visible = true
        @animation_sprite.x = 0
        @animation_sprite.y = 0
        @animation_bmp.clear
        frame = ma[:frames][ma[:frame_i]]
        return unless frame
        # A map animation is placed in map pixels and follows the camera; a
        # battle one is already where it belongs on screen. A whole-side
        # animation carries several target descriptors, so the frame is drawn
        # over each in turn.
        (ma[:targets] || []).each do |tgt|
          cx = ma[:battle] ? tgt[:tx] : tgt[:tx] - cam_x + TILE / 2
          cy = (ma[:battle] ? tgt[:ty] : tgt[:ty] - cam_y + TILE / 2) +
               animation_position_offset(tgt, ma[:position])
          table_entries(frame.cells).each do |cell|
            next if cell.respond_to?(:visible) && cell.visible == false
            blit_animation_cell(ma[:sheet], cell, cx, cy)
          end
        end
      end

      # The vertical pixel offset the battle_anime row's own `position` field (0
      # head / 1 center / 2 feet, LCF `battle_anime` chunk 19 field 10) adds on
      # top of the target's plain centre pixel -- previously decoded and stored
      # (`build_animation`'s `position:`) but never read, so every animation
      # drew centred regardless of what it asked for. Symmetric around the
      # existing centre pixel so position 1 -- the schema default, and every
      # animation that never sets the field -- draws exactly where it always
      # has; a target with no known height (the ally-side "middle of the
      # screen" fallback battle_animation_pixel returns, or a headless/
      # fixture animation nothing ever gave a height) is never offset, since
      # there is no sprite to split. The split point is the target's own real
      # sprite bounding box -- Game::CharSet's fixed 32px frame for a map
      # target, the battler bitmap's actual height in a fight -- rather than a
      # guessed fraction of it: the *direction* is confirmed by the schema's
      # own field comment (mruby-lcf/mrblib/schema.rb), but the exact split
      # RPG_RT itself draws at is still approximate pending a wine diff, the
      # same status the message window's own relocation zone boundary has
      # above.
      def animation_position_offset(tgt, position)
        h = tgt[:height]
        return 0 unless h
        case position
        when 0 then -(h / 2) # head: half the sprite's height above centre
        when 2 then h / 2    # feet: half the sprite's height below centre
        else 0
        end
      end

      # The blit opacity a cell's own `transparency` field asks for (LCF
      # `battle_anime` chunk 19's per-cell field 10, decoded in
      # mruby-lcf/mrblib/schema.rb; liblcf's `rpg::AnimationCellData::
      # transparency`, an `int32_t` defaulting to 0). It is a *percentage of
      # transparency*, 0 fully opaque .. 100 fully invisible, and it converts to
      # RGSS's 0..255 opacity the way a reference implementation does, not
      # independently confirmed against genuine RPG_RT under
      # wine: `opacity = 255 * (100 - cell.transparency) / 100` — integer
      # division, so 0 -> 255 and 100 -> 0, with the same truncation in between.
      #
      # Every drawable cell went down fully opaque before this: an animation
      # whose author faded a cell in or out (or layered a translucent glow over
      # a solid one) drew every one of its frames at full strength, which is a
      # visibly different animation, not a subtler one. The field is decoded off
      # the real database and was simply never read.
      #
      # A cell with no `transparency` at all — a bare test double, or an
      # Array2D entry the schema left defaulted — reads as 0 (opaque), the same
      # "absent means the schema default" shape #draw_map_animation's own
      # `visible` guard uses. Clamped both ways so a database carrying an
      # out-of-range value cannot ask for a negative or over-255 opacity.
      def animation_cell_opacity(cell)
        t = cell.respond_to?(:transparency) ? cell.transparency : nil
        t = 0 if t.nil?
        t = 0 if t < 0
        t = 100 if t > 100
        255 * (100 - t) / 100
      end

      # A cell's own `zoom` field (LCF `battle_anime` chunk 19's per-cell field
      # 5, mruby-lcf/mrblib/schema.rb; schema default 100 -- normal size), a
      # percentage the same way `#draw_picture`'s own `pic.zoom` already is:
      # 100 unscaled, below shrinks, above enlarges. Decoded off the real
      # database and never read before this -- every cell drew at its sheet's
      # native 96x96 no matter what its author dialled the zoom to. Clamped to
      # 0 at the bottom (a negative value would otherwise ask
      # `#animation_cell_dest_rect` for an inverted, off-by-its-own-width rect)
      # the same defensive shape `#animation_cell_opacity` already uses for
      # `transparency`; no ceiling, matching that a picture's own zoom has none
      # either.
      def animation_cell_zoom(cell)
        z = cell.respond_to?(:zoom) ? cell.zoom : nil
        z = 100 if z.nil?
        z = 0 if z < 0
        z
      end

      # The destination rect a zoomed cell blits into: `ANIM_CELL` scaled by
      # its own `#animation_cell_zoom`, centred on the same placement pixel
      # (`cx + cell.x, cy + cell.y`) the unzoomed path already centres on --
      # scaling around the cell's own centre, not its top-left corner, the
      # same "position/size by centre" convention `#draw_picture`'s own
      # zoom-vs-`pic.x`/`pic.y` centring already established for Show
      # Picture's identical zoom field. NOT independently confirmed against
      # genuine RPG_RT under wine.
      def animation_cell_dest_rect(cell, cx, cy)
        z = animation_cell_zoom(cell)
        w = ANIM_CELL * z / 100
        dx = cx + (cell.x || 0) - w / 2
        dy = cy + (cell.y || 0) - w / 2
        [dx, dy, w, w]
      end

      # A cell's own four tone fields (LCF `battle_anime` chunk 19's per-cell
      # fields 6-9: tone_red/green/blue/gray, mruby-lcf/mrblib/schema.rb),
      # each defaulting to 100 (neutral) -- exactly the same 0..200,
      # 100-is-neutral shape `Game::Picture`'s own red/green/blue/saturation
      # carry (confirmed by the matching `current_tone_red`/etc. save-field
      # defaults declared in the same schema file, chunk 103), so this reuses
      # `#toned?`'s reasoning: decoded off the real database and never read
      # before this -- every cell drew the sheet's raw, undialled colours no
      # matter what its author set the tone to. Defensive `respond_to?`/nil
      # guards match `#animation_cell_opacity`/`#animation_cell_zoom`'s own
      # shape for a bare test double.
      def animation_cell_tone(cell)
        [cell.respond_to?(:tone_red)   ? (cell.tone_red   || 100) : 100,
         cell.respond_to?(:tone_green) ? (cell.tone_green || 100) : 100,
         cell.respond_to?(:tone_blue)  ? (cell.tone_blue  || 100) : 100,
         cell.respond_to?(:tone_gray)  ? (cell.tone_gray  || 100) : 100]
      end

      # Whether a cell asks for any tint at all.
      def toned_animation_cell?(cell)
        animation_cell_tone(cell).any? { |v| v != 100 }
      end

      # The transient, reused-every-call scratch a cell's raw 96x96 square is
      # lifted into before toning -- `Bitmap#tone_blt` needs a same-size
      # destination that is not the source (see `#toned_picture_src`'s own
      # comment), and unlike a picture's source (one bitmap per shown
      # picture) every cell shares one 480x480/640x640 sheet, so there is no
      # single "whole source" to keep a toned copy of. Cropping the wanted
      # 96x96 square into this fixed-size buffer first, the same way
      # `#flashed_charset` lifts a CharSet frame before toning it, means the
      # cache below only ever needs to hold cell-sized (not sheet-sized)
      # toned copies.
      def animation_cell_crop_buffer
        @animation_cell_crop_buffer ||= Bitmap.new(ANIM_CELL, ANIM_CELL)
      end

      # The cell's raw sheet square with its tone baked in, cached per (sheet,
      # cell id, tone) so the software tone pass runs when a new tone/cell
      # combination is first drawn rather than every frame -- the same
      # caching shape `#toned_picture_src` uses for Show Picture, sized down
      # to one cell instead of a whole picture. Keyed by the sheet bitmap's
      # own `#object_id` rather than its name (there is no cell-level name to
      # key by, and unlike `@picture_cache`'s entries `ma[:sheet]` is already
      # held live for the animation's whole run once fetched -- see
      # `#draw_vehicle_frame`/`#draw_player_frame`'s own `charset.object_id`
      # frame-memo keys for the same identity-key precedent in this file); a
      # sheet reload after cache eviction simply keys fresh entries under the
      # new object, leaving the old ones to age out of the bound below same
      # as any other.
      def toned_animation_cell_src(sheet, cid, sx, sy, tr, tg, tb, ty)
        key = [sheet.object_id, cid, tr, tg, tb, ty]
        cached = @animation_tone_cache[key]
        return cached if cached
        buf = animation_cell_crop_buffer
        buf.clear
        buf.blt 0, 0, sheet, Rect.new(sx, sy, ANIM_CELL, ANIM_CELL)
        scratch = Bitmap.new(ANIM_CELL, ANIM_CELL)
        tone = Tone.new(Scene::Map.tone_channel(tr), Scene::Map.tone_channel(tg),
                        Scene::Map.tone_channel(tb),
                        # Mirrors `#toned_picture_src`'s own sign flip for
                        # Show Picture's `saturation` field: RPG2000's
                        # tone-gray/saturation channel runs the other way
                        # from RGSS's grey, so a channel under 100 becomes
                        # positive desaturation. Carried over unconfirmed --
                        # NOT independently verified against genuine RPG_RT
                        # under wine for this specific field.
                        Scene::Map.tone_channel(ty) * -1)
        scratch.tone_blt buf, tone
        # Bounded the same way #toned_picture_src bounds
        # @picture_tone_cache -- see its own comment.
        @animation_tone_cache.delete(@animation_tone_cache.keys.first) if
          @animation_tone_cache.size >= constrained_scale(ANIMATION_CELL_TONE_CACHE_MAX)
        @animation_tone_cache[key] = scratch
      rescue StandardError => e
        $stderr.puts "[RPG2k] animation cell ##{cid} tone failed, drawn untinted: #{e.message}"
        nil
      end

      # How many toned animation-cell variants to keep before evicting the
      # oldest -- see #PICTURE_TONE_CACHE_MAX's own comment for why this is
      # bounded at all.
      ANIMATION_CELL_TONE_CACHE_MAX = 16

      def blit_animation_cell(sheet, cell, cx, cy)
        opacity = animation_cell_opacity(cell)
        # A fully transparent cell contributes nothing; skipping it spares the
        # blit's own 96x96 per-pixel loop (Bitmap#blt would drop every pixel on
        # its `alpha <= 0` test anyway, one at a time).
        return if opacity <= 0
        cid = cell.cell_id || 0
        sx = (cid % ANIM_SHEET_COLS) * ANIM_CELL
        sy = (cid / ANIM_SHEET_COLS) * ANIM_CELL
        src_bmp = sheet
        src_rect = Rect.new(sx, sy, ANIM_CELL, ANIM_CELL)
        if toned_animation_cell?(cell)
          tr, tg, tb, ty = animation_cell_tone(cell)
          toned = toned_animation_cell_src(sheet, cid, sx, sy, tr, tg, tb, ty)
          if toned
            src_bmp = toned
            src_rect = Rect.new(0, 0, ANIM_CELL, ANIM_CELL)
          end
        end
        zoom = animation_cell_zoom(cell)
        if zoom == 100
          # The common case (a cell whose author never touched the zoom field,
          # or set it back to 100) keeps the plain, cheaper #blt path exactly
          # as before this fix -- no resample needed when the source and
          # destination are the same size.
          dx = cx + (cell.x || 0) - ANIM_CELL / 2
          dy = cy + (cell.y || 0) - ANIM_CELL / 2
          @animation_bmp.blt dx, dy, src_bmp, src_rect, opacity
        else
          dx, dy, w, h = animation_cell_dest_rect(cell, cx, cy)
          return if w <= 0 || h <= 0
          @animation_bmp.stretch_blt Rect.new(dx, dy, w, h), src_bmp, src_rect, opacity
        end
      rescue StandardError
        nil
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

      # RPG2003's "wait until the Decision key is pressed" mode of the Wait
      # command (Interpreter#do_wait's own `:wait_key_enter`) -- ported from
      # a reference implementation's own per-frame check, not
      # independently confirmed against genuine RPG_RT under wine.
      # A message window open (from any
      # interpreter -- #message_window_open? is scene-global, not per-
      # interpreter) blocks indefinitely without even consulting the key,
      # the same as the real engine's own `break` before the input check;
      # otherwise this resumes on the Decision key's rising edge, never a
      # key already held from before the command started.
      def drive_wait_key_enter
        return if message_window_open?
        @interpreter.resume if Input.trigger?(Input::C)
      end

      # Convert an RPG2000 wait duration (tenths of a second) to a frame count at
      # the current frame rate (defaulting to 60 fps).
      def frames_from_tenths(tenths)
        fr = Graphics.frame_rate
        fr = 60 if fr.nil? || fr <= 0
        tenths * fr / 10
      end

      # `keep_pictures` is false for an ordinary map transfer (the Transfer
      # Player / Recall to Location event commands, which arrive via the
      # interpreter's own `:teleport` wait) and true for the one documented
      # exception: a Teleport or Escape field skill/item, whose destination
      # arrives here via `@state.pending_teleport` instead (see #update).
      # yado.tk: changing maps clears every shown picture *except* via a
      # Teleport/Escape skill, a deliberate, distinct rule from an ordinary
      # map change.
      def perform_teleport(t, keep_pictures: false)
        map_id, x, y, dir = t
        begin
          @map = @parent.load_map(map_id)
        rescue StandardError => e
          # Transfer Player / Recall to Location naming a map id whose .lmu no
          # longer exists (a deleted map, or a stale id left behind by one) --
          # docs/TODO.md's runtime error catalog "invalid map": real RPG_RT
          # shows an error dialog naming the missing file rather than crashing.
          # This codebase has no error-dialog UI, so it reports the same detail
          # to $stderr, matching Call Event's own diagnostic-not-crash pattern,
          # and leaves the party on the map they were already on -- @map/@state
          # are still untouched at this point, so there is nothing to revert.
          $stderr.puts "[RPG2k] Teleport: destination map ##{map_id} failed to load: #{e.message}"
          @interpreter.stop
          return
        end
        @state.map = @map
        @state.map_id = map_id
        apply_map_access
        play_map_bgm
        @state.x = x
        @state.y = y
        @state.direction = dir if dir && dir > 0
        # Same marker `RPG2k#start_new_game`/`#continue_game` log on the initial
        # map load (`mruby-rpg2k/mrblib/main.rb`) — those only fire once, so a
        # session that walks through several Transfer Player/Teleport/Recall to
        # Location commands after that needs this to know which map and tile it
        # is actually looking at (see docs on debugging via this marker).
        # Existing `[RPG2k-MAP]`-scraping tooling (rpg2k_boot_check.bash,
        # compare-nepheshel-save-wine.bash) stays correct: one only checks the
        # marker's presence, and the other's `tail -1` never crosses a teleport
        # in the sequence it scripts.
        $stderr.puts "[RPG2k-MAP] map=#{@state.map_id} x=#{@state.x} y=#{@state.y}"
        # RPG2000 clears every shown picture when the map changes (RPG2003 is
        # the edition that added a per-picture "keep across map change" flag).
        # Without this, Nepheshel's opening leaves its full-screen credit
        # pictures on top of the first room and the map is never visible —
        # exactly what the wine comparison showed (ADR 0021). Not for a
        # Teleport/Escape skill's own warp, though — see `keep_pictures` above.
        @state.erase_all_pictures unless keep_pictures
        # A Change Parallax Background override does not survive a teleport
        # either; the destination map's own panorama applies. Rebuild the
        # backdrop from the new map so it isn't drawn with the old one.
        @state.clear_parallax
        dispose_parallax
        setup_parallax
        # ... nor does a Pan Screen offset / camera lock: the camera re-centres
        # on the hero on the new map. Nepheshel's opening pans a long way before
        # teleporting into the first room, and keeping that offset drew the room
        # from (304, 352) -- entirely outside a 320x240 map, i.e. a blank screen.
        @state.screen.pan_clear
        @locked_cam = nil
        # ... nor does a Change Encounter Rate override: the destination map's
        # own encount_steps applies again (yado.tk, corroborated with Chipset/
        # Panorama/Tile Replacement as one family of per-map runtime overrides
        # that reset on any map change, not just a save/load) -- #current_encounter_steps
        # falls back to the map's own rate whenever this is nil.
        @state.encounter_rate = nil
        @tileset_id = nil # a Change Map Tileset override does not survive a teleport
        @chipset = build_chipset
        # The new map may use a different chipset graphic, so reload it too;
        # otherwise the destination is drawn with the previous map's tiles.
        old_bmp = @chipset_bmp
        @chipset_bmp = load_chipset_graphic
        old_bmp.dispose if old_bmp && !old_bmp.equal?(@chipset_bmp)
        # ... nor does the timer's sticky "message was at top" flag: ported
        # from a reference implementation, not independently confirmed
        # against genuine RPG_RT under wine: it rebuilds its own message
        # window fresh on every genuine map
        # entry, matching a Teleport/Transfer Player, not
        # the reuse when merely returning from a pushed
        # menu/battle scene to the same map -- see #initialize's identical
        # reset for the very first visit.
        @message_window_top = false
        @started_auto = {}
        @started_common = {}
        @auto_once = {}
        @auto_once_common = {}
        @active_event = nil
        @player_route = nil # a forced player route does not survive a teleport
        # ... nor does a Set Move Route "Change Graphic" override on the hero
        # (see #player_draw_charset): RPG_RT reverts it on Transfer Player,
        # unlike the dedicated Change Hero Graphic command.
        @player_char = nil
        @player_through = false # ... nor does Through Mode
        @state.player_route = nil
        @state.player_through = false
        # Same for a vehicle's own forced route / Change Graphic override
        # (#force_vehicle_route, #vehicle_charset): none of it survives a
        # teleport, since the mirror was simulating movement against the map
        # being left, not whatever loads next.
        @vehicle_chars = {}
        @vehicle_routes = {}
        @vehicle_route_timers = {}
        @vehicle_orig_freq = {}
        @stuck_move_targets = [] # a stuck target was on the map being left
        # Both are per-visit: an Erase Event does not follow the party to the
        # next map, and the destination's pages are chosen fresh.
        @erased_events = {}
        @erased_event_positions = {}
        @event_last_position = {}
        # A saved wandered position is scoped to the map it was taken on --
        # event ids repeat per map, so carrying this forward would misapply a
        # stale entry to an unrelated event on the destination map. Dropped
        # here, before the destination's own events are built, so every one of
        # them falls back to its own page's default placement, matching an
        # ordinary map re-visit (see #record_map_event_positions). The same
        # applies to a saved custom-route cursor: dropped alongside so a
        # destination event beginning its own page's route starts at the top,
        # not part-way through wherever a same-numbered event on the map being
        # left happened to be. And (cycle #193) to a saved map-event Parallel
        # Process call-stack snapshot (#map_event_exec): dropped for the
        # identical reason -- without this, a destination map's own event
        # sharing the same numeric id as one still mid a Parallel Process on
        # the map being left could pick up that unrelated snapshot's captured
        # command list, running the wrong event's bytecode entirely rather
        # than merely mispositioning a sprite. This is exactly why a map
        # event's own Parallel Process still always restarts fresh across an
        # ordinary Transfer Player (see #build_parallels' own comment) even
        # though #new_parallel now knows how to resume one -- this reset is
        # what keeps that true.
        @state.map_event_positions = {}
        @state.map_event_route_index = {}
        @state.map_event_exec = {}
        # Tiles #warn_stale_terrain has already reported are per-visit too, same
        # reasoning as the tables above -- a stale reference on the map being
        # left says nothing about the destination.
        @warned_stale_terrain = {}
        @page_condition_ids = {}
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        # Any step in flight is dropped: the party arrives standing on the
        # destination tile rather than sliding toward one on the map it left.
        # A forced route can have a step in flight here -- it advances between
        # events, and an auto-start page can teleport on the very next frame.
        @moving = false
        @move_count = 0
        @slide_frac = 0
        @last_frame = nil
        # Resume, not stop: RPG_RT keeps running the rest of the event's own
        # command list after a Teleport lands, and the standard "fade to black,
        # teleport, fade back in" transition depends on it -- an Erase Screen
        # before the Teleport is paired with a Show Screen right after it, in
        # the SAME event, meant to run once the destination map is up. Stopping
        # here threw that trailing Show Screen away, so the erase overlay was
        # never lifted and the game stayed black from the first such teleport
        # on (this pattern opens Nepheshel's very first scene transition).
        @interpreter.resume
      rescue StandardError => e
        $stderr.puts "[RPG2k] Teleport failed: #{e.message}"
        @interpreter.stop
      end

      # Return to Title Screen: stop the running event and hand control back to
      # the app, which tears the play scenes down and shows a fresh title. There
      # is nothing to resume afterwards — this scene is being disposed. `it`
      # defaults to the foreground @interpreter but #drive_parallel_wait
      # passes its own parallel interpreter here too -- ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: Return to Title Screen has no
      # foreground-only gate, so a
      # Common Event's or a map event's own Parallel Process can trigger it
      # exactly like the foreground can.
      def perform_return_to_title(it = @interpreter)
        it.stop
        @parent.return_to_title
      rescue StandardError => e
        $stderr.puts "[RPG2k] Return to Title failed: #{e.message}"
        it.stop
      end

      # -- message / choice window --------------------------------------------

      # RPG2000's message window is a fixed 320x80 panel pinned to the left edge
      # — it does not shrink to the message, and it does not inset from the
      # screen. Measured off a genuine RPG_RT frame under wine (ADR 0021): the
      # bottom-positioned window occupies exactly (0, 160)-(319, 239).
      MSG_WIN_W = 320
      MSG_WIN_H = 80
      # One text row. Four rows fit in the 64px interior.
      MSG_LINE_H = 16
      # Lines the message window shows before it paginates (the 64px interior
      # holds exactly four 16px rows). RPG2000 keeps one window and shows the
      # next four lines -- a "▼" appears in the corner -- when a Show Text (or a
      # merged Show Choices) runs past this many lines.
      MSG_LINES_PER_PAGE = 4
      # Characters revealed per frame for the message typewriter effect.
      MSG_REVEAL_SPEED = 2
      # RPG_RT unrolls the message window (and its `\$` gold window) open and
      # shut over 7 frames rather than popping it, except during battle where
      # it appears/disappears instantly (ported from a reference
      # implementation, not independently confirmed against genuine
      # RPG_RT under wine).
      MSG_ANIM_FRAMES = 7
      # RPG2000 FaceSet geometry: a 4x4 grid of 48x48 face cells, drawn beside
      # the message text with a small gap.
      FACE_SIZE = 48
      FACE_MARGIN = 4

      # Look up an actor name by id for the \n[] message control code.
      #
      # The **live** actor is what RPG_RT names here, not the database row: a
      # hero the player named through Enter Hero Name (Nepheshel does exactly
      # that, then refers to them as \N[1] in 34 messages) or renamed by a Change
      # Actor Name has to be called what they are called now. Index **0** is the
      # party leader — the hero — which is how a boss addresses the player
      # character without knowing which actor id they are (`\n[0]よ…`).
      #
      # The roster is read without creating: naming an actor the game has never
      # met falls through to the database row instead of enrolling them in the
      # roster the save writes out.
      def actor_name(id)
        a = id.to_i.zero? ? party_leader : roster_actor(id)
        return a.name.to_s if a
        row = @db.player[id]
        row ? row.name.to_s : ''
      rescue StandardError => e
        $stderr.puts "[RPG2k] actor name ##{id} lookup failed: #{e.message}"
        ''
      end

      # The live actor `id`, if the game has one. nil for a scene fixture whose
      # party is a stub without a roster.
      def roster_actor(id)
        party = @state.party
        return nil unless party.respond_to?(:roster)
        party.roster.existing(id)
      end

      def party_leader
        party = @state.party
        party.respond_to?(:leader) ? party.leader : nil
      end

      # `interp:` is whichever interpreter's Show Text/Show Choices this window
      # answers to -- the foreground @interpreter by default, or a Parallel
      # Process's own interpreter when #drive_parallel_wait opens one (see
      # there). #drive_message/#drive_text_message read @message[:interp]
      # rather than @interpreter directly, so the window drives and resumes
      # the interpreter that actually asked for it either way; the "one
      # message window at a time" rule (yado.tk) that already made a second
      # same-frame call from @interpreter itself no-op below now equally holds
      # off a second, different interpreter's request until this one closes.
      # RPG2000 shows MSG_LINES_PER_PAGE text rows before paginating: a Show
      # Text (or a Show Choices merged onto it) that runs past that many lines
      # pages, with a "▼" marking that more follow. The reveal pauses at each
      # page boundary (a synthetic `:page` pause, released by paging rather than
      # dismissing) so the typewriter stops at the bottom of a page instead of
      # clipping the rest. Returns the boundary offsets (in the reveal's
      # revealed-character coordinates) for every page after the first that
      # actually holds a line, plus the total page count.
      def message_page_layout(plain)
        off = 0
        pauses = []
        plain.each_with_index do |line, i|
          off += line.to_s.length
          if (i + 1) % MSG_LINES_PER_PAGE == 0 && i + 1 < plain.length
            pauses << { at: off, kind: :page }
          end
        end
        pages = (plain.length + MSG_LINES_PER_PAGE - 1) / MSG_LINES_PER_PAGE
        pages = 1 if pages < 1
        [pauses, pages]
      end

      # Cumulative visible-character length of the message's lines before index
      # `idx`, in the same coordinates the reveal counts in, so a page slice can
      # be revealed relative to its own start.
      def message_line_offset(idx)
        off = 0
        lines = @message[:seg_lines]
        idx.times { |i| (lines[i] || []).each { |s| off += (s[:text] || '').length } }
        off
      end

      def open_message(lines, choice, interp: @interpreter)
        if @message
          # A Show Choices that directly follows a Show Text keeps the same
          # window: append the choice list below the text already on screen
          # instead of building a new window (see #drive_text_message).
          return unless choice && @message[:awaiting_followup] == :choice
          append_choice_lines(lines)
          return
        end
        names = ->(id) { actor_name(id) }
        raw = (lines || [])
        raw = [''] if raw.empty?
        # Parse each line into colour runs; the plain text (segments joined)
        # drives the reveal counter so it counts visible characters only.
        scans = raw.map do |l|
          Game::Message.scan(l.to_s, @state.variables, names)
        end
        seg_lines = scans.map { |s| s[:segments] }
        plain = seg_lines.map { |segs| segs.map { |s| s[:text] }.join }
        # Lift each line's pacing codes into global reveal coordinates (offset by
        # the visible length of the lines before it) so one reveal counter drives
        # the whole window.
        pauses = []
        instants = []
        speeds = []
        auto_close = false
        show_gold = false
        offset = 0
        scans.each_with_index do |s, li|
          s[:pauses].each { |p| pauses << { at: offset + p[:at], kind: p[:kind] } }
          (s[:instants] || []).each { |a, b| instants << [offset + a, offset + b] }
          (s[:speeds] || []).each { |sp| speeds << { at: offset + sp[:at], speed: sp[:speed] } }
          auto_close ||= s[:auto_close]
          show_gold ||= s[:show_gold]
          offset += plain[li].length
        end

        # Message Options / Change Face Graphic settings in effect for this
        # window (position, transparency and an optional FaceSet graphic).
        cfg = @state.message_config
        face_sheet = load_face(cfg)
        face_left = face_sheet && !cfg.face_right
        face_right = face_sheet && cfg.face_right
        text_x = face_left ? FACE_SIZE + FACE_MARGIN : 0

        inner_w = MSG_WIN_W - Window::BORDER * 2
        text_w = inner_w - text_x - (face_right ? FACE_SIZE + FACE_MARGIN : 0)
        inner_h = MSG_WIN_H - Window::BORDER * 2
        win_h = MSG_WIN_H
        # The timer's own bottom-edge-avoidance reads this (see #draw_timer's
        # comment) -- sticky, not reset when this message later closes,
        # ported from a reference implementation, not independently
        # confirmed against genuine RPG_RT under wine: it is
        # set afresh every message but never reset when the message finishes.
        @message_window_top =
          effective_message_position(win_h, cfg) == Game::MessageConfig::POS_TOP
        win = Window.new(0, message_window_y(win_h, cfg), MSG_WIN_W, win_h)
        win.z = 300
        win.windowskin = @windowskin
        win.transparent = cfg.transparent
        # No animation mid-battle: RPG_RT's own message/gold windows pop
        # straight in there instead of unrolling (see MSG_ANIM_FRAMES above).
        open_frames = @battle.nil? ? MSG_ANIM_FRAMES : 0
        win.open_animation(open_frames)

        contents = Bitmap.new(inner_w, inner_h)

        # A message longer than one screen paginates: inject a synthetic `:page`
        # pause at every page boundary so the typewriter stops at the bottom of
        # a page (a "▼" marks more) until the player advances it.
        page_pauses, pages = message_page_layout(plain)
        # Plain messages type out gradually; choice lists appear at once.
        reveal = Game::TextReveal.new(plain, 0, pauses + page_pauses,
                                      auto_close, instants, speeds)
        reveal.reveal_all if choice
        # `\$` shows the party's gold in a small window alongside the message.
        gold_window = nil
        if show_gold
          gold_window = build_inn_gold_window(nonblank(db.term.gold, 'G'))
          gold_window.open_animation(open_frames)
        end
        @message = { window: win, choice: choice, count: plain.length,
                     choice_start: 0, reveal: reveal, contents: contents,
                     inner_w: inner_w, seg_lines: seg_lines, interp: interp,
                     page: 0, pages: pages, auto_close: auto_close,
                     face: build_face_cell(face_sheet, cfg.face_index, cfg.face_flipped),
                     face_x: face_right ? inner_w - FACE_SIZE : 0,
                     text_x: text_x, text_w: text_w, gold_window: gold_window,
                     # The colour still in effect once this text ends -- a Show
                     # Choices later merged onto this same window (see
                     # #append_choice_lines) inherits it rather than starting
                     # back at the default (yado.tk: an explicit `\c[0]` is
                     # needed in the text to stop the choices inheriting it).
                     trailing_color: scans.empty? ? 0 : scans.last[:end_color] }
        speak_message(plain)
        draw_message_contents
        win.contents = contents
        @choice_index = 0
        set_choice_cursor if choice
      end

      # Zundamon (ずんだもん) message-window narration: read a page's plain,
      # fully-expanded text aloud (variables and actor names already
      # substituted, colour/pacing control codes already stripped -- see
      # `plain` in #open_message/#append_choice_lines) as the page opens.
      # Covers both Show Text and Show Choices -- a standalone choice window
      # reads its options through #open_message(lines, true), and one merged
      # onto a preceding Show Text reads just the appended options through
      # #append_choice_lines, never the text above it again. A no-op whenever
      # --zundamon_tts was not passed or its VOICEVOX assets are not
      # installed (RGSS::Tts.available? is false either way), so this changes
      # nothing about any other run.
      def speak_message(plain_lines)
        return unless RGSS::Tts.available?
        text = plain_lines.join("\n")
        RGSS::Tts.speak(text) unless text.strip.empty?
      end

      # Append a Show Choices block's labels to the still-open message window
      # from a Show Text that immediately preceded it (RPG_RT keeps one window
      # for the pair: text on top, choices below). Reuses the existing window,
      # contents bitmap and text layout; only the reveal and line list grow.
      def append_choice_lines(labels)
        @message[:awaiting_followup] = nil
        names = ->(id) { actor_name(id) }
        raw = (labels || [])
        raw = [''] if raw.empty?
        # Each choice label inherits the colour the preceding text (or an
        # earlier label) left off at, unless it sets its own -- the whole
        # merged window reads as one continuous colour stream (yado.tk).
        color = @message[:trailing_color] || 0
        scans = raw.map do |l|
          s = Game::Message.scan(l.to_s, @state.variables, names, color)
          color = s[:end_color]
          s
        end
        @message[:trailing_color] = color
        new_seg_lines = scans.map { |s| s[:segments] }
        @message[:choice_start] = @message[:seg_lines].length
        @message[:seg_lines] = @message[:seg_lines] + new_seg_lines
        @message[:choice] = true
        @message[:count] = new_seg_lines.length
        # Choice lists appear at once, same as a standalone choice window; the
        # text lines above are already fully revealed. A merged window that runs
        # past one screen still paginates, so recompute the page layout and
        # pause the reveal at each boundary (a confirm pages rather than
        # dismissing, see #drive_message).
        plain = @message[:seg_lines].map { |segs| segs.map { |s| s[:text] }.join }
        page_pauses, pages = message_page_layout(plain)
        reveal = Game::TextReveal.new(plain, 0, page_pauses,
                                      @message[:auto_close], [], [])
        reveal.reveal_all
        @message[:reveal] = reveal
        @message[:pages] = pages
        @message[:page] = 0
        # Only the newly appended options -- the preceding Show Text already
        # spoke itself from #open_message.
        speak_message(new_seg_lines.map { |segs| segs.map { |s| s[:text] }.join })
        draw_message_contents
        @choice_index = 0
        set_choice_cursor
      end

      # The display position (top / middle / bottom) a `win_h`-tall message
      # window actually resolves to right now. When the message is not pinned
      # (`position_fixed` off, RPG2000's default), this is the position that
      # keeps clear of the hero (`#auto_message_position`) rather than the
      # configured one directly -- ported from a reference implementation,
      # not independently confirmed
      # against genuine RPG_RT under wine: it does the identical
      # pinned-vs-dynamic split. `#open_message` also uses this (not just
      # `#message_window_y` below) to update the sticky "was the window at
      # the top" flag the timer's own bottom-edge-avoidance reads, since this
      # ported timer avoidance is downstream of this same per-page resolved
      # position, not the raw configured preference.
      def effective_message_position(win_h, cfg)
        return cfg.position if cfg.position_fixed
        auto_message_position(cfg.position)
      end

      # Vertical position of a `win_h`-tall message window for the configured
      # display position (top / middle / bottom). When the message is not pinned
      # (`position_fixed` off, RPG2000's default), the window relocates so it does
      # not cover the hero.
      def message_window_y(win_h, cfg)
        case effective_message_position(win_h, cfg)
        when Game::MessageConfig::POS_TOP    then 0
        when Game::MessageConfig::POS_MIDDLE then (SCREEN_H - win_h) / 2
        else SCREEN_H - win_h
        end
      end

      # RPG2000's own "avoid hiding the hero" auto-relocation, unpinned
      # (`position_fixed` off, the default) -- ported from a reference
      # implementation, not
      # independently confirmed against genuine RPG_RT under wine: it keys
      # a three-way switch off the *configured* Message Options preference
      # (`configured`) rather than always choosing top-or-bottom regardless
      # of it. Zone thresholds are the exact 112px / 160px (7 and 10 map
      # tiles at RPG2000's real 16px tile size, `16 * 7` / `16 * 10` in
      # the reference source) rather than the earlier `SCREEN_H / 2` (120px)
      # approximation this build used before a source read pinned those
      # ported figures down:
      #   configured Up:     hero above 112px -> Top,    else Bottom
      #   configured Center: hero above 160px -> Top, below 112px -> Bottom,
      #                      else Middle
      #   configured Down (RPG2000's own default): hero above 160px -> Top,
      #                      else Bottom
      def auto_message_position(configured)
        disp = hero_screen_y
        case configured
        when Game::MessageConfig::POS_TOP
          disp > 16 * 7 ? Game::MessageConfig::POS_TOP : Game::MessageConfig::POS_BOTTOM
        when Game::MessageConfig::POS_MIDDLE
          if disp <= 16 * 7
            Game::MessageConfig::POS_BOTTOM
          elsif disp >= 16 * 10
            Game::MessageConfig::POS_TOP
          else
            Game::MessageConfig::POS_MIDDLE
          end
        else
          disp >= 16 * 10 ? Game::MessageConfig::POS_TOP : Game::MessageConfig::POS_BOTTOM
        end
      end

      # The hero's feet in screen pixels (the bottom edge of its tile), from
      # the edge-clamped follow camera (ignoring transient pan / shake
      # offsets) -- ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT
      # under wine: it computes the tile's own top edge,
      # converted to pixels, plus one *full* tile, landing on the tile's
      # bottom edge -- not a half-tile centre the way horizontal centring
      # deliberately does for its own axis. The sprite's own draw origin is
      # pinned to the
      # bottom of its frame
      # for the identical reason. Previously computed the tile's centre
      # (`+ TILE / 2`) instead, which is what the message-position
      # thresholds above would have been comparing against if left
      # unfixed alongside them.
      def hero_screen_y
        _px, py = player_pixel
        cam_y = Game.camera_offset(py + TILE, SCREEN_H, @map.height * TILE)
        (py + TILE) - cam_y
      end

      # Load the FaceSet graphic named by the message config, or nil when no face
      # is selected or the file is missing (the message then shows text only).
      def load_face(cfg)
        return nil unless cfg.face?
        load_face_bitmap(cfg.face_name)
      end

      # Load a FaceSet graphic by name, or nil for a blank name or a missing
      # file (the caller then shows no portrait). Colour-keyed like the other
      # character art: a FaceSet's palette entry 0 is its background, and
      # drawing it opaque boxes the portrait in.
      def load_face_bitmap(name)
        return nil unless name && !name.empty?
        Bitmap.new "FaceSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{name}' load failed: #{e.message}"
        nil
      end

      # Crop one 48x48 cell out of a FaceSet sheet into its own bitmap, mirrored
      # horizontally when Change Face Graphic's own mirror flag (param2,
      # `cfg.face_flipped`) is set. `RGSS::Bitmap#blt` has no flip of its own
      # (mruby-rgss's `Sprite#mirror=` resorts to the same per-pixel software
      # pass for the same reason), so a mirrored face is built one column at a
      # time -- 48 single-column blits, done once here rather than once per
      # #draw_message_face call, since that runs every frame the text is still
      # revealing.
      def build_face_cell(sheet, index, flipped)
        return nil unless sheet
        src_x = (index % 4) * FACE_SIZE
        src_y = (index / 4) * FACE_SIZE
        cell = Bitmap.new(FACE_SIZE, FACE_SIZE)
        unless flipped
          cell.blt 0, 0, sheet, Rect.new(src_x, src_y, FACE_SIZE, FACE_SIZE)
          return cell
        end
        FACE_SIZE.times do |col|
          cell.blt FACE_SIZE - 1 - col, 0, sheet, Rect.new(src_x + col, src_y, 1, FACE_SIZE)
        end
        cell
      end

      # (Re)draw the message body showing the currently revealed characters,
      # each colour run in its own colour, laid out left to right per line. The
      # face graphic (when present) is drawn first, and text is inset past it.
      # Only the current page's MSG_LINES_PER_PAGE rows are drawn; a "▼" marks
      # that more pages follow.
      def draw_message_contents
        return unless @message
        c = @message[:contents]
        c.clear
        draw_message_face
        lines = @message[:seg_lines]
        page = @message[:page] || 0
        start = page * MSG_LINES_PER_PAGE
        slice = lines[start, MSG_LINES_PER_PAGE] || []
        rel = @message[:reveal].revealed - message_line_offset(start)
        rel = 0 if rel < 0
        vis = Game::Message.visible_segments(slice, rel)
        right = @message[:text_x] + @message[:text_w]
        vis.each_with_index do |segs, i|
          x = @message[:text_x]
          y = i * MSG_LINE_H
          segs.each do |seg|
            draw_message_run(c, x, y, right - x, seg)
            x += c.text_size(seg[:text]).width
          end
        end
        draw_message_more if page + 1 < (@message[:pages] || 1)
      end

      # RPG2000's "▼" continuation marker, drawn bottom-right of the message
      # interior when further pages follow. A small downward triangle (not every
      # system font carries the glyph), blinking like the keypress arrow it
      # replaces.
      def draw_message_more
        return unless @message
        c = @message[:contents]
        return unless @anim_frame % 30 < 15
        col = message_color(0)
        x = c.width - 14
        y = c.height - 9
        7.times { |i| c.fill_rect(x + (6 - i), y + i, 2 * i + 1, 1, col) }
      end

      # Draw one coloured message run. When the System windowskin is present and
      # the colour index is one of its 20 text swatches, blend the glyphs with
      # that swatch (`Bitmap#blend_text`), so the text takes the windowskin's own
      # colour and shading the way RPG2000 draws it. Otherwise fall back to a
      # flat font colour (the approximation, or an out-of-range `\c[n]`).
      #
      # yado.tk: text beyond a line's own display-limit width is silently
      # truncated, not wrapped. Neither `Bitmap#draw_text` nor `#blend_text`
      # (mruby-rgss/src/lib.cxx) clip to the `w`/`h` they are given -- those are
      # only ever used for centre/right alignment math -- so nothing here
      # stopped an overflowing run from drawing straight past its own line's
      # boundary. This happened to look right in the common case (no right-side
      # face), since the boundary coincides with the contents bitmap's own
      # right edge and glyphs simply run off the bitmap -- but a right-side Face
      # Graphic (`#open_message`'s `text_w`) leaves `FACE_SIZE + FACE_MARGIN` of
      # *bitmap* width beyond the intended text boundary for the portrait,
      # so an overflowing run kept drawing straight over it instead of
      # disappearing there. `#clip_text_to_width` (Scene::Base -- shared with
      # Scene::Battle's status panel, which hits the same unclipped-overflow
      # gap between its own name/state/HP/MP columns) measures and slices the
      # run to `w` itself before either draw path ever sees it, matching the
      # boundary this codebase's own message layout defines rather than
      # whatever the contents bitmap happens to be sized to.
      def draw_message_run(c, x, y, w, seg)
        idx = seg[:color]
        text = clip_text_to_width(c, seg[:text], w)
        if @windowskin && Game::MessagePalette.valid?(idx)
          draw_system_text c, x, y, w, MSG_LINE_H, text, @windowskin, idx
        else
          c.font.color = message_color(idx)
          c.draw_text x, y, w, MSG_LINE_H, text
        end
      end

      # Blit the already-cropped (and possibly mirrored, see #build_face_cell)
      # face cell into the message contents at its configured side.
      def draw_message_face
        face = @message[:face]
        return unless face
        @message[:contents].blt @message[:face_x], 0, face,
                                Rect.new(0, 0, FACE_SIZE, FACE_SIZE)
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
        offset = @message[:choice_start] || 0
        sel = offset + @choice_index
        page = @message[:page] || 0
        # The cursor only shows when the selected option is on the current page;
        # RPG2000 scrolls the choice list to keep the selection visible.
        if sel >= page * MSG_LINES_PER_PAGE &&
           sel < (page + 1) * MSG_LINES_PER_PAGE
          row = sel - page * MSG_LINES_PER_PAGE
          @message[:window].cursor_rect =
            Rect.new(0, row * MSG_LINE_H,
                     @message[:window].contents.width, MSG_LINE_H)
        else
          @message[:window].cursor_rect = Rect.new(0, 0, 0, 0)
        end
      end

      # Page the window so the selected choice option is on screen (RPG2000
      # scrolls the list to keep the cursor visible).
      def page_to_choice
        return unless @message
        offset = @message[:choice_start] || 0
        sel = offset + @choice_index
        @message[:page] = sel / MSG_LINES_PER_PAGE
      end

      def drive_message
        # Advances the open/close and blink/pause animation each frame so the
        # window unrolls open, and so the pause arrow (set below) actually
        # flashes instead of sitting on one frame. Text reveal and input are
        # not held off while it unrolls -- unlike a reference implementation,
        # which pauses its own message-window update while opening/closing
        # -- since the window
        # is a fresh object every message here rather than a persistent one
        # game scripts can poll, and holding logic off it would only delay
        # dismissal by MSG_ANIM_FRAMES with nothing else to show for it.
        @message[:window].update
        @message[:gold_window].update if @message[:gold_window]
        if @message[:choice]
          reveal = @message[:reveal]
          # A merged text+choices window that runs past one screen pages its
          # text first: while a `:page` pause is still pending, a confirm
          # advances the page (releasing it) instead of choosing, so the options
          # only become selectable once they are actually on screen.
          unless reveal.done?
            p = reveal.pending_pause
            if p && p[:kind] == :page
              if Input.trigger?(Input::C)
                @message[:page] = [@message[:page] + 1, @message[:pages] - 1].min
                reveal.release_pause
                draw_message_contents
              end
              return
            end
          end
          # Both directions auto-repeat while held, not just a fresh press --
          # ported from a reference implementation, not independently
          # confirmed against genuine RPG_RT under wine: the message
          # window is a plain
          # selectable-list subclass that runs the base list-cursor update
          # unconditionally every frame, before ever dispatching
          # to its own choice-specific input handling -- so a held Down/Up
          # scrolls the choice cursor exactly like any other list window
          # (gated on repeat-while-held, with endless scrolling on by
          # default and never overridden here).
          if Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
            @choice_index += 1
            @choice_index %= @message[:count]
            page_to_choice
            set_choice_cursor
            play_system_se(SFX_CURSOR)
          elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
            @choice_index -= 1
            @choice_index %= @message[:count]
            page_to_choice
            set_choice_cursor
            play_system_se(SFX_CURSOR)
          elsif Input.trigger?(Input::C)
            play_system_se(SFX_DECISION)
            index = @choice_index
            interp = @message[:interp]
            close_message
            interp.choose(index)
          elsif Input.trigger?(Input::B) && @message[:interp].choice_cancellable?
            # The Show Choices block says what cancelling means (pick a given
            # choice, or run its [Cancel] branch); a block that forbids it
            # swallows the key, as RPG_RT does.
            play_system_se(SFX_CANCEL)
            interp = @message[:interp]
            close_message
            interp.cancel_choice
          end
        else
          drive_text_message
        end
      end

      # A plain (non-choice) message: type the text out, and let a button press
      # first complete the reveal, then (once fully shown) dismiss and resume.
      # Frames a `\.` (quarter-second) and `\|` (full-second) pause hold.
      #
      # Not 15 / 60 (a literal quarter-/one-second at 60fps), even though
      # that is what RPG2000's own documentation names and what "quarter"/
      # "full" naturally suggest: ported from a reference implementation,
      # not independently confirmed against genuine RPG_RT under wine, whose
      # own comment claims this is RPG_RT's actual measured behaviour, one
      # frame longer than the documented duration in both cases ("Despite
      # documentation saying 1/4 second,
      # RPG_RT waits for 16 frames" / "...saying 1 second, RPG_RT waits for
      # 61 frames" -- the reference implementation's own comment,
      # not this project's own independent measurement),
      # the same "the natural reading is wrong" shape this codebase already
      # tracks for other RPG_RT quirks (e.g. the item-drain clamp order).
      #
      # `\.` alone has a second quirk on top: the reference implementation's
      # own comment calls it
      # "a bug(??)" -- the quarter-pause length is `16 + clamp(speed - 16,
      # 0, 4)`, where `speed` is whatever `\s[n]` (1..20) is in effect when
      # the `\.` is reached, not a fixed 16. A speed of 17..20 stretches the
      # quarter-pause by 1..4 extra frames; `\|`'s own 61-frame hold carries
      # no such term and stays flat regardless of speed.
      MSG_PAUSE_QUARTER = 16
      MSG_PAUSE_FULL = 61

      def drive_text_message
        interp = @message[:interp]
        reveal = @message[:reveal]
        # Cancel (B) dismisses a plain message exactly like Decision (C) --
        # re-verified against genuine RPG_RT.exe under wine (cycle #143):
        # a synthetic autostart Show Message immediately followed by a long,
        # already-proven-safe Enemy-Encounter tail (Map0478 event 2 page 2's
        # own genuine command list, spliced onto Map0012) showed the message
        # box open, then a single Escape/Cancel press closed it and let the
        # spliced Enemy Encounter fire right after -- the same outcome a
        # Decision press produces, not "swallowed" and not "opens the field
        # menu" (RPG_RT's own field-menu Escape handler never even sees the
        # key: #try_open_menu's `event_busy?` guard already keeps it from
        # firing while a message is up, independent of this line).
        confirm = Input.trigger?(Input::C) || Input.trigger?(Input::B)
        # Holding Shift during Test Play fast-forwards dialogue *while it is
        # still typing* -- same effect a C/B tap already has there (complete
        # the current reveal, releasing any inline `\!`/`\.`/`\|` pause along
        # the way). Once the whole message is shown, though, it always waits
        # for an actual confirm below, the same as with no Shift held: Shift
        # speeds up one paragraph's reveal, it does not blow through
        # paragraph after paragraph on its own. Gated on RPG2k#test_play the
        # same way #debug_through? is, so a released game never sees it.
        shift_forward = @parent.test_play && Input.press?(Input::SHIFT)
        fast_forward = confirm || shift_forward
        unless reveal.done?
          pause = reveal.pending_pause
          # A `:page` pause (synthetic, at a page boundary) means the current
          # page is full and more follow: a confirm advances to the next page
          # and releases it so that page's text starts typing, instead of
          # dismissing the window. No keypress arrow -- the "▼" marks it.
          if pause && pause[:kind] == :page
            @message[:window].pause = false
            if fast_forward
              @message[:page] = [@message[:page] + 1, @message[:pages] - 1].min
              reveal.release_pause
              draw_message_contents
            end
            return
          end
          # The blinking pause arrow only stands for a player-input wait
          # (`\!`, or the fully-revealed message below) -- not the timed
          # `\.` / `\|` holds, which clear on their own.
          @message[:window].pause = pause ? pause[:kind] == :key : false
          if pause
            drive_message_pause(reveal, pause, fast_forward, shift_forward)
          elsif fast_forward
            reveal.reveal_all
          else
            reveal.advance(MSG_REVEAL_SPEED)
          end
          draw_message_contents
          return
        end
        # `\^` closes the finished window on its own; otherwise wait for a button.
        if reveal.auto_close? || confirm
          followup = interp.message_followup
          if followup
            # A Show Choices / Input Number immediately follows this Show Text:
            # RPG_RT keeps the same window up, with the choices / digit entry
            # appended below the text already shown, instead of closing it.
            @message[:awaiting_followup] = followup
          else
            close_message
          end
          interp.resume
        else
          @message[:window].pause = true
        end
      end

      # Hold the reveal at a pacing code: `\!` waits for a button, `\.` / `\|`
      # count down a fixed number of frames that an ordinary Decision/Cancel
      # press cannot cut short -- ported from a reference implementation,
      # not independently confirmed against genuine RPG_RT under wine:
      # it decrements a wait counter that `\.`/`\|` set
      # and returns unconditionally while it is
      # still positive, entirely before the separate button-wait
      # branch even runs -- and the `\.`/`\|` cases only
      # ever arm that counter, never the button-wait flag, unlike
      # `\!`, which sets both. A `\.` pause's own length depends on
      # the `\s[n]` typing speed in effect at that point in the text (see
      # #speed_at and MSG_PAUSE_QUARTER's own comment); `\|` never varies.
      # `shift_forward` alone (Test Play's own fast-forward, see
      # #drive_text_message) still cuts a `\.`/`\|` wait short, mirroring
      # the reference implementation's own fast-forward guard around
      # that same wait -- an ordinary player confirm press must not.
      def drive_message_pause(reveal, pause, pressed, shift_forward)
        if pause[:kind] == :key
          reveal.release_pause if pressed
          return
        end
        @message[:pause_frames] ||= if pause[:kind] == :full
                                       MSG_PAUSE_FULL
                                     else
                                       speed = reveal.speed_at(pause[:at])
                                       MSG_PAUSE_QUARTER + Game.clamp(speed - 16, 0, 4)
                                     end
        @message[:pause_frames] -= 1
        if shift_forward || @message[:pause_frames] <= 0
          @message[:pause_frames] = nil
          reveal.release_pause
        end
      end

      # Dismiss the current message. By default this rolls the window (and its
      # `\$` gold window) shut over MSG_ANIM_FRAMES frames rather than popping
      # it away, mirroring #open_message; `animate: false` (scene teardown --
      # see #dispose) skips straight to disposal instead. The closing window
      # is handed off to #update_closing_windows rather than disposed here:
      # ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: its message window keeps
      # shrinking while the game underneath
      # it already carries on (the close animation is decoupled from the
      # interpreter), so @message is
      # cleared immediately and the caller (interpreter resume, choice
      # selection, ...) is never blocked on the animation finishing.
      def close_message(animate: true)
        return unless @message
        win = @message[:window]
        gold = @message[:gold_window]
        frames = (animate && @battle.nil?) ? MSG_ANIM_FRAMES : 0
        if frames > 0
          win.close_animation(frames)
          (@closing_windows ||= []) << win
          if gold
            gold.close_animation(frames)
            @closing_windows << gold
          end
        else
          win.dispose
          gold.dispose if gold
        end
        @message = nil
      end

      # Advance every window mid-close-animation (see #close_message) one
      # frame, disposing each once its animation finishes. Called once a
      # frame regardless of whether a message is open, since a window can
      # still be shrinking after @message itself has already moved on.
      def update_closing_windows
        return unless @closing_windows
        @closing_windows.reject! do |w|
          w.update
          unless w.closing?
            w.dispose
            true
          end
        end
      end

      # -- number input (Input Number command) --------------------------------

      # Pixels per digit cell in the Input Number widget.
      NUM_CELL = 16

      # Open a digit-entry widget for the Input Number command. When it directly
      # follows a Show Text (RPG_RT keeps one window for the pair -- see
      # #drive_text_message), the cells are drawn into the still-open message
      # window below the text already shown; otherwise a standalone compact
      # panel opens near the bottom of the screen. Either way the interpreter
      # is resumed with the entered value on confirm.
      #
      # `interp:` is whichever interpreter's Input Number this answers to --
      # the foreground @interpreter by default, or a Parallel Process's own
      # interpreter when #drive_parallel_wait opens one (mirrors #open_message's
      # own `interp:` keyword). #drive_number_input reads it back to resume the
      # interpreter that actually asked for it rather than always @interpreter.
      def open_number_input(digits, interp: @interpreter)
        return if @number_input
        model = Game::NumberInput.new(digits || 1)
        if @message && @message[:awaiting_followup] == :number
          @message[:awaiting_followup] = nil
          x = @message[:inner_w] - model.digits * NUM_CELL
          y = @message[:seg_lines].length * MSG_LINE_H
          @number_input = { model: model, embedded: true, x: x, y: y, interp: interp }
          draw_number_input
          return
        end
        inner_w = model.digits * NUM_CELL
        inner_h = MSG_LINE_H
        win_w = inner_w + Window::BORDER * 2
        win_h = inner_h + Window::BORDER * 2
        win = Window.new((SCREEN_W - win_w) / 2, SCREEN_H - win_h - 6, win_w, win_h)
        win.z = 320
        win.windowskin = @windowskin
        contents = Bitmap.new(inner_w, inner_h)
        @number_input = { window: win, contents: contents, model: model, interp: interp }
        draw_number_input
        win.contents = contents
      end

      def draw_number_input
        ni = @number_input
        return unless ni
        model = ni[:model]
        if ni[:embedded]
          c = @message[:contents]
          x0 = ni[:x]
          y0 = ni[:y]
          c.fill_rect x0, y0, model.digits * NUM_CELL, MSG_LINE_H, Color.new(0, 0, 0, 0)
        else
          c = ni[:contents]
          x0 = 0
          y0 = 0
          c.clear
        end
        (0...model.digits).each do |i|
          x = x0 + i * NUM_CELL
          if i == model.cursor
            c.fill_rect x, y0 + 1, NUM_CELL, MSG_LINE_H - 2, Color.new(40, 72, 200, 160)
          end
          c.font.color = Color.new(255, 255, 255, 255)
          c.draw_text x, y0, NUM_CELL, MSG_LINE_H, model.digit(i).to_s, 1
        end
      end

      # Ported from a reference implementation, not independently confirmed
      # against genuine
      # RPG_RT under wine: every digit adjustment/cursor move plays the
      # Cursor system SE, and confirm
      # plays Decision -- the same shape
      # Show Choices already gets a few lines up in this same method's
      # sibling handler (#drive_message's choice-list branch), just missed
      # here.
      def drive_number_input
        ni = @number_input
        model = ni[:model]
        if Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          model.inc
          draw_number_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          model.dec
          draw_number_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          model.left
          draw_number_input
          play_system_se(SFX_CURSOR)
        # Right is a no-op -- no move, no sound -- on a single-digit widget:
        # ported from a reference implementation, not independently
        # confirmed against genuine RPG_RT under wine: it guards only its
        # Right branch
        # behind a digit-count check; Left has no such guard and always
        # plays the Cursor SE, even though its own modulo leaves a
        # single-cell cursor unmoved either way. Not the symmetric pair a
        # single `#left`/`#right` gate would suggest.
        elsif (Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)) && model.digits >= 2
          model.right
          draw_number_input
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          value = model.value
          embedded = ni[:embedded]
          interp = ni[:interp] || @interpreter
          close_number_input
          close_message if embedded
          interp.resume_number(value)
        end
      end

      def close_number_input
        return unless @number_input
        @number_input[:window].dispose if @number_input[:window]
        @number_input = nil
      end

      # The tile the party would try to step onto this frame if #step_movement
      # ran right now, or nil if it would not attempt a move at all -- the
      # exact same set of early-outs #step_movement itself bails out on
      # (mid-slide, an event already running, a forced route driving the
      # party, no direction held), evaluated *before* #step_events so a
      # same-frame crossing can be recognised while an autonomous/route event
      # is still deciding its own move (see the #update call site and
      # #move_autonomous). None of these guards can change between here and
      # #step_movement's own call: #step_events never touches @moving,
      # #event_busy?, @player_route or @state.boarded for the party, so both
      # reads agree.
      def player_intended_target
        return nil if @moving
        return nil if event_busy?
        return nil if @player_route
        return nil if @state.boarded? # no touch trigger applies while riding
        dir = Input.dir4
        return nil if dir == 0
        target_tile(@state.x, @state.y, dir)
      end

      def step_movement
        return if advance_player_slide

        return if event_busy? # don't start a new move while an event runs
        return if @player_route # a forced route controls the player
        dir = Input.dir4
        return if dir == 0

        @state.direction = dir
        nx, ny = target_tile(@state.x, @state.y, dir)

        if @state.boarded?
          # Aboard a vehicle: use the vehicle's passability and glide over touch
          # events (you cannot trigger them from the water / air).
          return unless vehicle_passable?(nx, ny, dir, @state.boarded)
        else
          # Walking into a touch event runs it; whether that also blocks the
          # step depends on the event's layer (see the `LAYER_SAME` check
          # below). **Both** touch triggers answer here: ported from a
          # reference implementation, not independently confirmed against
          # genuine RPG_RT under wine: it tests both trigger types as
          # one set on every
          # player-side path, so the asymmetry is not
          # the one the trigger names suggest — an "event touch" (2) event fires
          # whether it walked into the party or the party walked into it, while
          # a "player touch" (1) fires only on the party's own move (the event
          # side checks trigger 2 alone, see #move_autonomous). A **Parallel
          # Process** (4) page answers here too (see #touch_trigger?) — its own
          # background loop (#step_parallel) is untouched, so contact starts a
          # second, independent run through the shared foreground @interpreter.
          touched = event_at(nx, ny)
          # A genuine same-frame crossing (docs/TODO.md "Map Event" case (c),
          # yado.tk's 当たり判定が無効になります): `touched` refused to step
          # onto the party's own tile this very frame *because* it was
          # heading for it, while the party is, this same frame, heading for
          # `touched`'s tile -- see #move_autonomous /
          # Game::MoveRoute#do_move's `:touched_hero` handling, which is the
          # only place this flag is ever set true. Real RPG_RT invalidates
          # the hit-test entirely for that configuration: neither this Hero
          # Touch (1) nor `touched`'s own Event Touch (2) (already withheld
          # above) fires, and control falls through to the ordinary
          # passability check below exactly as if `touched` were not a touch
          # page at all -- ordinary blocking (a same-layer event still stops
          # the party cold, just silently) is unaffected.
          if touched && touch_trigger?(touched[:trigger]) && touched[:commands] &&
             !touched[:crossed_hero_this_frame]
            start_event(touched)
            # A same-layer touch event blocks like a closed door: it fires but
            # the party stays put, exactly as before. A below/above-characters
            # touch event (the common "invisible SE tile" pattern) is a
            # decoration, not an obstacle -- #passable?/#char_passable? never
            # let it block movement elsewhere, so falling through to the
            # ordinary passability check below lets the party keep walking
            # onto its tile while the event's commands run alongside.
            return if touched[:layer] == LAYER_SAME
          end
          # Through Mode (see @player_through) bypasses collision the same way
          # it does for an event's own #char_passable? -- touch triggers still
          # fire above regardless, since through-ness is purely a collision
          # bypass, not a trigger suppression. Holding Ctrl during Test Play
          # (see #debug_through?) does the same.
          return unless @player_through || debug_through? || passable?(nx, ny, dir)
        end

        @dest_x = nx
        @dest_y = ny
        @moving = true
        @move_count = 0
        @player_forced_step = false
      end

      # One tile walked. Advance the party's step counter and let RPG2000's field
      # slip damage act on it: a status condition carrying a map-step interval
      # (mtf-meido-action's Poison, 1 HP every 4 steps, is the only one in either
      # test bed) drains its afflicted members every time the count reaches a
      # multiple of that interval.
      #
      # The drain cannot kill -- Party#apply_map_step_damage floors it at 1 HP --
      # so unlike the event commands that damage the party this needs no game-over
      # check. It flashes the screen red instead, because otherwise the HP would
      # simply fall with nothing on screen saying why: the map has no HP display.
      def note_party_step
        steps = @state.walk_step
        hit = @state.party.apply_map_step_damage(state_table, steps)
        # A GAIN-type (regen) state's own tick never flashes red, matching
        # a reference implementation, not independently
        # confirmed against genuine RPG_RT under wine -- see
        # Game::Party#map_step_damaged?'s own doc comment.
        state_damaged = @state.party.respond_to?(:map_step_damaged?) &&
                        @state.party.map_step_damaged?
        # RPG2000's 地形ダメージ on top of it: the terrain the tile just stepped
        # onto belongs to may take HP off everyone not wearing gear that blocks
        # it -- or, for a terrain with a negative `damage` (a healing tile),
        # add HP to everyone regardless of that gear (#apply_terrain_damage's
        # own doc comment). Read after the status slip and flashed together,
        # since both are the same "your HP just fell and the map has nowhere
        # to say so" moment -- except a heal never flashes red or counts as
        # "damaged" for the footstep SE below, matching a reference
        # implementation, not independently confirmed against genuine
        # RPG_RT under wine, which only sets the red flash for positive
        # damage.
        #
        # Skipped entirely while riding the airship, ported from a
        # reference implementation, not independently confirmed against
        # genuine RPG_RT under wine: it
        # returns via an airship-specific early check *before* it ever looks
        # up the stepped-on tile's terrain row, so an airborne party takes
        # neither the HP damage nor (RPG2003) the footstep SE for whatever is
        # below it -- unlike a boat/ship, which still sails the water layer's
        # own terrain and is not exempted (an airship-specific check alone,
        # not a general
        # `boarded?` check). The status-condition slip above has no such
        # gate in the reference implementation (its own state-damage
        # call runs unconditionally), so it stays outside
        # this guard.
        terrain_damaged = false
        unless @state.boarded == :airship
          row = terrain_row_at(@state.x, @state.y)
          terrain_hit = terrain_step_damage(row)
          terrain_damaged = !terrain_hit.empty? && row && row.respond_to?(:damage) &&
                            row.damage && row.damage > 0
          play_terrain_footstep_se(row, terrain_damaged)
        end
        return if hit.empty? && !terrain_damaged
        @state.screen.flash(*STEP_DAMAGE_FLASH) if state_damaged || terrain_damaged
      end

      # Apply the damage of the terrain under the party, returning the actors it
      # hit ([] when the tile is harmless or the database has no terrain table).
      # `row` defaults to a fresh #terrain_row_at lookup so existing callers
      # (and the diagnostic dedup test, which calls this indirectly through a
      # step) keep working; #note_party_step passes its own already-looked-up
      # row instead of asking #terrain_row_at a second time for the same tile.
      def terrain_step_damage(row = terrain_row_at(@state.x, @state.y))
        return [] unless row && row.respond_to?(:damage)
        @state.party.apply_terrain_damage(row.damage)
      end

      # RPG2003's 歩行音 (footstep SE), ported from a reference implementation,
      # not independently confirmed against genuine RPG_RT under wine: it
      # plays
      # the terrain's own footstep sound right after applying that step's
      # terrain damage,
      # gated on running as RPG2003 -- RPG2000 never plays it at all, which
      # is why `scripts/rpg2k_field_audit.rb`'s `NOT_OURS` table used to list
      # `footstep` as out of scope; wiring it here (RPG2003-gated, matching
      # that ported behaviour) is what retires that entry. `on_damage_se`
      # repurposes
      # the same field: when set, `footstep` only plays on a step that actually
      # damaged someone,
      # turning it from an ambient step sound into the terrain's own damage-tick
      # SE instead of playing on every ordinary step onto that terrain.
      # It plays
      # a full sound (filename + volume +
      # tempo + balance), which treats a blank name
      # *or* the literal "(OFF)" sentinel as silent no-ops, the same
      # convention every other Sound-typed field in this codebase already
      # follows (see `#db_system_se`/`#play_animation_se`). `balance` (cycle
      # #221) now reaches `RGSS::Audio.se_play`'s own native pan argument too
      # -- previously dropped along with every other SE call site's, before
      # the backend had anywhere to forward it to.
      def play_terrain_footstep_se(row, damaged)
        return unless @db.respond_to?(:rpg2003?) && @db.rpg2003?
        return unless row && row.respond_to?(:footstep) && row.respond_to?(:on_damage_se)
        return if row.on_damage_se && !damaged
        se = row.footstep
        name = se && se.respond_to?(:file) ? se.file : nil
        return if name.nil? || name.empty? || name == '(OFF)'
        balance = se.respond_to?(:balance) ? se.balance : 50
        RGSS::Audio.se_play(name, se.volume, se.pitch, balance)
      rescue StandardError => e
        $stderr.puts "[RPG2k] Terrain: footstep SE playback failed: #{e.message}"
      end

      # -- Random ("wandering monster") encounters -----------------------------
      #
      # Ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine: each
      # ordinary step
      # adds the stepped-on tile's terrain encounter_rate (database terrain
      # field 3, 100 by default) to a running total; the ratio of that total to
      # the map's own encounter-steps setting selects a row of this table, and
      # the row's multiplier scales the chance a fight starts *this* step. The
      # ratio only grows (nothing decays it) until a fight actually starts, so
      # a long walk with no encounter becomes steadily more likely to end in
      # one -- RPG2000's answer to "I haven't been ambushed in ages".
      ENCOUNTER_TABLE = [
        [0, 0.0625], [20, 0.125], [40, 0.25], [60, 0.5], [100, 2.0],
        [140, 4.0], [160, 8.0], [180, 16.0], [Float::INFINITY, 16.0]
      ].freeze

      # p scaled to basis points over this and rolled through Rng#scaled rather
      # than #random -- the fix Battle#critical? needed (see Game::Rng#scaled):
      # a plain modulus biases a small, threshold-sized chance high, and this
      # table's lower rows (as little as 1/16 of 1/encounter_steps) are exactly
      # that shape.
      ENCOUNTER_CHANCE_SCALE = 1_000_000

      # How many steps the map currently expects between encounters: a live
      # Change Encounter Rate (11740) override when one is set, else the
      # current map-tree node's own encount_steps (field 44, 25 by default --
      # RPG2000's editor default). 0 (from either source) turns encounters off
      # for this map outright, matching a reference implementation's own
      # steps<=0 exit, not independently confirmed against genuine RPG_RT
      # under wine.
      def current_encounter_steps
        return @state.encounter_rate if @state.encounter_rate
        row = map_node_properties
        row && row.respond_to?(:encount_steps) ? row.encount_steps : 25
      end

      # The current map's own map-tree node row -- Game::MapAccess's per-id
      # lookup, minus the "walk up to the parent" half of it: a map's random
      # encounters are its own list end to end, RPG_RT never inherits one from
      # an ancestor node the way it does Save/Teleport/Escape access.
      def map_node_properties
        props = map_properties
        props ? props[@state.map_id] : nil
      end

      # Troop ids the party's current tile can start a fight from: the map's
      # own encounter list (map-tree field 41) plus every "Area" sub-region
      # (field 4 == 2) that is this map's own direct child and whose bounds
      # (field 51) cover the party's tile, filtered by each troop's own
      # terrain_set (enemy_group chunk field 5) -- a per-terrain-tag allow list
      # a troop's editor page can restrict it to. An omitted entry (the array
      # too short to reach this tile's tag) defaults to allowed, the same
      # "missing entry reads as the field's default" rule the rest of this
      # runtime's bit tables already follow. Ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT under
      # wine: it pools an
      # Area node's own encounter list into the *same* pool as the map's
      # own, so the roll draws uniformly across both -- not a
      # separate roll layered on top.
      def candidate_troops
        tag = terrain_id(@state.x, @state.y)
        troop_ids(map_node_properties).concat(area_troop_ids).select do |tid|
          troop_allowed_on_terrain?(tid, tag)
        end
      end

      def troop_ids(row)
        return [] unless row && row.respond_to?(:enemy_groups) && row.enemy_groups
        row.enemy_groups.map { |_, e| e.enemy_group_id }
      end

      # Every Area node's own troop ids, for an Area that is a direct child of
      # the current map (field 2, `parent_map_id`) and whose rectangle (field
      # 51) contains the party's tile. `left`/`top` inclusive, `right`/
      # `bottom` exclusive -- this schema's own field-51 comment already notes
      # they are stored as `X2 + 1` / `Y2 + 1`, matching a reference
      # implementation, not independently confirmed against genuine
      # RPG_RT under wine,
      # worked through by hand: that reduces to `area.left <= x < area.right
      # && area.top <= y
      # < area.bottom`.
      def area_troop_ids
        props = map_properties
        return [] unless props
        troops = []
        props.each do |_, row|
          next unless row.respond_to?(:type) && row.type == 2
          next unless row.respond_to?(:parent_map_id) && row.parent_map_id == @state.map_id
          area = row.respond_to?(:area) ? row.area : nil
          next unless area && area_contains?(area, @state.x, @state.y)
          troops.concat(troop_ids(row))
        end
        troops
      end

      def area_contains?(area, x, y)
        x >= area[:left] && x < area[:right] && y >= area[:top] && y < area[:bottom]
      end

      def troop_allowed_on_terrain?(tid, tag)
        return true unless tag && tag > 0 && db.respond_to?(:enemy_group)
        troop = db.enemy_group[tid]
        return true unless troop
        ts = troop.respond_to?(:terrain_set) ? troop.terrain_set : nil
        return true unless ts
        ts.size < tag || (ts[tag - 1] || 0) != 0
      end

      # RPG_RT's own debug walk: holding Ctrl while Test Play is running (see
      # RPG2k#test_play) ignores collision the same way Through Mode does (see
      # #step_movement) and, below, suppresses random encounters outright --
      # released games never run with test_play true, so neither effect can
      # reach them. Ported from a reference implementation's own
      # reverse-engineered
      # behaviour, not independently confirmed against genuine RPG_RT under
      # wine.
      def debug_through?
        @parent.test_play && Input.press?(Input::CTRL)
      end

      # One ordinary step's roll for a wandering-monster fight. A hit picks a
      # uniform-random troop from #candidate_troops (an empty list -- a map
      # with no encounter entries reaching this tile -- never interrupts the
      # walk) and opens the battle exactly as an Enemy Encounter event command
      # would, through the same Game::Interpreter#start_random_battle the
      # interpreter exposes for it.
      #
      # Only ever called from ordinary player-input movement (see
      # @player_forced_step), so the interpreter is always idle here -- no
      # event, common event or forced route can be running underneath it.
      def check_random_encounter
        return if debug_through?
        return if @state.party.flying?(@state)
        # yado.tk quirk, multiply corroborated: a Hero Touch (trigger 1)
        # event's own tile also answers random encounters -- the party can
        # land on one without ever running it (an autonomously-moving event
        # only fires its *Event Touch* trigger on overlap, never Hero Touch,
        # see #touch_trigger?'s comment), and while standing there the
        # wandering-monster roll is suppressed for that step, same as
        # flying or a forced-route step above/below.
        ev = event_at(@state.x, @state.y)
        return if ev && ev[:trigger] == TRIGGER_PLAYER_TOUCH
        steps = current_encounter_steps
        if steps <= 0
          @state.encounter_total = 0
          @encounter_idx = 0
          return
        end
        # Ported from a reference implementation, not independently
        # confirmed against genuine
        # RPG_RT under wine:
        # it returns outright when the tile's terrain row can't be resolved at
        # all -- no
        # fallback rate, no encounter_total increment, no roll for that step,
        # exactly as if it never happened. A chipset cell whose terrain id a
        # database shrink has since removed (#terrain_row_at's own "stale
        # terrain" diagnostic) used to fall through to a fabricated `rate =
        # 100` here instead, still rolling for a fight on a tile this ported
        # model can never trigger one from. `terrain.respond_to?(:encounter_rate)`
        # below is unrelated and untouched: that's this build's own
        # test-fixture tolerance for a bare OpenStruct row that omits the
        # field, not something a real LCF terrain row (which always carries
        # it) can actually do.
        terrain = terrain_row_at(@state.x, @state.y)
        return unless terrain
        rate = terrain.respond_to?(:encounter_rate) ? terrain.encounter_rate : 100
        @state.encounter_total += rate
        ratio = @state.encounter_total / steps
        @encounter_idx += 1 while ratio >= ENCOUNTER_TABLE[@encounter_idx + 1][0]
        pmod = ENCOUNTER_TABLE[@encounter_idx][1]
        chance = pmod * rate / (100.0 * steps)
        return unless roll_encounter_chance(chance)
        @state.encounter_total = 0
        @encounter_idx = 0
        troops = candidate_troops
        return if troops.empty?
        troop_id = troops[@rng.random(troops.size)]
        # RPG2000's own first-strike roll for a wandering encounter -- ported
        # from a reference implementation, not independently confirmed against
        # genuine RPG_RT under wine: it rolls
        # a 1/32 chance only
        # for an RPG2000-battle-system database -- so a real
        # RPG2003 game never rolls this 1/32 chance at all; it draws from the
        # (largely unimplemented, see the terrain-condition TODO entry)
        # back-attack/pincer terrain system instead, never both. The roll is
        # skipped outright rather than merely discarded on an RPG2003 database,
        # matching the reference implementation's own branching exactly and keeping this
        # engine's seeded RNG stream in step with a genuine RPG2003 run, which
        # never consumes a random number here either.
        first_strike = !@state.party.rpg2003? && @rng.random(32).zero?
        @interpreter.start_random_battle(troop_id, first_strike: first_strike)
      end

      def roll_encounter_chance(p)
        chance = (p * ENCOUNTER_CHANCE_SCALE).round
        chance = ENCOUNTER_CHANCE_SCALE if chance > ENCOUNTER_CHANCE_SCALE
        chance = 0 if chance < 0
        @rng.scaled(ENCOUNTER_CHANCE_SCALE) < chance
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

      # The player's own step check: (x, y) is the tile ahead, `dir` the
      # direction of travel from the player's current tile. Like
      # `char_passable?`, both sides of the boundary must agree — the tile
      # under the player's feet must allow exit toward `dir`, and (x, y) must
      # allow entry from the opposite side — and the upper layer at each tile
      # gets the same say as the lower one.
      def passable?(x, y, dir)
        return false unless @map.in_bounds?(x, y)
        # The hero is always a "normal character" for collision purposes: only
        # a same-layer event blocks it, a below/above-characters one is a
        # decoration it walks straight over (see the LAYER_* comment).
        # `overlap_forbidden` (LCF page field 35) never enters into it: ported
        # from a reference implementation, not independently confirmed
        # against genuine RPG_RT under wine: collision only
        # ever consults that
        # flag when *both* sides of a collision are map events —
        # the
        # party is never a map event, so an event
        # with the flag set collides with *other events* regardless of its
        # layer but is never what blocks the hero (see #char_passable? for
        # the fuller citation). Every event on the tile gets a say
        # (#blockers_at), not just one of them: a below-characters decal and
        # a same-as-characters NPC can share a tile, and the NPC must still
        # block even though the decal alone would not. A blocker's own
        # Through Mode exempts it from this entirely, the same as the
        # mover's: collision checks either side's own Through Mode
        # before any layer test at all,
        # uniformly for the hero, another event, or a vehicle -- an NPC
        # authored with Through Mode on (a common technique so it never
        # blocks the party) must let the hero walk straight through it,
        # matching `#vehicle_passable?`'s own already-correct `!b[:char].
        # through` idiom just above.
        return false if blockers_at(x, y).any? { |b| b[:layer] == LAYER_SAME && !b[:char].through }
        # An unridden boat/ship blocks the hero on foot exactly like a
        # same-layer event would (see #vehicle_blocks?); an unridden airship
        # never does, on foot or otherwise (block_airship: false — the hero
        # is always "the player" for this rule).
        return false if vehicle_blocks?(x, y, block_airship: false)
        return true if @chipset.nil?
        @chipset.passable_tile?(@map.lower(@state.x, @state.y),
                                 @map.upper(@state.x, @state.y), dir) &&
          @chipset.passable_tile?(@map.lower(x, y), @map.upper(x, y),
                                   Game::Character::TURN_180[dir] || dir)
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

      # The view's top-left corner in map pixels — where the camera is looking
      # this frame. Extracted from #render so the Control Variables "screen
      # coordinate" operand can ask for it too; it is a pure function of the
      # hero position, the pan lock/offset and the shake, apart from `@locked_cam`
      # being captured the first frame the camera locks (which is idempotent, so
      # an extra caller cannot move the view). `px`/`py` let #render, which
      # already has #player_pixel's result, pass it straight through instead of
      # recomputing (and re-allocating) it here.
      def camera_position(px = nil, py = nil)
        px, py = player_pixel if px.nil?
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
        [base_x + ox - screen.shake_offset, base_y + oy]
      end

      # Where a character sits on screen, for the Control Variables "character"
      # operand's screen-coordinate selectors. `ref` is the operand's reference:
      # 10001 the hero, 10002-10004 a vehicle (boat/ship/airship), a positive id
      # a map event. nil when it names something this scene cannot place — a
      # vehicle not currently on this map included, the same degenerate answer
      # an unresolvable map event already gets.
      #
      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: it measures X from the tile's
      # centre and Y from its *bottom* — the
      # asymmetry is in that source, so it is
      # reproduced rather than tidied up.
      def character_screen_position(ref)
        pixel =
          if ref == MOVE_TARGET_PLAYER
            player_pixel
          elsif ref >= MOVE_TARGET_BOAT && ref <= MOVE_TARGET_AIRSHIP
            vehicle_pixel(Game::Vehicle::TYPES[ref - MOVE_TARGET_BOAT])
          else
            e = @events.find { |ev| ev[:id] == ref }
            e && event_pixel(e)
          end
        return nil unless pixel
        cam_x, cam_y = camera_position
        { x: pixel[0] - cam_x + TILE / 2, y: pixel[1] - cam_y + TILE }
      end

      # Whether `character` is on screen, plus a two-tile margin -- ported
      # from a reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: it computes the same
      # screen-pixel math #character_screen_position already ports and
      # tests it against the screen bounds plus a two-tile margin.
      # Used to gate Move Type Approach/Away from Player's
      # own randomness (see Game::MoveType.next_direction) -- an off-screen
      # chaser gets no special treatment there at all, not even a degraded
      # one, so this uses the character's plain tile position rather than
      # #event_pixel's mid-slide interpolation (a fresh autonomous-move
      # decision is only ever made between slides, never mid-step).
      def char_in_sight?(character)
        cam_x, cam_y = camera_position
        sx = character.x * TILE - cam_x + TILE / 2
        sy = character.y * TILE - cam_y + TILE
        offset = TILE * 2
        sx >= -offset && sx <= SCREEN_W + offset && sy >= -offset && sy <= SCREEN_H + offset
      end

      # Current position of vehicle `type` in map pixels: the party's own
      # interpolated pixel position while it's the one being ridden
      # (#player_pixel, so it reads in lockstep with the hero mid-step),
      # otherwise wherever it sits parked — the same rule #draw_vehicles
      # renders a vehicle's sprite by. nil when the vehicle isn't placed on the
      # currently loaded map at all (unplaced, or sitting on a different one).
      def vehicle_pixel(type)
        v = @state.vehicle(type)
        return nil unless v.placed? && v.map_id == @state.map_id
        @state.boarded == type ? player_pixel : [v.x * TILE, v.y * TILE]
      end
      public :camera_position, :character_screen_position, :char_in_sight?

      # The rest of the "services Scene::Battle calls back into" (see the
      # readers next to #dispose): BGM, backdrop, animation-player and
      # debug-menu methods a fight shares with the field map, reached from
      # Scene::Battle with an explicit `@map.` receiver, which -- like any
      # cross-object call -- only reaches a public method.
      public :play_battle_bgm, :play_victory_bgm, :restore_pre_battle_bgm,
             :terrain_backdrop, :backdrop_for_terrain_id, :map_properties, :perform_game_over,
              :try_open_debug_menu, :build_animation, :anim_target, :drive_map_animation,
             :fire_animation_flashes, :frames_from_tenths, :load_face_bitmap,
             :step_map_animation, :close_battle, :current_map_tone

      # Reached from Scene::ChipsetEditor (a debug tool, pushed on top rather
      # than a Scene::Battle callback like the block above) after it edits and
      # saves the database's chipset row, so the change is visible in the
      # field map immediately rather than only on the next map load.
      public :rebuild_chipset

      def render
        px, py = player_pixel
        cam_x, cam_y = camera_position(px, py)

        # The map itself never shows on the battle screen -- see
        # #set_map_layers_visible, which explains why the backdrop needs it gone
        # rather than merely sitting above it.
        if @battle
          set_map_layers_visible false
        else
          set_map_layers_visible true
          RGSS::Profiler.section("map.parallax") { draw_parallax cam_x, cam_y }
          RGSS::Profiler.section("map.layers") { draw_layers cam_x, cam_y }

          @player_sprite.x = px - cam_x - (Game::CharSet::WIDTH - TILE) / 2
          @player_sprite.y = py - cam_y - (Game::CharSet::HEIGHT - TILE) -
                             player_jump_offset
          # Reflect the Set Transparent Flag command (and the leader graphic's
          # own translucent-ghost flag) every frame -- see #apply_player_visibility.
          apply_player_visibility
          RGSS::Profiler.section("map.chars") do
            draw_player_frame
            draw_vehicles cam_x, cam_y, px, py
          end
        end
        # Not gated: @animation_sprite is a top-level sprite (z 150, above the
        # battlers) and #draw_map_animation drives the in-battle Show Battle
        # Animation through the very same path as the map one -- see its own
        # `ma[:battle]` branch.
        RGSS::Profiler.section("map.animation") { draw_map_animation cam_x, cam_y }

        # Pictures never show on the battle screen (yado.tk / 01_shoshin's
        # 011_siyou: "none show on Menu/Battle screens") -- unlike the Menu
        # screen, which is already covered by its own opaque field background
        # sitting above the picture layer (see Scene::Base#build_field_background),
        # nothing else painted over @picture_sprite (z 250) while a fight is
        # running: the battle backdrop (Scene::Battle's own back sprite) sits well below
        # it, so a picture shown before the encounter (or by a Parallel Process
        # still running during it) would otherwise draw straight over the battle
        # UI. Hidden for the fight's whole duration and stops compositing
        # entirely (not just hidden with a stale frame underneath), then resumes
        # -- and immediately redraws -- the instant the battle UI is gone.
        if @battle
          @picture_sprite.visible = false
        else
          @picture_sprite.visible = true
          RGSS::Profiler.section("map.pictures") { draw_pictures cam_x, cam_y }
        end
        RGSS::Profiler.section("map.overlay") { update_screen_overlay }
        draw_timer
      end

      # RPG2000 timer: five 8x16 digit/colon cells (M M : S S) cut straight out
      # of the System graphic, not a bordered window with drawn text -- ported
      # from a reference implementation, not independently confirmed against
      # genuine RPG_RT under wine, rather than left as the
      # "rendering-parity job of its own" this comment used to defer.
      # It blits each digit/colon cell out of the System graphic into a
      # bare 40x16 sprite,
      # with **no** window/border of any kind -- and it never draws at all when
      # there is no System graphic to cut from, unlike this build's old
      # windowed text, which
      # only lost its windowskin *decoration* on a missing graphic and kept
      # showing the digits anyway. Visibility (the Start command's "show timer"
      # flag) is independent of whether it is still counting, so a stopped
      # timer stays on screen frozen; it hides only when never shown (or with
      # no System graphic loaded).
      TIMER_INNER_W = 40
      TIMER_INNER_H = 16
      TIMER_DIGIT_W = 8
      TIMER_DIGIT_H = 16
      TIMER_DIGIT_SRC_X = 32
      TIMER_DIGIT_SRC_Y = 32
      TIMER_COLON_SRC_X = TIMER_DIGIT_SRC_X + TIMER_DIGIT_W * 10

      # Both timers are drawn the same way; ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT under
      # wine: it puts the first at the
      # screen's left edge and the second at its right,
      # and during battle both drop
      # to two-thirds down the screen minus 20px rather than sitting at the top
      # -- both now matched exactly. **Now also implemented**: outside
      # battle, this ported model slides a timer to the bottom edge whenever the
      # (sticky, persists-across-messages) message window is currently
      # parked at the top of the screen, so the two never overlap
      # -- ported from
      # a reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: the check reads
      # the message window's own last *resolved* Y (not the raw Message
      # Options preference), which stays wherever it was last set even after
      # that message closes, since nothing ever resets it on close, and
      # which is itself downstream of RPG2000's dynamic avoid-the-hero
      # repositioning when the position is not pinned. `#open_message`
      # tracks the same "was it at the top" outcome in `@message_window_top`
      # (see its own comment) since this build has no long-lived
      # message-window-equivalent object to read a literal Y back from;
      # `#perform_teleport`/`#initialize` reset it on every fresh map visit,
      # matching a reference implementation's own map-entry rebuild of its
      # message window from scratch (initial Y below the threshold), not
      # independently confirmed against genuine RPG_RT under wine,
      # rather than the reuse a mere return from a
      # pushed menu/battle scene gets.
      def draw_timer
        battle = !@battle.nil?
        @timer_sprites ||= [nil, nil]
        draw_one_timer(0, battle)
        draw_one_timer(1, battle)
      end

      def draw_one_timer(id, battle)
        timer = @state.timer(id)
        spr = @timer_sprites[id]
        unless timer.drawn?(battle) && @windowskin
          spr.visible = false if spr
          return
        end
        spr ||= (@timer_sprites[id] = build_timer_sprite)
        spr.x = id == 0 ? 4 : SCREEN_W - TIMER_INNER_W - 4
        spr.y = if battle
                  SCREEN_H * 2 / 3 - 20
                elsif @message_window_top
                  SCREEN_H - 20
                else
                  4
                end
        spr.visible = true
        draw_timer_digits(spr.bitmap, timer)
      end

      def build_timer_sprite
        spr = Sprite.new
        spr.z = 250 # above the map, below the message / menu windows (z 300+)
        spr.bitmap = Bitmap.new(TIMER_INNER_W, TIMER_INNER_H)
        spr
      end

      # Blit `timer`'s current M:SS reading's five cells into `bmp`. The colon
      # cell blinks, ported from a reference implementation and not
      # independently confirmed against genuine RPG_RT under wine:
      # it skips the colon cell outright (leaving that 8px
      # column blank) for the first half of every real second, drawing it
      # for the second half --
      # independent of the four digit cells either side of it, which always
      # draw regardless of the blink.
      #
      # `mins` overflowing past 99 (reachable via an uncapped Control-
      # Variables-sourced Timer Set, see `Game::Timer#set`'s own comment) is
      # NOT the naive "index the digit strip past its end" garble a single
      # unbounded `mins / 10` lookup would produce -- confirmed against a
      # genuine RPG_RT.exe: for `mins` 100..999 (i.e. `mins / 10` itself a
      # two-digit 10..99), the widget draws that two-digit value's own tens
      # and ones digits in cells 0-1, the colon glyph a SECOND time in cell 3
      # (not `mins % 10`, and not `secs % 10` either), and only `secs / 10`
      # in cell 4 -- `mins % 10` and `secs % 10` are both dropped entirely,
      # not merely miscomputed. `mins >= 1000` (over 16.7 real hours) departs
      # from even this pattern and is left unhandled, same as before.
      def draw_timer_digits(bmp, timer)
        s = timer.seconds
        mins = s / 60
        secs = s % 60
        mins_tens = mins / 10
        cells =
          if mins_tens >= 10 && mins_tens < 100
            [mins_tens / 10, mins_tens % 10, nil, nil, secs / 10]
          else
            [mins_tens, mins % 10, nil, secs / 10, secs % 10]
          end
        bmp.clear
        blink_off = (timer.frames % Game::Timer::FPS) < Game::Timer::FPS / 2
        cells.each_with_index do |digit, i|
          next if digit.nil? && blink_off # a colon cell, mid-blink-off
          src_x = digit.nil? ? TIMER_COLON_SRC_X : TIMER_DIGIT_SRC_X + TIMER_DIGIT_W * digit
          bmp.blt i * TIMER_DIGIT_W, 0, @windowskin,
                  Rect.new(src_x, TIMER_DIGIT_SRC_Y, TIMER_DIGIT_W, TIMER_DIGIT_H)
        end
      end

      # Position and draw each vehicle placed on the current map. A parked vehicle
      # sits on its own tile; the ridden one follows the party's pixel position
      # (so it slides smoothly), drawn just under the hero. A vehicle on another
      # map, or one with no CharSet graphic, is hidden.
      # Pixels the airship floats above its shadow on the ground -- a full
      # tile, not half. Ported from a reference implementation, not
      # independently confirmed against genuine
      # RPG_RT under wine: its steady-state airborne altitude works out to
      # one full tile once fully airborne (this codebase never models the
      # gradual ascend/descend transition itself, only this steady-state
      # value).
      AIRSHIP_ALTITUDE = 16

      def draw_vehicles(cam_x, cam_y, px, py)
        return unless @vehicle_sprites
        @airship_shadow.visible = false
        Game::Vehicle::TYPES.each do |type|
          spr = @vehicle_sprites[type]
          v = @state.vehicle(type)
          charset = (v.placed? && v.map_id == @state.map_id) ? vehicle_charset(v) : nil
          unless charset
            spr.visible = false
            next
          end
          ridden = @state.boarded == type
          vpx = ridden ? px : v.x * TILE
          vpy = ridden ? py : v.y * TILE
          sx = vpx - cam_x - (Game::CharSet::WIDTH - TILE) / 2
          sy = vpy - cam_y - (Game::CharSet::HEIGHT - TILE)
          if type == :airship
            # The shadow marks the ground tile; the airship floats above it.
            @airship_shadow.x = vpx - cam_x
            @airship_shadow.y = vpy - cam_y
            @airship_shadow.visible = true
            sy -= AIRSHIP_ALTITUDE
          end
          spr.x = sx
          spr.y = sy
          spr.visible = true
          draw_vehicle_frame(type, v, charset, vehicle_charset_index(v), ridden)
        end
      end

      # Blit the vehicle's CharSet cell into its sprite buffer, skipping the
      # redraw when the graphic/index/direction/pose haven't changed since the
      # last frame — mirrors draw_player_frame's @last_frame memo. A *ridden*
      # vehicle walk-cycles through #player_walk_pattern, the same pattern the
      # hero's own sprite would show (see that method's comment); an unboarded
      # one always draws its standing pose 1, since it snaps tile to tile
      # rather than sliding (see the "Vehicle move-routes" note in
      # docs/TODO.md) and so has no in-tile progress to animate against.
      def draw_vehicle_frame(type, v, charset, index, ridden)
        pat = ridden ? player_walk_pattern : 1
        frame = [index, v.direction, charset.object_id, pat]
        return if frame == @vehicle_last_frame[type]
        @vehicle_last_frame[type] = frame

        rx, ry, rw, rh = Game::CharSet.frame_rect(index, v.direction, pat)
        bmp = @vehicle_bmps[type]
        bmp.clear
        bmp.blt 0, 0, charset, Rect.new(rx, ry, rw, rh)
      end

      # The CharSet graphic for a vehicle: a Set Move Route "Change Graphic"
      # override on its forced-route mirror (@vehicle_chars[v.type]) takes
      # first priority -- exactly the same not-persisted-like-the-dedicated-
      # command shape as the hero's own #player_draw_charset (see its
      # comment): the override lives on the mirror, not on `v` itself, so it
      # never survives a save/load or map transfer, only the current visit.
      # Absent that, its own graphic (set by Change Vehicle Graphic / the
      # initial placement) or the database default (System boat/ship/airship
      # name). Loaded through the shared event-charset cache; nil when it has
      # none.
      def vehicle_charset(v)
        mirror = @vehicle_chars[v.type]
        return event_charset(mirror.graphic_name) if mirror && mirror.graphic_name
        name = v.charset_name
        if (name.nil? || name.empty?)
          field = "#{v.type}_name"
          name = @db.system.send(field) if @db.system.respond_to?(field)
        end
        event_charset(name)
      end

      # The CharSet cell index to go with #vehicle_charset, from the same
      # mirror-first source. Mirrors #vehicle_charset's own name fallback: an
      # unset `v.charset_index` (never touched by Change Vehicle Graphic) must
      # fall back to the database's System boat_index/ship_index/airship_index,
      # not silently draw cell 0. Ported from a reference implementation,
      # not independently confirmed against genuine RPG_RT under wine:
      # a fresh
      # vehicle's sprite is seeded from the same database
      # name/index fields
      # together, never index-0-regardless-of-database. Gated on the same
      # empty-charset_name test as #vehicle_charset, since this ported model
      # ties both to
      # whether Change Vehicle Graphic / Set Vehicle Location's own graphic
      # slot has ever been written; a mirror override (Set Move Route's own
      # "Change Graphic") already returns above and never reaches this.
      def vehicle_charset_index(v)
        mirror = @vehicle_chars[v.type]
        return mirror.graphic_index if mirror && mirror.graphic_name
        if v.charset_name.nil? || v.charset_name.empty?
          field = "#{v.type}_index"
          return @db.system.send(field) if @db.system.respond_to?(field)
        end
        v.charset_index
      end

      # Composite the Show Picture layer into its buffer, drawing lowest-id first
      # so higher-numbered pictures sit on top. Each picture is scaled by its zoom
      # about its centre and blitted at its opacity; a picture pinned to the map
      # scrolls with the camera, otherwise it holds its screen position. (Tone is
      # carried on the picture but not yet applied — that needs native tone
      # support, like the screen tint.)
      # Redraw the picture layer, or -- when no picture would draw differently
      # from the last frame -- keep last frame's pixels. The clear alone is a
      # full-screen fill that marks the bitmap dirty, and a dirty bitmap makes
      # the display layer invalidate and re-render the whole picture sprite, so
      # redrawing "the same nothing" every frame cost real time on a low-end
      # device even on maps with no picture at all. The signature covers
      # everything #draw_picture reads; the camera and screen shake only matter
      # when a picture is actually shown (an empty layer is the same cleared
      # bitmap whatever the camera does).
      def draw_pictures(cam_x, cam_y)
        pics = @state.pictures
        sig = pictures_signature pics, cam_x, cam_y
        return if sig == @pictures_sig
        @pictures_sig = sig
        return if pics.empty? && @picture_bmp.nil?
        unless @picture_bmp
          @picture_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
          @picture_sprite.bitmap = @picture_bmp
        end
        @picture_bmp.clear
        return if pics.empty?
        # An erased id's own `Game::Picture` object lingers in `@state.
        # pictures` (cycle #159, so `#to_lsd` can still read its stale
        # fields back out onto a save -- see `Picture#erase!`'s own
        # comment) but must never draw again; `#shown?` is the explicit
        # signal for that, not `Picture#name` (deliberately left untouched
        # by an erase, so relying on emptiness here would be wrong too).
        pics.keys.sort.each do |id|
          p = pics[id]
          draw_picture p, cam_x, cam_y if p.shown?
        end
      end

      # One array describing the whole picture layer's drawn output: the shown
      # pictures' every draw input, plus the camera/shake the map-fixed and
      # shake-affected pictures hang off. Comparing arrays compares values, so
      # a picture mid-Move-Picture (interpolated per frame) reads dirty until
      # it arrives.
      def pictures_signature(pics, cam_x, cam_y)
        return [].freeze if pics.empty?
        sig = [cam_x, cam_y, @state.screen.shake_offset]
        pics.keys.sort.each do |id|
          p = pics[id]
          sig.concat [id, p.name, p.use_transparent_color, p.x, p.y, p.zoom,
                      p.opacity, p.red, p.green, p.blue, p.saturation,
                      p.fixed_to_map]
        end
        sig
      end

      # A picture's RPG2000 tone channel (0..200, 100 neutral) as an RGSS Tone
      # component (-255..255), the same conversion the screen tint uses.
      #
      # The division truncates **toward zero**, not toward negative infinity as
      # Ruby's `/` would: the reference does this in C++ integer arithmetic, so a
      # channel of 30 is -178 rather than the -179 flooring gives. One unit of
      # 255 is invisible, but a rounding rule is worth getting on purpose.
      def self.tone_channel(v)
        n = ((v || 100) - 100) * 255
        n < 0 ? -(-n / 100) : n / 100
      end

      # Whether a picture asks for any tint at all.
      def toned?(pic)
        pic.red != 100 || pic.green != 100 || pic.blue != 100 ||
          pic.saturation != 100
      end

      # The picture's source with its tone baked in, cached per (image, tone) so
      # the software tone pass runs when the tint changes rather than every
      # frame. `Bitmap#tone_blt` writes to a *separate* destination on purpose —
      # toning in place would re-tone the same pixels each frame and walk the
      # image to black — so the scratch is a same-size bitmap per cache entry.
      #
      # This rides the path pictures already draw through: the result is blitted
      # into the shared picture bitmap, which is mutated in place. It is not the
      # per-frame `Sprite#bitmap=` swap that the map-layer tint attempt found
      # does not reach the display (see the screen-effects note in docs/TODO.md).
      def toned_picture_src(pic, src)
        key = [pic.name, pic.use_transparent_color,
               pic.red, pic.green, pic.blue, pic.saturation]
        cached = @picture_tone_cache[key]
        return cached if cached
        scratch = Bitmap.new(src.width, src.height)
        tone = Tone.new(Scene::Map.tone_channel(pic.red),
                        Scene::Map.tone_channel(pic.green),
                        Scene::Map.tone_channel(pic.blue),
                        # RPG2000's saturation runs the other way from RGSS's
                        # grey: below 100 is *less* saturated, so a value under
                        # neutral becomes positive desaturation.
                        Scene::Map.tone_channel(pic.saturation) * -1)
        scratch.tone_blt src, tone
        # Bounded so a picture cycling through tones cannot grow it without
        # end; the oldest entry goes first. See #constrained_scale: each
        # cached entry is a same-size decoded bitmap, so this shrinks under
        # --render_fps the same way the named-graphic caches above do.
        @picture_tone_cache.delete(@picture_tone_cache.keys.first) if
          @picture_tone_cache.size >= constrained_scale(PICTURE_TONE_CACHE_MAX)
        @picture_tone_cache[key] = scratch
      rescue StandardError => e
        $stderr.puts "[RPG2k] picture ##{pic.id} tone failed, drawn untinted: #{e.message}"
        nil
      end

      # How many toned picture variants to keep before evicting the oldest.
      PICTURE_TONE_CACHE_MAX = 16

      def draw_picture(pic, cam_x, cam_y)
        src = picture_src(pic.name, pic.use_transparent_color)
        return unless src
        src = (toned_picture_src(pic, src) || src) if toned?(pic)
        zw = src.width * pic.zoom / 100
        zh = src.height * pic.zoom / 100
        return if zw <= 0 || zh <= 0
        # RPG2000 positions a picture by its centre.
        dx = pic.x - zw / 2
        dy = pic.y - zh / 2
        if pic.fixed_to_map
          # `cam_x` (#camera_position) already folds in the screen-shake
          # offset alongside the map scroll, so a map-fixed picture gets
          # both from this one subtraction.
          dx -= cam_x
          dy -= cam_y
        else
          # A picture that is *not* fixed to the map still shakes with the
          # screen by default, ported from a reference implementation and
          # not
          # independently confirmed against genuine RPG_RT under wine:
          # its own default
          # flags set shake-affected on for
          # every picture (RPG2000 and pre-1.12 RPG2003 have no way to turn
          # it off at all), applied unconditionally of `fixed_to_map`.
          # Previously a non-map-fixed picture (a full-screen "impact"
          # graphic, a portrait during dialogue, a HUD) held rock-steady
          # through a Shake Screen instead of jittering with the rest of
          # the view.
          dx -= @state.screen.shake_offset
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
        # The re-tile is a full-screen copy; while the camera (or an autoscroll)
        # sits still it redraws the identical picture every frame. Skip those --
        # same contract as #draw_layers' composition skip: an untouched bitmap
        # stays clean, so the display layer has nothing to re-render either.
        # Identity for the image: a new map's panorama is a new object, and
        # Bitmap#== must not be a pixel compare here.
        if @parallax_drawn && @parallax_drawn[0] == ox && \
           @parallax_drawn[1] == oy && @parallax_drawn[2].equal?(@parallax_img)
          return
        end
        @parallax_drawn = [ox, oy, @parallax_img]
        @parallax_bmp.clear
        src = Rect.new(0, 0, iw, ih)
        parallax_tiles(oy, ih, SCREEN_H, @par_loop_y).each do |dy|
          parallax_tiles(ox, iw, SCREEN_W, @par_loop_x).each do |dx|
            # #copy_blt, not #blt, for the same reason #draw_layers copies its
            # tile cache that way: the destination was just cleared, so blending
            # onto it returns the source unchanged, and #blt pays a per-pixel
            # read/blend/write for nothing. While walking this redraws the whole
            # panorama every frame -- on the Android test device the blend cost
            # ~49ms of a ~90ms frame, the memcpy ~5.
            @parallax_bmp.copy_blt dx, dy, @parallax_img, src
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

      # Compose this frame's two tile buffers, then draw the events into them.
      #
      # The tiles themselves are not re-blitted every frame. They are built into
      # a pair of cached buffers (@lower_tiles / @upper_tiles) that hold the grid
      # on whole-tile boundaries, and each frame those are copied across at the
      # sub-tile scroll offset. That copy is two full-surface blits instead of
      # ~670 per-tile ones, and the expensive build behind it only re-runs when
      # something it depends on actually changed -- see #tile_cache_valid?.
      #
      # The events cannot go in the cache: they move every frame and composite
      # into these same two buffers (see #event_target_buffer), which is exactly
      # why the buffers stay separate from the cache rather than being drawn to
      # directly.
      #
      # When nothing the buffers show has changed -- same sub-tile scroll
      # offset, cache still valid, no event redrawn differently -- the whole
      # composition is skipped and the buffers keep last frame's pixels. This
      # is the common frame while standing still, reading a message or watching
      # a still demo scene, and skipping it is what lets the display layer skip
      # too: an untouched Bitmap stays clean, so RGSS::Graphics.update does not
      # invalidate the layer sprites and LVGL re-renders only what actually
      # moved. On a low-end device the recompose plus the re-render it triggered
      # measured a third of the whole frame budget.
      def draw_layers cam_x, cam_y
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

        rebuilt = false
        unless tile_cache_valid?(first_tx, first_ty, abf, cf)
          rebuild_tile_cache(first_tx, first_ty, abf, cf)
          rebuilt = true
        end

        # Captured separately from the #events_dirty? call itself so the
        # signature recompute after the redraw below (which only exists to
        # cover the paths that skip #events_dirty?) knows when it can trust
        # the freshly-stored signatures instead of redoing the same work.
        events_checked = !rebuilt && !@layers_dirty &&
                          @drawn_ox == ox && @drawn_oy == oy &&
                          @drawn_party_y == @state.y
        return if events_checked && !events_dirty?
        @layers_dirty = false
        @drawn_ox = ox
        @drawn_oy = oy
        @drawn_party_y = @state.y

        @lower_bmp.clear
        @upper_bmp.clear
        # Shifting by taking the source from (ox, oy) rather than blitting to
        # (-ox, -oy) is the same picture -- the cache is one tile wider and
        # taller than the screen precisely so the scrolled-in edge is there to
        # copy -- and keeps every coordinate non-negative. The strip past the
        # shifted grid is what the clears above leave transparent, exactly as
        # the old per-tile loop did (it never drew there either).
        #
        # #copy_blt, not #blt: the destination was just cleared, and blending
        # onto transparency returns the source unchanged, so the two draw the
        # same picture here -- but #blt pays a per-pixel read/blend/write for
        # it, which on these two 336x256 surfaces measured ~5ms a frame.
        src = Rect.new(ox, oy, COLS * TILE - ox, ROWS * TILE - oy)
        @lower_bmp.copy_blt 0, 0, @lower_tiles, src
        @upper_bmp.copy_blt 0, 0, @upper_tiles, src

        draw_events cam_x, cam_y
        # The signatures must describe what was *just drawn*, not some earlier
        # frame: a compose forced by a rebuild or a flash may have drawn a state
        # whose signature was never stored, and a later frame that matches it
        # has to be able to trust the skip. When #events_dirty? already ran
        # above, its signatures already describe this exact frame -- redoing
        # it here would just be recomputing values that haven't changed since.
        store_event_draw_sigs unless events_checked
      end

      # Number of scalar fields #store_event_draw_sig writes per event -- see
      # its comment for what each one is.
      EVENT_DRAW_SIG_FIELDS = 10

      # Writes event `e`'s current draw signature into the flat `buf` at
      # `base..base + EVENT_DRAW_SIG_FIELDS - 1`, covering exactly what
      # #draw_event reads for it -- which CharSet cell (direction/column
      # derived from the anim inputs), where it sits (pixel position, jump
      # arc, bush depth), how it blends (translucency) and which buffer it
      # lands in (page layer, and for the same-as-hero layer the y-sort
      # against the party). Returns whether any field differs from what was
      # there before, i.e. whether this event would composite differently
      # from the last completed composition. Scalars written into a reused
      # buffer, rather than an array-of-tuples rebuilt every call, so a frame
      # with nothing to redraw costs no per-event allocation to find that out.
      def store_event_draw_sig(e, buf, base)
        ch = e[:char]
        dir = Game::EventGraphic.frame_dir(e[:anim_type], ch.direction, e[:anim_phase])
        col = Game::EventGraphic.frame_col(e[:anim_type], e[:base_pattern],
                                           e[:anim_phase], e[:moving])
        epx = event_pixel_x(e)
        epy = event_pixel_y(e)
        translucent = e[:translucent]
        jump = event_jump_offset(e)
        bush = event_bush_depth(e)
        upper = event_target_buffer(e).equal?(@upper_bmp)

        changed = buf[base] != ch.graphic_name || buf[base + 1] != ch.graphic_index ||
                  buf[base + 2] != dir || buf[base + 3] != col ||
                  buf[base + 4] != epx || buf[base + 5] != epy ||
                  buf[base + 6] != translucent || buf[base + 7] != jump ||
                  buf[base + 8] != bush || buf[base + 9] != upper

        buf[base] = ch.graphic_name
        buf[base + 1] = ch.graphic_index
        buf[base + 2] = dir
        buf[base + 3] = col
        buf[base + 4] = epx
        buf[base + 5] = epy
        buf[base + 6] = translucent
        buf[base + 7] = jump
        buf[base + 8] = bush
        buf[base + 9] = upper
        changed
      end

      # Refreshes @event_draw_sigs to the current frame's actual values,
      # resizing the buffer first if the event count changed (a page rebuild
      # swapping entries in or out).
      def store_event_draw_sigs
        needed = @events.size * EVENT_DRAW_SIG_FIELDS
        unless @event_draw_sigs && @event_draw_sigs.size == needed
          @event_draw_sigs = Array.new(needed)
        end
        @events.each_with_index do |e, i|
          store_event_draw_sig(e, @event_draw_sigs, i * EVENT_DRAW_SIG_FIELDS)
        end
      end

      # Whether any event would composite differently from the last completed
      # composition, or the event set itself changed size (page rebuilds swap
      # the entries). Signatures are stored positionally, matching @events, so
      # a rebuild that reorders or resizes the list reads as dirty -- always
      # safe, merely sometimes conservative. An event mid-Flash recomposes
      # every frame by the global flash check below -- its tone changes per
      # frame, cheaper to over-draw than to fingerprint.
      def events_dirty?
        return true if @state.player_flash || @events.any? { |e| e[:flash] }
        needed = @events.size * EVENT_DRAW_SIG_FIELDS
        unless @event_draw_sigs && @event_draw_sigs.size == needed
          store_event_draw_sigs
          return true
        end
        dirty = false
        @events.each_with_index do |e, i|
          base = i * EVENT_DRAW_SIG_FIELDS
          dirty = true if store_event_draw_sig(e, @event_draw_sigs, base)
        end
        dirty
      end

      # Whether the cached tile buffers still show what this frame wants.
      #
      # Everything the build reads has to be covered here, or the change never
      # reaches the screen. In order: the cache has been built at all; the grid
      # has not scrolled onto a different first tile (the sub-tile remainder is
      # applied at copy time, so it is deliberately *not* part of this); the
      # animation has not stepped; the map object is the same one (a teleport
      # swaps it); its tile lookups still answer the same (Tile Substitution --
      # see Game::Map#revision); and the tileset has not been swapped under us.
      # The two animation inputs are only compared when the grid actually holds
      # a tile that moves with them (see Game::ChipsetLayout.anim_input): an
      # indoor map with no water and no block C chip is the same picture in
      # every animation state, and rebuilding it on their schedule would be
      # pure waste -- .anim_c alone steps ten times a second.
      def tile_cache_valid?(first_tx, first_ty, abf, cf)
        @tiles_built &&
          @tiles_tx == first_tx && @tiles_ty == first_ty &&
          (!@tiles_uses_abf || @tiles_abf == abf) &&
          (!@tiles_uses_cf || @tiles_cf == cf) &&
          @tiles_map.equal?(@map) &&
          @tiles_revision == @map.revision &&
          @tiles_chipset.equal?(@chipset) &&
          @tiles_chipset_bmp.equal?(@chipset_bmp)
      end

      # Drop the cached tile buffers, forcing the next render to rebuild them.
      # Only needed for a change #tile_cache_valid? cannot see by itself.
      def invalidate_tile_cache
        @tiles_built = false
      end

      # Record that this tile ties the grid to one of the animation inputs,
      # returning which one (nil for a tile that moves with neither) so the
      # full build can also list the cell for #patch_anim_cells.
      def note_anim_input(id)
        case Game::ChipsetLayout.anim_input(id)
        when :abf then @tiles_uses_abf = true; :abf
        when :cf  then @tiles_uses_cf = true; :cf
        end
      end

      # Re-blit the whole visible grid into the cached buffers, on whole-tile
      # boundaries (the scroll remainder is applied when they are copied out).
      # This is the expensive path the cache exists to avoid running per frame.
      #
      # When *only* the animation inputs moved -- the grid still covers the same
      # tiles of the same map, chipset and revision -- the full pass is pure
      # waste for every cell whose tiles do not read the animation: those pixels
      # are identical. #patch_anim_cells re-blits just the cells that do (#anim_cells,
      # recorded by the full pass below), which on a real map is a handful of
      # water/animated chips rather than all 336 cells -- the difference between
      # an ~80ms rebuild ten times a second and a few ms.
      def rebuild_tile_cache(first_tx, first_ty, abf, cf)
        if @tiles_built && @anim_cells &&
           @tiles_tx == first_tx && @tiles_ty == first_ty &&
           @tiles_map.equal?(@map) && @tiles_revision == @map.revision &&
           @tiles_chipset.equal?(@chipset) && @tiles_chipset_bmp.equal?(@chipset_bmp)
          patch_anim_cells abf, cf
          @tiles_abf = abf
          @tiles_cf = cf
          return
        end

        @lower_tiles.clear
        @upper_tiles.clear
        # Whether anything actually drawn this pass moves with the animation
        # columns/frames, which is what #tile_cache_valid? consults rather than
        # assuming every map animates.
        @tiles_uses_abf = false
        @tiles_uses_cf = false
        @anim_cells = []

        (0...ROWS).each do |ry|
          (0...COLS).each do |rx|
            tx = first_tx + rx
            ty = first_ty + ry
            dx = rx * TILE
            dy = ry * TILE

            lower = @map.lower(tx, ty)
            upper = @map.upper(tx, ty)
            upper_drawn = !Game::ChipsetLayout.upper_blank?(upper)
            lower_input = note_anim_input lower
            upper_input = upper_drawn ? note_anim_input(upper) : nil
            @anim_cells << [rx, ry, lower, upper, upper_drawn] if
              lower_input || upper_input

            if @chipset_bmp
              draw_tile @lower_tiles, lower, dx, dy, abf, cf
              # Nothing to draw for the two "no upper tile here" ids -- the
              # reserved blank chip the upper layer is almost entirely made of,
              # and a raw 0. Only this call may skip them: on the lower layer 0
              # is water set 0, a real tile. See ChipsetLayout.upper_blank?.
              if upper_drawn
                # Only a starred ("above hero") upper tile belongs in the
                # buffer that composites over the player/events -- see
                # Game::ChipSet#elevated? and its ABOVE_BIT comment. An
                # unstarred one (most of a chipset's upper tiles: furniture,
                # counters, anything meant to be walked *against* rather than
                # *under*) goes in the same buffer as the lower layer instead,
                # so it draws behind a character standing on or against it
                # rather than masking them outright.
                if @chipset.elevated?(upper)
                  draw_tile @upper_tiles, upper, dx, dy, abf, cf
                else
                  draw_tile @lower_tiles, upper, dx, dy, abf, cf
                end
              end
            else
              # Fallback: solid colour blocks keyed by tile id (no chipset image).
              @lower_tiles.fill_rect dx, dy, TILE, TILE, tile_color(lower)
              @upper_tiles.fill_rect dx, dy, TILE, TILE, tile_color(upper) if upper_drawn
            end
          end
        end

        @tiles_built = true
        @tiles_tx = first_tx
        @tiles_ty = first_ty
        @tiles_abf = abf
        @tiles_cf = cf
        @tiles_map = @map
        @tiles_revision = @map.revision
        @tiles_chipset = @chipset
        @tiles_chipset_bmp = @chipset_bmp
      end

      # Re-blit only the animation-following cells of the cached grid (see
      # #rebuild_tile_cache). Reads exactly what the full pass draws for those
      # cells, so the patched grid is pixel-identical to a full rebuild.
      def patch_anim_cells(abf, cf)
        @anim_cells.each do |rx, ry, lower, upper, upper_drawn|
          dx = rx * TILE
          dy = ry * TILE
          draw_tile @lower_tiles, lower, dx, dy, abf, cf
          if upper_drawn
            if @chipset.elevated?(upper)
              draw_tile @upper_tiles, upper, dx, dy, abf, cf
            else
              draw_tile @lower_tiles, upper, dx, dy, abf, cf
            end
          end
        end
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
      # Within whichever buffer an event lands in, draw order still has to obey
      # that same y-sort against every *other* event sharing it — RPG_RT sorts
      # all same-tier characters by screen y (then x, then event id) before
      # painting, not just each one against the hero. `event_target_buffer`
      # only decides lower-vs-upper; without this sort two events on the same
      # side of the hero would layer in event-array order instead, so whichever
      # was defined later in the map always drew on top regardless of position.
      # A translucent page is blitted at half opacity. Events with no graphic
      # (empty CharSet name and no tile substitution) draw nothing.
      def draw_events(cam_x, cam_y)
        ordered = @events.sort_by { |e| [e[:char].y, e[:char].x, e[:id]] }
        ordered.each { |e| draw_event e, cam_x, cam_y }
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
        dy = epy - cam_y - (Game::CharSet::HEIGHT - TILE) - event_jump_offset(e)
        src = Rect.new(sx, sy, sw, sh)
        bush = event_bush_depth(e)
        toned = e[:flash] && flashed_charset(charset, src, e[:flash])
        if toned
          blt_bushed bmp, dx, dy, toned,
                     Rect.new(0, 0, Game::CharSet::WIDTH, Game::CharSet::HEIGHT),
                     opacity, bush
        else
          blt_bushed bmp, dx, dy, charset, src, opacity, bush
        end
      end

      # A Flash-Sprite-tinted copy of one CharSet frame, or nil when the tone
      # pass is unavailable. The frame is lifted into a scratch buffer (tone_blt
      # works on same-size bitmaps) and toned with the flash's current colour,
      # which brightens the sprite toward that colour without touching its alpha
      # — so the flash keeps the character's outline instead of painting a
      # rectangle over it.
      def flashed_charset(charset, src, flash)
        buf = flash_buffer
        buf.clear
        buf.blt 0, 0, charset, src
        out = flash_out_buffer
        out.tone_blt buf, flash_tone(flash)
        out
      rescue StandardError => e
        $stderr.puts "[RPG2k] sprite flash tone failed: #{e.message}"
        nil
      end

      # Blit an event whose graphic is a chipset tile (16x16), aligned to its
      # tile. Needs the chipset image; with none loaded (colour-block fallback)
      # the tile event is skipped.
      def draw_event_tile(e, bmp, cam_x, cam_y, opacity)
        return unless @chipset_bmp
        sx, sy, sw, sh = Game::ChipsetLayout.event_tile_rect(e[:char].graphic_index)
        epx, epy = event_pixel(e)
        dx = epx - cam_x
        dy = epy - cam_y - event_jump_offset(e)
        # A tile-graphic event wades like any other: RPG_RT sinks the sprite, not
        # a particular kind of graphic. The depth is scaled off this frame's own
        # height, which is one tile rather than the 32px charset frame.
        blt_bushed bmp, dx, dy, @chipset_bmp, Rect.new(sx, sy, sw, sh), opacity,
                   event_bush_depth(e, sh)
      end

      # Blit one map tile from the chipset image into `bmp` at (dx, dy). A plain
      # chip is a single 16x16 copy; an autotile is assembled from four 8x8
      # quarters. Empty/out-of-range ids draw nothing (id 0 is transparent).
      def draw_tile bmp, id, dx, dy, abf, cf
        # One native dispatch for the whole chip instead of a dispatch (and
        # a Rect allocation) per sub-quad -- see Bitmap#blt_quads in
        # mruby-rgss/src/lib.cxx. Animation steps redraw every animated cell,
        # so this is the map renderer's hottest mruby path.
        qs = Game::ChipsetLayout.quads(id, abf, cf)
        return if qs.empty?
        bmp.blt_quads dx, dy, @chipset_bmp, qs
      end

      # Which CharSet bitmap + index currently draw the player: ordinarily the
      # party leader's own (@charset/@charset_index), but a Set Move Route
      # "Change Graphic" targeting the hero overrides it in place on the
      # forced-route mirror character (@player_char) -- distinct from, and not
      # persisted like, the dedicated Change Hero Graphic command (see
      # perform_teleport, which drops the override on Transfer Player the same
      # way a fresh Scene::Map drops it on save-load, by clearing @player_char).
      # Reuses the event-charset cache: it is the exact same "CharSet/<name>"
      # load a map event's own graphic already goes through.
      def player_draw_charset
        if @player_char && @player_char.graphic_name
          [event_charset(@player_char.graphic_name), @player_char.graphic_index]
        else
          [@charset, @charset_index]
        end
      end

      # The hero's own walk-cycle pattern (RPG2000's 3-frame charset animation,
      # `Game::CharSet::WALK_PATTERNS` stepping with the in-tile slide) or the
      # standing pose 1 when not sliding. Shared with #draw_vehicle_frame for a
      # *ridden* vehicle: a boarded vehicle's sprite tracks the party's own
      # pixel position frame for frame (#draw_vehicles' `ridden ? px : ...`),
      # so it walks the identical cycle the hero's own sprite would have shown
      # were it not hidden underneath the vehicle's.
      def player_walk_pattern
        @moving ? Game::CharSet::WALK_PATTERNS[(@move_count / 4) % 4] : 1
      end

      def draw_player_frame
        charset, charset_index = player_draw_charset
        return unless charset
        pat = player_walk_pattern
        bush = player_bush_depth
        # The sunken depth is part of the frame key, so walking into and out of
        # tall grass redraws the sprite even though the pose has not changed.
        # The bitmap identity + index are too, so a move-route graphic change
        # forces a redraw even when direction/pose/bush all stay the same.
        frame = [@state.direction, pat, bush, charset.object_id, charset_index]
        return if frame == @last_frame
        @last_frame = frame

        rx, ry, rw, rh = Game::CharSet.frame_rect(charset_index, @state.direction, pat)
        src = Rect.new(rx, ry, rw, rh)
        # A Flash Sprite aimed at the hero tones the frame as it is laid down
        # (update_sprite_flashes invalidates @last_frame each frame it runs, so
        # the fading colour is re-applied rather than baked in once).
        toned = @state.player_flash && flashed_charset(charset, src, @state.player_flash)
        @player_bmp.clear
        if toned
          blt_bushed @player_bmp, 0, 0, toned,
                     Rect.new(0, 0, Game::CharSet::WIDTH, Game::CharSet::HEIGHT),
                     255, bush
        else
          blt_bushed @player_bmp, 0, 0, charset, src, 255, bush
        end
      end

      # Lay down a character frame with its bottom `bush` pixel rows *sunk* into
      # the tile: those rows draw at half opacity, which is how RPG2000 shows a
      # character wading through tall grass or shallow water (下半身消去). A
      # `bush` of 0 is the ordinary one-blit case, and a depth that swallows the
      # whole frame (terrain bush_depth 3, 全身半透明) is one blit at the sunken
      # opacity rather than a split.
      def blt_bushed(bmp, dx, dy, src_bmp, src, opacity, bush)
        sunk = Game::CharSet.bush_opacity(opacity)
        if bush <= 0
          bmp.blt dx, dy, src_bmp, src, opacity
        elsif bush >= src.height
          bmp.blt dx, dy, src_bmp, src, sunk
        else
          top = src.height - bush
          bmp.blt dx, dy, src_bmp, Rect.new(src.x, src.y, src.width, top), opacity
          bmp.blt dx, dy + top, src_bmp,
                  Rect.new(src.x, src.y + top, src.width, bush), sunk
        end
      end

      # How many pixel rows of the hero's sprite the tile under the party sinks.
      # A jumping hero is *over* the tile rather than in it, and a boarded party
      # draws its vehicle instead of the hero, so neither sinks.
      def player_bush_depth
        return 0 if @player_jumping || @state.boarded?
        bush_pixels_at(@state.x, @state.y)
      end

      # The same for a map event, gated on the hero's own layer: an event drawn
      # below or above the party is scenery or a treetop rather than something
      # standing in the grass, which is the layer test RPG_RT makes too.
      # `height` is the frame the depth is scaled against — the 32px charset
      # frame for an ordinary event, one tile for a tile-graphic one.
      def event_bush_depth(e, height = Game::CharSet::HEIGHT)
        return 0 unless e[:layer] == 1
        return 0 if e[:jumping]
        ch = e[:char]
        Game::CharSet.bush_pixels(bush_depth_at(ch.x, ch.y), height)
      end

      def bush_pixels_at(x, y)
        Game::CharSet.bush_pixels(bush_depth_at(x, y))
      end

      # The terrain `bush_depth` under a tile (0 where the map, the chipset or
      # the database has no terrain to ask).
      def bush_depth_at(x, y)
        row = terrain_row_at(x, y)
        return 0 unless row && row.respond_to?(:bush_depth)
        row.bush_depth || 0
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

  end
end
