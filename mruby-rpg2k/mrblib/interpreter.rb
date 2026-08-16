# RPG2000 event command interpreter.
#
# Runs a decoded event command list (LCF::EventCommand array) against the game
# State. Commands that only change state (switches, variables, party, gold,
# items, conditional branches) are applied directly and are unit-testable
# without any RGSS/UI. Commands that need the UI or the map (messages, choices,
# waits, teleports) do not block here: the interpreter records the request,
# raises its `waiting?` flag and pauses; the owning scene reads the request,
# drives the UI, and calls `resume` (or `choose`) to continue.
module Game
  class Interpreter
    # RPG2000 event command opcodes (subset).
    module Cmd
      # RPG2003-only commands. The editor emits these low opcodes for the
      # features RPG2000 never had: the 100x block is the battle-event page's
      # own extras plus the class / battle-command changes, and the 500x block
      # is the "RPG2003 English release" (2k3e) system commands. The numbers are
      # liblcf's `EventCommand::Code` enum, not a guess -- RPG2000 game data
      # never carries them, so they only ever fire on a 2003 project.
      CALL_COMMON_EVENT      = 1005
      FORCE_FLEE             = 1006
      ENABLE_COMBO           = 1007
      CHANGE_CLASS           = 1008
      CHANGE_BATTLE_COMMANDS = 1009
      OPEN_LOAD_MENU         = 5001
      EXIT_GAME              = 5002
      TOGGLE_FULLSCREEN      = 5004
      OPEN_VIDEO_OPTIONS     = 5005
      SHOW_MESSAGE     = 10110
      MESSAGE_2        = 20110
      MESSAGE_OPTIONS  = 10120
      CHANGE_FACE      = 10130
      SHOW_CHOICES     = 10140
      CHOICE_OPTION    = 20140
      CHOICE_END       = 20141
      INPUT_NUMBER     = 10150
      NAME_INPUT       = 10740
      KEY_INPUT_PROC   = 11610
      CONTROL_SWITCHES = 10210
      CONTROL_VARS     = 10220
      TIMER_OPERATION  = 10230
      CHANGE_GOLD      = 10310
      CHANGE_ITEMS     = 10320
      CHANGE_PARTY     = 10330
      CHANGE_EXP       = 10410
      CHANGE_LEVEL     = 10420
      CHANGE_PARAM     = 10430
      CHANGE_SKILLS    = 10440
      CHANGE_EQUIP     = 10450
      CHANGE_HP        = 10460
      CHANGE_MP        = 10470
      CHANGE_CONDITION = 10480
      FULL_HEAL        = 10490
      SIMULATED_ATTACK = 10500
      CHANGE_ACTOR_NAME   = 10610
      CHANGE_ACTOR_TITLE  = 10620
      CHANGE_ACTOR_SPRITE = 10630
      CHANGE_ACTOR_FACE   = 10640
      CHANGE_VEHICLE_GRAPHIC = 10650
      CHANGE_SYSTEM_GFX   = 10680
      CHANGE_SYSTEM_BGM   = 10660
      CHANGE_SYSTEM_SFX   = 10670
      CHANGE_TRANSITION   = 10690
      ENEMY_ENCOUNTER  = 10710
      VICTORY_HANDLER  = 20710
      ESCAPE_HANDLER   = 20711
      DEFEAT_HANDLER   = 20712
      END_BATTLE       = 20713
      OPEN_SHOP           = 10720
      SHOP_TRANSACTION    = 20720
      SHOP_NO_TRANSACTION = 20721
      SHOP_END            = 20722
      SHOW_INN         = 10730
      INN_STAY         = 20730
      INN_NO_STAY      = 20731
      INN_END          = 20732
      MEMORIZE_LOCATION = 10820
      RECALL_LOCATION   = 10830
      ENTER_EXIT_VEHICLE = 10840
      SET_VEHICLE_LOCATION = 10850
      CHANGE_EVENT_LOCATION = 10860
      TRADE_EVENT_LOCATIONS = 10870
      STORE_TERRAIN_ID  = 10910
      STORE_EVENT_ID    = 10920
      CONDITIONAL      = 12010
      ELSE_BRANCH      = 22010
      END_BRANCH       = 22011
      LABEL            = 12110
      JUMP_TO_LABEL    = 12120
      LOOP             = 12210
      BREAK_LOOP       = 12220
      END_LOOP         = 22210
      COMMENT          = 12410
      COMMENT_2        = 22410
      END_EVENT        = 12310
      ERASE_EVENT      = 12320
      CALL_EVENT       = 12330
      TELEPORT         = 10810
      ERASE_SCREEN     = 11010
      SHOW_SCREEN      = 11020
      TINT_SCREEN      = 11030
      FLASH_SCREEN     = 11040
      SHAKE_SCREEN     = 11050
      PAN_SCREEN       = 11060
      WEATHER_EFFECTS  = 11070
      SHOW_PICTURE     = 11110
      MOVE_PICTURE     = 11120
      ERASE_PICTURE    = 11130
      SHOW_BATTLE_ANIM = 11210
      PLAYER_VISIBILITY = 11310
      FLASH_SPRITE     = 11320
      MOVE_EVENT       = 11330
      PROCEED_WITH_MOVEMENT = 11340
      HALT_ALL_MOVEMENT = 11350
      WAIT             = 11410
      PLAY_BGM         = 11510
      FADEOUT_BGM      = 11520
      MEMORIZE_BGM     = 11530
      PLAY_MEMORIZED_BGM = 11540
      PLAY_SE          = 11550
      PLAY_MOVIE       = 11560
      CHANGE_MAP_TILESET = 11710
      CHANGE_PARALLAX  = 11720
      CHANGE_ENCOUNTER_RATE = 11740
      TILE_SUBSTITUTION = 11750
      SET_TELEPORT_TARGET = 11810
      CHANGE_TELEPORT_ACCESS = 11820
      SET_ESCAPE_TARGET   = 11830
      CHANGE_ESCAPE_ACCESS   = 11840
      OPEN_SAVE_MENU   = 11910
      CHANGE_SAVE_ACCESS = 11930
      OPEN_MAIN_MENU   = 11950
      CHANGE_MENU_ACCESS = 11960
      GAME_OVER        = 12420
      RETURN_TO_TITLE  = 12510
      # Battle-only commands. These appear in a troop's battle-event pages
      # (enemy_group chunk 11), never in a map or common event, and act on the
      # running fight through Game::Interpreter#battle.
      CHANGE_MONSTER_HP        = 13110
      CHANGE_MONSTER_MP        = 13120
      CHANGE_MONSTER_CONDITION = 13130
      SHOW_HIDDEN_MONSTER      = 13150
      CHANGE_BATTLE_BG         = 13210
      SHOW_BATTLE_ANIM_B       = 13260
      CONDITIONAL_B            = 13310
      TERMINATE_BATTLE         = 13410
      ELSE_BRANCH_B            = 23310
      END_BRANCH_B             = 23311
    end

    # Move-command ids inside a Move Event that carry extra parameters (every
    # other id is a bare command). Mirrors LCF's move-route parameter layout.
    module MoveCmd
      SWITCH_ON      = 32 # + switch id
      SWITCH_OFF     = 33 # + switch id
      CHANGE_GRAPHIC = 34 # + charset name (string) + charset index
      PLAY_SOUND     = 35 # + file name (string) + volume, tempo, balance
    end

    # Character reference ids a command uses instead of a map event id, from
    # liblcf's `Game_Character::CharPlayer..CharThisEvent` (10002-10004, the
    # three vehicle slots, sit between them and are only recognised by the scene,
    # which owns the vehicles). **This event** is the event whose page is running
    # the command list: the editor writes 10005, and a bare 0 means the same
    # thing (RPG_RT's `GetCharacter` maps both), which is why every reference
    # goes through #character_ref before it is looked up.
    CHAR_PLAYER     = 10001
    CHAR_BOAT       = 10002
    CHAR_AIRSHIP    = 10004
    CHAR_THIS_EVENT = 10005

    # Show Choices holds at most four selectable options; a fifth (index 4) is
    # the optional [Cancel] branch, which is a jump target only and is never
    # drawn in the window. Mirrors EasyRPG's `GetChoices(4)`.
    MAX_CHOICES = 4

    # Upper bound on nested Call Event depth, so a common event that (directly or
    # indirectly) calls itself unwinds instead of growing the stack without end.
    # RPG_RT allows 1000 levels (not counting the original caller) before it
    # aborts the process with an "invalid event call" error.
    MAX_CALL_DEPTH = 1000

    def initialize(state)
      @state = state
      @list = []
      @index = 0
      @running = false
      @call_stack = []
      @resolver = nil
      @move_route_requests = []
      @location_requests = []
      @sprite_flash_requests = []
      # Also reset by #start/#stop; set here too so #resume's unconditional
      # drain (see #resume) is safe even before this interpreter has ever run a
      # command list -- a fresh map's Scene::Map now reaches it the moment an
      # Escape/Teleport field skill queues a warp with no event having started
      # the interpreter yet (see Game::State#pending_teleport).
      @pending_messages = []
      @erase_requested = false
      @halt_movement_requested = false
      @actor_graphic_changed = false
      @tileset_request = nil
      @parallax_changed = false
      @tiles_changed = false
      @vehicle_toggle_requested = false
      @movie_request = nil
      @triggered_by_decision_key = false
      @revealed_monsters = []
      @fled_monsters = []
      @battle_background = nil
      @input_variable = nil
      @input_digits = 1
      # Whether *this* interpreter is the one that most recently set the shared
      # Change Face Graphic state to a real face (see #do_change_face) -- so
      # only the event that owns the currently-shown face clears it when its
      # own execution ends, and an unrelated interpreter finishing elsewhere
      # (another parallel process, say) never stomps someone else's face.
      @face_owner = false
      # Deterministic RNG for the Control Variables "random" operand (Kernel#rand
      # exists but is unseeded, and these runs are diffed); seeded like the map
      # scene's own RNG.
      @rng = Game::Rng.new(0x2000)
      reset_waits
    end

    def running?; @running; end
    def waiting?; @waiting; end
    attr_reader :wait_kind, :message_lines, :choice_labels, :wait_frames,
                :teleport, :input_digits, :key_input_request, :inn_request,
                :shop_request, :battle_request, :name_input_request,
                :battle_animation, :choice_cancel_type, :message_followup
    # Resolves the command list a Call Event refers to (a common event, or a page
    # of a map event). Set by the owning scene; nil disables Call Event.
    attr_accessor :resolver
    # Whether the action (decision) key started the event this interpreter is
    # running — the "the decision key started this event" conditional-branch test
    # (12010 type 8). Set by the owning scene when it launches a trigger-0 event;
    # false for auto-start, touch and parallel processes, and for common events.
    attr_accessor :triggered_by_decision_key
    # The running fight a *battle*-event page acts on (see Game::Battle's
    # "battle-event context" section). nil for map and common events, which is
    # what makes the battle-only commands no-ops outside a battle — exactly as
    # they are in RPG_RT, where the editor cannot even place them there.
    attr_accessor :battle
    # The Scene::Battle running the fight `@battle` belongs to, set
    # alongside it. Lets #do_change_party notify the battle screen the moment
    # a Change Party Member command actually adds/removes a member, mirroring
    # EasyRPG's `Game_Party::AddActor`/`RemoveActor` calling
    # `Scene::Battle::OnPartyChanged` synchronously rather than leaving the
    # screen to notice on some later redraw. nil outside battle (same scope as
    # `@battle`), so the notification is a no-op there.
    attr_accessor :battle_screen
    # Answers tile queries for Store Terrain / Event ID: responds to
    # `terrain_id(x, y)` and `event_id_at(x, y)`. Set by the owning scene; nil
    # makes those commands store 0 (the map is not queryable without it).
    attr_accessor :map_info
    # The id of the map event whose page this interpreter is running, which is
    # what a "this event" (0 / 10005) character reference resolves to. Set by the
    # owning scene alongside #map_info; nil for a common event and for a battle
    # page, neither of which has a map character of its own — a "this event"
    # reference then resolves to nothing, exactly as it does in RPG_RT.
    #
    # The *write*-side commands (Move Event, Change Event Location, Flash Sprite)
    # pass their raw target on to the scene, which already knows which event it
    # is stepping. The read-side ones — Conditional Branch orientation, the
    # Control Variables character operand and a Call Event naming a map event —
    # are answered here, so they need the id too.
    attr_accessor :event_id

    def start(commands)
      @list = commands || []
      @index = 0
      @running = true
      @call_stack = []
      @move_route_requests = []
      @location_requests = []
      @sprite_flash_requests = []
      @erase_requested = false
      @halt_movement_requested = false
      @actor_graphic_changed = false
      @system_graphic_changed = false
      @tileset_request = nil
      @parallax_changed = false
      @tiles_changed = false
      @vehicle_toggle_requested = false
      @movie_request = nil
      @revealed_monsters = []
      @fled_monsters = []
      @battle_background = nil
      # Cleared per run so a reused interpreter (the shared foreground one, or a
      # looping parallel process) never inherits the previous event's trigger;
      # the scene sets it again right after #start for an action-key event.
      @triggered_by_decision_key = false
      # Cleared for the same reason as the trigger above: the shared foreground
      # interpreter runs one event after another, and a stale id would answer a
      # common event's "this event" reference with the last map event's position.
      # The scene sets it again right after #start.
      @event_id = nil
      # Messages queued by a stat command (a Change Level / Change EXP with its
      # "show message" flag set) and shown one after another before the event
      # continues. Drained by #resume, so it survives the reset_waits between
      # messages; abandoned by #stop.
      @pending_messages = []
      # A fresh run starts with no claim on the shared face state -- see
      # #do_change_face / #update.
      @face_owner = false
      reset_waits
    end

    # Drain the Move Event (Set Move Route) requests queued since the last call,
    # returning them (each a hash: target, frequency, repeat, skippable,
    # commands) and clearing the queue. Unlike message/wait/teleport, a Move
    # Event does not pause the interpreter — the route runs in the background —
    # so the owning scene polls this after each #update to apply the routes to
    # the target characters.
    def take_move_route_requests
      reqs = @move_route_requests
      @move_route_requests = []
      reqs
    end

    # Drain the instant event-repositioning requests (Change Event Location /
    # Trade Event Locations) queued since the last call, returning them and
    # clearing the queue. Each is a hash — `{ op: :set, target:, x:, y: }` or
    # `{ op: :swap, a:, b: }`. Like Move Event these do not pause the interpreter;
    # the owning scene polls this after #update and moves the characters.
    def take_location_requests
      reqs = @location_requests
      @location_requests = []
      reqs
    end

    # True (once) if an Erase Event command ran since the last call, clearing the
    # flag. The owning scene polls this after #update and removes the event that
    # was running this interpreter from the map. Like Move Event, Erase Event does
    # not pause the interpreter — the rest of the command list still runs.
    def take_erase_request
      v = @erase_requested
      @erase_requested = false
      v
    end

    # The new tileset (chipset) id requested by a Change Map Tileset command since
    # the last call, or nil if none. Reading it clears the request. The owning
    # scene polls this after #update and rebuilds the map's chipset; non-blocking,
    # so the rest of the command list runs on.
    def take_tileset_request
      id = @tileset_request
      @tileset_request = nil
      id
    end

    # True (once) if a Change Parallax Background command replaced the map's
    # panorama since the last call, clearing the flag. The owning scene polls
    # this after #update and rebuilds the parallax sprite from the new override
    # (Game::State#parallax). Non-blocking, like Change Map Tileset.
    def take_parallax_request
      v = @parallax_changed
      @parallax_changed = false
      v
    end

    # True (once) if a Halt All Movement command ran since the last call, clearing
    # the flag. The owning scene polls this after #update and cancels every forced
    # move route in progress (the player's and each event's). Non-blocking, like
    # Erase Event: the rest of the command list keeps running.
    def take_halt_movement_request
      v = @halt_movement_requested
      @halt_movement_requested = false
      v
    end

    # True (once) if a Change Sprite Association (Change Actor Graphic) command
    # ran since the last call, clearing the flag. The owning scene polls this
    # after #update and reloads the party leader's on-screen sprite so a mid-event
    # graphic change is reflected. Non-blocking.
    def take_actor_graphic_changed
      v = @actor_graphic_changed
      @actor_graphic_changed = false
      v
    end

    # Drain the one-shot Change System Graphics (10680) request so the scene
    # reloads the windowskin. Non-blocking.
    def take_system_graphic_changed
      v = @system_graphic_changed
      @system_graphic_changed = false
      v
    end

    # True (once) if a Tile Substitution (11750) rewrote a map tile since the
    # last call, clearing the flag. The substitution itself is already recorded
    # on Game::Map; the scene polls this only to know it must redraw the tile
    # layers (its chipset buffers are cached between frames). Non-blocking.
    def take_tiles_changed
      v = @tiles_changed
      @tiles_changed = false
      v
    end

    # True (once) if an Enter/Exit Vehicle (10840) command ran since the last
    # call, clearing the flag. The owning scene polls this after #update and
    # boards the vehicle the party is standing on / facing, or disembarks the one
    # it rides — the same toggle the action button performs. Non-blocking, as the
    # command carries no wait flag.
    def take_vehicle_toggle_request
      v = @vehicle_toggle_requested
      @vehicle_toggle_requested = false
      v
    end

    # Drain the Play Movie (11560) request queued since the last call (a hash:
    # name, x, y, width, height), or nil. Non-blocking.
    def take_movie_request
      req = @movie_request
      @movie_request = nil
      req
    end

    # Drain the Flash Sprite (11320) requests queued since the last call, each a
    # hash `{ target:, red:, green:, blue:, power:, frames: }` with the Move Event
    # target ids. The owning scene polls this after #update and starts the flash
    # on the matching character; when the command carried its wait flag the
    # interpreter is additionally paused on a :sprite_flash wait until the scene
    # reports the flash done.
    def take_sprite_flash_requests
      reqs = @sprite_flash_requests
      @sprite_flash_requests = []
      reqs
    end

    # Drain the fire-and-forget Show Battle Animation (11210) request queued
    # since the last call — `battle_animation` itself, only once, the one call
    # this made with its wait flag off (a waited-for one is driven straight off
    # the :animation wait instead and never touches this flag; see
    # #do_show_battle_animation). Returns nil when nothing new fired, so the
    # owning scene does not replay the same play every frame.
    def take_battle_animation_request
      return nil unless @battle_animation_pending
      @battle_animation_pending = false
      @battle_animation
    end

    # Drain the Show Hidden Monster (13150) troop-member indices queued since the
    # last call. The scene polls this and builds the sprites for the revealed
    # members. Non-blocking.
    def take_revealed_monsters
      ids = @revealed_monsters
      @revealed_monsters = []
      ids
    end

    # Drain the Force Flee (1006) troop-member indices queued since the last
    # call — the members that just ran from the fight. The scene polls this and
    # drops their sprites. Non-blocking.
    def take_fled_monsters
      ids = @fled_monsters
      @fled_monsters = []
      ids
    end

    # Drain the Change Battle Background (13210) name queued since the last call,
    # or nil. Non-blocking.
    def take_battle_background
      name = @battle_background
      @battle_background = nil
      name
    end

    # Upper bound on commands run in a single update (one map frame): RPG_RT
    # processes at most 10000 "steps" of event commands per 1/60s frame, after
    # which the rest waits for the next frame -- this is what makes a
    # tight/heavy loop visibly slow down the game instead of freezing it.
    MAX_STEPS = 10_000

    # Advance through commands until the list ends or a command asks to wait.
    # When the current (possibly called) list runs out, control returns to the
    # caller via the call stack; the process ends only once the outermost list is
    # exhausted.
    def update
      return unless @running
      steps = 0
      until @waiting
        # Unwind any exhausted called lists back to a caller with commands left.
        return_from_call while @index >= @list.size && !@call_stack.empty?
        break if @index >= @list.size # nothing left anywhere
        cmd = @list[@index]
        @index += 1
        execute cmd
        steps += step_cost(cmd.code)
        break if steps >= MAX_STEPS
      end
      if finished?
        @running = false
        # yado.tk: a Change Face Graphic setting is scoped to "the current
        # event's execution content" -- it applies to every message the event
        # shows from here on, but once the event's own command list (Call
        # Event nesting included, since that shares this same interpreter and
        # call stack) genuinely runs out, the face resets for whatever event
        # runs next, even though nothing explicitly erased it. Message Options
        # (transparency/position/etc., #do_message_options) get no such reset
        # -- those are deliberately sticky global state for the rest of the
        # game, a real and separate RPG_RT rule, not touched here.
        if @face_owner
          @state.message_config.clear_face
          @face_owner = false
        end
      end
    end

    # Per-command cost against the MAX_STEPS budget. Most commands cost one
    # step; a handful cost more because RPG_RT's own timing measurements show
    # them taking roughly twice as long to process: each loop iteration (the
    # End Loop marker looping back), a Call Event round trip, and a Conditional
    # Branch evaluation that falls through to its else/end (an unmatched
    # condition, or an End Branch reached after a matched one).
    #
    # Deliberately NOT "corrected" to a flat 1-per-command cost to match
    # EasyRPG Player's own `Game_Interpreter::Update` (`src/game_interpreter.
    # cpp`), whose `for (; loop_count < loop_limit; ++loop_count)` increments
    # once per `ExecuteCommand()` call with no per-command weighting at all --
    # re-checked directly against that source and confirmed genuinely flat
    # there. That is not evidence this codebase's weighting is wrong: this
    # specific 2x-cost claim is sourced from real RPG_RT's own timing
    # measurements (the community "event command spec" reference the tests
    # below cite), an internal-implementation timing quirk EasyRPG's own
    # from-scratch loop counter never claimed to reproduce -- this project's
    # own stance (see `#do_break_loop`'s identical reasoning) is to model
    # genuine RPG_RT behaviour over a cleaner-looking EasyRPG simplification
    # whenever the two disagree and a real-RPG_RT source settles it.
    def step_cost(code)
      case code
      when Cmd::END_LOOP, Cmd::CALL_EVENT, Cmd::CALL_COMMON_EVENT, Cmd::END_BRANCH
        2
      when Cmd::CONDITIONAL
        @last_condition_matched ? 1 : 2
      else
        1
      end
    end

    # True when nothing is left to run: the current list is exhausted, no caller
    # is waiting on the stack, and we are not paused on a UI/map request.
    def finished?
      @index >= @list.size && @call_stack.empty? && !@waiting
    end

    # Resume the caller that a finished called-list returned to; returns false
    # when there is no caller (the outermost list is done).
    def return_from_call
      return false if @call_stack.empty?
      @list, @index = @call_stack.pop
      true
    end

    # The position to record for a Common Event Parallel Process that needs to
    # resume here after a map load (see Game::State#common_event_progress),
    # instead of restarting at the top -- or nil when the current position
    # cannot be captured that way.
    #
    # @index always points at the next not-yet-executed command, whether or not
    # we are currently #waiting? on it (a blocking command increments @index
    # before raising its wait), so it is always a safe resume point on its
    # own -- restoring it just means a resumed process skips replaying any
    # remaining Wait duration rather than serving it again, which is the
    # deliberate scope of what this captures. What it does *not* capture is a
    # position inside a called list (@call_stack non-empty): unwinding that
    # would need to re-resolve every pending caller frame (a common or map
    # event id/page) from scratch, which nothing here tracks. A process
    # captured mid-call simply keeps whatever position was last recorded before
    # the call started (see Scene::Map#step_parallel, which only overwrites the
    # stored checkpoint when this returns non-nil).
    def resumable_index
      return nil unless @running && @call_stack.empty?
      return nil if @index <= 0 || @index >= @list.size
      @index
    end

    # Start (or restart) at a previously #resumable_index-captured position
    # instead of the top of the list. `commands` must be the same command list
    # (or an equivalent rebuild of it, e.g. the same common event reloaded from
    # the same database) the index was captured against -- like #start, this
    # trusts its caller to be resuming the right process rather than validating
    # it. An out-of-range index (a stale save against edited event data) falls
    # back to the top, same as #start alone.
    def start_at(commands, index)
      start(commands)
      @index = index if index && index > 0 && index < @list.size
    end

    # Resume after a message/wait/teleport request has been handled.
    def resume
      # A stat command may have queued several level-up messages; show the next
      # one instead of continuing until the queue drains.
      return if show_next_pending_message
      reset_waits
    end

    # Abandon the rest of the current command list (e.g. after a teleport),
    # including any pending callers.
    def stop
      @running = false
      @index = @list.size
      @call_stack = []
      @pending_messages = []
      reset_waits
    end

    # Resume a choice, jumping into the selected option's branch.
    def choose(index)
      target = find_choice_option(index)
      @index = target if target
      reset_waits
    end

    # Whether the cancel key may back out of the choice now on screen — false
    # when nothing is being chosen, or when the block forbids cancelling
    # (cancel type 0), where RPG_RT simply ignores the key.
    def choice_cancellable?
      @wait_kind == :choice && @choice_cancel_type > 0
    end

    # Cancel the choice on screen. Every allowed cancel type names an option in
    # the same 1-based numbering, so cancelling is just picking option
    # `type - 1`: type 2 of a two-option block picks the second choice, and
    # type 5 picks option index 4, the [Cancel] branch. Returns false (and does
    # nothing) when cancelling is not allowed, so the scene can leave the window
    # up on the key.
    def cancel_choice
      return false unless choice_cancellable?
      choose(@choice_cancel_type - 1)
      true
    end

    # Resume an Input Number request: store the entered `value` into the target
    # variable and continue. The owning scene drives a digit-entry widget while
    # the interpreter is paused on the :number wait, then calls this with the
    # number the player entered.
    def resume_number(value)
      variables[@input_variable] = value.to_i if @input_variable
      reset_waits
    end

    # Resume Enter Hero Name (10740): rename the target actor to the entered
    # `name` (a blank entry keeps the previous name, as RPG_RT does) and continue.
    # The owning scene drives the character-entry widget while the interpreter is
    # paused on the :name_input wait, then calls this with the entered name.
    def resume_name_input(name)
      req = @name_input_request
      # Through the roster, matching the lookup #do_name_input opened the request
      # with — otherwise naming a companion who is out of the party would put up
      # the widget and then quietly drop what was typed.
      actor = req && party.roster[req[:actor_id]]
      actor.name = name if actor && name && !name.empty?
      reset_waits
    end

    # Resume a Key Input Processing request: store the pressed key's RPG2000
    # `code` (0 when nothing matched, only reached in no-wait mode) into the
    # target variable and continue. The owning scene samples input while the
    # interpreter is paused on the :key_input wait, then calls this.
    def resume_key_input(code)
      variables[@input_variable] = code.to_i if @input_variable && @input_variable > 0
      reset_waits
    end

    # Resume a Show Inn request with the player's decision. On a stay: charge the
    # inn price and fully heal the party (HP and MP). Either way, if the event
    # carries [Stay] / [No Stay] handler sub-branches, jump into the matching one;
    # otherwise execution simply continues past the command. The owning scene
    # shows the greeting / choice prompt while the interpreter is paused on the
    # :inn wait, then calls this.
    def resume_inn(stayed)
      if stayed
        party.gain_gold(-@inn_price) if @inn_price && @inn_price > 0
        party.actors.each(&:full_heal)
      end
      if @inn_has_handlers
        target = find_inn_option(stayed)
        @index = target if target
      end
      reset_waits
    end

    # Locate the [Stay] (INN_STAY) or [No Stay] (INN_NO_STAY) handler branch for
    # the pending inn, returning the index just after its marker. Falls back to
    # the INN_END marker (so an absent branch runs nothing) and to nil once the
    # inn's own indent level is left without a match.
    def find_inn_option(stay)
      want = stay ? Cmd::INN_STAY : Cmd::INN_NO_STAY
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @inn_indent && c.code == want
        return i if c.indent == @inn_indent && c.code == Cmd::INN_END
        return nil if c.indent < @inn_indent
        i += 1
      end
      nil
    end

    # Resume an Open Shop request once the player leaves the shop. `transacted`
    # is whether anything was actually bought or sold — the buying and selling
    # (gold and inventory changes) happen in the shop scene, mirroring RPG_RT.
    # When the event carries [Transaction] / [No Transaction] handler branches,
    # jump into the matching one; otherwise execution simply continues.
    def resume_shop(transacted)
      if @shop_has_handlers
        target = find_shop_option(transacted)
        @index = target if target
      end
      reset_waits
    end

    # Locate the [Transaction] (SHOP_TRANSACTION) or [No Transaction]
    # (SHOP_NO_TRANSACTION) handler branch for the pending shop, returning the
    # index just after its marker. Falls back to SHOP_END and to nil once the
    # shop's own indent level is left — the same structure as the inn branches.
    def find_shop_option(transacted)
      want = transacted ? Cmd::SHOP_TRANSACTION : Cmd::SHOP_NO_TRANSACTION
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @shop_indent && c.code == want
        return i if c.indent == @shop_indent && c.code == Cmd::SHOP_END
        return nil if c.indent < @shop_indent
        i += 1
      end
      nil
    end

    # Resume an Enemy Encounter with the battle's outcome (:victory, :escape or
    # :defeat). Rewards (EXP / gold on victory) are granted by the scene, which
    # owns the battle; this only steers event flow. Escape with the "end event
    # processing" mode abandons the rest of the event; otherwise, when the
    # command carries [Victory] / [Escape] / [Defeat] handler branches, jump into
    # the matching one. A game-over on defeat is the scene's concern.
    def resume_battle(result)
      # Tally the outcome for the Control Variables "Other" operand.
      case result
      when :victory then @state.win_count += 1
      when :defeat  then @state.defeat_count += 1
      when :escape  then @state.escape_count += 1
      end
      if result == :escape && @battle_escape_aborts
        @index = @list.size
        @call_stack = []
        reset_waits
        return
      end
      if @battle_has_handlers
        target = find_battle_option(result)
        @index = target if target
      end
      reset_waits
    end

    BATTLE_HANDLERS = { victory: Cmd::VICTORY_HANDLER, escape: Cmd::ESCAPE_HANDLER,
                        defeat: Cmd::DEFEAT_HANDLER }.freeze

    # Locate the handler branch for a battle outcome, like the inn / shop
    # branches: the index just after its marker, falling back to END_BATTLE and
    # to nil once the encounter's indent level is left.
    def find_battle_option(result)
      want = BATTLE_HANDLERS[result]
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @battle_indent && c.code == want
        return i if c.indent == @battle_indent && c.code == Cmd::END_BATTLE
        return nil if c.indent < @battle_indent
        i += 1
      end
      nil
    end

    # RPG2000/2003 key-input result codes in priority order (highest first).
    # When more than one accepted button is active RPG_RT returns the largest
    # code: Period > Divide > Multiply > Minus > Plus > N9..N0 > Shift >
    # Cancel > Decision > Up > Right > Left > Down. The Numbers/Operators
    # block (10-24) matches EasyRPG Player's
    # Game_Interpreter::KeyInputState::CheckInput (src/game_interpreter.cpp),
    # the documented reference this codebase already leans on for RPG2000/2003
    # runtime behaviour that RPG_RT itself never published — Numbers is a
    # digit's own value plus 10 (N0 -> 10 .. N9 -> 19), Operators are
    # Plus/Minus/Multiply/Divide/Period at 20-24.
    KEY_INPUT_CODES = [
      [:period, 24], [:divide, 23], [:multiply, 22], [:minus, 21], [:plus, 20],
      [:n9, 19], [:n8, 18], [:n7, 17], [:n6, 16], [:n5, 15],
      [:n4, 14], [:n3, 13], [:n2, 12], [:n1, 11], [:n0, 10],
      [:shift, 7], [:cancel, 6], [:decision, 5],
      [:up, 4], [:right, 3], [:left, 2], [:down, 1]
    ].freeze

    # `accepted` (see #do_key_input) only carries whole-group flags for
    # Numbers/Operators, not one flag per digit/operator — this maps each of
    # KEY_INPUT_CODES' per-key symbols back onto the group flag that accepts
    # it, so #key_input_result can look up "was this key's group requested?"
    # for :n3 the same way it looks up acc[:decision] for :decision. A symbol
    # absent here (e.g. :decision) is its own group, i.e. `accepted` carries a
    # flag with that exact name.
    KEY_INPUT_GROUPS = { n0: :numbers, n1: :numbers, n2: :numbers, n3: :numbers,
                          n4: :numbers, n5: :numbers, n6: :numbers, n7: :numbers,
                          n8: :numbers, n9: :numbers,
                          plus: :operators, minus: :operators, multiply: :operators,
                          divide: :operators, period: :operators }.freeze

    # Given the set of currently-active key symbols (an array like [:decision]),
    # return the RPG2000 code of the highest-priority key the pending request
    # accepts, or 0 when none of the accepted keys are active. Called by the
    # owning scene once it has sampled real input.
    def key_input_result(active)
      acc = @key_input_request && @key_input_request[:accepted]
      return 0 unless acc
      KEY_INPUT_CODES.each do |sym, code|
        group = KEY_INPUT_GROUPS[sym] || sym
        return code if acc[group] && active.include?(sym)
      end
      0
    end

    private

    def reset_waits
      @waiting = false
      @wait_kind = nil
      @message_lines = nil
      @message_followup = nil
      @choice_labels = nil
      # 0 = cancelling forbidden, which is also the right answer while nothing
      # is being chosen (see #choice_cancellable?).
      @choice_cancel_type = 0
      @wait_frames = 0
      @teleport = nil
      @key_input_request = nil
      @inn_request = nil
      @shop_request = nil
      @battle_request = nil
      @name_input_request = nil
      @battle_animation = nil
      @battle_animation_pending = false
    end

    def switches;  @state.switches;  end
    def variables; @state.variables; end
    def party;     @state.party;     end

    def execute(cmd)
      case cmd.code
      when Cmd::SHOW_MESSAGE     then do_show_message cmd
      when Cmd::MESSAGE_OPTIONS  then do_message_options cmd
      when Cmd::CHANGE_FACE      then do_change_face cmd
      when Cmd::SHOW_CHOICES     then do_show_choices cmd
      when Cmd::CHOICE_OPTION    then skip_to([Cmd::CHOICE_END], cmd.indent); consume
      when Cmd::CHOICE_END       then nil
      when Cmd::INPUT_NUMBER     then do_input_number cmd
      when Cmd::KEY_INPUT_PROC   then do_key_input cmd
      when Cmd::ENEMY_ENCOUNTER  then do_enemy_encounter cmd
      when Cmd::VICTORY_HANDLER  then skip_to([Cmd::END_BATTLE], cmd.indent); consume
      when Cmd::ESCAPE_HANDLER   then skip_to([Cmd::END_BATTLE], cmd.indent); consume
      when Cmd::DEFEAT_HANDLER   then skip_to([Cmd::END_BATTLE], cmd.indent); consume
      when Cmd::END_BATTLE       then nil
      when Cmd::OPEN_SHOP        then do_open_shop cmd
      when Cmd::SHOP_TRANSACTION    then skip_to([Cmd::SHOP_END], cmd.indent); consume
      when Cmd::SHOP_NO_TRANSACTION then skip_to([Cmd::SHOP_END], cmd.indent); consume
      when Cmd::SHOP_END         then nil
      when Cmd::NAME_INPUT       then do_name_input cmd
      when Cmd::SHOW_INN         then do_show_inn cmd
      when Cmd::INN_STAY         then skip_to([Cmd::INN_END], cmd.indent); consume
      when Cmd::INN_NO_STAY      then skip_to([Cmd::INN_END], cmd.indent); consume
      when Cmd::INN_END          then nil
      when Cmd::CONTROL_SWITCHES then do_control_switches cmd
      when Cmd::CONTROL_VARS     then do_control_vars cmd
      when Cmd::TIMER_OPERATION  then do_timer cmd
      when Cmd::CHANGE_GOLD      then do_change_gold cmd
      when Cmd::CHANGE_ITEMS     then do_change_items cmd
      when Cmd::CHANGE_PARTY     then do_change_party cmd
      when Cmd::CHANGE_EXP       then do_change_exp cmd
      when Cmd::CHANGE_LEVEL     then do_change_level cmd
      when Cmd::CHANGE_PARAM     then do_change_params cmd
      when Cmd::CHANGE_SKILLS    then do_change_skills cmd
      when Cmd::CHANGE_EQUIP     then do_change_equipment cmd
      when Cmd::CHANGE_HP        then do_change_hp cmd
      when Cmd::CHANGE_MP        then do_change_mp cmd
      when Cmd::CHANGE_CONDITION then do_change_condition cmd
      when Cmd::FULL_HEAL        then do_full_heal cmd
      when Cmd::SIMULATED_ATTACK then do_simulated_attack cmd
      when Cmd::CHANGE_CLASS     then do_change_class cmd
      when Cmd::CHANGE_BATTLE_COMMANDS then do_change_battle_commands cmd
      when Cmd::CHANGE_ACTOR_NAME   then do_change_actor_name cmd
      when Cmd::CHANGE_ACTOR_TITLE  then do_change_actor_title cmd
      when Cmd::CHANGE_ACTOR_SPRITE then do_change_actor_sprite cmd
      when Cmd::CHANGE_ACTOR_FACE   then do_change_actor_face cmd
      when Cmd::CHANGE_VEHICLE_GRAPHIC then do_change_vehicle_graphic cmd
      when Cmd::SET_VEHICLE_LOCATION then do_set_vehicle_location cmd
      when Cmd::ENTER_EXIT_VEHICLE then @vehicle_toggle_requested = true
      when Cmd::CONDITIONAL      then do_conditional cmd
      when Cmd::ELSE_BRANCH      then skip_to([Cmd::END_BRANCH], cmd.indent); consume
      when Cmd::END_BRANCH       then nil
      when Cmd::JUMP_TO_LABEL    then do_jump_label cmd
      when Cmd::LOOP             then nil # marker; body runs, END_LOOP loops back
      when Cmd::BREAK_LOOP       then do_break_loop cmd
      when Cmd::END_LOOP         then do_end_loop cmd
      when Cmd::TELEPORT         then do_teleport cmd
      when Cmd::MEMORIZE_LOCATION then do_memorize_location cmd
      when Cmd::RECALL_LOCATION   then do_recall_location cmd
      when Cmd::CHANGE_EVENT_LOCATION then do_change_event_location cmd
      when Cmd::TRADE_EVENT_LOCATIONS then do_trade_event_locations cmd
      when Cmd::STORE_TERRAIN_ID  then do_store_terrain_id cmd
      when Cmd::STORE_EVENT_ID    then do_store_event_id cmd
      when Cmd::ERASE_SCREEN     then do_erase_screen cmd
      when Cmd::SHOW_SCREEN      then do_show_screen cmd
      when Cmd::TINT_SCREEN      then do_tint_screen cmd
      when Cmd::FLASH_SCREEN     then do_flash_screen cmd
      when Cmd::SHAKE_SCREEN     then do_shake_screen cmd
      when Cmd::PAN_SCREEN       then do_pan_screen cmd
      when Cmd::SHOW_PICTURE     then do_show_picture cmd
      when Cmd::MOVE_PICTURE     then do_move_picture cmd
      when Cmd::ERASE_PICTURE    then do_erase_picture cmd
      when Cmd::SHOW_BATTLE_ANIM then do_show_battle_animation cmd
      when Cmd::WEATHER_EFFECTS  then do_weather cmd
      when Cmd::PLAYER_VISIBILITY then do_player_visibility cmd
      when Cmd::FLASH_SPRITE     then do_flash_sprite cmd
      when Cmd::MOVE_EVENT       then do_move_event cmd
      when Cmd::PROCEED_WITH_MOVEMENT then do_proceed_with_movement cmd
      when Cmd::HALT_ALL_MOVEMENT then @halt_movement_requested = true
      when Cmd::WAIT             then do_wait cmd
      when Cmd::PLAY_BGM         then play_audio(:bgm, cmd)
      when Cmd::FADEOUT_BGM      then do_fadeout_bgm cmd
      when Cmd::MEMORIZE_BGM     then do_memorize_bgm cmd
      when Cmd::PLAY_MEMORIZED_BGM then do_play_memorized_bgm cmd
      when Cmd::PLAY_SE          then play_audio(:se, cmd)
      when Cmd::PLAY_MOVIE       then do_play_movie cmd
      when Cmd::CHANGE_MAP_TILESET then @tileset_request = cmd.param(0)
      when Cmd::CHANGE_PARALLAX   then do_change_parallax cmd
      when Cmd::CHANGE_ENCOUNTER_RATE then @state.encounter_rate = cmd.param(0)
      when Cmd::TILE_SUBSTITUTION then do_tile_substitution cmd
      when Cmd::SET_TELEPORT_TARGET then do_set_teleport_target cmd
      when Cmd::SET_ESCAPE_TARGET   then do_set_escape_target cmd
      when Cmd::CHANGE_SYSTEM_GFX     then do_change_system_graphic cmd
      when Cmd::CHANGE_SYSTEM_BGM    then do_change_system_bgm cmd
      when Cmd::CHANGE_SYSTEM_SFX    then do_change_system_sfx cmd
      when Cmd::CHANGE_TRANSITION    then @state.set_screen_transition(cmd.param(0), cmd.param(1))
      when Cmd::CHANGE_TELEPORT_ACCESS then @state.teleport_access = cmd.param(0) != 0
      when Cmd::CHANGE_ESCAPE_ACCESS then @state.escape_access = cmd.param(0) != 0
      when Cmd::OPEN_SAVE_MENU   then do_open_save_menu cmd
      when Cmd::CHANGE_SAVE_ACCESS then @state.save_access = cmd.param(0) != 0
      when Cmd::OPEN_MAIN_MENU   then do_open_main_menu cmd
      when Cmd::CHANGE_MENU_ACCESS then @state.menu_access = cmd.param(0) != 0
      when Cmd::RETURN_TO_TITLE  then do_return_to_title cmd
      when Cmd::GAME_OVER        then do_game_over cmd
      when Cmd::CALL_EVENT       then do_call_event cmd
      when Cmd::CALL_COMMON_EVENT then do_call_common_event cmd
      when Cmd::OPEN_LOAD_MENU   then do_open_load_menu cmd
      when Cmd::EXIT_GAME        then do_exit_game cmd
      when Cmd::TOGGLE_FULLSCREEN then do_toggle_fullscreen cmd
      when Cmd::OPEN_VIDEO_OPTIONS then do_open_video_options cmd
      when Cmd::ERASE_EVENT      then @erase_requested = true
      when Cmd::END_EVENT        then @index = @list.size
      when Cmd::LABEL            then nil # jump target only; Jump to Label finds it
      when Cmd::COMMENT, Cmd::COMMENT_2 then nil # developer annotation
      when Cmd::CHANGE_MONSTER_HP        then do_change_monster_hp cmd
      when Cmd::CHANGE_MONSTER_MP        then do_change_monster_mp cmd
      when Cmd::CHANGE_MONSTER_CONDITION then do_change_monster_condition cmd
      when Cmd::SHOW_HIDDEN_MONSTER      then do_show_hidden_monster cmd
      when Cmd::FORCE_FLEE               then do_force_flee cmd
      when Cmd::ENABLE_COMBO             then do_enable_combo cmd
      when Cmd::CHANGE_BATTLE_BG         then do_change_battle_bg cmd
      when Cmd::SHOW_BATTLE_ANIM_B       then do_show_battle_animation_b cmd
      when Cmd::CONDITIONAL_B            then do_conditional_battle cmd
      when Cmd::ELSE_BRANCH_B    then skip_to([Cmd::END_BRANCH_B], cmd.indent); consume
      when Cmd::END_BRANCH_B     then nil
      when Cmd::TERMINATE_BATTLE then do_terminate_battle cmd
      else nil # blank editor lines (codes 0 / 10) and RPG2003-only commands
      end
    end

    # Call Event: suspend the current list and run a referenced command list to
    # completion, then resume where we left off. param0 selects what is called:
    #   0 – common event: param1 = common event id
    #   1 – map event:    param1 = event id, param2 = page number
    #   2 – map event, ids taken indirectly from variables
    # The map-event id may be a "this event" reference (0 / 10005), which calls
    # another page of the event already running — RPG_RT resolves the id through
    # the same `GetCharacter` every other character reference uses, so a game can
    # keep a page of shared subroutine commands on the event itself.
    # A missing target is a logged no-op (see #resolve_call/#map_event_call); an
    # empty (but resolved) target is a silent no-op, since that page/event
    # genuinely has nothing to run. Recursion is bounded by MAX_CALL_DEPTH.
    def do_call_event(cmd)
      return unless @resolver
      cmds = resolve_call(cmd)
      return if cmds.nil? || cmds.empty?
      return if @call_stack.size >= MAX_CALL_DEPTH
      @call_stack.push [@list, @index]
      @list = cmds
      @index = 0
    end

    def resolve_call(cmd)
      case cmd.param(0)
      when 0
        id = cmd.param(1)
        cmds = @resolver.common_event_commands(id)
        $stderr.puts "[RPG2k] Call Event: common event #{id} not found" if cmds.nil?
        cmds
      when 1 then map_event_call(cmd.param(1), cmd.param(2))
      when 2 then map_event_call(variables[cmd.param(1)],
                                 variables[cmd.param(2)])
      end
    rescue StandardError => e
      $stderr.puts "[RPG2k] Call Event: failed to resolve target: #{e.message}"
      nil
    end

    # The command list of a map event's page, with the event id resolved through
    # #character_ref so "this event" reaches the running event. An unresolvable
    # reference (a common event calling "this event") has no page to run, and a
    # stale event id or page number resolves to no commands either -- both are
    # reported here rather than left a silent no-op, matching real RPG_RT's
    # error dialog for the same targets (see docs/TODO.md's runtime error
    # catalog).
    def map_event_call(event_ref, page)
      id = character_ref(event_ref)
      if id.nil?
        $stderr.puts '[RPG2k] Call Event: "this event" has no map event to ' \
                     'refer to (running inside a common event)'
        return nil
      end
      cmds = @resolver.map_event_commands(id, page)
      $stderr.puts "[RPG2k] Call Event: map event #{id} page #{page} not found" if cmds.nil?
      cmds
    end

    # Translate a command's character reference into the map event id the scene
    # can look up. "This event" (0 or 10005) becomes the id of the event running
    # this command list — nil when there is none (a common event, a battle page).
    # Every other reference, including the hero and the vehicle slots, passes
    # through untouched for the caller to recognise.
    def character_ref(ref)
      return @event_id if ref == 0 || ref == CHAR_THIS_EVENT
      ref
    end

    # -- flow helpers ---------------------------------------------------------

    # Move @index to the first command at `indent` whose code is in `codes`.
    def skip_to(codes, indent)
      while @index < @list.size
        c = @list[@index]
        break if c.indent == indent && codes.include?(c.code)
        @index += 1
      end
    end

    # Step past the command @index currently points at (a matched marker).
    def consume
      @index += 1 if @index < @list.size
    end

    # Jump to the (first) label command with the given id.
    def do_jump_label(cmd)
      target = cmd.param(0)
      @list.each_with_index do |c, j|
        if c.code == Cmd::LABEL && c.param(0) == target
          @index = j
          return
        end
      end
    end

    # End of loop: jump back to just after the matching Loop marker (same indent).
    def do_end_loop(cmd)
      j = @index - 2 # scan back from before this End Loop
      while j >= 0
        c = @list[j]
        if c.indent == cmd.indent && c.code == Cmd::LOOP
          @index = j + 1
          return
        end
        j -= 1
      end
    end

    # Break Loop: real RPG_RT does *not* scan for the enclosing loop's own End
    # Loop the way a nesting-aware reading of "break" would suggest -- it
    # searches downward for the very next End Loop command by list position
    # alone, with no regard for indent/nesting depth at all, and jumps just
    # past whichever one it hits first (viprpg-dev wiki: 200X共通/基本的な仕様
    # ・バグ, worked example: a Break Loop followed by a second, more-deeply-
    # nested, empty Loop/End Loop pair before the enclosing loop's own End
    # Loop lands on the *inner* End Loop, falls into a Show Text meant to run
    # only once the outer loop truly exits, and then loops forever through the
    # outer loop's own End Loop -- the code after the outer loop is never
    # reached). Reproduced here rather than "fixed" into the sane behavior,
    # matching this codebase's general stance of modelling RPG_RT's own
    # quirks rather than a better-behaved reading of the spec.
    def do_break_loop(_cmd)
      j = @index
      while j < @list.size
        if @list[j].code == Cmd::END_LOOP
          @index = j + 1
          return
        end
        j += 1
      end
    end

    # -- message / choices ----------------------------------------------------

    def do_show_message(cmd)
      lines = [cmd.string]
      while @index < @list.size && @list[@index].code == Cmd::MESSAGE_2
        lines.push @list[@index].string
        @index += 1
      end
      @message_lines = lines
      # RPG_RT keeps the same message window on screen when a Show Choices or
      # Input Number command immediately follows (same indent, nothing else
      # between): the typed-out lines stay up and the choices / digit entry
      # appear below them, instead of the window closing and a new one
      # opening. Peek at the next command now, before it runs, so the scene
      # knows at reveal-completion time whether to keep the window.
      next_cmd = @list[@index]
      @message_followup =
        if next_cmd && next_cmd.indent == cmd.indent && next_cmd.code == Cmd::SHOW_CHOICES
          :choice
        elsif next_cmd && next_cmd.indent == cmd.indent && next_cmd.code == Cmd::INPUT_NUMBER
          :number
        end
      @wait_kind = :message
      @waiting = true
    end

    # Message Options: configure the message window for subsequent Show Message
    # commands. param0 transparent background (0 shown / 1 transparent), param1
    # position (0 top / 1 middle / 2 bottom), param2 whether the window may move
    # aside to avoid the hero (0 fixed / 1 auto-position — so `position_fixed`
    # is the param2 == 0 case, matching RPG_RT), param3 whether other events keep
    # running while the message shows. Sets global state; it does not pause.
    def do_message_options(cmd)
      cfg = @state.message_config
      cfg.transparent = cmd.param(0) != 0
      cfg.position = cmd.param(1)
      cfg.position_fixed = cmd.param(2) == 0
      cfg.continue_events = cmd.param(3) != 0
    end

    # Change Face Graphic: select the face shown beside the next messages. The
    # command string is the FaceSet file name (empty clears the face); param0 is
    # the cell index (0..15), param1 puts the face on the right, param2 mirrors
    # it. Persists for the rest of *this* event's execution content (does not
    # pause), but -- unlike Message Options -- is not sticky game-wide: #update
    # auto-clears it once this interpreter's own command list genuinely
    # finishes, via the @face_owner claim set/dropped here.
    def do_change_face(cmd)
      cfg = @state.message_config
      name = cmd.string || ''
      if name.empty?
        cfg.clear_face
        @face_owner = false
      else
        cfg.face_name = name
        cfg.face_index = cmd.param(0)
        cfg.face_right = cmd.param(1) != 0
        cfg.face_flipped = cmd.param(2) != 0
        @face_owner = true
      end
    end

    # Show Choices: collect the block's option labels and suspend on a :choice
    # wait the owning scene answers with #choose (or #cancel_choice).
    #
    # param0 is the **cancel behaviour**, stored as a 1-based option index:
    # 0 forbids cancelling, 1..4 makes the cancel key pick that choice (the
    # editor's "「はい」/「いいえ」" default), and 5 runs a dedicated [Cancel]
    # branch — which the editor writes as a *fifth* option, index 4, with an
    # empty label. That branch is a jump target only: only options 0..3 are ever
    # drawn (EasyRPG's `GetChoices(4)`), or the cancel branch would show up as a
    # blank extra row and shift every label below it.
    def do_show_choices(cmd)
      labels = []
      i = @index
      while i < @list.size
        c = @list[i]
        break if c.indent == cmd.indent && c.code == Cmd::CHOICE_END
        if c.indent == cmd.indent && c.code == Cmd::CHOICE_OPTION &&
           c.param(0) < MAX_CHOICES
          labels[c.param(0)] = c.string
        end
        i += 1
      end
      @choice_indent = cmd.indent
      @choice_labels = labels.compact
      @choice_cancel_type = cmd.param(0)
      @wait_kind = :choice
      @waiting = true
    end

    def find_choice_option(index)
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @choice_indent && c.code == Cmd::CHOICE_OPTION && c.param(0) == index
        return i if c.indent == @choice_indent && c.code == Cmd::CHOICE_END
        i += 1
      end
      nil
    end

    # Input Number: RPG2000 lays the parameters out as [digits, variable_id]
    # (note the order is the reverse of RPG Maker XP's). Suspends with a :number
    # request the owning scene answers by driving a digit-entry widget and calling
    # `resume_number` with the value, which stores it into the variable. A digit
    # count below 1 is clamped so the widget always has at least one cell.
    def do_input_number(cmd)
      digits = cmd.param(0)
      @input_digits = digits < 1 ? 1 : digits
      @input_variable = cmd.param(1)
      @wait_kind = :number
      @waiting = true
    end

    # Key Input Processing (11610): wait for — or, in no-wait mode, sample — one
    # of a chosen set of buttons and store its RPG2000 code in a variable. The
    # parameter layout matches RPG_RT and depends on the command's length and,
    # for the param5/param6 slot, on whether the database is RPG2000 or
    # RPG2003 (`@state.party.rpg2003?`) — the two editions disagree on what
    # those two params mean:
    #   param0            target variable id
    #   param1            wait flag (0 = read this frame and continue)
    #   param2            (pre-1.50, or RPG2003's Numbers/Operators layout)
    #                     accept all four arrows when non-zero
    #   param3 / param4   accept Decision (OK) / Cancel — always present
    #   param5..param9    (RPG2000 1.50+, or an RPG2000 command carried
    #                     unchanged into an RPG2003 project — always a
    #                     10-param command either way) accept Shift / Down /
    #                     Left / Right / Up
    #   param5 / param6   (RPG2003's own Numbers/Operators layout — any other
    #                     length on an RPG2003 database) accept the numeric
    #                     keypad (0-9) / the five operator keys (+ - * / .) as
    #                     a whole; RPG_RT does not offer individual per-key
    #                     flags here, only through the Maniac Patch's own
    #                     further-extended param list (out of scope, see
    #                     below). param7/param8 are a separate "timed input"
    #                     countdown-variable feature, still unmodelled.
    # The interpreter only records the request and suspends on a :key_input
    # wait; the owning scene samples real input (triggered edges when waiting,
    # held state otherwise) and calls resume_key_input with the resulting code.
    # Numbers/Operators decoded into `accepted` are sampled by
    # Scene::Map::NUMBER_KEY_BUTTONS/OPERATOR_KEY_BUTTONS (RGSS::Input::N0..N9
    # / PLUS..PERIOD, see #key_input_result's KEY_INPUT_GROUPS), which today
    # have real key backing only on the SDL desktop window backend
    # (src/sdl_input.cxx) — the other native backends (PSP, Wio Terminal,
    # terminal/sixel) never press those ids, so a Numbers/Operators-only
    # request there resolves the same as before this: never. 🚧 The mouse
    # (Maniac) stays fully unmodelled everywhere.
    def do_key_input(cmd)
      var_id = cmd.param(0)
      wait = cmd.param(1) != 0
      size = cmd.parameters.size
      accepted = { decision: cmd.param(3) != 0, cancel: cmd.param(4) != 0,
                   shift: false, down: false, left: false, right: false,
                   up: false, numbers: false, operators: false }
      if @state.party.rpg2003? && size != 10
        # RPG2003's Numbers/Operators layout: still a single flag for the
        # whole D-pad, not the individual Shift/arrows RPG2000 1.50+ offers.
        if size < 10 && cmd.param(2) != 0
          accepted[:down] = accepted[:left] = true
          accepted[:right] = accepted[:up] = true
        end
        accepted[:numbers] = cmd.param(5) != 0
        accepted[:operators] = cmd.param(6) != 0
      elsif size < 6
        # Pre-1.50: a single flag enables the whole D-pad, no Shift.
        if cmd.param(2) != 0
          accepted[:down] = accepted[:left] = true
          accepted[:right] = accepted[:up] = true
        end
      else
        # RPG2000 1.50+, or that same layout carried into an RPG2003 project.
        accepted[:shift] = cmd.param(5) != 0
        accepted[:down]  = cmd.param(6) != 0
        accepted[:left]  = cmd.param(7) != 0
        accepted[:right] = cmd.param(8) != 0
        accepted[:up]    = cmd.param(9) != 0
      end
      @input_variable = var_id
      @key_input_request = { wait: wait, accepted: accepted }
      # RPG_RT clears the variable while a waiting proc is pending; a no-wait proc
      # overwrites it below via the scene's immediate resume.
      variables[var_id] = 0 if wait && var_id && var_id > 0
      @wait_kind = :key_input
      @waiting = true
    end

    # Show Inn / Stay at Inn (10730): offer to rest for a price. param0 selects
    # which term set greets the player (0 inn A, 1 inn B); param1 is the price.
    # A price of 0 skips the prompt and stays for free. The command may be
    # followed by [Stay] / [No Stay] handler branches (markers INN_STAY /
    # INN_NO_STAY, closed by INN_END) that run on the matching outcome, laid out
    # exactly like a Show Choices block. The interpreter records the request and
    # suspends on an :inn wait; the scene shows the greeting, the accept / cancel
    # choices (accept selectable only when affordable) and the gold window, then
    # resumes via resume_inn. Charging gold and healing the party happen there.
    # Enter Hero Name (10740): open the name-entry screen for the actor whose id
    # is param0. param1 is the initial character set (0 hiragana, 1 katakana,
    # 2 letters — our widget offers the letter set), param2 the "seed with the
    # current name" flag. Suspends on a :name_input wait carrying the actor id and
    # the seed name; the scene drives the entry widget and calls #resume_name_input
    # with the entered name. A no-op (no wait) for an actor not in the party, since
    # this build only instantiates party actors.
    def do_name_input(cmd)
      actor = identity_target(cmd)
      return unless actor
      @name_input_request = {
        actor_id: cmd.param(0), charset: cmd.param(1),
        seed: cmd.param(2) != 0 ? actor.name : ''
      }
      @wait_kind = :name_input
      @waiting = true
    end

    def do_show_inn(cmd)
      price = cmd.param(1)
      @inn_price = price
      @inn_indent = cmd.indent
      # Handler branches, when present, open with an INN_STAY marker immediately
      # after the command (as a Show Choices block opens with CHOICE_OPTION).
      nxt = @list[@index]
      @inn_has_handlers =
        !nxt.nil? && nxt.code == Cmd::INN_STAY && nxt.indent == cmd.indent
      @inn_request = { type: cmd.param(0), price: price,
                       can_afford: party.gold >= price, prompt: price > 0 }
      @wait_kind = :inn
      @waiting = true
    end

    # Open Shop (10720): enter a shop selling the goods listed from param4 on.
    # param0 is the mode (0 buy + sell, 1 buy only, 2 sell only); param1 the
    # shop-screen style (recorded for fidelity). Like the inn, the command may be
    # followed by [Transaction] / [No Transaction] handler branches (markers
    # SHOP_TRANSACTION / SHOP_NO_TRANSACTION, closed by SHOP_END) that run on
    # whether the player bought or sold anything. The interpreter records the
    # request and suspends on a :shop wait; the scene runs the buy / sell UI
    # (where the gold and inventory changes happen) and resumes via resume_shop.
    def do_open_shop(cmd)
      mode = cmd.param(0)
      @shop_indent = cmd.indent
      nxt = @list[@index]
      @shop_has_handlers =
        !nxt.nil? && nxt.code == Cmd::SHOP_TRANSACTION && nxt.indent == cmd.indent
      @shop_request = {
        mode: mode, allow_buy: mode == 0 || mode == 1,
        allow_sell: mode == 0 || mode == 2, type: cmd.param(1),
        goods: cmd.parameters[4..-1] || []
      }
      @wait_kind = :shop
      @waiting = true
    end

    # Enemy Encounter (10710): start a battle against a troop. param0 is the
    # troop-id source (0 constant, 1 variable) and param1 the id / variable;
    # param3 the escape mode (0 disallow, 1 end event processing on escape,
    # 2 custom [Escape] handler), param4 the defeat mode (0 game over, 1 custom
    # [Defeat] handler), param5 the first-strike flag. The command may be
    # followed by [Victory] / [Escape] / [Defeat] handler branches (markers
    # VICTORY/ESCAPE/DEFEAT_HANDLER, closed by END_BATTLE), like a Show Choices
    # block. The interpreter records the request and suspends on a :battle wait;
    # the scene runs the battle (rewards, game over) and resumes via
    # resume_battle. The turn-based battle itself is not built yet. A troop id
    # the database no longer has never arms the wait at all -- see
    # #skip_invalid_troop.
    def do_enemy_encounter(cmd)
      escape_mode = cmd.param(3)
      troop_id = cmd.param(0) == 0 ? cmd.param(1) : variables[cmd.param(1)]
      @battle_indent = cmd.indent
      @battle_escape_aborts = escape_mode == 1
      nxt = @list[@index]
      @battle_has_handlers =
        !nxt.nil? && nxt.code == Cmd::VICTORY_HANDLER && nxt.indent == cmd.indent
      return skip_invalid_troop(troop_id) unless party.db_enemy_group(troop_id)
      @battle_request = {
        troop_id: troop_id,
        allow_escape: escape_mode != 0, first_strike: cmd.param(5) != 0,
        defeat_game_over: cmd.param(4) == 0
      }
      @state.battle_count += 1 # a battle was entered (Control Variables "Other")
      @wait_kind = :battle
      @waiting = true
    end

    # A database shrink can leave a dangling enemy-group (troop) id reference
    # (docs/TODO.md's runtime error catalog) -- Game::Troop tolerates the gap
    # by degrading to an empty member list, which would otherwise open a real
    # battle screen (SE, BGM swap, status panel) against zero enemies. Real
    # RPG_RT has no on-screen precedent to match here (its own editor forbids
    # saving a dangling reference in the first place), so like Call Event's
    # other reported-but-tolerated gaps this logs instead of crashing or
    # silently succeeding. Routes exactly where an immediate Escape would --
    # into the [Escape] handler if the command carries one, ending the event
    # outright under the "abort on escape" escape mode, or otherwise simply
    # falling through to the command right after the encounter -- but does not
    # bump the win/escape/defeat "Other" battle counters (#resume_battle's
    # job), since no battle was ever actually fought.
    def skip_invalid_troop(troop_id)
      $stderr.puts "[RPG2k] Enemy Encounter: enemy group #{troop_id} not " \
                   'found, skipping battle'
      if @battle_escape_aborts
        @index = @list.size
        @call_stack = []
        return
      end
      target = @battle_has_handlers && find_battle_option(:escape)
      @index = target if target
    end

    # Start a battle that no event triggered — a wandering-monster encounter
    # the map rolled on its own (Scene::Map#check_random_encounter), which is
    # not a command in any list. Same request shape #do_enemy_encounter
    # builds and the same :battle wait, but with no [Victory]/[Escape]/[Defeat]
    # handler to route into and nothing to end early on an "abort" escape
    # mode, so #resume_battle's job shrinks to tallying the outcome and
    # clearing the wait. Only valid while this interpreter is otherwise idle
    # (Scene::Map only calls it from ordinary player movement, never while an
    # event is running); escape is always allowed. A wipe is game over unless
    # the database's own RPG2003 Death Handler is active
    # (Game::Party#death_handler?, matching EasyRPG's `Game_Battle::
    # HasDeathHandler`) -- Scene::Battle#finish_battle runs it instead (see
    # #start_death_handler below) when it applies. `random: true` marks the
    # request so #finish_battle can tell a wandering encounter apart from a
    # scripted Battle Processing command, whose own [Defeat] handler is a
    # separate mechanism this flag never touches. A troop id the database no
    # longer has (the map's own encounter list can go stale the same way a
    # scripted Enemy Encounter's can) logs and simply never arms the wait --
    # there is no event to resume here, so movement just continues
    # uninterrupted.
    def start_random_battle(troop_id, first_strike: false)
      unless party.db_enemy_group(troop_id)
        $stderr.puts "[RPG2k] Enemy Encounter: enemy group #{troop_id} not " \
                     'found, skipping random encounter'
        return
      end
      @battle_has_handlers = false
      @battle_escape_aborts = false
      @battle_request = { troop_id: troop_id, allow_escape: true,
                          first_strike: first_strike,
                          defeat_game_over: !party.death_handler?, random: true }
      @state.battle_count += 1
      @wait_kind = :battle
      @waiting = true
    end
    public :start_random_battle

    # RPG2003's Death Handler, run by Scene::Battle#finish_battle in place of
    # the ordinary Game Over screen once a random encounter's party is
    # wiped and Game::Party#death_handler? says the database wants this
    # instead. Matches EasyRPG's `Game_Map::OnEncounterEnd`
    # (src/game_map.cpp): the death event's own commands run first (pushed
    # the same way Call Event starts a common event, #do_call_event), then
    # the configured teleport (if any) is appended as a trailing synthetic
    # Teleport command, so it runs through the ordinary #do_teleport
    # machinery once those commands (if any) finish. Only ever called on an
    # idle interpreter -- #finish_battle only reaches this for a random
    # encounter, which by construction never has an owning event running
    # underneath it (see #start_random_battle above) -- so this simply
    # starts a fresh top-level command list rather than pushing a call
    # frame. A death handler with neither a resolvable event nor a
    # configured teleport is a silent no-op, the same as EasyRPG's own
    # empty-cases-are-inert function bodies.
    def start_death_handler
      cmds = []
      event_id = party.death_handler_event
      ev_cmds = event_id > 0 ? common_event_commands(event_id) : nil
      cmds.concat(ev_cmds) if ev_cmds
      tp = party.death_handler_teleport
      cmds << LCF::EventCommand.new(Cmd::TELEPORT, 0, '', tp) if tp
      return if cmds.empty?
      start(cmds)
    end
    public :start_death_handler

    # -- state commands -------------------------------------------------------

    def range(cmd)
      mode = cmd.param(0)
      a = cmd.param(1)
      b = mode == 0 ? a : cmd.param(2)
      if mode == 2 # indirect: id held in a variable
        a = variables[cmd.param(1)]
        # RPG_RT's indirect *target* addressing (as opposed to an indirect
        # operand read, which resolves a missing/out-of-range id to 0) is a
        # no-op when the resolved id is <= 0, rather than writing switch/
        # variable slot 0 or a negative one. An already-empty range gets the
        # same "does nothing" result do_control_switches/do_control_vars
        # already produce for a descending batch range.
        return [1, 0] if a <= 0
        b = a
      end
      [a, b]
    end

    def do_control_switches(cmd)
      a, b = range(cmd)
      op = cmd.param(3) # 0 on, 1 off, 2 toggle
      (a..b).each do |id|
        case op
        when 0 then switches[id] = true
        when 1 then switches[id] = false
        when 2 then switches.flip(id)
        end
      end
    end

    def do_control_vars(cmd)
      a, b = range(cmd)
      op = cmd.param(3)  # 0 =, 1 +, 2 -, 3 *, 4 /, 5 %
      # A random operand (type 3) rolls independently for each variable in the
      # range, matching RPG_RT -- a batch "Var[1..5] = random 1~6" is five
      # separate dice, not one roll broadcast to all five. Every other operand
      # type is evaluated once up front, as before -- except a direct-variable
      # operand (type 1) applied to a genuine multi-id range, which needs its
      # own split below (a variable-A-ops-B batch reading its own operand out
      # of the same range it writes).
      random = cmd.param(4) == 3
      return do_control_vars_range_variable(cmd, a, b, op) if !random && cmd.param(4) == 1 && a < b
      val = operand_value(cmd) unless random
      (a..b).each { |id| variables[id] = apply(op, variables[id], random ? operand_value(cmd) : val) }
    end

    # A batch (range) Control Variables write whose operand is itself a plain
    # variable read (type 1, "Var A ops B") and whose source id `src` falls
    # inside the destination range `a..b` is *not* a single value broadcast to
    # every id the way an out-of-range source (or any other operand type) is.
    # EasyRPG's `Game_Variables::WriteRangeVariable`
    # (`src/game_variables.cpp`) -- the direct-variable-lookup range path
    # `Game_Interpreter::CommandControlVariables`
    # (`src/game_interpreter.cpp`) dispatches to whenever the target
    # evaluation mode is a genuine multi-id range -- splits the write into two
    # passes right at `src`: ids `a..src` are written first, from `src`'s
    # value *before* this command touched anything; then, only once that
    # first pass has run (and, for anything but a plain Set, has therefore
    # already changed `src`'s own stored value), ids `src+1..b` are written
    # from `src`'s value *now* -- i.e. the just-updated one, not the original.
    # For Set this is unobservable (`src` written back to its own unchanged
    # value), but for Add/Sub/Mult/Div/Mod it means every id *after* `src` in
    # the range ends up combining the operation with itself twice while every
    # id at or before `src` only sees it once. A source outside `a..b`
    # entirely skips this split and degenerates to the ordinary single
    # up-front read every other operand type already uses.
    def do_control_vars_range_variable(cmd, a, b, op)
      src = cmd.param(5)
      unless src >= a && src <= b
        val = variables[src]
        (a..b).each { |id| variables[id] = apply(op, variables[id], val) }
        return
      end
      before = variables[src]
      (a..src).each { |id| variables[id] = apply(op, variables[id], before) }
      after = variables[src]
      ((src + 1)..b).each { |id| variables[id] = apply(op, variables[id], after) }
    end

    def operand_value(cmd)
      case cmd.param(4) # operand type
      when 0 then cmd.param(5)                             # constant
      when 1 then variables[cmd.param(5)]                  # variable
      when 2 then variables[variables[cmd.param(5)]]       # variable indirect
      when 3 then random_operand(cmd)                      # random in a range
      when 4 then item_operand(cmd)                        # item count / equipped
      when 5 then actor_operand(cmd)                       # an actor's stat
      when 6 then event_operand(cmd)                       # a character's position
      when 7 then other_operand(cmd)                       # gold / timer / ...
      when 8 then enemy_operand(cmd)                       # a monster's stat (2003)
      else
        # An operand this build does not know (the Maniac patch adds 9..21).
        # Reading 0 is the safe answer; returning param5 — which is the operand's
        # *selector*, not a value — used to write the enemy index or actor id
        # into the variable and look like a plausible number.
        $stderr.puts "[RPG2k] Control Variables: unsupported operand #{cmd.param(4)}"
        0
      end
    end

    # Operand type 6: a positional value of a character. param5 selects it (10001
    # the hero / party, 10002-10004 a vehicle (boat/ship/airship), "this event"
    # as 0 / 10005, any other positive id a map event); param6 the value (0 map
    # id, 1 x tile, 2 y tile, 3 facing in RPG2000's 2/4/6/8 numpad convention,
    # 4 screen x, 5 screen y). A *map event's* map id reads 0 -- but only on an
    # RPG2000 database: EasyRPG's `ControlVariables::Event` (case 0) is
    # explicit that this is "an RPG_RT bug for 2k only" -- its condition is
    # `!Player::IsRPG2k() || event_id == CharPlayer/CharBoat/CharShip/
    # CharAirship`, so a genuine RPG2003 project (`IsRPG2k3()`, the mutually
    # exclusive engine flag `db.rpg2003?` already detects) takes the *true*
    # branch and reads the event's real map id -- which, for a map event, is
    # simply whichever map is currently loaded, the same value the hero/party
    # branch below already returns (`Game_Event`'s own map id is set from the
    # loaded map at construction and never changes; unlike a vehicle it cannot
    # exist independently of one). A vehicle's map id reads for real
    # regardless of edition, since (unlike a map event) it is state that
    # exists independently of whatever map is currently loaded (yado.tk: a
    # vehicle's position can be read from a different map than the one it
    # currently occupies). An unresolvable reference (no map_info hook,
    # unknown event, "this event" outside a map event) reads 0.
    def event_operand(cmd)
      ref = character_ref(cmd.param(5))
      attr = cmd.param(6)
      return screen_operand(ref, attr) if attr == 4 || attr == 5
      if ref.nil?
        $stderr.puts '[RPG2k] Control Variables: "this event" has no map ' \
                     'event to refer to (running inside a common event)'
        return 0
      end
      if ref == CHAR_PLAYER # the hero / party leader
        case attr
        when 0 then @state.map_id
        when 1 then @state.x
        when 2 then @state.y
        when 3 then @state.direction
        else 0
        end
      elsif ref >= CHAR_BOAT && ref <= CHAR_AIRSHIP
        vehicle_operand(ref, attr)
      elsif ref > 0 && ref < 10000 && @map_info.respond_to?(:event_position)
        pos = @map_info.event_position(ref)
        unless pos
          $stderr.puts "[RPG2k] Control Variables: map event #{ref} not found"
          return 0
        end
        case attr
        when 0 then @state.party.rpg2003? ? @state.map_id : 0 # the RPG2000-only quirk
        when 1 then pos[:x]
        when 2 then pos[:y]
        when 3 then pos[:direction]
        else 0
        end
      else
        0
      end
    end

    # A vehicle's own stored position, read straight off `Game::State` rather
    # than through `@map_info` -- unlike a map event, a vehicle is tracked
    # independently of any loaded map (`Scene::Map#follow_vehicle` keeps the
    # ridden one's position live every step, and an unridden one simply sits
    # wherever it was last placed), so this needs no scene hook and works the
    # same whether or not the vehicle's own map is the one currently loaded.
    def vehicle_operand(ref, attr)
      v = @state.vehicle(Vehicle::TYPES[ref - CHAR_BOAT])
      return 0 unless v
      case attr
      when 0 then v.map_id
      when 1 then v.x
      when 2 then v.y
      when 3 then v.direction
      else 0
      end
    end

    # The screen-coordinate selectors of operand 6 (attr 4 x / 5 y): where the
    # character currently sits in the view, which only the map scene can answer
    # because it owns the camera. Without that hook (a headless interpreter, or a
    # battle page) there is no view to measure against, so it reads 0. `ref` has
    # already been through #character_ref, so "this event" arrives as a real id.
    def screen_operand(ref, attr)
      if ref.nil?
        $stderr.puts '[RPG2k] Control Variables: "this event" has no map ' \
                     'event to refer to (running inside a common event)'
        return 0
      end
      return 0 unless @map_info.respond_to?(:character_screen_position)
      pos = @map_info.character_screen_position(ref)
      unless pos
        $stderr.puts "[RPG2k] Control Variables: character #{ref} has no " \
                     'screen position (not on the current map)'
        return 0
      end
      attr == 4 ? pos[:x] : pos[:y]
    end

    # Operand type 4: a count for the item with id param5. param6 selects the
    # mode: 0 the number held in the bag, 1 the number equipped across the party
    # (each slot equipping it counts). Matches EasyRPG's ControlVariables::Item.
    def item_operand(cmd)
      id = cmd.param(5)
      cmd.param(6) == 1 ? party.equipped_item_count(id) : party.item_count(id)
    end

    # Operand type 3: a random integer in [param5, param6] inclusive (the bounds
    # are swapped if given the wrong way round).
    def random_operand(cmd)
      lo = cmd.param(5)
      hi = cmd.param(6)
      lo, hi = hi, lo if lo > hi
      lo + @rng.random(hi - lo + 1)
    end

    # Operand type 5: a stat of the actor with id param5. param6 selects the
    # attribute (0 level, 1 EXP, 2 HP, 3 MP, 4 max HP, 5 max MP, 6 attack,
    # 7 defence, 8 spirit, 9 agility, then 10..14 the id of the item in each
    # equipment slot — weapon, shield, armour, helmet, accessory, in the order
    # Game::Actor::EQUIP_ORDER already stores them, 0 for an empty slot).
    #
    # Read through the roster (RPG_RT's `Game_Actors::GetActor`), so a companion
    # who is out of the party reports their real level and gear rather than 0.
    # **Every** actor-stat read in Nepheshel — all 2436 — names a swappable
    # companion, and its party status display is built out of them, so a
    # dismissed member used to be listed at level 0. Only an id the database has
    # no row for reads as 0.
    def actor_operand(cmd)
      actor = party.roster[cmd.param(5)]
      return 0 unless actor
      attr = cmd.param(6)
      case attr
      when 0 then actor.level
      when 1 then actor.exp
      when 2 then actor.hp
      when 3 then actor.mp
      when 4 then actor.max_hp
      when 5 then actor.max_mp
      when 6 then actor.atk
      when 7 then actor.def
      when 8 then actor.int
      when 9 then actor.agi
      when 10, 11, 12, 13, 14 then actor.equipment[attr - 10] || 0
      else 0
      end
    end

    # Operand type 8: a stat of a monster in the running fight (RPG2003's battle
    # operand). param5 is the troop member index — the editor's own numbering,
    # the same one Change Monster HP uses — and param6 the attribute (0 HP,
    # 1 SP, 2 max HP, 3 max SP, 4 attack, 5 defence, 6 spirit, 7 agility).
    # Outside a battle, or for a member that is not in this troop, it reads 0.
    def enemy_operand(cmd)
      foe = @battle && @battle.enemy(cmd.param(5))
      return 0 unless foe
      case cmd.param(6)
      when 0 then foe.hp
      when 1 then foe.mp || 0
      when 2 then foe.max_hp
      when 3 then foe.max_mp || 0
      when 4 then foe.atk
      when 5 then foe.def
      when 6 then foe.spi
      when 7 then foe.agi
      else 0
      end
    end

    # Operand type 7: a miscellaneous game quantity selected by param5 (0 party
    # gold, 1 timer seconds, 2 party members, 3 save count, 4 battle count,
    # 5 win count, 6 defeat count, 7 escape/run count). Remaining RPG2003-only
    # selectors are not modelled and read as 0.
    def other_operand(cmd)
      case cmd.param(5)
      when 0 then party.gold
      when 1 then @state.timer(0).seconds
      when 2 then party.actors.size
      when 3 then @state.save_count
      when 4 then @state.battle_count
      when 5 then @state.win_count
      when 6 then @state.defeat_count
      when 7 then @state.escape_count
      when 9 then @state.timer(1).seconds # RPG2003's second timer
      else 0
      end
    end

    def apply(op, cur, val)
      case op
      when 0 then val
      when 1 then cur + val
      when 2 then cur - val
      when 3 then cur * val
      when 4 then val == 0 ? cur : trunc_div(cur, val)
      when 5 then val == 0 ? 0 : trunc_mod(cur, val)
      else cur
      end
    end

    # Control Variables' divide/modulo operands (op 4/5 above) need C++'s
    # truncate-toward-zero division, not mruby's native `/`/`%`, which floor
    # toward negative infinity -- the two only agree when both operands share
    # a sign. EasyRPG's `Game_Variables::VarDiv`/
    # `VarMod` (`src/game_variables.cpp`) are plain `n / d` / `n % d` in C++,
    # so e.g. -7 / 2 is -3 there (truncated) but mruby's `-7 / 2` is -4
    # (floored); -7 % 2 is -1 in C++ (remainder takes the dividend's sign) but
    # 1 in mruby (remainder takes the divisor's sign). A divide by zero already
    # left the variable unchanged above, matching `VarDiv`'s own
    # `d != 0 ? n / d : n`; `VarMod` differs from that -- `d != 0 ? n % d : 0`
    # -- so a modulo by zero zeroes the variable instead.
    def trunc_div(n, d)
      q = n.abs / d.abs
      (n < 0) == (d < 0) ? q : -q
    end

    def trunc_mod(n, d)
      n - d * trunc_div(n, d)
    end

    # Timer: op 0 set (seconds), 1 start, 2 stop. Start carries the RPG2000
    # "show timer" flag in param 3 (param 4 is the run-in-battle flag, unused
    # here); stopping freezes the display but leaves it shown.
    # Timer Operation (10230). param0 is the operation (0 set, 1 start,
    # 2 stop); a set reads its seconds from param2, as a constant or through
    # param1 == 1 as a variable; a start carries the "show the timer" flag in
    # param3 and the "keep running in battle" flag in param4. param5 selects
    # *which* timer — RPG2003 has a second one, and RPG2000 data simply never
    # carries that parameter, so it reads 0 and addresses the only timer there.
    def do_timer(cmd)
      t = @state.timer(cmd.param(5))
      case cmd.param(0)
      when 0 then t.set(cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)])
      when 1 then t.start(cmd.param(3) != 0, cmd.param(4) != 0)
      when 2 then t.stop
      end
    end

    def do_change_gold(cmd)
      v = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      party.gain_gold(cmd.param(0) == 0 ? v : -v)
    end

    def do_change_items(cmd)
      item = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      amount = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
      party.gain_item(item, cmd.param(0) == 0 ? amount : -amount)
    end

    # Change Party Member (10330): add or remove the actor named by param2 (a
    # constant, or a variable when param1 is 1). Either can change who leads
    # the party — an add when the party was empty, a remove of the current
    # leader — and RPG_RT's `Game_Player::Refresh` runs on every such change,
    # not only on Change Sprite Association, so the on-screen hero sprite
    # (loaded from the leader's CharSet) has to be reloaded here too. Without
    # this a companion swap left the map showing whichever leader's graphic
    # happened to be cached, which for Nepheshel's 5205 Change Party Member
    # commands is most of the game. When this runs from a battle-event page
    # (@battle_screen set, see its own comment), also pushes the change to
    # the open battle screen's actor sprites and status window immediately.
    def do_change_party(cmd)
      id = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      added = cmd.param(0) == 0
      was_member = party.include_actor?(id)
      added ? party.add_actor(id) : party.remove_actor(id)
      # #add_actor/#remove_actor silently no-op on a full party, an unknown
      # roster id, or a redundant add/remove of an already-(non)member -- only
      # a genuine membership flip needs to reach the battle screen. Reads the
      # actor back from the roster (not @actors, which no longer holds it
      # after a remove) since #on_battle_party_changed needs the same
      # Game::Actor either way.
      if @battle_screen && party.include_actor?(id) != was_member
        actor = party.roster[id]
        @battle_screen.on_battle_party_changed(actor, added) if actor
      end
      @actor_graphic_changed = true
      check_game_over
    end

    # Did that command just wipe the party? RPG_RT re-asks after **every**
    # command that can knock a member out — Change Party Member / EXP / Level /
    # Parameters / Skills / Equipment / HP / MP / Condition, Full Heal, Simulated
    # Attack and Change Class — and drops straight into Game Over when the answer
    # is yes outside battle. Without it a Simulated Attack floor trap (850 of them
    # in Nepheshel) leaves the player walking around a map with a dead party.
    #
    # Two guards come with it, both EasyRPG's `Game_Interpreter::CheckGameOver`:
    # a **battle** page resolves its own defeat through the battle's own handler,
    # and an **empty** party is explicitly allowed — a game that has taken every
    # member away is between members, not over.
    #
    # Suspends on the same :game_over wait the Game Over command (12420) raises,
    # so the scene tears the play scenes down exactly as it already does. Returns
    # true when it fired, so a caller can drop what it was about to do.
    def check_game_over
      return false if @battle
      return false if party.actors.empty?
      return false unless party.all_dead?
      @wait_kind = :game_over
      @waiting = true
      true
    end

    # -- actor EXP / level ----------------------------------------------------

    # Change EXP: add (or, when the operation is "remove", subtract) an amount of
    # experience to the target actors, re-deriving each one's level and base
    # stats from the growth curve. Uses the same scope/operation/operand layout
    # as Change HP (stat_targets / stat_amount); the show-level-up-message flag is
    # ignored (no battle/message UI drives it here).
    # Change EXP: add or remove experience for the target actors, which may cross
    # one or more level thresholds. param5 is the "show message" flag — when set,
    # each level an actor gains queues a level-up message (drained by #resume).
    def do_change_exp(cmd)
      amount = stat_amount(cmd)
      show_msg = cmd.param(5) != 0
      stat_targets(cmd).each do |a|
        before = a.level
        before_skills = show_msg && a.respond_to?(:skills) ? a.skills.dup : []
        a.gain_exp(amount)
        queue_level_up_messages(a, before, a.level, before_skills) if show_msg
      end
      # RPG_RT asks about the wipe first: a level change that killed the party
      # goes to Game Over instead of announcing the level-up.
      return if check_game_over
      show_next_pending_message
    end

    # Change Level: add or subtract levels for the target actors, recomputing
    # their base stats and re-aligning EXP to the new level. Same scope/operation/
    # operand layout as Change EXP.
    # Change Level: add or remove levels for the target actors. param5 is the
    # "show message" flag — when set, each level an actor gains queues a level-up
    # message (drained by #resume).
    def do_change_level(cmd)
      amount = stat_amount(cmd)
      show_msg = cmd.param(5) != 0
      stat_targets(cmd).each do |a|
        before = a.level
        before_skills = show_msg && a.respond_to?(:skills) ? a.skills.dup : []
        a.change_level_by(amount)
        queue_level_up_messages(a, before, a.level, before_skills) if show_msg
      end
      return if check_game_over
      show_next_pending_message
    end

    # Queue one level-up message per level `actor` gained going from `old_level`
    # to `new_level` (nothing when the level did not rise). RPG_RT phrases these
    # from the database terms; this build uses a plain English line for now.
    #
    # Also queues one line per skill the growth/class table teaches at that
    # exact level, appended onto the same page as the level's own line -- the
    # missing half of this feature. EasyRPG's Game_Actor::ChangeLevel
    # (`src/game_actor.cpp`) calls LearnLevelSkills(old_level+1, new_level, pm)
    # right after pushing the level-up line and before PushPageEnd, and
    # LearnSkill only pushes ActorMessage::GetLearningMessage (the
    # `skill_learned` database term glued onto the skill's own name) for a
    # skill not already IsSkillLearned -- both are only reachable from
    # #do_change_exp/#do_change_level, which already call #set_level (and so
    # Actor#learn_level_skills) before this runs, so `before_skills` -- the
    # actor's own skill list snapshotted before that happened -- is what tells
    # a *newly* taught skill apart from one the actor already knew (an earlier
    # explicit Change Skill teach), matching EasyRPG's own IsSkillLearned guard
    # without re-deriving it. `before_skills` is an empty array when the
    # caller's own show-message flag was off (nothing here runs then anyway)
    # or `actor` is a minimal stub with no #skills of its own (a handful of
    # scene-level fixtures exercise only the level line, never the skill
    # table) -- `actor.respond_to?(:learn_table)` guards the same stub case
    # for the skill lookup below.
    def queue_level_up_messages(actor, old_level, new_level, before_skills)
      return unless new_level > old_level
      ((old_level + 1)..new_level).each do |lv|
        lines = [level_up_message(actor, lv)]
        if actor.respond_to?(:learn_table)
          actor.learn_table.each do |sid, at|
            next unless at == lv && !before_skills.include?(sid)
            sk = party.db_skill(sid)
            lines.push(skill_learned_message(actor, sk)) if sk
          end
        end
        @pending_messages.push(lines)
      end
    end

    # The one line a level-up announces. RPG_RT phrases it from the database
    # terms; this build uses a plain English line for now.
    def level_up_message(actor, level)
      "#{actor.name} is now level #{level}!"
    end

    # The one line a newly-learned skill announces, immediately following its
    # level's own level-up line. RPG_RT glues the skill's own name onto the
    # `skill_learned` database term (EasyRPG's ActorMessage::GetLearningMessage,
    # `src/game_message_terms.cpp`); this build uses a plain English line for
    # now, matching #level_up_message's own documented simplification.
    def skill_learned_message(actor, sk)
      "#{actor.name} learned #{sk.name}!"
    end

    # Enter the next queued level-up message as a :message wait; returns false
    # (and does nothing) when the queue is empty.
    def show_next_pending_message
      return false if @pending_messages.empty?
      @message_lines = @pending_messages.shift
      # Not a user-authored Show Text block, so it never keeps the window open
      # for a following Show Choices / Input Number -- clear any followup left
      # over from an earlier, unrelated message.
      @message_followup = nil
      @wait_kind = :message
      @waiting = true
      true
    end

    # -- actor HP / MP --------------------------------------------------------

    # The actors a stat-change command targets. param0 selects the scope: 0 the
    # whole party, 1 a fixed actor id (param1), 2 the actor whose id is held in
    # variable param1.
    #
    # Only scope 0 means "the party". A **named** actor is looked up in the
    # roster, so the command reaches one who is currently out of the party —
    # RPG_RT's `Game_Interpreter::GetActors`, which reads the party for scope 0
    # and `Game_Actors::GetActor` for the other two. That distinction is the
    # whole point in a game that swaps members: **every** fixed-id stat command
    # in Nepheshel (7805 of them — Change Skills on actor 1 alone is 2871) names
    # an actor the game also dismisses, so treating a named target as
    # party-only silently dropped the lot whenever that actor was away. With
    # actors persisting (ADR 0030) such a miss is permanent: the skill is never
    # learned rather than being re-granted on the next rebuild.
    def stat_targets(cmd)
      case cmd.param(0)
      when 0 then party.actors
      when 1 then [party.roster[cmd.param(1)]].compact
      when 2 then [party.roster[variables[cmd.param(1)]]].compact
      else []
      end
    end

    # The signed amount a HP/MP change applies: param2 is the operation (0 add,
    # 1 remove) and param3/param4 the operand (0 constant / 1 variable, value).
    def stat_amount(cmd)
      amount = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
      cmd.param(2) == 0 ? amount : -amount
    end

    # Change HP: param5 is the "allow death" flag (0 floors HP at 1, 1 permits 0).
    def do_change_hp(cmd)
      amount = stat_amount(cmd)
      allow_death = cmd.param(5) != 0
      stat_targets(cmd).each { |a| a.change_hp(amount, allow_death) }
      check_game_over
    end

    def do_change_mp(cmd)
      amount = stat_amount(cmd)
      stat_targets(cmd).each { |a| a.change_mp(amount) }
      check_game_over
    end

    # Full recovery: restore HP and MP to their maxima for the target actors.
    def do_full_heal(cmd)
      stat_targets(cmd).each { |a| a.full_heal }
      check_game_over
    end

    # Simulated Attack (10500): hurt the target actors with an attack that has no
    # attacker — the event supplies the attack power itself. param0/param1 pick
    # the targets (the shared scope layout); param2 is the attack strength,
    # param3 how much the target's defence counts and param4 how much its spirit
    # counts, each as a permille-style divisor, and param5 the damage spread (the
    # database's own 0-10 variance scale, the same one a skill's own `variance`
    # field uses). When param6 is set the damage dealt is also written into
    # variable param7. The formula is EasyRPG Player's CommandSimulatedAttack,
    # which mirrors RPG_RT: `atk - def * p_def / 400 - spi * p_spi / 800`, floored
    # at 0, then spread by `Algo::VarianceAdjustEffect` and floored at 0 again.
    # The hit can be lethal.
    #
    # RPG_RT's damage popup is a fixed-width widget (the same reasoning behind
    # `Game::Battle#damage_cap` on the normal-attack/skill/self-destruct/
    # slip-damage paths -- edition-gated the same way, 999 on RPG2000, 9999
    # on RPG2003), so a Simulated Attack's own computed damage is clamped
    # too before it reaches HP or the result variable.
    def do_simulated_attack(cmd)
      atk = cmd.param(2)
      damage = 0
      cap = @state.party.rpg2003? ? Battle::DAMAGE_CAP_2K3 : Battle::DAMAGE_CAP_2K
      stat_targets(cmd).each do |a|
        damage = atk - (a.def * cmd.param(3)) / 400 - (a.int * cmd.param(4)) / 800
        damage = 0 if damage < 0
        damage = simulated_attack_variance(damage, cmd.param(5))
        damage = 0 if damage < 0
        damage = cap if damage > cap
        a.change_hp(-damage, true)
      end
      variables[cmd.param(7)] = damage if cmd.param(6) != 0
      check_game_over
    end

    # A Simulated Attack's random damage spread. Port of EasyRPG's
    # `Algo::VarianceAdjustEffect` -- the exact same formula
    # `Game::Battle#varied` already applies to a normal attack/skill/
    # self-destruct's own damage -- reimplemented here rather than shared
    # across classes, since `#varied` lives on `Battle`, not `Interpreter`.
    #
    # A prior version of this method modelled the spread as a flat +/-
    # (variance * 5) *percent* of `base` instead, which the doc comment above
    # incorrectly attributed to EasyRPG's own source. The two formulas'
    # outer bounds happen to coincide (`base +/- base*var/20` either way),
    # but the percent model's granularity is coarser by a factor of `100 /
    # base` -- e.g. at `base` 500, `var` 5, the percent model can only ever
    # land on one of 51 values, all multiples of 5, where the real formula
    # (`adj = max(1, var*base/10)`, `base + rand(0, adj) - adj/2`) draws
    # uniformly from 251 consecutive integers over the identical [375, 625]
    # range. #varied's own floor of (at least) 1 does not apply here: a
    # Simulated Attack's own real clamp is `std::max(0, result)`, applied
    # both before and after the variance call, so this can land on a
    # genuine 0 the way #varied's callers never do.
    def simulated_attack_variance(base, var)
      return base unless var && var > 0 && base > 0
      adj = var * base / 10
      adj = 1 if adj < 1
      base + @rng.random(adj + 1) - adj / 2
    end

    # Change Condition: inflict or cure a status condition on the target actors.
    # param0/param1 pick the targets (same scope layout as Change HP); param2 is
    # the operation (0 add / inflict, non-zero remove / cure) and param3 the state
    # id. Removing the death state (戦闘不能) revives a downed actor; inflicting it
    # knocks the actor out — the HP coupling lives in Game::Actor.
    def do_change_condition(cmd)
      state_id = cmd.param(3)
      remove = cmd.param(2) != 0
      stat_targets(cmd).each do |a|
        if remove
          a.remove_state(state_id)
        else
          a.add_state(state_id)
          # RPG_RT's crowding-out rule (Game::States::PRUNE_GAP): a state
          # just inflicted may push out (or itself be pushed out by) one
          # already held that outranks it by 10+ priority.
          a.states = Game::States.prune(a.states, party.state_table)
        end
      end
      check_game_over
    end

    # -- RPG2003 class / battle commands --------------------------------------

    # Change Class (1008), an RPG2003-only command: move the target actor(s) to
    # database class param2 (0 = no class). param3 sets the level to 1 rather
    # than keeping the current one, param4 is the skill mode and param5 the
    # parameter mode (see Game::Actor::CLASS_SKILL_* / CLASS_PARAM_*), and param6
    # is the "show level-up message" flag the Change Level command also carries.
    # An RPG2000 project cannot emit this, and a database without a class table
    # leaves every actor class-less, so the command self-limits to 2003 data.
    def do_change_class(cmd)
      class_id = cmd.param(2)
      level_1 = cmd.param(3) != 0
      skill_mode = cmd.param(4)
      param_mode = cmd.param(5)
      show_msg = cmd.param(6) != 0
      stat_targets(cmd).each do |a|
        before = a.level
        before_skills = show_msg && a.respond_to?(:skills) ? a.skills.dup : []
        next unless a.change_class(class_id, level_1 ? 1 : a.level,
                                   skill_mode, param_mode)
        # Unlike Change Level (which announces every level crossed) RPG_RT shows
        # a single line here, and shows it whenever the class change taught new
        # skills even if the level itself did not move (EasyRPG's ChangeClass,
        # which calls the identical LearnLevelSkills(1, new_level, pm) Change
        # Level/Change EXP use -- see queue_level_up_messages's own comment).
        # The actual skill diff (rather than a skill-mode guess) also decides
        # whether there is anything to announce at all: a RESET/ADD class swap
        # that happens to teach nothing the actor didn't already know stays
        # quiet, matching a level that didn't move.
        next unless show_msg
        new_skills = a.respond_to?(:skills) ? a.skills - before_skills : []
        next unless a.level > 1 && (a.level > before || !new_skills.empty?)
        lines = [level_up_message(a, a.level)]
        new_skills.each do |sid|
          sk = party.db_skill(sid)
          lines.push(skill_learned_message(a, sk)) if sk
        end
        @pending_messages.push(lines)
      end
      return if check_game_over
      show_next_pending_message
    end

    # Change Battle Commands (1009), RPG2003-only: add (param3 non-zero) or
    # remove battle command param2 from the target actor(s). Removing command 0
    # clears the list back to the Row entry alone.
    def do_change_battle_commands(cmd)
      cmd_id = cmd.param(2)
      add = cmd.param(3) != 0
      stat_targets(cmd).each { |a| a.change_battle_commands(add, cmd_id) }
    end

    # -- actor identity / graphic ---------------------------------------------

    # Every command in this group names its actor by a fixed id in param0, and
    # RPG_RT resolves all of them through `Game_Actors::GetActor` — the roster,
    # not the party — so a companion who is currently away is still renamed,
    # re-dressed and re-portraited, and has it waiting when they rejoin. nil only
    # for an id the database has no row for.
    def identity_target(cmd); party.roster[cmd.param(0)]; end

    # Change Actor Name: rename the actor whose id is param0 to the command
    # string. A blank name is ignored (RPG_RT keeps the previous name).
    def do_change_actor_name(cmd)
      name = cmd.string
      return if name.nil? || name.empty?
      actor = identity_target(cmd)
      actor.name = name if actor
    end

    # Change Actor Title: set the title (class/subtitle shown on the status
    # screen) of the actor whose id is param0 to the command string. An empty
    # string clears the title.
    def do_change_actor_title(cmd)
      actor = identity_target(cmd)
      actor.title = cmd.string || '' if actor
    end

    # Change Sprite Association (Change Actor Graphic): give the actor whose id is
    # param0 a new CharSet graphic — the command string names the file, param1 is
    # the cell index and param2 the transparency flag (non-zero hides the sprite).
    # Records a one-shot request so the owning scene can reload the party leader's
    # on-screen sprite.
    def do_change_actor_sprite(cmd)
      actor = identity_target(cmd)
      return unless actor
      actor.set_charset(cmd.string || '', cmd.param(1))
      actor.transparent = cmd.param(2) != 0
      @actor_graphic_changed = true
    end

    # Change Actor Face (10640): give the actor whose id is param0 a new FaceSet
    # graphic — the command string names the file and param1 the cell index. This
    # is the actor's own portrait (menus, the save-select screen), not the message
    # face a Change Face Graphic (10130) selects, so nothing on the map reloads.
    def do_change_actor_face(cmd)
      actor = identity_target(cmd)
      return unless actor
      actor.set_faceset(cmd.string || '', cmd.param(1))
    end

    # The vehicle a vehicle command targets: param0 is 0 boat / 1 ship /
    # 2 airship (Game::Vehicle::TYPES order), or nil for an out-of-range value.
    def vehicle_target(cmd)
      type = Vehicle::TYPES[cmd.param(0)]
      type && @state.vehicle(type)
    end

    # Set Vehicle Location (10850): place a vehicle on a map. param0 is the
    # vehicle; param1 the operand mode (0 the values are literal, 1 they are
    # variable ids), and param2/param3/param4 the map id, x and y (like Change
    # Event Location's designation). A no-op for an out-of-range vehicle.
    #
    # EasyRPG's own `CommandSetVehicleLocation` (`src/game_interpreter.cpp`):
    # "Check if the party is in the current vehicle and transfer the party
    # together with it" — when the party is currently boarded on the vehicle
    # this command targets *and* the destination is the map they are already
    # on, `Game_Player::MoveTo` runs alongside the vehicle's own move. A
    # cross-map destination goes through a materially different "quick
    # teleport" path (an async map switch with no transition) that this fix
    # deliberately leaves alone — only the same-map case is ported here.
    # Without this, relocating the vehicle the party is riding did nothing
    # visible at all: rendering while boarded follows the *player's* position,
    # not the vehicle's, and the party's own `@state.x`/`@state.y` were never
    # touched, so the very next completed step's `#follow_vehicle` silently
    # overwrote the vehicle back to the party's still-unmoved tile.
    def do_set_vehicle_location(cmd)
      type = Vehicle::TYPES[cmd.param(0)]
      v = type && @state.vehicle(type)
      return unless v
      map_id = cmd.param(2)
      x = cmd.param(3)
      y = cmd.param(4)
      if cmd.param(1) == 1
        map_id = variables[map_id]
        x = variables[x]
        y = variables[y]
      end
      v.map_id = map_id
      v.x = x
      v.y = y
      return unless @state.boarded == type && map_id == @state.map_id
      @location_requests.push({ op: :set, target: CHAR_PLAYER, x: x, y: y })
    end

    # Change Vehicle Graphic (10650): give a vehicle a new CharSet graphic — the
    # command string names the file and param1 the cell index. A no-op for an
    # out-of-range vehicle.
    def do_change_vehicle_graphic(cmd)
      v = vehicle_target(cmd)
      return unless v
      v.charset_name = cmd.string || ''
      v.charset_index = cmd.param(1)
    end

    # Change Parameters: adjust a base stat. param3 selects the stat (0 max HP,
    # 1 max MP, 2 attack, 3 defence, 4 spirit/int, 5 agility), param2 is the
    # operation (0 add, 1 remove) and param4/param5 the operand (0 constant /
    # 1 variable, value).
    def do_change_params(cmd)
      type = cmd.param(3)
      amount = cmd.param(4) == 0 ? cmd.param(5) : variables[cmd.param(5)]
      amount = -amount if cmd.param(2) != 0
      stat_targets(cmd).each { |a| a.change_param(type, amount) }
      check_game_over # a lowered max HP can knock the party out
    end

    # Change Skills (10440): teach or remove a skill. param0/param1 pick the
    # targets (the shared scope layout), param2 is the operation (0 learn, 1
    # forget) and param3/param4 the skill operand (0 = the id in param4, 1 = the
    # id held in variable param4). Skill id 0 is the editor's "none" and is
    # ignored.
    def do_change_skills(cmd)
      skill_id = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
      return if skill_id.nil? || skill_id <= 0
      forget = cmd.param(2) != 0
      stat_targets(cmd).each do |a|
        forget ? a.forget_skill(skill_id) : a.learn_skill(skill_id)
      end
      check_game_over
    end

    # Change Equipment (10450). param2 selects the operation: 0 equips an item
    # (param3 0 = the item id in param4, 1 = the id held in variable param4) into
    # the slot matching its type; 1 removes equipment, param4 selecting the slot
    # (0..4, or 5 for every slot). Confirmed against real events, e.g.
    # `[1, 3, 0, 0, 127]` equips armour 127 onto actor 3.
    #
    # Both operations swap through the party's bag, same as the equip menu
    # (`Game::Party#equip_item_from_bag` / `#unequip_to_bag`) -- confirmed
    # against real RPG_RT by community デフォ戦bot trivia: equipping consumes
    # a held copy from the bag, or fabricates a new one if the party has none,
    # and whatever was previously equipped comes back to the bag either way.
    def do_change_equipment(cmd)
      targets = stat_targets(cmd)
      if cmd.param(2) == 0
        item = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
        it = party.db_item(item)
        # An actor_set restriction blocks this command the same way it blocks
        # the equip menu (EasyRPG's ChangeEquipment reads Game_Actor::
        # IsItemUsable too) -- per target, since one target of a multi-actor
        # command might be allowed the item and another not.
        targets.each { |a| party.equip_item_from_bag(a, item) if party.item_usable_by?(it, a.id) }
      else
        targets.each { |a| party.unequip_to_bag(a, cmd.param(4)) }
      end
      check_game_over # losing an item's max-HP bonus can knock the party out
    end

    # -- battle-event commands ------------------------------------------------
    #
    # These only appear in a troop's battle-event pages and act on the fight the
    # owning battle scene put in `@battle`. Without one (a stray battle command
    # in a map event, or a headless check) every one of them is a no-op.

    # The amount a Change Monster HP / MP command applies. param2 selects how
    # param3 is read: 0 a constant, 1 the value of that variable, 2 (HP only) a
    # percentage of the target's maximum. Mirrors EasyRPG's
    # CommandChangeMonsterHP / CommandChangeMonsterMP.
    def monster_change_amount(cmd, battler)
      case cmd.param(2)
      when 1 then variables[cmd.param(3)]
      when 2 then cmd.param(3) * (battler.max_hp || 0) / 100
      else cmd.param(3)
      end
    end

    # Change Monster HP (13110): heal or hurt troop member param0. param1 is the
    # direction (non-zero = lose HP), param2/param3 the amount (see above) and
    # param4 whether the damage may be lethal — when it may not, the monster is
    # left on 1 HP instead of going down.
    def do_change_monster_hp(cmd)
      target = @battle && @battle.enemy(cmd.param(0))
      return unless target
      amount = monster_change_amount(cmd, target)
      amount = -amount if cmd.param(1) != 0
      # yado.tk quirk: a downed (0 HP) enemy stays down. A positive amount
      # here is a no-op on an already-dead target -- like Game::Actor#change_hp,
      # clearing the KO needs Change State / Full Recovery even after this
      # would otherwise put it back above 0. A further (negative) hit on a
      # dead target is left alone: it just re-clamps to the same floor below.
      return if target.dead? && amount > 0
      hp = target.hp + amount
      floor = cmd.param(4) != 0 ? 0 : 1
      hp = floor if hp < floor
      hp = target.max_hp if target.max_hp && hp > target.max_hp
      target.hp = hp
    end

    # Change Monster MP (13120): the SP counterpart. Same operand layout minus
    # the percentage mode and the lethal flag.
    def do_change_monster_mp(cmd)
      target = @battle && @battle.enemy(cmd.param(0))
      return unless target
      amount = monster_change_amount(cmd, target)
      amount = -amount if cmd.param(1) != 0
      mp = (target.mp || 0) + amount
      mp = 0 if mp < 0
      mp = target.max_mp if target.max_mp && mp > target.max_mp
      target.mp = mp
    end

    # Change Monster Condition (13130): inflict (param1 == 0) or cure the status
    # param2 on troop member param0.
    def do_change_monster_condition(cmd)
      target = @battle && @battle.enemy(cmd.param(0))
      return unless target
      state_id = cmd.param(2)
      return if state_id.nil? || state_id <= 0
      states = target.states ||= []
      if cmd.param(1) != 0
        states.delete(state_id)
      elsif !states.include?(state_id)
        states.push(state_id)
      end
    end

    # Show Hidden Monster (13150): bring troop member param0 — placed but held
    # off-screen by its "invisible" flag — into the fight. Recorded as a one-shot
    # request so the scene can build the sprite that was never made.
    def do_show_hidden_monster(cmd)
      return unless @battle
      @revealed_monsters.push(cmd.param(0))
    end

    # Force Flee (1006), RPG2003-only: make somebody leave the fight. param0
    # picks who — 0 the party (which only *grants* the escape: the player still
    # has to choose Flee, and then always succeeds), 1 every troop member still
    # standing, 2 the single member param1. param2 is RPG_RT's "check the battle
    # condition" flag, which suppresses the flee in a pincer / surround ambush;
    # this runtime models neither formation, so every fight counts as a normal
    # one and the flee always goes ahead. Enemies that leave are recorded so the
    # scene can drop their sprites and play the escape sound. Matches EasyRPG's
    # own `Game_Interpreter_Battle::CommandForceFlee`
    # (src/game_interpreter_battle.cpp): `if (!Player::IsRPG2k3Commands()) {
    # return true; }` -- the RPG2003 editor's battle event editor is the only
    # one with this command at all, so a genuine RPG2000 database's own
    # command list should never carry it, but an unguarded dispatch reads it
    # as live the instant one does.
    def do_force_flee(cmd)
      return unless @battle && @state.party.rpg2003?
      case cmd.param(0)
      when 0 then @battle.force_flee_party
      when 1 then @fled_monsters.concat(@battle.flee_all_enemies)
      when 2
        index = cmd.param(1)
        @fled_monsters.push(index) if @battle.flee_enemy(index)
      end
    end

    # Enable Combo (1007), RPG2003-only: arm actor param0's battle command param1
    # to repeat param2 times. The actor is named by id, so it resolves through the
    # roster like the other fixed-id commands. Recorded on the actor; the ATB
    # battle system that spends a combo is not modelled here, so nothing acts on
    # it yet. Matches EasyRPG's own `Game_Interpreter_Battle::
    # CommandEnableCombo` (src/game_interpreter_battle.cpp), the same
    # `IsRPG2k3Commands()` gate as Force Flee above.
    def do_enable_combo(cmd)
      return unless @battle && @state.party.rpg2003?
      actor = identity_target(cmd)
      return unless actor
      actor.set_battle_combo(cmd.param(1), cmd.param(2))
    end

    # Call Common Event (1005), the RPG2003 battle page's own call command:
    # param0 is the common event id, and unlike the map's Call Event (12330)
    # there is no map-event form. Runs through the same call stack. Matches
    # EasyRPG's own `Game_Interpreter_Battle::CommandCallCommonEvent`
    # (src/game_interpreter_battle.cpp), the same `IsRPG2k3Commands()` gate
    # as Force Flee/Enable Combo above.
    def do_call_common_event(cmd)
      return unless @resolver && @state.party.rpg2003?
      cmds = common_event_commands(cmd.param(0))
      return if cmds.nil? || cmds.empty?
      return if @call_stack.size >= MAX_CALL_DEPTH
      @call_stack.push [@list, @index]
      @list = cmds
      @index = 0
    end

    def common_event_commands(id)
      @resolver.common_event_commands(id)
    rescue StandardError => e
      $stderr.puts "[RPG2k] Call Common Event #{id} failed: #{e.message}"
      nil
    end

    # Change Battle Background (13210): swap the backdrop to the Backdrop/<name>
    # image the command string carries. Recorded for the scene to rebuild.
    def do_change_battle_bg(cmd)
      return unless @battle
      @battle_background = (cmd.string || '').to_s
    end

    # Show Battle Animation (13260), the battle-page form of 11210. param0 is
    # the animation, param1 the target troop member and param2 the wait flag.
    # RPG2003 adds an Ally/Enemy radio button to the command's target picker,
    # stored as a param3 flag -- matches EasyRPG's own
    # `Game_Interpreter_Battle::CommandShowBattleAnimation`
    # (src/game_interpreter_battle.cpp): `allies = com.parameters[3] != 0`,
    # read only `if (Player::IsRPG2k3() && com.parameters.size() > 3)`, same
    # gate already used for Flash/Shake Screen's own trailing RPG2003
    # parameter. Raised through the same request/wait the map command uses,
    # so the scene drives one animation player for both.
    def do_show_battle_animation_b(cmd)
      allies = @state.party.rpg2003? && cmd.parameters.size > 3 && cmd.param(3) != 0
      @battle_animation = { animation: cmd.param(0), target: cmd.param(1),
                            wait: cmd.param(2) != 0, battle: true, allies: allies }
      return unless cmd.param(2) != 0
      @wait_kind = :animation
      @waiting = true
    end

    # Terminate Battle (13410): end the fight immediately, with no victory or
    # defeat processing. The rest of the page is abandoned, as in RPG_RT.
    def do_terminate_battle(_cmd)
      return unless @battle
      @battle.terminate
      @index = @list.size
      @call_stack = []
    end

    # Conditional Branch (battle form, 13310). param0 selects the test:
    #   0 switch param1 is on (param2 == 0) / off
    #   1 variable param1 compared against param2/param3 by param4
    #   2 actor param1 — sub-test param2: 0 in the party, 1 named param(?),
    #     2 afflicted by state param3, 3 can use battle command param3
    #   3 troop member param1 — sub-test param2: 0 present, 1 afflicted by
    #     state param3
    #   4 the currently-targeted troop member is param1
    #   5 actor param1's chosen command is param2
    # Tests 4 and 5 read live battle-UI state the runtime does not model; they
    # report false rather than guessing, so the else branch runs. Actor
    # sub-test 3 ("can use battle command") is implemented; sub-test 1
    # ("named") is not -- see #battle_actor_condition for why.
    def do_conditional_battle(cmd)
      return if eval_battle_condition(cmd)
      skip_to([Cmd::ELSE_BRANCH_B, Cmd::END_BRANCH_B], cmd.indent)
      consume
    end

    def eval_battle_condition(cmd)
      case cmd.param(0)
      when 0
        on = switches[cmd.param(1)]
        cmd.param(2) == 0 ? on : !on
      when 1
        rhs = cmd.param(2) == 0 ? cmd.param(3) : variables[cmd.param(3)]
        compare(variables[cmd.param(1)], rhs, cmd.param(4))
      when 2 then battle_actor_condition(cmd)
      when 3 then battle_enemy_condition(cmd)
      else false
      end
    end

    # An actor sub-condition: is the actor in this fight, is it afflicted by
    # the given status, and can it currently be handed a battle command?
    #
    # Sub-test 3 mirrors EasyRPG's `Game_Battler::CanAct` (via
    # `Game_Interpreter_Battle::CommandConditionalBranchBattle`'s actor case):
    # true unless the ally carries a "do nothing" restriction (asleep /
    # paralysed). A Berserk (attack_enemy) or Confusion (attack_ally)
    # restriction does NOT fail this test -- such an ally still "can act", it
    # just acts on a forced target instead of the chosen command, which is why
    # this calls Game::Battle's do_nothing-only check rather than its broader
    # #command_restricted? (which also flags Berserk/Confusion because it
    # answers a different question: "does this ally get a normal command
    # menu").
    #
    # Sub-test 1 ("named") has no real counterpart to implement: EasyRPG's
    # actual actor case never sub-dispatches on a second parameter at all --
    # it unconditionally resolves to CanAct() using only the actor id. There
    # is no known "named" behavior to match, so it reports false.
    def battle_actor_condition(cmd)
      ally = @battle && @battle.ally_by_actor_id(cmd.param(1))
      return false unless ally
      case cmd.param(2)
      when 0 then true                                  # is in the party
      when 2 then ally.state?(cmd.param(3))              # is afflicted by a status
      when 3 then !@battle.do_nothing_restricted?(ally)  # can use a battle command
      else false
      end
    end

    # A troop-member sub-condition: is the member still standing, and is it
    # afflicted by the given status?
    def battle_enemy_condition(cmd)
      foe = @battle && @battle.enemy(cmd.param(1))
      return false unless foe
      case cmd.param(2)
      when 0 then !foe.dead?
      when 1 then foe.state?(cmd.param(3))
      else false
      end
    end

    # -- conditional branch ---------------------------------------------------

    def do_conditional(cmd)
      @last_condition_matched = eval_condition(cmd)
      return if @last_condition_matched # fall through into the true branch
      skip_to([Cmd::ELSE_BRANCH, Cmd::END_BRANCH], cmd.indent)
      consume # step past the else/end marker to run the else body (or continue)
    end

    def eval_condition(cmd)
      case cmd.param(0) # condition type
      when 0 # switch: param1 id, param2 state (0 on / 1 off)
        on = switches[cmd.param(1)]
        cmd.param(2) == 0 ? on : !on
      when 1 # variable: param1 id, param2 operand type, param3 operand, param4 comparison
        rhs = cmd.param(2) == 0 ? cmd.param(3) : variables[cmd.param(3)]
        compare(variables[cmd.param(1)], rhs, cmd.param(4))
      when 2 # timer: param1 seconds, param2 comparison (0 >=, 1 <=)
        timer_condition(cmd, 0)
      when 3 # gold: param1 amount, param2 comparison (0 >=, 1 <=)
        cmd.param(2) == 0 ? party.gold >= cmd.param(1) : party.gold <= cmd.param(1)
      when 4 # item: param1 id, param2 (0 has / 1 not)
        has = party.has_item?(cmd.param(1))
        cmd.param(2) == 0 ? has : !has
      when 5 # actor: param1 id, param2 sub-condition (see actor_condition)
        actor_condition(cmd)
      when 6 # orientation: is character param1 (10001 the hero, 0 / 10005 this
             # event, any other positive id a map event) facing direction param2
             # (0 up / 1 right / 2 down / 3 left)?
        facing = character_facing(cmd.param(1))
        !facing.nil? && facing == FACING_NUMPAD[cmd.param(2)]
      when 7 # vehicle: true when the party is riding vehicle param1 (0 boat /
             # 1 ship / 2 airship)
        v = cmd.param(1)
        v >= 0 && v < Vehicle::TYPES.size && @state.boarded == Vehicle::TYPES[v]
      when 8 # the decision (action) key started this event
        @triggered_by_decision_key ? true : false
      when 9 # the BGM has played through at least once
        @state.bgm_looped ? true : false
      when 10 # RPG2003's second timer, laid out exactly like type 2
        # EasyRPG's own CommandConditionalBranch (src/game_interpreter.cpp)
        # only evaluates this case at all `if (Player::IsRPG2k3Commands())`
        # -- on an RPG2000 database `result` is left at its initial `false`,
        # the same "unhandled type" answer the `else` arm below already
        # gives, not a live comparison against Timer2 (which RPG2000 has no
        # editor control to even set up a Conditional Branch against).
        party.rpg2003? && timer_condition(cmd, 1)
      else
        # An unhandled/unsupported branch type (RPG2003 v1.11's own type 11
        # "EX" conditions -- savestate available, Test Play, ATB-wait,
        # fullscreen -- Maniac Patch types 12-16, or malformed data) defaults
        # to false, taking the else branch, not the true one. Confirmed
        # against EasyRPG's `Game_Interpreter::CommandConditionalBranch`
        # (src/game_interpreter.cpp): `result` is initialized `false` at the
        # top of the function and is only ever set inside a matched `case`;
        # its `default:` arm only logs a warning, leaving `result` at its
        # initial `false`.
        false
      end
    end

    # The timer conditions (type 2 the first timer, type 10 RPG2003's second):
    # param1 is the seconds to compare against and param2 the comparison
    # (0 "at least", 1 "at most").
    def timer_condition(cmd, id)
      secs = @state.timer(id).seconds
      cmd.param(2) == 0 ? secs >= cmd.param(1) : secs <= cmd.param(1)
    end

    # Orientation directions (0 up / 1 right / 2 down / 3 left) mapped to the
    # runtime's 2/4/6/8 numpad facing, matching EasyRPG's facing enum.
    FACING_NUMPAD = [8, 6, 2, 4].freeze

    # The numpad facing (2/4/6/8) of the character referenced by `ref` (10001 the
    # hero, 0 / 10005 this event, any other positive id a map event), or nil when
    # it can't be resolved (no map_info, an unknown event, a "this event" outside
    # a map event, or a still-unmodelled vehicle ref).
    def character_facing(ref)
      id = character_ref(ref)
      return nil if id.nil?
      if id == CHAR_PLAYER
        @state.direction
      elsif id > 0 && id < 10000 && @map_info.respond_to?(:event_position)
        pos = @map_info.event_position(id)
        pos && pos[:direction]
      end
    end

    # Conditional type 5 (actor/hero): param1 is the actor id, param2 selects the
    # sub-condition — 0 in party, 1 name equals the command string, 2 level >=
    # param3, 3 HP >= param3, 4 knows skill param3, 5 has item param3 equipped,
    # 6 afflicted by state param3.
    #
    # Only sub-condition 0 asks the party; the rest ask the **actor**, through
    # the roster, exactly as RPG_RT splits them (`IsActorInParty` versus
    # `Game_Actors::GetActor`). The distinction decides which branch runs, and
    # real data leans on it: Nepheshel writes 28 "is in the party" tests and 243
    # state tests, all of the latter naming a companion it also dismisses — so
    # answering them from the party alone sent every one down the false branch
    # while that companion was away. A missing database row is still false.
    def actor_condition(cmd)
      id = cmd.param(1)
      return party.include_actor?(id) if cmd.param(2) == 0
      actor = party.roster[id]
      return false unless actor
      case cmd.param(2)
      when 1 then actor.name == cmd.string
      when 2 then actor.level >= cmd.param(3)
      when 3 then actor.hp >= cmd.param(3)
      when 4 then actor.knows_skill?(cmd.param(3))
      when 5 then actor.equipped?(cmd.param(3))
      when 6 then actor.state?(cmd.param(3))
      else false
      end
    end

    def compare(a, b, op)
      case op
      when 0 then a == b
      when 1 then a >= b
      when 2 then a <= b
      when 3 then a > b
      when 4 then a < b
      when 5 then a != b
      else false
      end
    end

    # -- UI / map requests ----------------------------------------------------

    # Teleport (10810): move the party to map param0 at (param1, param2).
    #
    # param3 is an **RPG2003** addition: the facing to arrive in, 1-based over
    # the editor's up / right / down / left, with 0 meaning "keep the current
    # one". It is not the runtime's 2/4/6/8 numpad direction, and passing it
    # through raw set two of the four values to numbers that are not directions
    # at all (1 and 3, which no delta or charset row matches) and a third to the
    # wrong one — only "left" happened to line up. An RPG2000 project writes 0
    # here, so converting unconditionally is the same as EasyRPG's
    # `IsRPG2k3Commands` guard for the games that can emit it.
    def do_teleport(cmd)
      @teleport = [cmd.param(0), cmd.param(1), cmd.param(2),
                   teleport_facing(cmd.param(3))]
      @wait_kind = :teleport
      @waiting = true
    end

    # The numpad facing a Teleport's 1-based direction argument names, or 0 for
    # "keep the current facing" (which is what an out-of-range value means too).
    def teleport_facing(param)
      return 0 unless param && param >= 1 && param <= FACING_NUMPAD.size
      FACING_NUMPAD[param - 1]
    end

    # Memorize Location: store the player's current map id, x and y into the
    # three variables named by param0/param1/param2. Non-blocking — it only
    # records the position for a later Recall to Location.
    def do_memorize_location(cmd)
      variables[cmd.param(0)] = @state.map_id
      variables[cmd.param(1)] = @state.x
      variables[cmd.param(2)] = @state.y
    end

    # Recall to Location: teleport to the map / x / y held in the three variables
    # named by param0/param1/param2 (the counterpart to Memorize Location).
    # Routed through the same teleport request the Teleport command raises, so
    # the owning scene loads the map and moves the player; the current facing is
    # kept (direction 0).
    def do_recall_location(cmd)
      @teleport = [variables[cmd.param(0)], variables[cmd.param(1)],
                   variables[cmd.param(2)], 0]
      @wait_kind = :teleport
      @waiting = true
    end

    # Change Event Location (Set Event Location): instantly place a character on
    # the current map at a tile. param0 selects the target (10001 player, 0 /
    # 10005 this event, else a map event id); param1 the appointment mode (0 the
    # constants param2/param3, 1 the values of those two variables); param2/param3
    # the x and y. Queued as a `:set` request the scene applies — non-blocking,
    # so the rest of the command list runs on.
    #
    # param4 is the same **RPG2003** facing addition Teleport's own param3 is
    # (EasyRPG's `CommandChangeEventLocation`, `src/game_interpreter.cpp`: `if
    # (Player::IsRPG2k3Commands() && com.parameters.size() > 4) direction =
    # com.parameters[4] - 1;`), 1-based over up/right/down/left, 0 (or absent,
    # which `#param` already reads as 0) meaning "keep the current facing" —
    # `#teleport_facing` already converts that exact encoding into this
    # runtime's own numpad direction, so it is reused verbatim here rather
    # than duplicated. EasyRPG only applies it "for the constant case, not
    # for variables" (its own comment) -- the appointment-mode check below
    # mirrors that.
    def do_change_event_location(cmd)
      x = cmd.param(2)
      y = cmd.param(3)
      variable_mode = cmd.param(1) == 1
      if variable_mode
        x = variables[x]
        y = variables[y]
      end
      dir = variable_mode ? 0 : teleport_facing(cmd.param(4))
      @location_requests.push({ op: :set, target: cmd.param(0), x: x, y: y, dir: dir })
    end

    # Trade Event Locations (Swap Event Locations): exchange the tiles of the two
    # characters named by param0 and param1 (same target ids as Change Event
    # Location). Queued as a `:swap` request the scene applies; non-blocking.
    def do_trade_event_locations(cmd)
      @location_requests.push({ op: :swap, a: cmd.param(0), b: cmd.param(1) })
    end

    # Store Terrain ID: write the terrain id of the tile at (x, y) into the
    # variable named by param3. Non-blocking; without a map_info hook (or on any
    # error) it stores 0.
    def do_store_terrain_id(cmd)
      x, y = query_position(cmd)
      variables[cmd.param(3)] = @map_info ? (@map_info.terrain_id(x, y) || 0) : 0
    rescue StandardError
      variables[cmd.param(3)] = 0
    end

    # Store Event ID: write the id of the event standing on the tile at (x, y)
    # into the variable named by param3 (0 when no event is there). Non-blocking.
    def do_store_event_id(cmd)
      x, y = query_position(cmd)
      variables[cmd.param(3)] = @map_info ? (@map_info.event_id_at(x, y) || 0) : 0
    rescue StandardError
      variables[cmd.param(3)] = 0
    end

    # The (x, y) tile a Store Terrain / Event ID command targets: param0 == 0
    # takes x and y as the constants param1/param2, otherwise as the values of
    # those two variables (the shared operand mode matches RPG_RT).
    def query_position(cmd)
      if cmd.param(0) == 0
        [cmd.param(1), cmd.param(2)]
      else
        [variables[cmd.param(1)], variables[cmd.param(2)]]
      end
    end

    # Move Event (Set Move Route): queue a forced move route for a target
    # character. The command parameters are [target, frequency, repeat,
    # skippable, then the move-route commands]; the target id selects the player
    # (10001), a vehicle (10002-4), this event (10005 or 0) or a map event (its
    # id). The route runs in the background, so this only records the request —
    # the scene resolves the target and steps the route (see decode_move_route).
    def do_move_event(cmd)
      params = cmd.parameters || []
      return if params.empty?
      @move_route_requests.push(
        target: cmd.param(0),
        frequency: cmd.param(1),
        repeat: cmd.param(2) != 0,
        skippable: cmd.param(3) != 0,
        commands: decode_move_route(params, cmd.string || '')
      )
    end

    # Decode the move-route commands packed into a Move Event's parameter list
    # (from index 4 on). Most ids are bare; a few carry integer parameters, and
    # change-graphic / play-sound carry a string whose bytes live in the event
    # command's string field, prefixed in the parameter list by their length
    # (matching LCF's layout). Returns Game::MoveCommand objects a MoveRoute can
    # run. String slicing assumes ASCII file names (as charset/SE names are).
    def decode_move_route(params, string)
      cmds = []
      i = 4
      soff = 0
      while i < params.size
        id = params[i]; i += 1
        a = b = c = 0
        str = ''
        case id
        when MoveCmd::SWITCH_ON, MoveCmd::SWITCH_OFF
          a = params[i] || 0; i += 1
        when MoveCmd::CHANGE_GRAPHIC
          len = params[i] || 0; i += 1
          str = string[soff, len] || ''; soff += len
          a = params[i] || 0; i += 1
        when MoveCmd::PLAY_SOUND
          len = params[i] || 0; i += 1
          str = string[soff, len] || ''; soff += len
          a = params[i] || 0; i += 1
          b = params[i] || 0; i += 1
          c = params[i] || 0; i += 1
        end
        cmds.push Game::MoveCommand.new(id, str, a, b, c)
      end
      cmds
    end

    # Wait (11410): param0 tenths of a second in RPG2000. RPG2003 adds a
    # param1 mode byte -- 0 the plain timed wait above, nonzero "wait until
    # the Decision key is pressed" instead, ignoring param0 entirely --
    # matching EasyRPG's own `CommandWait` (src/game_interpreter.cpp): `if
    # (com.parameters.size() <= 1 || (!maniac && !Player::
    # IsRPG2k3Commands())) { SetupWait(com.parameters[0]); return true; }
    # if (!maniac && com.parameters.size() > 1 && com.parameters[1] == 0) {
    # SetupWait(com.parameters[0]); return true; } ... _state.wait_key_enter
    # = true;` (the Maniac Patch's own extra wait_type/mode encoding is a
    # separate, unimplemented feature, out of scope here).
    def do_wait(cmd)
      if @state.party.rpg2003? && cmd.parameters.size > 1 && cmd.param(1) != 0
        @wait_kind = :wait_key_enter
      else
        @wait_frames = cmd.param(0) # tenths of a second in RPG2000
        @wait_kind = :wait
      end
      @waiting = true
    end

    # Proceed With Movement: pause until every forced move route in progress (set
    # by a Move Event) has finished. The owning scene advances those routes while
    # we wait and resumes us once none remain. As in RPG_RT, a *repeating* forced
    # route never finishes, so pairing it with this command waits indefinitely.
    def do_proceed_with_movement(_cmd)
      @wait_kind = :movement
      @waiting = true
    end

    # Set Transparent Flag (Change Player Visibility): toggle whether the party
    # leader's map sprite is hidden. Non-blocking — it only records the flag on
    # the shared game state; the owning scene reads it each frame. The polarity
    # (param0 non-zero = transparent / hidden) follows EasyRPG's
    # `SetSpriteHidden(parameters[0] != 0)`; the flag persists through Save /
    # Continue.
    def do_player_visibility(cmd)
      @state.player_transparent = cmd.param(0) != 0
    end

    # Flash Sprite (11320): pulse a character's sprite with a colour that decays
    # to nothing. param0 is the target (the Move Event target scheme: 10001 the
    # hero, 0 / 10005 this event, else a map event id), param1..3 the colour and
    # param4 its strength — all four stored 0..31, so they are scaled by 8 to the
    # 0..248 the renderer works in, as EasyRPG's CommandFlashSprite does — param5
    # the duration in tenths of a second and param6 the wait flag. Queued for the
    # owning scene (which owns the sprites); with the wait flag set the event also
    # pauses on a :sprite_flash wait until the scene reports the flash finished.
    FLASH_CHANNEL_SCALE = 8

    def do_flash_sprite(cmd)
      frames = cmd.param(5) * FRAMES_PER_TENTH
      @sprite_flash_requests.push(
        target: cmd.param(0),
        red: cmd.param(1) * FLASH_CHANNEL_SCALE,
        green: cmd.param(2) * FLASH_CHANNEL_SCALE,
        blue: cmd.param(3) * FLASH_CHANNEL_SCALE,
        power: cmd.param(4) * FLASH_CHANNEL_SCALE,
        frames: frames
      )
      return unless cmd.param(6) != 0 && frames > 0
      @wait_kind = :sprite_flash
      @waiting = true
    end

    # Open Save Menu (11910): hand control to the save screen. Raised as a
    # :save_menu request the owning scene answers by saving (and reporting the
    # outcome), then resuming the event where it left off. A Change Save Access
    # command that forbade saving also forbids this, matching RPG_RT.
    def do_open_save_menu(_cmd)
      @wait_kind = :save_menu
      @waiting = true
    end

    # Open Main Menu (11950): open the field menu as though the player had
    # pressed cancel. Raised as a :menu request the owning scene answers by
    # pushing Scene::Menu; the event resumes once the player closes it. Unlike
    # the cancel button this ignores the Change Main Menu Access flag — RPG_RT
    # lets an event open the menu it has otherwise locked out.
    def do_open_main_menu(_cmd)
      @wait_kind = :menu
      @waiting = true
    end

    # Tile Substitution (11750): from here on, draw and treat every occurrence of
    # tile param1 on layer param0 (0 lower, 1 upper) as tile param2. Recorded on
    # the current Game::Map (so passability follows the swap) and flagged so the
    # scene redraws its cached tile layers. Non-blocking; the rewrite lasts until
    # the map is left, as in RPG_RT.
    def do_tile_substitution(cmd)
      map = @state.map
      return unless map.respond_to?(:substitute_tile)
      map.substitute_tile(cmd.param(0), cmd.param(1), cmd.param(2))
      @tiles_changed = true
    end

    # Return to Title Screen: abandon the running game and go back to the title.
    # Raised as a :return_title request the owning scene answers by tearing the
    # play scenes down and showing a fresh title (there is nothing to resume, so
    # the request behaves like a one-way teleport out of the map).
    def do_return_to_title(_cmd)
      @wait_kind = :return_title
      @waiting = true
    end

    # -- RPG2003 English-release (2k3e) system commands ------------------------

    # Open Load Menu (5001): leave the map for the save-slot loader, the way
    # Return to Title leaves it. Raised as a :load_menu request; there is nothing
    # to resume, because whatever the player loads replaces this scene.
    def do_open_load_menu(_cmd)
      @wait_kind = :load_menu
      @waiting = true
    end

    # Exit Game (5002): quit outright — the title screen's Shutdown entry, driven
    # by an event. Raised as an :exit_game request the scene answers by leaving
    # the process; nothing resumes.
    def do_exit_game(_cmd)
      @wait_kind = :exit_game
      @waiting = true
    end

    # Toggle Fullscreen (5004) / Open Video Options (5005): the 2k3e display
    # commands. This build's display backend offers neither a fullscreen toggle
    # nor a video-options screen, so — like EasyRPG on a platform whose window
    # cannot change mode — the command is a logged no-op rather than a silent
    # one, and the event runs straight on.
    def do_toggle_fullscreen(_cmd)
      $stderr.puts '[RPG2k] Toggle Fullscreen: this display has no fullscreen mode'
    end

    def do_open_video_options(_cmd)
      $stderr.puts '[RPG2k] Open Video Options: no video-options screen in this build'
    end

    # Game Over (12420): raised as a :game_over request the owning scene answers
    # by ending the game (RPG2000 shows the Game Over screen, then the title).
    # Like Return to Title there is nothing to resume — the event stops here.
    def do_game_over(_cmd)
      @wait_kind = :game_over
      @waiting = true
    end

    # Frames per tenth of a second at RPG2000's fixed 60 fps, for turning a
    # screen effect's 0.1s-unit duration into a frame count.
    FRAMES_PER_TENTH = 6

    # Erase Screen (11010) / Show Screen (11020): take the whole screen to black
    # or back, in the transition style param0 names. The style table and each
    # style's own length live in Game::Transition; **param0 = -1 means "use the
    # configured transition"**, which is the Change Screen Transitions (10690)
    # slot for a teleport erase / show — itself seeded from the database. That is
    # the overwhelmingly common value in real games (2124 of Nepheshel's 2146
    # Erase Screens), so leaving it unresolved meant almost every fade in the
    # game ran an unnamed style of a made-up length.
    #
    # Both pause the event until the transition settles — the owning scene
    # advances Game::Screen each frame and resumes us on the :screen wait — but
    # an instant style (the cuts, or a transition onto a screen already in that
    # state) settles at once and does not wait at all.
    def do_erase_screen(cmd)
      style = Game::Transition.erase_style(cmd.param(0), teleport_transition(0))
      @state.screen.erase(style)
      return unless @state.screen.fading?
      @wait_kind = :screen
      @waiting = true
    end

    def do_show_screen(cmd)
      style = Game::Transition.show_style(cmd.param(0), teleport_transition(1))
      @state.screen.show(style)
      return unless @state.screen.fading?
      @wait_kind = :screen
      @waiting = true
    end

    # The configured teleport transition **setting** a -1 falls back to: slot 0
    # is the erase and slot 1 the show, in the same order Change Screen
    # Transitions (10690) writes them and the save stores them (chunks 111/112).
    # The state seeds these from the database when the game starts; setting 0,
    # the plain fade, stands in for a state that never got the chance.
    def teleport_transition(slot)
      v = @state.screen_transitions[slot]
      Game::Transition.setting?(v) ? v : 0
    end

    # Tint Screen: transition the shared screen tint to the RPG2000 channels
    # param0..3 (red / green / blue / saturation, each 0..200) over param4 tenths
    # of a second. When param5 (the wait flag) is set and the transition takes
    # time, pause until it finishes — the owning scene advances Game::Screen each
    # frame and resumes us once it settles.
    def do_tint_screen(cmd)
      frames = cmd.param(4) * FRAMES_PER_TENTH
      @state.screen.tint_to(cmd.param(0), cmd.param(1), cmd.param(2),
                            cmd.param(3), frames)
      return unless cmd.param(5) != 0 && @state.screen.tinting?
      @wait_kind = :screen
      @waiting = true
    end

    # Flash Screen: flash the screen the colour param0..2 (red / green / blue) at
    # peak strength param3, fading out over param4 tenths of a second. When param5
    # (the wait flag) is set, pause until it fades — the owning scene advances
    # Game::Screen each frame and resumes us once no screen effect is animating.
    # RPG2003 extends the command with a param6 mode byte (0 one-shot / 1 begin a
    # repeating strobe / 2 end one), matching EasyRPG's `CommandFlashScreen`
    # (src/game_interpreter.cpp): a command list carrying no 7th parameter (an
    # RPG2000 project, or an RPG2003 one never given the extended layout) always
    # falls back to a plain one-shot flash, mode 0. Only mode 0 ever waits — Begin
    # and End never suspend the interpreter, since the strobe runs indefinitely.
    def do_flash_screen(cmd)
      mode = @state.party.rpg2003? && cmd.parameters.size > 6 ? cmd.param(6) : 0
      case mode
      when 1
        frames = cmd.param(4) * FRAMES_PER_TENTH
        @state.screen.flash_begin(cmd.param(0), cmd.param(1), cmd.param(2),
                                  cmd.param(3), frames)
      when 2
        @state.screen.flash_end
      else
        frames = cmd.param(4) * FRAMES_PER_TENTH
        @state.screen.flash(cmd.param(0), cmd.param(1), cmd.param(2),
                            cmd.param(3), frames)
        return unless cmd.param(5) != 0 && @state.screen.flashing?
        @wait_kind = :screen
        @waiting = true
      end
    end

    # Pan Screen: param0 selects the operation — 0 lock the camera in place, 1
    # unlock it (resume following the hero), 2 pan the view param2 tiles in
    # direction param1 (0 up / 1 right / 2 down / 3 left) at speed param3, 3 reset
    # the pan back to the hero at speed param3. param4 is the wait flag for the
    # pan/reset scroll (lock/unlock are instant, so they never wait).
    def do_pan_screen(cmd)
      screen = @state.screen
      case cmd.param(0)
      when 0 then screen.pan_lock
      when 1 then screen.pan_unlock
      when 2 then screen.pan(cmd.param(1), cmd.param(2), cmd.param(3))
      when 3 then screen.pan_reset(cmd.param(3))
      end
      return unless cmd.param(4) != 0 && screen.panning?
      @wait_kind = :screen
      @waiting = true
    end

    # Shake Screen: start a timed screen shake of strength param0 and speed
    # param1 for param2 tenths of a second. When param3 (the wait flag) is set,
    # pause until it finishes — the owning scene advances Game::Screen each frame
    # and resumes us once no screen effect is animating.
    # RPG2003 extends the command with a param4 mode byte (0 one-shot / 1 begin a
    # repeating strobe / 2 end one), matching EasyRPG's `CommandShakeScreen`
    # (src/game_interpreter.cpp): a command list carrying no 5th parameter (an
    # RPG2000 project, or an RPG2003 one never given the extended layout) always
    # falls back to a plain one-shot shake, mode 0. Only mode 0 ever waits — Begin
    # and End never suspend the interpreter, since the strobe runs indefinitely.
    def do_shake_screen(cmd)
      mode = @state.party.rpg2003? && cmd.parameters.size > 4 ? cmd.param(4) : 0
      case mode
      when 1
        @state.screen.shake_begin(cmd.param(0), cmd.param(1))
      when 2
        @state.screen.shake_end
      else
        frames = cmd.param(2) * FRAMES_PER_TENTH
        @state.screen.shake(cmd.param(0), cmd.param(1), frames)
        return unless cmd.param(3) != 0 && @state.screen.shaking?
        @wait_kind = :screen
        @waiting = true
      end
    end

    # Whether Show/Move/Erase Picture must no-op this call: per yado.tk, real
    # RPG_RT fully suppresses all three picture commands while any message
    # window or choice list is open, anywhere in the scene — including a
    # picture command reached by an already-running parallel process while a
    # *different* interpreter's message window sits on screen (parallel
    # processes keep advancing during a message window, see
    # Scene::Map#parallels_paused?; this is the narrower rule layered on top
    # of that). Without a map_info hook (a headless interpreter, or a battle
    # page) there is no message window to suppress against.
    def picture_commands_suppressed?
      @map_info.respond_to?(:message_window_open?) && @map_info.message_window_open?
    end

    # Show Picture (11110): display picture param0 from the string file name at
    # the centre position param2/param3 (literal, or read from those variables
    # when the position-mode param1 is non-zero), at zoom param5 (%), transparency
    # param6 (0 opaque .. 100 clear), tone param8..11 (r/g/b/saturation) and the
    # "make colour 0 transparent" flag param7; param4 pins it to the map (it then
    # scrolls with the camera). The parameter layout is a direct port of EasyRPG
    # Player's CommandShowPicture (RPG2000 branch).
    def do_show_picture(cmd)
      id = cmd.param(0)
      return if id <= 0
      return if picture_commands_suppressed?
      @state.show_picture(id,
                          name: picture_name(cmd),
                          x: picture_coord(cmd, 2), y: picture_coord(cmd, 3),
                          zoom: cmd.param(5),
                          opacity: trans_to_opacity(cmd.param(6)),
                          use_transparent_color: cmd.param(7) != 0,
                          fixed_to_map: cmd.param(4) > 0,
                          red: cmd.param(8), green: cmd.param(9),
                          blue: cmd.param(10), saturation: cmd.param(11))
    end

    # Move Picture (11120): ease picture param0 to a new position/zoom/opacity/
    # tone over param14 tenths of a second. When the wait flag (param15) is set,
    # pause until the move finishes — the scene advances the pictures each frame
    # and resumes us once none is moving. Same parameter layout as Show Picture,
    # plus the trailing duration/wait pair (EasyRPG's CommandMovePicture).
    def do_move_picture(cmd)
      return if picture_commands_suppressed?
      id = cmd.param(0)
      frames = cmd.param(14) * FRAMES_PER_TENTH
      @state.move_picture(id, picture_coord(cmd, 2), picture_coord(cmd, 3),
                          cmd.param(5), trans_to_opacity(cmd.param(6)),
                          cmd.param(8), cmd.param(9), cmd.param(10),
                          cmd.param(11), frames)
      return unless cmd.param(15) != 0 && @state.pictures[id] &&
                    @state.pictures[id].moving?
      @wait_kind = :picture
      @waiting = true
    end

    # Erase Picture (11130): remove picture param0 from the screen.
    def do_erase_picture(cmd)
      return if picture_commands_suppressed?
      @state.erase_picture(cmd.param(0))
    end

    # Show Battle Animation (11210): play battle animation param0 over a target
    # character on the map. param1 is the target id (the player, an event, or
    # this event — the Move Event target scheme) and param2 the "wait until it
    # finishes" flag. EasyRPG's own `Game_Interpreter_Map::
    # CommandShowBattleAnimation` (src/game_interpreter_map.cpp) always starts the
    # animation through `Game_Screen::ShowBattleAnimation` regardless of the wait
    # flag — only whether `_state.wait_time` is then set (pausing the interpreter)
    # depends on it — so a fire-and-forget play is not merely non-blocking, it is
    # still expected to render. With the wait flag set, this suspends on an
    # :animation wait so the owning scene can hold the event for the animation's
    # duration (#drive_map_animation reads `battle_animation` directly off that
    # wait); with it unset, `@battle_animation_pending` flags this request for
    # #take_battle_animation_request instead, since nothing will ever visit an
    # :animation wait for it otherwise.
    def do_show_battle_animation(cmd)
      @battle_animation = { animation: cmd.param(0), target: cmd.param(1),
                            wait: cmd.param(2) != 0 }
      if cmd.param(2) != 0
        @wait_kind = :animation
        @waiting = true
      else
        @battle_animation_pending = true
      end
    end

    # A picture coordinate: the literal param at `idx`, or the value of the
    # variable it names when the position-mode param (index 1) is non-zero.
    def picture_coord(cmd, idx)
      cmd.param(1) != 0 ? variables[cmd.param(idx)] : cmd.param(idx)
    end

    # RPG2000 transparency (0 opaque .. 100 fully clear) -> a 0..255 opacity.
    def trans_to_opacity(top_trans)
      Game.trans_to_opacity(top_trans)
    end

    # The picture's file name (the command's string parameter), or ''.
    def picture_name(cmd)
      (cmd.string || '').to_s
    end

    # Weather Effects: set the map weather type (param0 — 0 none, 1 rain, 2 snow;
    # the RPG2003 additions come through as higher values) and strength (param1 —
    # 0 weak .. 2 strong) on the shared game state. Non-blocking; like the picture
    # / tint overlays this records the Ruby-half model only — compositing the
    # rain/snow particles is native renderer work still to come — but the setting
    # is applied and persists through Save / Continue.
    # Matches EasyRPG's `Game_Interpreter::CommandWeatherEffects`
    # (src/game_interpreter.cpp): `strength = std::min(str, 2)` unconditionally
    # (a stray value above 2 in the raw command bytes clamps down rather than
    # persisting out of range), and `type` above 2 (an RPG2003-only weather
    # type) is forced back to 0 (none) `if (!Player::IsRPG2k3Commands())` —
    # the RPG2000 editor's own Weather Effects dialog offers no type past
    # Snow at all, so a stray higher value should never linger on that
    # edition.
    def do_weather(cmd)
      type = cmd.param(0)
      type = 0 if !@state.party.rpg2003? && type > 2
      @state.weather.set(type, [cmd.param(1), 2].min)
    end

    # Fade Out BGM (11520): fade the music to silence over param0
    # milliseconds, then leave nothing playing. Clears the current-BGM
    # record so a Memorize BGM taken afterwards memorises silence, as
    # RPG_RT does. Non-blocking — the event runs on while the music fades.
    #
    # param0 is already milliseconds, not tenths of a second: EasyRPG's
    # `CommandFadeOutBGM` (src/game_interpreter.cpp) passes
    # `com.parameters[0]` straight through to `Game_System::BgmFade`, whose
    # own doc comment (src/game_system.h) reads "duration Duration in ms" --
    # confirmed by every other real `BgmFade(...)` call site in EasyRPG
    # (player.cpp, scene_end.cpp, scene_map.cpp), all bare millisecond
    # literals (400/800) with no scaling. This codebase's own
    # `RGSS::Audio.bgm_fade` already expects milliseconds too --
    # `Scene::Menu`'s own End Game call passes `bgm_fade(400)` directly.
    def do_fadeout_bgm(cmd)
      @state.current_bgm = nil
      @state.bgm_looped = false
      RGSS::Audio.bgm_fade(cmd.param(0))
    rescue StandardError => e
      $stderr.puts "[RPG2k] BGM fade-out failed: #{e.message}"
      nil
    end

    # Play Movie (11560): show a video file over the map. The command string
    # names the Movie/<name> file, param0 selects literal (0) or variable (1)
    # placement, param1/param2 the top-left position and param3/param4 the size.
    # No backend here decodes video, so the request is recorded for the scene
    # (which logs it) rather than silently dropped; playback itself is the one
    # part of the command that is not modelled.
    def do_play_movie(cmd)
      x = cmd.param(1)
      y = cmd.param(2)
      if cmd.param(0) != 0
        x = variables[x]
        y = variables[y]
      end
      @movie_request = { name: (cmd.string || '').to_s, x: x, y: y,
                         width: cmd.param(3), height: cmd.param(4) }
    end

    # Memorize BGM: stash a copy of the currently-playing BGM so a later Play
    # Memorized BGM can restore it (e.g. duck to a fanfare, then return). Nothing
    # playing memorises nothing. Non-blocking.
    def do_memorize_bgm(_cmd)
      cur = @state.current_bgm
      @state.memorized_bgm = cur ? cur.dup : nil
    end

    # Set Teleport Target: register (or clear) a destination the party can jump
    # to with the Teleport skill. param0 is the operation (0 add, 1 remove),
    # param1 the map id; on add, param2/param3 are the tile x/y and an optional
    # switch (param4 flags its presence, param5 is the switch id) gates the
    # target's availability. Stored in a Game::State registry keyed by map id.
    # Nothing consumes it yet — the Teleport skill is not executed — so this is
    # modelled purely for save fidelity, mirroring the access flags.
    def do_set_teleport_target(cmd)
      map_id = cmd.param(1)
      if cmd.param(0) != 0
        @state.teleport_targets.delete(map_id)
        return
      end
      switch_id = cmd.param(4) != 0 ? cmd.param(5) : nil
      @state.teleport_targets[map_id] =
        { x: cmd.param(2), y: cmd.param(3), switch_id: switch_id }
    end

    # Set Escape Target: register the single destination the Escape skill jumps
    # to. param0 map id, param1/param2 the tile x/y, and an optional switch
    # (param3 flags its presence, param4 the switch id). Like the teleport
    # registry this is stored for save fidelity only; the Escape skill is not
    # executed yet.
    def do_set_escape_target(cmd)
      switch_id = cmd.param(3) != 0 ? cmd.param(4) : nil
      @state.escape_target =
        { map_id: cmd.param(0), x: cmd.param(1), y: cmd.param(2),
          switch_id: switch_id }
    end

    # Change System Graphics: override the windowskin graphic and font. The
    # command string names the System/<name> windowskin; param0 is the message
    # background stretch style (not modelled — it is not in the save) and param1
    # the font id (RPG2000 games leave it 0). Records a one-shot request so the
    # scene reloads the windowskin, and the override persists across Save /
    # Continue.
    def do_change_system_graphic(cmd)
      @state.set_system_graphic(cmd.string || '', cmd.param(1))
      @system_graphic_changed = true
    end

    # Change Parallax Background (11720): replace the current map's panorama at
    # runtime. The command string names the Panorama/<name> image; param0/1 are
    # the horizontal / vertical loop flags, param2/4 enable horizontal / vertical
    # autoscroll and param3/5 give their speeds (per EasyRPG's SetParallax). An
    # empty name clears the backdrop. Stored as a Game::State override (reset on
    # the next map change, like shown pictures) and flagged so the scene rebuilds
    # the parallax sprite mid-map.
    def do_change_parallax(cmd)
      @state.set_parallax(name: (cmd.string || '').to_s,
                          loop_x: cmd.param(0) != 0, loop_y: cmd.param(1) != 0,
                          auto_x: cmd.param(2) != 0, sx: cmd.param(3),
                          auto_y: cmd.param(4) != 0, sy: cmd.param(5))
      @parallax_changed = true
    end

    # Change System BGM: override one of the system music slots (0 battle,
    # 1 victory, 2 inn, 3 boat, 4 ship, 5 airship, 6 game over) selected by
    # param0. The remaining fields carry a Music struct: string = file name,
    # param1 fade-in, param2 volume, param3 tempo, param4 balance. Stashed in
    # a Game::State slot table; Scene::Map's #battle_bgm reads slot 0 (battle),
    # #victory_bgm reads slot 1 (the "Victory!" result screen), #inn_bgm reads
    # slot 2 and #vehicle_bgm reads slots 3-5 (boat/ship/airship) back out
    # ahead of the database default, the same override-then-default idiom
    # Change System SFX already gets; Scene::GameOver#gameover_bgm_override
    # does the same for slot 6. All seven slots round-trip through a real
    # .lsd Save/Continue now too (Game::State#to_lsd/.from_lsd, SAVE_SYSTEM
    # fields 72-74/79-82), not just the portable Marshal save.
    def do_change_system_bgm(cmd)
      @state.system_bgm[cmd.param(0)] = {
        name: cmd.string, fadein: cmd.param(1), volume: cmd.param(2),
        tempo: cmd.param(3), balance: cmd.param(4)
      }
    end

    # Change System SFX: override one of the system sound slots (cursor,
    # decision, cancel, the battle per-hit sounds, ...) selected by param0.
    # string = file name, param1 volume, param2 tempo, param3 balance. The map
    # scene (Scene::Map::DB_SE_FIELD) already plays most of these slots at the
    # moments they name; a slot beyond the ones it plays is still stored for
    # save fidelity, matching the system BGM -- all twelve slots round-trip
    # through a real .lsd Save/Continue now too (SAVE_SYSTEM fields 91-102),
    # not just the portable Marshal save.
    def do_change_system_sfx(cmd)
      @state.system_sfx[cmd.param(0)] = {
        name: cmd.string, volume: cmd.param(1),
        tempo: cmd.param(2), balance: cmd.param(3)
      }
    end

    # Play Memorized BGM: resume the BGM stashed by Memorize BGM, making it the
    # current BGM again. A no-op when nothing was memorised. Playback resumes
    # from the start — the SDL_mixer backend cannot seek to the stored position
    # — *unless* the memorized file is the one still playing right now: real
    # RPG_RT's `Game_System::PlayMemorizedBGM` is a bare call to the same
    # `BgmPlay` every other BGM entry point goes through (Play BGM, and the
    # battle/vehicle/inn helpers — see `Scene::Map#play_bgm`), so its "same
    # music: only adjust volume and speed" no-restart rule applies here too,
    # same idiom (volume-in-place included) as `#play_audio`'s `:bgm` branch
    # just below.
    def do_play_memorized_bgm(_cmd)
      bgm = @state.memorized_bgm
      return if bgm.nil? || bgm[:name].nil? || bgm[:name].empty?
      same_file_already_playing = @state.current_bgm && @state.current_bgm[:name] == bgm[:name]
      if same_file_already_playing
        RGSS::Audio.bgm_volume(bgm[:volume] || 100)
      else
        @state.bgm_looped = false
        RGSS::Audio.bgm_play(bgm[:name], bgm[:volume] || 100, bgm[:tempo] || 100)
      end
      @state.current_bgm = bgm.dup
    rescue StandardError => e
      $stderr.puts "[RPG2k] memorized BGM playback failed: #{e.message}"
      nil
    end

    def play_audio(kind, cmd)
      name = cmd.string
      if name.nil? || name.empty?
        # Selecting "(OFF)" for the SE field (an empty string, same encoding
        # as any other blank filename) is not a no-op like a blank BGM field
        # is: real RPG_RT stops every currently-playing sound effect at once
        # (SE is truly polyphonic, unlike the single-channel BGM slot, so
        # there is no single "current" track for an empty name to leave
        # alone the way Play BGM does — yado.tk). Play BGM's own blank-name
        # case stays an untouched no-op; nothing here establishes RPG_RT
        # treats a blank Play BGM the same way, so that stays unaddressed.
        RGSS::Audio.se_stop if kind == :se
        return
      end
      if kind == :bgm
        # PlayBGM parameters: [fade_in, volume, tempo, balance]. Volume/tempo
        # default to 100, balance to 50 (centre), when the command carries a
        # shorter list.
        volume = cmd.parameters.size > 1 ? cmd.param(1) : 100
        pitch = cmd.parameters.size > 2 ? cmd.param(2) : 100
        balance = cmd.parameters.size > 3 ? cmd.param(3) : 50
        # BGM has a single channel, and RPG_RT special-cases re-triggering Play
        # BGM with the file that's already current: it does NOT break and
        # restart the track from the top the way any other Play BGM does
        # (yado.tk), but it does re-apply the command's own volume to the
        # still-playing track (`RGSS::Audio.bgm_volume`, backed by
        # `Mix_VolumeMusic` — see `src/sdl_audio.cxx`, which applies live with
        # no restart, unlike `bgm_play`'s `Mix_PlayMusic`). Tempo stays
        # unaddressed: SDL_mixer has no live pitch control for a playing music
        # stream (only a freshly started one). Balance/pan is wired the same
        # live-update way via `RGSS::Audio.bgm_pan` (backed by
        # `Mix_SetPanning(MIX_CHANNEL_POST, ...)` — the only technique that
        # reaches a Mix_Music stream at all, see `src/sdl_audio.cxx`), applied
        # on every Play BGM regardless of same-file-or-not since it has no
        # per-track state to restart.
        same_file_already_playing = @state.current_bgm && @state.current_bgm[:name] == name
        # Track what is playing so Memorize BGM can stash it (RPG_RT keeps this
        # as the "current system BGM" regardless of whether playback succeeds).
        @state.current_bgm = { name: name, volume: volume, tempo: pitch }
        if same_file_already_playing
          RGSS::Audio.bgm_volume(volume)
        else
          @state.bgm_looped = false # a fresh track has not looped yet
          RGSS::Audio.bgm_play(name, volume, pitch)
        end
        RGSS::Audio.bgm_pan(balance)
      else
        # PlaySE parameters: [volume, tempo, balance].
        volume = cmd.parameters.size > 0 ? cmd.param(0) : 100
        pitch = cmd.parameters.size > 1 ? cmd.param(1) : 100
        RGSS::Audio.se_play(name, volume, pitch)
      end
    rescue StandardError => e
      $stderr.puts "[RPG2k] #{kind} playback failed for '#{name}': #{e.message}"
      nil
    end
  end
end
