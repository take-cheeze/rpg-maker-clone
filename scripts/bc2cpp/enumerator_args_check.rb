#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the writers of Enumerator's @args, the premise for typing it as an Array. Every writer in the closed
# world stores an Array, by induction over the writers:
#   - initialize(obj = NONE, meth = :each, *args, **kwd): args is the rest parameter (always an Array);
#   - initialize_copy: args = @args read from another enumerator (an Array by induction);
#   - each: args is argv.dup or args.dup followed by concat(argv), so an Array.
# This script fails if the set of writers changes, so a new writer forces a review of that argument.
# It also fails on dynamic ivar writes (instance_variable_set) in the closed world's Ruby.
#
# Usage: ruby scripts/bc2cpp/enumerator_args_check.rb

ROOT = File.expand_path('../..', __dir__)

def ruby_sources
  Dir[File.join(ROOT, '3rd/mruby/mrbgems/*/mrblib/**/*.rb')] +
    Dir[File.join(ROOT, '3rd/mruby/mrblib/**/*.rb')] +
    Dir[File.join(ROOT, 'mruby-*/mrblib/**/*.rb')] +
    Dir[File.join(ROOT, '3rd/mruby-*/mrblib/**/*.rb')]
end

failures = []
writers = ruby_sources.flat_map do |path|
  File.readlines(path, encoding: 'UTF-8').each_with_index.filter_map do |line, i|
    next unless line.match?(/@args\s*=(?!=)/)

    [File.basename(path), i + 1, line.strip]
  end
end

# Only Enumerator's own writers count: other classes (mruby-wolf, mruby-mvjs) define their own @args and are
# not in the closed world, so they are excluded by the source set above (their gems are not closed-world).
enum_writers = writers.select { |file, _, _| file == 'enumerator.rb' }
failures << "expected 3 @args writers in enumerator.rb, found #{enum_writers.size}" unless enum_writers.size == 3
enum_writers.each do |file, line, text|
  next if text.match?(/\A@args = args\z/) || text.match?(/instance_eval\{@args = args\}/)

  failures << "unreviewed @args writer #{file}:#{line}: #{text}"
end

# A write to @args by name (instance_variable_set with a literal :@args, or a computed name) would bypass the
# writers above. A literal ivar symbol other than @args cannot write Enumerator's @args.
ruby_sources.each do |path|
  File.read(path, encoding: 'UTF-8').scan(/instance_variable_set\(([^,)]*)/) do |(arg)|
    arg = arg.strip
    next if arg.match?(/\A:@\w+\z/) && arg != ':@args'

    failures << "instance_variable_set with #{arg.inspect} in #{path.delete_prefix("#{ROOT}/")}"
  end
end

if failures.empty?
  puts 'enumerator_args_check: every @args writer is one of the reviewed three'
else
  failures.each { |f| warn "enumerator_args_check: #{f}" }
  exit 1
end
