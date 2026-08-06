#!/usr/bin/env ruby
# frozen_string_literal: true

# Push .github/labels.yml to the repository's GitHub labels.
#
# Creating a label is idempotent (`gh label create --force` updates an existing
# one), so this can run on every push that touches the file. Deleting is not:
# a label missing from the file is left alone unless `--prune` is passed, so a
# label somebody added by hand in the issue tracker survives a sync.
#
#     ruby scripts/sync_github_labels.rb                # create / update
#     ruby scripts/sync_github_labels.rb --dry-run      # show what it would do
#     ruby scripts/sync_github_labels.rb --prune        # also delete the rest
#
# Needs the `gh` CLI authenticated (GH_TOKEN in CI) and, unless `--repo` is
# given, a repository it can infer (GH_REPO or the current checkout).

require 'json'
require 'optparse'
require 'yaml'

options = { file: File.expand_path('../.github/labels.yml', __dir__), prune: false, dry_run: false }

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby scripts/sync_github_labels.rb [options]'
  opts.on('--file PATH', 'Label definitions (default .github/labels.yml)') { |v| options[:file] = v }
  opts.on('--repo OWNER/NAME', 'Repository to sync (default: gh’s current one)') { |v| options[:repo] = v }
  opts.on('--prune', 'Delete labels that the file does not define') { options[:prune] = true }
  opts.on('-n', '--dry-run', 'Print the changes without making them') { options[:dry_run] = true }
end.parse!

REPO_ARGS = options[:repo] ? ['--repo', options[:repo]] : []

def gh_capture(*args)
  out = IO.popen(['gh', *args], &:read)
  raise "gh #{args.join(' ')} failed" unless $?.success?

  out
end

def gh_run(*args, dry_run:)
  if dry_run
    puts "  would run: gh #{args.join(' ')}"
    return
  end
  raise "gh #{args.join(' ')} failed" unless system('gh', *args)
end

desired = YAML.safe_load_file(options[:file])
unless desired.is_a?(Array) && desired.all? { |l| l.is_a?(Hash) && l['name'] }
  abort "#{options[:file]}: expected a list of { name, color, description } entries"
end

existing = JSON.parse(gh_capture('label', 'list', *REPO_ARGS, '--limit', '200', '--json', 'name,color,description'))
by_name = existing.to_h { |l| [l['name'], l] }

created = updated = unchanged = 0
desired.each do |label|
  name = label['name']
  color = label['color'].to_s.delete_prefix('#')
  description = label['description'].to_s
  current = by_name[name]

  if current && current['color'].to_s.casecmp?(color) && current['description'].to_s == description
    unchanged += 1
    next
  end

  puts(current ? "update #{name}" : "create #{name}")
  gh_run('label', 'create', name, *REPO_ARGS, '--color', color, '--description', description, '--force',
         dry_run: options[:dry_run])
  current ? updated += 1 : created += 1
end

pruned = 0
if options[:prune]
  (by_name.keys - desired.map { |l| l['name'] }).each do |name|
    puts "delete #{name}"
    gh_run('label', 'delete', name, *REPO_ARGS, '--yes', dry_run: options[:dry_run])
    pruned += 1
  end
end

puts "#{created} created, #{updated} updated, #{unchanged} unchanged, #{pruned} deleted" \
     "#{options[:dry_run] ? ' (dry run)' : ''}"
