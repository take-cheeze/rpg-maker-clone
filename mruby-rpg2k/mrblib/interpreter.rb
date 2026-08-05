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
    CHAR_THIS_EVENT = 10005

    # Show Choices holds at most four selectable options; a fifth (index 4) is
    # the optional [Cancel] branch, which is a jump target only and is never
    # drawn in the window. Mirrors EasyRPG's `GetChoices(4)`.
    MAX_CHOICES = 4

    # Upper bound on nested Call Event depth, so a common event that (directly or
    # indirectly) calls itself unwinds instead of growing the stack without end.
    MAX_CALL_DEPTH = 100

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
                :battle_animation, :choice_cancel_type
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

    # Upper bound on commands run in a single update, so a malformed loop cannot
    # hang the game loop.
    MAX_STEPS = 1_000_000

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
        steps += 1
        break if steps >= MAX_STEPS
      end
      @running = false if finished?
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

    # RPG2000 key-input result codes in priority order (highest first). When more
    # than one accepted button is active RPG_RT returns the largest code:
    # Shift > Cancel > Decision > Up > Right > Left > Down.
    KEY_INPUT_CODES = [
      [:shift, 7], [:cancel, 6], [:decision, 5],
      [:up, 4], [:right, 3], [:left, 2], [:down, 1]
    ].freeze

    # Given the set of currently-active key symbols (an array like [:decision]),
    # return the RPG2000 code of the highest-priority key the pending request
    # accepts, or 0 when none of the accepted keys are active. Called by the
    # owning scene once it has sampled real input.
    def key_input_result(active)
      acc = @key_input_request && @key_input_request[:accepted]
      return 0 unless acc
      KEY_INPUT_CODES.each do |sym, code|
        return code if acc[sym] && active.include?(sym)
      end
      0
    end

    private

    def reset_waits
      @waiting = false
      @wait_kind = nil
      @message_lines = nil
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
    # A missing/empty target is a no-op; recursion is bounded by MAX_CALL_DEPTH.
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
      when 0 then @resolver.common_event_commands(cmd.param(1))
      when 1 then map_event_call(cmd.param(1), cmd.param(2))
      when 2 then map_event_call(variables[cmd.param(1)],
                                 variables[cmd.param(2)])
      end
    rescue StandardError
      nil
    end

    # The command list of a map event's page, with the event id resolved through
    # #character_ref so "this event" reaches the running event. An unresolvable
    # reference (a common event calling "this event") has no page to run.
    def map_event_call(event_ref, page)
      id = character_ref(event_ref)
      return nil if id.nil?
      @resolver.map_event_commands(id, page)
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

    # Break Loop: jump past the enclosing loop's End Loop marker.
    def do_break_loop(cmd)
      j = @index
      while j < @list.size
        c = @list[j]
        if c.code == Cmd::END_LOOP && c.indent < cmd.indent
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
    # it. Persists until changed; does not pause.
    def do_change_face(cmd)
      cfg = @state.message_config
      name = cmd.string || ''
      if name.empty?
        cfg.clear_face
      else
        cfg.face_name = name
        cfg.face_index = cmd.param(0)
        cfg.face_right = cmd.param(1) != 0
        cfg.face_flipped = cmd.param(2) != 0
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
    # parameter layout matches RPG_RT and depends on the command's length:
    #   param0            target variable id
    #   param1            wait flag (0 = read this frame and continue)
    #   param2            (pre-1.50 only) accept all four arrows when non-zero
    #   param3 / param4   accept Decision (OK) / Cancel — always present
    #   param5..param9    (1.50+) accept Shift / Down / Left / Right / Up
    # The interpreter only records the request and suspends on a :key_input wait;
    # the owning scene samples real input (triggered edges when waiting, held
    # state otherwise) and calls resume_key_input with the resulting code. Number
    # and operator keys (RPG2003) and the mouse (Maniac) are not modelled.
    def do_key_input(cmd)
      var_id = cmd.param(0)
      wait = cmd.param(1) != 0
      accepted = { decision: cmd.param(3) != 0, cancel: cmd.param(4) != 0,
                   shift: false, down: false, left: false, right: false,
                   up: false }
      if cmd.parameters.size < 6
        # Pre-1.50: a single flag enables the whole D-pad, no Shift.
        if cmd.param(2) != 0
          accepted[:down] = accepted[:left] = true
          accepted[:right] = accepted[:up] = true
        end
      else
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
    # resume_battle. The turn-based battle itself is not built yet.
    def do_enemy_encounter(cmd)
      escape_mode = cmd.param(3)
      @battle_indent = cmd.indent
      @battle_escape_aborts = escape_mode == 1
      nxt = @list[@index]
      @battle_has_handlers =
        !nxt.nil? && nxt.code == Cmd::VICTORY_HANDLER && nxt.indent == cmd.indent
      @battle_request = {
        troop_id: cmd.param(0) == 0 ? cmd.param(1) : variables[cmd.param(1)],
        allow_escape: escape_mode != 0, first_strike: cmd.param(5) != 0,
        defeat_game_over: cmd.param(4) == 0
      }
      @state.battle_count += 1 # a battle was entered (Control Variables "Other")
      @wait_kind = :battle
      @waiting = true
    end

    # -- state commands -------------------------------------------------------

    def range(cmd)
      mode = cmd.param(0)
      a = cmd.param(1)
      b = mode == 0 ? a : cmd.param(2)
      a = variables[cmd.param(1)] if mode == 2 # indirect: id held in a variable
      b = a if mode == 2
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
      val = operand_value(cmd)
      (a..b).each { |id| variables[id] = apply(op, variables[id], val) }
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
    # the hero / party, "this event" as 0 / 10005, any other positive id a map
    # event); param6 the value (0 map id, 1 x tile, 2 y tile, 3 facing in
    # RPG2000's 2/4/6/8 numpad convention, 4 screen x, 5 screen y). Matching a
    # long-standing RPG_RT quirk, a *map event's* map id reads 0. An unresolvable
    # reference (no map_info hook, unknown event, "this event" outside a map
    # event) reads 0.
    def event_operand(cmd)
      ref = character_ref(cmd.param(5))
      attr = cmd.param(6)
      return screen_operand(ref, attr) if attr == 4 || attr == 5
      return 0 if ref.nil?
      if ref == CHAR_PLAYER # the hero / party leader
        case attr
        when 0 then @state.map_id
        when 1 then @state.x
        when 2 then @state.y
        when 3 then @state.direction
        else 0
        end
      elsif ref > 0 && ref < 10000 && @map_info.respond_to?(:event_position)
        pos = @map_info.event_position(ref)
        return 0 unless pos
        case attr
        when 1 then pos[:x]
        when 2 then pos[:y]
        when 3 then pos[:direction]
        else 0 # an event's map id reads 0 (the RPG2000 quirk)
        end
      else
        0
      end
    end

    # The screen-coordinate selectors of operand 6 (attr 4 x / 5 y): where the
    # character currently sits in the view, which only the map scene can answer
    # because it owns the camera. Without that hook (a headless interpreter, or a
    # battle page) there is no view to measure against, so it reads 0. `ref` has
    # already been through #character_ref, so "this event" arrives as a real id.
    def screen_operand(ref, attr)
      return 0 if ref.nil?
      return 0 unless @map_info.respond_to?(:character_screen_position)
      pos = @map_info.character_screen_position(ref)
      return 0 unless pos
      attr == 4 ? pos[:x] : pos[:y]
    end

    # Operand type 4: a count for the item with id param5. param6 selects the
    # mode: 0 the number held in the bag, 1 the number equipped across the party
    # (each slot equipping it counts). Matches EasyRPG's ControlVariables::Item.
    def item_operand(cmd)
      id = cmd.param(5)
      if cmd.param(6) == 1
        party.actors.reduce(0) { |n, a| n + a.equipment.count(id) }
      else
        party.item_count(id)
      end
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
      when 4 then val == 0 ? cur : cur / val
      when 5 then val == 0 ? cur : cur % val
      else cur
      end
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

    def do_change_party(cmd)
      actor = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      if cmd.param(0) == 0
        party.add_actor(actor)
      else
        party.remove_actor(actor)
      end
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
        a.gain_exp(amount)
        queue_level_up_messages(a, before, a.level) if show_msg
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
        a.change_level_by(amount)
        queue_level_up_messages(a, before, a.level) if show_msg
      end
      return if check_game_over
      show_next_pending_message
    end

    # Queue one level-up message per level `actor` gained going from `old_level`
    # to `new_level` (nothing when the level did not rise). RPG_RT phrases these
    # from the database terms; this build uses a plain English line for now.
    def queue_level_up_messages(actor, old_level, new_level)
      return unless new_level > old_level
      ((old_level + 1)..new_level).each do |lv|
        @pending_messages.push([level_up_message(actor, lv)])
      end
    end

    # The one line a level-up announces. RPG_RT phrases it from the database
    # terms; this build uses a plain English line for now.
    def level_up_message(actor, level)
      "#{actor.name} is now level #{level}!"
    end

    # Enter the next queued level-up message as a :message wait; returns false
    # (and does nothing) when the queue is empty.
    def show_next_pending_message
      return false if @pending_messages.empty?
      @message_lines = @pending_messages.shift
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
    # counts, each as a permille-style divisor, and param5 the damage spread.
    # When param6 is set the damage dealt is also written into variable param7.
    # The formula is EasyRPG Player's CommandSimulatedAttack, which mirrors
    # RPG_RT: `atk - def * p_def / 400 - spi * p_spi / 800`, then spread by
    # +/- (param5 * 5) percent and floored at 0. The hit can be lethal.
    def do_simulated_attack(cmd)
      atk = cmd.param(2)
      damage = 0
      stat_targets(cmd).each do |a|
        damage = atk - (a.def * cmd.param(3)) / 400 - (a.int * cmd.param(4)) / 800
        damage += damage * simulated_attack_spread(cmd.param(5)) / 100
        damage = 0 if damage < 0
        a.change_hp(-damage, true)
      end
      variables[cmd.param(7)] = damage if cmd.param(6) != 0
      check_game_over
    end

    # A Simulated Attack's random damage spread, as a percentage in
    # -(variance * 5) .. +(variance * 5). A variance of 0 never spreads.
    def simulated_attack_spread(variance)
      return 0 if variance.nil? || variance <= 0
      span = variance * 5
      @rng.random(span * 2 + 1) - span
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
        remove ? a.remove_state(state_id) : a.add_state(state_id)
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
        next unless a.change_class(class_id, level_1 ? 1 : a.level,
                                   skill_mode, param_mode)
        # Unlike Change Level (which announces every level crossed) RPG_RT shows
        # a single line here, and shows it whenever the class change taught new
        # skills even if the level itself did not move (EasyRPG's ChangeClass).
        next unless show_msg && a.level > 1
        next unless a.level > before || skill_mode != Game::Actor::CLASS_SKILL_NO_CHANGE
        @pending_messages.push([level_up_message(a, a.level)])
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
    def do_set_vehicle_location(cmd)
      v = vehicle_target(cmd)
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
    def do_change_equipment(cmd)
      targets = stat_targets(cmd)
      if cmd.param(2) == 0
        item = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
        targets.each { |a| a.equip_item(item) }
      else
        targets.each { |a| a.unequip(cmd.param(4)) }
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
    # scene can drop their sprites and play the escape sound.
    def do_force_flee(cmd)
      return unless @battle
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
    # it yet.
    def do_enable_combo(cmd)
      return unless @battle
      actor = identity_target(cmd)
      return unless actor
      actor.set_battle_combo(cmd.param(1), cmd.param(2))
    end

    # Call Common Event (1005), the RPG2003 battle page's own call command:
    # param0 is the common event id, and unlike the map's Call Event (12330)
    # there is no map-event form. Runs through the same call stack.
    def do_call_common_event(cmd)
      return unless @resolver
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
    # Raised through the same request/wait the map command uses, so the scene
    # drives one animation player for both.
    def do_show_battle_animation_b(cmd)
      @battle_animation = { animation: cmd.param(0), target: cmd.param(1),
                            wait: cmd.param(2) != 0, battle: true }
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
    # report false rather than guessing, so the else branch runs.
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

    # An actor sub-condition: is the actor in this fight, and is it afflicted by
    # the given status? The name / usable-command tests need data the battle
    # context does not carry, so they report false.
    def battle_actor_condition(cmd)
      ally = @battle && @battle.ally_by_actor_id(cmd.param(1))
      return false unless ally
      case cmd.param(2)
      when 0 then true                       # is in the party
      when 2 then ally.state?(cmd.param(3))  # is afflicted by a status
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
      return if eval_condition(cmd) # fall through into the true branch
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
        timer_condition(cmd, 1)
      else true
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
    def do_change_event_location(cmd)
      x = cmd.param(2)
      y = cmd.param(3)
      if cmd.param(1) == 1
        x = variables[x]
        y = variables[y]
      end
      @location_requests.push(op: :set, target: cmd.param(0), x: x, y: y)
    end

    # Trade Event Locations (Swap Event Locations): exchange the tiles of the two
    # characters named by param0 and param1 (same target ids as Change Event
    # Location). Queued as a `:swap` request the scene applies; non-blocking.
    def do_trade_event_locations(cmd)
      @location_requests.push(op: :swap, a: cmd.param(0), b: cmd.param(1))
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

    def do_wait(cmd)
      @wait_frames = cmd.param(0) # tenths of a second in RPG2000
      @wait_kind = :wait
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
    def do_flash_screen(cmd)
      frames = cmd.param(4) * FRAMES_PER_TENTH
      @state.screen.flash(cmd.param(0), cmd.param(1), cmd.param(2),
                          cmd.param(3), frames)
      return unless cmd.param(5) != 0 && @state.screen.flashing?
      @wait_kind = :screen
      @waiting = true
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
    def do_shake_screen(cmd)
      frames = cmd.param(2) * FRAMES_PER_TENTH
      @state.screen.shake(cmd.param(0), cmd.param(1), frames)
      return unless cmd.param(3) != 0 && @state.screen.shaking?
      @wait_kind = :screen
      @waiting = true
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
      @state.erase_picture(cmd.param(0))
    end

    # Show Battle Animation (11210): play battle animation param0 over a target
    # character on the map. param1 is the target id (the player, an event, or
    # this event — the Move Event target scheme) and param2 the "wait until it
    # finishes" flag. Records the request (which a future map-animation renderer
    # will draw) and, when the wait flag is set, suspends on an :animation wait so
    # the owning scene can hold the event for the animation's duration. Drawing
    # the animation itself is native renderer work still to come.
    def do_show_battle_animation(cmd)
      @battle_animation = { animation: cmd.param(0), target: cmd.param(1),
                            wait: cmd.param(2) != 0 }
      return unless cmd.param(2) != 0
      @wait_kind = :animation
      @waiting = true
    end

    # A picture coordinate: the literal param at `idx`, or the value of the
    # variable it names when the position-mode param (index 1) is non-zero.
    def picture_coord(cmd, idx)
      cmd.param(1) != 0 ? variables[cmd.param(idx)] : cmd.param(idx)
    end

    # RPG2000 transparency (0 opaque .. 100 fully clear) -> a 0..255 opacity.
    def trans_to_opacity(top_trans)
      (100 - Game.clamp(top_trans, 0, 100)) * 255 / 100
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
    def do_weather(cmd)
      @state.weather.set(cmd.param(0), cmd.param(1))
    end

    # Fade Out BGM (11520): fade the music to silence over param0 tenths of a
    # second, then leave nothing playing. Clears the current-BGM record so a
    # Memorize BGM taken afterwards memorises silence, as RPG_RT does.
    # Non-blocking — the event runs on while the music fades.
    MS_PER_TENTH = 100

    def do_fadeout_bgm(cmd)
      @state.current_bgm = nil
      @state.bgm_looped = false
      RGSS::Audio.bgm_fade(cmd.param(0) * MS_PER_TENTH)
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

    # Change System BGM: override one of the system music slots (battle,
    # victory, inn, ...) selected by param0. The remaining fields carry a Music
    # struct: string = file name, param1 fade-in, param2 volume, param3 tempo,
    # param4 balance. Stashed in a Game::State slot table; the battle / inn / …
    # scenes that would play these are not built yet, so this only preserves the
    # configured music across Save / Continue.
    def do_change_system_bgm(cmd)
      @state.system_bgm[cmd.param(0)] = {
        name: cmd.string, fadein: cmd.param(1), volume: cmd.param(2),
        tempo: cmd.param(3), balance: cmd.param(4)
      }
    end

    # Change System SFX: override one of the system sound slots (cursor,
    # decision, cancel, ...) selected by param0. string = file name, param1
    # volume, param2 tempo, param3 balance. Stored for save fidelity like the
    # system BGM; nothing plays these yet.
    def do_change_system_sfx(cmd)
      @state.system_sfx[cmd.param(0)] = {
        name: cmd.string, volume: cmd.param(1),
        tempo: cmd.param(2), balance: cmd.param(3)
      }
    end

    # Play Memorized BGM: resume the BGM stashed by Memorize BGM, making it the
    # current BGM again. A no-op when nothing was memorised. Playback resumes
    # from the start — the SDL_mixer backend cannot seek to the stored position.
    def do_play_memorized_bgm(_cmd)
      bgm = @state.memorized_bgm
      return if bgm.nil? || bgm[:name].nil? || bgm[:name].empty?
      RGSS::Audio.bgm_play(bgm[:name], bgm[:volume] || 100, bgm[:tempo] || 100)
      @state.current_bgm = bgm.dup
      @state.bgm_looped = false
    rescue StandardError => e
      $stderr.puts "[RPG2k] memorized BGM playback failed: #{e.message}"
      nil
    end

    def play_audio(kind, cmd)
      name = cmd.string
      return if name.nil? || name.empty?
      if kind == :bgm
        # PlayBGM parameters: [fade_in, volume, tempo, balance]. Volume/tempo
        # default to 100 when the command carries a shorter list.
        volume = cmd.parameters.size > 1 ? cmd.param(1) : 100
        pitch = cmd.parameters.size > 2 ? cmd.param(2) : 100
        # Track what is playing so Memorize BGM can stash it (RPG_RT keeps this
        # as the "current system BGM" regardless of whether playback succeeds).
        @state.current_bgm = { name: name, volume: volume, tempo: pitch }
        @state.bgm_looped = false # a fresh track has not looped yet
        RGSS::Audio.bgm_play(name, volume, pitch)
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
