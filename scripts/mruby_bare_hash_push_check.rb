#!/usr/bin/env ruby
# encoding: UTF-8
# Guard against a real mruby/CRuby divergence: a bare, unbraced trailing
# keyword-style hash passed to Array#push/#unshift/#concat.
#
# `Array#push` (and #unshift/#concat) are builtin C-defined methods with no
# declared keyword parameters. CRuby falls back to treating a bare trailing
# `key: value, ...` argument list as one ordinary positional Hash when the
# callee declares no keyword parameters at all -- but this project's mruby
# build does not make that same fallback for a builtin method: the hash
# silently evaporates instead of being pushed, with no exception anywhere to
# catch it (Interpreter#update's per-command dispatch has no rescue around
# an individual command). Two real, live instances of exactly this shipped
# silently broken: Interpreter#do_move_event (found investigating Nepheshel
# map 23 event 29, a secret door whose Move Event never actually moved or
# turned it, even though its own SE played -- see
# changelog.d/move-event-queue-bare-hash-push.fixed.md) and
# Interpreter#do_flash_sprite (the identical shape, never independently
# reported since nothing else in this codebase reads a Flash Sprite's timing
# closely enough to notice a request silently dropped). Neither
# scripts/rpg2k_scene_check.rb nor scripts/rpg2k_logic_check.rb can see this
# class of bug at all, since both run these same sources under plain CRuby
# (see docs/adr/0021-nepheshel-render-parity-under-wine.md's own two prior
# examples of a CRuby-invisible mruby divergence) -- this is a *static*
# source check instead, so it catches the pattern itself rather than one
# more behavioral symptom of it.
#
# The fix at both sites was to brace the hash literal explicitly
# (`.push({ ... })`), which is unambiguous -- always one ordinary positional
# Hash argument -- under every Ruby implementation; three sibling
# `@location_requests.push({ ... })` call sites already used this form.
#
# Usage: ruby scripts/mruby_bare_hash_push_check.rb
# Exits non-zero (naming every offending file:line) if the pattern is found
# anywhere under a mruby-*/mrblib tree.

ROOT = File.expand_path('..', __dir__)
METHODS = %w[push unshift concat].freeze

mrblib_dirs = Dir.glob(File.join(ROOT, 'mruby-*/mrblib')).sort
if mrblib_dirs.empty?
  warn 'mruby bare-hash-push check: no mruby-*/mrblib directories found'
  exit 1
end

offenses = []

mrblib_dirs.each do |dir|
  Dir.glob(File.join(dir, '**', '*.rb')).sort.each do |path|
    lines = File.readlines(path, encoding: 'UTF-8')
    lines.each_with_index do |line, i|
      METHODS.each do |m|
        # Case 1: `.push(` ending the line (the multi-line call-with-a-hash
        # shape both real bugs had) -- the very next non-comment content line
        # must not itself already open a brace.
        next unless line =~ /\.#{m}\(\s*(#.*)?$/

        nxt = lines[(i + 1)..].find { |l| !l.strip.empty? }
        next unless nxt

        if nxt =~ /^\s*[A-Za-z_]\w*:\s/ && nxt !~ /^\s*\{/
          offenses << "#{path}:#{i + 1}: bare `.#{m}(` followed by an " \
                      "unbraced `#{nxt.strip[/\A[A-Za-z_]\w*:/]}` -- wrap the " \
                      "hash in `{ ... }`"
        end
      end
    end

    # Case 2: the whole call sits on one line, e.g. `.push(a: 1, b: 2)`.
    lines.each_with_index do |line, i|
      METHODS.each do |m|
        next unless line =~ /\.#{m}\(\s*([A-Za-z_]\w*:\s)/

        offenses << "#{path}:#{i + 1}: bare `.#{m}(#{Regexp.last_match(1).strip} " \
                    '...)` on one line -- wrap the hash in `{ ... }`' unless line =~ /\.#{m}\(\s*\{/
      end
    end
  end
end

if offenses.empty?
  puts "mruby bare-hash-push check: #{mrblib_dirs.size} mrblib tree(s) clean"
  exit 0
end

offenses.uniq.sort.each { |o| warn "mruby bare-hash-push check: #{o}" }
exit 1
