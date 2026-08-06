#!/usr/bin/env ruby
# frozen_string_literal: true

# Keep the three halves of the label taxonomy in agreement:
#
#   .github/labels.yml            the labels that exist (source of truth)
#   .github/labeler.yml           path rules for pull requests
#   .github/ISSUE_TEMPLATE/*.yml  the form pickers, mapped by
#                                 scripts/issue_form_labels.rb
#
# A label typo'd in one of the last three is invisible in production: the
# labeler silently creates a stray label, `gh issue edit --add-label` fails on
# the issue nobody is watching. So this runs from pre-commit (and therefore in
# CI) over every one of them, plus a few cases for the issue-body parser.
#
#     ruby scripts/label_config_check.rb

require 'set'
require 'yaml'
require_relative 'issue_form_labels'

ROOT = File.expand_path('..', __dir__)
LABELS_FILE = File.join(ROOT, '.github/labels.yml')
LABELER_FILE = File.join(ROOT, '.github/labeler.yml')
TEMPLATE_GLOB = File.join(ROOT, '.github/ISSUE_TEMPLATE/*.yml')

GROUPS = %w[engine platform component type status].freeze

@errors = []

def error(message)
  @errors << message
end

def rel(path)
  path.sub("#{ROOT}/", '')
end

# --- .github/labels.yml ----------------------------------------------------

definitions = YAML.safe_load_file(LABELS_FILE)
error("#{rel(LABELS_FILE)}: expected a list of entries") unless definitions.is_a?(Array)
definitions = [] unless definitions.is_a?(Array)

names = []
definitions.each_with_index do |label, i|
  where = "#{rel(LABELS_FILE)} entry #{i + 1}"
  unless label.is_a?(Hash)
    error("#{where}: expected a mapping, got #{label.class}")
    next
  end

  name = label['name']
  error("#{where}: missing a name") if name.to_s.empty?
  error("#{where} (#{name}): duplicate name") if names.include?(name)
  names << name

  color = label['color'].to_s
  error("#{where} (#{name}): color #{color.inspect} is not six hex digits") unless color.match?(/\A[0-9a-f]{6}\z/)

  error("#{where} (#{name}): missing a description") if label['description'].to_s.empty?

  next unless name.to_s.include?(':')

  group = name.split(':', 2).first
  error("#{where} (#{name}): unknown group #{group.inspect}, expected one of #{GROUPS.join(', ')}") unless
    GROUPS.include?(group)
end

known = names.to_set

# --- .github/labeler.yml ---------------------------------------------------

rules = YAML.safe_load_file(LABELER_FILE)
if rules.is_a?(Hash)
  rules.each do |label, matchers|
    error("#{rel(LABELER_FILE)}: #{label.inspect} is not in #{rel(LABELS_FILE)}") unless known.include?(label)

    globs = Array(matchers).flat_map do |matcher|
      next [] unless matcher.is_a?(Hash)

      Array(matcher['changed-files']).flat_map { |m| m.is_a?(Hash) ? m.values.flatten : [] }
    end
    error("#{rel(LABELER_FILE)}: #{label.inspect} has no globs") if globs.empty?
  end
else
  error("#{rel(LABELER_FILE)}: expected a mapping of label => rules")
end

# --- issue forms and their mapping -----------------------------------------

IssueFormLabels::ANSWER_LABELS.each do |heading, mapping|
  mapping.each do |answer, label|
    next if label.nil?

    error("scripts/issue_form_labels.rb: #{heading}/#{answer.inspect} maps to #{label.inspect}, " \
          "which is not in #{rel(LABELS_FILE)}") unless known.include?(label)
  end
end

templates = Dir[TEMPLATE_GLOB].reject { |path| File.basename(path) == 'config.yml' }.sort
error("no issue forms found under #{rel(File.dirname(TEMPLATE_GLOB))}") if templates.empty?

templates.each do |path|
  form = YAML.safe_load_file(path)
  Array(form['labels']).each do |label|
    error("#{rel(path)}: default label #{label.inspect} is not in #{rel(LABELS_FILE)}") unless known.include?(label)
  end

  Array(form['body']).each do |field|
    next unless field.is_a?(Hash)

    attributes = field['attributes'] || {}
    heading = attributes['label']
    mapping = IssueFormLabels::ANSWER_LABELS[heading]
    next if mapping.nil?

    unless field['type'] == 'dropdown'
      error("#{rel(path)}: the #{heading.inspect} field is a #{field['type']}, " \
            'but the label mapping parses it as a dropdown')
      next
    end

    Array(attributes['options']).each do |option|
      error("#{rel(path)}: #{heading} option #{option.inspect} contains a comma, which the " \
            'comma-separated answer line cannot be split on') if option.to_s.include?(',')

      error("#{rel(path)}: #{heading} option #{option.inspect} is not mapped in " \
            'scripts/issue_form_labels.rb') unless mapping.key?(option)
    end
  end
end

# --- the parser itself -----------------------------------------------------

body = <<~BODY
  ### What happened

  The chest plays its SE twice.

  ### Engine

  RPG Maker 2000, RPG Maker MZ

  ### Platform

  _No response_

  ### Component

  Audio, Scenes / menus / windows
BODY

expected = %w[engine:rpg2k engine:mz component:audio component:scenes]
got = IssueFormLabels.labels(body, warn_io: nil)
error("issue form parse: expected #{expected.inspect}, got #{got.inspect}") unless got == expected

# CRLF (what a browser posts), an unmapped leftover answer and the "unsure"
# options that deliberately produce nothing.
crlf = "### Engine\r\n\r\nRPG Maker XP, RPG Maker 3000\r\n\r\n### Component\r\n\r\nNot sure\r\n"
got = IssueFormLabels.labels(crlf, warn_io: nil)
error("issue form parse (CRLF): expected [\"engine:xp\"], got #{got.inspect}") unless got == ['engine:xp']

# A body with no form at all (a blank issue) asks for no labels.
got = IssueFormLabels.labels("Just a note about a wrong pixel.\n", warn_io: nil)
error("issue form parse (free text): expected [], got #{got.inspect}") unless got.empty?

# --- report ----------------------------------------------------------------

if @errors.empty?
  puts "label config OK: #{names.size} labels, #{rules.is_a?(Hash) ? rules.size : 0} labeler rules, " \
       "#{templates.size} issue forms"
  exit 0
end

@errors.each { |message| warn "error: #{message}" }
exit 1
