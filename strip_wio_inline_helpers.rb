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
    ],
    substitutions: [],
  },
  'mruby-rpg2k/mrblib/scene/map.rb' => {
    deletions: [
      { first: '      # Drive the just-started foreground Auto-Start process, then -- yado.tk',
        last: '      end', # def drive_autostart_cascade's own `end`
        expect_lines: 45 },
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
