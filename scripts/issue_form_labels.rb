#!/usr/bin/env ruby
# frozen_string_literal: true

# Turn the Engine / Platform / Component answers of an issue form into
# repository labels.
#
# GitHub renders an issue form (.github/ISSUE_TEMPLATE/*.yml) into Markdown:
# every field becomes an `### <field label>` heading followed by the answer,
# and a `multiple: true` dropdown puts its picks on one comma-separated line.
#
#     ### Engine
#
#     RPG Maker 2000, RPG Maker MZ
#
#     ### Platform
#
#     _No response_
#
# So the mapping is a lookup from the answer strings the form offers to the
# labels in .github/labels.yml. Both sides are pinned by
# scripts/label_config_check.rb: every option the templates offer must appear
# here, and every label named here must exist in .github/labels.yml.
#
# Usage:
#
#     ISSUE_BODY="$(...)" ruby scripts/issue_form_labels.rb   # body from the env
#     ruby scripts/issue_form_labels.rb -                     # body from stdin
#     ruby scripts/issue_form_labels.rb issue.md              # body from a file
#
# Prints one label per line (nothing at all when nothing matched), which is
# what .github/workflows/issue-labels.yml feeds to `gh issue edit --add-label`.

module IssueFormLabels
  # Answers that deliberately map to no label ("unsure", "not sure") are listed
  # with nil rather than left out, so the config check can tell a deliberate
  # no-op from an option somebody forgot to map.
  ANSWER_LABELS = {
    'Engine' => {
      'RPG Maker 2000' => 'engine:rpg2k',
      'RPG Maker 2003' => 'engine:rpg2k3',
      'RPG Maker XP' => 'engine:xp',
      'RPG Maker VX' => 'engine:vx',
      'RPG Maker VX Ace' => 'engine:vxace',
      'RPG Maker MV' => 'engine:mv',
      'RPG Maker MZ' => 'engine:mz',
      'Not engine specific / unsure' => nil
    }.freeze,
    'Platform' => {
      'Browser / WebAssembly' => 'platform:wasm',
      'Terminal (sixel / iTerm2)' => 'platform:terminal',
      'Linux (SDL)' => 'platform:linux',
      'Windows' => 'platform:windows',
      'PSP' => 'platform:psp',
      'Wio Terminal' => 'platform:wio',
      'Other platform' => 'platform:other'
    }.freeze,
    'Component' => {
      'Graphics / rendering' => 'component:graphics',
      'Audio' => 'component:audio',
      'Input' => 'component:input',
      'mruby runtime' => 'component:runtime-mruby',
      'JavaScript runtime (MV/MZ)' => 'component:runtime-js',
      'Game data / file formats' => 'component:data',
      'Save / load' => 'component:save',
      'Event interpreter' => 'component:events',
      'Scenes / menus / windows' => 'component:scenes',
      'Battle' => 'component:battle',
      'Build / packaging' => 'component:build',
      'CI' => 'component:ci',
      'Docs' => 'component:docs',
      'Scripts & test beds' => 'component:tooling',
      'Not sure' => nil
    }.freeze
  }.freeze

  # What GitHub writes for a field the reporter left empty.
  NO_RESPONSE = '_No response_'

  # The body split into `heading => text`, for the `###` headings only. A
  # reporter's own `###` inside a textarea answer starts a section too; that is
  # harmless, because only the three headings above are ever read back.
  def self.sections(body)
    result = {}
    heading = nil
    body.to_s.gsub("\r\n", "\n").each_line do |line|
      if (m = line.match(/\A###\s+(.*?)\s*\z/))
        heading = m[1]
        result[heading] ||= +''
      elsif heading
        result[heading] << line
      end
    end
    result
  end

  # The picks under one heading. Dropdown answers arrive comma separated (no
  # option may contain a comma — the config check enforces that); checkbox
  # answers, should a form switch to them, arrive as `- [X] option` lines.
  def self.answers(body, heading)
    text = sections(body)[heading]
    return [] if text.nil?

    text.each_line.flat_map do |line|
      line = line.strip
      next [] if line.empty? || line == NO_RESPONSE

      if (m = line.match(/\A- \[([ xX])\]\s*(.*)\z/))
        m[1] == ' ' ? [] : [m[2].strip]
      else
        line.split(',').map(&:strip).reject(&:empty?)
      end
    end
  end

  # Every label the body asks for, in taxonomy order, without duplicates.
  # Answers the form does not offer are reported on stderr and skipped: a stale
  # bookmark of an older form should not fail the labelling of a fresh issue.
  def self.labels(body, warn_io: $stderr)
    ANSWER_LABELS.flat_map do |heading, mapping|
      answers(body, heading).filter_map do |answer|
        unless mapping.key?(answer)
          warn_io&.puts("issue_form_labels: unknown #{heading} answer #{answer.inspect}")
          next
        end
        mapping[answer]
      end
    end.uniq
  end
end

if $PROGRAM_NAME == __FILE__
  body =
    case ARGV[0]
    when nil then ENV['ISSUE_BODY'].to_s
    when '-' then $stdin.read
    else File.read(ARGV[0])
    end

  puts IssueFormLabels.labels(body)
end
