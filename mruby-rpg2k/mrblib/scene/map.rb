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
      # Pixels moved per frame while stepping between tiles (must divide TILE).
      SPEED = 2

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
      def initialize parent, state, apply_access: true
        super parent
        @state = state
        # Named graphics loaded and memoized on demand -- see #cached_bitmap.
        # One hash per graphic category (rather than a single cache keyed by
        # a [kind, name] tuple) so each material's entries stay a plain
        # name -> Bitmap lookup and one category's keys can never collide
        # with another's.
        @charset_cache = {}   # CharSet/<name> -- event graphics and the
                               # party leader's own graphic share this, since
                               # both load the same files.
        @picture_cache = {}   # Picture/<name>, keyed by [name, transparent]
        @backdrop_cache = {}  # Backdrop/<name> (battle background)
        @monster_cache = {}   # Monster/<name> (battler graphics)
        @animation_cache = {} # Battle/<name> (battle animation sheets)
        @battlecharset_cache = {} # BattleCharSet/<name> (RPG2003 actor battler sprites)
        @system2_cache = {}   # System2/<name> (RPG2003 gauge card sprite sheet)
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
        # visit, matching EasyRPG's own Window_Message starting below the
        # `GetY() < 20` threshold before any message has opened yet.
        @message_window_top = false
        @started_auto = {}
        @started_common = {}
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
        @page_revision = page_revision
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        @message = nil
        @inn_window = nil
        @inn_bgm_started = false
        @inn_fading_out = false
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
        @pre_vehicle_bgm = nil
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
        # Through Mode set on the player by a forced route (Set Move Route's
        # Through Mode: Begin/End), which -- like the genuine runtime -- is a
        # standing property of the hero, not scoped to the route that set it: it
        # keeps affecting ordinary input-driven walking once the route ends,
        # however that happened. Halt All Movement (Cancel All Designated Moves)
        # deliberately does not clear it (see #apply_halt_request) -- RPG_RT
        # aborts an in-progress route without unwinding its side effects, so a
        # route cancelled mid-Through-Mode leaves the hero stuck pass-through.
        @player_through = false

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
        # Move Event targets that resolved to a currently-hidden map event
        # (see #apply_move_request) -- once stuck, permanently so, matching a
        # freeze that never clears on its own.
        @stuck_move_targets = []

        # Player pixel position and step state. `player_jumping` marks the slide
        # as a hop, which is lifted along an arc (see player_jump_offset).
        @moving = false
        @move_count = 0
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
        # latter (see the comment there), matching EasyRPG's
        # UpdateEncounterSteps, which UpdateNextMovementAction only calls from
        # the input-driven path.
        @player_forced_step = false
        # The wandering-monster encounter table row #check_random_encounter is
        # on (EasyRPG's Game_Player::last_encounter_idx) -- a plain runtime
        # counter, not part of the save (see Game::State#encounter_total).
        @encounter_idx = 0

        setup_sprites
        render
      end

      attr_reader :state

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
        # Held by no sprite (see #setup_sprites), so nothing else frees these.
        @lower_tiles.dispose if @lower_tiles
        @upper_tiles.dispose if @upper_tiles
        @chipset_bmp.dispose if @chipset_bmp
        @parallax_img.dispose if @parallax_img
      end

      def update
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
        # *under* the picture layer. EasyRPG Player's own Drawable::Priority
        # enum (src/drawable.h) orders `Priority_PictureOld = 120 << z_offset`
        # above `Priority_BattleAnimation = 110 << z_offset` -- the ordering
        # every standard RPG2000/RPG2003 database uses, since Sprite_Picture's
        # constructor (src/sprite_picture.cpp) seeds every picture at
        # `Priority_PictureOld + pic_id` unconditionally, only overridden by
        # `Priority_PictureNew` (100, *below* BattleAnimation) when
        # `feature_priority_layers` -- `Player::IsMajorUpdatedVersion()` --
        # detects the "RPG2000 Value!" English re-release or a specifically
        # patched RPG2003 English runtime (`ultimate_rt_eb.dll`), neither of
        # which this project has any file/version signal to detect from a
        # plain .ldb/.lmt/.lmu triple. So "pictures always draw over a map
        # animation" is correct for every ordinary database this runtime reads.
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
        @flash_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @flash_sprite.bitmap = @flash_bmp
        @flash_sprite.opacity = 0
        @flash_rgb = nil


        # Weather Effects: rain / snow particles drawn on a screen-sized layer
        # (under the flash / fade overlays), animated by @anim_frame.
        @weather_sprite = Sprite.new
        @weather_sprite.z = 430
        @weather_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @weather_sprite.bitmap = @weather_bmp
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
      # Particle counts by strength (0..2) -- EasyRPG's own
      # num_rain_or_snow_particles table (src/weather.cpp) is the literal
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
      def draw_weather_particle(type, i)
        x0 = (i * 97) % SCREEN_W
        y0 = (i * 59) % SCREEN_H
        if type == WEATHER_RAIN
          y = (y0 + @anim_frame * 8) % SCREEN_H
          x = (x0 - @anim_frame * 2) % SCREEN_W
          @weather_bmp.fill_rect x, y, 1, 6, RAIN_COLOR
        else
          y = (y0 + @anim_frame * 3) % SCREEN_H
          x = (x0 + weather_drift(i)) % SCREEN_W
          @weather_bmp.fill_rect x, y, 2, 2, SNOW_COLOR
        end
      end

      # A small side-to-side snow drift, from a triangle wave over @anim_frame.
      def weather_drift(i)
        phase = (@anim_frame / 8 + i) % 8
        phase < 4 ? phase : 8 - phase
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
        @picture_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @picture_sprite.bitmap = @picture_bmp
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
          page = selected[1]
          @events.push(build_event(id, ev, page, restore_route_index: restore_route_index))
        end
        rebuild_event_tiles
      rescue StandardError => e
        $stderr.puts "[RPG2k] event setup failed, map runs with no events: #{e.message}"
        @events = []
        @event_tiles = {}
        @event_tiles_by_pos = {}
      end

      def build_event(id, ev, page, restore_route_index: true)
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
        # the same one (see #pages_changed?).
        { id: id, char: ch, page: page, trigger: page_trigger(page),
          commands: page_commands(page), move_type: move_type, route: route,
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
          moving: false, disp_x: x, disp_y: y, move_count: TILE,
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
        @events.each do |e|
          ch = e[:char]
          @state.map_event_positions[e[:id]] = [ch.x, ch.y, ch.direction]
          @state.map_event_route_index[e[:id]] = e[:route].index if e[:route]
          # Also keeps @event_last_position current for #event_id_at's hidden-
          # event fallback -- see #build_events' seeding comment.
          @event_last_position[e[:id]] = [ch.x, ch.y, ch.direction]
        end
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
      def page_move_speed(page); page_field(:move_speed, 3) { page.move_speed || 3 }; end
      def page_move_frequency(page); page_field(:move_frequency, 3) { page.move_frequency || 3 }; end
      def page_move_route(page); page_field(:move_route, nil) { page.move_route }; end
      def page_charset_name(page); page_field(:charset_name, nil) { page.charset_name }; end
      def page_charset_index(page); page_field(:charset_index, 0) { page.charset_index || 0 }; end
      def page_layer(page); page_field(:layer, 0) { page.layer || 0 }; end
      def page_overlap_forbidden(page); page_field(:overlap_forbidden, false) { page.overlap_forbidden ? true : false }; end
      def page_pattern(page); page_field(:pattern, 1) { p = page.pattern; (0..2).include?(p) ? p : 1 }; end
      def page_anim_type(page); page_field(:anim_type, 0) { page.animation_type || 0 }; end
      def page_translucent(page); page_field(:translucent, false) { page.translucent ? true : false }; end

      # -- event execution ----------------------------------------------------

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
      # Verified against EasyRPG Player's actual C++ source rather than
      # guessed at: `Game_Map::UpdateForegroundEvents` (src/game_map.cpp)
      # drives the single shared foreground interpreter inside a `while
      # (!interp.IsRunning() && !interp.ReachedLoopLimit())` loop -- the
      # instant a pushed event's own command list empties out
      # (`IsRunning()` false), that same call immediately rescans every
      # `IsWaitingForegroundExecution()` map/common event and pushes another
      # one too, all sharing one `Game_Interpreter::loop_count`/`loop_limit`
      # (10000) budget rather than ending the frame the first time the
      # interpreter goes idle. `Scene::Map#update`'s own foreground dispatch
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
          @interpreter.event_id = ev[:id]
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
      # there is nothing sound to reuse.
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
      # previous @parallels to reuse from, so #new_parallel instead
      # fast-forwards a fresh interpreter to whatever position #step_parallel
      # last recorded on Game::State before the game was last saved (see
      # Game::State#common_event_progress) -- a coarser, index-only
      # continuation, since nothing was kept alive across a save to resume with
      # full fidelity.
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
        # Common events are pushed before map events, matching real RPG_RT's
        # own fixed frame order: `Game_Map::Update` (src/game_map.cpp) always
        # calls `UpdateCommonEvents()` before `UpdateMapEvents()`, with no
        # interleaving by id across the two groups -- `Game_CommonEvent`
        # (src/game_commonevent.cpp) only ever builds an interpreter for a
        # Parallel-trigger common event, so that call is this engine's exact
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
      def new_parallel(commands, gate_switch, event, common_event_id)
        it = Game::Interpreter.new(@state)
        it.resolver = @interpreter.resolver
        it.map_info = self
        resume_at = common_event_id && @state.common_event_progress[common_event_id]
        if resume_at
          it.start_at(commands, resume_at)
        else
          it.start(commands)
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
        # @parallels mid-loop (see erase_event).
        @parallels.dup.each { |p| step_parallel(p) }
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
        p = @parallels.find { |pp| pp[:interp].equal?(owner) }
        step_parallel(p) if p
      end

      def step_parallel(p)
        return if p[:gate_switch] && !@state.switches[p[:gate_switch]]
        it = p[:interp]
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
          # stutter", the parallel-process half. Other wait kinds keep their
          # old one-frame-per-call pacing.
          unless (wait_kind == :wait || wait_kind == :animation) && !it.waiting?
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

      # Snapshot a Common Event Parallel Process's current position onto
      # Game::State, so a fresh Scene::Map built later from this state (a
      # genuine save/load, not a Transfer Player -- see #build_parallels) can
      # resume it instead of restarting at the top. Only overwrites the stored
      # checkpoint when the interpreter's position is cleanly capturable right
      # now (see Game::Interpreter#resumable_index); a tick that returns nil
      # (mid a nested Call Event) simply leaves the last known-good checkpoint
      # in place rather than clearing it. A no-op for a map event's own
      # parallel process (p[:common_event_id] is nil there), which never gets a
      # checkpoint at all -- it always restarts fresh, unchanged.
      def record_parallel_progress(p)
        return unless p[:common_event_id]
        idx = p[:interp].resumable_index
        @state.common_event_progress[p[:common_event_id]] = idx if idx
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
        elsif it.wait_kind == :sprite_flash
          # Flash Sprite's own wait flag, the parallel-process equivalent of
          # the :screen/:picture cases just above.
          it.resume unless sprite_flashing?
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
      # faced event turns toward the player before its commands run.
      # RPG_RT looks through at most three counter tiles in a row before giving
      # up (EasyRPG's `Game_Player::CheckActionEvent`).
      MAX_COUNTER_REACH = 3

      def try_action_trigger
        return if event_busy?
        return unless Input.trigger?(Input::C)
        # An action event **under the player** fires too: RPG_RT checks the tile
        # the party is standing on before the one it faces, which is how a
        # trigger-0 event on a doorway tile answers the action button. Overlap
        # answers the button regardless of priority type, so this check alone
        # is how a below/above-characters action event (see below) is ever
        # reachable at all.
        here = event_at(@state.x, @state.y)
        return start_event(here, true) if actionable?(here)

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
          disembark_vehicle
          true # aboard, the action button belongs to the vehicle
        else
          board_vehicle
        end
      end

      # Board a vehicle placed on the current map at the party's tile (airship) or
      # the tile it faces (boat / ship, boarded from the shore). Steps onto the
      # vehicle's tile and returns whether a vehicle was boarded.
      def board_vehicle
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        Game::Vehicle::TYPES.each do |type|
          v = @state.vehicle(type)
          next unless v.placed? && v.map_id == @state.map_id
          if v.x == @state.x && v.y == @state.y
            board_as(type)
            return true
          elsif v.x == fx && v.y == fy
            @state.x = fx
            @state.y = fy
            board_as(type)
            return true
          end
        end
        false
      end

      # Mark the party aboard `type` and switch to the vehicle's BGM.
      def board_as(type)
        @state.boarded = type
        play_vehicle_bgm(type)
      end

      # Step off the ridden vehicle. A boat / ship disembarks onto the tile
      # ahead when it is walkable on foot, leaving the vehicle on the tile the
      # party vacates; the airship instead lands in place — RPG_RT tests the
      # terrain directly under it, not the tile ahead, since it has no "shore"
      # to step onto. Either way a no-op when the landing spot is blocked (the
      # party stays aboard).
      def disembark_vehicle
        if @state.boarded == :airship
          return unless airship_landable?(@state.x, @state.y)
          follow_vehicle # the airship is left where it touched down
          @state.boarded = nil
          restore_pre_vehicle_bgm # the map BGM resumes
          return
        end
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        return unless passable?(fx, fy, @state.direction)
        follow_vehicle # the vehicle is left where the party is getting off
        @state.x = fx
        @state.y = fy
        @state.boarded = nil
        restore_pre_vehicle_bgm # the map BGM resumes
      end

      # Whether the airship may land on tile (x, y): the database terrain's
      # airship_land flag (default true), with no map event occupying the
      # ground underneath at all — yado.tk: an airship can never land on a
      # tile a map event occupies, regardless of terrain. Flying itself
      # ignores events entirely (#vehicle_passable?'s airship branch never
      # reads @event_tiles, so the airship can cruise directly over a
      # below-characters event a walking hero would just as happily overlap),
      # so this is the one place events reach it at all — and, once they do,
      # this follows the same vehicle-specific rule #vehicle_passable? already
      # uses for a boat/ship (`!blocker[:char].through`): any layer blocks,
      # priority-type/overlap_forbidden gating is ignored entirely, and only
      # the blocking event's own Through Mode lets it through. A tile with no
      # terrain data (a bare fixture) is landable.
      def airship_landable?(x, y)
        return false unless @map.in_bounds?(x, y)
        return false if blockers_at(x, y).any? { |b| !b[:char].through }
        row = terrain_row_at(x, y)
        return true if row.nil?
        row.airship_land ? true : false
      end

      # Play `music` ({ name:, volume:, tempo: }) as the current BGM, the one
      # choke point every BGM-switching helper below (vehicle/battle/victory/
      # inn, play and restore alike) funnels through. RPG_RT's BGM is a
      # single channel with one real entry point on the native side --
      # EasyRPG's `Game_System::BgmPlay` (`src/game_system.cpp`) -- and it
      # special-cases re-selecting the file already playing: "Same music:
      # Only adjust volume and speed" rather than stopping and restarting it,
      # for *every* caller, not just the Play BGM event command (battle entry
      # itself calls the identical `BgmPlay`, per `Scene_Battle::Init` in
      # `src/scene_battle.cpp`: `BgmPlay(GetSystemBGM(BGM_Battle))`). This
      # codebase already ported that for the event-command path
      # (`Game::Interpreter#play_audio`'s `:bgm` branch, same
      # `same_file_already_playing` idiom, volume-in-place included) but every
      # helper here still called `RGSS::Audio.bgm_play` unconditionally, so a
      # battle/vehicle/inn BGM configured to the exact same file as whatever
      # was already playing broke and restarted it from the top instead of
      # continuing seamlessly across the transition — including the
      # asymmetric case of restoring a field track this scene itself never
      # actually stopped. Tempo/pan are still not adjusted in place on a
      # same-file call: SDL_mixer has no live pitch control for a playing
      # stream, and pan is not wired as a BGM parameter at all, the same
      # already-documented limitation the event-command path carries.
      def play_bgm(music)
        same_file_already_playing = @state.current_bgm && @state.current_bgm[:name] == music[:name]
        if same_file_already_playing
          RGSS::Audio.bgm_volume(music[:volume] || 100)
        else
          RGSS::Audio.bgm_play(music[:name], music[:volume] || 100, music[:tempo] || 100)
        end
        @state.current_bgm = music
      end

      # Play the vehicle's own BGM — a Change System BGM (10660) override for
      # its slot when one is set, else the database System boat / ship /
      # airship music — remembering the BGM that was playing so
      # #restore_pre_vehicle_bgm can bring it back on disembark. A vehicle
      # with no configured BGM (override or database) leaves the current
      # music playing.
      def play_vehicle_bgm(type)
        music = vehicle_bgm(type)
        return unless music
        @pre_vehicle_bgm = @state.current_bgm
        play_bgm(music)
      rescue StandardError => e
        $stderr.puts "[RPG2k] vehicle BGM failed: #{e.message}"
      end

      # Restore the BGM that was playing before the party boarded (the map BGM).
      # A no-op when boarding did not switch the music.
      def restore_pre_vehicle_bgm
        bgm = @pre_vehicle_bgm
        @pre_vehicle_bgm = nil
        return unless bgm && bgm[:name] && !bgm[:name].empty?
        play_bgm(bgm)
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
      # matching RPG_RT's own no-op on an empty Music struct
      # (Game_System::BgmPlay does nothing for a blank filename).
      def play_battle_bgm
        music = battle_bgm
        return unless music
        @pre_battle_bgm = @state.current_bgm
        play_bgm(music)
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle BGM failed: #{e.message}"
      end

      # The battle BGM to play as { name:, volume:, tempo: }, or nil when
      # neither source names a file. Prefers a Change System BGM override for
      # the battle slot over the database's own System battle_music -- the
      # same override-then-default idiom #system_se already uses for Change
      # System SFX overrides, extended to BGM now that a battle actually
      # plays music to override.
      def battle_bgm
        ov = @state.system_bgm[SYSTEM_BGM_BATTLE]
        if ov && ov[:name] && !ov[:name].empty?
          return { name: ov[:name], volume: ov[:volume] || 100,
                    tempo: ov[:tempo] || 100 }
        end
        name = music_name(db.system.battle_music)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(db.system.battle_music),
          tempo: music_tempo(db.system.battle_music) }
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
      def play_victory_bgm
        music = victory_bgm
        return unless music
        RGSS::Audio.me_play(music[:name], music[:volume] || 100, music[:tempo] || 100)
      rescue StandardError => e
        $stderr.puts "[RPG2k] victory BGM failed: #{e.message}"
      end

      # The victory BGM to play as { name:, volume:, tempo: }, or nil when
      # neither source names a file. Prefers a Change System BGM override for
      # the victory slot over the database's own System battle_end_music --
      # the same override-then-default idiom #battle_bgm uses for the battle
      # slot.
      def victory_bgm
        ov = @state.system_bgm[SYSTEM_BGM_VICTORY]
        if ov && ov[:name] && !ov[:name].to_s.empty?
          return { name: ov[:name], volume: ov[:volume] || 100,
                    tempo: ov[:tempo] || 100 }
        end
        name = music_name(db.system.battle_end_music)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(db.system.battle_end_music),
          tempo: music_tempo(db.system.battle_end_music) }
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
        bgm = @pre_battle_bgm
        @pre_battle_bgm = nil
        return unless bgm && bgm[:name] && !bgm[:name].empty?
        RGSS::Audio.me_stop
        play_bgm(bgm)
      rescue StandardError => e
        $stderr.puts "[RPG2k] restoring BGM after battle failed: #{e.message}"
      end

      # System BGM slot index for Change System BGM (10660)'s inn override,
      # matching EasyRPG's Game_System::sys_bgm enum (Battle 0, Victory 1,
      # Inn 2, ...) -- the same enum VEHICLE_SYSTEM_BGM_SLOT below resolves
      # its own slots against.
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

      # The inn BGM to play as { name:, volume:, tempo: }, or nil when
      # neither source names a file. Prefers a Change System BGM override for
      # the inn slot over the database's own System inn_music -- the same
      # override-then-default idiom #battle_bgm / #vehicle_bgm already use.
      def inn_bgm
        ov = @state.system_bgm[SYSTEM_BGM_INN]
        if ov && ov[:name] && !ov[:name].to_s.empty?
          return { name: ov[:name], volume: ov[:volume] || 100, tempo: ov[:tempo] || 100 }
        end
        name = music_name(db.system.inn_music)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(db.system.inn_music),
          tempo: music_tempo(db.system.inn_music) }
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

      # System BGM slot indices for Change System BGM (10660), matching
      # EasyRPG's Game_System::sys_bgm enum (Battle 0, Victory 1, Inn 2,
      # Boat 3, Ship 4, Airship 5, GameOver 6) — the boat/ship/airship slots
      # sit between the ones the battle and game-over BGM already resolve.
      VEHICLE_SYSTEM_BGM_SLOT = { boat: 3, ship: 4, airship: 5 }.freeze

      # The BGM to play for vehicle `type` as { name:, volume:, tempo: }, or
      # nil when neither source names a file. Prefers a Change System BGM
      # override for the vehicle's slot over the database's own boat / ship /
      # airship music — the same override-then-default idiom #system_se
      # already uses for Change System SFX.
      def vehicle_bgm(type)
        slot = VEHICLE_SYSTEM_BGM_SLOT[type]
        ov = slot && @state.system_bgm[slot]
        if ov && ov[:name] && !ov[:name].to_s.empty?
          return { name: ov[:name], volume: ov[:volume] || 100, tempo: ov[:tempo] || 100 }
        end
        field = "#{type}_music"
        return nil unless @db.system.respond_to?(field)
        bgm = @db.system.send(field)
        name = music_name(bgm)
        return nil if name.nil? || name.empty?
        { name: name, volume: music_volume(bgm), tempo: music_tempo(bgm) }
      end

      # A parsed BGM chunk exposes file / volume / pitch; read them defensively so
      # a bare fixture that omits a field still works.
      def music_name(m); m.file rescue nil; end
      def music_volume(m); (m.volume rescue nil) || 100; end
      def music_tempo(m); (m.pitch rescue nil) || 100; end

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
      # A boat / ship's event-blocking rule is a real divergence from the
      # hero's own (yado.tk quirk): the walking hero is priority-type-gated —
      # a below/above-characters event with a passable graphic never blocks it
      # (see `passable?` / `char_passable?`, which key off `blocker[:layer]`).
      # A ship ignores that entirely and just asks whether the blocking
      # event's *own* move route has Through Mode on
      # (`blocker[:char].through`, the same accessor `char_passable?` and
      # `passable?` check for the mover's own Through Mode) — a below-
      # characters, passable-graphic event the hero strolls over still stops
      # a ship dead unless that specific event has Through Mode enabled.
      def vehicle_passable?(x, y, dir, type)
        return false unless @map.in_bounds?(x, y)
        row = terrain_row_at(x, y)
        if type == :airship
          return true if row.nil?
          return row.airship_pass ? true : false
        end
        return false if blockers_at(x, y).any? { |b| !b[:char].through }
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
        @events.each { |e| step_event(e, allow_trigger: allow_trigger) }
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
          status = forced.step(ch, @world) unless forced.done?
          if forced.done? # revert to page movement
            e[:forced_route] = nil
            # The page's own Move Frequency reasserts itself once the forced
            # route finishes -- a Frequency Up/Down sub-command inside that
            # route must not go on pacing the event after control reverts to
            # its page, only for the duration of the route that issued it.
            ch.move_frequency = page_move_frequency(e[:page])
          end
        elsif e[:route]
          status = e[:route].step(ch, @world) unless e[:route].done?
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
        return false unless e[:move_count] < TILE
        # A jump that lands on its own tile moves the sprite nowhere but is
        # still in progress, so it cannot be recognised by the displacement.
        e[:jumping] ||
          e[:disp_x] != e[:char].x || e[:disp_y] != e[:char].y
      end

      # Move an autonomous event one step in `dir`. Walking into the player fires
      # an event-touch (trigger 2) event instead of moving; any other obstacle
      # just turns the event to face it. `allow_trigger: false` (the "keep
      # moving during an open message" pass, see #step_events) still turns the
      # event to face the player but never starts one -- there is only one
      # foreground @interpreter, already mid-message, and RPG2000 never shows
      # two message windows at once, so a second event's commands have nowhere
      # safe to run until the first message closes.
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
        deindex_event_tile(e, ox, oy)
        index_event_tile(e, e[:char].x, e[:char].y)
        start_event_slide(e, ox, oy)
      end

      # Begin a render slide for event `e` that just stepped off (ox, oy): the
      # sprite eases from that tile to its new one over TILE/SPEED frames.
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
          e[:jumping] = jumped
        else
          e[:disp_x] = e[:char].x
          e[:disp_y] = e[:char].y
          e[:move_count] = TILE
          e[:jumping] = false
        end
      end

      # How far event `e`'s sprite is lifted off the ground this frame, in
      # pixels: 0 unless a jump is in progress, otherwise RPG_RT's arc.
      #
      # A port of EasyRPG's `Game_Character::GetJumpHeight`, kept in its own
      # 256-per-tile units so the formula reads as it does there: the height
      # rises and falls linearly with the remaining step, peaking at the
      # midpoint, and is then stretched -- doubled while small (h < 5), offset
      # by 4 through h < 13, and capped at a flat 16 beyond that -- which is
      # what makes the hop leave the ground sharply, hang near the top, and
      # never rise past a full tile. The peak is exactly 16px on a 16px tile,
      # so a jumping sprite clearly leaves its row without overshooting it.
      # (This offset/cap shape was previously mis-ported as an uncapped `h +
      # 5`, peaking at 21px -- 5px, ~31%, past the real arc's own ceiling --
      # now corrected to match EasyRPG's actual source exactly.)
      #
      # The lift is applied where the sprite is blitted, not inside #event_pixel:
      # RPG_RT raises the drawn character without moving it, so its logical
      # position -- what the camera follows and what the draw order sorts on --
      # stays on the ground.
      JUMP_STEP_UNITS = 256              # EasyRPG's SCREEN_TILE_SIZE
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
        # Remembered so a page refresh cannot resurrect it: an Erase Event lasts
        # for the rest of the visit to the map, whatever its conditions do next.
        @erased_events[ev[:id]] = true
        tile = [ev[:char].x, ev[:char].y]
        deindex_event_tile(ev, tile[0], tile[1])
        # Frozen at the tile it occupied right before erasure -- an erased
        # event cannot move any further, and #event_id_at still needs it (see
        # there) even though it no longer blocks or draws.
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
      # RPG_RT re-selects them whenever those change (its `Game_Map::
      # SetNeedRefresh`, set by Control Switches / Variables, Change Items and
      # Change Party Member -- plus, for a Timer condition, every tick of the
      # countdown). Rather than flagging each command — which silently misses
      # any path that is not an event command, like using an item from the menu
      # — this watches the revision counters those carry, so every writer is
      # covered by construction. Timer1's seconds figure has no revision
      # counter of its own, but it only ever changes once a second (it is
      # already whole seconds -- #timer_seconds), so folding it into the sum
      # catches exactly the frame a Timer condition's threshold is crossed
      # without sweeping every frame in between.
      def page_revision
        rev(@state.switches) + rev(@state.variables) + rev(@state.party) +
          @state.timer_seconds
      end

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
        rev = page_revision
        return if rev == @page_revision
        @page_revision = rev
        return unless pages_changed?
        rebuild_events_preserving_positions
      rescue StandardError => e
        $stderr.puts "[RPG2k] event page refresh failed: #{e.message}"
      end

      # Whether any event's conditions now pick a different page than the one it
      # is running. Walks the *map's* events rather than the live list, so it
      # also catches an event that has no active page at all right now and has
      # just gained one — those are absent from @events entirely.
      def pages_changed?
        evs = @map.unit.events
        return false unless evs
        live = {}
        @events.each { |e| live[e[:id]] = e }
        changed = false
        evs.each do |id, src|
          next if changed || @erased_events[id]
          selected = Game::EventPage.select(src.pages, @state.switches,
                                            @state.variables, @state.party,
                                            @state.timer_seconds, @state.timer2_seconds)
          page = selected && selected[1]
          e = live[id]
          changed = true unless page.equal?(e && e[:page])
        end
        changed
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
      # until it finishes" flag off. EasyRPG's own `Game_Interpreter_Map::
      # CommandShowBattleAnimation` always calls `Game_Screen::
      # ShowBattleAnimation` regardless of that flag — it only gates whether the
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
      # cuts the first off" fix, settled the same way against EasyRPG's actual
      # C++ source: `Game_Screen::ShowBattleAnimation` (`src/game_screen.cpp`)
      # is a bare unconditional `animation.reset(new BattleAnimationMap(...))`
      # with no check on whether the *new* request itself carries a wait flag —
      # only the *issuing* interpreter's own resulting wait is conditional on
      # that (`_state.wait_time = frames` only when the flag is set), the
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
      # renderer tones their CharSet frame with; a target that cannot be resolved
      # (a vehicle, or an unknown event id) simply flashes nothing.
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
          @player_flash = flash
          @last_frame = nil # force the hero's cached frame to be re-toned
          flash
        when 0, MOVE_TARGET_THIS
          this_event ? (this_event[:flash] = flash) : nil
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
        @last_frame = nil if @player_flash
        @player_flash = tick_flash(@player_flash)
        @events.each { |e| e[:flash] = tick_flash(e[:flash]) if e[:flash] }
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
      def perform_event_save
        if @event_save_load
          @event_save_load = false
          @interpreter.resume
        else
          @event_save_load = true
          @parent.push Scene::SaveLoad.new(@parent, @state, :save)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Save Menu failed: #{e.message}"
        @event_save_load = false
        @interpreter.resume
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
      def perform_event_load
        if @event_save_load
          @event_save_load = false
          @interpreter.resume
        else
          @event_save_load = true
          @parent.push Scene::SaveLoad.new(@parent, nil, :load)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Load Menu failed: #{e.message}"
        @event_save_load = false
        @interpreter.resume
      end

      # Exit Game (5002, RPG2003): quit, the way the title screen's Shutdown
      # entry does.
      def perform_exit_game
        @interpreter.stop
        exit
      end

      # Open Main Menu (11950): push the field menu over the map, then resume the
      # event once the player closes it again. `@event_menu` marks that this
      # scene is waiting on its own menu, so the event stays paused for exactly
      # one visit instead of re-opening it every frame.
      def perform_event_menu
        if @event_menu
          @event_menu = false
          @interpreter.resume
        else
          @event_menu = true
          @parent.push Scene::Menu.new(@parent, @state)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Main Menu failed: #{e.message}"
        @event_menu = false
        @interpreter.resume
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
          type = Game::Vehicle::TYPES[r[:target] - MOVE_TARGET_BOAT]
          force_vehicle_route(type, route, r[:frequency])
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
            # A genuinely nonexistent event id is a different, unmodelled
            # error-dialog case (see the "Concrete runtime error catalog" TODO
            # entry) and does not land here.
            @stuck_move_targets << r[:target]
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
          v = @state.vehicle(Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT])
          [v.x, v.y]
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
          move_vehicle_to(Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT], x, y)
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
      end

      # Give vehicle `type` a forced route (Move Event / Set Move Route
      # targeting a boat/ship/airship). A no-op when the vehicle is not
      # placed on the current map (nothing here simulates a map that is not
      # loaded) or is currently ridden -- the party's own #follow_vehicle
      # already claims the ridden vehicle's position every frame, and RPG_RT
      # has no documented "pilot the vehicle you're standing on by event"
      # interaction, so the simplest, safest reading is that boarding and a
      # route on the same vehicle just don't mix.
      def force_vehicle_route(type, route, freq)
        v = @state.vehicle(type)
        return unless v.placed? && v.map_id == @state.map_id
        return if @state.boarded == type
        ch = (@vehicle_chars[type] ||= Game::Character.new(v.x, v.y, v.direction))
        ch.x = v.x
        ch.y = v.y
        ch.direction = v.direction
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
        route.step(ch, @vehicle_worlds[type]) unless route.done?
        v = @state.vehicle(type)
        v.x = ch.x
        v.y = ch.y
        v.direction = ch.direction
        @vehicle_routes[type] = nil if route.done?
      rescue StandardError => e
        $stderr.puts "[RPG2k] vehicle move route failed: #{e.message}"
        @vehicle_routes[type] = nil # drop a broken route so Proceed does not hang
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
        # not on-foot chipset passability -- EasyRPG's own Game_Player::
        # MakeWay (src/game_player.cpp) unconditionally delegates to
        # GetVehicle()->MakeWay whenever IsAboard(), with no separate branch
        # for move-route-driven movement vs. ordinary input movement, so a
        # boat/ship/airship's own boat_pass/ship_pass/airship_pass clearance
        # (or an airship's own event-blind rule) applies here exactly as it
        # already does for #try_move (the input-driven path, see
        # @state.boarded? above).
        world = @state.boarded? ? @vehicle_worlds[@state.boarded] : @world
        @player_route.step(@player_char, world) unless @player_route.done?
        # Mirror Through Mode out to the standing flag every step (not just when
        # the route ends), so a Halt All Movement mid-route sees whatever the
        # route had set so far rather than the mirror's now-discarded state.
        @player_through = @player_char.through
        @state.direction = @player_char.direction
        if @player_char.x != ox || @player_char.y != oy || @player_char.jumped
          start_player_slide
        end
        @player_route = nil if @player_route.done?
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
        @player_jumping = @player_char.jumped
        @player_forced_step = true
      end

      # The party's own per-frame slide rate: SPEED on foot, in a Boat, or in a
      # Ship (EasyRPG's Game_Vehicle constructor, src/game_vehicle.cpp, gives
      # both `MoveSpeed_normal`, identical to the player's own default), but
      # doubled while aboard the Airship (`MoveSpeed_double`). Boarding stashes
      # no separate "preboard speed" the way EasyRPG's Game_Player does --
      # unlike EasyRPG, this engine has no general per-character move-speed
      # model to save and restore (Speed Up/Down move-route commands only
      # ever touch an NPC/forced-route Character mirror, never the player's
      # own walking rate), so the airship's speedup is derived straight from
      # `@state.boarded` each frame instead, reverting for free the instant
      # #disembark_vehicle clears it.
      def player_slide_speed
        @state.boarded == :airship ? SPEED * 2 : SPEED
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
        @move_count += player_slide_speed
        if @move_count >= TILE
          @state.x = @dest_x
          @state.y = @dest_y
          @moving = false
          @move_count = 0
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
        e[:forced_route].step(ch, @world) unless e[:forced_route].done?
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
      # verified against EasyRPG Player's actual C++ source rather than
      # guessed at: `Game_Map::CheckOrMakeWayEx` (`src/game_map.cpp`) blocks
      # every character type, the player included, on a Boat/Ship's own tile,
      # but only checks the Airship when `self.GetType() != Game_Character::
      # Player` -- an unridden airship is a walkable, non-blocking tile for
      # the party on foot, but still a solid obstacle for every other
      # character (a map event's autonomous/custom-route movement, or the
      # player's own forced Set Move Route mirror, `@player_char`). A vehicle
      # currently being ridden still counts here: it tracks the party's own
      # tile every frame (`#follow_vehicle`), so this only ever blocks a
      # *different* character trying to step onto the party's own tile, never
      # the ridden vehicle's own movement (driven through the entirely
      # separate `#vehicle_passable?`/`VehicleWorld`, never through this
      # method or `#char_passable?`/`#passable?`).
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
      # Layer gates the occupancy half exactly the way EasyRPG Player's own
      # `WouldCollide` (`src/game_map.cpp`) does: two characters only collide
      # over layer when their priority types match *exactly* --
      # `self.GetLayer() == other.GetLayer()` -- not when either happens to
      # be LAYER_SAME specifically. Two below-characters events collide with
      # each other exactly as two same-characters ones do; a below-layer
      # mover and an above-layer (or same-layer) blocker pass through each
      # other, layers differing either way. The hero's own layer is always
      # effectively LAYER_SAME (`Game_Player` never overrides `GetLayer`, so
      # it keeps `Game_Character`'s LAYER_SAME default) -- `character.layer`
      # already reads that way whenever `character` is the party's own
      # forced Set Move Route mirror, so this single check covers the hero
      # correctly with no special-casing.
      #
      # `overlap_forbidden` is different: `WouldCollide` only ever consults
      # it when **both** sides are map events --
      # `self.GetType() == Event && other.GetType() == Event && (self.
      # IsOverlapForbidden() || other.IsOverlapForbidden())` -- so it can
      # make two events collide regardless of their (mismatched) layers, but
      # can never be what blocks the hero, on either side: the party's own
      # `GetType()` is `Player`, never `Event`, in real RPG_RT. `hero` (via
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
        return false if blockers_at(nx, ny).any? do |b|
          b[:layer] == character.layer ||
            (!hero && (character.overlap_forbidden || b[:overlap_forbidden]))
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
        # Same layer-gated occupancy rule as #char_passable? (see its comment).
        return false if x == @state.x && y == @state.y && character.layer == LAYER_SAME
        hero = character.event_id == MOVE_TARGET_PLAYER
        return false if blockers_at(x, y).any? do |b|
          b[:layer] == character.layer ||
            (!hero && (character.overlap_forbidden || b[:overlap_forbidden]))
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
      # while its own page was still active) -- verified against EasyRPG
      # Player's actual C++ source rather than left a guess: real RPG_RT keeps
      # one Game_Event object per map event for the whole visit regardless of
      # page state (Game_Event::RefreshPage, src/game_event.cpp, clears the
      # active page and sets Through Mode on a no-match but never touches
      # x/y), and Game_Interpreter::CommandStoreEventID's own lookup,
      # Game_Map::GetEventAt(x, y, /* require_active */ false)
      # (src/game_map.cpp), explicitly passes false so an inactive event is
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
      # the Control Variables "character" operand, or nil when there is no such
      # event. Queried by the interpreter via map_info.
      def event_position(id)
        ev = @events.find { |e| e[:id] == id }
        return nil unless ev
        c = ev[:char]
        { x: c.x, y: c.y, direction: c.direction }
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
          when :teleport then perform_teleport(@interpreter.teleport)
          when :movement then @interpreter.resume if step_forced_movement
          when :screen then @interpreter.resume unless @state.screen.busy?
          when :picture then @interpreter.resume unless @state.pictures_moving?
          when :return_title then perform_return_to_title
          when :game_over then perform_game_over
          when :name_input then drive_name_input
          when :animation
            drive_map_animation(@interpreter)
            # Same "spend this frame's own step budget immediately" idiom as
            # :wait/:battle above: EasyRPG's own Game_Interpreter::Update loop
            # only breaks early *while* `_state.wait_time` is still > 0 (`if
            # (_state.wait_time > 0) { _state.wait_time--; break; }`) -- once a
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
          when :sprite_flash then @interpreter.resume unless sprite_flashing?
          when :save_menu then perform_event_save
          when :menu then perform_event_menu
          when :load_menu then perform_event_load
          when :exit_game then perform_exit_game
          end
        else
          @interpreter.update
          apply_interpreter_requests(@interpreter, @active_event)
          # A Show Battle Animation with its wait flag set builds its animation
          # object synchronously in real RPG_RT -- EasyRPG's own
          # Game_Interpreter_Map::CommandShowBattleAnimation
          # (src/game_interpreter_map.cpp) calls Game_Screen::ShowBattleAnimation
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
          # EasyRPG's Game_Map::Update calls Game_Screen::Update (the only thing
          # that ever advances an animation once built, including the "stomp an
          # unrelated Screen/Character Flash to nothing" side effect riding
          # along with it) *before* UpdateForegroundEvents each real frame, so a
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
      # RGSS::Input::N0..PERIOD exists only on the SDL desktop backend today
      # (src/sdl_input.cxx) — on every other native backend (PSP, Wio
      # Terminal, terminal/sixel) these ids are simply never pressed, the same
      # way this build already leaves F5-F12 unbound there.
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
      # no-op leave the screen alone, matching real RPG_RT (its inn fade only
      # runs down the accepted-stay `AsyncOp::eCallInn` path -- a cancelled
      # prompt never reaches it).
      def drive_inn
        req = @interpreter.inn_request
        return @interpreter.resume_inn(false) unless req
        if @inn_fading_out
          return if @state.screen.fading?
          @inn_fading_out = false
          finish_inn(true)
          return
        end
        unless @inn_bgm_started
          play_inn_bgm
          @inn_bgm_started = true
        end
        return start_inn_fade_out unless req[:prompt]

        if @inn_window.nil?
          open_inn_window(req) # opened this frame; take input from the next one
          return
        end
        if Input.trigger?(Input::DOWN)
          @inn_choice += 1
          @inn_choice %= 2
          set_inn_cursor
        elsif Input.trigger?(Input::UP)
          @inn_choice -= 1
          @inn_choice %= 2
          set_inn_cursor
        elsif Input.trigger?(Input::C)
          if @inn_choice.zero?
            # Accept: only honoured when the party can pay; otherwise ignored.
            if req[:can_afford]
              close_inn_window
              start_inn_fade_out
            end
          else
            close_inn_window
            finish_inn(false)
          end
        elsif Input.trigger?(Input::B)
          close_inn_window
          finish_inn(false)
        end
      end

      # Begin the accepted-stay fade to black (Erase Screen's own FADE_OUT
      # style, its default 35-frame length) and park in the :inn wait until it
      # settles -- #drive_inn's `@inn_fading_out` branch above resumes it and
      # calls #finish_inn once the screen is fully black. A screen already
      # erased (e.g. an event faded to black right before the Show Inn command)
      # is a no-op transition, per #Game::Screen#erase, so it resolves at once
      # exactly like Erase Screen onto Erase Screen does.
      def start_inn_fade_out
        @state.screen.erase(Game::Transition::FADE_OUT)
        if @state.screen.fading?
          @inn_fading_out = true
        else
          finish_inn(true)
        end
      end

      # Restore the pre-inn BGM and resume the interpreter with the player's
      # stay/no-stay decision -- the common tail of every #drive_inn exit path.
      # An accepted stay also starts the fade back in (Show Screen's FADE_IN
      # style) here, the same frame the heal happens in resume_inn -- like real
      # RPG_RT's FinishInn, the fade-in only starts, it does not block: the
      # interpreter resumes immediately below and the screen brightens over the
      # following frames while the game keeps running.
      def finish_inn(stayed)
        @inn_bgm_started = false
        restore_pre_inn_bgm
        @state.screen.show(Game::Transition::FADE_IN) if stayed
        @interpreter.resume_inn(stayed)
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
      # Game::Shop, followed by a purchased / sold confirmation line before
      # control returns to the list; leaving resumes the interpreter with
      # whether anything was traded (which picks the [Transaction] /
      # [No Transaction] branch).
      def drive_shop
        req = @interpreter.shop_request
        return @interpreter.resume_shop(false) unless req
        if @shop.nil?
          open_shop(req) # opened this frame; take input from the next one
          return
        end
        case @shop[:screen]
        when :command  then drive_shop_command
        when :quantity then drive_shop_quantity
        when :purchased, :sold then drive_shop_confirm
        else drive_shop_list
        end
      end

      def open_shop(req)
        model = Game::Shop.new(db, @state.party, req[:goods],
                               req[:allow_buy], req[:allow_sell])
        has_menu = req[:allow_buy] && req[:allow_sell]
        screen = has_menu ? :command : (req[:allow_buy] ? :buy : :sell)
        @shop = { model: model, has_menu: has_menu, screen: screen, index: 0,
                  window: nil, gold: build_shop_gold_window, status: nil,
                  terms: shop_terms(req[:type]), browsed: false }
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

      # The line shown above the current screen's selectable rows: the
      # shopkeeper's greeting on first entering the command menu, the same
      # shopkeeper asking "anything else?" on returning to it after browsing
      # (EasyRPG's Window_Shop switches from `shop_greeting` to
      # `shop_regreeting` once the player has entered Buy or Sell mode -- a
      # per-visit flag, not a persisted "have I shopped here before"), a
      # prompt on the buy / sell / quantity screens themselves, and the
      # purchased / sold confirmation once a transaction commits. nil for any
      # other screen, which #draw_shop reads as "no header row".
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

      def draw_shop
        lines = shop_lines
        @shop[:index] = Game.clamp(@shop[:index], 0, [lines.length - 1, 0].max)
        # The shopkeeper's line (greeting / regreeting / a buy-sell-quantity
        # prompt) sits above the selectable rows as one extra line, the same
        # layout #open_inn_window uses for its own greeting.
        header = shop_header
        offset = header ? 1 : 0
        row_count = lines.length + offset
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = [row_count, 1].max * SHOP_LINE_H
        @shop[:window].dispose if @shop[:window]
        win = Window.new(10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, SHOP_LINE_H, header if header
        lines.each_with_index do |(label, _), i|
          c.draw_text 0, (i + offset) * SHOP_LINE_H, inner_w, SHOP_LINE_H, label
        end
        win.contents = c
        unless lines.empty?
          win.cursor_rect =
            Rect.new(0, (@shop[:index] + offset) * SHOP_LINE_H, inner_w, SHOP_LINE_H)
        end
        @shop[:window] = win
        draw_shop_gold
        draw_shop_status(lines)
      end

      def draw_shop_gold
        gw = 88
        c = Bitmap.new(gw - Window::BORDER * 2, SHOP_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, SHOP_LINE_H,
                    "#{@state.party.gold}#{shop_gold_term}"
        @shop[:gold].contents = c
      end

      # Panel dimensions mirror EasyRPG's Window_ShopStatus (136x48 at
      # RPG2000's own 320x240 resolution): two rows tall enough for one
      # SHOP_LINE_H label line each, plus the ordinary window border.
      SHOP_STATUS_W = 136

      # The item id the status panel should describe: whichever row the
      # cursor sits on in the buy or sell list. The command menu, the
      # quantity counter and the purchase/sale confirmation don't highlight
      # a single item, so there is nothing for the panel to show there.
      def shop_status_item_id(lines)
        return nil unless @shop[:screen] == :buy || @shop[:screen] == :sell
        return nil if lines.nil? || lines.empty?
        lines[@shop[:index]][1]
      end

      # The status panel beside the buy/sell list: the `possessed_items` /
      # `equipped_items` database terms with their counts for the currently
      # highlighted item right-aligned beside them -- EasyRPG's
      # Window_ShopStatus, refreshed the same way its own SetItemId call is,
      # from the list's own cursor. `possessed` is the bag only
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
          win = Window.new(6, 6, SHOP_STATUS_W, SHOP_LINE_H * 2 + Window::BORDER * 2)
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
          open_shop_quantity(lines[@shop[:index]][1])
        elsif Input.trigger?(Input::B)
          @shop[:has_menu] ? shop_switch(:command) : leave_shop
        end
      end

      # The purchased / sold confirmation shown right after a transaction
      # commits (Game::Shop#buy / #sell): a single line, dismissed on a
      # button press the same way the battle event message panel is (see
      # #drive_battle_event_message), then back to the list it came from --
      # EasyRPG's own Scene_Shop::Bought / Sold modes return to Buy / Sell
      # respectively (a timed auto-dismiss there; button-driven here to match
      # every other message screen in this scene).
      def drive_shop_confirm
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        @shop[:screen] = @shop[:screen] == :purchased ? :buy : :sell
        draw_shop
      end

      # How far UP / DOWN jump the quantity cursor — RPG_RT's shop counter
      # moves in tens on the vertical axis (confirmed against EasyRPG's
      # Window_ShopNumber::Update, src/window_shopnumber.cpp) so a stack of 99
      # is a few presses away rather than ninety-nine.
      SHOP_QUANTITY_STEP = 10

      # Picking an item opens the quantity counter rather than transacting one
      # unit: RPG2000 asks how many, bounded by what the party can afford, the
      # 99-item cap, or (selling) what it holds. An item with no room at all —
      # unaffordable, already capped — never opens the counter.
      def open_shop_quantity(id)
        model = @shop[:model]
        max = @shop[:screen] == :buy ? model.max_buy(id) : model.max_sell(id)
        return if max < 1
        @shop[:quantity] = { id: id, count: 1, max: max, mode: @shop[:screen] }
        @shop[:screen] = :quantity
        draw_shop
      end

      # Drive the quantity counter: RIGHT / LEFT by one, UP / DOWN by ten (both
      # clamped to 1..max), C commits the whole stack in one transaction and B
      # goes back to the list having bought nothing.
      def drive_shop_quantity
        q = @shop[:quantity]
        if shop_quantity_move(q)
          draw_shop
        elsif Input.trigger?(Input::C)
          model = @shop[:model]
          mode = q[:mode]
          mode == :buy ? model.buy(q[:id], q[:count]) : model.sell(q[:id], q[:count])
          @shop[:quantity] = nil
          @shop[:screen] = mode == :buy ? :purchased : :sold
          draw_shop
        elsif Input.trigger?(Input::B)
          close_shop_quantity
        end
      end

      # Apply one frame of quantity input; returns whether the count changed.
      def shop_quantity_move(q)
        before = q[:count]
        if Input.trigger?(Input::RIGHT)
          q[:count] += 1
        elsif Input.trigger?(Input::LEFT)
          q[:count] -= 1
        elsif Input.trigger?(Input::UP)
          q[:count] += SHOP_QUANTITY_STEP
        elsif Input.trigger?(Input::DOWN)
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

      # Move the shop cursor with Up / Down; returns true if it moved.
      def shop_move_cursor(lines)
        if Input.trigger?(Input::DOWN) && !lines.empty?
          @shop[:index] += 1
          @shop[:index] %= lines.length
          draw_shop
          true
        elsif Input.trigger?(Input::UP) && !lines.empty?
          @shop[:index] -= 1
          @shop[:index] %= lines.length
          draw_shop
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
        @shop[:status].dispose if @shop[:status]
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
          @battle = Scene::Battle.new(self, req, it)
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
      # initial map load and every Transfer Player, same as RPG_RT's
      # `Game_Player::MoveTo` calling `Game_Map::PlayBgm()` right after every
      # `Game_Map::Setup` -- a map with nothing configured, or explicitly set
      # to "none" (type 1), leaves whatever is already playing alone, and
      # #play_bgm's own same-file check keeps a Transfer Player back onto the
      # same map (or between maps sharing a track) from restarting it.
      # Skipped while boarded: the vehicle's own BGM (#play_vehicle_bgm) owns
      # the audio then, and #restore_pre_vehicle_bgm resumes whatever this
      # would have played once the party disembarks.
      def play_map_bgm
        return if @state.boarded?
        bgm = Game::MapBgm.chunk_for(@state.map_id, map_properties)
        return unless bgm
        name = music_name(bgm)
        return if name.nil? || name.empty?
        play_bgm(name: name, volume: music_volume(bgm), tempo: music_tempo(bgm))
      rescue StandardError => e
        $stderr.puts "[RPG2k] map BGM failed: #{e.message}"
      end

      # Continue's counterpart to #play_map_bgm, called instead of it when
      # #initialize's apply_access: is false. Verified against EasyRPG
      # Player's actual C++ source rather than guessed at: Scene_Map::Start
      # (src/scene_map.cpp) branches on from_save_id -- a fresh map entry
      # (from_save_id == 0) calls Game_Map::PlayBgm() (the map-tree walk
      # #play_map_bgm already ports), but resuming a save
      # (from_save_id > 0) instead does `auto current_music =
      # game_system->GetCurrentBGM(); game_system->BgmStop();
      # game_system->BgmPlay(current_music);` -- the save's own remembered
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
        tid = terrain_id(x, y)
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
      # the backdrop sprite's z 5 (EasyRPG Player's own `Priority_Background`,
      # `src/drawable.h`, correct there precisely because no map is ever drawn
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
      end

      # Game over: the party was wiped in an encounter that ends the game on
      # defeat (also the target of the Game Over event command). Stop the event
      # and return to the title screen — the faithful end state. (RPG2000 shows a
      # Game Over graphic first; that screen is native renderer work still to come.)
      # Game Over (12420), and a battle defeat the encounter marked "game over":
      # show the Game Over screen, which returns to the title once dismissed.
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
      # RPG2000's own screen offers three character sets, chosen by the
      # command's "initial character type" parameter: hiragana (0), katakana
      # (1) or, for English-patched games, the Latin alphabet (2). The
      # hiragana/katakana pages share one gojuuon grid with a face portrait
      # and a name-so-far field above it (#draw_kana_name_input and friends);
      # the alphabet page keeps the flat Latin/digit grid this widget always
      # had (#draw_name_input and friends) — RPG_RT never lets the two mix,
      # so neither does this build.

      # -- Letters page (charset 2) --------------------------------------

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
      NAME_KANA_LAST_HIRAGANA = (%w[ら り る れ ろ ゔ] + %i[toggle confirm]).freeze
      NAME_KANA_LAST_KATAKANA = (%w[ラ リ ル レ ロ ヴ] + %i[toggle confirm]).freeze
      NAME_HIRAGANA_ROWS = [
        %w[あ い う え お が ぎ ぐ げ ご],
        %w[か き く け こ ざ じ ず ぜ ぞ],
        %w[さ し す せ そ だ ぢ づ で ど],
        %w[た ち つ て と ば び ぶ べ ぼ],
        %w[な に ぬ ね の ぱ ぴ ぷ ぺ ぽ],
        %w[は ひ ふ へ ほ ぁ ぃ ぅ ぇ ぉ],
        %w[ま み む め も ゃ ゅ ょ っ ー],
        %w[や ゆ よ わ ん ー 〜 ・ ＝ ★],
        NAME_KANA_LAST_HIRAGANA
      ].freeze
      NAME_KATAKANA_ROWS = [
        %w[ア イ ウ エ オ ガ ギ グ ゲ ゴ],
        %w[カ キ ク ケ コ ザ ジ ズ ゼ ゾ],
        %w[サ シ ス セ ソ ダ ヂ ヅ デ ド],
        %w[タ チ ツ テ ト バ ビ ブ ベ ボ],
        %w[ナ ニ ヌ ネ ノ パ ピ プ ペ ポ],
        %w[ハ ヒ フ ヘ ホ ァ ィ ゥ ェ ォ],
        %w[マ ミ ム メ モ ャ ュ ョ ッ ー],
        %w[ヤ ユ ヨ ワ ン ー 〜 ・ ＝ ★],
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
      # (Latin alphabet) opens the flat letters grid; charsets 0 and 1 open the
      # kana grid on the matching page. Either way the widget is seeded with
      # the actor's current name when the command asked for it, and commits to
      # the actor and resumes the event when confirmed.
      def drive_name_input
        req = @interpreter.name_input_request
        return @interpreter.resume_name_input('') unless req
        if @name_ui.nil?
          background = build_field_background(@windowskin)
          if req[:charset] == 2
            @name_ui = { name: req[:seed] || '', sel: 0, win: nil, kana: false,
                         background: background }
            draw_name_input
          else
            @name_ui = { name: req[:seed] || '', sel: 0, kana: true,
                         page: req[:charset] == 1 ? :katakana : :hiragana,
                         actor_id: req[:actor_id], background: background }
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

      def handle_name_input
        ui = @name_ui
        row = ui[:sel] / NAME_COLS
        col = ui[:sel] % NAME_COLS
        rows = (NAME_CELLS.length + NAME_COLS - 1) / NAME_COLS
        if Input.trigger?(Input::RIGHT)
          ui[:sel] = row * NAME_COLS + (col + 1) % name_row_len(row)
          draw_name_input
        elsif Input.trigger?(Input::LEFT)
          ui[:sel] = row * NAME_COLS + (col - 1) % name_row_len(row)
          draw_name_input
        elsif Input.trigger?(Input::DOWN)
          new_row = (row + 1) % rows
          ui[:sel] = new_row * NAME_COLS + col % name_row_len(new_row)
          draw_name_input
        elsif Input.trigger?(Input::UP)
          new_row = (row - 1) % rows
          ui[:sel] = new_row * NAME_COLS + col % name_row_len(new_row)
          draw_name_input
        elsif Input.trigger?(Input::C)
          name_input_confirm
        elsif Input.trigger?(Input::B)
          name_input_backspace
        end
      end

      # Act on the highlighted cell: OK commits, BS backspaces, any other cell
      # types its character (up to NAME_MAX).
      def name_input_confirm
        cell = NAME_CELLS[@name_ui[:sel]]
        case cell
        when 'OK' then commit_name_input
        when 'BS' then name_input_backspace
        else
          @name_ui[:name] += cell if @name_ui[:name].length < NAME_MAX
          draw_name_input
        end
      end

      def name_input_backspace
        @name_ui[:name] = @name_ui[:name].chop
        @name_ui[:kana] ? draw_kana_name_input : draw_name_input
      end

      def commit_name_input
        name = @name_ui[:name]
        close_name_input
        @interpreter.resume_name_input(name)
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

      def handle_kana_name_input
        ui = @name_ui
        rows = name_kana_rows(ui[:page])
        row = ui[:sel] / NAME_KANA_COLS
        col = ui[:sel] % NAME_KANA_COLS
        if Input.trigger?(Input::RIGHT)
          ui[:sel] = row * NAME_KANA_COLS + (col + 1) % rows[row].length
          draw_kana_name_input
        elsif Input.trigger?(Input::LEFT)
          ui[:sel] = row * NAME_KANA_COLS + (col - 1) % rows[row].length
          draw_kana_name_input
        elsif Input.trigger?(Input::DOWN)
          new_row = (row + 1) % rows.length
          ui[:sel] = new_row * NAME_KANA_COLS + col % rows[new_row].length
          draw_kana_name_input
        elsif Input.trigger?(Input::UP)
          new_row = (row - 1) % rows.length
          ui[:sel] = new_row * NAME_KANA_COLS + col % rows[new_row].length
          draw_kana_name_input
        elsif Input.trigger?(Input::C)
          kana_name_input_confirm
        elsif Input.trigger?(Input::B)
          name_input_backspace
        end
      end

      # Act on the highlighted cell: :confirm commits, :toggle swaps the
      # hiragana/katakana page, any kana cell types its character (up to
      # NAME_KANA_MAX).
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
          ui[:name] += cell if ui[:name].length < NAME_KANA_MAX
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
      # ANIM_CELL_FRAMES is 2, not some other guess: EasyRPG's `BattleAnimation`
      # (src/battle_animation.{h,cpp}) drives an internal `frame` counter that
      # ticks once per `Update()` call (once per logical 60fps frame, called from
      # `Game_Battle::UpdateAnimation` every `Scene_Battle::UpdateBattlers`), with
      # `num_frames = GetRealFrames() * 2` and `GetRealFrame() { return GetFrame()
      # / 2; }` -- i.e. every real (LCF) animation frame is held for exactly two
      # ticks before the displayed cell advances, independent of whether that
      # frame's own cell list is empty (a "Wait" frame) or not; there is no
      # separate doubling rule for blank frames specifically. 2 ticks at 60fps is
      # 1/30s per frame, matching the "1 frame = 1/30s" fact this codebase already
      # otherwise assumed correctly.
      ANIM_CELL_FRAMES = 2
      # ANIM_FLASH_FRAMES is 11, not some other guess: EasyRPG's
      # `BattleAnimation::UpdateFlashGeneric` (src/battle_animation.cpp) keeps a
      # fired timing's own colour/power alive for `delta_frames = GetFrame() -
      # start_frame` from 0 up to and including 10 (`if (delta_frames <= 10)`)
      # before `UpdateScreenFlash`/`UpdateTargetFlash` fall back to all-zero --
      # `GetFrame()` is the same raw once-per-`Update()`-call tick counter
      # `ANIM_CELL_FRAMES`'s own derivation above already relies on, so this is
      # 11 raw ticks (0..10 inclusive), not 8. Previously an unverified guess,
      # left untouched by the `ANIM_CELL_FRAMES` fix's own comment ("independent
      # constants").
      ANIM_FLASH_FRAMES = 11
      # A frame's `screen_shaking` timing (LCF field 8: 0 none / 1 target / 2
      # screen) fires a fixed (power, speed, frames) triple regardless of the
      # timing's own data -- verified against EasyRPG Player's actual C++
      # source, `BattleAnimation::ProcessAnimationTiming` (src/battle_animation.cpp,
      # fetched verbatim): both the `ScreenShake_screen` (`screen->
      # ShakeOnce(3, 5, 32)`) and `ScreenShake_target` (`ShakeTargets(3, 5,
      # 32)`) cases share this exact triple, which their own comment calls
      # "not proven accurate" but the only real-RPG_RT numbers documented
      # anywhere. `frames` is already in real (60fps) frames, not tenths of a
      # second -- their comment derives it as "16 animation frames (32 real
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
      # confirmed against EasyRPG's own `BattleAnimationMap::DrawSingle`
      # (`src/battle_animation.cpp`, fetched verbatim): `const int
      # character_height = 24;`, a hardcoded constant local to that one
      # function, unrelated to `Game::CharSet::HEIGHT` (32, the actual
      # CharSet frame's pixel height) despite reading like it should be the
      # same thing. Previously used `Game::CharSet::HEIGHT` directly, which
      # split Head/Feet by 16px each way instead of RPG_RT's real 12px.
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
      # confirmed against EasyRPG Player's actual C++ source rather than left
      # as a guess: `Game_Screen::ShowBattleAnimation` (src/game_screen.cpp)
      # is a bare `animation.reset(new BattleAnimationMap(...))`, an
      # unconditional `unique_ptr` replace with no check for whether the
      # previous one had finished. If the slot is currently held by a
      # *different* interpreter's animation, that request is torn down here
      # (rather than left to finish naturally) and `it`'s own takes over
      # immediately, same frame. The interpreter that just lost the slot has
      # nothing left on screen to keep waiting on, so it resumes right away --
      # EasyRPG's own interpreter actually arms an independent, precomputed
      # frame-count wait at request time (`Game_Interpreter_Map::
      # CommandShowBattleAnimation`'s `_state.wait_time = frames`) rather than
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
      def begin_map_animation(req)
        @map_animation = start_map_animation(req)
        if @map_animation
          fire_animation_flashes(@map_animation) # frame 0 flashes
        else
          @anim_wait = missing_animation_wait(req[:animation])
        end
      end

      # The wait a Show Battle Animation command with nothing drawable still
      # applies -- confirmed against EasyRPG's own `Game_Screen::
      # ShowBattleAnimation`/`BattleAnimation` (`src/game_screen.cpp`/
      # `src/battle_animation.cpp`, fetched verbatim): there is no fixed
      # fallback duration anywhere in the reference implementation (the
      # `ANIM_FALLBACK_FRAMES` constant this replaced was an unverified
      # guess, never checked against source the way `ANIM_CELL_FRAMES` and
      # `ANIM_FLASH_FRAMES` already were). An invalid animation id, or a
      # database row with no frames at all, waits exactly 0 --
      # `Game_Interpreter`'s own `wait_time == 0` falls straight through to
      # the next command the same tick, no one-frame floor. A row with real
      # frame data but an unloadable `Battle/<name>` sheet still waits the
      # row's own real duration (`frames.size * ANIM_CELL_FRAMES`) --
      # EasyRPG computes the frame count from the database row before it
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
      # duration -- corroborated independently by EasyRPG's own C++ source:
      # `BattleAnimation::Update` (src/battle_animation.cpp) calls
      # `UpdateScreenFlash` on *every* real frame the animation is on screen,
      # not just frames with their own flash_scope-2 timing, and
      # `UpdateScreenFlash` always ends in `Game_Screen::FlashOnce(r, g, b, p,
      # 0)` -- r/g/b/p taken from the most recently fired timing's own
      # decaying value (`UpdateFlashGeneric`/`CalculateFlashPower`), or all
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
      # way and for the same reason -- corroborated independently against
      # EasyRPG's own C++ source right alongside #hold_animation_screen_flash's:
      # `BattleAnimation::Update` calls `UpdateTargetFlash()` unconditionally on
      # *every* real frame, right next to its `UpdateScreenFlash()` call
      # (`src/battle_animation.cpp`), and `UpdateTargetFlash` always ends in
      # `FlashTargets(r, g, b, p)` -- `BattleAnimationMap::FlashTargets`
      # (`target->Flash(r, g, b, p, 0)`) and `BattleAnimationBattle::FlashTargets`
      # (`battler->Flash(r, g, b, p, 0)`, the two map/battle-round shapes this
      # codebase's own #fire_map_target_flash/#fire_target_flash mirror) are
      # both unconditional the exact same way `Game_Screen::FlashOnce` is, with
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
          if ma[:battle]
            @battle.clear_target_flash(ma[:target_index])
          else
            clear_map_target_flash(ma[:flash_target])
          end
        end
      end

      # The map-triggered half: drop @player_flash / an @events entry's own
      # [:flash] back to nil, the same "no flash in flight" state #tick_flash's
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
          @last_frame = nil if @player_flash
          @player_flash = nil
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
        tx, ty = animation_target_pixel(req[:target])
        # Every map target -- the player, a map event, a vehicle -- gets the
        # same fixed height for #animation_position_offset's Head/Feet split
        # (see ANIM_MAP_TARGET_HEIGHT's own comment for why this is 24, not
        # the CharSet frame's actual 32px), so the sprite bounding box is
        # known without asking what kind of character this actually is.
        build_animation(req[:animation], tx, ty, target_height: ANIM_MAP_TARGET_HEIGHT,
                         flash_target: map_animation_flash_target(req[:target]))
      end

      # The character a map-triggered flash_scope-1 timing (see
      # #fire_map_target_flash) should pulse: `:player`, a specific `@events`
      # entry (this event / a named map event id), a `Game::Vehicle::TYPES`
      # symbol (`:boat`/`:ship`/`:airship`) for a vehicle slot, or nil when
      # the target id names nothing (a stale/invalid event id no live event
      # matches). Mirrors #animation_target_pixel's own target-id decoding
      # exactly, including its "this event" -> player fallback when there is
      # no active event (a common event Parallel Process's own Show Battle
      # Animation) and its `Game::Vehicle::TYPES[target - MOVE_TARGET_BOAT]`
      # idiom for a vehicle slot.
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

      # The animation player itself, shared by the map's Show Battle Animation
      # command and by a battle round. `battle` says the pixel is already a
      # screen position rather than a map one, and that nothing is waiting on the
      # animation to finish. `target_height` is the target sprite's own pixel
      # height, when known (see #animation_position_offset) -- nil when there is
      # no real sprite to measure (the ally-side "middle of the screen"
      # fallback), which leaves every position setting drawing at the plain
      # centre pixel, same as before this field existed. nil when the animation
      # is unknown or its Battle/<name> sheet is missing.
      def build_animation(id, tx, ty, battle = false, target_index: nil, target_height: nil,
                          flash_target: nil)
        anim = animation_row(id)
        return nil unless anim
        frames = table_entries(anim.frames)
        return nil if frames.empty?
        sheet = animation_sheet(anim.animation_name)
        return nil unless sheet
        { frames: frames, timings: table_entries(anim.timings), sheet: sheet,
          position: (anim.position || 1), tx: tx, ty: ty, frame_i: 0,
          timer: ANIM_CELL_FRAMES, battle: battle, target_index: target_index,
          target_height: target_height, flash_target: flash_target }
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
      # on the enemy for the animation's whole duration, not a spell. Confirmed
      # against EasyRPG's own material table (`src/cache.cpp`, fetched
      # verbatim), whose `Spec::transparent` column is true for `Battle` (and
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
      # ("this event" / 0), a vehicle slot, or a map event by id, defaulting to
      # the player. yado.tk: a vehicle target reads that vehicle's real,
      # currently-live x/y off `Game::State` (the same source
      # `#event_operand`'s Control Variables "character position" vehicle fix
      # reads) even when the vehicle is not on the map this scene has loaded --
      # RPG_RT does not check that the two agree before placing the animation,
      # the same blind-read quirk as the Control Variables fix.
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
      # genuine no-op rather than a gap). RPG2000 stores the flash colour /
      # power as 0..31, scaled up to the 0..255 range every flash path uses.
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
              @battle.fire_target_flash(ma[:target_index], t)
            else
              fire_map_target_flash(ma[:flash_target], t)
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
            # EasyRPG's own fixed triple instead of a command's own params.
            # A timed shake decays on its own via Game::Screen#update
            # (already driven every frame), so unlike the flash paths above
            # this needs no per-frame re-assertion hold.
            @state.screen.shake(ANIM_SHAKE_POWER, ANIM_SHAKE_SPEED, ANIM_SHAKE_FRAMES)
          when 1
            # BattleAnimationMap::ShakeTargets (the map-triggered Show Battle
            # Animation path) is a genuine empty no-op in EasyRPG's real
            # source, not a dropped feature -- so this only ever fires in
            # battle, matching #fire_target_shake's own battle-only scope.
            @battle.fire_target_shake(ma[:target_index]) if ma[:battle]
          end
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
      # #map_animation_flash_target) is either `:player` (-> @player_flash) or
      # an `@events` entry (-> its `[:flash]`). A vehicle target (one of
      # `Game::Vehicle::TYPES`) instead pulses `@vehicle_sprites[type]`
      # directly with the native RGSS `Sprite#flash` primitive #fire_target_flash
      # already uses for an enemy sprite -- unlike the player/event case, a
      # vehicle already draws through a real `Sprite` (#draw_vehicles), so it
      # needs no CharSet-tint mechanism of its own. Verified against EasyRPG
      # Player's actual C++ source rather than assumed unsupported:
      # `Game_Character::GetCharacter` (src/game_character.cpp) resolves
      # CharBoat/CharShip/CharAirship straight to the live `Game_Vehicle`
      # object -- a `Game_Character` subclass -- so `BattleAnimationMap::
      # FlashTargets`'s `target->Flash(...)` call (src/battle_animation.cpp)
      # reaches a vehicle exactly like it reaches the player or a map event;
      # nothing in real RPG_RT exempts it. nil (an unresolved event id) is a
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
          @player_flash = flash
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
      # (#animation_cell_opacity). Zoom / tone are still approximated as a plain
      # blit.
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
        # battle one is already where it belongs on screen.
        cx = ma[:battle] ? ma[:tx] : ma[:tx] - cam_x + TILE / 2
        cy = (ma[:battle] ? ma[:ty] : ma[:ty] - cam_y + TILE / 2) +
             animation_position_offset(ma)
        table_entries(frame.cells).each do |cell|
          next if cell.respond_to?(:visible) && cell.visible == false
          blit_animation_cell(ma[:sheet], cell, cx, cy)
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
      def animation_position_offset(ma)
        h = ma[:target_height]
        return 0 unless h
        case ma[:position]
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
      # RGSS's 0..255 opacity exactly the way EasyRPG's own
      # `BattleAnimation::DrawAt` does (src/battle_animation.cpp, fetched
      # verbatim): `SetOpacity(255 * (100 - cell.transparency) / 100)` — integer
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

      def blit_animation_cell(sheet, cell, cx, cy)
        opacity = animation_cell_opacity(cell)
        # A fully transparent cell contributes nothing; skipping it spares the
        # blit's own 96x96 per-pixel loop (Bitmap#blt would drop every pixel on
        # its `alpha <= 0` test anyway, one at a time).
        return if opacity <= 0
        cid = cell.cell_id || 0
        sx = (cid % ANIM_SHEET_COLS) * ANIM_CELL
        sy = (cid / ANIM_SHEET_COLS) * ANIM_CELL
        dx = cx + (cell.x || 0) - ANIM_CELL / 2
        dy = cy + (cell.y || 0) - ANIM_CELL / 2
        @animation_bmp.blt dx, dy, sheet, Rect.new(sx, sy, ANIM_CELL, ANIM_CELL), opacity
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
        # ... nor does the timer's sticky "message was at top" flag: real
        # RPG_RT rebuilds its own Window_Message fresh on every genuine map
        # entry (`Scene_Map::Start`, matching a Teleport/Transfer Player, not
        # `Scene_Map::Continue`'s reuse when merely returning from a pushed
        # menu/battle scene to the same map) -- see #initialize's identical
        # reset for the very first visit.
        @message_window_top = false
        @started_auto = {}
        @started_common = {}
        @active_event = nil
        @player_route = nil # a forced player route does not survive a teleport
        # ... nor does a Set Move Route "Change Graphic" override on the hero
        # (see #player_draw_charset): RPG_RT reverts it on Transfer Player,
        # unlike the dedicated Change Hero Graphic command.
        @player_char = nil
        @player_through = false # ... nor does Through Mode
        # Same for a vehicle's own forced route / Change Graphic override
        # (#force_vehicle_route, #vehicle_charset): none of it survives a
        # teleport, since the mirror was simulating movement against the map
        # being left, not whatever loads next.
        @vehicle_chars = {}
        @vehicle_routes = {}
        @vehicle_route_timers = {}
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
        # left happened to be.
        @state.map_event_positions = {}
        @state.map_event_route_index = {}
        # Tiles #warn_stale_terrain has already reported are per-visit too, same
        # reasoning as the tables above -- a stale reference on the map being
        # left says nothing about the destination.
        @warned_stale_terrain = {}
        @page_revision = page_revision
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
      # is nothing to resume afterwards — this scene is being disposed.
      def perform_return_to_title
        @interpreter.stop
        @parent.return_to_title
      rescue StandardError => e
        $stderr.puts "[RPG2k] Return to Title failed: #{e.message}"
        @interpreter.stop
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
      # Characters revealed per frame for the message typewriter effect.
      MSG_REVEAL_SPEED = 2
      # RPG_RT unrolls the message window (and its `\$` gold window) open and
      # shut over 7 frames rather than popping it, except during battle where
      # it appears/disappears instantly (EasyRPG's window_message.cpp:
      # `constexpr int message_animation_frames = 7`, gated on
      # `Game_Battle::IsBattleRunning()`).
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
        # matching EasyRPG's own Window_Message#y, which InsertNewPage sets
        # afresh every message but FinishMessageProcessing never resets.
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

        # Plain messages type out gradually; choice lists appear at once.
        reveal = Game::TextReveal.new(plain, 0, pauses, auto_close, instants, speeds)
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
        # text lines above are already fully revealed.
        plain = @message[:seg_lines].map { |segs| segs.map { |s| s[:text] }.join }
        reveal = Game::TextReveal.new(plain)
        reveal.reveal_all
        @message[:reveal] = reveal
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
      # configured one directly -- confirmed against EasyRPG's own
      # `Game_Message::GetRealPosition()`, which does the identical
      # pinned-vs-dynamic split. `#open_message` also uses this (not just
      # `#message_window_y` below) to update the sticky "was the window at
      # the top" flag the timer's own bottom-edge-avoidance reads, since real
      # RPG_RT's timer avoidance is downstream of this same per-page resolved
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
      # (`position_fixed` off, the default) -- confirmed against EasyRPG's
      # own `Game_Message::GetRealPosition()`, fetched verbatim, which keys
      # a three-way switch off the *configured* Message Options preference
      # (`configured`) rather than always choosing top-or-bottom regardless
      # of it. Zone thresholds are the exact 112px / 160px (7 and 10 map
      # tiles at RPG2000's real 16px tile size, `16 * 7` / `16 * 10` in
      # EasyRPG's own source) rather than the earlier `SCREEN_H / 2` (120px)
      # approximation this build used before a source read pinned the real
      # figures down:
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
      # offsets) -- confirmed against EasyRPG's own `Game_Character::
      # GetScreenY()` (`Main_Data::game_player->GetScreenY()` is what
      # `Game_Message::GetRealPosition()` actually compares its thresholds
      # against): `GetSpriteY() / TILE_SIZE - display_y / TILE_SIZE +
      # TILE_SIZE` is the tile's own top edge (`GetY() * SCREEN_TILE_SIZE`,
      # converted to pixels) plus one *full* tile, landing on the tile's
      # bottom edge -- not a half-tile centre the way `GetScreenX()`
      # deliberately does for its own, horizontal, centring (`x -=
      # TILE_SIZE / 2`). The sprite's own draw origin is pinned to the
      # bottom of its frame (`Sprite_Character`'s `SetOy(chara_height)`)
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
      # disappearing there. `#clip_text_to_width` measures and slices the run
      # to `w` itself before either draw path ever sees it, matching the
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

      # Slice `text` down to however many leading characters fit within `w`
      # pixels of `c`'s own font metrics, dropping the rest outright -- RPG_RT
      # truncates an overlong line rather than wrapping it. Walks one character
      # (not byte) at a time so a multi-byte codepoint is never split mid-way.
      def clip_text_to_width(c, text, w)
        return '' if w <= 0
        return text if c.text_size(text).width <= w
        out = ''
        text.each_char do |ch|
          candidate = out + ch
          break if c.text_size(candidate).width > w
          out = candidate
        end
        out
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
        @message[:window].cursor_rect =
          Rect.new(0, (offset + @choice_index) * MSG_LINE_H,
                   @message[:window].contents.width, MSG_LINE_H)
      end

      def drive_message
        # Advances the open/close and blink/pause animation each frame so the
        # window unrolls open, and so the pause arrow (set below) actually
        # flashes instead of sitting on one frame. Text reveal and input are
        # not held off while it unrolls -- unlike EasyRPG, which pauses
        # Window_Message::Update() on IsOpeningOrClosing() -- since the window
        # is a fresh object every message here rather than a persistent one
        # game scripts can poll, and holding logic off it would only delay
        # dismissal by MSG_ANIM_FRAMES with nothing else to show for it.
        @message[:window].update
        @message[:gold_window].update if @message[:gold_window]
        if @message[:choice]
          if Input.trigger?(Input::DOWN)
            @choice_index += 1
            @choice_index %= @message[:count]
            set_choice_cursor
            play_system_se(SFX_CURSOR)
          elsif Input.trigger?(Input::UP)
            @choice_index -= 1
            @choice_index %= @message[:count]
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
      # "full" naturally suggest: EasyRPG's `Window_Message` ports RPG_RT's
      # own measured behaviour instead, one frame longer than the documented
      # duration in both cases ("Despite documentation saying 1/4 second,
      # RPG_RT waits for 16 frames" / "...saying 1 second, RPG_RT waits for
      # 61 frames" -- src/window_message.cpp, `case '.'` / `case '|'`), the
      # same "the natural reading is wrong" shape this codebase already
      # tracks for other RPG_RT quirks (e.g. the item-drain clamp order).
      #
      # `\.` alone has a second quirk on top: EasyRPG's own comment calls it
      # "a bug(??)" -- `SetWaitForNonPrintable(16 + Utils::Clamp(speed - 16,
      # 0, 4))`, where `speed` is whatever `\s[n]` (1..20) is in effect when
      # the `\.` is reached, not a fixed 16. A speed of 17..20 stretches the
      # quarter-pause by 1..4 extra frames; `\|`'s own 61-frame hold carries
      # no such term (`case '|'` is a bare literal, no `speed` reference at
      # all) and stays flat regardless of speed.
      MSG_PAUSE_QUARTER = 16
      MSG_PAUSE_FULL = 61

      def drive_text_message
        interp = @message[:interp]
        reveal = @message[:reveal]
        confirm = Input.trigger?(Input::C) || Input.trigger?(Input::B)
        # Holding Shift during Test Play fast-forwards dialogue *while it is
        # still typing* -- same effect a C/B tap already has there (complete
        # the current reveal, releasing any inline `\!`/`\.`/`\|` pause along
        # the way). Once the whole message is shown, though, it always waits
        # for an actual confirm below, the same as with no Shift held: Shift
        # speeds up one paragraph's reveal, it does not blow through
        # paragraph after paragraph on its own. Gated on RPG2k#test_play the
        # same way #debug_through? is, so a released game never sees it.
        fast_forward = confirm || (@parent.test_play && Input.press?(Input::SHIFT))
        unless reveal.done?
          pause = reveal.pending_pause
          # The blinking pause arrow only stands for a player-input wait
          # (`\!`, or the fully-revealed message below) -- not the timed
          # `\.` / `\|` holds, which clear on their own.
          @message[:window].pause = pause ? pause[:kind] == :key : false
          if pause
            drive_message_pause(reveal, pause, fast_forward)
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
      # count down a fixed number of frames (a button skips the wait). A `\.`
      # pause's own length depends on the `\s[n]` typing speed in effect at
      # that point in the text (see #speed_at and MSG_PAUSE_QUARTER's own
      # comment); `\|` never varies.
      def drive_message_pause(reveal, pause, pressed)
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
        if pressed || @message[:pause_frames] <= 0
          @message[:pause_frames] = nil
          reveal.release_pause
        end
      end

      # Dismiss the current message. By default this rolls the window (and its
      # `\$` gold window) shut over MSG_ANIM_FRAMES frames rather than popping
      # it away, mirroring #open_message; `animate: false` (scene teardown --
      # see #dispose) skips straight to disposal instead. The closing window
      # is handed off to #update_closing_windows rather than disposed here:
      # RPG_RT's own message window keeps shrinking while the game underneath
      # it already carries on (EasyRPG decouples FinishMessageProcessing's
      # SetCloseAnimation from the interpreter the same way), so @message is
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
          # Walking into a touch event runs it instead of moving. **Both** touch
          # triggers answer here: RPG_RT tests them as one set on every
          # player-side path (EasyRPG's `{Trigger_touched, Trigger_collision}` in
          # `Game_Player::Update` / `UpdateMovement`), so the asymmetry is not
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
            return
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
        # EasyRPG's `Game_Party::ApplyStateDamage` -- see
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
        # "damaged" for the footstep SE below, matching EasyRPG's own
        # `Game_Player::Move`, which only sets `red_flash` for positive damage.
        row = terrain_row_at(@state.x, @state.y)
        terrain_hit = terrain_step_damage(row)
        terrain_damaged = !terrain_hit.empty? && row && row.respond_to?(:damage) &&
                          row.damage && row.damage > 0
        play_terrain_footstep_se(row, terrain_damaged)
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

      # RPG2003's 歩行音 (footstep SE): EasyRPG's `Game_Player::Move` plays
      # `terrain->footstep` right after applying that step's terrain damage,
      # gated on `Player::IsRPG2k3()` -- RPG2000 never plays it at all, which
      # is why `scripts/rpg2k_field_audit.rb`'s `NOT_OURS` table used to list
      # `footstep` as out of scope; wiring it here (RPG2003-gated, matching
      # real behaviour) is what retires that entry. `on_damage_se` repurposes
      # the same field: when set, `footstep` only plays on a step that actually
      # damaged someone (EasyRPG's `!terrain->on_damage_se || red_flash`),
      # turning it from an ambient step sound into the terrain's own damage-tick
      # SE instead of playing on every ordinary step onto that terrain.
      def play_terrain_footstep_se(row, damaged)
        return unless @db.respond_to?(:rpg2003?) && @db.rpg2003?
        return unless row && row.respond_to?(:footstep) && row.respond_to?(:on_damage_se)
        return if row.on_damage_se && !damaged
        name = row.footstep
        return if name.nil? || name.empty?
        RGSS::Audio.se_play(name)
      rescue StandardError => e
        $stderr.puts "[RPG2k] Terrain: footstep SE playback failed: #{e.message}"
      end

      # -- Random ("wandering monster") encounters -----------------------------
      #
      # Port of EasyRPG's Game_Player::UpdateEncounterSteps: each ordinary step
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
      # for this map outright, matching EasyRPG's own steps<=0 exit.
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
      # own encounter list (map-tree field 41), filtered by each troop's own
      # terrain_set (enemy_group chunk field 5) -- a per-terrain-tag allow list
      # a troop's editor page can restrict it to. An omitted entry (the array
      # too short to reach this tile's tag) defaults to allowed, the same
      # "missing entry reads as the field's default" rule the rest of this
      # runtime's bit tables already follow.
      def candidate_troops
        row = map_node_properties
        return [] unless row && row.respond_to?(:enemy_groups) && row.enemy_groups
        tag = terrain_id(@state.x, @state.y)
        row.enemy_groups.map { |_, e| e.enemy_group_id }.select do |tid|
          troop_allowed_on_terrain?(tid, tag)
        end
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
      # reach them. Matches EasyRPG's reverse-engineered behaviour
      # (Game_Player::UpdateNextMovementAction / UpdateEncounterSteps: both
      # gated on `Player::debug_flag && Input::IsPressed(Input::DEBUG_THROUGH)`).
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
        terrain = terrain_row_at(@state.x, @state.y)
        rate = terrain && terrain.respond_to?(:encounter_rate) ? terrain.encounter_rate : 100
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
        # RPG2000's own first-strike roll for a wandering encounter (EasyRPG's
        # Rand::ChanceOf(1, 32) under Feature::HasRpg2kBattleSystem; 2003's
        # back-attack / pincer terrain rolls are a different battle system's
        # feature and do not apply here).
        @interpreter.start_random_battle(troop_id, first_strike: @rng.random(32).zero?)
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
        # `overlap_forbidden` (LCF page field 35) never enters into it: real
        # RPG_RT (`WouldCollide`, `src/game_map.cpp`) only ever consults that
        # flag when *both* sides of a collision are map events
        # (`self.GetType() == Event && other.GetType() == Event`) — the
        # party's own `GetType()` is `Player`, never `Event`, so an event
        # with the flag set collides with *other events* regardless of its
        # layer but is never what blocks the hero (see #char_passable? for
        # the fuller citation). Every event on the tile gets a say
        # (#blockers_at), not just one of them: a below-characters decal and
        # a same-as-characters NPC can share a tile, and the NPC must still
        # block even though the decal alone would not.
        return false if blockers_at(x, y).any? { |b| b[:layer] == LAYER_SAME }
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
      # an extra caller cannot move the view).
      def camera_position
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
        [base_x + ox - screen.shake_offset, base_y + oy]
      end

      # Where a character sits on screen, for the Control Variables "character"
      # operand's screen-coordinate selectors. `ref` is the operand's reference:
      # 10001 the hero, 10002-10004 a vehicle (boat/ship/airship), a positive id
      # a map event. nil when it names something this scene cannot place — a
      # vehicle not currently on this map included, the same degenerate answer
      # an unresolvable map event already gets.
      #
      # RPG_RT measures X from the tile's centre and Y from its *bottom* — the
      # asymmetry is real (EasyRPG's GetScreenX subtracts half a tile after
      # adding a whole one, GetScreenY only adds the whole one), so it is
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
      public :camera_position, :character_screen_position

      # The rest of the "services Scene::Battle calls back into" (see the
      # readers next to #dispose): BGM, backdrop, animation-player and
      # debug-menu methods a fight shares with the field map, reached from
      # Scene::Battle with an explicit `@map.` receiver, which -- like any
      # cross-object call -- only reaches a public method.
      public :play_battle_bgm, :play_victory_bgm, :restore_pre_battle_bgm,
             :terrain_backdrop, :map_properties, :perform_game_over,
             :try_open_debug_menu, :build_animation, :drive_map_animation,
             :fire_animation_flashes, :frames_from_tenths, :load_face_bitmap,
             :step_map_animation, :close_battle

      def render
        px, py = player_pixel
        cam_x, cam_y = camera_position

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
          # Reflect the Set Transparent Flag command (and any leader graphic flag)
          # every frame so the hero hides/shows as events toggle it.
          @player_sprite.visible = !player_hidden?
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
      # of the System graphic, not a bordered window with drawn text -- verified
      # against EasyRPG Player's actual C++ source rather than left as the
      # "rendering-parity job of its own" this comment used to defer.
      # `Sprite_Timer::Draw` (src/sprite_timer.cpp) blits `digits[i]` (a
      # `Rect(32 + 8*digit, 32, 8, 16)` into the System graphic; the colon cell
      # is the same rect at `32 + 8*10`) at `i*8, 0` into a bare 40x16 sprite,
      # with **no** window/border of any kind -- and it never draws at all when
      # there is no System graphic to cut from
      # (`if (!system) return;`), unlike this build's old windowed text, which
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

      # Both timers are drawn the same way; RPG_RT puts the first at the
      # screen's left edge and the second at its right
      # (`Sprite_Timer::Sprite_Timer`'s own `SetX`), and during battle both drop
      # to `screen_height / 3 * 2 - 20` (`Sprite_Timer::Draw`'s
      # `Game_Battle::IsBattleRunning()` branch) rather than sitting at the top
      # -- both now matched exactly. **Now also implemented**: outside
      # battle, real RPG_RT slides a timer to the bottom edge whenever the
      # (sticky, persists-across-messages) message window is currently
      # parked at the top of the screen, so the two never overlap
      # (`Game_Message::GetWindow()->GetY() < 20`) -- confirmed against
      # EasyRPG's own `Sprite_Timer::Draw`/`Game_Message::GetRealPosition`/
      # `Window_Message::InsertNewPage` (`src/sprite_timer.cpp`,
      # `src/game_message.cpp`, `src/window_message.cpp`): the check reads
      # the message window's own last *resolved* Y (not the raw Message
      # Options preference), which stays wherever it was last set even after
      # that message closes, since nothing ever resets it on close, and
      # which is itself downstream of RPG2000's dynamic avoid-the-hero
      # repositioning when the position is not pinned. `#open_message`
      # tracks the same "was it at the top" outcome in `@message_window_top`
      # (see its own comment) since this build has no long-lived
      # `Window_Message`-equivalent object to read a literal Y back from;
      # `#perform_teleport`/`#initialize` reset it on every fresh map visit,
      # matching a genuine `Scene_Map::Start` rebuilding EasyRPG's own
      # `Window_Message` from scratch (initial Y below the threshold),
      # rather than the `Scene_Map::Continue` reuse a mere return from a
      # pushed menu/battle scene gets.
      def draw_timer
        battle = !@battle.nil?
        @timer_sprites ||= [nil, nil]
        2.times { |id| draw_one_timer(id, battle) }
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
      # cell blinks: `Sprite_Timer::Draw` skips it outright (leaving that 8px
      # column blank) whenever `frames % DEFAULT_FPS < DEFAULT_FPS / 2` --
      # off for the first half of every real second, on for the second half --
      # independent of the four digit cells either side of it, which always
      # draw regardless of the blink.
      def draw_timer_digits(bmp, timer)
        s = timer.seconds
        mins = s / 60
        secs = s % 60
        cells = [mins / 10, mins % 10, nil, secs / 10, secs % 10]
        bmp.clear
        blink_off = (timer.frames % Game::Timer::FPS) < Game::Timer::FPS / 2
        cells.each_with_index do |digit, i|
          next if digit.nil? && blink_off # the colon cell, mid-blink-off
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
      # tile, not half. EasyRPG's own Game_Vehicle::GetAltitude()
      # (src/game_vehicle.cpp) is `SCREEN_TILE_SIZE / (SCREEN_TILE_SIZE /
      # TILE_SIZE)` once fully airborne (this codebase never models the
      # gradual ascend/descend transition itself, only this steady-state
      # value) -- 256 / (256 / 16) = 16 with RPG_RT's own real constants.
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
      # not silently draw cell 0. Verified against EasyRPG Player's actual C++
      # source: Game_Vehicle::Game_Vehicle (src/game_vehicle.cpp) seeds a fresh
      # vehicle's sprite with `SetSpriteGraphic(ToString(lcf::Data::system.
      # boat_name), lcf::Data::system.boat_index)` (and the ship_/airship_
      # equivalents) -- name and index come from the same database fields
      # together, never index-0-regardless-of-database. Gated on the same
      # empty-charset_name test as #vehicle_charset, since RPG_RT ties both to
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
      def draw_pictures(cam_x, cam_y)
        @picture_bmp.clear
        pics = @state.pictures
        return if pics.empty?
        pics.keys.sort.each { |id| draw_picture pics[id], cam_x, cam_y }
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
        # Bounded so a picture cycling through tones cannot grow it without end;
        # the oldest entry goes first.
        @picture_tone_cache.delete(@picture_tone_cache.keys.first) if
          @picture_tone_cache.size >= PICTURE_TONE_CACHE_MAX
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

        unless tile_cache_valid?(first_tx, first_ty, abf, cf)
          rebuild_tile_cache(first_tx, first_ty, abf, cf)
        end

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

      # Record that this tile ties the grid to one of the animation inputs.
      def note_anim_input(id)
        case Game::ChipsetLayout.anim_input(id)
        when :abf then @tiles_uses_abf = true
        when :cf  then @tiles_uses_cf = true
        end
      end

      # Re-blit the whole visible grid into the cached buffers, on whole-tile
      # boundaries (the scroll remainder is applied when they are copied out).
      # This is the expensive path the cache exists to avoid running per frame.
      def rebuild_tile_cache(first_tx, first_ty, abf, cf)
        @lower_tiles.clear
        @upper_tiles.clear
        # Whether anything actually drawn this pass moves with the animation
        # columns/frames, which is what #tile_cache_valid? consults rather than
        # assuming every map animates.
        @tiles_uses_abf = false
        @tiles_uses_cf = false

        (0...ROWS).each do |ry|
          (0...COLS).each do |rx|
            tx = first_tx + rx
            ty = first_ty + ry
            dx = rx * TILE
            dy = ry * TILE

            lower = @map.lower(tx, ty)
            upper = @map.upper(tx, ty)
            upper_drawn = !Game::ChipsetLayout.upper_blank?(upper)
            note_anim_input lower
            note_anim_input upper if upper_drawn

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
        Game::ChipsetLayout.quads(id, abf, cf).each do |qdx, qdy, sx, sy, w, h|
          bmp.blt dx + qdx, dy + qdy, @chipset_bmp, Rect.new(sx, sy, w, h)
        end
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
        toned = @player_flash && flashed_charset(charset, src, @player_flash)
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
