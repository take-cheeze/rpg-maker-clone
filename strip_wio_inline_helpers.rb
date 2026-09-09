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
    ],
  },
  'mruby-rpg2k/mrblib/scene/base.rb' => {
    deletions: [],
    substitutions: [
      { old: "        shx, shy = Game::MessagePalette.shadow_origin\n",
        new: "        shx, shy = Game::MessagePalette::SHADOW_X, Game::MessagePalette::SHADOW_Y\n" },
      { old: "        sx, sy = Game::MessagePalette.cell_origin(idx)\n",
        new: "        sx = (idx % Game::MessagePalette::COLS) * cell\n" \
             "        sy = (idx / Game::MessagePalette::COLS) * cell + Game::MessagePalette::Y_OFFSET\n" },
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
    ],
    substitutions: [
      { old: '        draw_battle_row c, a if rpg2003_party?',
        new: '        (back = a.respond_to?(:battle_row) && a.battle_row == Game::Actor::ROW_BACK; ' \
             'draw_system_text c, 0, ROW_LABEL_LINE * LINE_H, c.width, LINE_H, ' \
             'back ? ROW_BACK_LABEL : ROW_FRONT_LABEL, @skin, 0, 2) if rpg2003_party?' },
    ],
  },
  'mruby-rpg2k/mrblib/scene/item_menu.rb' => {
    deletions: [
      { first: '      def invalidate_items',
        last: '      end', # def invalidate_items's own `end`
        expect_lines: 3 },
    ],
    substitutions: [
      { old: '        invalidate_items',
        new: '        @items = nil' },
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
