#!/usr/bin/env ruby
# frozen_string_literal: true

# wio-only build step: rewrites a copy of a handful of mruby-rpg2k/mrblib
# files, folding a small, hand-picked set of methods into their one real
# engine call site -- mrbc has no inliner of its own (checked: nothing in
# mrbgems/mruby-compiler/core/codegen.c), so every def, no matter how many
# times (or how few) it is called, always gets its own irep node (a 10-byte
# header plus its own iseq/pool/syms blocks, never shared or deduplicated).
#
# Deliberately NOT a general inliner, and deliberately NOT touching the real
# source files at all. An earlier attempt at automating this broadly across
# every "single mrblib caller" method found the real blocker: scripts/*.rb's
# own CRuby-based regression checks (rpg2k_render_check.rb, in particular)
# call several of these same methods directly, by name, to test the exact
# formulas they implement (grid non-overlap, opacity edge cases including
# default-argument behaviour) -- e.g. `CS.bush_opacity`, `MP.cell_origin`.
# Deleting the methods outright, even ones with only one *engine* caller,
# would silently break real regression coverage that has nothing to do with
# wio. Keeping every definition exactly as-is in the checked-in source (so
# those checks keep testing them on every target, wio included at dev time)
# and only rewriting this specific, hand-verified set of call sites in a
# wio-only build-time copy keeps both: full regression coverage everywhere,
# and the flash win only where wio's own compiled build never reaches the
# definition through anything but this one call site anyway. See
# docs/adr/0129-wio-inline-single-caller-helpers.md.
#
# Deletions are expressed as a first-line/last-line marker pair rather than
# the full body text, and applied by line range: a whole method body is
# whitespace-sensitive enough (indentation inside a heredoc, in particular)
# that matching it verbatim as one string is itself a real way to introduce
# a silent bug, whereas two single-line markers are easy to eyeball and
# still refuse to apply (raising, same as a text-substitution mismatch)
# the moment either line stops appearing exactly once. Substitutions (the
# call sites) stay simple exact-text swaps -- always one line, no
# indentation-sensitive multi-line literal to get wrong.
#
# The regex/token-based general-automation attempt above (ADR 0129) failed
# for real, reproducible reasons: wrong call-site line numbers, a naive
# substring match confusing a `:symbol` literal for a real call, and
# multi-line call continuations corrupting the splice. All three are a
# location-finding problem, not a semantics one -- ADR 0131 rebuilds the
# same generation step on `RubyVM::AbstractSyntaxTree` instead (real
# per-node line/column spans, real node-type checks for CALL vs LIT,
# `rescue`/`ensure` detection by node type rather than text search), and
# every one of the entries it added below was re-verified through this
# exact file's own `apply_deletion`/`apply_rewrites` and a real `mrbc`
# compile before being written -- the generation method changed, the
# safety bar (real recompile, no guessing) did not.
#
# Usage: ruby strip_wio_inline_helpers.rb <input.rb> <output.rb>

require 'ripper'

