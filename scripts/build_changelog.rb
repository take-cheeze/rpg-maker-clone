#!/usr/bin/env ruby
# frozen_string_literal: true

# Assemble changelog fragments (changelog.d/*.md) into CHANGELOG.md.
#
# Editing the single `## [Unreleased]` section by hand made every branch touch
# the same lines, so pull requests constantly conflicted. Instead each change
# lands as its own file under changelog.d/, and this script folds them in.
#
# Usage:
#   ruby scripts/build_changelog.rb list             # list pending fragments
#   ruby scripts/build_changelog.rb preview          # print the merged Unreleased section
#   ruby scripts/build_changelog.rb release VERSION [DATE]
#
# See changelog.d/README.md for the fragment format.

require "date"

# CHANGELOG.md and fragments contain UTF-8 (→, —, …); read/write them as such
# regardless of the ambient locale.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
FRAGMENT_DIR = File.join(ROOT, "changelog.d")
CHANGELOG = File.join(ROOT, "CHANGELOG.md")

# Canonical "Keep a Changelog" categories, in display order.
CATEGORIES = %w[added changed deprecated removed fixed security].freeze
HEADINGS = {
  "added" => "Added",
  "changed" => "Changed",
  "deprecated" => "Deprecated",
  "removed" => "Removed",
  "fixed" => "Fixed",
  "security" => "Security",
}.freeze

# A fragment file is `<slug>.<category>.md`. Returns [category, path] pairs
# grouped by category, in canonical order, each list sorted by filename so the
# output is deterministic regardless of filesystem order.
def load_fragments
  grouped = Hash.new { |h, k| h[k] = [] }
  Dir.glob(File.join(FRAGMENT_DIR, "*.md")).sort.each do |path|
    name = File.basename(path, ".md")
    category = name.split(".").last
    unless CATEGORIES.include?(category)
      abort "Fragment #{File.basename(path)} has an unknown category " \
            "'#{category}'. Expected one of: #{CATEGORIES.join(', ')}."
    end
    grouped[category] << path
  end
  grouped
end

# Read a fragment body, ensuring it is a non-empty Markdown bullet.
def fragment_body(path)
  body = File.read(path).strip
  abort "Fragment #{File.basename(path)} is empty." if body.empty?
  unless body.start_with?("- ")
    abort "Fragment #{File.basename(path)} must start with '- ' " \
          "(a Markdown list item). See changelog.d/README.md."
  end
  body
end

# Render pending fragments as `### Category` blocks.
def render_fragments(grouped)
  out = []
  CATEGORIES.each do |category|
    paths = grouped[category]
    next if paths.empty?

    out << "### #{HEADINGS[category]}"
    out << paths.map { |p| fragment_body(p) }.join("\n")
    out << ""
  end
  out.join("\n").rstrip
end

def pending_paths(grouped)
  CATEGORIES.flat_map { |c| grouped[c] }
end

def cmd_list
  grouped = load_fragments
  paths = pending_paths(grouped)
  if paths.empty?
    puts "No pending changelog fragments."
    return
  end
  puts "Pending changelog fragments:"
  paths.each { |p| puts "  #{File.basename(p)}" }
end

def cmd_preview
  grouped = load_fragments
  rendered = render_fragments(grouped)
  if rendered.empty?
    puts "No pending changelog fragments."
    return
  end
  puts "## [Unreleased]  (with pending fragments merged in)"
  puts
  puts rendered
end

# Split CHANGELOG.md into [preamble, unreleased_body, rest]. `unreleased_body`
# is everything between the `## [Unreleased]` heading and the next `## ` header
# (or end of file).
def split_changelog(text)
  lines = text.lines
  start = lines.index { |l| l.start_with?("## [Unreleased]") }
  abort "Could not find a '## [Unreleased]' heading in CHANGELOG.md." if start.nil?

  finish = ((start + 1)...lines.length).find { |i| lines[i].start_with?("## ") }
  finish ||= lines.length

  # preamble excludes the `## [Unreleased]` heading itself so the caller can
  # re-emit a fresh heading without duplicating it.
  preamble = lines[0...start].join
  body = lines[(start + 1)...finish].join
  rest = lines[finish..].join
  [preamble, body, rest]
end

# Append fragment bullets into the matching `### Category` subsection of the
# Unreleased body, creating subsections (in canonical order) when absent. Only
# the first occurrence of a heading is appended to; pre-existing duplicates are
# left untouched.
def merge_into_body(body, grouped)
  CATEGORIES.each do |category|
    paths = grouped[category]
    next if paths.empty?

    bullets = paths.map { |p| fragment_body(p) }.join("\n")
    heading = "### #{HEADINGS[category]}"
    body = append_to_subsection(body, category, heading, bullets)
  end
  body
end

def append_to_subsection(body, category, heading, bullets)
  lines = body.lines
  head_idx = lines.index { |l| l.rstrip == heading }

  if head_idx
    # Find the end of this subsection (next `### ` or end of body).
    nxt = ((head_idx + 1)...lines.length).find { |i| lines[i].start_with?("### ") }
    nxt ||= lines.length
    # Back up over trailing blank lines within the subsection.
    insert = nxt
    insert -= 1 while insert > head_idx + 1 && lines[insert - 1].strip.empty?
    lines.insert(insert, "#{bullets}\n")
    lines.join
  else
    insert_new_subsection(lines, category, heading, bullets).join
  end
end

# Insert a brand-new subsection so that subsections stay in canonical order.
def insert_new_subsection(lines, category, heading, bullets)
  rank = CATEGORIES.index(category)
  target = nil
  lines.each_with_index do |line, i|
    next unless line.start_with?("### ")

    other = line.sub("### ", "").strip.downcase
    other_rank = CATEGORIES.index(other)
    if other_rank && other_rank > rank
      target = i
      break
    end
  end

  block = ["#{heading}\n", "#{bullets}\n", "\n"]
  if target
    lines.insert(target, *block)
  else
    lines << "\n" unless lines.empty? || lines.last.end_with?("\n\n") || lines.last.strip.empty?
    lines.concat(block)
  end
  lines
end

def cmd_release(version, date)
  abort "VERSION is required, e.g. `release 1.2.0`." if version.nil? || version.empty?

  grouped = load_fragments
  text = File.read(CHANGELOG)
  preamble, body, rest = split_changelog(text)

  merged = merge_into_body(body, grouped).rstrip

  new_unreleased = "## [Unreleased]\n\n"
  released_header = "## [#{version}] - #{date}\n"
  released = "#{released_header}\n#{merged}\n\n"

  content = "#{preamble.rstrip}\n\n#{new_unreleased}#{released}#{rest.strip}\n"
  File.write(CHANGELOG, content.gsub(/\n{3,}/, "\n\n"))

  consumed = pending_paths(grouped)
  consumed.each { |p| File.delete(p) }

  puts "Released #{version} (#{date}); folded #{consumed.size} fragment(s) into CHANGELOG.md."
end

command = ARGV.shift
case command
when "list"
  cmd_list
when "preview"
  cmd_preview
when "release"
  version = ARGV.shift
  date = ARGV.shift || Date.today.iso8601
  cmd_release(version, date)
else
  warn <<~USAGE
    Usage:
      ruby scripts/build_changelog.rb list
      ruby scripts/build_changelog.rb preview
      ruby scripts/build_changelog.rb release VERSION [DATE]

    See changelog.d/README.md for the fragment format.
  USAGE
  exit(command.nil? ? 1 : 2)
end