REWRITES = {
  'mruby-rpg2k/mrblib/game.rb' => {
    deletions: [
      { first: '    # The opacity those sunken rows draw at: half, rounded up, of whatever the',
        last: '    end', # def self.bush_opacity's own `end`
        expect_lines: 7 },
      { first: '    # Top-left [x, y] of colour idx\'s swatch cell in the System graphic.',
        last: '    end', # def self.cell_origin's own `end`
        expect_lines: 4 },
      { first: '    # Top-left [x, y] of the shadow block in the System graphic.',
        last: '    end', # def self.shadow_origin's own `end`
        expect_lines: 4 },
      { first: '    # Animation frame (0..3) for the block-C animated tiles (advances every 6',
        last: '    end', # def self.anim_c's own `end`
        expect_lines: 5 },
      { first: '    def self.numpad_direction(lcf_dir)',
        last: '    end', # def self.numpad_direction's own `end`
        expect_lines: 3 },
      { first: '    def self.continuous?(anim_type)',
        last: '    end', # def self.continuous?'s own `end`
        expect_lines: 4 },
      { first: '    def self.frame_dir(anim_type, char_dir, phase)',
        last: '    end', # def self.frame_dir's own `end`
        expect_lines: 3 },
      { first: '    def item_cured_states(it)',
        last: '    end', # def item_cured_states's own `end`
        expect_lines: 3 },
      { first: '    # `MAX_EFFECTIVE_HP_2K3` on an RPG2003 database, `MAX_EFFECTIVE_HP_2K`',
        last: '    end', # def max_hp_cap's own `end`
        expect_lines: 5 },
      { first: '    def scroll_offset',
        last: '    end', # def scroll_offset's own `end`
        expect_lines: 13 },
      { first: '    def zoom_rect',
        last: '    end', # def zoom_rect's own `end`
        expect_lines: 11 },
      { first: '    def update_pan',
        last: '    end', # def update_pan's own `end`
        expect_lines: 4 },
      { first: '    def moving?; @frames > 0; end',
        last: '    def moving?; @frames > 0; end', # def moving?'s own `end`
        expect_lines: 1 },
      { first: '    def finish_move',
        last: '    end', # def finish_move's own `end`
        expect_lines: 4 },
      { first: '    def timer_frames; timer(0).frames; end',
        last: '    def timer_frames; timer(0).frames; end', # def timer_frames's own `end`
        expect_lines: 1 },
      { first: '    def apply_actor_meta(actor, m)',
        last: '    end', # def apply_actor_meta's own `end`
        expect_lines: 17 },
      { first: '    def update_flash',
        last: '    end', # def update_flash's own `end`
        expect_lines: 13 },
      { first: '    def item_field_occasion?(it)',
        last: '    end', # def item_field_occasion?'s own `end`
        expect_lines: 4 },
      { first: '    def use_special_item(it, id, actor)',
        last: '    end', # def use_special_item's own `end`
        expect_lines: 6 },
      { first: '    def attribute_weapon_type?(aid)',
        last: '    end', # def attribute_weapon_type?'s own `end`
        expect_lines: 5 },
    ],
    substitutions: [
      { old: '      @direction = EventGraphic.numpad_direction(m.direction)',
        new: '      @direction = EventGraphic::LCF_DIR_TO_NUMPAD[m.direction] || 2' },
      { old: '        (moving || continuous?(anim_type)) ? pattern_column(phase) : base_pattern',
        new: '        (moving || anim_type == CONTINUOUS || anim_type == FIXED_CONTINUOUS || ' \
             'anim_type == SPIN) ? pattern_column(phase) : base_pattern' },
      { old: '      [frame_dir(anim_type, char_dir, phase),',
        new: '      [(anim_type == SPIN ? spin_direction(phase) : char_dir),' },
      { old: '          item_cured_states(it).any? { |s| actor.state?(s) }',
        new: '          item_state_ids(it).any? { |s| actor.state?(s) }' },
      { old: '      cured = item_cured_states(it)',
        new: '      cured = item_state_ids(it)' },
      { old: '      @max_hp = Game.clamp(@base_raw[0] + equip_bonus(0), 1, max_hp_cap)',
        new: '      @max_hp = Game.clamp(@base_raw[0] + equip_bonus(0), 1, ' \
             '(rpg2003? ? MAX_EFFECTIVE_HP_2K3 : MAX_EFFECTIVE_HP_2K))' },
      { old: '        ox, oy = scroll_offset
',
        new: '        ox, oy = (p, d = frame_ratio; case @style
      when SCROLL_UP_IN    then [0, @height - @height * p / d]
      when SCROLL_DOWN_IN  then [0, -(@height - @height * p / d)]
      when SCROLL_LEFT_IN  then [@width - @width * p / d, 0]
      when SCROLL_RIGHT_IN then [-(@width - @width * p / d), 0]
      when SCROLL_UP_OUT   then [0, -(@height * p / d)]
      when SCROLL_DOWN_OUT then [0, @height * p / d]
      when SCROLL_LEFT_OUT then [-(@width * p / d), 0]
      when SCROLL_RIGHT_OUT then [@width * p / d, 0]
      end)
' }, # scroll_offset
      { old: '        [zoom_rect]
',
        new: '        [(p, d = frame_ratio; if @style == ZOOM_OUT
        sw = @width * p / d
        sh = @height * p / d
      else
        sw = @width - @width * p / d
        sh = @height - @height * p / d
      end; [0, 0, @width, @height, (@width - sw) / 2, (@height - sh) / 2, sw, sh])]
' }, # zoom_rect
      { old: '      update_pan
',
        new: '      (@pan_x = approach(@pan_x, @pan_tx, @pan_step); @pan_y = approach(@pan_y, @pan_ty, @pan_step))
' }, # update_pan
      { old: '      return unless moving?
',
        new: '      return unless (@frames > 0)
' }, # moving?
      { old: '      finish_move if @frames == 0
',
        new: '      (@x = @tx; @y = @ty; @zoom = @tzoom; @opacity = @topacity; @red = @tred; @green = @tgreen; @blue = @tblue; @saturation = @tsat) if @frames == 0
' }, # finish_move
      { old: '        timer_frames: timer_frames,
',
        new: '        timer_frames: (timer(0).frames),
' }, # timer_frames
      { old: '        apply_actor_meta(a, m)
',
        new: '        (unless !(m); actor.name = m[:name] if m[:name]; actor.title = m[:title] unless m[:title].nil?; if m[:charset_name] && m[:sprite_changed] != false
        actor.set_charset(m[:charset_name], m[:charset_index] || actor.charset_index)
      end; actor.transparent = m[:transparent] unless m[:transparent].nil?; actor.states = m[:states] if m[:states]; actor.battle_commands = m[:battle_commands] if m[:battle_commands]; actor.battle_row = m[:row] if m[:row]; end)
' }, # apply_actor_meta
      { old: '      update_flash
',
        new: '      (unless (@flash_frames <= 0); @flash_frames -= 1; if @flash_frames <= 0 && @flash_continuous
        # A Begin strobe never settles: re-arm at peak strength for another
        # full duration, matching `Flash::Update`\'s own continuous re-arm.
        @flash_frames = @flash_total
        @flash_strength = @flash_power
      else
        # Strength fades linearly from the peak power to 0 across the duration.
        @flash_strength = @flash_total > 0 ? @flash_power * @flash_frames / @flash_total : 0
      end; end)
' }, # update_flash
      { old: '      when ITEM_SWITCH then item_field_occasion?(it)
',
        new: '      when ITEM_SWITCH then (it.respond_to?(:occasion_field2) ? it.occasion_field2 : (true))
' }, # item_field_occasion?
      { old: '      when ITEM_SPECIAL then use_special_item(it, id, actor)
',
        new: '      when ITEM_SPECIAL then (!(actor && item_usable_by?(it, actor.id)) ? [] : (affected = cast_skill(actor, it.skill_id, actor, true); consume_item_use(id) unless affected.empty?; affected))
' }, # use_special_item
      { old: '      ids = skill_attributes(sk).select { |aid| attribute_weapon_type?(aid) }
',
        new: '      ids = skill_attributes(sk).select { |aid| (!(@db.respond_to?(:property) && @db.property) ? false : (row = @db.property[aid]; row && row.respond_to?(:type) && row.type == 0 ? true : false)) }
' }, # attribute_weapon_type?
    ],
  },
  'mruby-rpg2k/mrblib/scene/map.rb' => {
    deletions: [
      { first: '      # Drive the just-started foreground Auto-Start process, then -- yado.tk',
        last: '      end', # def drive_autostart_cascade's own `end`
        expect_lines: 45 },
      { first: '      def valid_move_freq(f)',
        last: '      end', # def valid_move_freq's own `end`
        expect_lines: 3 },
      { first: '      def apply_tile_substitution(interp)',
        last: '      end', # def apply_tile_substitution's own `end`
        expect_lines: 4 },
      { first: '      def setup_screen_overlay',
        last: '      end', # def setup_screen_overlay's own `end`
        expect_lines: 45 },
      { first: '      def update_screen_overlay',
        last: '      end', # def update_screen_overlay's own `end`
        expect_lines: 23 },
      { first: '      def reset_fade_bitmap',
        last: '      end', # def reset_fade_bitmap's own `end`
        expect_lines: 4 },
      { first: '      def setup_pictures',
        last: '      end', # def setup_pictures's own `end`
        expect_lines: 12 },
      { first: '      def record_foreground_event_exec',
        last: '      end', # def record_foreground_event_exec's own `end`
        expect_lines: 5 },
      { first: '      def record_tile_substitutions',
        last: '      end', # def record_tile_substitutions's own `end`
        expect_lines: 3 },
      { first: '      def events_move_during_message?',
        last: '      end', # def events_move_during_message?'s own `end`
        expect_lines: 3 },
      { first: '      def parallels_paused?',
        last: '      end', # def parallels_paused?'s own `end`
        expect_lines: 3 },
      { first: '      def reload_windowskin',
        last: '      end', # def reload_windowskin's own `end`
        expect_lines: 5 },
      { first: '      def player_hidden?',
        last: '      end', # def player_hidden?'s own `end`
        expect_lines: 3 },
      { first: '      def player_translucent?',
        last: '      end', # def player_translucent?'s own `end`
        expect_lines: 4 },
      { first: '      def flash_buffer',
        last: '      end', # def flash_buffer's own `end`
        expect_lines: 3 },
      { first: '      def flash_out_buffer',
        last: '      end', # def flash_out_buffer's own `end`
        expect_lines: 3 },
      { first: '      def start_player_slide',
        last: '      end', # def start_player_slide's own `end`
        expect_lines: 9 },
      { first: '      def player_slide_step',
        last: '      end', # def player_slide_step's own `end`
        expect_lines: 6 },
      { first: '      def drive_key_input',
        last: '      end', # def drive_key_input's own `end`
        expect_lines: 3 },
      { first: '      def build_shop_gold_window',
        last: '      end', # def build_shop_gold_window's own `end`
        expect_lines: 8 },
      { first: '      def shop_list_min_inner_h',
        last: '      end', # def shop_list_min_inner_h's own `end`
        expect_lines: 3 },
      { first: '      def drive_shop_command',
        last: '      end', # def drive_shop_command's own `end`
        expect_lines: 16 },
      { first: '      def drive_shop_list',
        last: '      end', # def drive_shop_list's own `end`
        expect_lines: 15 },
      { first: '      def animation_cell_crop_buffer',
        last: '      end', # def animation_cell_crop_buffer's own `end`
        expect_lines: 3 },
      { first: '      def drive_wait',
        last: '      end', # def drive_wait's own `end`
        expect_lines: 9 },
      { first: '      def party_leader',
        last: '      end', # def party_leader's own `end`
        expect_lines: 4 },
      { first: '      def apply_pending_choice_lines',
        last: '      end', # def apply_pending_choice_lines's own `end`
        expect_lines: 8 },
      { first: '      def hero_screen_y',
        last: '      end', # def hero_screen_y's own `end`
        expect_lines: 5 },
      { first: '      def draw_timer',
        last: '      end', # def draw_timer's own `end`
        expect_lines: 6 },
      { first: '      def build_timer_sprite',
        last: '      end', # def build_timer_sprite's own `end`
        expect_lines: 6 },
      { first: '      def player_draw_charset',
        last: '      end', # def player_draw_charset's own `end`
        expect_lines: 7 },
      { first: '      def release_transition_capture',
        last: '      end', # def release_transition_capture's own `end`
        expect_lines: 6 },
      { first: '      def player_jump_offset',
        last: '      end', # def player_jump_offset's own `end`
        expect_lines: 4 },
      { first: '      def try_open_menu',
        last: '      end', # def try_open_menu's own `end`
        expect_lines: 6 },
      { first: '      def close_name_input',
        last: '      end', # def close_name_input's own `end`
        expect_lines: 12 },
      { first: '      def clear_map_target_flash(target)',
        last: '      end', # def clear_map_target_flash's own `end`
        expect_lines: 12 },
      { first: '      def drive_wait_key_enter',
        last: '      end', # def drive_wait_key_enter's own `end`
        expect_lines: 4 },
      { first: '      def draw_event_tile(e, bmp, cam_x, cam_y, opacity)',
        last: '      end', # def draw_event_tile's own `end`
        expect_lines: 12 },
      { first: '      def common_gate_open?(c)',
        last: '      end', # def common_gate_open?'s own `end`
        expect_lines: 4 },
      { first: '      def counter_tile?(x, y)',
        last: '      end', # def counter_tile?'s own `end`
        expect_lines: 4 },
      { first: '      def try_board_vehicle',
        last: '      end', # def try_board_vehicle's own `end`
        expect_lines: 24 },
      { first: '      def warn_stale_terrain(x, y, tid)',
        last: '      end', # def warn_stale_terrain's own `end`
        expect_lines: 6 },
      { first: '      def step_ownerless_map_animation',
        last: '      end', # def step_ownerless_map_animation's own `end`
        expect_lines: 8 },
      { first: '      def start_map_animation(req)',
        last: '      end', # def start_map_animation's own `end`
        expect_lines: 20 },
      { first: '      def load_face(cfg)',
        last: '      end', # def load_face's own `end`
        expect_lines: 4 },
      { first: '      def choice_row_indent(line_index)',
        last: '      end', # def choice_row_indent's own `end`
        expect_lines: 4 },
      { first: '      def terrain_step_damage(row = terrain_row_at(@state.x, @state.y))',
        last: '      end', # def terrain_step_damage's own `end`
        expect_lines: 4 },
      { first: '      def current_encounter_steps',
        last: '      end', # def current_encounter_steps's own `end`
        expect_lines: 5 },
      { first: '      def player_bush_depth',
        last: '      end', # def player_bush_depth's own `end`
        expect_lines: 4 },
    ],
    substitutions: [
      { old: '        sunk = Game::CharSet.bush_opacity(opacity)',
        new: '        sunk = (opacity + 1) / 2' },
      { old: '          cf = Game::ChipsetLayout.anim_c(@anim_frame)',
        new: '          cf = (@anim_frame / 6) % 4' },
      { old: '            drive_autostart_cascade',
        new: "            loop do\n" \
             "              drive_event\n" \
             "              break if event_busy?\n" \
             "              start_autostart\n" \
             "              break unless event_busy?\n" \
             '            end' },
      { old: '        dir = Game::EventGraphic.numpad_direction(page_direction(page))',
        new: '        dir = Game::EventGraphic::LCF_DIR_TO_NUMPAD[page_direction(page)] || 2' },
      { old: '        return unless sliding || Game::EventGraphic.continuous?(type)',
        new: '        return unless sliding || type == Game::EventGraphic::CONTINUOUS || ' \
             'type == Game::EventGraphic::FIXED_CONTINUOUS || type == Game::EventGraphic::SPIN' },
      { old: '        dir = Game::EventGraphic.frame_dir(e[:anim_type], ch.direction, e[:anim_phase])',
        new: '        dir = e[:anim_type] == Game::EventGraphic::SPIN ? ' \
             'Game::EventGraphic.spin_direction(e[:anim_phase]) : ch.direction' },
      { old: '        ev[:forced_freq] = valid_move_freq(freq)',
        new: '        ev[:forced_freq] = ((freq && freq >= 1 && freq <= 8) ? freq : nil)' },
      { old: '        ch.move_frequency = valid_move_freq(freq) || ch.move_frequency',
        new: '        ch.move_frequency = ((freq && freq >= 1 && freq <= 8) ? freq : nil) || ' \
             'ch.move_frequency' },
      { old: '        @player_char.move_frequency = valid_move_freq(freq) ||',
        new: '        @player_char.move_frequency = ((freq && freq >= 1 && freq <= 8) ? freq : nil) ||' },
      { old: '        apply_tile_substitution(interp)',
        new: '        (interp.take_tiles_changed; nil)' },
      { old: '        setup_screen_overlay
',
        new: '        (@fade_sprite = Sprite.new; @fade_sprite.z = 500; @fade_bmp = Bitmap.new(SCREEN_W, SCREEN_H); @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(0, 0, 0, 255); @fade_sprite.bitmap = @fade_bmp; @fade_sprite.opacity = 0; @fade_masked = false; @transition_capture = nil; @captured_transition = nil; @random_blocks_transition = nil; @flash_sprite = Sprite.new; @flash_sprite.z = 450; @flash_sprite.opacity = 0; @flash_rgb = nil; @weather_sprite = Sprite.new; @weather_sprite.z = 430; @weather_sprite.visible = false)
' }, # setup_screen_overlay
      { old: '        RGSS::Profiler.section("map.overlay") { update_screen_overlay }
',
        new: '        RGSS::Profiler.section("map.overlay") { (screen = @state.screen; draw_transition_mask screen; update_map_tone screen.tint; r, g, b, strength = screen.flash_color; if strength <= 0
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
        end; draw_weather) }
' }, # update_screen_overlay
      { old: '          reset_fade_bitmap if @fade_masked
',
        new: '          (@fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK; @fade_masked = false) if @fade_masked
' }, # reset_fade_bitmap
      { old: '        setup_pictures
',
        new: '        (@picture_sprite = Sprite.new; @picture_sprite.z = 250; @picture_tone_cache = {})
' }, # setup_pictures
      { old: '        record_foreground_event_exec
',
        new: '        (frames = @interpreter.call_stack_snapshot; @state.foreground_event_exec =
          frames && { event_id: @active_event ? @active_event[:id] : 0, frames: frames })
' }, # record_foreground_event_exec
      { old: '        record_tile_substitutions
',
        new: '        (@state.tile_substitutions = @map.substitution_snapshot)
' }, # record_tile_substitutions
      { old: '          step_events(allow_trigger: false) if events_move_during_message?
',
        new: '          step_events(allow_trigger: false) if (message_window_open? && @state.message_config.continue_events)
' }, # events_move_during_message?
      { old: '        paused = parallels_paused?
',
        new: '        paused = (!@battle.nil? || (@interpreter.running? && !@interpreter.waiting?))
' }, # parallels_paused?
      { old: '        reload_windowskin if interp.take_system_graphic_changed
',
        new: '        (old = @windowskin; @windowskin = load_windowskin; old.dispose if old && !old.equal?(@windowskin)) if interp.take_system_graphic_changed
' }, # reload_windowskin
      { old: '        @player_sprite.visible = !player_hidden?
',
        new: '        @player_sprite.visible = !(@state.player_transparent ? true : false)
' }, # player_hidden?
      { old: '        @player_sprite.opacity = player_translucent? ? TRANSLUCENT_OPACITY : 255
',
        new: '        @player_sprite.opacity = (leader = @state.party.leader; leader && leader.transparent ? true : false) ? TRANSLUCENT_OPACITY : 255
' }, # player_translucent?
      { old: '        buf = flash_buffer
',
        new: '        buf = (@flash_buffer ||= Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT))
' }, # flash_buffer
      { old: '        out = flash_out_buffer
',
        new: '        out = (@flash_out_buffer ||= Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT))
' }, # flash_out_buffer
      { old: '          start_player_slide
',
        new: '          (@dest_x = @player_char.x; @dest_y = @player_char.y; @moving = true; @move_count = 0; @slide_frac = 0; @player_jumping = @player_char.jumped; @player_forced_step = true)
' }, # start_player_slide
      { old: '        @move_count, @slide_frac = advance_slide(@move_count, @slide_frac || 0, player_slide_step)
',
        new: '        @move_count, @slide_frac = advance_slide(@move_count, @slide_frac || 0, (speed = @player_char&.move_speed || 3; step = @player_jumping ? jump_slide_step(speed)
                               : walk_slide_step(speed); @state.boarded == :airship && !@player_jumping ? step * 2 : step))
' }, # player_slide_step
      { old: '          when :key_input then drive_key_input
',
        new: '          when :key_input then (resolve_key_input(@interpreter))
' }, # drive_key_input
      { old: '                  scroll: 0, cmd_index: 0, window: nil, gold: build_shop_gold_window,
',
        new: '                  scroll: 0, cmd_index: 0, window: nil, gold: (gw = SHOP_STATUS_W; win = Window.new(SCREEN_W - gw - 6, SHOP_GOLD_Y,
                         gw, SHOP_LINE_H + Window::BORDER * 2); win.z = 300; win.windowskin = @windowskin; win),
' }, # build_shop_gold_window
      { old: '        inner_h = [inner_h, shop_list_min_inner_h].max
',
        new: '        inner_h = [inner_h, (SCREEN_H - SHOP_DESC_H - MSG_WIN_H - Window::BORDER * 2)].max
' }, # shop_list_min_inner_h
      { old: '        when :command  then drive_shop_command
',
        new: '        when :command  then (lines = shop_lines; if shop_move_cursor(lines)
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
        end)
' }, # drive_shop_command
      { old: '        else drive_shop_list
',
        new: '        else (lines = shop_lines; if shop_move_cursor(lines)
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
        end)
' }, # drive_shop_list
      { old: '        buf = animation_cell_crop_buffer
',
        new: '        buf = (@animation_cell_crop_buffer ||= Bitmap.new(ANIM_CELL, ANIM_CELL))
' }, # animation_cell_crop_buffer
      { old: '            drive_wait
',
        new: '            (@wait_timer = frames_from_tenths(@interpreter.wait_frames) if @wait_timer.nil?; if @wait_timer <= 0
          @wait_timer = nil
          @interpreter.resume
        else
          @wait_timer -= 1
        end)
' }, # drive_wait
      { old: '        a = id.to_i.zero? ? party_leader : roster_actor(id)
',
        new: '        a = id.to_i.zero? ? (party = @state.party; party.respond_to?(:leader) ? party.leader : nil) : roster_actor(id)
' }, # party_leader
      { old: '          apply_pending_choice_lines if confirm
',
        new: '          (new_seg_lines = @message[:pending_choice]; @message[:pending_choice] = nil; @message[:window].pause = false; @message[:choice_start] = 0; @message[:seg_lines] = new_seg_lines; install_choice_lines(new_seg_lines)) if confirm
' }, # apply_pending_choice_lines
      { old: '        disp = hero_screen_y
',
        new: '        disp = (_px, py = player_pixel; cam_y = Game.camera_offset(py + TILE, SCREEN_H, @map.height * TILE); (py + TILE) - cam_y)
' }, # hero_screen_y
      { old: '        draw_timer
',
        new: '        (battle = !@battle.nil?; @timer_sprites ||= [nil, nil]; draw_one_timer(0, battle); draw_one_timer(1, battle))
' }, # draw_timer
      { old: '        spr ||= (@timer_sprites[id] = build_timer_sprite)
',
        new: '        spr ||= (@timer_sprites[id] = (spr = Sprite.new; spr.z = 250; spr.bitmap = Bitmap.new(TIMER_INNER_W, TIMER_INNER_H); spr))
' }, # build_timer_sprite
      { old: '        charset, charset_index = player_draw_charset
',
        new: '        charset, charset_index = (if @player_char && @player_char.graphic_name
          [event_charset(@player_char.graphic_name), @player_char.graphic_index]
        else
          [@charset, @charset_index]
        end)
' }, # player_draw_charset
      { old: '        release_transition_capture
',
        new: '        (unless !(@transition_capture); @transition_capture.dispose; @transition_capture = nil; @captured_transition = nil; end)
' }, # release_transition_capture
      { old: '                             player_jump_offset
',
        new: '                             (unless !(@player_jumping && @moving); jump_offset_for(@move_count); end)
' }, # player_jump_offset
      { old: '            try_open_menu
',
        new: '            (unless (event_busy?) || !(@state.menu_access) || !(Input.trigger?(Input::B)); @parent.push Scene::Menu.new(@parent, @state); end)
' }, # try_open_menu
      { old: '        close_name_input
',
        new: '        (unless !(@name_ui); @name_ui[:background].dispose if @name_ui[:background]; if @name_ui[:kana]
          @name_ui[:face_win].dispose if @name_ui[:face_win]
          @name_ui[:name_win].dispose if @name_ui[:name_win]
          @name_ui[:grid_win].dispose if @name_ui[:grid_win]
        else
          @name_ui[:win].dispose if @name_ui[:win]
        end; @name_ui = nil; end)
' }, # close_name_input
      { old: '              clear_map_target_flash(tgt[:flash_target])
',
        new: '              (unless (target.nil?); if Game::Vehicle::TYPES.include?(target)
          spr = @vehicle_sprites && @vehicle_sprites[target]
          spr.flash(nil, 0) if spr
        elsif target == :player
          @last_frame = nil if @state.player_flash
          @state.player_flash = nil
        else
          target[:flash] = nil
        end; end)
' }, # clear_map_target_flash
      { old: '            drive_wait_key_enter
',
        new: '            (unless (message_window_open?); @interpreter.resume if Input.trigger?(Input::C); end)
' }, # drive_wait_key_enter
      { old: '          draw_event_tile(e, bmp, cam_x, cam_y, opacity)
',
        new: '          (unless !(@chipset_bmp); sx, sy, sw, sh = Game::ChipsetLayout.event_tile_rect(e[:char].graphic_index); epx, epy = event_pixel(e); dx = epx - cam_x; dy = epy - cam_y - event_jump_offset(e); blt_bushed bmp, dx, dy, @chipset_bmp, Rect.new(sx, sy, sw, sh), opacity,
                   event_bush_depth(e, sh); end)
' }, # draw_event_tile
      { old: '            common_gate_open?(c) && !@started_common[c[:id]] &&
',
        new: '            (!(c[:need_flag]) ? true : (@state.switches[c[:switch_id]])) && !@started_common[c[:id]] &&
' }, # common_gate_open?
      { old: '          break unless counter_tile?(fx, fy)
',
        new: '          break unless (@chipset.nil? || !@map.in_bounds?(x, y) ? false : (@chipset.counter?(@map.upper(x, y))))
' }, # counter_tile?
      { old: '            try_action_trigger unless try_board_vehicle
',
        new: '            try_action_trigger unless (event_busy? ? false : (!(Input.trigger?(Input::C)) ? false : (if @state.boarded?
          airship = @state.boarded == :airship
          disembarked = disembark_vehicle
          # Ported from a reference implementation\'s action-trigger check,
          # NOT independently confirmed against genuine RPG_RT under wine: it
          # opens with an unconditional flying-check
          # bail, so an airship rider\'s Decision press never falls through
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
        end)))
' }, # try_board_vehicle
      { old: '        warn_stale_terrain(x, y, tid) if row.nil?
',
        new: '        (@warned_stale_terrain[[x, y]] ? nil : (@warned_stale_terrain[[x, y]] = true; $stderr.puts "[RPG2k] Terrain: tile (#{x}, #{y}) references terrain " \\
                     "##{tid}, which no longer exists in the database")) if row.nil?
' }, # warn_stale_terrain
      { old: '        step_ownerless_map_animation # a fire-and-forget Show Battle Animation plays on, unattended
',
        new: '        (!(@map_animation_interp.nil?) ? nil : (if @map_animation
          step_map_animation unless @map_animation[:battle]
        elsif @anim_wait
          step_animation_wait
        end)) # a fire-and-forget Show Battle Animation plays on, unattended
' }, # step_ownerless_map_animation
      { old: '        @map_animation = start_map_animation(req)
',
        new: '        @map_animation = (!(req) ? nil : (req[:battle] ? @battle.start_battle_page_animation(req) : (!(animation_target_resolves?(req[:target])) ? nil : (flash_target = map_animation_flash_target(req[:target]); targets =
          if req[:global]
            global_animation_targets(flash_target)
          else
            tx, ty = animation_target_pixel(req[:target])
            # Every map target -- the player, a map event, a vehicle -- gets
            # the same fixed height for #animation_position_offset\'s
            # Head/Feet split (see ANIM_MAP_TARGET_HEIGHT\'s own comment for
            # why this is 24, not the CharSet frame\'s actual 32px), so the
            # sprite bounding box is known without asking what kind of
            # character this actually is.
            [anim_target(tx, ty, height: ANIM_MAP_TARGET_HEIGHT, index: nil, flash_target: flash_target)]
          end; build_animation(req[:animation], targets, false)))))
' }, # start_map_animation
      { old: '        face_sheet = load_face(cfg)
',
        new: '        face_sheet = (!(cfg.face?) ? nil : (load_face_bitmap(cfg.face_name)))
' }, # load_face
      { old: '          x = @message[:text_x] + choice_row_indent(start + i)
',
        new: '          x = @message[:text_x] + (!(@message && @message[:choice]) ? 0 : (line_index >= (@message[:choice_start] || 0) ? MSG_CHOICE_INDENT : 0))
' }, # choice_row_indent
      { old: '          terrain_hit = terrain_step_damage(row)
',
        new: '          terrain_hit = (!(row && row.respond_to?(:damage)) ? [] : (@state.party.apply_terrain_damage(row.damage)))
' }, # terrain_step_damage
      { old: '        steps = current_encounter_steps
',
        new: '        steps = (@state.encounter_rate ? @state.encounter_rate : (row = map_node_properties; row && row.respond_to?(:encount_steps) ? row.encount_steps : 25))
' }, # current_encounter_steps
      { old: '        bush = player_bush_depth
',
        new: '        bush = (@player_jumping || @state.boarded? ? 0 : (bush_pixels_at(@state.x, @state.y)))
' }, # player_bush_depth
    ],
  },
  'mruby-rpg2k/mrblib/scene/base.rb' => {
    deletions: [
      { first: '      def normal_status_term',
        last: '      end', # def normal_status_term's own `end`
        expect_lines: 3 },
    ],
    substitutions: [
      { old: "        shx, shy = Game::MessagePalette.shadow_origin\n",
        new: "        shx, shy = Game::MessagePalette::SHADOW_X, Game::MessagePalette::SHADOW_Y\n" },
      { old: "        sx, sy = Game::MessagePalette.cell_origin(idx)\n",
        new: "        sx = (idx % Game::MessagePalette::COLS) * cell\n" \
             "        sy = (idx / Game::MessagePalette::COLS) * cell + Game::MessagePalette::Y_OFFSET\n" },
      { old: '        return [normal_status_term, 0] unless id
',
        new: '        return [(term(:normal_status)), 0] unless id
' }, # normal_status_term
    ],
  },
  'mruby-rpg2k/mrblib/interpreter.rb' => {
    deletions: [
      { first: '    def trunc_mod(n, d)',
        last: '    end', # def trunc_mod's own `end`
        expect_lines: 3 },
      { first: '    # lets an event open the menu it has otherwise locked out.',
        last: '    end', # def do_open_main_menu's own `end`
        expect_lines: 5 },
      { first: '    # the Decision key (the Maniac Patch\'s own extra wait_type/mode encoding is a',
        last: '    end', # def do_wait's own `end`
        expect_lines: 11 },
      { first: '    def finished?',
        last: '    end', # def finished?'s own `end`
        expect_lines: 3 },
      { first: '    def return_from_call',
        last: '    end', # def return_from_call's own `end`
        expect_lines: 5 },
      { first: '    def do_message_options(cmd)',
        last: '    end', # def do_message_options's own `end`
        expect_lines: 8 },
      { first: '    def do_change_face(cmd)',
        last: '    end', # def do_change_face's own `end`
        expect_lines: 15 },
      { first: '    def simulated_attack_variance(base, var)',
        last: '    end', # def simulated_attack_variance's own `end`
        expect_lines: 6 },
      { first: '    def do_show_hidden_monster(cmd)',
        last: '    end', # def do_show_hidden_monster's own `end`
        expect_lines: 4 },
      { first: '    def do_force_flee(cmd)',
        last: '    end', # def do_force_flee's own `end`
        expect_lines: 10 },
      { first: '    def do_change_battle_bg(cmd)',
        last: '    end', # def do_change_battle_bg's own `end`
        expect_lines: 4 },
      { first: '    def do_terminate_battle(_cmd)',
        last: '    end', # def do_terminate_battle's own `end`
        expect_lines: 7 },
      { first: '    def do_conditional_battle(cmd)',
        last: '    end', # def do_conditional_battle's own `end`
        expect_lines: 5 },
      { first: '    def battle_command_condition(cmd)',
        last: '    end', # def battle_command_condition's own `end`
        expect_lines: 4 },
      { first: '    def battle_target_enemy_condition(cmd)',
        last: '    end', # def battle_target_enemy_condition's own `end`
        expect_lines: 4 },
      { first: '    def do_teleport(cmd)',
        last: '    end', # def do_teleport's own `end`
        expect_lines: 7 },
      { first: '    def do_recall_location(cmd)',
        last: '    end', # def do_recall_location's own `end`
        expect_lines: 7 },
      { first: '    def do_open_load_menu(_cmd)',
        last: '    end', # def do_open_load_menu's own `end`
        expect_lines: 5 },
      { first: '    def do_exit_game(_cmd)',
        last: '    end', # def do_exit_game's own `end`
        expect_lines: 5 },
      { first: '    def do_toggle_atb_mode(_cmd)',
        last: '    end', # def do_toggle_atb_mode's own `end`
        expect_lines: 4 },
      { first: '    def do_toggle_fullscreen(_cmd)',
        last: '    end', # def do_toggle_fullscreen's own `end`
        expect_lines: 4 },
      { first: '    def do_open_video_options(_cmd)',
        last: '    end', # def do_open_video_options's own `end`
        expect_lines: 4 },
      { first: '    def block_pending_battle_command',
        last: '    end', # def block_pending_battle_command's own `end`
        expect_lines: 7 },
      { first: '    def block_pending_key_input_command(wait)',
        last: '    end', # def block_pending_key_input_command's own `end`
        expect_lines: 7 },
      { first: '    def do_erase_picture(cmd)',
        last: '    end', # def do_erase_picture's own `end`
        expect_lines: 4 },
    ],
    substitutions: [
      { old: '      when 5 then val == 0 ? 0 : trunc_mod(cur, val)',
        new: '      when 5 then val == 0 ? 0 : (cur - val * trunc_div(cur, val))' },
      { old: '      when Cmd::OPEN_MAIN_MENU   then do_open_main_menu cmd',
        new: '      when Cmd::OPEN_MAIN_MENU   then (@wait_kind = :menu; @waiting = true)' },
      { old: '      when Cmd::WAIT             then do_wait cmd',
        new: '      when Cmd::WAIT             then ' \
             '(if @state.party.rpg2003? && cmd.parameters.size > 1 && cmd.param(1) != 0; ' \
             '@wait_kind = :wait_key_enter; else; @wait_frames = cmd.param(0); ' \
             '@wait_kind = :wait; end; @waiting = true)' },
      { old: '      if finished?
',
        new: '      if (@index >= @list.size && @call_stack.empty? && !@waiting)
' }, # finished?
      { old: '        return_from_call while @index >= @list.size && !@call_stack.empty?
',
        new: '        (@call_stack.empty? ? false : (@list, @index, @call_frame_event_id = @call_stack.pop; true)) while @index >= @list.size && !@call_stack.empty?
' }, # return_from_call
      { old: '      when Cmd::MESSAGE_OPTIONS  then do_message_options cmd
',
        new: '      when Cmd::MESSAGE_OPTIONS  then (block_pending_message_config_command ? nil : (cfg = @state.message_config; cfg.transparent = cmd.param(0) != 0; cfg.position = cmd.param(1); cfg.position_fixed = cmd.param(2) == 0; cfg.continue_events = cmd.param(3) != 0))
' }, # do_message_options
      { old: '      when Cmd::CHANGE_FACE      then do_change_face cmd
',
        new: '      when Cmd::CHANGE_FACE      then (block_pending_message_config_command ? nil : (cfg = @state.message_config; name = cmd.string || \'\'; if name.empty?
        cfg.clear_face
        @face_owner = false
      else
        cfg.face_name = name
        cfg.face_index = cmd.param(0)
        cfg.face_right = cmd.param(1) != 0
        cfg.face_flipped = cmd.param(2) != 0
        @face_owner = true
      end))
' }, # do_change_face
      { old: '        damage = simulated_attack_variance(damage, cmd.param(5))
',
        new: '        damage = (!(var && var > 0 && base > 0) ? base : (adj = var * base / 10; adj = 1 if adj < 1; base + @rng.random(adj + 1) - adj / 2))
' }, # simulated_attack_variance
      { old: '      when Cmd::SHOW_HIDDEN_MONSTER      then do_show_hidden_monster cmd
',
        new: '      when Cmd::SHOW_HIDDEN_MONSTER      then (!(@battle) ? nil : (@revealed_monsters.push(cmd.param(0))))
' }, # do_show_hidden_monster
      { old: '      when Cmd::FORCE_FLEE               then do_force_flee cmd
',
        new: '      when Cmd::FORCE_FLEE               then (!(@battle && @state.party.rpg2003?) ? nil : (case cmd.param(0)
      when 0 then @battle.force_flee_party
      when 1 then @fled_monsters.concat(@battle.flee_all_enemies)
      when 2
        index = cmd.param(1)
        @fled_monsters.push(index) if @battle.flee_enemy(index)
      end))
' }, # do_force_flee
      { old: '      when Cmd::CHANGE_BATTLE_BG         then do_change_battle_bg cmd
',
        new: '      when Cmd::CHANGE_BATTLE_BG         then (!(@battle) ? nil : (@battle_background = (cmd.string || \'\').to_s))
' }, # do_change_battle_bg
      { old: '      when Cmd::TERMINATE_BATTLE then do_terminate_battle cmd
',
        new: '      when Cmd::TERMINATE_BATTLE then (!(@battle) ? nil : (@battle.terminate; @index = @list.size; @call_stack = []; @call_frame_event_id = nil))
' }, # do_terminate_battle
      { old: '      when Cmd::CONDITIONAL_B            then do_conditional_battle cmd
',
        new: '      when Cmd::CONDITIONAL_B            then (eval_battle_condition(cmd) ? nil : (skip_to(SKIP_TO_ELSE_OR_END_BRANCH_B, cmd.indent); consume))
' }, # do_conditional_battle
      { old: '      when 5 then battle_command_condition(cmd)
',
        new: '      when 5 then (!(@battle) ? false : (@battle.actor_command(cmd.param(1), battle_source) == cmd.param(2)))
' }, # battle_command_condition
      { old: '      when 4 then battle_target_enemy_condition(cmd)
',
        new: '      when 4 then (!(@battle) ? false : (@battle.target_enemy_index(battle_source) == cmd.param(1)))
' }, # battle_target_enemy_condition
      { old: '      when Cmd::TELEPORT         then do_teleport cmd
',
        new: '      when Cmd::TELEPORT         then (block_pending_teleport_command ? nil : (dir = @state.party.rpg2003? && cmd.parameters.size > 3 ? teleport_facing(cmd.param(3)) : 0; @teleport = [cmd.param(0), cmd.param(1), cmd.param(2), dir]; @wait_kind = :teleport; @waiting = true))
' }, # do_teleport
      { old: '      when Cmd::RECALL_LOCATION   then do_recall_location cmd
',
        new: '      when Cmd::RECALL_LOCATION   then (block_pending_teleport_command ? nil : (@teleport = [variables[cmd.param(0)], variables[cmd.param(1)],
                   variables[cmd.param(2)], 0]; @wait_kind = :teleport; @waiting = true))
' }, # do_recall_location
      { old: '      when Cmd::OPEN_LOAD_MENU   then do_open_load_menu cmd
',
        new: '      when Cmd::OPEN_LOAD_MENU   then (!(party.rpg2003?) ? nil : (@wait_kind = :load_menu; @waiting = true))
' }, # do_open_load_menu
      { old: '      when Cmd::EXIT_GAME        then do_exit_game cmd
',
        new: '      when Cmd::EXIT_GAME        then (!(party.rpg2003?) ? nil : (@wait_kind = :exit_game; @waiting = true))
' }, # do_exit_game
      { old: '      when Cmd::TOGGLE_ATB_MODE  then do_toggle_atb_mode cmd
',
        new: '      when Cmd::TOGGLE_ATB_MODE  then (!(party.rpg2003?) ? nil : (@state.atb_mode = @state.atb_mode == 1 ? 0 : 1))
' }, # do_toggle_atb_mode
      { old: '      when Cmd::TOGGLE_FULLSCREEN then do_toggle_fullscreen cmd
',
        new: '      when Cmd::TOGGLE_FULLSCREEN then (!(party.rpg2003?) ? nil : ($stderr.puts \'[RPG2k] Toggle Fullscreen: this display has no fullscreen mode\'))
' }, # do_toggle_fullscreen
      { old: '      when Cmd::OPEN_VIDEO_OPTIONS then do_open_video_options cmd
',
        new: '      when Cmd::OPEN_VIDEO_OPTIONS then (!(party.rpg2003?) ? nil : ($stderr.puts \'[RPG2k] Open Video Options: no video-options screen in this build\'))
' }, # do_open_video_options
      { old: '      return if block_pending_battle_command
',
        new: '      return if (!(message_window_blocks_command?) ? false : (@index -= 1; @wait_kind = :battle_blocked; @waiting = true; true))
' }, # block_pending_battle_command
      { old: '      return if block_pending_key_input_command(wait)
',
        new: '      return if (!(wait && message_window_blocks_command?) ? false : (@index -= 1; @wait_kind = :key_input_blocked; @waiting = true; true))
' }, # block_pending_key_input_command
      { old: '      when Cmd::ERASE_PICTURE    then do_erase_picture cmd
',
        new: '      when Cmd::ERASE_PICTURE    then (block_pending_picture_command ? nil : (@state.erase_picture(cmd.param(0))))
' }, # do_erase_picture
    ],
  },
  'mruby-rpg2k/mrblib/scene/title.rb' => {
    deletions: [
      { first: '      def continue_available?',
        last: '      end', # def continue_available?'s own `end`
        expect_lines: 5 },
    ],
    substitutions: [
      { old: '        @continue_available = continue_available?',
        new: '        @continue_available = (parent.any_save_exists? rescue false)' },
    ],
  },
  'mruby-rpg2k/mrblib/scene/status_menu.rb' => {
    deletions: [
      { first: '      def draw_battle_row(c, a)',
        last: '      end', # def draw_battle_row's own `end`
        expect_lines: 5 },
      { first: '      def draw_gold',
        last: '      end', # def draw_gold's own `end`
        expect_lines: 6 },
    ],
    substitutions: [
      { old: '        draw_battle_row c, a if rpg2003_party?',
        new: '        (back = a.respond_to?(:battle_row) && a.battle_row == Game::Actor::ROW_BACK; ' \
             'draw_system_text c, 0, ROW_LABEL_LINE * LINE_H, c.width, LINE_H, ' \
             'back ? ROW_BACK_LABEL : ROW_FRONT_LABEL, @skin, 0, 2) if rpg2003_party?' },
      { old: '        draw_gold
',
        new: '        (c = new_contents(@gold_window); draw_system_text c, 0, 0, c.width, LINE_H,
                         "#{@state.party.gold}#{term(:gold)}", @skin, 0, 2; @gold_window.contents = c)
' }, # draw_gold
    ],
  },
  'mruby-rpg2k/mrblib/scene/item_menu.rb' => {
    deletions: [
      { first: '      def invalidate_items',
        last: '      end', # def invalidate_items's own `end`
        expect_lines: 3 },
      { first: '      def item_row_count',
        last: '      end', # def item_row_count's own `end`
        expect_lines: 3 },
      { first: '      def leader_target_index',
        last: '      end', # def leader_target_index's own `end`
        expect_lines: 3 },
      { first: '      def build_possessed_window',
        last: '      end', # def build_possessed_window's own `end`
        expect_lines: 13 },
    ],
    substitutions: [
      { old: '        invalidate_items',
        new: '        @items = nil' },
      { old: '        @down_arrow.visible = listing && blink_on && @item_top < item_row_count - VISIBLE_ROWS
',
        new: '        @down_arrow.visible = listing && blink_on && @item_top < ([(items.size + COLUMN_MAX - 1) / COLUMN_MAX, 1].max) - VISIBLE_ROWS
' }, # item_row_count
      { old: '        @target_index = lock ? leader_target_index : 0
',
        new: '        @target_index = lock ? (@state.party.actors.index(@state.party.leader) || 0) : 0
' }, # leader_target_index
      { old: '          build_possessed_window
',
        new: '          (w = left_panel_w; inner_w = w - Window::BORDER * 2; @item_window = Window.new(0, DESC_H, w, DESC_H); @item_window.z = 400; @item_window.windowskin = @skin; c = Bitmap.new(inner_w, LINE_H); c.font.color = Color.new(255, 255, 255, 255); c.draw_text 0, 0, inner_w, LINE_H, term(:possessed_items); count = @pending_item ? @state.party.item_count(@pending_item) : 0; c.draw_text 0, 0, inner_w, LINE_H, count.to_s, 2; @item_window.contents = c)
' }, # build_possessed_window
    ],
  },
  'mruby-rpg2k/mrblib/main.rb' => {
    deletions: [
      { first: '    def position_arrow',
        last: '    end', # def position_arrow's own `end`
        expect_lines: 4 },
      { first: '    def draw_arrow',
        last: '    end', # def draw_arrow's own `end`
        expect_lines: 9 },
      { first: '  def db_path',
        last: '  end', # def db_path's own `end`
        expect_lines: 3 },
      { first: '  def bug_report_stamp',
        last: '  end', # def bug_report_stamp's own `end`
        expect_lines: 4 },
      { first: '    def drawn_height',
        last: '    end', # def drawn_height's own `end`
        expect_lines: 5 },
    ],
    substitutions: [
      { old: '      position_arrow
',
        new: '      (@arrow_sprite.x = @width / 2 - ARROW_W / 2; @arrow_sprite.y = @height - ARROW_H)
' }, # position_arrow
      { old: '      draw_arrow
',
        new: '      (@arrow_bmp.clear; if @windowskin
        @arrow_bmp.blt 0, 0, @windowskin,
                       Rect.new(ARROW_SRC_X, ARROW_SRC_Y, ARROW_W, ARROW_H)
      else
        draw_arrow_fallback
      end)
' }, # draw_arrow
      { old: '    @db = LCF::Database.new File.open db_path
',
        new: '    @db = LCF::Database.new File.open ("#{GAME_DIR}/RPG_RT.ldb")
' }, # db_path
      { old: '    path = "#{GAME_DIR}/bugreport_#{bug_report_stamp}.md"
',
        new: '    path = "#{GAME_DIR}/bugreport_#{(t = Time.now; "%04d%02d%02d_%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.min, t.sec])}.md"
' }, # bug_report_stamp
      { old: '      h = drawn_height
',
        new: '      h = (fully_open? ? @height : (h = (@height * @openness).to_i; h.negative? ? 0 : h))
' }, # drawn_height
    ],
  },
  'mruby-rpg2k/mrblib/scene/equip_menu.rb' => {
    deletions: [
      { first: '      def update_slots',
        last: '      end', # def update_slots's own `end`
        expect_lines: 52 },
      { first: '      def cand_row_count',
        last: '      end', # def cand_row_count's own `end`
        expect_lines: 3 },
      { first: '      def apply_choice',
        last: '      end', # def apply_choice's own `end`
        expect_lines: 13 },
      { first: '      def other_hand_item',
        last: '      end', # def other_hand_item's own `end`
        expect_lines: 6 },
    ],
    substitutions: [
      { old: '        @mode == :items ? update_items : update_slots
',
        new: '        @mode == :items ? update_items : (party = @state.party.actors; if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_slot_cursor(1)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_slot_cursor(-1)
        # A solo party leaves RIGHT/LEFT silent no-ops -- this was only ever
        # cited to a reference implementation\'s own live source (gating
        # both branches on the party having more than one actor), the exact
        # kind of claim this session\'s
        # methodology treats as worth re-checking on its own. Independently
        # re-verified since (cycle #121, and again in cycle #250) against a
        # genuine RPG_RT.exe under wine: with a solo-actor party on the real
        # Equip screen, a single RIGHT tap followed by a single LEFT tap
        # left the captured frame pixel-identical (0 differing pixels,
        # `compare -fuzz 5%`) to the frame taken before the RIGHT -- the
        # only pixel movement anywhere in the sequence was the windowskin\'s
        # own constant cursor-blink noise floor (a steady 3200 px, present
        # between every frame pair regardless of input), not a rebuilt
        # screen or a moved actor. Confirmed correct; no code change.
        elsif party.size > 1 && Input.trigger?(Input::RIGHT)
          @actor_index += 1
          @actor_index %= party.size
          rebuild_for_actor
          play_system_se(SFX_CURSOR)
        elsif party.size > 1 && Input.trigger?(Input::LEFT)
          @actor_index -= 1
          @actor_index %= party.size
          rebuild_for_actor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          # 装備固定 / 呪われた装備: RPG_RT refuses to even open the item list
          # for such an actor, or for a slot currently holding a cursed item,
          # ported from a reference implementation\'s equip-selection update
          # (NOT independently confirmed against genuine RPG_RT under wine --
          # Nepheshel\'s database carries no cursed equipment and no
          # equipment-fixed actor to try it on), rather than opening it and
          # rejecting whatever gets chosen there -- a rejected Decision plays
          # Buzzer, matching every other "confirmed but refused" case this
          # scene\'s siblings handle the same way.
          if actor.equipment_fixed? || actor.slot_cursed?(@slot_index)
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            @mode = :items
            refresh_cand_cursor
          end
        end)
' }, # update_slots
      { old: '        @down_arrow.visible = blink_on && @cand_top < cand_row_count - VISIBLE_ROWS
',
        new: '        @down_arrow.visible = blink_on && @cand_top < ([(candidates.size + COLUMN_MAX - 1) / COLUMN_MAX, 1].max) - VISIBLE_ROWS
' }, # cand_row_count
      { old: '          apply_choice
',
        new: '          (id, = candidates[@cand_index]; if id == 0
          @state.party.unequip_to_bag(actor, @slot_index)
        else
          # Pass the slot the candidate list was built for -- a 二刀流 actor\'s
          # second weapon has to land in the shield slot (1), which its own
          # item type (weapon, slot 0) would not otherwise pick.
          @state.party.equip_from_bag(actor, id, @slot_index)
        end; leave_items; rebuild_for_actor)
' }, # apply_choice
      { old: '        other = other_hand_item
',
        new: '        other = (case @slot_index
        when Game::Actor::WEAPON_SLOT then actor.equipment[Game::Actor::SHIELD_SLOT]
        when Game::Actor::SHIELD_SLOT then actor.equipment[Game::Actor::WEAPON_SLOT]
        end)
' }, # other_hand_item
    ],
  },
  'mruby-rpg2k/mrblib/scene/menu.rb' => {
    deletions: [
      { first: '      def update_actor_selection',
        last: '      end', # def update_actor_selection's own `end`
        expect_lines: 19 },
      { first: '      def build_gold_window',
        last: '      end', # def build_gold_window's own `end`
        expect_lines: 6 },
      { first: '      def update_end_game_confirm',
        last: '      end', # def update_end_game_confirm's own `end`
        expect_lines: 19 },
      { first: '      def wait_term_for(key, term_name)',
        last: '      end', # def wait_term_for's own `end`
        expect_lines: 4 },
    ],
    substitutions: [
      { old: '        when :actors then update_actor_selection
',
        new: '        when :actors then (party = @state.party.actors; if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_actor_selection
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @actor_index += 1
          @actor_index %= party.size
          refresh_status_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @actor_index -= 1
          @actor_index %= party.size
          refresh_status_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          confirm_actor_selection
        end)
' }, # update_actor_selection
      { old: '        build_gold_window
',
        new: '        (@gold = Window.new(0, SCREEN_H - GOLD_WINDOW_H, GOLD_WINDOW_W, GOLD_WINDOW_H); @gold.z = 400; @gold.windowskin = @skin; draw_gold_window)
' }, # build_gold_window
      { old: '        when :end_game_confirm then update_end_game_confirm
',
        new: '        when :end_game_confirm then (if Input.trigger?(Input::DOWN) || Input.trigger?(Input::UP) ||
           Input.repeat?(Input::DOWN) || Input.repeat?(Input::UP)
          @confirm_index = (@confirm_index == END_GAME_YES) ? END_GAME_NO : END_GAME_YES
          refresh_end_game_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_end_game_confirm
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          if @confirm_index == END_GAME_YES
            RGSS::Audio.bgm_fade(400)
            @parent.return_to_title
          else
            close_end_game_confirm
          end
        end)
' }, # update_end_game_confirm
      { old: '        keys.map { |key, term_name| [key, wait_term_for(key, term_name)] }
',
        new: '        keys.map { |key, term_name| [key, (key == :wait ? wait_label : (term(term_name)))] }
' }, # wait_term_for
    ],
  },
  'mruby-rpg2k/mrblib/scene/order.rb' => {
    deletions: [
      { first: '      def enter_confirm',
        last: '      end', # def enter_confirm's own `end`
        expect_lines: 9 },
    ],
    substitutions: [
      { old: '        enter_confirm if @counter == @names.size
',
        new: '        (@focus = :confirm; @confirm_index = 0; @left_window.active = false; @left_window.cursor_rect = Rect.new(0, 0, 0, 0); @confirm_window.visible = true; @confirm_window.active = true; refresh_confirm_cursor) if @counter == @names.size
' }, # enter_confirm
    ],
  },
  'mruby-rpg2k/mrblib/scene/save_load.rb' => {
    deletions: [
      { first: '      def confirm_selection',
        last: '      end', # def confirm_selection's own `end`
        expect_lines: 19 },
      { first: '      def build_header_window',
        last: '      end', # def build_header_window's own `end`
        expect_lines: 11 },
    ],
    substitutions: [
      { old: '          confirm_selection
',
        new: '          (slot = @index + 1; case @mode
        when :save
          play_system_se(SFX_DECISION)
          @parent.save_game(@state, slot)
          @parent.pop
        when :load
          # An empty slot has nothing to resume -- refused (Buzzer), like the
          # selection key on a title screen Continue with no save at all
          # (Scene::Title#update).
          if @slots[@index]
            play_system_se(SFX_DECISION)
            @parent.continue_game(slot)
          else
            play_system_se(SFX_BUZZER)
          end
        end)
' }, # confirm_selection
      { old: '        build_header_window
',
        new: '        (@header_window = Window.new(0, 0, SCREEN_W, HEADER_H); @header_window.z = 400; @header_window.windowskin = @skin; inner_w = SCREEN_W - Window::BORDER * 2; c = Bitmap.new(inner_w, LINE_H); header = @mode == :save ? term(:save_file_select) :
                                   term(:load_file_select); draw_system_text c, 0, 0, inner_w, LINE_H, header, @skin, TEXT_COLOR; @header_window.contents = c)
' }, # build_header_window
    ],
  },
  'mruby-rpg2k/mrblib/scene/skill_menu.rb' => {
    deletions: [
      { first: '      def update_skills',
        last: '      end', # def update_skills's own `end`
        expect_lines: 23 },
      { first: '      def leave_target',
        last: '      end', # def leave_target's own `end`
        expect_lines: 25 },
      { first: '      def build_mp_cost_window',
        last: '      end', # def build_mp_cost_window's own `end`
        expect_lines: 14 },
      { first: '      def total_rows',
        last: '      end', # def total_rows's own `end`
        expect_lines: 3 },
    ],
    substitutions: [
      { old: '        else update_skills
',
        new: '        else (if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_skill_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_skill_cursor(-COLUMN_MAX)
        # Right/Left cross a row boundary rather than stopping at the row\'s
        # own edge -- see Scene::ItemMenu#update_items\'s identical comment
        # (ported from a reference implementation, not independently
        # confirmed against genuine RPG_RT under wine:
        # Right/Left are a flat `index +- 1`
        # bounded only by the list\'s own absolute start/end, no row-boundary
        # check, unlike Down/Up\'s genuine column-lock).
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          move_skill_cursor(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          move_skill_cursor(-1)
        elsif Input.trigger?(Input::C)
          choose_skill
        end)
' }, # update_skills
      { old: '          leave_target
',
        new: '          (@pending_skill = nil; @target_lock = nil; @mode = :skills; if @target_window
          @target_window.dispose
          @target_window = nil
        end; @skills = nil; @skill_index = skills.size - 1 if @skill_index >= skills.size; @skill_index = 0 if @skill_index < 0; build_status_window; build_skill_window; build_desc_window; refresh_arrows)
' }, # leave_target
      { old: '          build_mp_cost_window
',
        new: '          (w = left_panel_w; inner_w = w - Window::BORDER * 2; @skill_window = Window.new(0, DESC_H, w, DESC_H); @skill_window.z = 400; @skill_window.windowskin = @skin; c = Bitmap.new(inner_w, LINE_H); c.font.color = Color.new(255, 255, 255, 255); c.draw_text 0, 0, inner_w, LINE_H, term(:mp_cost); sk = @pending_skill ? @state.party.db_skill(@pending_skill) : nil; cost = sk ? @state.party.skill_cost(sk, caster) : 0; c.draw_text 0, 0, inner_w, LINE_H, cost.to_s, 2; @skill_window.contents = c)
' }, # build_mp_cost_window
      { old: '        @down_arrow.visible = !!(showing && @top_row + VISIBLE_ROWS < total_rows)
',
        new: '        @down_arrow.visible = !!(showing && @top_row + VISIBLE_ROWS < ([(skills.size + COLUMN_MAX - 1) / COLUMN_MAX, 1].max))
' }, # total_rows
    ],
  },
}.freeze

def apply_deletion(lines, spec, path)
  first_idxs = lines.each_index.select { |i| lines[i].chomp == spec[:first] }
  raise "#{path}: expected exactly 1 line matching #{spec[:first].inspect}, found #{first_idxs.size} -- " \
        'source has drifted since this rewrite was written; update strip_wio_inline_helpers.rb' \
    unless first_idxs.size == 1

  start = first_idxs.first
  last_idxs = (start...lines.size).select { |i| lines[i].chomp == spec[:last] }
  raise "#{path}: expected a line matching #{spec[:last].inspect} after line #{start + 1}, found none" \
    if last_idxs.empty?

  stop = last_idxs.first
  got = stop - start + 1
  raise "#{path}: deletion block #{spec[:first].inspect}..#{spec[:last].inspect} is #{got} lines, " \
        "expected #{spec[:expect_lines]} -- source has drifted; update strip_wio_inline_helpers.rb" \
    unless got == spec[:expect_lines]

  # Drop the block plus one trailing blank line (the separator before
  # whatever follows), so deleting it never leaves a double blank line.
  stop += 1 if lines[stop + 1] && lines[stop + 1].chomp.empty?
  lines[start..stop] = []
end

def apply_rewrites(src, rewrites, path)
  lines = src.each_line.to_a
  (rewrites[:deletions] || []).each { |spec| apply_deletion(lines, spec, path) }
  out = lines.join

  (rewrites[:substitutions] || []).each do |r|
    count = out.scan(r[:old]).length
    raise "#{path}: expected exactly 1 occurrence of #{r[:old].inspect}, found #{count} -- " \
          'source has drifted since this rewrite was written; update strip_wio_inline_helpers.rb' \
      unless count == 1

    out = out.sub(r[:old], r[:new])
  end
  out
end

if __FILE__ == $PROGRAM_NAME
  in_path, out_path = ARGV
  raise ArgumentError, "usage: #{$PROGRAM_NAME} <input.rb> <output.rb>" unless in_path && out_path

  source = File.read(in_path, external_encoding: Encoding::UTF_8)

  rel = REWRITES.keys.find { |k| in_path.end_with?(k) }
  rewritten = rel ? apply_rewrites(source, REWRITES[rel], in_path) : source

  if Ripper.sexp(source) && !Ripper.sexp(rewritten)
    raise "strip_wio_inline_helpers: rewrite of #{in_path} does not parse; " \
          "leaving the original untouched"
  end

  File.write(out_path, rewritten)
end
